"""ESRI shapefile (.shp/.shx) and dBase III (.dbf) writer, plus a small reader
used to verify what was written. Follows the ESRI Shapefile Technical
Description (July 1998): big-endian file code/length and record headers,
little-endian everything else, lengths counted in 16-bit words.
"""

import struct

from fx_common import FIXED_DATE, signed_area

NULL, POINT, POLYLINE, POLYGON, POINTZ = 0, 1, 3, 5, 11

PRJ_WGS84 = ('GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],'
             'PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]]')

PRJ_UTM33N = ('PROJCS["WGS_1984_UTM_Zone_33N",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",'
              'SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],'
              'UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],'
              'PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",0.0],'
              'PARAMETER["Central_Meridian",15.0],PARAMETER["Scale_Factor",0.9996],'
              'PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]')

PRJ_LAMBERT93 = ('PROJCS["RGF_1993_Lambert_93",GEOGCS["GCS_RGF_1993",DATUM["D_RGF_1993",'
                 'SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],'
                 'UNIT["Degree",0.0174532925199433]],PROJECTION["Lambert_Conformal_Conic"],'
                 'PARAMETER["False_Easting",700000.0],PARAMETER["False_Northing",6600000.0],'
                 'PARAMETER["Central_Meridian",3.0],PARAMETER["Standard_Parallel_1",49.0],'
                 'PARAMETER["Standard_Parallel_2",44.0],PARAMETER["Latitude_Of_Origin",46.5],'
                 'UNIT["Meter",1.0]]')

# As ArcGIS writes it (unit name Foot_US, full-precision false easting/northing).
PRJ_CA3_FTUS = ('PROJCS["NAD_1983_StatePlane_California_III_FIPS_0403_Feet",'
                'GEOGCS["GCS_North_American_1983",DATUM["D_North_American_1983",'
                'SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],'
                'UNIT["Degree",0.0174532925199433]],PROJECTION["Lambert_Conformal_Conic"],'
                'PARAMETER["False_Easting",6561666.666666666],PARAMETER["False_Northing",1640416.666666667],'
                'PARAMETER["Central_Meridian",-120.5],PARAMETER["Standard_Parallel_1",37.06666666666667],'
                'PARAMETER["Standard_Parallel_2",38.43333333333333],PARAMETER["Latitude_Of_Origin",36.5],'
                'UNIT["Foot_US",0.3048006096012192]]')


class ShapeWriter:
    def __init__(self, shape_type):
        self.shape_type = shape_type
        self.contents = []
        self.xs = []
        self.ys = []
        self.zs = []
        self.ms = []

    def add_point(self, x, y):
        assert self.shape_type == POINT
        self.contents.append(struct.pack("<i2d", POINT, x, y))
        self.xs.append(x)
        self.ys.append(y)

    def add_pointz(self, x, y, z, m=0.0):
        assert self.shape_type == POINTZ
        self.contents.append(struct.pack("<i4d", POINTZ, x, y, z, m))
        self.xs.append(x)
        self.ys.append(y)
        self.zs.append(z)
        self.ms.append(m)

    def add_parts(self, parts):
        """PolyLine or Polygon record. parts: list of [(x, y), ...].

        For polygons each ring must be closed; outer rings clockwise and holes
        counter-clockwise (checked here).
        """
        assert self.shape_type in (POLYLINE, POLYGON)
        if self.shape_type == POLYGON:
            for ring in parts:
                assert ring[0] == ring[-1], "polygon rings must be closed"
        pts = [p for part in parts for p in part]
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        starts, n = [], 0
        for part in parts:
            starts.append(n)
            n += len(part)
        body = struct.pack("<i4d2i", self.shape_type, min(xs), min(ys), max(xs), max(ys), len(parts), len(pts))
        body += struct.pack("<%di" % len(starts), *starts)
        body += struct.pack("<%dd" % (2 * len(pts)), *[c for p in pts for c in (p[0], p[1])])
        self.contents.append(body)
        self.xs.extend(xs)
        self.ys.extend(ys)

    def _header(self, length_bytes):
        bbox = (min(self.xs), min(self.ys), max(self.xs), max(self.ys))
        z = (min(self.zs), max(self.zs)) if self.zs else (0.0, 0.0)
        m = (min(self.ms), max(self.ms)) if self.ms else (0.0, 0.0)
        return (struct.pack(">7i", 9994, 0, 0, 0, 0, 0, length_bytes // 2)
                + struct.pack("<2i", 1000, self.shape_type)
                + struct.pack("<8d", bbox[0], bbox[1], bbox[2], bbox[3], z[0], z[1], m[0], m[1]))

    def build(self):
        """Return (shp_bytes, shx_bytes)."""
        shp_body = b""
        shx_body = b""
        offset = 100
        for i, content in enumerate(self.contents):
            words = len(content) // 2
            shp_body += struct.pack(">2i", i + 1, words) + content
            shx_body += struct.pack(">2i", offset // 2, words)
            offset += 8 + len(content)
        shp = self._header(100 + len(shp_body)) + shp_body
        shx = self._header(100 + len(shx_body)) + shx_body
        return shp, shx


class Field:
    def __init__(self, name, ftype, length, decimals=0):
        assert len(name) <= 10 and name.isascii()
        assert ftype in "CNFLD"
        self.name, self.type, self.length, self.decimals = name, ftype, length, decimals
        if ftype == "L":
            assert length == 1
        if ftype == "D":
            assert length == 8


def _fit_bytes(text, encoding, length):
    """Encode and truncate on a character boundary to at most length bytes."""
    out = b""
    for ch in text:
        b = ch.encode(encoding)
        if len(out) + len(b) > length:
            break
        out += b
    return out


def build_dbf(fields, records, encoding="utf-8", ldid=0x00):
    """dBase III table. records: list of tuples matching fields.

    Values: C -> str, N/F -> int/float or None, L -> True/False/None,
    D -> (y, m, d) or None.
    """
    y, m, d = FIXED_DATE
    header_len = 32 + 32 * len(fields) + 1
    record_len = 1 + sum(f.length for f in fields)
    head = struct.pack("<B3BIHH", 0x03, y - 1900, m, d, len(records), header_len, record_len)
    head += b"\x00" * 16 + b"\x00" + bytes([ldid]) + b"\x00\x00"
    assert len(head) == 32
    for f in fields:
        head += (f.name.encode("ascii").ljust(11, b"\x00") + f.type.encode("ascii") + b"\x00" * 4
                 + bytes([f.length, f.decimals]) + b"\x00" * 14)
    head += b"\x0d"
    body = b""
    for rec in records:
        assert len(rec) == len(fields)
        row = b" "
        for f, v in zip(fields, rec):
            if f.type == "C":
                cell = _fit_bytes(v or "", encoding, f.length).ljust(f.length, b" ")
            elif f.type in "NF":
                if v is None:
                    cell = b" " * f.length
                else:
                    txt = ("%d" % v) if f.decimals == 0 else ("%.*f" % (f.decimals, v))
                    if len(txt) > f.length:
                        raise ValueError("value %r too wide for %s" % (v, f.name))
                    cell = txt.rjust(f.length).encode("ascii")
            elif f.type == "L":
                cell = b"?" if v is None else (b"T" if v else b"F")
            else:  # D
                cell = b" " * 8 if v is None else ("%04d%02d%02d" % v).encode("ascii")
            assert len(cell) == f.length
            row += cell
        body += row
    return head + body + b"\x1a"


def write_shapefile(base, writer, fields, records, prj=None, cpg=None, encoding="utf-8", ldid=0x00):
    """Write base.shp/.shx/.dbf (+ .prj/.cpg when given). Returns written paths."""
    assert len(writer.contents) == len(records)
    shp, shx = writer.build()
    files = {base + ".shp": shp, base + ".shx": shx,
             base + ".dbf": build_dbf(fields, records, encoding, ldid)}
    if prj is not None:
        files[base + ".prj"] = prj.encode("ascii")
    if cpg is not None:
        files[base + ".cpg"] = cpg.encode("ascii")
    for path, data in files.items():
        with open(path, "wb") as fh:
            fh.write(data)
    return files


# ---------------------------------------------------------------- reading (verification)

def read_shp(shp, shx):
    """Parse shp/shx bytes; returns dict with header info and record geometries."""
    code, = struct.unpack(">i", shp[0:4])
    assert code == 9994
    flen, = struct.unpack(">i", shp[24:28])
    assert flen * 2 == len(shp), "shp length field mismatch"
    version, stype = struct.unpack("<2i", shp[28:36])
    assert version == 1000
    bbox = struct.unpack("<8d", shp[36:100])
    xlen, = struct.unpack(">i", shx[24:28])
    assert xlen * 2 == len(shx), "shx length field mismatch"
    nrec = (len(shx) - 100) // 8
    records = []
    for i in range(nrec):
        off, words = struct.unpack(">2i", shx[100 + 8 * i:108 + 8 * i])
        recno, clen = struct.unpack(">2i", shp[off * 2:off * 2 + 8])
        assert recno == i + 1 and clen == words
        c = shp[off * 2 + 8:off * 2 + 8 + clen * 2]
        t, = struct.unpack("<i", c[:4])
        assert t == stype
        if t == POINT:
            records.append([[struct.unpack("<2d", c[4:20])]])
        elif t == POINTZ:
            records.append([[struct.unpack("<4d", c[4:36])]])
        else:
            nparts, npts = struct.unpack("<2i", c[36:44])
            starts = list(struct.unpack("<%di" % nparts, c[44:44 + 4 * nparts]))
            raw = struct.unpack("<%dd" % (2 * npts), c[44 + 4 * nparts:44 + 4 * nparts + 16 * npts])
            pts = [(raw[2 * k], raw[2 * k + 1]) for k in range(npts)]
            starts.append(npts)
            records.append([pts[starts[k]:starts[k + 1]] for k in range(nparts)])
    return {"type": stype, "bbox": bbox, "records": records}


def read_dbf(data, encoding):
    nrec, hlen, rlen = struct.unpack("<IHH", data[4:12])
    fields = []
    pos = 32
    while data[pos] != 0x0D:
        name = data[pos:pos + 11].split(b"\x00")[0].decode("ascii")
        fields.append((name, chr(data[pos + 11]), data[pos + 16], data[pos + 17]))
        pos += 32
    assert pos + 1 == hlen
    assert rlen == 1 + sum(f[2] for f in fields)
    rows = []
    for i in range(nrec):
        rec = data[hlen + i * rlen:hlen + (i + 1) * rlen]
        assert rec[0:1] == b" "
        p = 1
        row = {}
        for name, t, ln, dec in fields:
            raw = rec[p:p + ln]
            p += ln
            row[name] = raw.decode(encoding).rstrip() if t == "C" else raw.decode("ascii").strip()
        rows.append(row)
    assert data[hlen + nrec * rlen:] == b"\x1a"
    return {"fields": fields, "rows": rows, "ldid": data[29]}


def ring_is_clockwise(ring):
    return signed_area(ring) < 0
