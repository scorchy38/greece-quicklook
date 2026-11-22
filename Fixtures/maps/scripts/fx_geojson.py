"""GeoJSON, GeoJSON Lines, TopoJSON and WKT fixtures."""

import hashlib
import os
import urllib.request

from fx_common import (dumps, load_geojson, orient, rnd, round_geometry, write_bytes,
                       write_feature_collection, write_text)

TOPOJSON_SOURCES = {
    # output name: (url, sha256 of the published file)
    "world.topojson": ("https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/countries-110m.json",
                       "2516c915867c7baf18ddec727aec46c315541a07cfb3d79a6559b05d5e94eee8"),
    "us-states-albers.topojson": ("https://cdn.jsdelivr.net/npm/us-atlas@3.0.1/states-albers-10m.json",
                                  "6e7bb086a3c791490361968a3094f377f7726c5d0c4900fec03cc42db2305a3d"),
}


def _int_if_whole(v):
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def make_countries(ne, out_dir):
    src = load_geojson(os.path.join(ne, "ne_110m_admin_0_countries.geojson"))
    keep = ["NAME", "NAME_LONG", "CONTINENT", "SUBREGION", "POP_EST", "GDP_MD", "ISO_A3"]
    feats = []
    for f in src["features"]:
        props = {k: _int_if_whole(f["properties"][k]) for k in keep}
        feats.append({"type": "Feature", "properties": props, "geometry": round_geometry(f["geometry"], 4)})
    path = os.path.join(out_dir, "countries.geojson")
    write_feature_collection(path, feats)
    return {"features": len(feats)}


def make_cities(ne, out_dir):
    src = load_geojson(os.path.join(ne, "ne_110m_populated_places_simple.geojson"))
    feats = []
    for f in src["features"]:
        p = f["properties"]
        props = {"name": p["name"], "adm0name": p["adm0name"], "pop_max": _int_if_whole(p["pop_max"]),
                 "featurecla": p["featurecla"]}
        feats.append({"type": "Feature", "properties": props, "geometry": round_geometry(f["geometry"], 6)})
    write_feature_collection(os.path.join(out_dir, "cities.json"), feats)
    return {"features": len(feats)}


def make_rivers_geojsonl(ne, out_dir):
    src = load_geojson(os.path.join(ne, "ne_110m_rivers_lake_centerlines.geojson"))
    lines = []
    for f in src["features"]:
        p = f["properties"]
        feat = {"type": "Feature",
                "properties": {"name": p["name"], "featurecla": p["featurecla"], "scalerank": p["scalerank"]},
                "geometry": round_geometry(f["geometry"], 5)}
        lines.append(dumps(feat))
    write_text(os.path.join(out_dir, "rivers.geojsonl"), "\n".join(lines) + "\n")
    return {"features": len(lines)}


def fetch_topojson(cache_dir, out_dir):
    os.makedirs(cache_dir, exist_ok=True)
    info = {}
    for name, (url, sha) in TOPOJSON_SOURCES.items():
        cached = os.path.join(cache_dir, url.rsplit("/", 2)[-2] + "_" + url.rsplit("/", 1)[-1])
        if not os.path.exists(cached):
            req = urllib.request.Request(url, headers={"User-Agent": "fixture-generator"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                write_bytes(cached, resp.read())
        with open(cached, "rb") as fh:
            data = fh.read()
        got = hashlib.sha256(data).hexdigest()
        if got != sha:
            raise RuntimeError("%s: sha256 %s does not match expected %s" % (cached, got, sha))
        write_bytes(os.path.join(out_dir, name), data)
        info[name] = {"source": url, "sha256": got}
    return info


# ---------------------------------------------------------------- WKT

def _fmt(v):
    return ("%.6f" % v).rstrip("0").rstrip(".")


def _pt(p):
    return " ".join(_fmt(c) for c in p)


def _seq(points):
    return "(" + ", ".join(_pt(p) for p in points) + ")"


def _poly(rings):
    return "(" + ", ".join(_seq(r) for r in rings) + ")"


# Berlin, lon/lat (approximate public landmark positions).
TIERGARTEN = [(13.3375, 52.5145), (13.3500, 52.5102), (13.3655, 52.5098), (13.3748, 52.5118),
              (13.3768, 52.5158), (13.3742, 52.5196), (13.3620, 52.5206), (13.3465, 52.5190),
              (13.3372, 52.5172)]
NEUER_SEE = [(13.3440, 52.5130), (13.3482, 52.5125), (13.3501, 52.5136), (13.3475, 52.5145),
             (13.3445, 52.5142)]
MUSEUMSINSEL = [(13.3955, 52.5225), (13.3990, 52.5182), (13.4040, 52.5168), (13.4030, 52.5190),
                (13.3990, 52.5230)]
TEMPELHOF = [(13.3860, 52.4780), (13.3940, 52.4700), (13.4110, 52.4690), (13.4200, 52.4740),
             (13.4170, 52.4810), (13.4000, 52.4830)]
TEMPELHOF_HOLE = [(13.3980, 52.4790), (13.4040, 52.4795), (13.4045, 52.4765), (13.3985, 52.4760)]


def _ring(points, ccw):
    r = orient(points, ccw)
    return r + [r[0]]


def make_wkt(out_dir):
    tier = _ring(TIERGARTEN, True)
    see = _ring(NEUER_SEE, False)
    musi = _ring(MUSEUMSINSEL, True)
    temp = _ring(TEMPELHOF, True)
    temp_hole = _ring(TEMPELHOF_HOLE, False)
    landmarks = [(13.377704, 52.516275), (13.409419, 52.520817), (13.350139, 52.514543)]
    linden = [(13.3777, 52.5163), (13.3830, 52.5170), (13.3888, 52.5176), (13.3946, 52.5180),
              (13.3990, 52.5185)]
    spree = [(13.3655, 52.5205), (13.3760, 52.5218), (13.3870, 52.5205), (13.3962, 52.5216),
             (13.4040, 52.5185), (13.4110, 52.5140)]
    kanal = [(13.3540, 52.5045), (13.3700, 52.5030), (13.3860, 52.4995), (13.4050, 52.4970),
             (13.4210, 52.4950)]
    lines = [
        "POINT (%s)" % _pt(landmarks[0]),
        "POINT Z (13.409419 52.520817 368)",
        "LINESTRING %s" % _seq(linden),
        "POLYGON %s" % _poly([tier, see]),
        "MULTIPOINT (%s)" % ", ".join("(%s)" % _pt(p) for p in landmarks),
        "MULTIPOINT (%s)" % ", ".join(_pt(p) for p in landmarks),
        "MULTILINESTRING (%s, %s)" % (_seq(spree), _seq(kanal)),
        "MULTIPOLYGON (%s, %s)" % (_poly([musi]), _poly([temp, temp_hole])),
        "GEOMETRYCOLLECTION (POINT (13.4050 52.5200), LINESTRING %s, POLYGON %s)" % (_seq(linden[:3]), _poly([musi])),
        "POINT EMPTY",
        "SRID=4326;LINESTRING(%s)" % ",".join(_pt(p) for p in [landmarks[0], landmarks[1]]),
        "LINESTRING Z (13.3777 52.5163 34, 13.3888 52.5176 36, 13.3990 52.5185 38)",
    ]
    write_text(os.path.join(out_dir, "shapes.wkt"), "\n".join(lines) + "\n")

    # single.wkt: one MULTIPOLYGON, pretty-printed.
    def block(rings, indent):
        pad = " " * indent
        inner = ",\n".join(pad + "    (" + ", ".join(_pt(p) for p in r) + ")" for r in rings)
        return pad + "(\n" + inner + "\n" + pad + ")"

    single = "MULTIPOLYGON (\n" + ",\n".join([block([tier, see], 4), block([musi], 4), block([temp, temp_hole], 4)]) + "\n)\n"
    write_text(os.path.join(out_dir, "single.wkt"), single)
    return {"lines": len(lines)}
