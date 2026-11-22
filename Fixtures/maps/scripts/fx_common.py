"""Shared helpers for the map fixture generators.

Everything here is pure Python (no third-party imports) so it can be reused by
make_large.py without a virtual environment.
"""

import json
import math
import os
import zipfile

# Fixed timestamp used for every archive member, dbf header and database row so
# that regenerating the fixtures produces byte-identical files.
FIXED_DATE = (2025, 1, 1)
FIXED_ZIP_TIME = (2025, 1, 1, 0, 0, 0)
FIXED_ISO = "2025-01-01T00:00:00Z"

MAX_MERC_LAT = 85.0511287798066
EARTH_RADIUS = 6378137.0


# ---------------------------------------------------------------- JSON output

def dumps(obj):
    """Compact JSON with real UTF-8 characters (no \\u escapes)."""
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def write_bytes(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def write_feature_collection(path, features, extra_members=None):
    """Write a FeatureCollection with "type" first and one feature per line."""
    head = '{"type":"FeatureCollection"'
    if extra_members:
        for key, value in extra_members:
            head += "," + dumps(key) + ":" + dumps(value)
    lines = [head + ',"features":[']
    for i, feat in enumerate(features):
        lines.append(dumps(feat) + ("," if i < len(features) - 1 else ""))
    lines.append("]}")
    write_text(path, "\n".join(lines) + "\n")


def load_geojson(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------- rounding

def rnd(value, ndigits):
    r = round(value, ndigits)
    return 0.0 if r == 0 else r  # avoid "-0.0"


def round_line(coords, ndigits):
    out = []
    for c in coords:
        p = [rnd(c[0], ndigits), rnd(c[1], ndigits)]
        if not out or out[-1] != p:
            out.append(p)
    return out


def round_ring(ring, ndigits):
    out = round_line(ring, ndigits)
    if out and out[0] != out[-1]:
        out.append(list(out[0]))
    return out if len(out) >= 4 else None


def round_geometry(geom, ndigits):
    """Round a GeoJSON geometry, dropping duplicate vertices and collapsed rings."""
    t = geom["type"]
    c = geom["coordinates"]
    if t == "Point":
        return {"type": t, "coordinates": [rnd(c[0], ndigits), rnd(c[1], ndigits)]}
    if t == "MultiPoint":
        return {"type": t, "coordinates": [[rnd(p[0], ndigits), rnd(p[1], ndigits)] for p in c]}
    if t == "LineString":
        return {"type": t, "coordinates": round_line(c, ndigits)}
    if t == "MultiLineString":
        return {"type": t, "coordinates": [round_line(l, ndigits) for l in c]}
    if t == "Polygon":
        return {"type": t, "coordinates": _round_polygon(c, ndigits)}
    if t == "MultiPolygon":
        polys = [_round_polygon(p, ndigits) for p in c]
        return {"type": t, "coordinates": [p for p in polys if p]}
    raise ValueError(t)


def _round_polygon(rings, ndigits):
    out = []
    for i, ring in enumerate(rings):
        r = round_ring(ring, ndigits)
        if r is None:
            if i == 0:
                return []
            continue
        out.append(r)
    return out


# ---------------------------------------------------------------- planar geometry

def signed_area(ring):
    """Shoelace area; positive when counter-clockwise with y pointing up.

    Works with or without a repeated closing vertex.
    """
    a = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[(i + 1) % n][0], ring[(i + 1) % n][1]
        a += x1 * y2 - x2 * y1
    return a / 2.0


def orient(ring, ccw):
    """Return the ring wound counter-clockwise (ccw=True) or clockwise (y up)."""
    a = signed_area(ring)
    if (a > 0) != ccw:
        return list(reversed(ring))
    return list(ring)


def close_ring(ring):
    ring = [tuple(p) for p in ring]
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    return ring


def bbox_of(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def simplify_dp(points, tol):
    """Douglas-Peucker simplification (iterative). Keeps first and last point."""
    n = len(points)
    if n < 3 or tol <= 0:
        return list(points)
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    tol2 = tol * tol
    while stack:
        a, b = stack.pop()
        ax, ay = points[a][0], points[a][1]
        bx, by = points[b][0], points[b][1]
        dx, dy = bx - ax, by - ay
        seg2 = dx * dx + dy * dy
        best, best_i = -1.0, -1
        for i in range(a + 1, b):
            px, py = points[i][0], points[i][1]
            if seg2 == 0:
                d2 = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / seg2
                t = max(0.0, min(1.0, t))
                qx, qy = ax + t * dx, ay + t * dy
                d2 = (px - qx) ** 2 + (py - qy) ** 2
            if d2 > best:
                best, best_i = d2, i
        if best > tol2:
            keep[best_i] = True
            stack.append((a, best_i))
            stack.append((best_i, b))
    return [p for p, k in zip(points, keep) if k]


def clip_ring(ring, xmin, ymin, xmax, ymax):
    """Sutherland-Hodgman clip of a ring (no closing vertex) to a rectangle.

    Orientation is preserved. Concave rings may gain zero-width edges along the
    clip border, which is acceptable for tiles drawn with a buffer.
    """

    def clip(points, inside, intersect):
        out = []
        if not points:
            return out
        prev = points[-1]
        prev_in = inside(prev)
        for cur in points:
            cur_in = inside(cur)
            if cur_in:
                if not prev_in:
                    out.append(intersect(prev, cur))
                out.append(cur)
            elif prev_in:
                out.append(intersect(prev, cur))
            prev, prev_in = cur, cur_in
        return out

    def ix(x0):
        def f(p, q):
            t = (x0 - p[0]) / (q[0] - p[0])
            return (x0, p[1] + t * (q[1] - p[1]))
        return f

    def iy(y0):
        def f(p, q):
            t = (y0 - p[1]) / (q[1] - p[1])
            return (p[0] + t * (q[0] - p[0]), y0)
        return f

    pts = list(ring)
    pts = clip(pts, lambda p: p[0] >= xmin, ix(xmin))
    pts = clip(pts, lambda p: p[0] <= xmax, ix(xmax))
    pts = clip(pts, lambda p: p[1] >= ymin, iy(ymin))
    pts = clip(pts, lambda p: p[1] <= ymax, iy(ymax))
    return pts


def clip_line(points, xmin, ymin, xmax, ymax):
    """Liang-Barsky clip of a polyline to a rectangle; returns a list of parts."""
    parts = []
    cur = []
    for i in range(len(points) - 1):
        x0, y0 = points[i][0], points[i][1]
        x1, y1 = points[i + 1][0], points[i + 1][1]
        dx, dy = x1 - x0, y1 - y0
        t0, t1 = 0.0, 1.0
        ok = True
        for p, q in ((-dx, x0 - xmin), (dx, xmax - x0), (-dy, y0 - ymin), (dy, ymax - y0)):
            if p == 0:
                if q < 0:
                    ok = False
                    break
            else:
                t = q / p
                if p < 0:
                    if t > t1:
                        ok = False
                        break
                    t0 = max(t0, t)
                else:
                    if t < t0:
                        ok = False
                        break
                    t1 = min(t1, t)
        if not ok:
            if cur:
                parts.append(cur)
                cur = []
            continue
        a = (x0 + t0 * dx, y0 + t0 * dy)
        b = (x0 + t1 * dx, y0 + t1 * dy)
        if not cur:
            cur = [a]
        elif cur[-1] != a:
            parts.append(cur)
            cur = [a]
        cur.append(b)
        if t1 < 1.0:
            parts.append(cur)
            cur = []
    if cur:
        parts.append(cur)
    return [p for p in parts if len(p) >= 2]


# ---------------------------------------------------------------- web mercator

def lonlat_to_unit(lon, lat):
    """Lon/lat to Web Mercator unit square (x right, y down, both 0..1)."""
    lat = max(-MAX_MERC_LAT, min(MAX_MERC_LAT, lat))
    x = (lon + 180.0) / 360.0
    s = math.sin(math.radians(lat))
    y = 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)
    return x, y


def unit_to_lonlat(x, y):
    lon = x * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y))))
    return lon, lat


def lonlat_to_3857(lon, lat):
    x = math.radians(lon) * EARTH_RADIUS
    y = math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)) * EARTH_RADIUS
    return x, y


def tile_bounds_lonlat(z, x, y):
    n = 2 ** z
    w, n_ = unit_to_lonlat(x / n, y / n)
    e, s = unit_to_lonlat((x + 1) / n, (y + 1) / n)
    return w, s, e, n_


# ---------------------------------------------------------------- local metric frame

class LocalFrame:
    """Equirectangular east/north metres around an origin; fine for a few km."""

    def __init__(self, lon0, lat0):
        self.lon0, self.lat0 = lon0, lat0
        self.mx = 111320.0 * math.cos(math.radians(lat0))
        self.my = 110574.0

    def to_lonlat(self, x, y):
        return self.lon0 + x / self.mx, self.lat0 + y / self.my

    def to_xy(self, lon, lat):
        return (lon - self.lon0) * self.mx, (lat - self.lat0) * self.my


def haversine_m(lon1, lat1, lon2, lat2):
    r = 6371008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def catmull_rom(points, samples_per_segment):
    """Centripetal-free uniform Catmull-Rom through points (tuples of any dim).

    samples_per_segment may be an int or a callable(i, p1, p2) -> int.
    """
    if len(points) < 2:
        return list(points)
    pts = [points[0]] + list(points) + [points[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        n = samples_per_segment(i - 1, p1, p2) if callable(samples_per_segment) else samples_per_segment
        n = max(1, n)
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(
                0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                for a, b, c, d in zip(p0, p1, p2, p3)
            ))
    out.append(tuple(points[-1]))
    return out


# ---------------------------------------------------------------- archives

def write_zip(path, entries):
    """Deterministic deflate ZIP. entries: list of (name, bytes)."""
    if os.path.exists(path):
        os.remove(path)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            zf.writestr(info, data, compresslevel=9)


def xml_escape(text):
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))
