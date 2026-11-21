"""MBTiles fixtures: raster PNG, relief JPEG and Mapbox Vector Tiles."""

import gzip
import io
import json
import math
import os
import random
import sqlite3

from PIL import Image, ImageDraw, ImageFilter

import fx_mvt as mvt
from fx_common import bbox_of, load_geojson, lonlat_to_unit, unit_to_lonlat

MBTILES_APPLICATION_ID = 0x4D504258  # "MPBX", optional per MBTiles 1.3
WORLD_BOUNDS = "-180,-85.0511,180,85.0511"
ATTRIBUTION = "Made with Natural Earth"


# ---------------------------------------------------------------- source data in unit coordinates

class World:
    """Natural Earth layers projected to the Web Mercator unit square."""

    def __init__(self, ne):
        self.land = self._polys(load_geojson(os.path.join(ne, "ne_110m_land.geojson")))
        self.lakes = self._polys(load_geojson(os.path.join(ne, "ne_110m_lakes.geojson")))
        self.borders = self._lines(load_geojson(os.path.join(ne, "ne_110m_admin_0_boundary_lines_land.geojson")))
        self.rivers = self._lines(load_geojson(os.path.join(ne, "ne_110m_rivers_lake_centerlines.geojson")))
        places = load_geojson(os.path.join(ne, "ne_110m_populated_places_simple.geojson"))
        self.places = [(lonlat_to_unit(*f["geometry"]["coordinates"]), f["properties"]) for f in places["features"]]

    @staticmethod
    def _polys(fc):
        out = []
        for f in fc["features"]:
            g = f["geometry"]
            polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
            for poly in polys:
                rings = [[lonlat_to_unit(lon, lat) for lon, lat in ring] for ring in poly]
                out.append((rings, bbox_of(rings[0]), f["properties"]))
        return out

    @staticmethod
    def _lines(fc):
        out = []
        for f in fc["features"]:
            g = f["geometry"]
            lines = [g["coordinates"]] if g["type"] == "LineString" else g["coordinates"]
            for line in lines:
                pts = [lonlat_to_unit(lon, lat) for lon, lat in line]
                out.append((pts, bbox_of(pts), f["properties"]))
        return out


def _hits(bbox, z, x, y, margin=0.0):
    n = 2 ** z
    x0, y0, x1, y1 = x / n - margin, y / n - margin, (x + 1) / n + margin, (y + 1) / n + margin
    return not (bbox[2] < x0 or bbox[0] > x1 or bbox[3] < y0 or bbox[1] > y1)


def all_tiles(zooms):
    for z in zooms:
        for x in range(2 ** z):
            for y in range(2 ** z):
                yield z, x, y


# ---------------------------------------------------------------- MBTiles writer

def write_mbtiles(path, metadata, tiles):
    """metadata: list of (name, value); tiles: dict {(z, x, y_xyz): bytes}."""
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    c = db.cursor()
    c.execute("PRAGMA application_id = %d" % MBTILES_APPLICATION_ID)
    c.executescript("""
    CREATE TABLE metadata (name TEXT, value TEXT);
    CREATE UNIQUE INDEX name ON metadata (name);
    CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
    CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
    """)
    c.executemany("INSERT INTO metadata (name, value) VALUES (?, ?)", metadata)
    rows = []
    for (z, x, y), data in sorted(tiles.items()):
        rows.append((z, x, (2 ** z - 1) - y, sqlite3.Binary(data)))  # TMS row numbering
    c.executemany("INSERT INTO tiles VALUES (?, ?, ?, ?)", rows)
    db.commit()
    c.execute("VACUUM")
    db.close()


# ---------------------------------------------------------------- raster PNG

OCEAN = (170, 205, 225)
LAND = (246, 241, 229)
COAST = (150, 186, 207)
BORDER = (152, 152, 152)


def _px(points, z, x, y, size):
    n = 2 ** z
    return [((ux * n - x) * size, (uy * n - y) * size) for ux, uy in points]


def render_raster_tile(world, z, x, y, ss=4):
    size = 256 * ss
    img = Image.new("RGB", (size, size), OCEAN)
    d = ImageDraw.Draw(img)
    margin = 2.0 / 2 ** z / 256
    land = [p for p in world.land if _hits(p[1], z, x, y, margin)]
    for rings, _, _ in land:
        d.polygon(_px(rings[0], z, x, y, size), fill=LAND)
        for hole in rings[1:]:
            d.polygon(_px(hole, z, x, y, size), fill=OCEAN)
    for rings, bb, _ in world.lakes:
        if _hits(bb, z, x, y, margin):
            d.polygon(_px(rings[0], z, x, y, size), fill=OCEAN)
    coast_w = max(1, int(round(0.9 * ss)))
    for rings, _, _ in land:
        for ring in rings:
            pts = _px(ring, z, x, y, size)
            d.line(pts + [pts[0]], fill=COAST, width=coast_w)
    border_w = max(1, int(round(0.8 * ss)))
    for pts, bb, _ in world.borders:
        if _hits(bb, z, x, y, margin):
            d.line(_px(pts, z, x, y, size), fill=BORDER, width=border_w, joint="curve")
    img = img.resize((256, 256), Image.Resampling.LANCZOS)
    pal = img.quantize(colors=24, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    buf = io.BytesIO()
    pal.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def make_raster(world, out_dir):
    tiles = {(z, x, y): render_raster_tile(world, z, x, y) for z, x, y in all_tiles(range(0, 4))}
    meta = [("name", "World Overview"), ("format", "png"), ("minzoom", "0"), ("maxzoom", "3"),
            ("bounds", WORLD_BOUNDS), ("center", "0,20,1"), ("type", "baselayer"), ("version", "1.0"),
            ("description", "Natural Earth 1:110m land, lakes and country borders rendered in Web Mercator "
                            "as 256x256 palette PNG tiles, zoom 0-3."),
            ("attribution", ATTRIBUTION)]
    write_mbtiles(os.path.join(out_dir, "raster.mbtiles"), meta, tiles)
    return {"tiles": len(tiles), "tile_bytes": sum(len(v) for v in tiles.values())}


# ---------------------------------------------------------------- relief JPEG

class Relief:
    """Smooth pseudo-terrain defined on the whole world so tiles join seamlessly.

    A sum of a few low-frequency plane waves (deterministic phases); its
    analytic gradient gives a gentle hillshade. Purely decorative.
    """

    def __init__(self, seed=2024):
        rng = random.Random(seed)
        self.waves = []
        for i in range(8):
            f = 2.0 * (1.5 ** i)  # cycles per world width: 2 .. 34
            th = rng.uniform(0, math.pi)
            self.waves.append((0.6 / (1 + i * 0.6), f, math.cos(th), math.sin(th), rng.uniform(0, 2 * math.pi)))
        # RMS of the gradient, used to normalise the shading strength
        self.grad_rms = math.sqrt(sum((a * 2 * math.pi * f) ** 2 / 2 for a, f, _, _, _ in self.waves))

    def sample(self, ux, uy):
        e = 0.0
        gx = gy = 0.0
        for a, f, cx, cy, ph in self.waves:
            arg = 2 * math.pi * f * (ux * cx + uy * cy) + ph
            e += a * math.sin(arg)
            g = a * 2 * math.pi * f * math.cos(arg)
            gx += g * cx
            gy += g * cy
        return e, gx, gy


TINTS = [(-1.2, (176, 201, 150)), (-0.2, (203, 214, 160)), (0.4, (226, 212, 170)), (0.9, (205, 178, 145)),
         (1.4, (184, 160, 140))]
SNOW = (243, 243, 240)


def _tint(e, lat):
    if e <= TINTS[0][0]:
        col = TINTS[0][1]
    elif e >= TINTS[-1][0]:
        col = TINTS[-1][1]
    else:
        for (e0, c0), (e1, c1) in zip(TINTS, TINTS[1:]):
            if e0 <= e <= e1:
                t = (e - e0) / (e1 - e0)
                col = tuple(a + (b - a) * t for a, b in zip(c0, c1))
                break
    polar = min(1.0, max(0.0, (abs(lat) - 60.0) / 12.0))
    return tuple(a + (b - a) * polar for a, b in zip(col, SNOW))


def render_relief_tile(world, relief, z, x, y):
    m = 32  # margin so the coastal glow is continuous across tile edges
    size = 256 + 2 * m
    ss = 3
    n = 2 ** z
    mask = Image.new("L", (size * ss, size * ss), 0)
    d = ImageDraw.Draw(mask)
    margin = (m + 2) / 256 / n

    def px(points):
        return [(((ux * n - x) * 256 + m) * ss, ((uy * n - y) * 256 + m) * ss) for ux, uy in points]

    for rings, bb, _ in world.land:
        if _hits(bb, z, x, y, margin):
            d.polygon(px(rings[0]), fill=255)
            for hole in rings[1:]:
                d.polygon(px(hole), fill=0)
    for rings, bb, _ in world.lakes:
        if _hits(bb, z, x, y, margin):
            d.polygon(px(rings[0]), fill=0)
    mask = mask.resize((size, size), Image.Resampling.BOX)

    # land colour on a coarse grid, then smoothed up
    g = 80
    grid = Image.new("RGB", (g, g))
    gp = []
    for j in range(g):
        for i in range(g):
            fx = (i + 0.5) / g * size - m
            fy = (j + 0.5) / g * size - m
            ux, uy = (x + fx / 256) / n, (y + fy / 256) / n
            uy = min(max(uy, 0.0), 1.0)
            _, lat = unit_to_lonlat(ux, uy)
            e, gx, gy = relief.sample(ux, uy)
            # light from the north-west (screen x left, y up)
            shade = 1.0 + max(-0.12, min(0.12, (gx + gy) / relief.grad_rms * 0.07))
            col = _tint(e, lat)
            gp.append(tuple(int(max(0, min(255, c * shade))) for c in col))
    grid.putdata(gp)
    land_rgb = grid.resize((size, size), Image.Resampling.BICUBIC)

    glow = mask.filter(ImageFilter.GaussianBlur(radius=9)).point(lambda v: min(255, int(v * 1.8)))
    deep = Image.new("RGB", (size, size), (120, 160, 196))
    shallow = Image.new("RGB", (size, size), (178, 208, 228))
    ocean = Image.composite(shallow, deep, glow)
    img = Image.composite(land_rgb, ocean, mask).crop((m, m, m + 256, m + 256))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=80, optimize=True)
    return buf.getvalue()


def make_relief(world, out_dir):
    relief = Relief()
    tiles = {(z, x, y): render_relief_tile(world, relief, z, x, y) for z, x, y in all_tiles(range(0, 3))}
    meta = [("name", "World Relief"), ("format", "jpg"), ("minzoom", "0"), ("maxzoom", "2"),
            ("bounds", WORLD_BOUNDS), ("center", "0,20,1"), ("type", "baselayer"), ("version", "1.0"),
            ("description", "Natural Earth 1:110m land with a synthetic, purely decorative terrain tint and "
                            "coastal shading, as 256x256 JPEG tiles, zoom 0-2."),
            ("attribution", ATTRIBUTION)]
    write_mbtiles(os.path.join(out_dir, "relief.mbtiles"), meta, tiles)
    return {"tiles": len(tiles), "tile_bytes": sum(len(v) for v in tiles.values())}


# ---------------------------------------------------------------- vector tiles

EUROPE_Z4 = [(4, x, y) for x in range(7, 10) for y in range(3, 7)]


def _boundary_kind(featurecla):
    f = (featurecla or "").lower()
    for word, kind in (("disputed", "disputed"), ("claim", "claim"), ("control", "line_of_control"),
                       ("indefinite", "indefinite"), ("indeterminant", "indefinite")):
        if word in f:
            return kind
    return "international"


def build_vector_tile(world, z, x, y):
    margin = 80.0 / 4096 / 2 ** z
    land = mvt.LayerBuilder("land")
    for rings, bb, props in world.land:
        if not _hits(bb, z, x, y, margin):
            continue
        parts = mvt.polygon_parts(rings, z, x, y)
        if parts:
            land.add(mvt.POLYGON, parts, [("scalerank", mvt.V_UINT, int(props.get("scalerank") or 0)),
                                          ("min_zoom", mvt.V_DOUBLE, float(props.get("min_zoom") or 0.0))])
    boundaries = mvt.LayerBuilder("boundaries")
    for pts, bb, props in world.borders:
        if not _hits(bb, z, x, y, margin):
            continue
        parts = mvt.line_parts(pts, z, x, y)
        if parts:
            boundaries.add(mvt.LINESTRING, parts, [("name", mvt.V_STRING, props.get("NAME")),
                                                   ("kind", mvt.V_STRING, _boundary_kind(props.get("FEATURECLA")))])
    rivers = mvt.LayerBuilder("rivers")
    for i, (pts, bb, props) in enumerate(world.rivers):
        if not _hits(bb, z, x, y, margin):
            continue
        parts = mvt.line_parts(pts, z, x, y)
        if parts:
            rivers.add(mvt.LINESTRING, parts, [("name", mvt.V_STRING, props.get("name")),
                                               ("scalerank", mvt.V_SINT, int(props.get("scalerank") or 0))],
                       fid=i + 1)
    places = mvt.LayerBuilder("places")
    for i, (pt, props) in enumerate(world.places):
        if z < 2 and props["scalerank"] > 3:
            continue  # thin out labels at the lowest zooms
        p = mvt.point_in_tile(pt, z, x, y)
        if p is None:
            continue
        places.add(mvt.POINT, [[p]], [
            ("name", mvt.V_STRING, props["name"]),
            ("adm0name", mvt.V_STRING, props["adm0name"]),
            ("pop_max", mvt.V_INT, int(props["pop_max"])),
            ("scalerank", mvt.V_UINT, int(props["scalerank"])),
            ("pop_m", mvt.V_FLOAT, round(props["pop_max"] / 1e6, 2)),
            ("capital", mvt.V_BOOL, bool(props["adm0cap"])),
        ], fid=i + 1)
    layers = [land, boundaries, rivers, places]
    return mvt.encode_tile(layers), {l.name: l.encoded for l in layers}


VECTOR_LAYERS = [
    {"id": "land", "description": "Natural Earth 1:110m land polygons", "minzoom": 0, "maxzoom": 4,
     "fields": {"scalerank": "Number", "min_zoom": "Number"}},
    {"id": "boundaries", "description": "Natural Earth 1:110m admin-0 land boundary lines", "minzoom": 0,
     "maxzoom": 4, "fields": {"name": "String", "kind": "String"}},
    {"id": "rivers", "description": "Natural Earth 1:110m rivers and lake centerlines", "minzoom": 0, "maxzoom": 4,
     "fields": {"name": "String", "scalerank": "Number"}},
    {"id": "places", "description": "Natural Earth 1:110m populated places (scalerank <= 3 below zoom 2)",
     "minzoom": 0, "maxzoom": 4,
     "fields": {"name": "String", "adm0name": "String", "pop_max": "Number", "scalerank": "Number",
                "pop_m": "Number", "capital": "Boolean"}},
]


def make_vector(world, out_dir):
    tiles = {}
    raw = {}
    counts = {}
    skipped_empty = 0
    for z, x, y in list(all_tiles(range(0, 4))) + EUROPE_Z4:
        data, c = build_vector_tile(world, z, x, y)
        if not data:
            skipped_empty += 1
            continue
        raw[(z, x, y)] = data
        counts[(z, x, y)] = c
        tiles[(z, x, y)] = gzip.compress(data, compresslevel=9, mtime=0)
    meta = [("name", "World Vector"), ("format", "pbf"), ("minzoom", "0"), ("maxzoom", "4"),
            ("bounds", WORLD_BOUNDS), ("center", "0,20,1"), ("type", "baselayer"), ("version", "1.0"),
            ("description", "Natural Earth 1:110m land, boundaries, rivers and places as Mapbox Vector Tiles "
                            "(gzip). Zoom 0-3 world-wide; zoom 4 only for Europe (x 7-9, y 3-6)."),
            ("attribution", ATTRIBUTION),
            ("json", json.dumps({"vector_layers": VECTOR_LAYERS}, separators=(",", ":")))]
    write_mbtiles(os.path.join(out_dir, "vector.mbtiles"), meta, tiles)
    return {"tiles": len(tiles), "skipped_empty": skipped_empty, "raw_bytes": sum(len(v) for v in raw.values()),
            "gzip_bytes": sum(len(v) for v in tiles.values()), "raw": raw, "encoded": counts}


# ---------------------------------------------------------------- verification

def read_mbtiles(path):
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    c = db.cursor()
    meta = dict(c.execute("SELECT name, value FROM metadata").fetchall())
    tiles = c.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles").fetchall()
    app_id = c.execute("PRAGMA application_id").fetchone()[0]
    idx = c.execute("SELECT sql FROM sqlite_master WHERE type='index' AND name='tile_index'").fetchone()
    integrity = c.execute("PRAGMA integrity_check").fetchone()[0]
    db.close()
    return meta, tiles, app_id, idx, integrity


def verify_images(path, fmt):
    meta, tiles, app_id, idx, integrity = read_mbtiles(path)
    assert integrity == "ok" and idx and "UNIQUE" in idx[0].upper()
    modes = set()
    per_zoom = {}
    for z, x, row, data in tiles:
        im = Image.open(io.BytesIO(data))
        im.load()
        assert im.size == (256, 256) and im.format == fmt
        modes.add(im.mode)
        per_zoom[z] = per_zoom.get(z, 0) + 1
        assert 0 <= row < 2 ** z
    return {"metadata": meta, "per_zoom": per_zoom, "modes": sorted(modes), "application_id": hex(app_id)}


def verify_vector(path, built):
    """Decode every tile with the independent mapbox-vector-tile package (if installed)."""
    meta, tiles, app_id, idx, integrity = read_mbtiles(path)
    assert integrity == "ok" and idx
    json.loads(meta["json"])
    result = {"metadata_keys": sorted(meta), "tiles": len(tiles), "application_id": hex(app_id)}
    try:
        import mapbox_vector_tile
    except ImportError:
        result["independent_decode"] = "skipped (mapbox_vector_tile not installed)"
        return result
    checked = features = polys = rings_checked = 0
    sample = None
    for z, x, row, data in tiles:
        y = (2 ** z - 1) - row
        raw = gzip.decompress(data)
        assert raw == built["raw"][(z, x, y)]
        dec = mapbox_vector_tile.decode(raw, default_options={"y_coord_down": True})
        expected = {k: v for k, v in built["encoded"][(z, x, y)].items() if v}
        assert set(dec) == set(expected), (z, x, y, set(dec), set(expected))
        for name, layer in dec.items():
            assert layer["extent"] == 4096 and layer["version"] == 2
            assert len(layer["features"]) == len(expected[name])
            features += len(layer["features"])
            for f, (gtype, parts) in zip(layer["features"], expected[name]):
                g = f["geometry"]
                if name == "land":
                    # One exterior per feature: the decoder must rebuild exactly one polygon whose
                    # rings are ours (closed). A winding error would split or drop rings.
                    assert g["type"] == "Polygon", (z, x, y, g["type"])
                    want = [[list(p) for p in ring] + [list(ring[0])] for ring in parts]
                    got = [[list(p) for p in ring] for ring in g["coordinates"]]
                    assert got == want, (z, x, y)
                    polys += 1
                    rings_checked += len(parts)
                elif name in ("boundaries", "rivers"):
                    want = [[list(p) for p in part] for part in parts]
                    got = [g["coordinates"]] if g["type"] == "LineString" else g["coordinates"]
                    assert [[list(p) for p in part] for part in got] == want, (z, x, y, name)
                else:
                    assert g["type"] == "Point" and list(g["coordinates"]) == list(parts[0][0])
                    p = f["properties"]
                    assert isinstance(p["pop_max"], int) and isinstance(p["pop_m"], float)
                    assert isinstance(p["capital"], bool) and isinstance(p["name"], str)
                    if sample is None and z == 3 and p["name"] in ("Paris", "London", "Tokyo"):
                        sample = {"tile": "%d/%d/%d" % (z, x, y), "properties": p, "id": f.get("id"),
                                  "geometry": g}
        checked += 1
    try:
        from importlib.metadata import version
        decoder = "mapbox-vector-tile %s" % version("mapbox-vector-tile")
    except Exception:  # pragma: no cover - metadata missing
        decoder = "mapbox-vector-tile"
    result["independent_decode"] = {"decoder": decoder,
                                    "tiles_decoded": checked, "features": features, "land_polygons": polys,
                                    "land_rings_matched": rings_checked,
                                    "sample_place": sample}
    return result
