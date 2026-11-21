"""Shapefile fixtures: rivers, parcels (UTM 33N), roads (Lambert-93), stations
(California zone III, US survey feet), PointZ without .prj, zipped cities."""

import json
import math
import os
import random

from pyproj import CRS, Transformer

import fx_shapefile as shp
from fx_common import (catmull_rom, haversine_m, load_geojson, orient, signed_area, write_text,
                       write_zip)


def _ring_cw(points):
    """Close a ring and wind it clockwise (shapefile outer ring)."""
    r = orient(points, ccw=False)
    return r + [r[0]]


def _ring_ccw(points):
    r = orient(points, ccw=True)
    return r + [r[0]]


# ---------------------------------------------------------------- rivers.shp

def make_rivers(ne, out_dir):
    src = load_geojson(os.path.join(ne, "ne_110m_rivers_lake_centerlines.geojson"))
    w = shp.ShapeWriter(shp.POLYLINE)
    recs = []
    for f in src["features"]:
        g = f["geometry"]
        parts = [g["coordinates"]] if g["type"] == "LineString" else g["coordinates"]
        w.add_parts([[(round(x, 6), round(y, 6)) for x, y in part] for part in parts])
        p = f["properties"]
        recs.append((p["name"], p.get("name_ru") or "", p["featurecla"], p["scalerank"]))
    fields = [shp.Field("NAME", "C", 32), shp.Field("NAME_RU", "C", 48), shp.Field("FEATURECLA", "C", 16),
              shp.Field("SCALERANK", "N", 2)]
    shp.write_shapefile(os.path.join(out_dir, "rivers"), w, fields, recs, prj=shp.PRJ_WGS84, cpg="UTF-8")
    return {"records": len(recs), "non_ascii_names": [r[0] for r in recs if not r[0].isascii()]}


# ---------------------------------------------------------------- parcels_utm33n

def make_parcels(out_dir):
    rng = random.Random(3301)
    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32633", always_xy=True)
    cx, cy = to_utm.transform(16.37, 48.21)
    angle = math.radians(17.0)
    ca, sa = math.cos(angle), math.sin(angle)

    def place(u, v):
        # local block frame (u east-ish, v north-ish) -> UTM metres, rounded to cm
        return (round(cx + u * ca - v * sa, 2), round(cy + u * sa + v * ca, 2))

    streets = ["Hofgasse", "Lindengasse", "Kirchengasse", "Zieglergasse", "Neubaugasse"]
    w = shp.ShapeWriter(shp.POLYGON)
    recs = []
    cols, rows = 8, 5
    pw, ph, gap = 42.0, 58.0, 4.0
    pid = 0
    hole_ids = {3, 9, 14, 22, 27, 35}
    multipart_id = 18
    for r in range(rows):
        for c in range(cols):
            pid += 1
            u0 = (c - cols / 2) * (pw + gap) + (8.0 if c >= cols // 2 else 0.0)  # street between halves
            v0 = (r - rows / 2) * (ph + gap)
            jit = lambda: rng.uniform(-2.5, 2.5)
            corners = [(u0 + jit(), v0 + jit()), (u0 + pw + jit(), v0 + jit()),
                       (u0 + pw + jit(), v0 + ph + jit()), (u0 + jit(), v0 + ph + jit())]
            if pid % 5 == 2:  # a fifth vertex on the street side
                corners.insert(2, (u0 + pw + 3.0 + jit(), v0 + ph / 2 + jit()))
            rings = []
            if pid == multipart_id:
                # split parcel: two separate outer rings
                left = [(u0, v0), (u0 + pw * 0.45, v0), (u0 + pw * 0.45, v0 + ph), (u0, v0 + ph)]
                right = [(u0 + pw * 0.55, v0), (u0 + pw, v0), (u0 + pw, v0 + ph), (u0 + pw * 0.55, v0 + ph)]
                rings.append(_ring_cw([place(*p) for p in left]))
                rings.append(_ring_cw([place(*p) for p in right]))
            else:
                rings.append(_ring_cw([place(*p) for p in corners]))
                if pid in hole_ids:
                    hu, hv = u0 + pw * 0.3, v0 + ph * 0.3
                    court = [(hu, hv), (hu + pw * 0.4, hv), (hu + pw * 0.4, hv + ph * 0.4), (hu, hv + ph * 0.4)]
                    rings.append(_ring_ccw([place(*p) for p in court]))
            area = -sum(signed_area(ring[:-1]) for ring in rings)  # outer cw (negative), holes ccw
            w.add_parts(rings)
            name = "%s %d, Parzelle %d/%d" % (streets[r], c * 2 + 1, 400 + r, c + 1)
            zoned = None if pid == 11 else (pid % 3 != 0)
            surveyed = None if pid == 7 else (1996 + (pid * 7) % 28, 1 + (pid * 5) % 12, 1 + (pid * 11) % 28)
            recs.append((pid, name, round(area, 2), zoned, surveyed))
    fields = [shp.Field("ID", "N", 9), shp.Field("NAME", "C", 48), shp.Field("AREA_M2", "F", 13, 2),
              shp.Field("ZONED", "L", 1), shp.Field("SURVEYED", "D", 8)]
    shp.write_shapefile(os.path.join(out_dir, "parcels_utm33n"), w, fields, recs, prj=shp.PRJ_UTM33N,
                        encoding="cp1252", ldid=0x57)
    return {"records": len(recs), "with_hole": sorted(hole_ids), "multipart": multipart_id,
            "null_logical_id": 11, "blank_date_id": 7}


# ---------------------------------------------------------------- roads_lambert93

LYON_ROADS = [
    ("Autoroute A6", "motorway", [(4.8205, 45.7605), (4.8150, 45.7750), (4.8105, 45.7900), (4.8010, 45.8100),
                                  (4.7820, 45.8300), (4.7620, 45.8500)]),
    ("Autoroute A7", "motorway", [(4.8185, 45.7470), (4.8172, 45.7350), (4.8135, 45.7200), (4.8105, 45.7000),
                                  (4.8160, 45.6800), (4.8300, 45.6500)]),
    ("Boulevard Périphérique Nord", "trunk", [(4.7900, 45.7900), (4.8200, 45.7955), (4.8500, 45.7950),
                                              (4.8800, 45.7900), (4.9000, 45.7800)]),
    ("Rue de la République", "primary", [(4.8322, 45.7585), (4.8340, 45.7620), (4.8358, 45.7650),
                                         (4.8362, 45.7668)]),
    ("Rue Victor Hugo", "secondary", [(4.8300, 45.7570), (4.8288, 45.7535), (4.8276, 45.7500)]),
    ("Cours Lafayette", "primary", [(4.8385, 45.7640), (4.8500, 45.7637), (4.8650, 45.7636), (4.8800, 45.7655)]),
    ("Rue Garibaldi", "primary", [(4.8522, 45.7750), (4.8512, 45.7600), (4.8500, 45.7450)]),
    ("Avenue Jean Jaurès", "secondary", [(4.8410, 45.7530), (4.8420, 45.7400), (4.8410, 45.7300)]),
    ("Avenue Berthelot", "secondary", [(4.8375, 45.7510), (4.8500, 45.7470), (4.8700, 45.7420)]),
    ("Boulevard des Belges", "secondary", [(4.8500, 45.7720), (4.8550, 45.7760), (4.8580, 45.7790)]),
    ("Quai Saint-Antoine", "tertiary", [(4.8305, 45.7620), (4.8302, 45.7640), (4.8300, 45.7660)]),
    ("Quai Claude Bernard", "tertiary", [(4.8390, 45.7560), (4.8380, 45.7525), (4.8370, 45.7490)]),
    ("Montée de la Grande Côte", "residential", [(4.8322, 45.7690), (4.8316, 45.7710), (4.8310, 45.7730)]),
    ("Avenue Félix Faure", "secondary", [(4.8460, 45.7570), (4.8700, 45.7540), (4.8850, 45.7520)]),
    ("Route de Vienne", "primary", [(4.8450, 45.7450), (4.8500, 45.7300), (4.8550, 45.7150), (4.8600, 45.7000)]),
]


def make_roads(out_dir):
    to_l93 = Transformer.from_crs("EPSG:4326", "EPSG:2154", always_xy=True)
    w = shp.ShapeWriter(shp.POLYLINE)
    recs = []
    for name, kind, ctrl in LYON_ROADS:
        step = 120.0 if kind in ("motorway", "trunk") else 40.0

        def n_for(i, a, b):
            return int(haversine_m(a[0], a[1], b[0], b[1]) / step) + 1

        dense = catmull_rom(ctrl, n_for)
        pts = [tuple(round(v, 2) for v in to_l93.transform(lon, lat)) for lon, lat in dense]
        w.add_parts([pts])
        recs.append((name, kind))
    fields = [shp.Field("NAME", "C", 40), shp.Field("KIND", "C", 12)]
    shp.write_shapefile(os.path.join(out_dir, "roads_lambert93"), w, fields, recs, prj=shp.PRJ_LAMBERT93,
                        encoding="cp1252", ldid=0x57)
    return {"records": len(recs)}


# ---------------------------------------------------------------- stations_nad83_ft

BAY_STATIONS = [
    ("Mount Diablo Summit", -121.9142, 37.8816, 3849),
    ("Mount Tamalpais East Peak", -122.5776, 37.9235, 2571),
    ("Twin Peaks", -122.4477, 37.7544, 922),
    ("Coit Tower", -122.4058, 37.8024, 284),
    ("Mount Hamilton", -121.6429, 37.3414, 4209),
    ("Mission Peak", -121.8806, 37.5126, 2517),
    ("Grizzly Peak", -122.2420, 37.8820, 1754),
    ("Mount Umunhum", -121.8984, 37.1608, 3486),
    ("Black Mountain", -122.1478, 37.3197, 2812),
    ("Montara Mountain", -122.4769, 37.5550, 1898),
    ("San Bruno Mountain", -122.4339, 37.6889, 1319),
    ("Mount Davidson", -122.4537, 37.7385, 928),
    ("Oakland Airport", -122.2208, 37.7213, 9),
    ("San Francisco Airport", -122.3750, 37.6190, 13),
    ("San Jose Airport", -121.9290, 37.3626, 62),
    ("Livermore", -121.7680, 37.6819, 495),
    ("Stockton", -121.2908, 37.9577, 13),
    ("Santa Cruz", -122.0308, 36.9741, 20),
    ("Half Moon Bay", -122.4286, 37.4636, 69),
    ("Point Reyes Lighthouse", -123.0232, 37.9955, 265),
]


def make_stations(out_dir):
    to_sp = Transformer.from_crs("EPSG:4326", "EPSG:2227", always_xy=True)
    w = shp.ShapeWriter(shp.POINT)
    recs = []
    for name, lon, lat, elev in BAY_STATIONS:
        x, y = to_sp.transform(lon, lat)
        w.add_point(round(x, 2), round(y, 2))
        recs.append((name, elev))
    fields = [shp.Field("NAME", "C", 32), shp.Field("ELEV_FT", "N", 6)]
    shp.write_shapefile(os.path.join(out_dir, "stations_nad83_ft"), w, fields, recs, prj=shp.PRJ_CA3_FTUS,
                        encoding="cp1252", ldid=0x57)
    return {"records": len(recs)}


# ---------------------------------------------------------------- points_noprj (PointZ)

ALPINE_PEAKS = [
    ("Mont Blanc", "France/Italy", 6.8652, 45.8326, 4808),
    ("Dufourspitze", "Switzerland", 7.8669, 45.9369, 4634),
    ("Dom", "Switzerland", 7.8586, 46.0939, 4545),
    ("Matterhorn", "Switzerland/Italy", 7.6586, 45.9763, 4478),
    ("Jungfrau", "Switzerland", 7.9625, 46.5367, 4158),
    ("Gran Paradiso", "Italy", 7.2661, 45.5181, 4061),
    ("Piz Bernina", "Switzerland", 9.9081, 46.3823, 4049),
    ("Eiger", "Switzerland", 8.0053, 46.5775, 3967),
    ("Grossglockner", "Austria", 12.6939, 47.0742, 3798),
    ("Zugspitze", "Germany/Austria", 10.9863, 47.4211, 2962),
    ("Triglav", "Slovenia", 13.8369, 46.3783, 2864),
]


def make_points_noprj(out_dir):
    w = shp.ShapeWriter(shp.POINTZ)
    recs = []
    for name, country, lon, lat, ele in ALPINE_PEAKS:
        w.add_pointz(lon, lat, float(ele), 0.0)
        recs.append((name, country, ele))
    fields = [shp.Field("NAME", "C", 24), shp.Field("COUNTRY", "C", 24), shp.Field("ELEV_M", "N", 5)]
    shp.write_shapefile(os.path.join(out_dir, "points_noprj"), w, fields, recs, prj=None,
                        encoding="cp1252", ldid=0x57)
    return {"records": len(recs)}


# ---------------------------------------------------------------- cities_shp.zip

def make_cities_zip(ne, out_dir, work_dir):
    src = load_geojson(os.path.join(ne, "ne_110m_populated_places_simple.geojson"))
    w = shp.ShapeWriter(shp.POINT)
    recs = []
    for f in src["features"]:
        lon, lat = f["geometry"]["coordinates"]
        p = f["properties"]
        w.add_point(round(lon, 6), round(lat, 6))
        recs.append((p["name"], p["adm0name"], int(p["pop_max"]), p["featurecla"], bool(p["adm0cap"])))
    fields = [shp.Field("NAME", "C", 48), shp.Field("ADM0NAME", "C", 48), shp.Field("POP_MAX", "N", 10),
              shp.Field("FEATURECLA", "C", 32), shp.Field("CAPITAL", "L", 1)]
    os.makedirs(work_dir, exist_ok=True)
    files = shp.write_shapefile(os.path.join(work_dir, "cities"), w, fields, recs, prj=shp.PRJ_WGS84, cpg="UTF-8")
    order = [".shp", ".shx", ".dbf", ".prj", ".cpg"]
    entries = []
    for ext in order:
        path = os.path.join(work_dir, "cities" + ext)
        entries.append(("cities" + ext, files[path]))
    write_zip(os.path.join(out_dir, "cities_shp.zip"), entries)
    return {"records": len(recs), "members": [e[0] for e in entries]}


# ---------------------------------------------------------------- reprojection reference

REFERENCE_LAYERS = [
    ("parcels_utm33n", 32633, "metre", shp.PRJ_UTM33N),
    ("roads_lambert93", 2154, "metre", shp.PRJ_LAMBERT93),
    ("stations_nad83_ft", 2227, "US survey foot", shp.PRJ_CA3_FTUS),
]


def make_reference(out_dir, scripts_dir):
    ref = {"description": ("First vertex of the first record of each projected shapefile, as stored in the "
                           ".shp (projected CRS units) and converted to WGS84 longitude/latitude with pyproj "
                           "(PROJ) using the EPSG definition. Use it to unit-test the app's own reprojection. "
                           "RGF93 and NAD83 are treated as coincident with WGS84 (PROJ's default, no grid "
                           "shift), so lon/lat equal the datum's own geographic coordinates."),
           "generator": "Fixtures/maps/scripts/make_fixtures.py",
           "layers": {}}
    for base, epsg, unit, prj in REFERENCE_LAYERS:
        with open(os.path.join(out_dir, base + ".shp"), "rb") as fh:
            shp_bytes = fh.read()
        with open(os.path.join(out_dir, base + ".shx"), "rb") as fh:
            shx_bytes = fh.read()
        parsed = shp.read_shp(shp_bytes, shx_bytes)
        x, y = parsed["records"][0][0][0][:2]
        t = Transformer.from_crs(CRS.from_epsg(epsg), CRS.from_epsg(4326), always_xy=True)
        lon, lat = t.transform(x, y)
        # Cross-check: the .prj text itself must describe the same projection.
        t_prj = Transformer.from_crs(CRS.from_wkt(prj), CRS.from_epsg(4326), always_xy=True)
        lon2, lat2 = t_prj.transform(x, y)
        assert abs(lon - lon2) < 1e-8 and abs(lat - lat2) < 1e-8, (base, lon, lon2, lat, lat2)
        ref["layers"][base] = {
            "file": base + ".shp",
            "epsg": epsg,
            "units": unit,
            "projected": {"x": x, "y": y},
            "wgs84": {"lon": round(lon, 9), "lat": round(lat, 9)},
        }
    path = os.path.join(scripts_dir, "shapefile_reference.json")
    write_text(path, json.dumps(ref, indent=2, ensure_ascii=False) + "\n")
    return ref


# ---------------------------------------------------------------- verification

def verify_all(out_dir):
    """Read every shapefile back and check counts, ring winding and dbf contents."""
    report = {}
    sets = [("rivers", "utf-8"), ("parcels_utm33n", "cp1252"), ("roads_lambert93", "cp1252"),
            ("stations_nad83_ft", "cp1252"), ("points_noprj", "cp1252")]
    for base, enc in sets:
        with open(os.path.join(out_dir, base + ".shp"), "rb") as fh:
            s = fh.read()
        with open(os.path.join(out_dir, base + ".shx"), "rb") as fh:
            x = fh.read()
        with open(os.path.join(out_dir, base + ".dbf"), "rb") as fh:
            d = fh.read()
        geo = shp.read_shp(s, x)
        tab = shp.read_dbf(d, enc)
        assert len(geo["records"]) == len(tab["rows"]), base
        if geo["type"] == shp.POLYGON:
            for rec in geo["records"]:
                outer = [r for r in rec if shp.ring_is_clockwise(r)]
                assert outer and rec[0] in outer, "first ring of a polygon record must be an outer ring"
        report[base] = {"shape_type": geo["type"], "records": len(geo["records"]),
                        "fields": [f[0] + ":" + f[1] for f in tab["fields"]], "ldid": tab["ldid"],
                        "bbox": [round(v, 4) for v in geo["bbox"][:4]]}
        if base == "rivers":
            report[base]["sample_name"] = [r["NAME"] for r in tab["rows"] if not r["NAME"].isascii()]
        if base == "roads_lambert93":
            report[base]["sample_name"] = [r["NAME"] for r in tab["rows"] if not r["NAME"].isascii()][:2]
    return report
