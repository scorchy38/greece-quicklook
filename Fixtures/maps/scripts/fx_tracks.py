"""Synthetic GPX tracks: a loop hike above Zermatt (GPX 1.1 with Garmin heart
rate) and a bike ride from Zwolle to Deventer (GPX 1.0 with speed/course)."""

import datetime as dt
import math
import os
import random
import xml.etree.ElementTree as ET

from fx_common import LocalFrame, catmull_rom, haversine_m, write_text, xml_escape

# ---------------------------------------------------------------- shared path helpers


def _densify(frame, ctrl_lonlat, step):
    """Catmull-Rom through control points (lon, lat, extra...) in local metres."""
    pts = [frame.to_xy(c[0], c[1]) + tuple(c[2:]) for c in ctrl_lonlat]

    def n_for(i, a, b):
        return max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) / step))

    return catmull_rom(pts, n_for)


def _cumdist(xy):
    s = [0.0]
    for a, b in zip(xy, xy[1:]):
        s.append(s[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    return s


def _offset_path(xy, s, offset_fn):
    """Displace each centreline point sideways by offset_fn(s, i) metres."""
    out = []
    n = len(xy)
    for i in range(n):
        a = xy[max(0, i - 1)]
        b = xy[min(n - 1, i + 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / ln, dx / ln
        o = offset_fn(s[i], i)
        out.append((xy[i][0] + nx * o, xy[i][1] + ny * o))
    return out


def _smooth(values, window):
    half = window // 2
    out = []
    pref = [0.0]
    for v in values:
        pref.append(pref[-1] + v)
    for i in range(len(values)):
        a, b = max(0, i - half), min(len(values), i + half + 1)
        out.append((pref[b] - pref[a]) / (b - a))
    return out


def _interp_at(s_list, values, s):
    """Linear interpolation of values (list of tuples or floats) at distance s."""
    lo, hi = 0, len(s_list) - 1
    if s <= s_list[0]:
        return values[0]
    if s >= s_list[-1]:
        return values[-1]
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if s_list[mid] <= s:
            lo = mid
        else:
            hi = mid
    t = (s - s_list[lo]) / ((s_list[hi] - s_list[lo]) or 1.0)
    a, b = values[lo], values[hi]
    if isinstance(a, tuple):
        return tuple(x + (y - x) * t for x, y in zip(a, b))
    return a + (b - a) * t


def _iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def track_stats(points):
    """points: list of (lon, lat, ele, time) -> distance m, ascent m, descent m."""
    dist = asc = desc = 0.0
    for a, b in zip(points, points[1:]):
        dist += haversine_m(a[0], a[1], b[0], b[1])
        d = b[2] - a[2]
        if d > 0:
            asc += d
        else:
            desc -= d
    return dist, asc, desc


# ---------------------------------------------------------------- hike.gpx (GPX 1.1)

ZERMATT = (7.7476, 46.0199)
HIKE_UP = [  # lon, lat, ele (m)
    (7.7476, 46.0199, 1608),  # Zermatt, church square
    (7.7540, 46.0210, 1640),  # Wiesti
    (7.7640, 46.0155, 1820),  # Ried
    (7.7700, 46.0145, 1940),
    (7.7768, 46.0118, 2051),  # Findeln
    (7.7840, 46.0135, 2200),
    (7.7915, 46.0143, 2334),  # Grindjisee
    (7.7975, 46.0158, 2460),
    (7.8030, 46.0171, 2537),  # Stellisee (high point)
]
HIKE_DOWN = [
    (7.8030, 46.0171, 2537),
    (7.8040, 46.0130, 2440),
    (7.8010, 46.0085, 2300),  # Grünsee
    (7.7930, 46.0072, 2200),
    (7.7840, 46.0080, 2100),
    (7.7745, 46.0090, 2000),  # Eggen
    (7.7660, 46.0085, 1840),
    (7.7553, 46.0122, 1672),  # Winkelmatten
    (7.7495, 46.0195, 1606),  # bridge over the Vispa
    (7.7476, 46.0199, 1608),
]
HIKE_WAYPOINTS = [  # name, lon, lat, ele, sym, desc
    ("Zermatt", 7.7476, 46.0199, 1608, "Trail Head", "Start and finish at the church square."),
    ("Findeln", 7.7768, 46.0115, 2051, "Restaurant", "Hamlet with mountain restaurants."),
    ("Stellisee", 7.8030, 46.0171, 2537, "Scenic Area", "High point; 20 minute break with Matterhorn view."),
    ("Grünsee", 7.8010, 46.0085, 2300, "Swimming Area", "Small lake on the descent."),
]
HIKE_START = dt.datetime(2024, 7, 14, 7, 10, 0)
HIKE_MOVING_S = 4 * 3600 + 40 * 60
HIKE_STOP_S = 20 * 60
HIKE_DT = 11  # seconds between recorded points


def _hike_leg(frame, ctrl, rng, phase):
    dense = _densify(frame, ctrl, 4.0)  # (x, y, ele)
    xy = [(p[0], p[1]) for p in dense]
    s = _cumdist(xy)
    ele_c = _smooth([p[2] for p in dense], 31)
    # grade along the centreline drives the switchback amplitude
    grade = []
    for i in range(len(xy)):
        a, b = max(0, i - 10), min(len(xy) - 1, i + 10)
        grade.append(abs(ele_c[b] - ele_c[a]) / ((s[b] - s[a]) or 1.0))
    grade = _smooth(grade, 41)

    # Irregular meander: a few incommensurate waves with random phases.
    meander = [(rng.uniform(70, 110), rng.uniform(3, 6), rng.uniform(0, 2 * math.pi)),
               (rng.uniform(190, 260), rng.uniform(8, 14), rng.uniform(0, 2 * math.pi)),
               (rng.uniform(420, 560), rng.uniform(16, 26), rng.uniform(0, 2 * math.pi)),
               (rng.uniform(900, 1300), rng.uniform(25, 40), rng.uniform(0, 2 * math.pi))]
    # Hairpin switchbacks on steep stretches: a triangle wave whose period and
    # amplitude drift slowly, so the zigzags are not uniform.
    period_wave = (rng.uniform(300, 700), rng.uniform(0, 2 * math.pi))
    amp_wave = (rng.uniform(250, 500), rng.uniform(0, 2 * math.pi))
    zig = []
    ph = phase
    for i, si in enumerate(s):
        lam = 150.0 + 40.0 * math.sin(2 * math.pi * si / period_wave[0] + period_wave[1])
        if i:
            ph += 2 * math.pi * (si - s[i - 1]) / lam
        zig.append(2 / math.pi * math.asin(math.sin(ph)))

    def offset(si, i):
        m = sum(a * math.sin(2 * math.pi * si / lam + p) for lam, a, p in meander)
        steep = max(0.0, min(1.0, (grade[i] - 0.10) / 0.08))
        amp = steep * (42.0 + 16.0 * math.sin(2 * math.pi * si / amp_wave[0] + amp_wave[1]))
        # fade in/out at the leg ends so both legs meet the control points
        fade = min(1.0, si / 150.0, (s[-1] - si) / 150.0)
        return fade * (m + amp * zig[i])

    raw = _offset_path(xy, s, offset)
    # round off the hairpin corners a little
    path = list(zip(_smooth([p[0] for p in raw], 5), _smooth([p[1] for p in raw], 5)))
    path_s = _cumdist(path)
    # elevation: centreline profile + gentle terrain undulation
    ele = []
    for i, si in enumerate(path_s):
        e = ele_c[i] + 1.6 * math.sin(si / 230.0 * 2 * math.pi + phase) + 0.7 * math.sin(si / 97.0 * 2 * math.pi)
        ele.append(e)
    return path, path_s, ele


def _tobler(grade):
    return 6.0 * math.exp(-3.5 * abs(grade + 0.05)) / 3.6  # m/s


def _hike_times(path_s, ele):
    """Raw (unscaled) cumulative times along the path from Tobler's function."""
    t = [0.0]
    for i in range(1, len(path_s)):
        ds = path_s[i] - path_s[i - 1]
        g = (ele[i] - ele[i - 1]) / (ds or 1.0)
        t.append(t[-1] + ds / _tobler(max(-0.6, min(0.6, g))))
    return t


def make_hike(out_dir):
    rng = random.Random(4478)
    frame = LocalFrame(*ZERMATT)
    up = _hike_leg(frame, HIKE_UP, rng, 0.3)
    down = _hike_leg(frame, HIKE_DOWN, rng, 1.7)
    t_up = _hike_times(up[1], up[2])
    t_down = _hike_times(down[1], down[2])
    k = HIKE_MOVING_S / (t_up[-1] + t_down[-1])
    legs = []
    for (path, path_s, ele), traw in ((up, t_up), (down, t_down)):
        legs.append((path, ele, [v * k for v in traw]))

    segments = []
    hr = 78.0
    nx = ny = 0.0
    clock = 0.0
    for li, (path, ele, times) in enumerate(legs):
        seg = []
        total = times[-1]
        n = int(total // HIKE_DT)
        sample_t = [j * HIKE_DT for j in range(n + 1)]
        if total - sample_t[-1] > 1.0:
            sample_t.append(total)
        prev = None
        if li == 1:
            hr = 88.0
        for ts in sample_t:
            x, y = _interp_at(times, path, ts)
            e = _interp_at(times, ele, ts)
            nx = 0.8 * nx + rng.gauss(0, 0.7)
            ny = 0.8 * ny + rng.gauss(0, 0.7)
            lon, lat = frame.to_lonlat(x + nx, y + ny)
            e += rng.gauss(0, 0.25)
            if prev is not None:
                dts = ts - prev[0]
                vs = (e - prev[1]) / dts if dts else 0.0
                vh = math.hypot(x - prev[2], y - prev[3]) / dts if dts else 0.0
                target = 92 + 9 * vh + 520 * max(vs, 0.0) + 40 * max(-vs, 0.0)
                hr += (target - hr) * (1 - math.exp(-dts / 45.0))
            prev = (ts, e, x, y)
            bpm = int(round(max(60, min(185, hr + rng.gauss(0, 1.5)))))
            when = HIKE_START + dt.timedelta(seconds=round(clock + ts))
            seg.append((round(lon, 7), round(lat, 7), round(e, 1), when, bpm))
        segments.append(seg)
        clock += times[-1] + (HIKE_STOP_S if li == 0 else 0)

    all_pts = [(p[0], p[1], p[2], p[3]) for seg in segments for p in seg]
    lats = [p[1] for p in all_pts]
    lons = [p[0] for p in all_pts]
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<gpx version="1.1" creator="Greece fixture generator (make_fixtures.py)"',
             '     xmlns="http://www.topografix.com/GPX/1/1"',
             '     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"',
             '     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
             '     xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd '
             'http://www.garmin.com/xmlschemas/TrackPointExtension/v1 '
             'http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd">',
             '  <metadata>',
             '    <name>Zermatt Lakes Loop</name>',
             '    <desc>Synthetic loop hike from Zermatt via Ried, Findeln, Grindjisee, Stellisee and Grünsee. '
             'Generated for testing; not a recorded activity.</desc>',
             '    <author><name>Greece fixtures</name></author>',
             '    <time>%s</time>' % _iso(HIKE_START),
             '    <bounds minlat="%.7f" minlon="%.7f" maxlat="%.7f" maxlon="%.7f"/>' % (min(lats), min(lons), max(lats), max(lons)),
             '  </metadata>']
    for name, lon, lat, ele, sym, desc in HIKE_WAYPOINTS:
        lines.append('  <wpt lat="%.6f" lon="%.6f"><ele>%d</ele><name>%s</name><desc>%s</desc><sym>%s</sym></wpt>'
                     % (lat, lon, ele, xml_escape(name), xml_escape(desc), xml_escape(sym)))
    lines += ['  <trk>', '    <name>Zermatt Lakes Loop</name>', '    <type>hiking</type>']
    for seg in segments:
        lines.append('    <trkseg>')
        for lon, lat, e, when, bpm in seg:
            lines.append('      <trkpt lat="%.7f" lon="%.7f"><ele>%.1f</ele><time>%s</time><extensions>'
                         '<gpxtpx:TrackPointExtension><gpxtpx:hr>%d</gpxtpx:hr></gpxtpx:TrackPointExtension>'
                         '</extensions></trkpt>' % (lat, lon, e, _iso(when), bpm))
        lines.append('    </trkseg>')
    lines += ['  </trk>', '</gpx>']
    write_text(os.path.join(out_dir, "hike.gpx"), "\n".join(lines) + "\n")

    dist, asc, desc = track_stats(all_pts)
    hrs = [p[4] for seg in segments for p in seg]
    return {"points": len(all_pts), "segments": [len(s) for s in segments], "distance_km": round(dist / 1000, 2),
            "ascent_m": round(asc), "descent_m": round(desc),
            "duration": str(all_pts[-1][3] - all_pts[0][3]),
            "gap_between_segments": str(segments[1][0][3] - segments[0][-1][3]),
            "ele_range": (min(p[2] for p in all_pts), max(p[2] for p in all_pts)),
            "hr_range": (min(hrs), max(hrs)), "start": _iso(all_pts[0][3]), "end": _iso(all_pts[-1][3])}


# ---------------------------------------------------------------- ride.gpx (GPX 1.0)

RIDE_ROUTE = [  # lat, lon, name, ele (m)
    (52.5126, 6.0915, "Zwolle, Grote Markt", 2.0),
    (52.5040, 6.0925, "Zwolle, Station", 1.5),
    (52.4960, 6.1010, "Assendorp", 1.0),
    (52.4850, 6.1100, "Knooppunt 12", 0.5),
    (52.4720, 6.1110, "Knooppunt 14", 1.0),
    (52.4590, 6.1060, "Windesheim", 2.0),
    (52.4470, 6.1130, "Knooppunt 17", 2.5),
    (52.4350, 6.1180, "Knooppunt 18", 3.0),
    (52.4260, 6.1160, "Herxen", 3.5),
    (52.4150, 6.1250, "Knooppunt 21", 3.5),
    (52.4020, 6.1310, "Knooppunt 22", 4.0),
    (52.3880, 6.1330, "Wijhe", 4.5),
    (52.3850, 6.1650, "Knooppunt 24", 5.0),
    (52.3700, 6.1550, "Knooppunt 25", 5.5),
    (52.3640, 6.1180, "Fortmond", 4.5),
    (52.3510, 6.1150, "Knooppunt 29", 5.0),
    (52.3380, 6.1110, "Olst", 5.0),
    (52.3330, 6.1350, "Knooppunt 33", 6.0),
    (52.3250, 6.1600, "Knooppunt 34", 7.0),
    (52.3150, 6.1820, "Knooppunt 35", 8.0),
    (52.3050, 6.1980, "Wesepe", 9.0),
    (52.2900, 6.1850, "Knooppunt 38", 8.5),
    (52.2780, 6.1720, "Knooppunt 39", 7.5),
    (52.2680, 6.1640, "Deventer, Noord", 7.0),
    (52.2535, 6.1600, "Deventer, Brink", 8.0),
]
RIDE_TOWNS = {"Zwolle, Grote Markt", "Zwolle, Station", "Windesheim", "Wijhe", "Olst", "Wesepe",
              "Deventer, Noord", "Deventer, Brink"}
RIDE_START = dt.datetime(2024, 5, 11, 8, 30, 0)
RIDE_DT = 5


def make_ride(out_dir):
    rng = random.Random(1222)
    frame = LocalFrame(6.12, 52.38)
    ctrl = [(lon, lat, ele) for lat, lon, _, ele in RIDE_ROUTE]
    dense = _densify(frame, ctrl, 10.0)
    xy = [(p[0], p[1]) for p in dense]
    s = _cumdist(xy)
    path = _offset_path(xy, s, lambda si, i: 55.0 * math.sin(2 * math.pi * si / 1300.0)
                        + 25.0 * math.sin(2 * math.pi * si / 410.0 + 1.0))
    ps = _cumdist(path)
    ele_c = [p[2] for p in dense]
    town_xy = [frame.to_xy(lon, lat) for lat, lon, name, _ in RIDE_ROUTE if name in RIDE_TOWNS]

    # speed profile along the path (m/s): cruising 23-27 km/h, slower in towns
    speed = []
    for i, (x, y) in enumerate(path):
        si = ps[i]
        v = (25.0 + 1.6 * math.sin(2 * math.pi * si / 5200.0) + 0.8 * math.sin(2 * math.pi * si / 1700.0 + 0.4)) / 3.6
        dtown = min(math.hypot(x - tx, y - ty) for tx, ty in town_xy)
        if dtown < 500:
            v *= 0.55 + 0.45 * (dtown / 500.0)
        speed.append(max(v, 2.0))
    speed = _smooth(speed, 15)
    speed[0] = speed[-1] = 1.5
    t = [0.0]
    for i in range(1, len(path)):
        t.append(t[-1] + (ps[i] - ps[i - 1]) / ((speed[i] + speed[i - 1]) / 2))
    # two traffic-light stops (seconds added at a distance)
    stops = [(1400.0, 35.0), (ps[-1] - 1700.0, 25.0)]

    def time_at(si):
        tt = _interp_at(ps, t, si)
        for sd, dur in stops:
            if si > sd:
                tt += dur
        return tt

    # sample every RIDE_DT seconds: invert time_at by walking the path
    samples = []
    total = time_at(ps[-1])
    j = 0
    k_ts = 0.0
    while k_ts <= total:
        while j < len(ps) - 1 and time_at(ps[j + 1]) <= k_ts:
            j += 1
        if j >= len(ps) - 1:
            si = ps[-1]
        else:
            t0, t1 = time_at(ps[j]), time_at(ps[j + 1])
            si = ps[j] + (ps[j + 1] - ps[j]) * ((k_ts - t0) / ((t1 - t0) or 1.0))
            si = min(max(si, ps[j]), ps[j + 1])
        samples.append((k_ts, si))
        k_ts += RIDE_DT
    pts = []
    prev = None
    for ts, si in samples:
        x, y = _interp_at(ps, path, si)
        e = _interp_at(ps, ele_c, si) + 0.6 * math.sin(si / 900.0) + rng.gauss(0, 0.2)
        lon, lat = frame.to_lonlat(x + rng.gauss(0, 0.6), y + rng.gauss(0, 0.6))
        if prev is None:
            v, course = 0.0, 0.0
        else:
            v = (si - prev[1]) / RIDE_DT
            dx, dy = x - prev[2], y - prev[3]
            course = (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0 if (dx or dy) else prev[4]
        prev = (ts, si, x, y, course)
        pts.append((round(lon, 6), round(lat, 6), round(e, 1), RIDE_START + dt.timedelta(seconds=ts),
                    round(course, 1), round(v, 2)))

    lats = [p[1] for p in pts]
    lons = [p[0] for p in pts]
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<gpx version="1.0" creator="Greece fixture generator (make_fixtures.py)"',
             '     xmlns="http://www.topografix.com/GPX/1/0"',
             '     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
             '     xsi:schemaLocation="http://www.topografix.com/GPX/1/0 http://www.topografix.com/GPX/1/0/gpx.xsd">',
             '  <name>Zwolle to Deventer along the IJssel</name>',
             '  <desc>Synthetic bike ride (route plus recorded track). Generated for testing.</desc>',
             '  <author>Greece fixtures</author>',
             '  <time>%s</time>' % _iso(RIDE_START),
             '  <bounds minlat="%.6f" minlon="%.6f" maxlat="%.6f" maxlon="%.6f"/>' % (min(lats), min(lons), max(lats), max(lons)),
             '  <rte>',
             '    <name>IJssel route Zwolle - Deventer</name>',
             '    <number>1</number>']
    for lat, lon, name, ele in RIDE_ROUTE:
        lines.append('    <rtept lat="%.6f" lon="%.6f"><ele>%.1f</ele><name>%s</name><sym>%s</sym></rtept>'
                     % (lat, lon, ele, xml_escape(name), "City (Small)" if name in RIDE_TOWNS else "Waypoint"))
    lines += ['  </rte>', '  <trk>', '    <name>Morning ride Zwolle - Deventer</name>', '    <number>1</number>',
              '    <trkseg>']
    for lon, lat, e, when, course, v in pts:
        lines.append('      <trkpt lat="%.6f" lon="%.6f"><ele>%.1f</ele><time>%s</time><course>%.1f</course>'
                     '<speed>%.2f</speed></trkpt>' % (lat, lon, e, _iso(when), course, v))
    lines += ['    </trkseg>', '  </trk>', '</gpx>']
    write_text(os.path.join(out_dir, "ride.gpx"), "\n".join(lines) + "\n")
    dist, asc, desc = track_stats([(p[0], p[1], p[2], p[3]) for p in pts])
    return {"route_points": len(RIDE_ROUTE), "track_points": len(pts), "distance_km": round(dist / 1000, 2),
            "duration": str(pts[-1][3] - pts[0][3]),
            "avg_speed_kmh": round(dist / (pts[-1][3] - pts[0][3]).total_seconds() * 3.6, 1),
            "max_speed_kmh": round(max(p[5] for p in pts) * 3.6, 1),
            "ele_range": (min(p[2] for p in pts), max(p[2] for p in pts))}


# ---------------------------------------------------------------- verification

def verify(out_dir):
    res = {}
    ns11 = {"g": "http://www.topografix.com/GPX/1/1",
            "x": "http://www.garmin.com/xmlschemas/TrackPointExtension/v1"}
    root = ET.parse(os.path.join(out_dir, "hike.gpx")).getroot()
    assert root.tag == "{%s}gpx" % ns11["g"] and root.get("version") == "1.1"
    segs = root.findall("g:trk/g:trkseg", ns11)
    res["hike"] = {"wpt": len(root.findall("g:wpt", ns11)), "trkseg": len(segs),
                   "trkpt": sum(len(s.findall("g:trkpt", ns11)) for s in segs),
                   "hr_elements": len(root.findall(".//x:hr", ns11))}
    ns10 = {"g": "http://www.topografix.com/GPX/1/0"}
    root = ET.parse(os.path.join(out_dir, "ride.gpx")).getroot()
    assert root.tag == "{%s}gpx" % ns10["g"] and root.get("version") == "1.0"
    res["ride"] = {"rtept": len(root.findall("g:rte/g:rtept", ns10)),
                   "trkpt": len(root.findall("g:trk/g:trkseg/g:trkpt", ns10)),
                   "speed_elements": len(root.findall(".//g:speed", ns10))}
    return res
