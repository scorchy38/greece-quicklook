#!/usr/bin/env python3
"""Regenerate every map fixture in Fixtures/maps deterministically.

Usage:
    python3 make_fixtures.py [--ne DIR] [--cache DIR] [--out DIR]

Requirements: Python 3.9+, pyproj and Pillow. mapbox-vector-tile is optional
and only used to decode the vector tiles back as an independent check.

--ne     folder with the Natural Earth GeoJSON layers (ne_110m_*.geojson).
         Missing layers are downloaded from the natural-earth-vector GitHub
         repository into that folder.
--cache  folder for the downloaded TopoJSON files (sha256-checked).
--out    output folder (default: the folder above this script).
"""

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.request

sys.dont_write_bytecode = True  # keep __pycache__ out of the fixtures folder
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)  # helper modules live next to this script (needed under python -I)

import fx_geojson  # noqa: E402
import fx_gpkg  # noqa: E402
import fx_kml  # noqa: E402
import fx_osm  # noqa: E402
import fx_shapes  # noqa: E402
import fx_tiles  # noqa: E402
import fx_tracks  # noqa: E402

NE_BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
NE_LAYERS = ["ne_110m_admin_0_countries", "ne_110m_populated_places_simple", "ne_110m_rivers_lake_centerlines",
             "ne_110m_land", "ne_110m_lakes", "ne_110m_admin_0_boundary_lines_land"]

SHP_SETS = {
    "rivers": [".shp", ".shx", ".dbf", ".prj", ".cpg"],
    "parcels_utm33n": [".shp", ".shx", ".dbf", ".prj"],
    "roads_lambert93": [".shp", ".shx", ".dbf", ".prj"],
    "stations_nad83_ft": [".shp", ".shx", ".dbf", ".prj"],
    "points_noprj": [".shp", ".shx", ".dbf"],
}
OUTPUTS = (["countries.geojson", "cities.json", "rivers.geojsonl", "world.topojson", "us-states-albers.topojson"]
           + [b + e for b, exts in SHP_SETS.items() for e in exts]
           + ["cities_shp.zip", "places.gpkg", "raster.mbtiles", "relief.mbtiles", "vector.mbtiles", "hike.gpx",
              "ride.gpx", "places.kml", "tour.kmz", "town.osm", "shapes.wkt", "single.wkt"])
FILE_LIMIT = 500 * 1000  # bytes; "under 500 KB" read conservatively
TOTAL_LIMIT = 5 * 1000 * 1000


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_natural_earth(ne_dir):
    os.makedirs(ne_dir, exist_ok=True)
    info = {}
    for layer in NE_LAYERS:
        path = os.path.join(ne_dir, layer + ".geojson")
        if not os.path.exists(path):
            print("downloading %s" % layer)
            req = urllib.request.Request(NE_BASE + layer + ".geojson", headers={"User-Agent": "fixture-generator"})
            with urllib.request.urlopen(req, timeout=120) as resp, open(path, "wb") as fh:
                fh.write(resp.read())
        info[layer] = sha256(path)
    return info


def step(label, fn, *args):
    t = time.time()
    result = fn(*args)
    print("  %-34s %6.1fs  %s" % (label, time.time() - t, _short(result)))
    return result


def _short(obj):
    if isinstance(obj, dict):
        obj = {k: v for k, v in obj.items() if k not in ("raw", "encoded")}
    text = json.dumps(obj, ensure_ascii=False, default=str)
    return text if len(text) < 400 else text[:397] + "..."


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ne", default=os.path.join(tempfile.gettempdir(), "greece-map-fixtures", "ne"))
    ap.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "greece-map-fixtures", "cache"))
    ap.add_argument("--out", default=os.path.dirname(HERE))
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    ne = os.path.abspath(args.ne)
    os.makedirs(out, exist_ok=True)

    print("inputs:")
    for layer, digest in ensure_natural_earth(ne).items():
        print("  %-40s sha256 %s" % (layer, digest))
    for name in OUTPUTS:  # remove stale outputs so nothing old survives a rename
        path = os.path.join(out, name)
        if os.path.exists(path):
            os.remove(path)

    print("generating:")
    step("countries.geojson", fx_geojson.make_countries, ne, out)
    step("cities.json", fx_geojson.make_cities, ne, out)
    step("rivers.geojsonl", fx_geojson.make_rivers_geojsonl, ne, out)
    step("world/us-states topojson", fx_geojson.fetch_topojson, args.cache, out)
    step("shapes.wkt, single.wkt", fx_geojson.make_wkt, out)
    step("rivers.shp", fx_shapes.make_rivers, ne, out)
    step("parcels_utm33n.shp", fx_shapes.make_parcels, out)
    step("roads_lambert93.shp", fx_shapes.make_roads, out)
    step("stations_nad83_ft.shp", fx_shapes.make_stations, out)
    step("points_noprj.shp", fx_shapes.make_points_noprj, out)
    with tempfile.TemporaryDirectory() as tmp:
        step("cities_shp.zip", fx_shapes.make_cities_zip, ne, out, tmp)
    ref_dir = os.path.join(out, "scripts")  # == this folder for the default --out
    os.makedirs(ref_dir, exist_ok=True)
    step("scripts/shapefile_reference.json", fx_shapes.make_reference, out, ref_dir)
    step("places.gpkg", fx_gpkg.build, out)
    world = fx_tiles.World(ne)
    step("raster.mbtiles", fx_tiles.make_raster, world, out)
    step("relief.mbtiles", fx_tiles.make_relief, world, out)
    vector = step("vector.mbtiles", fx_tiles.make_vector, world, out)
    step("hike.gpx", fx_tracks.make_hike, out)
    step("ride.gpx", fx_tracks.make_ride, out)
    step("places.kml", fx_kml.make_kml, out)
    step("tour.kmz", fx_kml.make_kmz, out)
    step("town.osm", fx_osm.make_osm, out)

    print("verifying:")
    checks = {
        "shapefiles": fx_shapes.verify_all(out),
        "geopackage": fx_gpkg.verify(out),
        "raster.mbtiles": fx_tiles.verify_images(os.path.join(out, "raster.mbtiles"), "PNG"),
        "relief.mbtiles": fx_tiles.verify_images(os.path.join(out, "relief.mbtiles"), "JPEG"),
        "vector.mbtiles": fx_tiles.verify_vector(os.path.join(out, "vector.mbtiles"), vector),
        "gpx": fx_tracks.verify(out),
        "kml/kmz": fx_kml.verify(out),
        "town.osm": fx_osm.verify(out),
    }
    for name, result in checks.items():
        print("  %-16s %s" % (name, json.dumps(result, ensure_ascii=False, default=str)))

    print("files:")
    total = 0
    rows = []
    for root, dirs, files in os.walk(out):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for f in sorted(files):
            if f == ".DS_Store":
                continue
            path = os.path.join(root, f)
            size = os.path.getsize(path)
            total += size
            rows.append((os.path.relpath(path, out), size))
    for rel, size in rows:
        flag = "" if size < FILE_LIMIT else "   <-- over %d bytes" % FILE_LIMIT
        print("  %-36s %9d bytes  %7.1f KB%s" % (rel, size, size / 1024.0, flag))
    print("  %-36s %9d bytes  %7.1f KB (%d files)" % ("TOTAL", total, total / 1024.0, len(rows)))
    over = [r for r in rows if r[1] >= FILE_LIMIT]
    if over or total >= TOTAL_LIMIT:
        print("SIZE LIMIT EXCEEDED")
        return 1
    print("all files under %d bytes; folder total under %d bytes" % (FILE_LIMIT, TOTAL_LIMIT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
