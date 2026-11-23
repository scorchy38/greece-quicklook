#!/usr/bin/env python3
"""Writes the Lottie fixtures: Lighthouse.json (a hand-built animation) and Harbour.lottie (a
dotLottie package with two animations and a packaged image). Run from this folder."""
import json, struct, zlib, zipfile, math

def static(value):
    return {"a": 0, "k": value}

def keyed(frames):
    """frames: [(time, value)], eased in and out."""
    out = []
    for i, (t, v) in enumerate(frames):
        v = v if isinstance(v, list) else [v]
        frame = {"t": t, "s": v}
        if i < len(frames) - 1:
            n = len(v)
            frame["i"] = {"x": [0.42] * n, "y": [1] * n}
            frame["o"] = {"x": [0.58] * n, "y": [0] * n}
        out.append(frame)
    return {"a": 1, "k": out}

def transform(p=(0, 0), a=(0, 0), s=(100, 100), r=0, o=100):
    return {"ty": "tr", "p": static(list(p)), "a": static(list(a)), "s": static(list(s)), "r": static(r), "o": static(o),
            "sk": static(0), "sa": static(0), "nm": "Transform"}

def group(name, items, tr=None):
    return {"ty": "gr", "nm": name, "it": items + [tr or transform()]}

def rect(x, y, w, h, r=0):
    return {"ty": "rc", "d": 1, "p": static([x, y]), "s": static([w, h]), "r": static(r), "nm": "Rectangle"}

def ellipse(x, y, w, h):
    return {"ty": "el", "d": 1, "p": static([x, y]), "s": static([w, h]), "nm": "Ellipse"}

def path(points, closed=True, tangents=None):
    n = len(points)
    i = [[0, 0]] * n
    o = [[0, 0]] * n
    if tangents:
        i, o = tangents
    return {"ty": "sh", "ks": static({"i": i, "o": o, "v": points, "c": closed}), "nm": "Path"}

def fill(rgb, opacity=100):
    return {"ty": "fl", "c": static(list(rgb) + [1]), "o": static(opacity), "r": 1, "nm": "Fill"}

def stroke(rgb, width, opacity=100):
    return {"ty": "st", "c": static(list(rgb) + [1]), "o": static(opacity), "w": static(width), "lc": 2, "lj": 2, "ml": 4, "nm": "Stroke"}

def gradient(stops, start, end):
    flat = []
    for offset, (r, g, b) in stops:
        flat += [offset, r, g, b]
    return {"ty": "gf", "o": static(100), "r": 1, "t": 1, "g": {"p": len(stops), "k": static(flat)}, "s": static(list(start)), "e": static(list(end)), "nm": "Gradient"}

def layer(index, name, shapes, ks=None, ip=0, op=90):
    base = {"o": static(100), "r": static(0), "p": static([0, 0, 0]), "a": static([0, 0, 0]), "s": static([100, 100, 100])}
    base.update(ks or {})
    return {"ddd": 0, "ind": index, "ty": 4, "nm": name, "sr": 1, "ks": base, "ao": 0, "shapes": shapes, "ip": ip, "op": op, "st": 0, "bm": 0}

def hex_rgb(value):
    value = value.lstrip("#")
    return [round(int(value[i:i + 2], 16) / 255, 4) for i in (0, 2, 4)]

W = H = 400
lighthouse = {
    "v": "5.7.4", "fr": 30, "ip": 0, "op": 90, "w": W, "h": H, "nm": "Lighthouse", "ddd": 0, "assets": [],
    "meta": {"g": "Greece fixtures (hand-built)"},
    "markers": [{"tm": 0, "cm": "Sweep", "dr": 45}, {"tm": 45, "cm": "Return", "dr": 45}],
    "layers": [
        layer(1, "Beam", [group("Beam", [
            path([[0, 0], [230, -46], [230, 46]]),
            gradient([(0, hex_rgb("#fff6d0")), (1, hex_rgb("#ffd27a"))], (0, 0), (230, 0)),
        ], transform(o=55))], {"p": static([200, 132, 0]), "r": keyed([(0, -20), (45, 200), (90, 340)])}),
        layer(2, "Lamp", [group("Glow", [ellipse(0, 0, 30, 30), fill(hex_rgb("#fff1c9"))])],
              {"p": static([200, 132, 0]), "s": keyed([(0, [100, 100, 100]), (22, [135, 135, 100]), (45, [100, 100, 100]), (67, [135, 135, 100]), (90, [100, 100, 100])])}),
        layer(3, "Tower", [
            group("Cap", [path([[176, 118], [224, 118], [200, 96]]), fill(hex_rgb("#c0392b"))]),
            group("Lantern", [rect(200, 132, 34, 24, 4), fill(hex_rgb("#2c3e50"))]),
            group("Stripes", [rect(200, 196, 46, 18), rect(200, 252, 56, 18), fill(hex_rgb("#c0392b"))]),
            group("Body", [path([[180, 146], [220, 146], [236, 300], [164, 300]]), fill(hex_rgb("#fbfaf6"))]),
        ]),
        layer(4, "Rocks", [group("Rocks", [path([[110, 318], [150, 290], [250, 286], [300, 318], [300, 330], [110, 330]]), fill(hex_rgb("#3b2f2f"))])]),
        layer(5, "Waves", [group("Waves", [
            path([[0, 0], [60, -8], [120, 0], [180, -8], [240, 0]], closed=False),
            stroke([1, 1, 1], 3, 40),
        ], transform(p=(80, 350)))], {"p": keyed([(0, [0, 0, 0]), (45, [30, 6, 0]), (90, [0, 0, 0])])}),
        layer(6, "Sea", [group("Sea", [rect(200, 365, 400, 90), gradient([(0, hex_rgb("#1f6f9f")), (1, hex_rgb("#0b3a5a"))], (200, 320), (200, 410))])]),
        layer(7, "Stars", [group(f"Star {n}", [ellipse(x, y, 4, 4), fill([1, 1, 1], 80)]) for n, (x, y) in enumerate([(60, 60), (320, 50), (360, 120), (90, 150), (260, 80)])],
              {"o": keyed([(0, 40), (30, 100), (60, 40), (90, 100)])}),
        layer(8, "Sky", [group("Sky", [rect(200, 200, 400, 400), gradient([(0, hex_rgb("#141e3c")), (1, hex_rgb("#3d2c5e"))], (200, 0), (200, 330))])]),
    ],
}

def png(width, height):
    rows = b""
    for y in range(height):
        row = b"\x00"
        for x in range(width):
            d = math.hypot(x - width / 2 + .5, y - height / 2 + .5) / (width / 2)
            alpha = 255 if d < .8 else max(0, int(255 * (1 - (d - .8) / .2))) if d < 1 else 0
            row += bytes([255, int(200 - 80 * d), int(80 + 40 * d), alpha])
        rows += row
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")

pulse = {
    "v": "5.9.0", "fr": 60, "ip": 0, "op": 120, "w": 256, "h": 256, "nm": "Sun Pulse", "ddd": 0,
    "assets": [{"id": "image_0", "w": 64, "h": 64, "u": "images/", "p": "sun.png", "e": 0}],
    "layers": [
        {"ddd": 0, "ind": 1, "ty": 2, "nm": "Sun", "refId": "image_0", "sr": 1,
         "ks": {"o": static(100), "r": keyed([(0, 0), (120, 90)]), "p": static([128, 128, 0]), "a": static([32, 32, 0]), "s": static([100, 100, 100])},
         "ao": 0, "ip": 0, "op": 120, "st": 0, "bm": 0},
        layer(2, "Ring", [group("Ring", [ellipse(0, 0, 120, 120), stroke(hex_rgb("#ff9f0a"), 6)])],
              {"p": static([128, 128, 0]), "s": keyed([(0, [60, 60, 100]), (120, [190, 190, 100])]), "o": keyed([(0, 100), (120, 0)])}, op=120),
    ],
}

with open("Lighthouse.json", "w") as handle:
    json.dump(lighthouse, handle, separators=(",", ":"))

manifest = {"version": "1", "generator": "Greece fixtures", "author": "Greece",
            "animations": [{"id": "lighthouse", "speed": 1, "loop": True, "autoplay": True}, {"id": "sun-pulse", "speed": 1, "loop": True}]}
with zipfile.ZipFile("Harbour.lottie", "w", zipfile.ZIP_DEFLATED) as package:
    package.writestr("manifest.json", json.dumps(manifest))
    package.writestr("animations/lighthouse.json", json.dumps(lighthouse, separators=(",", ":")))
    package.writestr("animations/sun-pulse.json", json.dumps(pulse, separators=(",", ":")))
    package.writestr("images/sun.png", png(64, 64))
print("ok")
