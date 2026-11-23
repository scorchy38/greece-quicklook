import struct, sys, zlib

def png(path, size, background, foreground):
    rows = []
    inset = size // 4
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            inside = inset <= x < size - inset and inset <= y < size - inset
            row += bytes(foreground if inside else background)
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

out = sys.argv[1]
png(out + "/mipmap-mdpi/ic_launcher.png", 48, (0x34, 0xA8, 0x53), (0xFF, 0xFF, 0xFF))
png(out + "/mipmap-xxxhdpi/ic_launcher.png", 192, (0x34, 0xA8, 0x53), (0xFF, 0xFF, 0xFF))
