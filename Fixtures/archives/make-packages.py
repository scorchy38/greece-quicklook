#!/usr/bin/env python3
"""Builds the package and comic fixtures from scratch (fictional packages, generated art).

    swift Fixtures/archives/make-images.swift /tmp/images
    python3 -I Fixtures/archives/make-packages.py /tmp/images Fixtures/archives

Needs `zstd` on PATH (for the .deb's data.tar.zst and the RPM's zstd payload) and /usr/bin/tar.
"""
import gzip, io, json, lzma, os, struct, subprocess, sys, tarfile, time, zipfile

images, out = sys.argv[1], sys.argv[2]
packages = os.path.join(out, "packages")
comics = os.path.join(out, "comics")
os.makedirs(packages, exist_ok=True)
os.makedirs(comics, exist_ok=True)
MTIME = 1_763_700_000  # 21 November 2025, fixed so rebuilds are identical
DATE = (2025, 11, 21, 4, 40, 0)


def image(name):
    with open(os.path.join(images, name), "rb") as f:
        return f.read()


def zip_file(path, members, stored=()):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in members:
            info = zipfile.ZipInfo(name, DATE)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_STORED if name in stored or name.endswith((".png", ".jpg")) else zipfile.ZIP_DEFLATED
            z.writestr(info, data)


def tar_bytes(members, mode="w"):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode=mode, format=tarfile.GNU_FORMAT) as t:
        for name, data in members:
            info = tarfile.TarInfo(name)
            info.size, info.mtime, info.mode = len(data), MTIME, 0o755 if "/bin/" in name else 0o644
            t.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def gz(data):
    return gzip.compress(data, mtime=MTIME)


def zstd(data):
    return subprocess.run(["zstd", "-q", "-19", "-c"], input=data, check=True, capture_output=True).stdout


SCRIPT = b"#!/bin/sh\necho 'Harbourmaster: berth A1 is free.'\n"
LIB = b'"""Assigns berths to ferries arriving at Aegean harbours."""\n\n__version__ = "2.4.1"\n\ndef assign(ship, harbour):\n    return harbour.free_berths()[0]\n'
README = b"# Harbourmaster\n\nAssigns berths to ferries arriving at Aegean harbours.\n"

# --- Python wheel and sdist --------------------------------------------------------------------

METADATA = b"""Metadata-Version: 2.3
Name: harbourmaster
Version: 2.4.1
Summary: Assigns berths to ferries arriving at Aegean harbours.
Project-URL: Homepage, https://example.org/harbourmaster
Author-email: Eleni Papadaki <eleni@example.org>
License-Expression: MIT
Requires-Python: >=3.9
Requires-Dist: attrs>=23.1
Requires-Dist: python-dateutil>=2.8
Requires-Dist: tzdata; platform_system == "Windows"
Requires-Dist: pytest>=8; extra == "test"
Provides-Extra: test
Description-Content-Type: text/markdown

# Harbourmaster
"""
zip_file(os.path.join(packages, "harbourmaster-2.4.1-py3-none-any.whl"), [
    ("harbourmaster/__init__.py", LIB),
    ("harbourmaster/berths.py", b"BERTHS = ['A1', 'A2', 'B1']\n"),
    ("harbourmaster-2.4.1.dist-info/METADATA", METADATA),
    ("harbourmaster-2.4.1.dist-info/WHEEL", b"Wheel-Version: 1.0\nGenerator: hatchling 1.25.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n"),
    ("harbourmaster-2.4.1.dist-info/licenses/LICENSE", b"MIT License\n"),
    ("harbourmaster-2.4.1.dist-info/RECORD", b"harbourmaster/__init__.py,,\n"),
])
with open(os.path.join(packages, "harbourmaster-2.4.1.tar.gz"), "wb") as f:
    f.write(gz(tar_bytes([
        ("harbourmaster-2.4.1/PKG-INFO", METADATA.replace(b"Metadata-Version: 2.3", b"Metadata-Version: 2.1")),
        ("harbourmaster-2.4.1/pyproject.toml", b'[project]\nname = "harbourmaster"\nversion = "2.4.1"\n'),
        ("harbourmaster-2.4.1/README.md", README),
        ("harbourmaster-2.4.1/src/harbourmaster/__init__.py", LIB),
    ])))

# --- Java -------------------------------------------------------------------------------------

CLASS = b"\xca\xfe\xba\xbe\x00\x00\x00\x41" + bytes(64)
zip_file(os.path.join(packages, "lighthouse-1.3.0.jar"), [
    ("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\nCreated-By: Maven JAR Plugin 3.4.1\r\nBuild-Jdk-Spec: 21\r\n"
                             b"Implementation-Title: Lighthouse\r\nImplementation-Version: 1.3.0\r\nImplementation-Vendor: Aegean Lig\r\n ht Company\r\n"
                             b"Main-Class: gr.aegean.lighthouse.Keeper\r\nAutomatic-Module-Name: gr.aegean.lighthouse\r\n\r\n"),
    ("META-INF/maven/gr.aegean/lighthouse/pom.properties", b"groupId=gr.aegean\nartifactId=lighthouse\nversion=1.3.0\n"),
    ("gr/aegean/lighthouse/Keeper.class", CLASS),
    ("gr/aegean/lighthouse/Beam.class", CLASS),
    ("gr/aegean/lighthouse/Weather.class", CLASS),
    ("lighthouse.properties", b"beam.interval=10\n"),
])

# --- NuGet ------------------------------------------------------------------------------------

NUSPEC = b"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>Aegean.Ferries</id>
    <version>3.1.0</version>
    <title>Aegean Ferries</title>
    <authors>Aegean Labs</authors>
    <license type="expression">Apache-2.0</license>
    <icon>images/icon.png</icon>
    <projectUrl>https://example.org/ferries</projectUrl>
    <description>Timetables and live positions for ferries between the Greek islands.</description>
    <tags>ferries greece timetable</tags>
    <dependencies>
      <group targetFramework="net8.0">
        <dependency id="System.Text.Json" version="8.0.4" />
      </group>
      <group targetFramework="netstandard2.0">
        <dependency id="System.Text.Json" version="8.0.4" />
        <dependency id="Microsoft.Bcl.AsyncInterfaces" version="8.0.0" />
      </group>
    </dependencies>
  </metadata>
</package>
"""
zip_file(os.path.join(packages, "Aegean.Ferries.3.1.0.nupkg"), [
    ("Aegean.Ferries.nuspec", NUSPEC),
    ("lib/net8.0/Aegean.Ferries.dll", b"MZ" + bytes(126)),
    ("lib/netstandard2.0/Aegean.Ferries.dll", b"MZ" + bytes(126)),
    ("images/icon.png", image("icon-waves.png")),
    ("[Content_Types].xml", b"<Types/>"),
])

# --- Editors and browsers ---------------------------------------------------------------------

# An agent skill: SKILL.md with front matter, plus the scripts and references it bundles.
zip_file(os.path.join(packages, "harbour-forms.skill"), [
    ("harbour-forms/SKILL.md", b"""---
name: harbour-forms
description: >
  Fills in and checks Aegean harbour permit forms (PDF). Use when the user asks to complete,
  validate or summarise a berth or ferry permit.
license: Apache-2.0
allowed-tools:
  - Bash
  - Read
metadata:
  version: 1.4.0
---

# Harbour forms

Fill permit forms with `scripts/fill_form.py`, then check them against
[the field reference](references/fields.md).

## Steps

1. Read the form's fields.
2. Fill them from the user's details.
3. Validate the dates and the berth number.
"""),
    ("harbour-forms/scripts/fill_form.py", b"import sys\n\nprint('filling', sys.argv[1])\n"),
    ("harbour-forms/scripts/validate.py", b"def validate(form):\n    return bool(form)\n"),
    ("harbour-forms/references/fields.md", b"# Fields\n\n- berth\n- vessel\n- arrival\n"),
])

zip_file(os.path.join(packages, "ferry-tracker-0.9.2.vsix"), [
    ("extension.vsixmanifest", b'<PackageManifest Version="2.0.0"><Metadata><Identity Id="ferry-tracker" Version="0.9.2" Publisher="aegean-labs"/>'
                               b"<DisplayName>Ferry Tracker</DisplayName></Metadata></PackageManifest>"),
    ("extension/package.json", json.dumps({
        "name": "ferry-tracker", "displayName": "Ferry Tracker", "version": "0.9.2", "publisher": "aegean-labs",
        "description": "See which ferries are at sea, right in the status bar.", "license": "MIT",
        "engines": {"vscode": "^1.90.0"}, "categories": ["Visualization", "Other"], "icon": "images/icon.png",
        "extensionDependencies": ["aegean-labs.harbour-maps"],
    }, indent=2).encode()),
    ("extension/out/extension.js", b"exports.activate = () => {};\n"),
    ("extension/images/icon.png", image("icon-ferry.png")),
    ("extension/README.md", b"# Ferry Tracker\n"),
])

MANIFEST = {
    "manifest_version": 3, "name": "__MSG_extensionName__", "version": "1.2", "description": "__MSG_extensionDescription__",
    "default_locale": "en", "permissions": ["alarms", "storage"], "host_permissions": ["https://example.org/*"],
    "icons": {"48": "icons/icon-48.png", "128": "icons/icon-128.png"},
    "background": {"service_worker": "background.js"},
}
MESSAGES = json.dumps({"extensionName": {"message": "Tide Clock"},
                       "extensionDescription": {"message": "High and low tide for your harbour, in the toolbar."}}).encode()
browser = [
    ("_locales/en/messages.json", MESSAGES),
    ("background.js", b"chrome.alarms.create('tide', {periodInMinutes: 30});\n"),
    ("icons/icon-128.png", image("icon-sun.png")),
]
firefox = dict(MANIFEST, browser_specific_settings={"gecko": {"id": "tide-clock@example.org"}})
zip_file(os.path.join(packages, "tide-clock-1.2.xpi"), [("manifest.json", json.dumps(firefox, indent=2).encode())] + browser)
crx_zip = io.BytesIO()
with zipfile.ZipFile(crx_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in [("manifest.json", json.dumps(MANIFEST, indent=2).encode())] + browser:
        z.writestr(zipfile.ZipInfo(name, DATE), data)
header = b"\x82\xf1\x04\x05\x0a\x03abc"  # a stand-in CrxFileHeader; Greece doesn't verify signatures
with open(os.path.join(packages, "tide-clock-1.2.crx"), "wb") as f:
    f.write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + crx_zip.getvalue())

# --- Android: binary XML (APK) and protobuf XML (AAB) -----------------------------------------

ANDROID = "http://schemas.android.com/apk/res/android"
ATTRS = [("versionCode", 0x0101021B), ("versionName", 0x0101021C), ("minSdkVersion", 0x0101020C),
         ("targetSdkVersion", 0x01010270), ("name", 0x01010003), ("label", 0x01010001), ("icon", 0x01010002)]
PERMISSIONS = ["android.permission.INTERNET", "android.permission.ACCESS_FINE_LOCATION", "android.permission.POST_NOTIFICATIONS"]
TREE = ("manifest", [(None, "package", "gr.aegean.lighthouse"), (ANDROID, "versionCode", 42), (ANDROID, "versionName", "3.2.0")], [
    ("uses-sdk", [(ANDROID, "minSdkVersion", 26), (ANDROID, "targetSdkVersion", 35)], []),
] + [("uses-permission", [(ANDROID, "name", p)], []) for p in PERMISSIONS] + [
    ("application", [(ANDROID, "label", "Lighthouse Keeper"), (ANDROID, "icon", ("ref", 0x7F0D0000))], []),
])


def axml(tree):
    strings = [name for name, _ in ATTRS]
    def index(s):
        if s not in strings:
            strings.append(s)
        return strings.index(s)
    for s in ["android", ANDROID]:
        index(s)
    body = b""

    def element(node):
        nonlocal body
        name, attributes, children = node
        attrs = b""
        for namespace, key, value in attributes:
            ns = index(namespace) if namespace else 0xFFFFFFFF
            if isinstance(value, int):
                raw, kind, data = 0xFFFFFFFF, 0x10, value
            elif isinstance(value, tuple):
                raw, kind, data = 0xFFFFFFFF, 0x01, value[1]
            else:
                raw = index(value)
                kind, data = 0x03, raw
            attrs += struct.pack("<IIIHBBI", ns, index(key), raw, 8, 0, kind, data)
        start = struct.pack("<II", 1, 0xFFFFFFFF) + struct.pack("<IIHHHHHH", 0xFFFFFFFF, index(name), 20, 20, len(attributes), 0, 0, 0) + attrs
        body += struct.pack("<HHI", 0x0102, 16, 8 + len(start)) + start
        for child in children:
            element(child)
        end = struct.pack("<II", 1, 0xFFFFFFFF) + struct.pack("<II", 0xFFFFFFFF, index(name))
        body += struct.pack("<HHI", 0x0103, 16, 8 + len(end)) + end
    namespace = struct.pack("<IIII", 1, 0xFFFFFFFF, index("android"), index(ANDROID))
    element(tree)
    body = struct.pack("<HHI", 0x0100, 16, 8 + len(namespace)) + namespace + body + struct.pack("<HHI", 0x0101, 16, 8 + len(namespace)) + namespace
    offsets, data = b"", b""
    for s in strings:
        offsets += struct.pack("<I", len(data))
        encoded = s.encode("utf-16-le")
        data += struct.pack("<H", len(s)) + encoded + b"\0\0"
    while len(data) % 4:
        data += b"\0"
    pool_header = 28
    pool = struct.pack("<IIIII", len(strings), 0, 0, pool_header + len(offsets), 0) + offsets + data
    pool = struct.pack("<HHI", 0x0001, pool_header, 8 + len(pool)) + pool
    ids = b"".join(struct.pack("<I", value) for _, value in ATTRS)
    resources = struct.pack("<HHI", 0x0180, 8, 8 + len(ids)) + ids
    content = pool + resources + body
    return struct.pack("<HHI", 0x0003, 8, 8 + len(content)) + content


def varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        out += bytes([byte | (0x80 if value else 0)])
        if not value:
            return out


def field(number, payload):
    return varint(number << 3 | 2) + varint(len(payload)) + payload


def proto_node(node):
    name, attributes, children = node
    element = field(3, name.encode())
    for namespace, key, value in attributes:
        attribute = (field(1, namespace.encode()) if namespace else b"") + field(2, key.encode())
        attribute += field(3, (str(value) if not isinstance(value, tuple) else "@mipmap/ic_launcher").encode())
        resource = dict(ATTRS).get(key) if namespace else None
        if resource:
            attribute += varint(5 << 3) + varint(resource)
        element += field(4, attribute)
    for child in children:
        element += field(5, proto_node(child))
    return field(1, element)


zip_file(os.path.join(packages, "lighthouse-keeper.apk"), [
    ("AndroidManifest.xml", axml(TREE)),
    ("classes.dex", b"dex\n035\0" + bytes(104)),
    ("classes2.dex", b"dex\n035\0" + bytes(104)),
    ("resources.arsc", b"\x02\x00\x0c\x00" + bytes(60)),
    ("res/mipmap-xxxhdpi-v4/ic_launcher.png", image("icon-sailboat.png")),
    ("lib/arm64-v8a/liblighthouse.so", b"\x7fELF" + bytes(60)),
    ("lib/x86_64/liblighthouse.so", b"\x7fELF" + bytes(60)),
    ("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\nCreated-By: Android Gradle 8.7\r\n\r\n"),
], stored={"resources.arsc"})
zip_file(os.path.join(packages, "lighthouse-keeper.aab"), [
    ("base/manifest/AndroidManifest.xml", proto_node(TREE)),
    ("base/dex/classes.dex", b"dex\n035\0" + bytes(104)),
    ("BundleConfig.pb", b"\x0a\x05\x0a\x031.0"),
])

# --- Ruby gem ---------------------------------------------------------------------------------

GEMSPEC = b"""--- !ruby/object:Gem::Specification
name: harbourmaster
version: !ruby/object:Gem::Version
  version: 2.4.1
platform: ruby
authors:
- Eleni Papadaki
- Nikos Georgiou
bindir: exe
cert_chain: []
date: 2025-11-21 00:00:00.000000000 Z
dependencies:
- !ruby/object:Gem::Dependency
  name: concurrent-ruby
  requirement: !ruby/object:Gem::Requirement
    requirements:
    - - "~>"
      - !ruby/object:Gem::Version
        version: '1.3'
  type: :runtime
  prerelease: false
  version_requirements: !ruby/object:Gem::Requirement
    requirements:
    - - "~>"
      - !ruby/object:Gem::Version
        version: '1.3'
- !ruby/object:Gem::Dependency
  name: rspec
  requirement: !ruby/object:Gem::Requirement
    requirements:
    - - ">="
      - !ruby/object:Gem::Version
        version: '0'
  type: :development
  prerelease: false
description: Assigns berths to ferries arriving at Aegean harbours.
email:
- eleni@example.org
executables:
- harbourmaster
files:
- lib/harbourmaster.rb
homepage: https://example.org/harbourmaster
licenses:
- MIT
metadata: {}
required_ruby_version: !ruby/object:Gem::Requirement
  requirements:
  - - ">="
    - !ruby/object:Gem::Version
      version: 3.1.0
summary: Berths for Aegean ferries
"""
gem_data = gz(tar_bytes([("lib/harbourmaster.rb", b"module Harbourmaster\n  VERSION = '2.4.1'\nend\n"),
                         ("lib/harbourmaster/berth.rb", b"class Berth; end\n"),
                         ("exe/harbourmaster", SCRIPT), ("README.md", README)]))
with open(os.path.join(packages, "harbourmaster-2.4.1.gem"), "wb") as f:
    f.write(tar_bytes([("metadata.gz", gz(GEMSPEC)), ("data.tar.gz", gem_data), ("checksums.yaml.gz", gz(b"---\n"))]))

# --- Debian package ---------------------------------------------------------------------------

CONTROL = b"""Package: harbourmaster
Version: 2.4.1-1
Architecture: arm64
Maintainer: Eleni Papadaki <eleni@example.org>
Installed-Size: 184
Depends: libc6 (>= 2.34), python3 (>= 3.9), python3-attr
Section: utils
Priority: optional
Homepage: https://example.org/harbourmaster
Description: berths for Aegean ferries
 Harbourmaster assigns berths to ferries arriving at Aegean harbours,
 and prints the day's arrivals.
"""
control_tar = lzma.compress(tar_bytes([("./control", CONTROL), ("./md5sums", b"d41d8cd98f00b204e9800998ecf8427e  usr/bin/harbourmaster\n")]))
data_tar = zstd(tar_bytes([("./usr/bin/harbourmaster", SCRIPT), ("./usr/lib/python3/dist-packages/harbourmaster/__init__.py", LIB),
                           ("./usr/share/doc/harbourmaster/README.md", README)]))


def ar_member(name, data):
    header = f"{name:<16}{MTIME:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}`\n".encode()
    return header + data + (b"\n" if len(data) % 2 else b"")


with open(os.path.join(packages, "harbourmaster_2.4.1-1_arm64.deb"), "wb") as f:
    f.write(b"!<arch>\n" + ar_member("debian-binary", b"2.0\n") + ar_member("control.tar.xz", control_tar) + ar_member("data.tar.zst", data_tar))

# --- RPM with a zstd payload ------------------------------------------------------------------


def cpio(files):
    out = b""
    for number, (name, data, mode) in enumerate(files + [("TRAILER!!!", b"", 0)], start=1):
        encoded = name.encode() + b"\0"
        header = b"070701" + b"".join(f"{v:08x}".encode() for v in [number, mode, 0, 0, 1, MTIME, len(data), 0, 0, 0, 0, len(encoded), 0])
        out += header + encoded
        out += b"\0" * (-len(out) % 4) + data
        out += b"\0" * (-len(out) % 4)
    return out


def rpm_header(entries):
    index, store = b"", b""
    for tag, kind, value in sorted(entries):
        align = {3: 2, 4: 4, 5: 8}.get(kind, 1)
        store += b"\0" * (-len(store) % align)
        offset = len(store)
        if kind == 6:
            data, count = value.encode() + b"\0", 1
        elif kind in (8, 9):
            data, count = b"".join(s.encode() + b"\0" for s in value), len(value)
        else:
            fmt = {3: ">H", 4: ">i", 5: ">q"}[kind]
            data, count = b"".join(struct.pack(fmt, v) for v in value), len(value)
        store += data
        index += struct.pack(">iiii", tag, kind, offset, count)
    return b"\x8e\xad\xe8\x01" + bytes(4) + struct.pack(">ii", len(entries), len(store)) + index + store


files = [("./usr/bin/harbourmaster", SCRIPT, 0o100755), ("./usr/share/doc/harbourmaster/README.md", README, 0o100644)]
payload = zstd(cpio(files))
lead = b"\xed\xab\xee\xdb\x03\x00" + struct.pack(">hh", 0, 1) + b"harbourmaster-2.4.1-1".ljust(66, b"\0") + struct.pack(">hh", 1, 5) + bytes(16)
signature = rpm_header([(1000, 4, [len(payload)])])
signature += b"\0" * (-len(signature) % 8)
header = rpm_header([
    (1000, 6, "harbourmaster"), (1001, 6, "2.4.1"), (1002, 6, "1"), (1004, 9, ["Berths for Aegean ferries"]),
    (1005, 9, ["Harbourmaster assigns berths to ferries arriving at Aegean harbours."]), (1006, 4, [MTIME]),
    (1009, 4, [len(SCRIPT) + len(README)]), (1011, 6, "Aegean Labs"), (1014, 6, "MIT"), (1016, 9, ["Applications/System"]),
    (1020, 6, "https://example.org/harbourmaster"), (1021, 6, "linux"), (1022, 6, "x86_64"),
    (1028, 4, [len(SCRIPT), len(README)]), (1030, 3, [0o100755, 0o100644]), (1034, 4, [MTIME, MTIME]),
    (1049, 8, ["/bin/sh", "python3", "python3-attrs", "rpmlib(CompressedFileNames)"]),
    (1116, 4, [0, 1]), (1117, 8, ["harbourmaster", "README.md"]), (1118, 8, ["/usr/bin/", "/usr/share/doc/harbourmaster/"]),
    (1124, 6, "cpio"), (1125, 6, "zstd"),
])
with open(os.path.join(packages, "harbourmaster-2.4.1-1.x86_64.rpm"), "wb") as f:
    f.write(lead + signature + header + payload)

# --- npm --------------------------------------------------------------------------------------

with open(os.path.join(packages, "tide-clock-1.2.0.tgz"), "wb") as f:
    f.write(gz(tar_bytes([
        ("package/package.json", json.dumps({
            "name": "@aegean/tide-clock", "version": "1.2.0", "description": "High and low tide times for Greek harbours.",
            "license": "MIT", "author": "Eleni Papadaki <eleni@example.org>", "type": "module", "engines": {"node": ">=18"},
            "dependencies": {"date-fns": "^4.1.0", "suncalc": "^1.9.0"},
        }, indent=2).encode()),
        ("package/index.js", b"export const tides = () => [];\n"),
        ("package/README.md", b"# Tide Clock\n"),
    ])))

# --- Comics -----------------------------------------------------------------------------------

COMIC_INFO = b"""<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Title>The Crossing</Title>
  <Series>Aegean Tales</Series>
  <Number>1</Number>
  <Year>2026</Year>
  <Writer>Eleni Papadaki</Writer>
  <Summary>A ferry, a storm and a very persistent gull.</Summary>
  <PageCount>8</PageCount>
  <LanguageISO>en</LanguageISO>
</ComicInfo>
"""
pages = [f"page-{n:02d}.jpg" for n in range(1, 9)]
zip_file(os.path.join(comics, "Aegean Tales 01.cbz"),
         [("ComicInfo.xml", COMIC_INFO)] + [(f"Aegean Tales 01/{p}", image(p)) for p in pages])
with open(os.path.join(comics, "Aegean Tales 01.cbt"), "wb") as f:
    f.write(tar_bytes([(p, image(p)) for p in pages[:3]]))
stage = os.path.join(images, "cb7")
os.makedirs(stage, exist_ok=True)
for p in pages[:3]:
    with open(os.path.join(stage, p), "wb") as f:
        f.write(image(p))
subprocess.run(["/usr/bin/tar", "--format", "7zip", "-cf", os.path.abspath(os.path.join(comics, "Aegean Tales 01.cb7")), *pages[:3]], cwd=stage, check=True)

for folder in (packages, comics):
    for name in sorted(os.listdir(folder)):
        print(f"{os.path.getsize(os.path.join(folder, name)):>8}  {name}")
