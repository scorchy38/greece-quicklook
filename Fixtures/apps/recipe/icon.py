# Writes a 120x120 RGBA PNG: a blue-to-teal gradient with a white disc, using only zlib.
import sys, zlib, struct, math
w = h = 120
rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        t = y / (h - 1)
        r, g, b = int(20 + 10 * t), int(110 + 90 * t), int(235 - 40 * t)
        d = math.hypot(x - 60, y - 60)
        if d < 30:
            r, g, b = 255, 255, 255
        elif d < 31:
            k = 31 - d
            r, g, b = int(r + (255 - r) * k), int(g + (255 - g) * k), int(b + (255 - b) * k)
        row += bytes([r, g, b, 255])
    rows.append(bytes(row))
raw = b''.join(rows)


def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)


png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
