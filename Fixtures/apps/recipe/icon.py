# Writes a square RGBA PNG (120 px unless a size is given): a blue-to-teal gradient with a white
# disc, using only zlib.  Usage: icon.py <out.png> [size]
import sys, zlib, struct, math
w = h = int(sys.argv[2]) if len(sys.argv) > 2 else 120
radius = w / 4
rows = []
for y in range(h):
    row = bytearray([0])
    t = y / (h - 1)
    base = (int(20 + 10 * t), int(110 + 90 * t), int(235 - 40 * t))
    for x in range(w):
        r, g, b = base
        d = math.hypot(x - w / 2, y - h / 2)
        if d < radius:
            r, g, b = 255, 255, 255
        elif d < radius + 1:
            k = radius + 1 - d
            r, g, b = int(r + (255 - r) * k), int(g + (255 - g) * k), int(b + (255 - b) * k)
        row += bytes([r, g, b, 255])
    rows.append(bytes(row))
raw = b''.join(rows)


def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)


png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
