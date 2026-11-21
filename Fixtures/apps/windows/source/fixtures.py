#!/usr/bin/env python3
"""Builds pieces of the Windows fixtures (see build.sh).

  fixtures.py icon <out.ico>                       a 16x16 BMP + 32x32 PNG icon
  fixtures.py digest <in.exe> <padded.exe> <spc.der>  pads to 8 bytes, writes SpcIndirectDataContent with the SHA-256 Authenticode digest
  fixtures.py attach <padded.exe> <cms.der> <out.exe> unwraps OpenSSL's eContent the way Authenticode stores it and appends it
"""
import hashlib, struct, sys, zlib


def png(width, height, pixels):
    raw = b"".join(b"\0" + bytes(pixels[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def disc(size):
    """A blue disc on transparent: RGBA, top-down."""
    out = []
    centre = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            inside = (x - centre) ** 2 + (y - centre) ** 2 <= (size / 2 - 0.5) ** 2
            out += [0x0A, 0x84, 0xFF, 0xFF] if inside else [0, 0, 0, 0]
    return out


def icon(path):
    small = disc(16)
    # BMP entry: BITMAPINFOHEADER with doubled height, BGRA rows bottom-up, then a 1-bit AND mask.
    header = struct.pack("<IiiHHIIiiII", 40, 16, 32, 1, 32, 0, 16 * 16 * 4 + 64, 0, 0, 0, 0)
    rows = b""
    for y in reversed(range(16)):
        for x in range(16):
            r, g, b, a = small[(y * 16 + x) * 4:(y * 16 + x) * 4 + 4]
            rows += bytes([b, g, r, a])
    bmp = header + rows + b"\0" * 64
    large = png(32, 32, disc(32))
    images = [(16, bmp), (32, large)]
    data = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    for size, blob in images:
        data += struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for _, blob in images:
        data += blob
    open(path, "wb").write(data)


def der_length(n):
    if n < 0x80:
        return bytes([n])
    body = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(body)]) + body


def tlv(tag, body):
    return bytes([tag]) + der_length(len(body)) + body


def parse(data, offset=0):
    tag = data[offset]
    first = data[offset + 1]
    cursor = offset + 2
    if first < 0x80:
        length = first
    else:
        count = first & 0x7F
        length = int.from_bytes(data[cursor:cursor + count], "big")
        cursor += count
    body = data[cursor:cursor + length]
    node = {"tag": tag, "body": body, "children": None}
    if tag & 0x20:
        node["children"] = []
        inner = 0
        while inner < len(body):
            child, size = parse(body, inner)
            node["children"].append(child)
            inner += size
    return node, cursor + length - offset


def serialize(node):
    if node["children"] is None:
        return tlv(node["tag"], node["body"])
    return tlv(node["tag"], b"".join(serialize(child) for child in node["children"]))


def pe_layout(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)
    return optional + 64, directories + 4 * 8


def digest(source, padded_path, spc_path):
    data = open(source, "rb").read()
    data += b"\0" * ((8 - len(data) % 8) % 8)
    open(padded_path, "wb").write(data)
    checksum, entry = pe_layout(data)
    sha = hashlib.sha256()
    sha.update(data[:checksum])
    sha.update(data[checksum + 4:entry])
    sha.update(data[entry + 8:])
    sha256_oid = tlv(0x06, bytes([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]))
    pe_image_oid = tlv(0x06, bytes([0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x0F]))
    spc = tlv(0x30, tlv(0x30, pe_image_oid) + tlv(0x30, tlv(0x30, sha256_oid + b"\x05\x00") + tlv(0x04, sha.digest())))
    open(spc_path, "wb").write(spc)


def attach(padded_path, cms_path, out_path):
    data = bytearray(open(padded_path, "rb").read())
    root, _ = parse(open(cms_path, "rb").read())
    signed = root["children"][1]["children"][0]
    encapsulated = signed["children"][2]
    explicit = encapsulated["children"][1]
    octets = explicit["children"][0]
    assert octets["tag"] == 0x04
    content, _ = parse(octets["body"])
    explicit["children"] = [content]
    blob = serialize(root)
    length = 8 + len(blob)
    padding = (8 - length % 8) % 8
    certificate = struct.pack("<IHH", length + padding, 0x0200, 0x0002) + blob + b"\0" * padding
    _, entry = pe_layout(data)
    struct.pack_into("<II", data, entry, len(data), len(certificate))
    data += certificate
    open(out_path, "wb").write(bytes(data))


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "icon":
        icon(sys.argv[2])
    elif command == "digest":
        digest(sys.argv[2], sys.argv[3], sys.argv[4])
    elif command == "attach":
        attach(sys.argv[2], sys.argv[3], sys.argv[4])
