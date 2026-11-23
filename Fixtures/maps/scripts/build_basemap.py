#!/usr/bin/env python3
"""Builds Greece's offline basemap (GreeceKit/Resources/Web/modules/maps-basemap.bin) from
Natural Earth 1:50m GeoJSON (public domain, https://www.naturalearthdata.com).

    build_basemap.py <natural-earth-geojson-dir> <out.bin>

Needs: ne_50m_land, ne_50m_lakes, ne_50m_admin_0_boundary_lines_land,
ne_50m_admin_1_states_provinces_lines, ne_50m_rivers_lake_centerlines, ne_50m_admin_0_countries
(from https://github.com/nvkelso/natural-earth-vector/tree/master/geojson).

Format (little-endian varints, coordinates in thousandths of a degree):
    "GRBM" u8 version(1) u8 layerCount
    layer: u8 nameLength, name, u8 kind (1 polygons, 2 lines, 3 labels), varint featureCount
      polygons/lines feature: u8 rank, varint partCount, then per part varint pointCount and
        zigzag-varint deltas (x, y) continuing from the previous point (starting at 0,0 per feature).
        A polygon feature is one polygon: its first ring is the outer ring (counter-clockwise), the
        rest are holes (clockwise).
      labels feature: u8 rank, varint nameLength, name, zigzag-varint x, y (absolute)
The same file is decoded by maps.js (previews) and Basemap.swift (thumbnails).
"""
import json, os, sys

SCALE = 1000


def varint(n, out):
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def zigzag(n):
    return (n << 1) ^ (n >> 63)


def quantize(ring):
    result = []
    for x, y, *_ in ring:
        q = (round(x * SCALE), round(y * SCALE))
        if not result or result[-1] != q:
            result.append(q)
    return result


def signed_area(ring):
    s = 0
    for i in range(len(ring) - 1):
        s += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
    return s / 2


def oriented(ring, ccw):
    if (signed_area(ring) > 0) != ccw:
        return list(reversed(ring))
    return ring


def write_parts(parts, rank, out):
    out.append(max(0, min(255, int(rank))))
    varint(len(parts), out)
    px, py = 0, 0
    for part in parts:
        varint(len(part), out)
        for x, y in part:
            varint(zigzag(x - px), out)
            varint(zigzag(y - py), out)
            px, py = x, y


def polygons(path, rank_key=None, keep=lambda p: True):
    features = []
    for f in json.load(open(path))['features']:
        g = f.get('geometry')
        props = f.get('properties') or {}
        if not g or not keep(props):
            continue
        rank = props.get(rank_key, 0) if rank_key else 0
        polys = [g['coordinates']] if g['type'] == 'Polygon' else g['coordinates'] if g['type'] == 'MultiPolygon' else []
        for poly in polys:
            rings = []
            for i, ring in enumerate(poly):
                q = quantize(ring)
                if len(q) < 4:
                    continue
                if q[0] != q[-1]:
                    q.append(q[0])
                rings.append(oriented(q, ccw=(i == 0)))
            if rings:
                features.append((rings, rank))
    return features


def lines(path, rank_key=None, keep=lambda p: True):
    features = []
    for f in json.load(open(path))['features']:
        g = f.get('geometry')
        props = f.get('properties') or {}
        if not g or not keep(props):
            continue
        rank = props.get(rank_key, 0) if rank_key else 0
        parts = [g['coordinates']] if g['type'] == 'LineString' else g['coordinates'] if g['type'] == 'MultiLineString' else []
        parts = [q for q in (quantize(p) for p in parts) if len(q) >= 2]
        if parts:
            features.append((parts, rank))
    return features


def main():
    source, output = sys.argv[1], sys.argv[2]
    p = lambda name: os.path.join(source, name + '.geojson')
    layers = [
        ('land', 1, polygons(p('ne_50m_land'))),
        ('lakes', 1, polygons(p('ne_50m_lakes'), 'min_zoom', keep=lambda props: props.get('featurecla') != 'Reservoir' or props.get('scalerank', 9) <= 3)),
        ('rivers', 2, lines(p('ne_50m_rivers_lake_centerlines'), 'min_zoom')),
        ('states', 2, lines(p('ne_50m_admin_1_states_provinces_lines'), 'MIN_ZOOM')),
        ('borders', 2, lines(p('ne_50m_admin_0_boundary_lines_land'), 'MIN_ZOOM')),
    ]
    labels = []
    for f in json.load(open(p('ne_50m_admin_0_countries')))['features']:
        props = f['properties']
        name = props.get('NAME') or ''
        x, y = props.get('LABEL_X'), props.get('LABEL_Y')
        if name and x is not None and y is not None:
            labels.append((name, round(x * SCALE), round(y * SCALE), props.get('MIN_LABEL', 5)))

    out = bytearray(b'GRBM')
    out.append(1)
    out.append(len(layers) + 1)
    for name, kind, features in layers:
        out.append(len(name))
        out += name.encode()
        out.append(kind)
        varint(len(features), out)
        for parts, rank in features:
            write_parts(parts, round(float(rank or 0) * 10), out)
        print(f'{name:8s} {len(features):5d} features {sum(len(r) for parts, _ in features for r in parts):7d} points')
    out.append(len('countries'))
    out += b'countries'
    out.append(3)
    varint(len(labels), out)
    for name, x, y, rank in sorted(labels, key=lambda l: l[3]):
        out.append(max(0, min(255, round(float(rank) * 10))))
        encoded = name.encode()
        varint(len(encoded), out)
        out += encoded
        varint(zigzag(x), out)
        varint(zigzag(y), out)
    open(output, 'wb').write(out)
    print(f'{len(out):,} bytes -> {output}')


if __name__ == '__main__':
    main()
