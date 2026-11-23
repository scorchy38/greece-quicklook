#!/usr/bin/env python3
"""Write a large synthetic GeoJSON FeatureCollection for performance testing.

Usage:
    python3 make_large.py OUT.geojson [COUNT] [--seed N]

COUNT defaults to 100000. The mix is about 60% points, 25% short linestrings
and 15% small polygons, spread over Europe (clustered around major cities with
some uniform scatter). Every feature has 4-6 properties. Output is streamed,
deterministic for a given seed, and needs only the Python standard library.
Do not write the output into Fixtures/ (100k features is roughly 30 MB).
"""

import argparse
import json
import math
import random

CITIES = [  # lon, lat
    (-0.13, 51.51), (2.35, 48.86), (13.40, 52.52), (-3.70, 40.42), (12.50, 41.90), (16.37, 48.21),
    (4.90, 52.37), (4.35, 50.85), (21.01, 52.23), (14.42, 50.09), (19.04, 47.50), (23.73, 37.98),
    (-9.14, 38.72), (18.07, 59.33), (10.75, 59.91), (12.57, 55.68), (24.94, 60.17), (-6.26, 53.35),
    (8.54, 47.38), (11.58, 48.14), (9.19, 45.46), (2.17, 41.39), (-0.38, 39.47), (5.37, 43.30),
    (4.84, 45.76), (6.96, 50.94), (8.68, 50.11), (9.99, 53.55), (26.10, 44.43), (23.32, 42.70),
    (20.46, 44.82), (15.98, 45.81), (14.51, 46.06), (17.11, 48.15), (25.28, 54.69), (24.11, 56.95),
    (24.75, 59.44), (-2.24, 53.48), (-4.25, 55.86), (14.27, 40.85),
]
CATEGORIES = ["cafe", "school", "park", "station", "museum", "hospital", "shop", "hotel", "office", "farm"]
SYLLABLES = ["ber", "lin", "ma", "dor", "sta", "ven", "ka", "ri", "mon", "to", "va", "len", "bur", "gen", "o",
             "sa", "ne", "vik", "hal", "ros"]


def _pt(rng):
    if rng.random() < 0.7:
        lon, lat = rng.choice(CITIES)
        return lon + rng.gauss(0, 0.6), lat + rng.gauss(0, 0.4)
    return rng.uniform(-10.0, 30.0), rng.uniform(36.0, 60.0)


def _name(rng):
    n = "".join(rng.choice(SYLLABLES) for _ in range(rng.randint(2, 4)))
    return n.capitalize() + " " + rng.choice(["Nord", "Süd", "Ost", "West", "Centre", "Park", "Hof", "Ring"])


def _r(v):
    return round(v, 6)


def feature(i, rng):
    kind = rng.random()
    lon, lat = _pt(rng)
    k = math.cos(math.radians(lat))
    if kind < 0.60:
        geom = {"type": "Point", "coordinates": [_r(lon), _r(lat)]}
    elif kind < 0.85:
        n = rng.randint(3, 8)
        heading = rng.uniform(0, 2 * math.pi)
        coords = [[_r(lon), _r(lat)]]
        for _ in range(n - 1):
            heading += rng.gauss(0, 0.5)
            step_km = rng.uniform(0.1, 0.8)
            lon += step_km * math.cos(heading) / (111.32 * k)
            lat += step_km * math.sin(heading) / 110.57
            coords.append([_r(lon), _r(lat)])
        geom = {"type": "LineString", "coordinates": coords}
    else:
        n = rng.randint(5, 10)
        radius_km = rng.uniform(0.1, 0.8)
        ring = []
        for j in range(n):  # counter-clockwise, as RFC 7946 recommends for exterior rings
            a = 2 * math.pi * j / n
            r = radius_km * rng.uniform(0.7, 1.0)
            ring.append([_r(lon + r * math.cos(a) / (111.32 * k)), _r(lat + r * math.sin(a) / 110.57)])
        ring.append(list(ring[0]))
        geom = {"type": "Polygon", "coordinates": [ring]}
    props = {"id": i + 1, "name": _name(rng), "category": rng.choice(CATEGORIES),
             "value": round(rng.lognormvariate(3, 1), 3)}
    if rng.random() < 0.7:
        props["active"] = rng.random() < 0.8
    if rng.random() < 0.5:
        props["created"] = "20%02d-%02d-%02d" % (rng.randint(10, 25), rng.randint(1, 12), rng.randint(1, 28))
    return {"type": "Feature", "id": i + 1, "properties": props, "geometry": geom}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("count", nargs="?", type=int, default=100000)
    ap.add_argument("--seed", type=int, default=20250101)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    kinds = {}
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write('{"type":"FeatureCollection","features":[\n')
        for i in range(args.count):
            f = feature(i, rng)
            kinds[f["geometry"]["type"]] = kinds.get(f["geometry"]["type"], 0) + 1
            fh.write(json.dumps(f, ensure_ascii=False, separators=(",", ":")))
            fh.write(",\n" if i < args.count - 1 else "\n")
        fh.write("]}\n")
    print("wrote %d features to %s: %s" % (args.count, args.out, kinds))


if __name__ == "__main__":
    main()
