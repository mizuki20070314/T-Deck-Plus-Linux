"""Minimal JFFS2 reader and single-file patcher (little-endian, 64 KiB blocks).

usage:
  py -I jffs2_tool.py slice FULL.bin OFFSET SIZE OUT.jffs2
  py -I jffs2_tool.py info  IMG
  py -I jffs2_tool.py ls    IMG
  py -I jffs2_tool.py cat   IMG /path            (raw bytes to stdout)
  py -I jffs2_tool.py patch IMG /path OUT --append-line TEXT
  py -I jffs2_tool.py patch IMG /path OUT --uncomment PREFIX

The patch appends a newer version of the file's inode (a new full-content data
node with version = highest + 1) into the erased tail of a block. This is the
same operation the kernel does when a file is rewritten, so nothing else in
the image changes. Pure stdlib, safe to run with `py -I`.
"""
import hashlib
import struct
import sys
import time
import zlib

EB = 0x10000
MAGIC = 0x1985
T_DIRENT, T_INODE, T_CLEAN, T_PAD, T_SUM = 0xE001, 0xE002, 0x2003, 0x2004, 0x2006
INODE_HDR = 68
DIRENT_HDR = 40


def jcrc(data):
    """JFFS2 crc: Linux crc32_le with seed 0 and no final xor."""
    return (~zlib.crc32(bytes(data), 0xFFFFFFFF)) & 0xFFFFFFFF


def pad4(n):
    return (n + 3) & ~3


def rtime_decompress(src, destlen):
    out = bytearray()
    positions = [0] * 256
    pos = 0
    while len(out) < destlen:
        value = src[pos]
        repeat = src[pos + 1]
        pos += 2
        out.append(value)
        backoffs = positions[value]
        positions[value] = len(out)
        for _ in range(repeat):
            out.append(out[backoffs])
            backoffs += 1
    return bytes(out[:destlen])


def decompress(compr, data, dsize):
    if compr == 0:
        return bytes(data)
    if compr == 1:
        return bytes(dsize)
    if compr == 2:
        return rtime_decompress(data, dsize)
    if compr == 6:
        return zlib.decompressobj().decompress(bytes(data))
    raise ValueError("unsupported jffs2 compression %d" % compr)


def scan(img):
    nodes, blocks, bad = [], [], []
    for b in range(0, len(img), EB):
        end = b + EB
        ofs = b
        used_end = b
        count = 0
        real = 0
        free_from = None
        while ofs + 4 <= end:
            if img[ofs:ofs + 4] == b"\xff\xff\xff\xff":
                if img.count(b"\xff", ofs, end) == end - ofs:
                    free_from = ofs
                    break
                ofs += 4
                continue
            magic, ntype = struct.unpack_from("<HH", img, ofs)
            if magic != MAGIC:
                ofs += 4
                continue
            if ofs + 12 > end:
                break
            totlen, hcrc = struct.unpack_from("<II", img, ofs + 4)
            if jcrc(img[ofs:ofs + 8]) != hcrc:
                bad.append(("hdr_crc", ofs))
                ofs += 4
                continue
            if totlen < 12 or ofs + totlen > end:
                bad.append(("totlen", ofs))
                ofs += 4
                continue
            n = {"ofs": ofs, "type": ntype, "totlen": totlen, "ok": True}
            if ntype == T_DIRENT and totlen >= DIRENT_HDR:
                (pino, version, ino, mctime, nsize, dtype, _u0, _u1,
                 node_crc, name_crc) = struct.unpack_from("<IIIIBBBBII", img, ofs + 12)
                name = bytes(img[ofs + DIRENT_HDR:ofs + DIRENT_HDR + nsize])
                n.update(pino=pino, version=version, ino=ino, name=name, dtype=dtype)
                if jcrc(img[ofs:ofs + 32]) != node_crc or jcrc(name) != name_crc:
                    n["ok"] = False
                    bad.append(("dirent_crc", ofs))
            elif ntype == T_INODE and totlen >= INODE_HDR:
                (ino, version, mode, uid, gid, isize, atime, mtime, ctime, offset,
                 csize, dsize, compr, usercompr, flags, data_crc,
                 node_crc) = struct.unpack_from("<IIIHHIIIIIIIBBHII", img, ofs + 12)
                data = bytes(img[ofs + INODE_HDR:ofs + INODE_HDR + csize])
                n.update(ino=ino, version=version, mode=mode, uid=uid, gid=gid,
                         isize=isize, atime=atime, mtime=mtime, ctime=ctime,
                         offset=offset, csize=csize, dsize=dsize, compr=compr,
                         data=data)
                if jcrc(img[ofs:ofs + 60]) != node_crc or jcrc(data) != data_crc:
                    n["ok"] = False
                    bad.append(("inode_crc", ofs))
            nodes.append(n)
            count += 1
            if ntype != T_CLEAN:
                real += 1
            ofs += pad4(totlen)
            used_end = ofs
        blocks.append({"start": b, "used_end": used_end, "nodes": count,
                       "real": real, "free_from": free_from})
    return nodes, blocks, bad


def build_fs(nodes):
    dirents = {}
    inodes = {}
    for n in nodes:
        if not n["ok"]:
            continue
        if n["type"] == T_DIRENT:
            key = (n["pino"], n["name"])
            if key not in dirents or n["version"] > dirents[key]["version"]:
                dirents[key] = n
        elif n["type"] == T_INODE:
            inodes.setdefault(n["ino"], []).append(n)
    children = {}
    for (pino, name), d in dirents.items():
        if d["ino"] != 0:
            children.setdefault(pino, {})[name] = d
    return children, inodes


def file_content(inode_nodes):
    inode_nodes = sorted(inode_nodes, key=lambda x: x["version"])
    buf = bytearray()
    for n in inode_nodes:
        chunk = decompress(n["compr"], n["data"], n["dsize"])
        end = n["offset"] + len(chunk)
        if len(buf) < end:
            buf.extend(bytes(end - len(buf)))
        buf[n["offset"]:end] = chunk
    size = inode_nodes[-1]["isize"]
    if len(buf) < size:
        buf.extend(bytes(size - len(buf)))
    return bytes(buf[:size])


def walk(children, inodes, ino=1, prefix=""):
    for name, d in sorted(children.get(ino, {}).items()):
        path = prefix + "/" + name.decode("utf-8", "replace")
        yield path, d
        if d["dtype"] == 4:
            yield from walk(children, inodes, d["ino"], path)


def lookup(children, path):
    ino = 1
    d = None
    for part in [p for p in path.split("/") if p]:
        d = children.get(ino, {}).get(part.encode())
        if d is None:
            raise FileNotFoundError(path)
        ino = d["ino"]
    return d


def cmd_slice(a):
    full, off, size, out = a[0], int(a[1], 0), int(a[2], 0), a[3]
    with open(full, "rb") as f:
        f.seek(off)
        data = f.read(size)
    with open(out, "wb") as f:
        f.write(data)
    print("wrote %s: %d bytes sha256=%s" % (out, len(data), hashlib.sha256(data).hexdigest()))


def cmd_info(a):
    img = open(a[0], "rb").read()
    nodes, blocks, bad = scan(img)
    kinds = {}
    for n in nodes:
        kinds[hex(n["type"])] = kinds.get(hex(n["type"]), 0) + 1
    print("size=%d bytes (%d blocks)  nodes by type: %s  crc problems: %d" % (
        len(img), len(img) // EB, kinds, len(bad)))
    comp = {}
    for n in nodes:
        if n["type"] == T_INODE:
            comp[n["compr"]] = comp.get(n["compr"], 0) + 1
    print("inode nodes by compr: %s" % comp)
    for blk in blocks:
        tail = (blk["start"] + EB) - blk["used_end"]
        print("block @0x%06x nodes=%3d used_end=+0x%05x tail_free=%6d erased_tail=%s" % (
            blk["start"], blk["nodes"], blk["used_end"] - blk["start"], tail,
            blk["free_from"] is not None))
    for b in bad[:10]:
        print("BAD", b)


def cmd_ls(a):
    img = open(a[0], "rb").read()
    nodes, _, _ = scan(img)
    children, inodes = build_fs(nodes)
    for path, d in walk(children, inodes):
        ino = d["ino"]
        ns = inodes.get(ino, [])
        if d["dtype"] == 4:
            print("d %-40s ino=%d" % (path + "/", ino))
        elif ns:
            top = max(ns, key=lambda x: x["version"])
            print("%s %-40s ino=%d size=%d mode=%o ver=%d nodes=%d" % (
                "l" if d["dtype"] == 10 else "-", path, ino, top["isize"],
                top["mode"], top["version"], len(ns)))
        else:
            print("? %-40s ino=%d (no inode nodes)" % (path, ino))


def cmd_cat(a):
    img = open(a[0], "rb").read()
    nodes, _, _ = scan(img)
    children, inodes = build_fs(nodes)
    d = lookup(children, a[1])
    sys.stdout.buffer.write(file_content(inodes[d["ino"]]))


def make_inode_node(ino, version, mode, uid, gid, isize, atime, mtime, ctime,
                    offset, data):
    csize = dsize = len(data)
    common = struct.pack("<HHI", MAGIC, T_INODE, INODE_HDR + csize)
    pre = common + struct.pack("<I", jcrc(common))
    pre += struct.pack("<IIIHHIIIIIIIBBH", ino, version, mode, uid, gid, isize,
                       atime, mtime, ctime, offset, csize, dsize, 0, 0, 0)
    assert len(pre) == 60
    node = pre + struct.pack("<II", jcrc(data), jcrc(pre)) + data
    return node + bytes(pad4(len(node)) - len(node))


def cmd_patch(a):
    img = bytearray(open(a[0], "rb").read())
    path, out = a[1], a[2]
    mode_flag, arg = a[3], a[4]
    nodes, blocks, bad = scan(bytes(img))
    if bad:
        sys.exit("refusing to patch: %d CRC problems in the source image" % len(bad))
    children, inodes = build_fs(nodes)
    d = lookup(children, path)
    ino = d["ino"]
    ns = inodes[ino]
    top = max(ns, key=lambda x: x["version"])
    old = file_content(ns)
    text = old.decode()
    if mode_flag == "--append-line":
        if arg in text.splitlines():
            sys.exit("line already present; nothing to do")
        new = text if text.endswith("\n") or not text else text + "\n"
        new = (new + arg + "\n").encode()
    elif mode_flag == "--uncomment":
        lines = text.splitlines(keepends=True)
        hits = [i for i, l in enumerate(lines) if l.startswith("#" + arg)]
        if len(hits) != 1:
            sys.exit("--uncomment needs exactly one match, found %d" % len(hits))
        lines[hits[0]] = lines[hits[0]][1:]
        new = "".join(lines).encode()
    else:
        sys.exit("unknown patch mode")
    if len(new) > 4096:
        sys.exit("new content over 4096 bytes: multi-node write not implemented")
    now = int(time.time())
    version = max(n["version"] for n in ns) + 1
    node = make_inode_node(ino, version, top["mode"], top["uid"], top["gid"],
                           len(new), top["atime"], now, now, 0, new)
    # Same choice the kernel makes for its next write: the partly-filled block
    # (real data nodes, not just a cleanmarker) with the most erased tail left.
    cand = [b for b in blocks
            if b["free_from"] is not None and (b["start"] + EB) - b["used_end"] >= len(node)
            and b["real"] > 0]
    if cand:
        blk = max(cand, key=lambda b: (b["start"] + EB) - b["used_end"])
        at = blk["used_end"]
    else:
        cand = [b for b in blocks if b["free_from"] is not None
                and (b["start"] + EB) - b["used_end"] >= len(node)]
        if not cand:
            sys.exit("no block has %d bytes of erased tail" % len(node))
        blk = cand[0]
        at = blk["used_end"]
    assert img.count(b"\xff", at, at + len(node)) == len(node), "target not erased"
    img[at:at + len(node)] = node
    open(out, "wb").write(bytes(img))
    print("patched %s: ino=%d  version %d -> %d  size %d -> %d" % (
        path, ino, top["version"], version, len(old), len(new)))
    print("new node at image offset 0x%06x (%d bytes, block @0x%06x)" % (at, len(node), blk["start"]))
    print("sha256(out)=%s" % hashlib.sha256(bytes(img)).hexdigest())


def cmd_diff(a):
    import difflib
    texts = []
    for img_path in a[:2]:
        nodes, _, bad = scan(open(img_path, "rb").read())
        children, inodes = build_fs(nodes)
        d = lookup(children, a[2])
        texts.append(file_content(inodes[d["ino"]]).decode().splitlines())
        print("%s: %d crc problems, %d lines" % (img_path, len(bad), len(texts[-1])))
    diff = list(difflib.unified_diff(texts[0], texts[1], "A", "B", lineterm="", n=1))
    print("\n".join(diff) if diff else "(identical)")


def main():
    cmds = {"slice": cmd_slice, "info": cmd_info, "ls": cmd_ls, "cat": cmd_cat,
            "patch": cmd_patch, "diff": cmd_diff}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])


main()
