"""Convert a dump of the board's /dev/fb0 (RGB565, little endian) to a PNG.

    py -I fb_snapshot.py <fb.raw> <out.png> [--size WxH] [--scale N] [--at X0,Y0]

--size   framebuffer size (default: 466x466, or 328x320 if the dump has that many bytes)
--scale  repeat every pixel N times so small text stays readable
--at     panel position of the first pixel, e.g. 68,72. The picture is then placed on a
         466x466 panel and everything outside the round glass is painted dark blue-gray,
         which shows what is really visible.

The dump is the framebuffer in RAM, i.e. what fbcon drew, which the driver sends to the AMOLED.
"""
import argparse
import struct
import sys
import zlib

PANEL = 466
KNOWN = {466 * 466 * 2: (466, 466), 328 * 320 * 2: (328, 320)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--size")
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--at")
    a = ap.parse_args()

    data = open(a.src, "rb").read()
    if a.size:
        w, h = (int(v) for v in a.size.lower().split("x"))
    else:
        w, h = KNOWN.get(len(data), (0, 0))
    if not w or len(data) != w * h * 2:
        print(f"unexpected dump size {len(data)} for {w}x{h}", file=sys.stderr)
        return 1

    # pixels as RGB888 rows
    pix = []
    for y in range(h):
        row = []
        for (v,) in struct.iter_unpack("<H", data[y * w * 2:(y + 1) * w * 2]):
            r = (v >> 11) & 31
            g = (v >> 5) & 63
            b = v & 31
            row.append(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))
        pix.append(row)

    if a.at:
        x0, y0 = (int(v) for v in a.at.split(","))
        canvas = [[(0, 0, 0)] * PANEL for _ in range(PANEL)]
        for y in range(h):
            if 0 <= y0 + y < PANEL:
                for x in range(w):
                    if 0 <= x0 + x < PANEL:
                        canvas[y0 + y][x0 + x] = pix[y][x]
        c = (PANEL - 1) / 2
        for y in range(PANEL):
            for x in range(PANEL):
                if (x - c) ** 2 + (y - c) ** 2 > (PANEL / 2) ** 2:
                    canvas[y][x] = (28, 28, 44)
        pix, w, h = canvas, PANEL, PANEL

    s = a.scale
    rows = []
    for y in range(h):
        line = bytearray()
        for px in pix[y]:
            line += bytes(px) * s
        rows.extend([b"\x00" + bytes(line)] * s)

    def chunk(tag: bytes, body: bytes) -> bytes:
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w * s, h * s, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
    png += chunk(b"IEND", b"")
    open(a.dst, "wb").write(png)
    print(f"{a.dst}: {w * s}x{h * s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
