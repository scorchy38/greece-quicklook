"""Minimal Mapbox Vector Tile 2.1 encoder (protobuf written by hand).

Spec: https://github.com/mapbox/vector-tile-spec/tree/master/2.1
"""

import struct

from fx_common import clip_line, clip_ring, signed_area, simplify_dp

POINT, LINESTRING, POLYGON = 1, 2, 3
CMD_MOVE_TO, CMD_LINE_TO, CMD_CLOSE_PATH = 1, 2, 7

# Value types (field numbers of vector_tile.Tile.Value)
V_STRING, V_FLOAT, V_DOUBLE, V_INT, V_UINT, V_SINT, V_BOOL = 1, 2, 3, 4, 5, 6, 7


# ---------------------------------------------------------------- protobuf primitives

def varint(n):
    assert n >= 0
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def zigzag32(n):
    return ((n << 1) ^ (n >> 31)) & 0xFFFFFFFF


def zigzag64(n):
    return ((n << 1) ^ (n >> 63)) & 0xFFFFFFFFFFFFFFFF


def key(field, wire):
    return varint((field << 3) | wire)


def len_field(field, payload):
    return key(field, 2) + varint(len(payload)) + payload


def packed(field, values):
    return len_field(field, b"".join(varint(v) for v in values))


def command(cmd_id, count):
    return (cmd_id & 0x7) | (count << 3)


# ---------------------------------------------------------------- values and geometry

def encode_value(vtype, v):
    if vtype == V_STRING:
        return len_field(1, v.encode("utf-8"))
    if vtype == V_FLOAT:
        return key(2, 5) + struct.pack("<f", v)
    if vtype == V_DOUBLE:
        return key(3, 1) + struct.pack("<d", v)
    if vtype == V_INT:
        return key(4, 0) + varint(v & 0xFFFFFFFFFFFFFFFF)
    if vtype == V_UINT:
        return key(5, 0) + varint(v)
    if vtype == V_SINT:
        return key(6, 0) + varint(zigzag64(v))
    if vtype == V_BOOL:
        return key(7, 0) + varint(1 if v else 0)
    raise ValueError(vtype)


def encode_geometry(gtype, parts):
    """parts: points -> [[(x, y)]...] (one point per part); lines -> list of
    point lists; polygons -> list of rings without the closing vertex, each
    exterior followed by its interiors. Coordinates are integers."""
    out = []
    cx = cy = 0
    if gtype == POINT:
        pts = [p[0] for p in parts]
        out.append(command(CMD_MOVE_TO, len(pts)))
        for x, y in pts:
            out += [zigzag32(x - cx), zigzag32(y - cy)]
            cx, cy = x, y
        return out
    for part in parts:
        x, y = part[0]
        out += [command(CMD_MOVE_TO, 1), zigzag32(x - cx), zigzag32(y - cy)]
        cx, cy = x, y
        rest = part[1:]
        out.append(command(CMD_LINE_TO, len(rest)))
        for x, y in rest:
            out += [zigzag32(x - cx), zigzag32(y - cy)]
            cx, cy = x, y
        if gtype == POLYGON:
            out.append(command(CMD_CLOSE_PATH, 1))
    return out


class LayerBuilder:
    def __init__(self, name, extent=4096):
        self.name = name
        self.extent = extent
        self.keys = []
        self.key_index = {}
        self.values = []
        self.value_index = {}
        self.features = []
        self.encoded = []  # (geometry type, parts) per feature, kept for verification

    def _key(self, k):
        if k not in self.key_index:
            self.key_index[k] = len(self.keys)
            self.keys.append(k)
        return self.key_index[k]

    def _value(self, vtype, v):
        idx_key = (vtype, v)
        if idx_key not in self.value_index:
            self.value_index[idx_key] = len(self.values)
            self.values.append(encode_value(vtype, v))
        return self.value_index[idx_key]

    def add(self, gtype, parts, props, fid=None):
        """props: list of (key, value_type, value); None values are skipped."""
        tags = []
        for k, vtype, v in props:
            if v is None:
                continue
            tags += [self._key(k), self._value(vtype, v)]
        body = b""
        if fid is not None:
            body += key(1, 0) + varint(fid)
        if tags:
            body += packed(2, tags)
        body += key(3, 0) + varint(gtype)
        body += packed(4, encode_geometry(gtype, parts))
        self.features.append(body)
        self.encoded.append((gtype, parts))

    def encode(self):
        out = key(15, 0) + varint(2)  # version
        out += len_field(1, self.name.encode("utf-8"))
        for f in self.features:
            out += len_field(2, f)
        for k in self.keys:
            out += len_field(3, k.encode("utf-8"))
        for v in self.values:
            out += len_field(4, v)
        out += key(5, 0) + varint(self.extent)
        return out


def encode_tile(layers):
    return b"".join(len_field(3, layer.encode()) for layer in layers if layer.features)


# ---------------------------------------------------------------- tile preparation

def _to_tile(points, z, x, y, extent):
    n = 2 ** z
    return [((ux * n - x) * extent, (uy * n - y) * extent) for ux, uy in points]


def _round_dedupe(points):
    out = []
    for px, py in points:
        p = (int(round(px)), int(round(py)))
        if not out or out[-1] != p:
            out.append(p)
    return out


def polygon_parts(rings_unit, z, x, y, extent=4096, buffer=64, tol=1.0):
    """Clip one polygon (unit coords, first ring exterior) to a tile.

    Returns rings without closing vertex: exterior with positive shoelace area
    in tile coordinates (y down, i.e. clockwise on screen), holes negative.
    Returns [] when the exterior disappears.
    """
    lo, hi = -buffer, extent + buffer
    out = []
    for i, ring in enumerate(rings_unit):
        pts = _to_tile(ring, z, x, y, extent)
        if pts[0] == pts[-1]:
            pts = pts[:-1]
        pts = simplify_dp(pts + [pts[0]], tol)[:-1] if tol > 0 else pts
        if len(pts) < 3:
            if i == 0:
                return []
            continue
        pts = clip_ring(pts, lo, lo, hi, hi)
        pts = _round_dedupe(pts)
        while len(pts) > 1 and pts[0] == pts[-1]:
            pts.pop()
        if len(pts) < 3:
            if i == 0:
                return []
            continue
        a = signed_area(pts)
        if abs(a) < 1.0:
            if i == 0:
                return []
            continue
        want_positive = i == 0
        if (a > 0) != want_positive:
            pts.reverse()
        assert (signed_area(pts) > 0) == want_positive
        out.append(pts)
    return out


def line_parts(points_unit, z, x, y, extent=4096, buffer=64, tol=1.0):
    lo, hi = -buffer, extent + buffer
    pts = _to_tile(points_unit, z, x, y, extent)
    pts = simplify_dp(pts, tol) if tol > 0 else pts
    parts = []
    for part in clip_line(pts, lo, lo, hi, hi):
        p = _round_dedupe(part)
        if len(p) >= 2:
            parts.append(p)
    return parts


def point_in_tile(point_unit, z, x, y, extent=4096):
    (px, py), = _to_tile([point_unit], z, x, y, extent)
    ix, iy = int(round(px)), int(round(py))
    if 0 <= ix < extent and 0 <= iy < extent:
        return (ix, iy)
    return None
