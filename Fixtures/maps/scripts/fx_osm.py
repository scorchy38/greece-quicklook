"""Synthetic OSM XML 0.6 neighbourhood near 52.37N, 4.89E (Amsterdam).

Everything is laid out in local metres (x east, y north) and converted to
lon/lat. Street and footway nodes are shared at junctions.
"""

import math
import os
import random
import xml.etree.ElementTree as ET

from fx_common import FIXED_ISO, LocalFrame, write_text, xml_escape

ORIGIN = (4.8830, 52.3660)  # lon, lat of local (0, 0)
NODE_ID0, WAY_ID0, REL_ID0 = 1000001, 2000001, 3000001

NS_STREETS = [  # x, name, highway
    (0, "Molenweg", "secondary"), (120, "Tulpstraat", "residential"), (240, "Lindenstraat", "residential"),
    (360, "Hoofdweg", "primary"), (480, "Rozenstraat", "residential"), (600, "Iepenstraat", "residential"),
    (720, "Parklaan", "residential"),
]
EW_STREETS = [  # y, name, highway, x range
    (0, "Kastanjelaan", "secondary", (0, 720)), (100, "Bakkerstraat", "residential", (0, 720)),
    (190, "Zuidkade", "residential", (0, 720)), (230, "Noordkade", "residential", (0, 720)),
    (320, "Kerkstraat", "residential", (0, 600)), (420, "Noorderweg", "secondary", (0, 720)),
]
CANAL_Y = 210
COLS = [(0, 120), (120, 240), (240, 360), (360, 480), (480, 600), (600, 720)]
ROWS = [(0, 100), (100, 190), (230, 320), (320, 420)]
PARK_BLOCKS = {(5, 2), (5, 3)}
MP_BLOCK = (2, 2)
SPECIAL_BLOCKS = {  # block -> (tags, inset)
    (0, 0): {"building": "yes", "amenity": "school", "name": "Basisschool De Linde"},
    (3, 1): {"building": "yes", "shop": "supermarket", "name": "Buurtsuper Hoofdweg"},
    (1, 3): {"building": "yes", "amenity": "place_of_worship", "religion": "christian", "name": "Lindenkerk"},
    (4, 3): {"building": "yes", "building:levels": "6", "name": "Rozenhof"},
    (0, 2): {"building": "yes", "building:levels": "5", "name": "Kadeflat"},
}
POI_SPECS = [
    {"amenity": "cafe", "name": "Café De Gracht", "opening_hours": "Mo-Su 08:00-23:00"},
    {"amenity": "cafe", "name": "Koffiehuis Lindenstraat"},
    {"amenity": "cafe", "name": "Het Kadecafé", "outdoor_seating": "yes"},
    {"amenity": "cafe", "name": "Espressobar Tulp"},
    {"amenity": "restaurant", "name": "Restaurant De Molen", "cuisine": "dutch"},
    {"amenity": "restaurant", "name": "Trattoria Ponte", "cuisine": "italian"},
    {"amenity": "restaurant", "name": "Eethuis Kerkstraat", "cuisine": "regional"},
    {"amenity": "restaurant", "name": "Noodlebar Noorderweg", "cuisine": "asian"},
    {"amenity": "restaurant", "name": "Visrestaurant De Kade", "cuisine": "seafood"},
    {"amenity": "pub", "name": "Bruin Café 't Hoekje"},
    {"amenity": "pub", "name": "De Gouden Brug"},
    {"shop": "bakery", "name": "Bakkerij Van Dam", "opening_hours": "Tu-Sa 07:00-17:00"},
    {"shop": "bakery", "name": "Brood & Banket Rozenstraat"},
    {"shop": "bakery", "name": "Warme Bakker Molenweg"},
    {"shop": "florist", "name": "Bloemenhuis Iep"},
    {"shop": "bicycle", "name": "Fietsenmaker Kastanje", "service:bicycle:repair": "yes"},
    {"shop": "books", "name": "Boekhandel Het Lindeblad"},
    {"shop": "greengrocer", "name": "Groenteboer Bakkerstraat"},
    {"amenity": "pharmacy", "name": "Apotheek Hoofdweg"},
    {"amenity": "ice_cream", "name": "IJssalon Noordkade"},
]


class OsmBuilder:
    def __init__(self):
        self.frame = LocalFrame(*ORIGIN)
        self.nodes = []  # (id, lon, lat, tags)
        self.ways = []  # (id, [node ids], tags)
        self.rels = []  # (id, [(type, ref, role)], tags)
        self.shared = {}

    def node(self, x, y, tags=None, share=False):
        key = (round(x, 2), round(y, 2))
        if share and key in self.shared:
            nid = self.shared[key]
            if tags:
                self.nodes[nid - NODE_ID0][3].update(tags)
            return nid
        nid = NODE_ID0 + len(self.nodes)
        lon, lat = self.frame.to_lonlat(x, y)
        self.nodes.append((nid, lon, lat, dict(tags or {})))
        if share:
            self.shared[key] = nid
        return nid

    def way(self, refs, tags):
        wid = WAY_ID0 + len(self.ways)
        self.ways.append((wid, refs, dict(tags)))
        return wid

    def relation(self, members, tags):
        rid = REL_ID0 + len(self.rels)
        self.rels.append((rid, members, dict(tags)))
        return rid

    def line(self, pts, step, share=True):
        """Shared nodes every `step` metres along a polyline of (x, y) vertices."""
        refs = []
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            n = max(1, int(round(math.hypot(x1 - x0, y1 - y0) / step)))
            for k in range(n):
                t = k / n
                nid = self.node(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, share=share)
                if not refs or refs[-1] != nid:
                    refs.append(nid)
        nid = self.node(*pts[-1], share=share)
        if refs[-1] != nid:
            refs.append(nid)
        return refs

    def closed(self, pts, tags=None, share=False):
        refs = [self.node(x, y, share=share) for x, y in pts]
        refs.append(refs[0])
        if tags is None:
            return refs
        return self.way(refs, tags)


def _house(x0, x1, y_front, depth, north_side, ell):
    """Footprint (x, y) list; front edge on y_front, extending away from the street."""
    sgn = -1 if north_side else 1  # north-side houses extend southwards
    yb = y_front + sgn * depth
    if not ell:
        return [(x0, y_front), (x1, y_front), (x1, yb), (x0, yb)]
    xm = x0 + (x1 - x0) * 0.55
    ye = yb + sgn * 5.0
    return [(x0, y_front), (x1, y_front), (x1, yb), (xm, yb), (xm, ye), (x0, ye)]


def make_osm(out_dir):
    rng = random.Random(1052)
    b = OsmBuilder()

    # streets (N-S streets split around the canal: the middle piece is a bridge)
    for x, name, hw in NS_STREETS:
        for (ya, yb), extra in (((0, 190), {}), ((190, 230), {"bridge": "yes", "layer": "1"}), ((230, 420), {})):
            tags = {"highway": hw, "name": name}
            if hw == "primary":
                tags.update({"ref": "S100", "maxspeed": "50", "lanes": "2"})
            elif hw == "residential":
                tags["maxspeed"] = "30"
            tags.update(extra)
            b.way(b.line([(x, ya), (x, yb)], 10.0), tags)
    for y, name, hw, (xa, xb) in EW_STREETS:
        tags = {"highway": hw, "name": name}
        if y in (190, 230):
            tags["oneway"] = "yes"
        b.way(b.line([(xa, y), (xb, y)] if y != 230 else [(xb, y), (xa, y)], 10.0), tags)

    # canal: centre line and water area
    b.way(b.line([(0, CANAL_Y), (720, CANAL_Y)], 20.0, share=False), {"waterway": "canal", "name": "Nieuwe Gracht"})
    water = [(0, 197), (180, 197), (360, 197), (540, 197), (720, 197), (720, 223), (540, 223), (360, 223), (180, 223),
             (0, 223)]
    b.closed(water, {"natural": "water", "water": "canal", "name": "Nieuwe Gracht"})

    # park with a pond, footpaths and trees
    park = [(606, 236), (660, 236), (714, 236), (714, 330), (714, 414), (660, 414), (606, 414), (606, 330)]
    b.closed(park, {"leisure": "park", "name": "Lindenpark", "opening_hours": "24/7"})
    pond = [(660 + 28 * math.cos(2 * math.pi * k / 24), 330 + 18 * math.sin(2 * math.pi * k / 24)) for k in range(24)]
    b.closed(pond, {"natural": "water", "water": "pond", "name": "Eendenvijver"})
    f1 = b.line([(600, 280), (618, 285), (622, 330), (630, 365), (660, 372), (700, 380), (720, 390)], 8.0)
    b.way(f1, {"highway": "footway", "name": "Vijverpad", "surface": "gravel"})
    f2 = b.line([(660, 230), (664, 270), (700, 300), (706, 340), (700, 380)], 8.0)
    b.way(f2, {"highway": "footway", "surface": "gravel"})
    for k in range(12):
        tx = rng.uniform(612, 708)
        ty = rng.uniform(242, 408)
        if ((tx - 660) / 34) ** 2 + ((ty - 330) / 24) ** 2 < 1:
            ty = 395.0
        b.node(tx, ty, {"natural": "tree", "leaf_type": "broadleaved", "species": "Tilia europaea"})

    # courtyard building as a multipolygon (outer ring split into two ways)
    x0, x1, y0, y1 = 247, 353, 237, 313
    w_west = b.way(b.line([(300, y0), (x0, y0), (x0, y1), (300, y1)], 15.0, share=True), {})
    w_east = b.way(b.line([(300, y1), (x1, y1), (x1, y0), (300, y0)], 15.0, share=True), {})
    w_in = b.closed([(267, 257), (333, 257), (333, 293), (267, 293)], {})
    b.relation([("way", w_west, "outer"), ("way", w_east, "outer"), ("way", w_in, "inner")],
               {"type": "multipolygon", "building": "yes", "building:levels": "3", "name": "Hofje De Linde",
                "addr:street": "Noordkade", "addr:housenumber": "41", "addr:city": "Amsterdam"})

    # buildings
    house_centres = []
    n_buildings = 0
    next_number = {}  # (street, north side) -> next house number; odd south, even north
    for ci, (bx0, bx1) in enumerate(COLS):
        for ri, (by0, by1) in enumerate(ROWS):
            if (ci, ri) in PARK_BLOCKS or (ci, ri) == MP_BLOCK:
                continue
            if (ci, ri) in SPECIAL_BLOCKS:
                tags = dict(SPECIAL_BLOCKS[(ci, ri)])
                pts = [(bx0 + 12, by0 + 12), (bx1 - 12, by0 + 12), (bx1 - 12, by1 - 30), (bx0 + 60, by1 - 30),
                       (bx0 + 60, by1 - 12), (bx0 + 12, by1 - 12)]
                b.closed(pts, tags)
                n_buildings += 1
                continue
            # one row of terraced houses, alternating between the block's south and north side
            for north in [(ci + ri) % 2 == 1]:
                street = [s for s in EW_STREETS if s[0] == (by1 if north else by0)][0][1]
                y_front = by1 - 7 if north else by0 + 7
                x = bx0 + 7
                number = next_number.get((street, north), 2 if north else 1)
                while x < bx1 - 7 - 8:
                    w = min(rng.uniform(8.5, 13.5), bx1 - 7 - x)
                    depth = rng.uniform(10.0, 13.0)
                    ell = rng.random() < 0.18
                    pts = [(round(px, 2), round(py, 2)) for px, py in _house(x, x + w, y_front, depth, north, ell)]
                    tags = {"building": "yes"}
                    if rng.random() < 0.65:
                        tags.update({"addr:street": street, "addr:housenumber": str(number),
                                     "addr:postcode": "1015 %s" % ("AB" if ri < 2 else "CD"), "addr:city": "Amsterdam"})
                    if rng.random() < 0.3:
                        tags["building:levels"] = str(rng.choice([3, 4, 4, 5]))
                    b.closed(pts, tags)
                    n_buildings += 1
                    house_centres.append((x + w / 2, y_front + (-1 if north else 1) * depth / 2))
                    number += 2
                    x += w
                next_number[(street, north)] = number
    # points of interest, placed inside a spread of houses
    picks = sorted(rng.sample(range(len(house_centres)), len(POI_SPECS)))
    for spec, idx in zip(POI_SPECS, picks):
        hx, hy = house_centres[idx]
        b.node(hx, hy, spec)

    # write XML
    lons = [n[1] for n in b.nodes]
    lats = [n[2] for n in b.nodes]
    pad_lon, pad_lat = 0.0004, 0.0003
    L = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<osm version="0.6" generator="Greece fixture generator (make_fixtures.py)">',
         ' <bounds minlat="%.7f" minlon="%.7f" maxlat="%.7f" maxlon="%.7f"/>'
         % (min(lats) - pad_lat, min(lons) - pad_lon, max(lats) + pad_lat, max(lons) + pad_lon)]
    meta = 'visible="true" version="1" changeset="1" timestamp="%s" user="fixture" uid="1"' % FIXED_ISO

    def tags_xml(tags, indent):
        return ["%s<tag k=\"%s\" v=\"%s\"/>" % (indent, xml_escape(k), xml_escape(v)) for k, v in sorted(tags.items())]

    for nid, lon, lat, tags in b.nodes:
        if tags:
            L.append(' <node id="%d" %s lat="%.7f" lon="%.7f">' % (nid, meta, lat, lon))
            L += tags_xml(tags, "  ")
            L.append(' </node>')
        else:
            L.append(' <node id="%d" %s lat="%.7f" lon="%.7f"/>' % (nid, meta, lat, lon))
    for wid, refs, tags in b.ways:
        L.append(' <way id="%d" %s>' % (wid, meta))
        L += ['  <nd ref="%d"/>' % r for r in refs]
        L += tags_xml(tags, "  ")
        L.append(' </way>')
    for rid, members, tags in b.rels:
        L.append(' <relation id="%d" %s>' % (rid, meta))
        L += ['  <member type="%s" ref="%d" role="%s"/>' % m for m in members]
        L += tags_xml(tags, "  ")
        L.append(' </relation>')
    L.append('</osm>')
    write_text(os.path.join(out_dir, "town.osm"), "\n".join(L) + "\n")
    return {"nodes": len(b.nodes), "ways": len(b.ways), "relations": len(b.rels), "buildings": n_buildings + 1,
            "pois": len(POI_SPECS)}


def verify(out_dir):
    root = ET.parse(os.path.join(out_dir, "town.osm")).getroot()
    assert root.tag == "osm" and root.get("version") == "0.6"
    nodes = {n.get("id"): n for n in root.findall("node")}
    ways = root.findall("way")
    used = set()
    for w in ways:
        refs = [nd.get("ref") for nd in w.findall("nd")]
        assert all(r in nodes for r in refs)
        used.update(refs)
    way_ids = {w.get("id") for w in ways}
    for r in root.findall("relation"):
        for m in r.findall("member"):
            assert m.get("type") == "way" and m.get("ref") in way_ids
    tagged_nodes = [n for n in nodes.values() if n.find("tag") is not None]
    untagged_in_ways = [i for i, n in nodes.items() if n.find("tag") is None and i in used]
    orphans = [i for i, n in nodes.items() if n.find("tag") is None and i not in used]

    def tagdict(e):
        return {t.get("k"): t.get("v") for t in e.findall("tag")}

    buildings = [w for w in ways if "building" in tagdict(w)]
    closed_buildings = [w for w in buildings if w.findall("nd")[0].get("ref") == w.findall("nd")[-1].get("ref")]
    highways = {}
    for w in ways:
        hw = tagdict(w).get("highway")
        if hw:
            highways[hw] = highways.get(hw, 0) + 1
    b = root.find("bounds")
    return {"nodes": len(nodes), "ways": len(ways), "relations": len(root.findall("relation")),
            "building_ways": len(buildings), "closed_building_ways": len(closed_buildings),
            "buildings_with_addr": sum(1 for w in buildings if "addr:street" in tagdict(w)),
            "highway_ways": highways, "tagged_nodes": len(tagged_nodes),
            "untagged_way_nodes": len(untagged_in_ways), "orphan_untagged_nodes": len(orphans),
            "bounds": {k: b.get(k) for k in ("minlat", "minlon", "maxlat", "maxlon")}}
