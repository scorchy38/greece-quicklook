#!/usr/bin/env python3
"""Writes Greece's generated 3D fixtures (no third-party code or data, so they are CC0).

    python3 Fixtures/models/generate.py

Every file is deterministic. The glTF samples from Khronos are downloaded separately (see SOURCES.md).
"""
import json, math, os, struct, zipfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def out(name):
    return os.path.join(HERE, name)


# ---------------------------------------------------------------------------- geometry helpers

def lathe(profile, segments):
    """Revolves (radius, height) points around Y. Returns vertices, quads (as index lists), uvs."""
    vertices, uvs, faces = [], [], []
    for s in range(segments + 1):
        angle = 2 * math.pi * s / segments
        for i, (r, y) in enumerate(profile):
            vertices.append((r * math.cos(angle), y, -r * math.sin(angle)))
            uvs.append((s / segments, i / (len(profile) - 1)))
    rows = len(profile)
    for s in range(segments):
        for i in range(rows - 1):
            a = s * rows + i
            b = (s + 1) * rows + i
            faces.append([a, b, b + 1, a + 1])
    return vertices, faces, uvs


def triangulate(faces):
    tris = []
    for face in faces:
        for k in range(1, len(face) - 1):
            tris.append((face[0], face[k], face[k + 1]))
    return tris


def normal(a, b, c):
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    n = (uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
    length = math.sqrt(sum(x * x for x in n)) or 1
    return tuple(x / length for x in n)


def box(cx, cy, cz, sx, sy, sz):
    """An axis-aligned box: 8 vertices, 6 outward quads."""
    x0, x1, y0, y1, z0, z1 = cx - sx / 2, cx + sx / 2, cy - sy / 2, cy + sy / 2, cz - sz / 2, cz + sz / 2
    v = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    f = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
    return v, f


def png(width, height, pixel):
    """A truecolour PNG from pixel(x, y) -> (r, g, b)."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(bytes(pixel(x, y)))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---------------------------------------------------------------------------- STL: a spur gear (binary) and a stepped pyramid (ASCII)

def gear_mesh(teeth=18, outer=20.0, root=17.0, hole=5.0, thickness=6.0, per_tooth=10):
    ring = []
    n = teeth * per_tooth
    for i in range(n):
        angle = 2 * math.pi * i / n
        phase = (i % per_tooth) / per_tooth
        # Trapezoidal teeth: rise, flat top, fall, flat root.
        if phase < 0.2: r = root + (outer - root) * (phase / 0.2)
        elif phase < 0.5: r = outer
        elif phase < 0.7: r = outer - (outer - root) * ((phase - 0.5) / 0.2)
        else: r = root
        ring.append((r * math.cos(angle), r * math.sin(angle)))
    inner = [(hole * math.cos(2 * math.pi * i / n), hole * math.sin(2 * math.pi * i / n)) for i in range(n)]
    tris = []
    for i in range(n):
        j = (i + 1) % n
        o0, o1, i0, i1 = ring[i], ring[j], inner[i], inner[j]
        top, bottom = thickness, 0.0
        # Top and bottom annulus.
        tris += [((o0[0], o0[1], top), (o1[0], o1[1], top), (i1[0], i1[1], top)), ((o0[0], o0[1], top), (i1[0], i1[1], top), (i0[0], i0[1], top))]
        tris += [((o0[0], o0[1], bottom), (i1[0], i1[1], bottom), (o1[0], o1[1], bottom)), ((o0[0], o0[1], bottom), (i0[0], i0[1], bottom), (i1[0], i1[1], bottom))]
        # Outer and inner walls.
        tris += [((o0[0], o0[1], bottom), (o1[0], o1[1], bottom), (o1[0], o1[1], top)), ((o0[0], o0[1], bottom), (o1[0], o1[1], top), (o0[0], o0[1], top))]
        tris += [((i0[0], i0[1], bottom), (i1[0], i1[1], top), (i1[0], i1[1], bottom)), ((i0[0], i0[1], bottom), (i0[0], i0[1], top), (i1[0], i1[1], top))]
    return tris


def write_stl_binary(path, tris, header=b"Greece fixture: spur gear, millimetres"):
    with open(path, "wb") as f:
        f.write(header.ljust(80, b" "))
        f.write(struct.pack("<I", len(tris)))
        for a, b, c in tris:
            f.write(struct.pack("<3f", *normal(a, b, c)))
            for p in (a, b, c):
                f.write(struct.pack("<3f", *p))
            f.write(b"\0\0")


def write_stl_ascii(path):
    tris = []
    for level in range(4):
        size, z = 40 - level * 10, level * 6
        v, faces = box(0, 0, z + 3, size, size, 6)
        tris += [(v[a], v[b], v[c]) for a, b, c in triangulate(faces)]
    with open(path, "w") as f:
        f.write("solid ziggurat\n")
        for a, b, c in tris:
            n = normal(a, b, c)
            f.write(f"  facet normal {n[0]:.6f} {n[1]:.6f} {n[2]:.6f}\n    outer loop\n")
            for p in (a, b, c):
                f.write(f"      vertex {p[0]:.4f} {p[1]:.4f} {p[2]:.4f}\n")
            f.write("    endloop\n  endfacet\n")
        f.write("endsolid ziggurat\n")


# ---------------------------------------------------------------------------- PLY: a glazed vase with vertex colours (binary)

def write_ply_vase(path):
    profile = []
    for i in range(48):
        t = i / 47
        y = t * 24
        r = 4.2 + 3.2 * math.sin(math.pi * (t * 0.95 + 0.05)) ** 1.6 - 1.4 * max(0, t - 0.82) * 5 + (0.9 if t > 0.96 else 0)
        profile.append((max(r, 1.6), y))
    vertices, faces, _ = lathe(profile, 72)
    colors = []
    for x, y, z in vertices:
        t = y / 24
        glaze = 0.5 + 0.5 * math.sin(t * 22)
        base = (196, 98, 60) if t < 0.18 else (32 + 30 * glaze, 96 + 50 * glaze, 140 + 60 * glaze)
        colors.append(tuple(int(max(0, min(255, c))) for c in base))
    center = len(vertices)
    vertices.append((0, 0, 0)); colors.append((150, 80, 50))
    rows = len(profile)
    for s in range(72):
        faces.append([center, (s + 1) * rows, s * rows])
    header = (f"ply\nformat binary_little_endian 1.0\ncomment Greece fixture: glazed vase\nelement vertex {len(vertices)}\n"
              "property float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\n"
              f"element face {len(faces)}\nproperty list uchar int vertex_indices\nend_header\n")
    with open(path, "wb") as f:
        f.write(header.encode())
        for (x, y, z), (r, g, b) in zip(vertices, colors):
            f.write(struct.pack("<3f3B", x, y, z, r, g, b))
        for face in faces:
            f.write(struct.pack("<B", len(face)) + struct.pack(f"<{len(face)}i", *face))


# ---------------------------------------------------------------------------- OBJ + MTL + texture: a chess pawn on a wooden plinth

def write_obj_pawn(folder):
    profile = [(0.0, 0.0), (5.2, 0.0), (5.2, 0.6), (4.9, 1.0), (4.6, 1.3), (4.0, 1.6), (3.3, 1.9), (2.6, 2.4), (2.1, 3.4),
               (1.8, 4.8), (1.7, 6.0), (2.9, 6.3), (3.0, 6.6), (2.5, 6.9), (1.7, 7.1)]
    for i in range(1, 13):
        a = math.pi * (-0.42 + i * 1.42 / 12)
        profile.append((2.35 * math.cos(a) + 0.0001, 9.0 + 2.35 * math.sin(a)))
    profile.append((0.0, 11.35))
    pawn_v, pawn_f, _ = lathe(profile, 48)
    plinth_v, plinth_f = box(0, -0.75, 0, 14, 1.5, 14)
    lines = ["# Greece fixture: a chess pawn on a wooden plinth", "mtllib pawn.mtl", "o Pawn"]
    for v in pawn_v:
        lines.append("v %.4f %.4f %.4f" % v)
    lines.append("usemtl Ivory")
    lines.append("s 1")
    for face in pawn_f:
        lines.append("f " + " ".join(str(i + 1) for i in face))
    base = len(pawn_v)
    lines.append("o Plinth")
    for v in plinth_v:
        lines.append("v %.4f %.4f %.4f" % v)
    for u, w in [(0, 0), (1, 0), (1, 1), (0, 1)]:
        lines.append(f"vt {u} {w}")
    lines.append("usemtl Walnut")
    lines.append("s off")
    for face in plinth_f:
        lines.append("f " + " ".join(f"{base + i + 1}/{k + 1}" for k, i in enumerate(face)))
    with open(os.path.join(folder, "pawn.obj"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(folder, "pawn.mtl"), "w") as f:
        f.write("# Greece fixture materials\nnewmtl Ivory\nKa 0 0 0\nKd 0.92 0.89 0.82\nKs 0.4 0.4 0.4\nNs 60\n\n"
                "newmtl Walnut\nKa 0 0 0\nKd 1 1 1\nKs 0.1 0.1 0.1\nNs 12\nmap_Kd walnut.png\n")
    def wood(x, y):
        grain = math.sin((x * 0.35 + 6 * math.sin(y * 0.05)) * 1.3) * 0.5 + 0.5
        ring = 0.75 + 0.25 * grain
        return (int(120 * ring), int(78 * ring), int(48 * ring))
    with open(os.path.join(folder, "walnut.png"), "wb") as f:
        f.write(png(96, 96, wood))


# ---------------------------------------------------------------------------- 3MF: a bracket with pegs, coloured, in millimetres

def write_3mf(path):
    # An L-shaped bracket: the L profile in XZ, extruded along Y.
    profile = [(0, 0), (40, 0), (40, 6), (6, 6), (6, 30), (0, 30)]
    depth = 20
    verts = [(x, 0, z) for x, z in profile] + [(x, depth, z) for x, z in profile]
    n = len(profile)
    tris = [(0, 1, 2), (0, 2, 3), (0, 3, 4), (0, 4, 5)]
    tris += [(n + a, n + c, n + b) for a, b, c in tris]
    for i in range(n):
        j = (i + 1) % n
        tris += [(i, n + i, n + j), (i, n + j, j)]
    # Fix winding so normals face outwards for the front face (profile is CCW in XZ seen from -Y).
    peg = []
    segments = 32
    for s in range(segments):
        a = 2 * math.pi * s / segments
        peg.append((3 * math.cos(a), 3 * math.sin(a), 0))
    for s in range(segments):
        a = 2 * math.pi * s / segments
        peg.append((3 * math.cos(a), 3 * math.sin(a), 8))
    peg += [(0, 0, 0), (0, 0, 8)]
    peg_tris = []
    for s in range(segments):
        t = (s + 1) % segments
        peg_tris += [(s, t, segments + t), (s, segments + t, segments + s)]
        peg_tris += [(2 * segments, t, s), (2 * segments + 1, segments + s, segments + t)]

    def mesh_xml(vs, ts, pid=None, colors=None):
        rows = ["<mesh><vertices>"] + [f'<vertex x="{x:.3f}" y="{y:.3f}" z="{z:.3f}"/>' for x, y, z in vs] + ["</vertices><triangles>"]
        for k, (a, b, c) in enumerate(ts):
            extra = f' pid="{pid}" p1="{colors[k]}"' if colors else ""
            rows.append(f'<triangle v1="{a}" v2="{b}" v3="{c}"{extra}/>')
        rows.append("</triangles></mesh>")
        return "".join(rows)

    # Colour the bracket's top faces differently, per triangle, to exercise colour groups.
    face_colors = [1 if all(verts[i][2] >= 6 for i in t) and i_ >= 8 else 0 for i_, t in enumerate(tris)]
    model = f"""<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:m="http://schemas.microsoft.com/3dmanufacturing/material/2015/02">
 <metadata name="Title">Bracket</metadata>
 <metadata name="Application">Greece fixture generator</metadata>
 <resources>
  <basematerials id="1"><base name="Anodised blue" displaycolor="#2F6FDEFF"/><base name="Steel" displaycolor="#B9BDC6FF"/><base name="Signal orange" displaycolor="#F28C28FF"/></basematerials>
  <object id="2" type="model" pid="1" pindex="0" name="Bracket">{mesh_xml(verts, tris, 1, face_colors)}</object>
  <object id="3" type="model" pid="1" pindex="2" name="Peg">{mesh_xml(peg, peg_tris)}</object>
  <object id="4" type="model" name="Pegs"><components><component objectid="3" transform="1 0 0 0 1 0 0 0 1 24 6 6"/><component objectid="3" transform="1 0 0 0 1 0 0 0 1 24 14 6"/></components></object>
 </resources>
 <build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 0"/><item objectid="4"/></build>
</model>
"""
    rels = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
"""
    types = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in [("[Content_Types].xml", types), ("_rels/.rels", rels), ("3D/3dmodel.model", model)]:
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)


# ---------------------------------------------------------------------------- OFF: an icosahedron with face colours

def write_off(path):
    t = (1 + math.sqrt(5)) / 2
    v = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t), (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    f = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
         (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    palette = [(242, 140, 40), (47, 111, 222), (52, 168, 83), (234, 67, 53)]
    lines = ["OFF", "# Greece fixture: icosahedron with face colours", f"{len(v)} {len(f)} 30"]
    lines += [f"{x * 10:.5f} {y * 10:.5f} {z * 10:.5f}" for x, y, z in v]
    lines += [f"3 {a} {b} {c} {' '.join(map(str, palette[i % 4]))}" for i, (a, b, c) in enumerate(f)]
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------- 3DS: a small table

def chunk3ds(cid, payload):
    return struct.pack("<HI", cid, 6 + len(payload)) + payload


def write_3ds(path):
    materials = [("Oak", (186, 140, 92)), ("Graphite", (58, 60, 66))]
    mats = b"".join(chunk3ds(0xAFFF, chunk3ds(0xA000, name.encode() + b"\0") + chunk3ds(0xA020, chunk3ds(0x0011, bytes(rgb)))) for name, rgb in materials)
    objects = b""
    parts = [("Top", "Oak", box(0, 0, 72, 120, 70, 4))] + [(f"Leg{i}", "Graphite", box(sx * 54, sy * 29, 35, 4, 4, 70)) for i, (sx, sy) in enumerate([(-1, -1), (1, -1), (1, 1), (-1, 1)])]
    for name, material, (verts, faces) in parts:
        tris = triangulate(faces)
        vertex_chunk = chunk3ds(0x4110, struct.pack("<H", len(verts)) + b"".join(struct.pack("<3f", *p) for p in verts))
        face_body = struct.pack("<H", len(tris)) + b"".join(struct.pack("<4H", a, b, c, 0) for a, b, c in tris)
        face_body += chunk3ds(0x4130, material.encode() + b"\0" + struct.pack("<H", len(tris)) + b"".join(struct.pack("<H", i) for i in range(len(tris))))
        mesh = chunk3ds(0x4100, vertex_chunk + chunk3ds(0x4120, face_body) + chunk3ds(0x4160, struct.pack("<12f", 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)))
        objects += chunk3ds(0x4000, name.encode() + b"\0" + mesh)
    editor = chunk3ds(0x3D3D, chunk3ds(0x3D3E, struct.pack("<I", 3)) + mats + objects)
    with open(path, "wb") as f:
        f.write(chunk3ds(0x4D4D, chunk3ds(0x0002, struct.pack("<I", 3)) + editor))


# ---------------------------------------------------------------------------- VRML 2.0: primitives

def write_vrml(path):
    shapes = [("Box { size 1.6 1.6 1.6 }", (-2.4, 0.8, 0), (0.95, 0.55, 0.2)),
              ("Sphere { radius 0.9 }", (0, 0.9, 0), (0.2, 0.5, 0.9)),
              ("Cone { bottomRadius 0.9 height 1.9 }", (2.4, 0.95, 0), (0.3, 0.75, 0.4)),
              ("Cylinder { radius 0.6 height 1.2 }", (0, 0.6, -2.4), (0.85, 0.3, 0.35))]
    body = "#VRML V2.0 utf8\n# Greece fixture: primitives\n"
    for geometry, (x, y, z), (r, g, b) in shapes:
        body += (f"Transform {{\n  translation {x} {y} {z}\n  children [\n    Shape {{\n      appearance Appearance {{ material Material {{ diffuseColor {r} {g} {b} shininess 0.4 }} }}\n"
                 f"      geometry {geometry}\n    }}\n  ]\n}}\n")
    with open(path, "w") as f:
        f.write(body)


# ---------------------------------------------------------------------------- MagicaVoxel: a tree on a patch of grass

def write_vox(path):
    size = 16
    voxels = {}
    for x in range(size):
        for y in range(size):
            voxels[(x, y, 0)] = 1   # grass
            if (x - 3) ** 2 + (y - 12) ** 2 < 4:
                voxels[(x, y, 0)] = 4   # pond
    for z in range(1, 7):
        voxels[(8, 8, z)] = 2   # trunk
    for x in range(4, 13):
        for y in range(4, 13):
            for z in range(6, 14):
                if (x - 8) ** 2 + (y - 8) ** 2 + (z - 9.5) ** 2 * 1.4 < 17:
                    voxels[(x, y, z)] = 3   # leaves
    palette = [(0, 0, 0, 0)] * 256
    palette[0], palette[1], palette[2], palette[3] = (96, 168, 72, 255), (122, 84, 52, 255), (52, 132, 64, 255), (64, 140, 220, 255)
    xyzi = struct.pack("<I", len(voxels)) + b"".join(struct.pack("<4B", x, y, z, c) for (x, y, z), c in sorted(voxels.items()))
    def vchunk(cid, content, children=b""):
        return cid + struct.pack("<II", len(content), len(children)) + content + children
    children = vchunk(b"SIZE", struct.pack("<3I", size, size, size)) + vchunk(b"XYZI", xyzi) + vchunk(b"RGBA", b"".join(struct.pack("<4B", *c) for c in palette))
    with open(path, "wb") as f:
        f.write(b"VOX " + struct.pack("<I", 150) + vchunk(b"MAIN", b"", children))


# ---------------------------------------------------------------------------- Terrain point cloud (shared by LAS, LAZ and PCD)

def terrain_points(count, seed=7):
    """A hillside with a road, two buildings and trees: (x, y, z, r, g, b, classification, intensity)."""
    import random
    rng = random.Random(seed)
    points = []
    buildings = [(-30, 20, 18, 12, 9), (25, -15, 14, 20, 12)]
    trees = [(rng.uniform(-60, 60), rng.uniform(-60, 60), rng.uniform(3, 6), rng.uniform(8, 14)) for _ in range(26)]
    def ground(x, y):
        return 6 * math.sin(x / 23) + 4 * math.cos(y / 17) + 0.04 * x
    while len(points) < count:
        x, y = rng.uniform(-70, 70), rng.uniform(-70, 70)
        z = ground(x, y) + rng.gauss(0, 0.05)
        cls, rgb, intensity = 2, (118 + rng.randint(-10, 10), 132 + rng.randint(-10, 10), 82), 900 + rng.randint(-100, 100)
        if abs(y - 0.3 * x) < 4:
            cls, rgb, intensity = 11, (96, 98, 104), 1800
        for bx, by, w, d, h in buildings:
            if abs(x - bx) < w / 2 and abs(y - by) < d / 2:
                z = ground(bx, by) + h + 0.3 * math.sin(x) * 0
                cls, rgb, intensity = 6, (184, 92, 72) if bx < 0 else (160, 160, 168), 2400
        for tx, ty, r, h in trees:
            dist = math.hypot(x - tx, y - ty)
            if dist < r:
                top = ground(tx, ty) + h * (1 - (dist / r) ** 2) ** 0.5
                if rng.random() < 0.85:
                    z = top - rng.uniform(0, 1.5)
                    cls, rgb, intensity = 5, (44 + rng.randint(-8, 8), 104 + rng.randint(-12, 12), 52), 600
        points.append((x, y, z, *rgb, cls, max(0, intensity)))
    return points


def write_las(path, points, version_minor=2):
    """LAS 1.2, point format 2 (XYZ, intensity, classification, RGB), metres, with a GeoTIFF key directory."""
    scale, offset = 0.01, (500000.0, 4100000.0, 100.0)
    record = 26
    keys = [(1024, 0, 1, 1), (3072, 0, 1, 32633), (3076, 0, 1, 9001), (4099, 0, 1, 9001)]
    geokeys = struct.pack("<4H", 1, 1, 0, len(keys)) + b"".join(struct.pack("<4H", *k) for k in keys)
    vlr = struct.pack("<H16sHH32s", 0, b"LASF_Projection", 34735, len(geokeys), b"GeoKeyDirectoryTag") + geokeys
    header_size = 227
    point_offset = header_size + len(vlr)
    xs = [p[0] + offset[0] for p in points]; ys = [p[1] + offset[1] for p in points]; zs = [p[2] + offset[2] for p in points]
    returns = [len(points), 0, 0, 0, 0]
    header = struct.pack("<4sHH16sBB32s32sHHHIIBHI5I12d", b"LASF", 0, 0, b"\0" * 16, 1, version_minor, b"Greece".ljust(32, b"\0"),
                         b"Greece fixture generator".ljust(32, b"\0"), 1, 2026, header_size, point_offset, 1, 2, record, len(points), *returns,
                         scale, scale, scale, *offset, max(xs), min(xs), max(ys), min(ys), max(zs), min(zs))
    assert len(header) == header_size, len(header)
    body = bytearray()
    for (x, y, z, r, g, b, cls, intensity), wx, wy, wz in zip(points, xs, ys, zs):
        body += struct.pack("<iiiHBBbBH3H", round((wx - offset[0]) / scale), round((wy - offset[1]) / scale), round((wz - offset[2]) / scale),
                            intensity, 0x09, cls, 0, 0, 1, r * 257, g * 257, b * 257)
    with open(path, "wb") as f:
        f.write(header + vlr + bytes(body))


def write_laz(path, points):
    """LAS 1.4, point format 7, LASzip-compressed. Needs `pip install laspy lazrs`; skipped otherwise."""
    try:
        import laspy, numpy as np
    except ImportError:
        print("laspy not installed: skipping", os.path.basename(path))
        return
    header = laspy.LasHeader(point_format=7, version="1.4")
    header.scales = [0.01, 0.01, 0.01]
    header.offsets = [600000.0, 5200000.0, 0.0]
    header.generating_software = "Greece fixture generator"
    las = laspy.LasData(header)
    columns = list(zip(*points))
    las.x = np.array(columns[0]) + 600000.0
    las.y = np.array(columns[1]) + 5200000.0
    las.z = np.array(columns[2]) + 40.0
    las.red, las.green, las.blue = (np.array(c, dtype=np.uint16) * 257 for c in columns[3:6])
    las.classification = np.array(columns[6], dtype=np.uint8)
    las.intensity = np.array(columns[7], dtype=np.uint16)
    las.gps_time = np.arange(len(points), dtype=np.float64) * 0.0001
    las.write(path, laz_backend=laspy.LazBackend.Lazrs)


def write_pcd(path, count=6000):
    """A binary PCD of a trefoil-knot tube, coloured along its length."""
    rows = []
    for i in range(count):
        t = 2 * math.pi * i / count * 1.0
        u = (i * 0.61803398875 % 1) * 2 * math.pi
        cx, cy, cz = math.sin(t) + 2 * math.sin(2 * t), math.cos(t) - 2 * math.cos(2 * t), -math.sin(3 * t)
        dx, dy, dz = math.cos(t) + 4 * math.cos(2 * t), -math.sin(t) + 4 * math.sin(2 * t), -3 * math.cos(3 * t)
        length = math.sqrt(dx * dx + dy * dy + dz * dz)
        nx, ny, nz = -dy / length, dx / length, 0
        bx, by, bz = dy * nz - dz * ny, dz * nx - dx * nz, dx * ny - dy * nx
        bl = math.sqrt(bx * bx + by * by + bz * bz) or 1
        r = 0.45
        x = cx + r * (math.cos(u) * nx + math.sin(u) * bx / bl)
        y = cy + r * (math.cos(u) * ny + math.sin(u) * by / bl)
        z = cz + r * (math.cos(u) * nz + math.sin(u) * bz / bl)
        hue = i / count
        red, green, blue = (int(127 + 127 * math.cos(2 * math.pi * (hue + k / 3))) for k in range(3))
        rows.append(struct.pack("<3fI", x, y, z, (red << 16) | (green << 8) | blue))
    header = ("# .PCD v0.7 - Greece fixture\nVERSION 0.7\nFIELDS x y z rgb\nSIZE 4 4 4 4\nTYPE F F F U\nCOUNT 1 1 1 1\n"
              f"WIDTH {count}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {count}\nDATA binary\n")
    with open(path, "wb") as f:
        f.write(header.encode() + b"".join(rows))


# ---------------------------------------------------------------------------- COLLADA: a desk lamp in centimetres, Z up

def write_dae(path):
    parts = [("Base", "Graphite", box(0, 0, 1, 18, 18, 2)), ("Stem", "Brushed", box(0, 0, 14, 2, 2, 26)),
             ("Arm", "Brushed", box(7, 0, 27, 16, 2, 2)), ("Shade", "Coral", box(15, 0, 23, 8, 8, 8))]
    colors = {"Graphite": (0.16, 0.16, 0.18), "Brushed": (0.72, 0.73, 0.76), "Coral": (0.96, 0.45, 0.36)}
    geometries, nodes = [], []
    for name, material, (verts, faces) in parts:
        tris = triangulate(faces)
        positions = " ".join(f"{c:.3f}" for v in verts for c in v)
        normals = " ".join(f"{c:.5f}" for a, b, c in tris for c in normal(verts[a], verts[b], verts[c]))
        indices = " ".join(f"{a} {k} {b} {k} {c} {k}" for k, (a, b, c) in enumerate(tris))
        geometries.append(f"""<geometry id="{name}-mesh" name="{name}"><mesh>
<source id="{name}-pos"><float_array id="{name}-pos-array" count="{len(verts) * 3}">{positions}</float_array><technique_common><accessor source="#{name}-pos-array" count="{len(verts)}" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
<source id="{name}-nrm"><float_array id="{name}-nrm-array" count="{len(tris) * 3}">{normals}</float_array><technique_common><accessor source="#{name}-nrm-array" count="{len(tris)}" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
<vertices id="{name}-vtx"><input semantic="POSITION" source="#{name}-pos"/></vertices>
<triangles material="{material}-material" count="{len(tris)}"><input semantic="VERTEX" source="#{name}-vtx" offset="0"/><input semantic="NORMAL" source="#{name}-nrm" offset="1"/><p>{indices}</p></triangles>
</mesh></geometry>""")
        nodes.append(f"""<node id="{name}" name="{name}"><instance_geometry url="#{name}-mesh"><bind_material><technique_common><instance_material symbol="{material}-material" target="#{material}-material"/></technique_common></bind_material></instance_geometry></node>""")
    effects = "".join(f"""<effect id="{m}-effect"><profile_COMMON><technique sid="common"><phong><diffuse><color>{r} {g} {b} 1</color></diffuse><shininess><float>40</float></shininess></phong></technique></profile_COMMON></effect>""" for m, (r, g, b) in colors.items())
    materials = "".join(f"""<material id="{m}-material" name="{m}"><instance_effect url="#{m}-effect"/></material>""" for m in colors)
    document = f"""<?xml version="1.0" encoding="utf-8"?>
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
<asset><contributor><authoring_tool>Greece fixture generator</authoring_tool></contributor><unit name="centimeter" meter="0.01"/><up_axis>Z_UP</up_axis></asset>
<library_effects>{effects}</library_effects>
<library_materials>{materials}</library_materials>
<library_geometries>{''.join(geometries)}</library_geometries>
<library_visual_scenes><visual_scene id="Scene" name="Scene">{''.join(nodes)}</visual_scene></library_visual_scenes>
<scene><instance_visual_scene url="#Scene"/></scene>
</COLLADA>
"""
    with open(path, "w") as f:
        f.write(document)


# ---------------------------------------------------------------------------- FBX: a windmill with spinning sails (ASCII and binary)

KTIME = 46186158000   # FBX ticks per second


def fbx_windmill():
    """The FBX document as (name, properties, children) nodes; property tuples are (type, value)."""
    objects, connections = [], []
    ids = iter(range(1000, 100000))
    def P(name, kind, label, flags, *values, value_type="D"):
        return ("P", [("S", name), ("S", kind), ("S", label), ("S", flags)] + [(value_type, v) for v in values], [])
    def mesh(name, verts, faces, material_id, translation, rotation=(0, 0, 0), parent=0):
        geometry_id, model_id = next(ids), next(ids)
        flat = [c for v in verts for c in v]
        index = []
        normals = []
        for face in faces:
            n = normal(verts[face[0]], verts[face[1]], verts[face[2]])
            for k, i in enumerate(face):
                index.append(i if k < len(face) - 1 else -i - 1)
                normals += n
        objects.append(("Geometry", [("L", geometry_id), ("N", ("Geometry", name)), ("S", "Mesh")], [
            ("Vertices", [("d", flat)], []), ("PolygonVertexIndex", [("i", index)], []), ("GeometryVersion", [("I", 124)], []),
            ("LayerElementNormal", [("I", 0)], [("Version", [("I", 101)], []), ("Name", [("S", "")], []),
                                                ("MappingInformationType", [("S", "ByPolygonVertex")], []),
                                                ("ReferenceInformationType", [("S", "Direct")], []), ("Normals", [("d", normals)], [])]),
            ("LayerElementMaterial", [("I", 0)], [("Version", [("I", 101)], []), ("Name", [("S", "")], []),
                                                  ("MappingInformationType", [("S", "AllSame")], []),
                                                  ("ReferenceInformationType", [("S", "IndexToDirect")], []), ("Materials", [("i", [0])], [])]),
            ("Layer", [("I", 0)], [("Version", [("I", 100)], []),
                                   ("LayerElement", [], [("Type", [("S", "LayerElementNormal")], []), ("TypedIndex", [("I", 0)], [])]),
                                   ("LayerElement", [], [("Type", [("S", "LayerElementMaterial")], []), ("TypedIndex", [("I", 0)], [])])]),
        ]))
        objects.append(("Model", [("L", model_id), ("N", ("Model", name)), ("S", "Mesh")], [
            ("Version", [("I", 232)], []),
            ("Properties70", [], [P("Lcl Translation", "Lcl Translation", "", "A", *translation),
                                  P("Lcl Rotation", "Lcl Rotation", "", "A", *rotation),
                                  P("Lcl Scaling", "Lcl Scaling", "", "A", 1.0, 1.0, 1.0)]),
            ("Culling", [("S", "CullingOff")], []),
        ]))
        connections.append(("C", [("S", "OO"), ("L", geometry_id), ("L", model_id)], []))
        connections.append(("C", [("S", "OO"), ("L", model_id), ("L", parent)], []))
        connections.append(("C", [("S", "OO"), ("L", material_id), ("L", model_id)], []))
        return model_id
    def material(name, rgb, shininess=20.0):
        material_id = next(ids)
        objects.append(("Material", [("L", material_id), ("N", ("Material", name)), ("S", "")], [
            ("Version", [("I", 102)], []), ("ShadingModel", [("S", "phong")], []), ("MultiLayer", [("I", 0)], []),
            ("Properties70", [], [P("DiffuseColor", "Color", "", "A", *rgb), P("Shininess", "double", "Number", "", shininess)]),
        ]))
        return material_id
    plaster, timber, sail = material("Plaster", (0.93, 0.9, 0.84)), material("Timber", (0.45, 0.3, 0.2)), material("Sailcloth", (0.95, 0.95, 0.93), 6.0)
    # The tower tapers: a lathe with eight sides.
    tower_v, tower_f, _ = lathe([(0.0, 0.0), (90.0, 0.0), (60.0, 420.0), (0.0, 420.0)], 8)
    mesh("Tower", tower_v, tower_f, plaster, (0.0, 0.0, 0.0))
    roof_v, roof_f, _ = lathe([(0.0, 0.0), (75.0, 0.0), (0.0, 110.0)], 8)
    mesh("Roof", roof_v, roof_f, timber, (0.0, 420.0, 0.0))
    hub_v, hub_f = box(0, 0, 0, 30, 30, 30)
    hub = mesh("Rotor", hub_v, hub_f, timber, (0.0, 400.0, 75.0))
    for k in range(4):
        angle = k * 90.0
        blade_v, blade_f = box(0, 150, 6, 46, 260, 4)
        mesh(f"Sail{k + 1}", blade_v, blade_f, sail, (0.0, 0.0, 0.0), (0.0, 0.0, angle), parent=hub)
    # Animation: the rotor turns once every four seconds.
    stack, layer, curve_node, curve = next(ids), next(ids), next(ids), next(ids)
    times = [int(KTIME * t) for t in (0, 1, 2, 3, 4)]
    objects.append(("AnimationStack", [("L", stack), ("N", ("AnimStack", "Turn")), ("S", "")], [
        ("Properties70", [], [P("LocalStop", "KTime", "Time", "", times[-1], value_type="L"), P("ReferenceStop", "KTime", "Time", "", times[-1], value_type="L")])]))
    objects.append(("AnimationLayer", [("L", layer), ("N", ("AnimLayer", "BaseLayer")), ("S", "")], []))
    objects.append(("AnimationCurveNode", [("L", curve_node), ("N", ("AnimCurveNode", "R")), ("S", "")], [
        ("Properties70", [], [P("d|X", "Number", "", "A", 0.0), P("d|Y", "Number", "", "A", 0.0), P("d|Z", "Number", "", "A", 0.0)])]))
    objects.append(("AnimationCurve", [("L", curve), ("N", ("AnimCurve", "")), ("S", "")], [
        ("Default", [("D", 0.0)], []), ("KeyVer", [("I", 4009)], []), ("KeyTime", [("l", times)], []),
        ("KeyValueFloat", [("f", [0.0, -90.0, -180.0, -270.0, -360.0])], []), ("KeyAttrFlags", [("i", [8456])], []),
        ("KeyAttrDataFloat", [("f", [0.0, 0.0, 0.0, 0.0])], []), ("KeyAttrRefCount", [("i", [5])], [])]))
    connections += [("C", [("S", "OO"), ("L", layer), ("L", stack)], []), ("C", [("S", "OO"), ("L", curve_node), ("L", layer)], []),
                    ("C", [("S", "OP"), ("L", curve_node), ("L", hub), ("S", "Lcl Rotation")], []),
                    ("C", [("S", "OP"), ("L", curve), ("L", curve_node), ("S", "d|Z")], [])]
    settings = ("GlobalSettings", [], [("Version", [("I", 1000)], []), ("Properties70", [], [
        P("UpAxis", "int", "Integer", "", 1, value_type="I"), P("UpAxisSign", "int", "Integer", "", 1, value_type="I"),
        P("FrontAxis", "int", "Integer", "", 2, value_type="I"), P("FrontAxisSign", "int", "Integer", "", 1, value_type="I"),
        P("CoordAxis", "int", "Integer", "", 0, value_type="I"), P("CoordAxisSign", "int", "Integer", "", 1, value_type="I"),
        P("UnitScaleFactor", "double", "Number", "", 1.0), P("OriginalUnitScaleFactor", "double", "Number", "", 1.0)])])
    header = ("FBXHeaderExtension", [], [("FBXHeaderVersion", [("I", 1003)], []), ("FBXVersion", [("I", 7400)], []),
                                         ("Creator", [("S", "Greece fixture generator")], [])])
    return [header, settings, ("Objects", [], objects), ("Connections", [], connections)]


def fbx_ascii(nodes):
    def value(kind, v):
        if kind == "N": return '"%s::%s"' % v
        if kind == "S": return '"%s"' % v
        if kind in "DF": return repr(float(v))
        return str(int(v))
    def write(node, depth):
        name, props, children = node
        pad = "\t" * depth
        arrays = [p for p in props if p[0] in "dilfb"]
        if arrays:
            kind, values = arrays[0]
            text = ",".join(value(kind.upper() if kind in "df" else "I", v) for v in values)
            return f"{pad}{name}: *{len(values)} {{\n{pad}\ta: {text}\n{pad}}}\n"
        # Real FBX writes `"A",0,0,0`: numbers follow without a space (three.js's parser relies on it).
        text = ""
        for index, (k, v) in enumerate(props):
            if index:
                text += "," if k in "IDFL" else ", "
            text += value(k, v)
        line = f"{pad}{name}: " + text
        # Objects (anything with an id) always open a block, even when empty.
        if children or not props or props[0][0] == "L":
            return line + " {\n" + "".join(write(c, depth + 1) for c in children) + pad + "}\n"
        return line + "\n"
    return "; FBX 7.4.0 project file\n; Greece fixture generator\n" + "".join(write(n, 0) for n in nodes)


def fbx_binary(nodes):
    def prop(kind, v):
        if kind == "N": text = (v[1] + "\x00\x01" + v[0]).encode(); return b"S" + struct.pack("<I", len(text)) + text
        if kind == "S": text = v.encode(); return b"S" + struct.pack("<I", len(text)) + text
        if kind == "I": return b"I" + struct.pack("<i", v)
        if kind == "L": return b"L" + struct.pack("<q", v)
        if kind == "D": return b"D" + struct.pack("<d", v)
        if kind == "F": return b"F" + struct.pack("<f", v)
        code = {"d": "d", "i": "i", "l": "q", "f": "f"}[kind]
        data = struct.pack(f"<{len(v)}{code}", *v)
        if len(data) > 128:
            packed = zlib.compress(data)
            return kind.encode() + struct.pack("<III", len(v), 1, len(packed)) + packed
        return kind.encode() + struct.pack("<III", len(v), 0, len(data)) + data
    def record(node, offset):
        name, props, children = node
        body = b"".join(prop(k, v) for k, v in props)
        head_size = 13 + len(name)
        nested = b""
        cursor = offset + head_size + len(body)
        for child in children:
            data = record(child, cursor)
            nested += data
            cursor += len(data)
        if children:
            nested += b"\0" * 13
        end = offset + head_size + len(body) + len(nested)
        return struct.pack("<IIIB", end, len(props), len(body), len(name)) + name.encode() + body + nested
    data = bytearray(b"Kaydara FBX Binary  \x00\x1a\x00" + struct.pack("<I", 7400))
    for node in nodes:
        data += record(node, len(data))
    data += b"\0" * 13
    # Footer: id, padding to 16 bytes, zeros, version, zeros, magic.
    data += bytes([0xFA, 0xBC, 0xAB, 0x09, 0xD0, 0xC8, 0xD4, 0x66, 0xB1, 0x76, 0xFB, 0x83, 0x1C, 0xF7, 0x26, 0x7E])
    data += b"\0" * ((16 - len(data) % 16) % 16 or 16)
    data += b"\0" * 4 + struct.pack("<I", 7400) + b"\0" * 120
    data += bytes([0xF8, 0x5A, 0x8C, 0x6A, 0xDE, 0xF5, 0xD9, 0x7E, 0xEC, 0xE9, 0x0C, 0xE3, 0x75, 0x8F, 0x29, 0x0B])
    return bytes(data)


# ---------------------------------------------------------------------------- glTF: a glass dome over a brass sphere (translucency)

def write_glass_glb(path):
    def sphere(radius, rings, segments, y_offset, hemisphere=False):
        positions, normals, indices = [], [], []
        top = rings // 2 if hemisphere else rings
        for r in range(top + 1):
            phi = math.pi * r / rings
            for s in range(segments + 1):
                theta = 2 * math.pi * s / segments
                n = (math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta))
                positions.append((n[0] * radius, n[1] * radius + y_offset, n[2] * radius))
                normals.append(n)
        for r in range(top):
            for s in range(segments):
                a = r * (segments + 1) + s
                b = a + segments + 1
                indices += [a, a + 1, b, b, a + 1, b + 1]
        return positions, normals, indices
    plinth_v, plinth_f = box(0, 0.03, 0, 0.36, 0.06, 0.36)
    plinth_tris = triangulate(plinth_f)
    plinth_positions, plinth_normals, plinth_indices = [], [], []
    for a, b, c in plinth_tris:
        n = normal(plinth_v[a], plinth_v[b], plinth_v[c])
        for i in (a, b, c):
            plinth_positions.append(plinth_v[i]); plinth_normals.append(n); plinth_indices.append(len(plinth_indices))
    parts = [sphere(0.07, 32, 48, 0.13), sphere(0.15, 32, 48, 0.06, hemisphere=True), (plinth_positions, plinth_normals, plinth_indices)]
    buffer = bytearray()
    accessors, views, meshes = [], [], []
    for positions, normals, indices in parts:
        primitive = {}
        for kind, values in (("POSITION", positions), ("NORMAL", normals)):
            offset = len(buffer)
            for v in values:
                buffer += struct.pack("<3f", *v)
            views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(buffer) - offset, "target": 34962})
            accessor = {"bufferView": len(views) - 1, "componentType": 5126, "count": len(values), "type": "VEC3"}
            if kind == "POSITION":
                accessor["min"] = [min(v[k] for v in values) for k in range(3)]
                accessor["max"] = [max(v[k] for v in values) for k in range(3)]
            accessors.append(accessor)
            primitive[kind] = len(accessors) - 1
        offset = len(buffer)
        for i in indices:
            buffer += struct.pack("<H", i)
        while len(buffer) % 4: buffer += b"\0"
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(indices) * 2, "target": 34963})
        accessors.append({"bufferView": len(views) - 1, "componentType": 5123, "count": len(indices), "type": "SCALAR"})
        meshes.append({"attributes": {"POSITION": primitive["POSITION"], "NORMAL": primitive["NORMAL"]}, "indices": len(accessors) - 1})
    materials = [
        {"name": "Brass", "pbrMetallicRoughness": {"baseColorFactor": [0.86, 0.66, 0.32, 1], "metallicFactor": 1, "roughnessFactor": 0.28}},
        {"name": "Glass", "alphaMode": "BLEND", "doubleSided": True, "pbrMetallicRoughness": {"baseColorFactor": [0.82, 0.9, 1, 0.22], "metallicFactor": 0, "roughnessFactor": 0.04}},
        {"name": "Walnut", "pbrMetallicRoughness": {"baseColorFactor": [0.36, 0.22, 0.13, 1], "metallicFactor": 0, "roughnessFactor": 0.55}},
    ]
    gltf = {
        "asset": {"version": "2.0", "generator": "Greece fixture generator"},
        "scene": 0, "scenes": [{"nodes": [0, 1, 2]}],
        "nodes": [{"mesh": 0, "name": "Orb"}, {"mesh": 1, "name": "Dome"}, {"mesh": 2, "name": "Plinth"}],
        "meshes": [{"primitives": [dict(p, material=i)]} for i, p in enumerate(meshes)],
        "materials": materials, "accessors": accessors, "bufferViews": views,
        "buffers": [{"byteLength": len(buffer)}],
    }
    text = json.dumps(gltf, separators=(",", ":")).encode()
    text += b" " * ((4 - len(text) % 4) % 4)
    body = struct.pack("<II", len(text), 0x4E4F534A) + text + struct.pack("<II", len(buffer), 0x004E4942) + bytes(buffer)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


# ---------------------------------------------------------------------------- hostile and malformed samples (for tests)

def write_hostile(folder):
    os.makedirs(folder, exist_ok=True)
    # Binary STL claiming far more triangles than it holds.
    with open(os.path.join(folder, "lying.stl"), "wb") as f:
        f.write(b"x" * 80 + struct.pack("<I", 0xFFFFFFF0) + b"\0" * 100)
    # glTF whose node graph is a cycle and whose accessor counts overflow.
    with open(os.path.join(folder, "cycle.gltf"), "w") as f:
        json.dump({"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"children": [1], "mesh": 0}, {"children": [0], "mesh": 0}],
                   "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
                   "accessors": [{"count": 9223372036854775807, "componentType": 5126, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]},
                                 {"count": 9223372036854775807, "componentType": 5125, "type": "SCALAR"}]}, f)
    # GLB with a JSON chunk longer than the file.
    with open(os.path.join(folder, "truncated.glb"), "wb") as f:
        f.write(struct.pack("<IIIII", 0x46546C67, 2, 1000, 900, 0x4E4F534A) + b'{"asset":')
    # LAS whose header points past the end of the file.
    header = bytearray(227)
    header[0:4] = b"LASF"; header[24] = 1; header[25] = 2
    struct.pack_into("<H", header, 94, 227); struct.pack_into("<I", header, 96, 10_000_000); struct.pack_into("<B", header, 104, 2)
    struct.pack_into("<H", header, 105, 26); struct.pack_into("<I", header, 107, 4_000_000_000)
    struct.pack_into("<3d", header, 131, 0.01, 0.01, 0.01)
    with open(os.path.join(folder, "short.las"), "wb") as f:
        f.write(bytes(header))
    # 3MF whose zip directory is garbage.
    with open(os.path.join(folder, "broken.3mf"), "wb") as f:
        f.write(b"PK\x03\x04" + b"\xff" * 200)
    # OBJ that is really a binary object file.
    with open(os.path.join(folder, "coff.obj"), "wb") as f:
        f.write(b"\x4c\x01\x03\x00" + bytes(range(256)) * 4)


def main():
    write_stl_binary(out("gear.stl"), gear_mesh())
    write_stl_ascii(out("ziggurat.stl"))
    write_ply_vase(out("vase.ply"))
    pawn = out("pawn")
    os.makedirs(pawn, exist_ok=True)
    write_obj_pawn(pawn)
    write_3mf(out("bracket.3mf"))
    write_off(out("icosahedron.off"))
    write_3ds(out("table.3ds"))
    write_vrml(out("primitives.wrl"))
    write_vox(out("tree.vox"))
    write_las(out("terrain.las"), terrain_points(15000))
    write_laz(out("hillside.laz"), terrain_points(25000, seed=11))
    write_pcd(out("knot.pcd"))
    write_dae(out("lamp.dae"))
    nodes = fbx_windmill()
    with open(out("windmill.fbx"), "w") as f:
        f.write(fbx_ascii(nodes))
    with open(out("windmill-binary.fbx"), "wb") as f:
        f.write(fbx_binary(nodes))
    write_glass_glb(out("glass.glb"))
    write_hostile(out("hostile"))


if __name__ == "__main__":
    main()
