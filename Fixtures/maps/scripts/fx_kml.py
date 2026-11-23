"""KML 2.2 document around Paris and a KMZ tour of Rome with bundled images."""

import datetime as dt
import io
import math
import os
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image, ImageDraw

from fx_common import orient, write_text, write_zip, xml_escape

KML_NS = "http://www.opengis.net/kml/2.2"
GX_NS = "http://www.google.com/kml/ext/2.2"


def _coords(points, alt=None):
    if alt is None:
        return " ".join("%.6f,%.6f" % (lon, lat) for lon, lat in points)
    return " ".join("%.6f,%.6f,%g" % (lon, lat, alt) for lon, lat in points)


def _ring(points, ccw=True):
    r = orient(points, ccw)
    return r + [r[0]]


# ---------------------------------------------------------------- places.kml

LANDMARKS = [
    # name, lon, lat, style, description (HTML, goes into CDATA), extended data
    ("Eiffel Tower", 2.294481, 48.858370, "#landmarkMap",
     '<p>Wrought-iron lattice tower, completed in <b>1889</b>.</p>'
     '<p><a href="https://en.wikipedia.org/wiki/Eiffel_Tower">Read more on Wikipedia</a></p>',
     [("height_m", "330"), ("opened", "1889-03-31"), ("architect", "Stephen Sauvestre")]),
    ("Louvre Pyramid", 2.335885, 48.861016, "#landmarkMap",
     '<p>Glass and metal pyramid in the main courtyard of the Louvre.</p>'
     '<img src="https://example.com/images/louvre-pyramid.jpg" width="160" alt="Remote image (should not load)">',
     [("height_m", "21.6"), ("opened", "1989")]),
    ("Notre-Dame de Paris", 2.349902, 48.852968, "#landmarkMap",
     '<p>Sanitiser test: the next script must not run.</p><script>alert(1)</script>'
     '<p>Broken image with handler: <img src=x onerror=alert(1)></p>'
     '<p><a href="javascript:alert(1)">javascript: link</a> and a '
     '<a href="https://www.notredamedeparis.fr/">normal link</a>.</p>'
     '<div onclick="alert(1)" style="color:red">click handler</div>',
     [("rebuilt", "2024-12-07")]),
    ("Sacré-Cœur", 2.343076, 48.886705, "#pushpin",
     "<p>Basilica on the summit of Montmartre, <i>the highest point in the city</i>.</p>",
     [("elevation_m", "130")]),
    ("Arc de Triomphe", 2.295028, 48.873792, "#pushpin",
     "<p>Honours those who fought for France. Unicode: « Place Charles-de-Gaulle » — 12 avenues.</p>", []),
    ("Panthéon", 2.346271, 48.846222, "#pushpin", "<p>Neoclassical mausoleum in the Latin Quarter.</p>", []),
    ("Musée d'Orsay", 2.326561, 48.859961, "#landmarkMap",
     "<p>Museum in a former railway station.</p><ul><li>Impressionism</li><li>Post-Impressionism</li></ul>", []),
    ("Centre Pompidou", 2.352245, 48.860642, "#landmarkMap",
     "<table><tr><th>Opened</th><td>1977</td></tr><tr><th>Architects</th><td>Piano &amp; Rogers</td></tr></table>",
     []),
]

SEINE_WALK = [(2.2945, 48.8584), (2.3013, 48.8619), (2.3060, 48.8627), (2.3105, 48.8634), (2.3136, 48.8638),
              (2.3188, 48.8617), (2.3230, 48.8608), (2.3266, 48.8600), (2.3320, 48.8591), (2.3375, 48.8583),
              (2.3410, 48.8573), (2.3440, 48.8535), (2.3490, 48.8530)]

CANAL_WALK = [(2.3660, 48.8530), (2.3680, 48.8580), (2.3655, 48.8630), (2.3640, 48.8690), (2.3700, 48.8740),
              (2.3730, 48.8780)]

LUXEMBOURG = [(2.3318, 48.8490), (2.3340, 48.8467), (2.3368, 48.8442), (2.3392, 48.8437), (2.3405, 48.8452),
              (2.3398, 48.8478), (2.3376, 48.8494), (2.3345, 48.8496)]
GRAND_BASSIN = [(2.3372 + 0.00045 * math.cos(a), 48.8467 + 0.0003 * math.sin(a))
                for a in [2 * math.pi * i / 8 for i in range(8)]]

ILE_CITE = [(2.3400, 48.8573), (2.3445, 48.8560), (2.3510, 48.8532), (2.3530, 48.8519), (2.3505, 48.8510),
            (2.3440, 48.8535), (2.3395, 48.8566)]
ILE_SAINT_LOUIS = [(2.3530, 48.8530), (2.3600, 48.8515), (2.3615, 48.8507), (2.3580, 48.8505), (2.3525, 48.8518)]

MONTMARTRE_TRACK = [(2.3384, 48.8844, 85), (2.3390, 48.8851, 92), (2.3398, 48.8857, 101), (2.3404, 48.8862, 110),
                    (2.3408, 48.8865, 118), (2.3418, 48.8867, 124), (2.3426, 48.8868, 128), (2.3431, 48.8867, 130)]


def make_kml(out_dir):
    L = []
    a = L.append
    a('<?xml version="1.0" encoding="UTF-8"?>')
    a('<kml xmlns="%s" xmlns:gx="%s">' % (KML_NS, GX_NS))
    a('<Document>')
    a('  <name>Paris sampler</name>')
    a('  <open>1</open>')
    a('  <description><![CDATA[<p>Synthetic KML 2.2 fixture: styles, folders, geometry types, '
      'ExtendedData, gx:Track and HTML descriptions (one is hostile, for sanitiser tests).</p>]]></description>')
    a('  <LookAt><longitude>2.3376</longitude><latitude>48.8606</latitude><altitude>0</altitude>'
      '<heading>0</heading><tilt>0</tilt><range>9000</range><altitudeMode>relativeToGround</altitudeMode></LookAt>')
    # shared styles
    a('  <Style id="landmarkNormal">')
    a('    <IconStyle><color>ff0000ff</color><scale>1.1</scale>'
      '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-circle.png</href></Icon>'
      '<hotSpot x="32" y="1" xunits="pixels" yunits="pixels"/></IconStyle>')
    a('    <LabelStyle><scale>0.0</scale></LabelStyle>')
    a('  </Style>')
    a('  <Style id="landmarkHighlight">')
    a('    <IconStyle><color>ff00aaff</color><scale>1.4</scale>'
      '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-circle.png</href></Icon>'
      '<hotSpot x="32" y="1" xunits="pixels" yunits="pixels"/></IconStyle>')
    a('    <LabelStyle><scale>1.0</scale></LabelStyle>')
    a('  </Style>')
    a('  <StyleMap id="landmarkMap">')
    a('    <Pair><key>normal</key><styleUrl>#landmarkNormal</styleUrl></Pair>')
    a('    <Pair><key>highlight</key><styleUrl>#landmarkHighlight</styleUrl></Pair>')
    a('  </StyleMap>')
    a('  <Style id="pushpin">')
    a('    <IconStyle><color>ff00ffff</color><scale>1.0</scale>'
      '<Icon><href>http://maps.google.com/mapfiles/kml/pushpin/ylw-pushpin.png</href></Icon>'
      '<hotSpot x="20" y="2" xunits="pixels" yunits="pixels"/></IconStyle>')
    a('  </Style>')
    a('  <Style id="walkLine">')
    a('    <LineStyle><color>ffd18802</color><width>4</width></LineStyle>')
    a('  </Style>')
    a('  <Style id="parkArea">')
    a('    <LineStyle><color>ff2f8f2f</color><width>2</width></LineStyle>')
    a('    <PolyStyle><color>7f3fbf3f</color><fill>1</fill><outline>1</outline></PolyStyle>')
    a('  </Style>')
    a('  <Style id="islandArea">')
    a('    <IconStyle><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/info-i.png</href></Icon></IconStyle>')
    a('    <LineStyle><color>ff7f3f00</color><width>1.5</width></LineStyle>')
    a('    <PolyStyle><color>66c08040</color></PolyStyle>')
    a('  </Style>')

    a('  <Folder>')
    a('    <name>Landmarks</name>')
    a('    <open>1</open>')
    for name, lon, lat, style, desc, ext in LANDMARKS:
        a('    <Placemark>')
        a('      <name>%s</name>' % xml_escape(name))
        a('      <description><![CDATA[%s]]></description>' % desc)
        a('      <styleUrl>%s</styleUrl>' % style)
        if ext:
            a('      <ExtendedData>')
            for k, v in ext:
                a('        <Data name="%s"><displayName>%s</displayName><value>%s</value></Data>'
                  % (k, xml_escape(k.replace("_", " ").title()), xml_escape(v)))
            a('      </ExtendedData>')
        a('      <Point><coordinates>%.6f,%.6f,0</coordinates></Point>' % (lon, lat))
        a('    </Placemark>')
    a('  </Folder>')

    a('  <Folder>')
    a('    <name>Walks</name>')
    a('    <Placemark>')
    a('      <name>Along the Seine (left bank)</name>')
    a('      <description>Eiffel Tower to Notre-Dame along the quais, about 5 km.</description>')
    a('      <styleUrl>#walkLine</styleUrl>')
    a('      <ExtendedData><Data name="distance_km"><value>5.1</value></Data>'
      '<Data name="surface"><value>paved</value></Data></ExtendedData>')
    a('      <LineString><tessellate>1</tessellate><coordinates>%s</coordinates></LineString>' % _coords(SEINE_WALK, 0))
    a('    </Placemark>')
    a('    <Placemark>')
    a('      <name>Canal Saint-Martin</name>')
    a('      <Style><LineStyle><color>ffb4581f</color><width>3</width></LineStyle></Style>')
    a('      <LineString><coordinates>%s</coordinates></LineString>' % _coords(CANAL_WALK))
    a('    </Placemark>')
    start = dt.datetime(2024, 5, 4, 9, 0, 0)
    a('    <Placemark>')
    a('      <name>Montmartre climb (gx:Track)</name>')
    a('      <styleUrl>#walkLine</styleUrl>')
    a('      <gx:Track>')
    a('        <altitudeMode>absolute</altitudeMode>')
    for i in range(len(MONTMARTRE_TRACK)):
        a('        <when>%s</when>' % (start + dt.timedelta(seconds=45 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"))
    for lon, lat, alt in MONTMARTRE_TRACK:
        a('        <gx:coord>%.6f %.6f %d</gx:coord>' % (lon, lat, alt))
    a('      </gx:Track>')
    a('    </Placemark>')
    a('  </Folder>')

    a('  <Folder>')
    a('    <name>Areas</name>')
    a('    <Placemark>')
    a('      <name>Jardin du Luxembourg</name>')
    a('      <description><![CDATA[<p>Park with the <b>Grand Bassin</b> pond cut out as an inner boundary.</p>]]></description>')
    a('      <styleUrl>#parkArea</styleUrl>')
    a('      <ExtendedData><Data name="area_ha"><value>23</value></Data></ExtendedData>')
    a('      <Polygon>')
    a('        <outerBoundaryIs><LinearRing><coordinates>%s</coordinates></LinearRing></outerBoundaryIs>'
      % _coords(_ring(LUXEMBOURG, True)))
    a('        <innerBoundaryIs><LinearRing><coordinates>%s</coordinates></LinearRing></innerBoundaryIs>'
      % _coords(_ring(GRAND_BASSIN, False)))
    a('      </Polygon>')
    a('    </Placemark>')
    a('    <Placemark>')
    a('      <name>Islands of the Seine</name>')
    a('      <description>MultiGeometry: two polygons and a label point.</description>')
    a('      <styleUrl>#islandArea</styleUrl>')
    a('      <MultiGeometry>')
    for ring in (ILE_CITE, ILE_SAINT_LOUIS):
        a('        <Polygon><outerBoundaryIs><LinearRing><coordinates>%s</coordinates></LinearRing>'
          '</outerBoundaryIs></Polygon>' % _coords(_ring(ring, True)))
    a('        <Point><coordinates>2.350500,48.853200</coordinates></Point>')
    a('      </MultiGeometry>')
    a('    </Placemark>')
    a('  </Folder>')
    a('</Document>')
    a('</kml>')
    write_text(os.path.join(out_dir, "places.kml"), "\n".join(L) + "\n")
    return {"placemarks": len(LANDMARKS) + 3 + 2}


# ---------------------------------------------------------------- tour.kmz

ROME = [
    ("Colosseum", 12.492231, 41.890210, "Amphitheatre completed in 80 AD."),
    ("Pantheon", 12.476873, 41.898614, "Roman temple, now a church; the dome is unreinforced concrete."),
    ("Trevi Fountain", 12.483313, 41.900932, "Baroque fountain finished in 1762."),
    ("St. Peter's Basilica", 12.453389, 41.902167, "In Vatican City."),
    ("Piazza Navona", 12.473074, 41.898946, "Built on the Stadium of Domitian."),
    ("Spanish Steps", 12.482778, 41.905991, "135 steps between Piazza di Spagna and Trinità dei Monti."),
]
OVERLAY_BOX = {"north": 41.9120, "south": 41.8820, "east": 12.5020, "west": 12.4460, "rotation": 0}


def _png(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def marker_png():
    ss = 8
    big = Image.new("RGBA", (32 * ss, 32 * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.ellipse((2 * ss, 2 * ss, 30 * ss, 30 * ss), fill=(255, 255, 255, 255))
    d.ellipse((4 * ss, 4 * ss, 28 * ss, 28 * ss), fill=(214, 69, 65, 255))
    d.ellipse((12 * ss, 12 * ss, 20 * ss, 20 * ss), fill=(255, 255, 255, 230))
    return _png(big.resize((32, 32), Image.Resampling.LANCZOS))


def overlay_png():
    """256x256 semi-transparent overlay: warm wash, grid and a ring."""
    ss = 2
    s = 256 * ss
    img = Image.new("RGBA", (s, s), (255, 196, 120, 70))
    d = ImageDraw.Draw(img)
    for i in range(0, s + 1, 32 * ss):
        d.line([(i, 0), (i, s)], fill=(120, 60, 20, 120), width=ss)
        d.line([(0, i), (s, i)], fill=(120, 60, 20, 120), width=ss)
    d.ellipse((48 * ss, 48 * ss, 208 * ss, 208 * ss), outline=(200, 40, 40, 200), width=4 * ss)
    d.rectangle((0, 0, s - 1, s - 1), outline=(120, 60, 20, 200), width=3 * ss)
    return _png(img.resize((256, 256), Image.Resampling.LANCZOS))


def make_kmz(out_dir):
    L = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<kml xmlns="%s">' % KML_NS,
         '<Document>',
         '  <name>Rome tour</name>',
         '  <description>KMZ fixture: icon and ground overlay images are bundled in files/.</description>',
         '  <Style id="marker">',
         '    <IconStyle><scale>1.0</scale><Icon><href>files/marker.png</href></Icon>'
         '<hotSpot x="0.5" y="0.5" xunits="fraction" yunits="fraction"/></IconStyle>',
         '  </Style>',
         '  <Folder>',
         '    <name>Sights</name>']
    for name, lon, lat, desc in ROME:
        L += ['    <Placemark>', '      <name>%s</name>' % xml_escape(name),
              '      <description>%s</description>' % xml_escape(desc),
              '      <styleUrl>#marker</styleUrl>',
              '      <Point><coordinates>%.6f,%.6f,0</coordinates></Point>' % (lon, lat),
              '    </Placemark>']
    L += ['  </Folder>',
          '  <GroundOverlay>',
          '    <name>Centro storico overlay</name>',
          '    <color>ffffffff</color>',
          '    <drawOrder>1</drawOrder>',
          '    <Icon><href>files/overlay.png</href></Icon>',
          '    <LatLonBox><north>%.4f</north><south>%.4f</south><east>%.4f</east><west>%.4f</west>'
          '<rotation>%d</rotation></LatLonBox>' % (OVERLAY_BOX["north"], OVERLAY_BOX["south"], OVERLAY_BOX["east"],
                                                   OVERLAY_BOX["west"], OVERLAY_BOX["rotation"]),
          '  </GroundOverlay>',
          '</Document>',
          '</kml>']
    doc = ("\n".join(L) + "\n").encode("utf-8")
    write_zip(os.path.join(out_dir, "tour.kmz"),
              [("doc.kml", doc), ("files/marker.png", marker_png()), ("files/overlay.png", overlay_png())])
    return {"placemarks": len(ROME), "ground_overlays": 1}


# ---------------------------------------------------------------- verification

def verify(out_dir):
    ns = {"k": KML_NS, "gx": GX_NS}
    root = ET.parse(os.path.join(out_dir, "places.kml")).getroot()
    res = {"places.kml": {
        "folders": [f.findtext("k:name", namespaces=ns) for f in root.findall(".//k:Folder", ns)],
        "placemarks": len(root.findall(".//k:Placemark", ns)),
        "styles": len(root.findall("k:Document/k:Style", ns)),
        "stylemaps": len(root.findall("k:Document/k:StyleMap", ns)),
        "gx_track_when": len(root.findall(".//gx:Track/k:when", ns)),
        "gx_track_coord": len(root.findall(".//gx:Track/gx:coord", ns)),
        "has_script_in_description": any("<script>" in (d.text or "") for d in root.iter("{%s}description" % KML_NS)),
    }}
    with zipfile.ZipFile(os.path.join(out_dir, "tour.kmz")) as zf:
        assert zf.testzip() is None
        names = zf.namelist()
        assert names[0] == "doc.kml"
        assert all(i.compress_type == zipfile.ZIP_DEFLATED for i in zf.infolist())
        kml = ET.fromstring(zf.read("doc.kml"))
        hrefs = [h.text for h in kml.iter("{%s}href" % KML_NS)]
        assert all(h in names for h in hrefs), hrefs
        imgs = {n: Image.open(io.BytesIO(zf.read(n))) for n in names if n.endswith(".png")}
        res["tour.kmz"] = {"members": names, "hrefs": hrefs,
                           "images": {n: (im.size, im.mode) for n, im in imgs.items()},
                           "overlay_alpha_range": imgs["files/overlay.png"].getchannel("A").getextrema()}
    return res
