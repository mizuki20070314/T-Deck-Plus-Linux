"""Make a test pattern for the 466x466 AMOLED framebuffer.

usage: py make_fb_test.py OUTDIR [SIZE]

Writes OUTDIR/fbtest-SIZE.rgb565 (little-endian 16-bit pixels, the layout of
/dev/fb0 on the board: `cat fbtest.rgb565 > /dev/fb0`) and a PNG preview of
exactly the same pixels. Standard library only.
"""
import math
import os
import struct
import sys
import zlib

out = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 466
os.makedirs(out, exist_ok=True)

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
GRAY = (128, 128, 128)
RED, GREEN, BLUE = (255, 0, 0), (0, 255, 0), (0, 0, 255)
CYAN, MAGENTA, YELLOW = (0, 255, 255), (255, 0, 255), (255, 255, 0)

px = [[BLACK] * n for _ in range(n)]


def put(x, y, c):
    if 0 <= x < n and 0 <= y < n:
        px[y][x] = c


def rect(x0, y0, x1, y1, c):
    for y in range(max(0, y0), min(n, y1 + 1)):
        for x in range(max(0, x0), min(n, x1 + 1)):
            px[y][x] = c


def circle(r, c):
    cx = cy = (n - 1) / 2
    for y in range(n):
        for x in range(n):
            if abs(math.hypot(x - cx, y - cy) - r) < 0.75:
                px[y][x] = c


# crosshair and circles first, so the solid shapes stay on top
mid = n // 2
rect(0, mid, n - 1, mid, (64, 64, 64))
rect(mid, 0, mid, n - 1, (64, 64, 64))
for r, c in ((n // 2 - 1, WHITE), (200, GRAY), (164, YELLOW), (100, GRAY), (50, GRAY)):
    circle(r, c)

# frame at the very edge of the frame memory
rect(0, 0, n - 1, 0, WHITE)
rect(0, n - 1, n - 1, n - 1, WHITE)
rect(0, 0, 0, n - 1, WHITE)
rect(n - 1, 0, n - 1, n - 1, WHITE)

# corner markers: which corners are really visible on a round panel?
m = 24
rect(1, 1, m, m, RED)
rect(n - 1 - m, 1, n - 2, m, GREEN)
rect(1, n - 1 - m, m, n - 2, BLUE)
rect(n - 1 - m, n - 1 - m, n - 2, n - 2, YELLOW)

# color bars
bars = [RED, GREEN, BLUE, WHITE, CYAN, MAGENTA, YELLOW, GRAY]
x0, x1 = 80, n - 81
w = (x1 - x0 + 1) // len(bars)
for i, c in enumerate(bars):
    rect(x0 + i * w, mid - 45, x0 + (i + 1) * w - 1, mid + 45, c)

# gray ramp below, and a small "L" so a mirrored or rotated image shows
for x in range(x0, x1 + 1):
    v = (x - x0) * 255 // (x1 - x0)
    rect(x, mid + 60, x, mid + 90, (v, v, v))
rect(x0, mid - 130, x0 + 6, mid - 70, WHITE)
rect(x0, mid - 76, x0 + 40, mid - 70, WHITE)


def q565(c):
    r, g, b = c
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


raw = bytearray()
for y in range(n):
    raw += struct.pack("<%dH" % n, *(q565(c) for c in px[y]))
open(os.path.join(out, "fbtest-%d.rgb565" % n), "wb").write(raw)

rows = bytearray()
for y in range(n):
    rows.append(0)
    for x in range(n):
        rows += bytes(from565(q565(px[y][x])))


def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
open(os.path.join(out, "fbtest-%d.png" % n), "wb").write(png)
print("wrote %s (%d bytes) and the PNG preview" % (os.path.join(out, "fbtest-%d.rgb565" % n), len(raw)))
