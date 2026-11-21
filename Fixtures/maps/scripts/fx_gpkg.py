"""OGC GeoPackage 1.3 fixture around Yosemite, written with sqlite3 only."""

import math
import os
import random
import sqlite3
import struct

from pyproj import Geod

from fx_common import catmull_rom, lonlat_to_3857, orient

GPKG_APPLICATION_ID = 0x47504B47  # "GPKG"
GPKG_USER_VERSION = 10300
LAST_CHANGE = "2025-01-01T00:00:00.000Z"

WKT_4326 = ('GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],'
            'AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],'
            'UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]]')
WKT_3857 = ('PROJCS["WGS 84 / Pseudo-Mercator",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,'
            '298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,'
            'AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],'
            'AUTHORITY["EPSG","4326"]],PROJECTION["Mercator_1SP"],PARAMETER["central_meridian",0],'
            'PARAMETER["scale_factor",1],PARAMETER["false_easting",0],PARAMETER["false_northing",0],'
            'UNIT["metre",1,AUTHORITY["EPSG","9001"]],AXIS["Easting",EAST],AXIS["Northing",NORTH],'
            'EXTENSION["PROJ4","+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 +x_0=0 +y_0=0 +k=1 '
            '+units=m +nadgrids=@null +wktext +no_defs"],AUTHORITY["EPSG","3857"]]')

WKB_POINT, WKB_LINESTRING, WKB_POLYGON, WKB_MULTIPOLYGON = 1, 2, 3, 6


# ---------------------------------------------------------------- WKB / GeoPackage binary

def _wkb(geom_type, payload_fn, little, has_z=False):
    bo = "<" if little else ">"
    code = geom_type + (1000 if has_z else 0)  # ISO WKB Z codes, as GeoPackage requires
    return bytes([1 if little else 0]) + struct.pack(bo + "I", code) + payload_fn(bo)


def wkb_point(x, y, z=None, little=True):
    if z is None:
        return _wkb(WKB_POINT, lambda bo: struct.pack(bo + "2d", x, y), little)
    return _wkb(WKB_POINT, lambda bo: struct.pack(bo + "3d", x, y, z), little, has_z=True)


def wkb_linestring(pts, little=True):
    def body(bo):
        return struct.pack(bo + "I", len(pts)) + b"".join(struct.pack(bo + "2d", x, y) for x, y in pts)
    return _wkb(WKB_LINESTRING, body, little)


def _rings_body(bo, rings):
    out = struct.pack(bo + "I", len(rings))
    for r in rings:
        out += struct.pack(bo + "I", len(r)) + b"".join(struct.pack(bo + "2d", x, y) for x, y in r)
    return out


def wkb_polygon(rings, little=True):
    return _wkb(WKB_POLYGON, lambda bo: _rings_body(bo, rings), little)


def wkb_multipolygon(polys, little=True):
    def body(bo):
        return struct.pack(bo + "I", len(polys)) + b"".join(wkb_polygon(p, little) for p in polys)
    return _wkb(WKB_MULTIPOLYGON, body, little)


def gpkg_blob(wkb, srs_id, xs, ys, little=True):
    """GeoPackageBinary: 'GP', version 0, flags, srs_id, xy envelope, WKB."""
    flags = (1 << 1) | (1 if little else 0)  # envelope contents indicator 1 = [minx, maxx, miny, maxy]
    bo = "<" if little else ">"
    return (b"GP" + bytes([0, flags]) + struct.pack(bo + "i", srs_id)
            + struct.pack(bo + "4d", min(xs), max(xs), min(ys), max(ys)) + wkb)


# ---------------------------------------------------------------- parsing (verification)

def parse_blob(blob):
    assert blob[:2] == b"GP" and blob[2] == 0
    flags = blob[3]
    little = flags & 1
    env_type = (flags >> 1) & 7
    bo = "<" if little else ">"
    srs, = struct.unpack(bo + "i", blob[4:8])
    n_env = {0: 0, 1: 4, 2: 6, 3: 6, 4: 8}[env_type]
    env = struct.unpack(bo + "%dd" % n_env, blob[8:8 + 8 * n_env])
    geom, end = parse_wkb(blob, 8 + 8 * n_env)
    assert end == len(blob)
    return {"little": bool(little), "env_type": env_type, "srs_id": srs, "envelope": env, "geom": geom}


def parse_wkb(buf, pos):
    bo = "<" if buf[pos] == 1 else ">"
    code, = struct.unpack(bo + "I", buf[pos + 1:pos + 5])
    pos += 5
    has_z = code >= 1000
    gtype = code % 1000
    dim = 3 if has_z else 2

    def read_pts(pos):
        n, = struct.unpack(bo + "I", buf[pos:pos + 4])
        pos += 4
        vals = struct.unpack(bo + "%dd" % (n * dim), buf[pos:pos + 8 * n * dim])
        return [vals[i * dim:(i + 1) * dim] for i in range(n)], pos + 8 * n * dim

    if gtype == WKB_POINT:
        vals = struct.unpack(bo + "%dd" % dim, buf[pos:pos + 8 * dim])
        return ("Point", vals, bo), pos + 8 * dim
    if gtype == WKB_LINESTRING:
        pts, pos = read_pts(pos)
        return ("LineString", pts, bo), pos
    if gtype == WKB_POLYGON:
        n, = struct.unpack(bo + "I", buf[pos:pos + 4])
        pos += 4
        rings = []
        for _ in range(n):
            r, pos = read_pts(pos)
            rings.append(r)
        return ("Polygon", rings, bo), pos
    if gtype == WKB_MULTIPOLYGON:
        n, = struct.unpack(bo + "I", buf[pos:pos + 4])
        pos += 4
        polys = []
        for _ in range(n):
            p, pos = parse_wkb(buf, pos)
            polys.append(p[1])
        return ("MultiPolygon", polys, bo), pos
    raise ValueError(code)


# ---------------------------------------------------------------- data

def _blob_ring(cx, cy, rx_km, ry_km, n, rng, rough=0.12, rot=0.0):
    """Irregular closed lon/lat ring around (cx, cy)."""
    kx = 1.0 / (111.32 * math.cos(math.radians(cy)))
    ky = 1.0 / 110.57
    phases = [rng.uniform(0, 2 * math.pi) for _ in range(3)]
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        f = 1 + rough * (math.sin(2 * a + phases[0]) * 0.6 + math.sin(3 * a + phases[1]) * 0.3
                         + math.sin(5 * a + phases[2]) * 0.2)
        ux, uy = math.cos(a) * rx_km * f, math.sin(a) * ry_km * f
        x = ux * math.cos(rot) - uy * math.sin(rot)
        y = ux * math.sin(rot) + uy * math.cos(rot)
        pts.append((round(cx + x * kx, 6), round(cy + y * ky, 6)))
    return pts


def _close(points, ccw):
    r = orient(points, ccw)
    return r + [r[0]]


PARKS = [
    # name, established, polygons: list of (outer spec, [hole specs]); spec = (lon, lat, rx_km, ry_km, rot_deg)
    ("Yosemite Valley Floor", 1864, [((-119.590, 37.737, 4.6, 0.9, 12), [(-119.600, 37.735, 0.6, 0.25, 12)])]),
    ("Tuolumne Meadows", 1890, [((-119.365, 37.874, 2.4, 0.8, -5), [(-119.370, 37.874, 0.4, 0.2, 0)]),
                                ((-119.412, 37.881, 0.9, 0.5, 20), [])]),
    ("Mariposa Grove", 1864, [((-119.600, 37.507, 1.6, 1.1, 30), [])]),
    ("Hetch Hetchy Watershed", 1913, [((-119.785, 37.952, 3.2, 1.6, 25),
                                       [(-119.800, 37.948, 0.5, 0.3, 0), (-119.765, 37.958, 0.4, 0.25, 0)])]),
    ("Glacier Point Reserve", 1906, [((-119.574, 37.728, 0.8, 0.5, 0), [])]),
]

TRAILS = [
    ("Mist Trail", "strenuous", [(-119.5583, 37.7322), (-119.5520, 37.7290), (-119.5440, 37.7275),
                                 (-119.5385, 37.7262), (-119.5330, 37.7247)]),
    ("Four Mile Trail", "strenuous", [(-119.6033, 37.7392), (-119.5990, 37.7330), (-119.5920, 37.7310),
                                      (-119.5850, 37.7290), (-119.5737, 37.7307)]),
    ("Upper Yosemite Fall Trail", "strenuous", [(-119.6004, 37.7420), (-119.6011, 37.7462),
                                                (-119.5985, 37.7510), (-119.5960, 37.7565)]),
    ("Half Dome Trail", "strenuous", [(-119.5330, 37.7247), (-119.5240, 37.7290), (-119.5140, 37.7330),
                                      (-119.5200, 37.7420), (-119.5332, 37.7459)]),
    ("Panorama Trail", "moderate", [(-119.5737, 37.7307), (-119.5680, 37.7250), (-119.5610, 37.7230),
                                    (-119.5480, 37.7220), (-119.5330, 37.7247)]),
    ("Mirror Lake Loop", "easy", [(-119.5583, 37.7395), (-119.5530, 37.7440), (-119.5480, 37.7470),
                                  (-119.5450, 37.7445), (-119.5520, 37.7400), (-119.5583, 37.7395)]),
    ("Clouds Rest Trail", "strenuous", [(-119.4710, 37.8260), (-119.4750, 37.8100), (-119.4790, 37.7950),
                                        (-119.4850, 37.7800), (-119.4895, 37.7672)]),
    ("Cathedral Lakes Trail", "moderate", [(-119.3830, 37.8730), (-119.3950, 37.8650), (-119.4060, 37.8560),
                                           (-119.4180, 37.8470)]),
    ("Dog Lake Trail", "easy", [(-119.3500, 37.8790), (-119.3480, 37.8850), (-119.3440, 37.8930)]),
    ("Pohono Trail", "moderate", [(-119.5737, 37.7307), (-119.5843, 37.7230), (-119.6036, 37.7128),
                                  (-119.6300, 37.7130), (-119.6550, 37.7150), (-119.6772, 37.7156)]),
]
BIG_ENDIAN_TRAILS = {"Half Dome Trail", "Clouds Rest Trail"}

PEAKS = [
    ("Half Dome", -119.5332, 37.7459, 2694), ("El Capitan", -119.6377, 37.7340, 2307),
    ("Clouds Rest", -119.4895, 37.7672, 3025), ("Mount Hoffmann", -119.5103, 37.8466, 3307),
    ("Sentinel Dome", -119.5843, 37.7230, 2476), ("Cathedral Peak", -119.4057, 37.8476, 3326),
    ("Mount Dana", -119.2209, 37.8999, 3981), ("Mount Lyell", -119.2710, 37.7396, 3997),
    ("Mount Conness", -119.3210, 37.9670, 3837), ("Unicorn Peak", -119.3880, 37.8466, 3241),
    ("North Dome", -119.5536, 37.7577, 2295), ("Eagle Peak", -119.6066, 37.7375, 2373),
    ("Mount Starr King", -119.5153, 37.6950, 2773), ("Liberty Cap", -119.5216, 37.7404, 2155),
    ("Lembert Dome", -119.3519, 37.8775, 2843),
]

NOTES = [
    ("Data source", "Synthetic shapes for testing. Names refer to real places; geometry is approximate.",
     "2025-01-01T00:00:00Z"),
    ("Trail closures", "Mist Trail: check conditions in winter. Half Dome cables seasonal.", "2025-01-02T08:30:00Z"),
    ("Units", "area_km2 and length_km are geodesic (WGS84). elevation_m is metres above sea level.",
     "2025-01-03T12:00:00Z"),
    ("Encoding test", "Unicode: Tuolumne – Mariposa — “quoted” · café · 优胜美地", "2025-01-04T16:45:00Z"),
]


def build(out_dir):
    path = os.path.join(out_dir, "places.gpkg")
    if os.path.exists(path):
        os.remove(path)
    rng = random.Random(1890)
    geod = Geod(ellps="WGS84")
    db = sqlite3.connect(path)
    c = db.cursor()
    c.execute("PRAGMA application_id = %d" % GPKG_APPLICATION_ID)
    c.execute("PRAGMA user_version = %d" % GPKG_USER_VERSION)
    c.executescript("""
    CREATE TABLE gpkg_spatial_ref_sys (
      srs_name TEXT NOT NULL,
      srs_id INTEGER NOT NULL PRIMARY KEY,
      organization TEXT NOT NULL,
      organization_coordsys_id INTEGER NOT NULL,
      definition TEXT NOT NULL,
      description TEXT
    );
    CREATE TABLE gpkg_contents (
      table_name TEXT NOT NULL PRIMARY KEY,
      data_type TEXT NOT NULL,
      identifier TEXT UNIQUE,
      description TEXT DEFAULT '',
      last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE,
      srs_id INTEGER,
      CONSTRAINT fk_gc_r_srs_id FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id)
    );
    CREATE TABLE gpkg_geometry_columns (
      table_name TEXT NOT NULL,
      column_name TEXT NOT NULL,
      geometry_type_name TEXT NOT NULL,
      srs_id INTEGER NOT NULL,
      z TINYINT NOT NULL,
      m TINYINT NOT NULL,
      CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name),
      CONSTRAINT uk_gc_table_name UNIQUE (table_name),
      CONSTRAINT fk_gc_tn FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
      CONSTRAINT fk_gc_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys (srs_id)
    );
    """)
    c.executemany("INSERT INTO gpkg_spatial_ref_sys VALUES (?,?,?,?,?,?)", [
        ("Undefined cartesian SRS", -1, "NONE", -1, "undefined", "undefined cartesian coordinate reference system"),
        ("Undefined geographic SRS", 0, "NONE", 0, "undefined", "undefined geographic coordinate reference system"),
        ("WGS 84 geodetic", 4326, "EPSG", 4326, WKT_4326, "longitude/latitude coordinates in decimal degrees on the WGS 84 spheroid"),
        ("WGS 84 / Pseudo-Mercator", 3857, "EPSG", 3857, WKT_3857, "Web Mercator (spherical), metres"),
    ])

    def add_contents(table, dtype, desc, bounds, srs):
        c.execute("INSERT INTO gpkg_contents (table_name, data_type, identifier, description, last_change, "
                  "min_x, min_y, max_x, max_y, srs_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
                  (table, dtype, table, desc, LAST_CHANGE) + tuple(bounds) + (srs,))

    # parks: MULTIPOLYGON, 4326
    c.execute("CREATE TABLE parks (fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom MULTIPOLYGON, "
              "name TEXT NOT NULL, area_km2 REAL, established INTEGER)")
    all_x, all_y = [], []
    park_rows = []
    for name, year, polys in PARKS:
        mp = []
        area = 0.0
        for outer, holes in polys:
            o = _close(_blob_ring(outer[0], outer[1], outer[2], outer[3], 36, rng, rot=math.radians(outer[4])), True)
            rings = [o]
            for h in holes:
                rings.append(_close(_blob_ring(h[0], h[1], h[2], h[3], 14, rng, rough=0.08,
                                               rot=math.radians(h[4])), False))
            mp.append(rings)
            for i, r in enumerate(rings):
                a, _ = geod.polygon_area_perimeter([p[0] for p in r], [p[1] for p in r])
                area += abs(a) * (1 if i == 0 else -1)
        xs = [p[0] for poly in mp for p in poly[0]]
        ys = [p[1] for poly in mp for p in poly[0]]
        all_x += xs
        all_y += ys
        blob = gpkg_blob(wkb_multipolygon(mp), 4326, xs, ys)
        park_rows.append((blob, name, round(area / 1e6, 3), year))
    c.executemany("INSERT INTO parks (geom, name, area_km2, established) VALUES (?,?,?,?)", park_rows)
    add_contents("parks", "features", "Protected areas (synthetic outlines)",
                 (min(all_x), min(all_y), max(all_x), max(all_y)), 4326)
    c.execute("INSERT INTO gpkg_geometry_columns VALUES ('parks','geom','MULTIPOLYGON',4326,0,0)")

    # trails: LINESTRING, 4326
    c.execute("CREATE TABLE trails (fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom LINESTRING, "
              "name TEXT NOT NULL, length_km REAL, difficulty TEXT)")
    all_x, all_y = [], []
    trail_rows = []
    for name, difficulty, ctrl in TRAILS:
        dense = catmull_rom(ctrl, 8)
        wig = []
        for i, (x, y) in enumerate(dense):
            if 0 < i < len(dense) - 1:
                x += rng.uniform(-0.00025, 0.00025)
                y += rng.uniform(-0.00020, 0.00020)
            wig.append((round(x, 6), round(y, 6)))
        length = geod.line_length([p[0] for p in wig], [p[1] for p in wig]) / 1000.0
        xs = [p[0] for p in wig]
        ys = [p[1] for p in wig]
        all_x += xs
        all_y += ys
        little = name not in BIG_ENDIAN_TRAILS
        trail_rows.append((gpkg_blob(wkb_linestring(wig, little), 4326, xs, ys, little), name, round(length, 2),
                           difficulty))
    trail_rows.append((None, "Proposed connector (not yet mapped)", None, "unknown"))
    c.executemany("INSERT INTO trails (geom, name, length_km, difficulty) VALUES (?,?,?,?)", trail_rows)
    add_contents("trails", "features", "Hiking trails (approximate)", (min(all_x), min(all_y), max(all_x), max(all_y)),
                 4326)
    c.execute("INSERT INTO gpkg_geometry_columns VALUES ('trails','geom','LINESTRING',4326,0,0)")

    # peaks: POINT Z, 3857, little-endian
    c.execute("CREATE TABLE peaks (fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom POINT, "
              "name TEXT NOT NULL, elevation_m REAL)")
    all_x, all_y = [], []
    peak_rows = []
    for name, lon, lat, ele in PEAKS:
        x, y = lonlat_to_3857(lon, lat)
        x, y = round(x, 2), round(y, 2)
        all_x.append(x)
        all_y.append(y)
        peak_rows.append((gpkg_blob(wkb_point(x, y, float(ele)), 3857, [x], [y]), name, float(ele)))
    c.executemany("INSERT INTO peaks (geom, name, elevation_m) VALUES (?,?,?)", peak_rows)
    add_contents("peaks", "features", "Summits (Web Mercator metres, Z = elevation)",
                 (min(all_x), min(all_y), max(all_x), max(all_y)), 3857)
    c.execute("INSERT INTO gpkg_geometry_columns VALUES ('peaks','geom','POINT',3857,1,0)")

    # notes: attributes (no geometry)
    c.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, title TEXT NOT NULL, "
              "body TEXT, created DATETIME)")
    c.executemany("INSERT INTO notes (title, body, created) VALUES (?,?,?)", NOTES)
    c.execute("INSERT INTO gpkg_contents (table_name, data_type, identifier, description, last_change) "
              "VALUES ('notes','attributes','notes','Free-text notes (attributes table)',?)", (LAST_CHANGE,))
    db.commit()
    c.execute("VACUUM")
    db.close()
    return {"parks": len(park_rows), "trails": len(trail_rows), "peaks": len(peak_rows), "notes": len(NOTES)}


def verify(out_dir):
    path = os.path.join(out_dir, "places.gpkg")
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    c = db.cursor()
    app_id = c.execute("PRAGMA application_id").fetchone()[0]
    user_version = c.execute("PRAGMA user_version").fetchone()[0]
    integrity = c.execute("PRAGMA integrity_check").fetchone()[0]
    fk = c.execute("PRAGMA foreign_key_check").fetchall()
    assert app_id == GPKG_APPLICATION_ID and user_version == GPKG_USER_VERSION and integrity == "ok" and not fk
    with open(path, "rb") as fh:
        head = fh.read(100)
    assert head[68:72] == b"GPKG"  # application_id lives at offset 68 of the SQLite header
    out = {"application_id": hex(app_id), "user_version": user_version, "integrity_check": integrity,
           "srs_ids": [r[0] for r in c.execute("SELECT srs_id FROM gpkg_spatial_ref_sys ORDER BY srs_id")],
           "contents": c.execute("SELECT table_name, data_type, srs_id, min_x, min_y, max_x, max_y "
                                 "FROM gpkg_contents ORDER BY table_name").fetchall(),
           "tables": {}}
    for table, gtype in (("parks", "MultiPolygon"), ("trails", "LineString"), ("peaks", "Point")):
        rows = c.execute("SELECT geom FROM %s ORDER BY fid" % table).fetchall()
        info = {"rows": len(rows), "null_geom": 0, "big_endian": 0, "holes": 0}
        for (blob,) in rows:
            if blob is None:
                info["null_geom"] += 1
                continue
            g = parse_blob(blob)
            assert g["env_type"] == 1
            assert g["geom"][0] == gtype
            if not g["little"]:
                info["big_endian"] += 1
                assert g["geom"][2] == ">"
            coords = g["geom"][1]
            if gtype == "MultiPolygon":
                info["holes"] += sum(len(p) - 1 for p in coords)
                pts = [pt for p in coords for pt in p[0]]
            elif gtype == "LineString":
                pts = coords
            else:
                pts = [coords]
                info["z_example"] = coords[2] if len(coords) == 3 else None
            env = g["envelope"]
            assert abs(env[0] - min(p[0] for p in pts)) < 1e-9 and abs(env[1] - max(p[0] for p in pts)) < 1e-9
            assert abs(env[2] - min(p[1] for p in pts)) < 1e-9 and abs(env[3] - max(p[1] for p in pts)) < 1e-9
        out["tables"][table] = info
    out["tables"]["notes"] = {"rows": c.execute("SELECT count(*) FROM notes").fetchone()[0]}
    db.close()
    return out
