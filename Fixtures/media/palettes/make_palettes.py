#!/usr/bin/env python3
"""Writes the palette fixtures (Aegean in every format Greece reads). Run from this folder.
Harbor.clr is written by AppKit's NSColorList (see SOURCES.md)."""
import colorsys, json, struct, zipfile

AEGEAN = [
    ("Aegean Blue", "#0D5EAF"), ("Santorini Dome", "#2A6FDB"), ("Whitewash", "#FBFAF6"), ("Limestone", "#E9E3D5"),
    ("Terracotta", "#C4622D"), ("Olive Grove", "#6B7B3A"), ("Bougainvillea", "#C0267E"), ("Sunset", "#F08A5D"),
    ("Honey", "#F2B33D"), ("Night Sea", "#0B3A5A"),
]

def rgb(hex_value):
    hex_value = hex_value.lstrip("#")
    return tuple(int(hex_value[i:i + 2], 16) for i in (0, 2, 4))

# ---------------------------------------------------------------- ASE
def ase_name(name):
    units = (name + "\0").encode("utf-16-be")
    return struct.pack(">H", len(units) // 2) + units

def ase_color(name, model, values, kind):
    body = ase_name(name) + model.encode("ascii") + b"".join(struct.pack(">f", v) for v in values) + struct.pack(">H", kind)
    return struct.pack(">HI", 0x0001, len(body)) + body

def ase_group(name):
    body = ase_name(name)
    return struct.pack(">HI", 0xC001, len(body)) + body

blocks = [ase_group("Island")]
for name, value in AEGEAN[:6]:
    blocks.append(ase_color(name, "RGB ", [c / 255 for c in rgb(value)], 0))
blocks.append(struct.pack(">HI", 0xC002, 0))
blocks.append(ase_group("Print"))
blocks.append(ase_color("Bougainvillea Spot", "CMYK", [0.05, 0.92, 0.12, 0.0], 1))
blocks.append(ase_color("Honey Spot", "CMYK", [0.0, 0.3, 0.85, 0.02], 1))
blocks.append(struct.pack(">HI", 0xC002, 0))
blocks.append(ase_color("Sunset Lab", "LAB ", [0.70, 32.0, 38.0], 2))
blocks.append(ase_color("Charcoal", "Gray", [0.22], 2))
with open("Aegean.ase", "wb") as handle:
    handle.write(b"ASEF" + struct.pack(">HHI", 1, 0, len(blocks)) + b"".join(blocks))

# ---------------------------------------------------------------- ACO (version 1, then 2 with names)
def aco_entries(named):
    out = b""
    for name, value in AEGEAN:
        r, g, b = rgb(value)
        out += struct.pack(">HHHHH", 0, r * 257, g * 257, b * 257, 0)
        if named:
            units = (name + "\0").encode("utf-16-be")
            out += struct.pack(">HI", 0, len(units) // 2) + units
    # A CMYK and a Lab colour (Photoshop stores CMYK inverted).
    out += struct.pack(">HHHHH", 2, int(65535 * (1 - 0.05)), int(65535 * (1 - 0.92)), int(65535 * (1 - 0.12)), 65535)
    if named:
        units = ("Bougainvillea CMYK\0").encode("utf-16-be")
        out += struct.pack(">HI", 0, len(units) // 2) + units
    out += struct.pack(">Hhhhh", 7, 7000, 3200, 3800, 0)
    if named:
        units = ("Sunset Lab\0").encode("utf-16-be")
        out += struct.pack(">HI", 0, len(units) // 2) + units
    return out

count = len(AEGEAN) + 2
with open("Aegean.aco", "wb") as handle:
    handle.write(struct.pack(">HH", 1, count) + aco_entries(False) + struct.pack(">HH", 2, count) + aco_entries(True))

# ---------------------------------------------------------------- ACT
table = b"".join(bytes(rgb(v)) for _, v in AEGEAN)
table += bytes(768 - len(table))
with open("Aegean.act", "wb") as handle:
    handle.write(table + struct.pack(">HH", len(AEGEAN), 0xFFFF))

# ---------------------------------------------------------------- GIMP
with open("Aegean.gpl", "w") as handle:
    handle.write("GIMP Palette\nName: Aegean\nColumns: 5\n#\n")
    for name, value in AEGEAN:
        r, g, b = rgb(value)
        handle.write(f"{r:3d} {g:3d} {b:3d}\t{name}\n")

# ---------------------------------------------------------------- Procreate
swatches = []
for _, value in AEGEAN:
    r, g, b = (c / 255 for c in rgb(value))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    swatches.append({"hue": h, "saturation": s, "brightness": v, "alpha": 1, "colorSpace": 0})
swatches += [None] * (30 - len(swatches))
with zipfile.ZipFile("Aegean.swatches", "w", zipfile.ZIP_DEFLATED) as package:
    package.writestr("Swatches.json", json.dumps([{"name": "Aegean", "swatches": swatches}]))

# ---------------------------------------------------------------- Sketch
with open("Aegean.sketchpalette", "w") as handle:
    json.dump({"compatibleVersion": "2.0", "pluginVersion": "2.22",
               "colors": [{"name": n, "red": rgb(v)[0] / 255, "green": rgb(v)[1] / 255, "blue": rgb(v)[2] / 255, "alpha": 1} for n, v in AEGEAN]},
              handle, indent=1)
print("ok")
