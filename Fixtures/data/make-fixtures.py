#!/usr/bin/env python3
"""Writes the data fixtures in this folder. Deterministic: run it again and nothing changes.

    python3 -I Fixtures/data/make-fixtures.py

Everything here is synthetic. See SOURCES.md.
"""
import datetime, json, os, random, sqlite3, struct

HERE = os.path.dirname(os.path.abspath(__file__))
rng = random.Random(1821)


def path(*parts):
    full = os.path.join(HERE, *parts)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    return full


ISLANDS = [
    # name, group, area km², population, highest point m, airport
    ("Naxos", "Cyclades", 430, 18904, 1004, True), ("Andros", "Cyclades", 380, 9221, 994, False),
    ("Paros", "Cyclades", 196, 13715, 724, True), ("Tinos", "Cyclades", 194, 8636, 729, False),
    ("Milos", "Cyclades", 151, 4977, 748, True), ("Kea", "Cyclades", 131, 2455, 568, False),
    ("Amorgos", "Cyclades", 121, 1973, 821, False), ("Ios", "Cyclades", 109, 2024, 723, False),
    ("Kythnos", "Cyclades", 99, 1456, 336, False), ("Mykonos", "Cyclades", 86, 10704, 341, True),
    ("Syros", "Cyclades", 84, 21507, 442, True), ("Santorini", "Cyclades", 76, 15550, 567, True),
    ("Serifos", "Cyclades", 75, 1420, 585, False), ("Sifnos", "Cyclades", 74, 2625, 678, False),
    ("Folegandros", "Cyclades", 32, 765, 414, False), ("Crete", "Crete", 8336, 624408, 2456, True),
    ("Rhodes", "Dodecanese", 1401, 125113, 1216, True), ("Kos", "Dodecanese", 290, 33388, 843, True),
    ("Karpathos", "Dodecanese", 301, 6226, 1215, True), ("Patmos", "Dodecanese", 34, 3283, 269, False),
    ("Corfu", "Ionian", 593, 102071, 906, True), ("Kefalonia", "Ionian", 781, 35801, 1628, True),
    ("Zakynthos", "Ionian", 406, 40759, 756, True), ("Lefkada", "Ionian", 336, 22652, 1158, False),
    ("Ithaca", "Ionian", 118, 2862, 806, False), ("Lesbos", "North Aegean", 1633, 83755, 967, True),
    ("Chios", "North Aegean", 842, 51390, 1297, True), ("Samos", "North Aegean", 478, 32642, 1434, True),
    ("Ikaria", "North Aegean", 255, 8423, 1037, True), ("Euboea", "Euboea", 3684, 191206, 1743, False),
    ("Skiathos", "Sporades", 50, 6088, 433, True), ("Skopelos", "Sporades", 96, 4960, 680, False),
    ("Aegina", "Saronic", 87, 13056, 531, False), ("Hydra", "Saronic", 64, 1966, 593, False),
]


def islands_tsv():
    lines = ["name\tgroup\tarea_km2\tpopulation\thighest_point_m\tairport\tfirst_ferry\tdensity\tnotes"]
    notes = ["Marble quarries", "", "Windmills", "", "Volcanic beaches", "", "Monastery on a cliff", "", ""]
    for i, (name, group, area, pop, peak, airport) in enumerate(ISLANDS):
        day = datetime.date(1952, 1, 1) + datetime.timedelta(days=rng.randrange(0, 365 * 60))
        density = f"{pop / area:.1f}"
        lines.append("\t".join([name, group, str(area), f"{pop:,}" if i % 7 == 3 else str(pop), str(peak),
                                "yes" if airport else "no", day.isoformat() if i % 9 != 4 else "", density,
                                notes[i % len(notes)]]))
    open(path("islands.tsv"), "w").write("\n".join(lines) + "\n")


def voyages_psv():
    ports = ["Piraeus", "Rafina", "Lavrio", "Heraklion", "Syros", "Naxos", "Paros", "Mykonos", "Santorini", "Milos"]
    operators = ["Blue Star Ferries", "Seajets", "Golden Star", "Minoan Lines", "Fast Ferries", "Zante Ferries"]
    lines = ["voyage|departs|origin|destination|operator|minutes|fare_eur|on_time"]
    start = datetime.datetime(2025, 6, 1, 6, 0)
    for n in range(1, 241):
        origin, destination = rng.sample(ports, 2)
        departs = start + datetime.timedelta(minutes=37 * n + rng.randrange(0, 30))
        minutes = rng.choice([35, 40, 50, 60, 75, 90, 110, 120, 135, 170, 240, 300])
        fare = round(minutes * rng.uniform(0.18, 0.42), 2)
        on_time = rng.random() > 0.18
        lines.append("|".join([f"V{n:04d}", departs.strftime("%Y-%m-%dT%H:%M"), origin, destination,
                               rng.choice(operators), str(minutes), f"{fare:.2f}", "true" if on_time else "false"]))
    open(path("voyages.psv"), "w").write("\n".join(lines) + "\n")


PNG_PIXEL = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360f8cf00000301010018dd8db00000000049454e44ae426082")


def harbour_sqlite():
    """A small ferry company: foreign keys (one self-referencing, one composite), indexes,
    a WITHOUT ROWID table, a view, a trigger and blobs."""
    out = path("harbour.sqlite")
    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript("""
        PRAGMA foreign_keys = ON;
        CREATE TABLE ports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            island TEXT,
            latitude REAL, longitude REAL
        );
        CREATE TABLE operators (id INTEGER PRIMARY KEY, name TEXT NOT NULL, founded INTEGER, website TEXT);
        CREATE TABLE vessels (
            id INTEGER PRIMARY KEY,
            operator_id INTEGER NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            built INTEGER CHECK (built > 1900),
            capacity INTEGER DEFAULT 0,
            photo BLOB
        );
        CREATE TABLE crew (
            id INTEGER PRIMARY KEY,
            vessel_id INTEGER REFERENCES vessels(id),
            manager_id INTEGER REFERENCES crew(id),
            name TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'deckhand'
        );
        CREATE TABLE routes (
            id INTEGER PRIMARY KEY,
            origin_id INTEGER NOT NULL REFERENCES ports(id),
            destination_id INTEGER NOT NULL REFERENCES ports(id),
            operator_id INTEGER NOT NULL REFERENCES operators(id),
            minutes INTEGER NOT NULL,
            seasonal INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE fares (
            route_id INTEGER NOT NULL REFERENCES routes(id),
            class TEXT NOT NULL,
            price_eur REAL NOT NULL,
            PRIMARY KEY (route_id, class)
        ) WITHOUT ROWID;
        CREATE TABLE sailings (
            id INTEGER PRIMARY KEY,
            route_id INTEGER NOT NULL REFERENCES routes(id),
            vessel_id INTEGER NOT NULL REFERENCES vessels(id),
            departs TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'scheduled'
        );
        CREATE TABLE passengers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, country TEXT);
        CREATE TABLE tickets (
            id INTEGER PRIMARY KEY,
            sailing_id INTEGER NOT NULL REFERENCES sailings(id) ON DELETE CASCADE,
            passenger_id INTEGER NOT NULL REFERENCES passengers(id),
            route_id INTEGER, class TEXT,
            seat TEXT,
            issued TEXT NOT NULL,
            FOREIGN KEY (route_id, class) REFERENCES fares(route_id, class)
        );
        CREATE TABLE weather_log (observed TEXT, port TEXT, wind_knots REAL, note TEXT);
        CREATE INDEX sailings_departs ON sailings(departs);
        CREATE INDEX tickets_passenger ON tickets(passenger_id, issued);
        CREATE INDEX routes_pair ON routes(origin_id, destination_id) WHERE seasonal = 0;
        CREATE VIEW busy_routes AS
            SELECT r.id, o.name AS origin, d.name AS destination, count(t.id) AS tickets
            FROM routes r JOIN ports o ON o.id = r.origin_id JOIN ports d ON d.id = r.destination_id
            LEFT JOIN sailings s ON s.route_id = r.id LEFT JOIN tickets t ON t.sailing_id = s.id
            GROUP BY r.id ORDER BY tickets DESC;
        CREATE TRIGGER tickets_issue AFTER INSERT ON tickets
            BEGIN UPDATE sailings SET status = 'boarding' WHERE id = NEW.sailing_id AND status = 'scheduled'; END;
    """)
    ports = ["Piraeus", "Rafina", "Lavrio", "Heraklion", "Syros", "Naxos", "Paros", "Mykonos", "Santorini", "Milos", "Ios", "Tinos"]
    for name in ports:
        db.execute("INSERT INTO ports (name, island, latitude, longitude) VALUES (?, ?, ?, ?)",
                   (name, None if name in ("Piraeus", "Rafina", "Lavrio") else name, round(rng.uniform(36, 38.5), 4), round(rng.uniform(23, 26), 4)))
    operators = [("Blue Star Ferries", 2000), ("Seajets", 1989), ("Golden Star", 2009), ("Minoan Lines", 1972), ("Fast Ferries", 1989)]
    for i, (name, founded) in enumerate(operators, 1):
        db.execute("INSERT INTO operators VALUES (?, ?, ?, ?)", (i, name, founded, f"https://example.com/{i}"))
    for v in range(1, 19):
        db.execute("INSERT INTO vessels VALUES (?, ?, ?, ?, ?, ?)",
                   (v, rng.randint(1, 5), f"{rng.choice(['Aegean', 'Blue', 'Cyclades', 'Delos', 'Express'])} {v}", rng.randint(1975, 2022),
                    rng.choice([350, 800, 1200, 1800, 2400]), PNG_PIXEL if v % 3 == 0 else None))
    for c in range(1, 61):
        db.execute("INSERT INTO crew VALUES (?, ?, ?, ?, ?)",
                   (c, rng.randint(1, 18), None if c <= 5 else rng.randint(1, 5), f"Crew {c}", rng.choice(["captain", "engineer", "deckhand", "steward"])))
    r = 0
    for o in range(1, len(ports) + 1):
        for d in rng.sample(range(1, len(ports) + 1), 3):
            if d == o:
                continue
            r += 1
            db.execute("INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?)", (r, o, d, rng.randint(1, 5), rng.choice([35, 50, 90, 120, 240]), int(rng.random() < 0.3)))
            for cls, factor in (("deck", 1.0), ("cabin", 2.4)):
                db.execute("INSERT INTO fares VALUES (?, ?, ?)", (r, cls, round(rng.uniform(12, 60) * factor, 2)))
    start = datetime.datetime(2025, 6, 1, 7, 0)
    for s in range(1, 901):
        db.execute("INSERT INTO sailings VALUES (?, ?, ?, ?, ?)",
                   (s, rng.randint(1, r), rng.randint(1, 18), (start + datetime.timedelta(minutes=53 * s)).isoformat(timespec="minutes"),
                    rng.choice(["scheduled", "departed", "arrived", "cancelled"])))
    for p in range(1, 601):
        db.execute("INSERT INTO passengers VALUES (?, ?, ?, ?)", (p, f"Passenger {p}", f"p{p}@example.com", rng.choice(["GR", "IT", "FR", "DE", "UK", "US"])))
    for t in range(1, 2201):
        route = rng.randint(1, r)
        db.execute("INSERT INTO tickets VALUES (?, ?, ?, ?, ?, ?, ?)",
                   (t, rng.randint(1, 900), rng.randint(1, 600), route, rng.choice(["deck", "cabin"]), f"{rng.randint(1, 40)}{rng.choice('ABCD')}",
                    (start + datetime.timedelta(hours=rng.randint(0, 2000))).isoformat(timespec="seconds")))
    for w in range(200):
        db.execute("INSERT INTO weather_log VALUES (?, ?, ?, ?)",
                   ((start + datetime.timedelta(hours=6 * w)).isoformat(timespec="minutes"), rng.choice(ports), round(rng.uniform(2, 38), 1),
                    rng.choice(["", "", "Meltemi", "Calm", "Gale warning"])))
    db.commit()
    db.execute("VACUUM")
    db.close()


def write(name, text):
    with open(path(name), "w", encoding="utf-8") as f:
        f.write(text)


def jsonl():
    kinds = ["departure", "arrival", "delay", "cancellation"]
    lines = []
    for i in range(60):
        record = {"id": i + 1, "event": kinds[i % 4], "port": rng.choice(["Piraeus", "Naxos", "Paros", "Syros"]),
                  "at": f"2025-07-{i % 28 + 1:02d}T{8 + i % 12:02d}:{i * 7 % 60:02d}:00Z",
                  "passengers": rng.randint(20, 1800), "on_time": rng.random() > 0.2,
                  "vessel": {"name": f"Aegean {i % 6 + 1}", "imo": 9000000 + i}}
        if i % 5 == 0:
            record["delay_minutes"] = rng.choice([5, 15, 40])
        if i % 7 == 0:
            record["tags"] = ["weather", "meltemi"]
        if i % 11 == 0:
            record["note"] = None
        lines.append(json.dumps(record, ensure_ascii=False))
    lines.insert(17, "{this line is not json")
    write("events.jsonl", "\n".join(lines) + "\n")
    # Lines that aren't objects: shown as code.
    write("matrix.ndjson", "\n".join(json.dumps([i, i * i, i * i * i]) for i in range(20)) + "\n")


def har():
    origin = datetime.datetime(2025, 6, 2, 9, 30, 0, tzinfo=datetime.timezone.utc)
    entries = []
    t = 0.0
    def entry(url, mime, status=200, size=0, body=None, encoding=None, method="GET", resource=None, post=None, query=None):
        nonlocal t
        blocked, dns, connect, ssl = rng.uniform(0.5, 4), (rng.uniform(8, 30) if len(entries) < 3 else -1), (rng.uniform(20, 60) if len(entries) < 3 else -1), (rng.uniform(10, 40) if len(entries) < 3 else -1)
        send, wait, receive = rng.uniform(0.1, 1), rng.uniform(20, 180), rng.uniform(2, 90 if size > 20000 else 15)
        total = sum(v for v in (blocked, dns, connect, ssl, send, wait, receive) if v > 0)
        started = origin + datetime.timedelta(milliseconds=t)
        response = {"status": status, "statusText": {200: "OK", 301: "Moved Permanently", 404: "Not Found", 500: "Internal Server Error", 0: ""}[status],
                    "httpVersion": "h2", "cookies": [], "redirectURL": "https://ferries.example/en/" if status == 301 else "",
                    "headers": [{"name": "content-type", "value": mime}, {"name": "cache-control", "value": "max-age=3600"},
                                {"name": "server", "value": "nginx"}, {"name": "content-length", "value": str(size)}],
                    "content": {"size": size, "mimeType": mime}, "headersSize": -1, "bodySize": size, "_transferSize": size + 300}
        if body is not None:
            response["content"]["text"] = body
        if encoding:
            response["content"]["encoding"] = encoding
        request = {"method": method, "url": url, "httpVersion": "h2", "cookies": [], "headersSize": -1, "bodySize": 0,
                   "headers": [{"name": "accept", "value": "*/*"}, {"name": "user-agent", "value": "Mozilla/5.0 (Macintosh)"}],
                   "queryString": query or []}
        if post:
            request["postData"] = post
        item = {"pageref": "page_1", "startedDateTime": started.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                "time": total, "request": request, "response": response, "cache": {}, "serverIPAddress": "203.0.113.7", "connection": "443",
                "timings": {"blocked": blocked, "dns": dns, "connect": connect, "ssl": ssl, "send": send, "wait": wait, "receive": receive}}
        if resource:
            item["_resourceType"] = resource
        if status == 0:
            item["_error"] = "net::ERR_CONNECTION_REFUSED"
            item["response"]["content"]["size"] = 0
        entries.append(item)
        t += rng.uniform(2, 40)
    entry("http://ferries.example/", "text/html", status=301, resource="document")
    entry("https://ferries.example/en/", "text/html", size=48211, body="<!doctype html><html><head><title>Aegean Ferries</title></head><body><h1>Timetable</h1></body></html>", resource="document")
    for name in ["app", "vendor", "timetable", "map"]:
        entry(f"https://cdn.ferries.example/js/{name}.{rng.randint(1000, 9999)}.js", "application/javascript", size=rng.randint(4000, 220000), resource="script")
    for name in ["main", "print"]:
        entry(f"https://cdn.ferries.example/css/{name}.css", "text/css", size=rng.randint(2000, 40000), body="body { font: 14px system-ui; }\n.timetable td { padding: 4px; }", resource="stylesheet")
    entry("https://fonts.example/inter-var.woff2", "font/woff2", size=110000, resource="font")
    png = __import__("base64").b64encode(PNG_PIXEL).decode()
    for name in ["logo", "naxos", "paros", "santorini", "ship"]:
        entry(f"https://img.ferries.example/{name}.png", "image/png", size=rng.randint(3000, 160000), body=png, encoding="base64", resource="image")
    sailings = json.dumps({"route": "Piraeus–Naxos", "sailings": [{"departs": "07:25", "vessel": "Blue Star Delos", "minutes": 330}, {"departs": "17:30", "vessel": "Champion Jet 2", "minutes": 210}]})
    entry("https://api.ferries.example/v2/sailings?from=PIR&to=NAX&date=2025-06-02", "application/json", size=len(sailings), body=sailings, resource="fetch",
          query=[{"name": "from", "value": "PIR"}, {"name": "to", "value": "NAX"}, {"name": "date", "value": "2025-06-02"}])
    entry("https://api.ferries.example/v2/basket", "application/json", size=120, body='{"ok":true,"items":2}', method="POST", resource="fetch",
          post={"mimeType": "application/json", "text": json.dumps({"sailing": "BSD-0725", "passengers": 2, "cabin": False})})
    entry("https://api.ferries.example/v2/weather/naxos", "application/json", status=500, size=40, body='{"error":"upstream timeout"}', resource="fetch")
    entry("https://img.ferries.example/missing.png", "text/html", status=404, size=512, resource="image")
    entry("https://tracker.example/collect", "", status=0, resource="other")
    for i in range(14):
        entry(f"https://tiles.example/7/{70 + i}/{45 + i % 3}.png", "image/png", size=rng.randint(9000, 30000), resource="image")
    log = {"log": {"version": "1.2", "creator": {"name": "WebKit Web Inspector", "version": "18.4"}, "browser": {"name": "Safari", "version": "18.4"},
                   "pages": [{"startedDateTime": origin.isoformat(timespec="milliseconds").replace("+00:00", "Z"), "id": "page_1", "title": "Aegean Ferries — Timetable",
                              "pageTimings": {"onContentLoad": t * 0.45, "onLoad": t * 0.8}}],
                   "entries": entries}}
    write("ferries.har", json.dumps(log, indent=1))


def lock_files():
    write("lock/npm/package-lock.json", json.dumps({
        "name": "harbour-web", "version": "1.0.0", "lockfileVersion": 3, "requires": True,
        "packages": {
            "": {"name": "harbour-web", "version": "1.0.0", "dependencies": {"react": "^18.3.1", "react-dom": "^18.3.1"}, "devDependencies": {"vite": "^5.4.0"}},
            "node_modules/react": {"version": "18.3.1", "resolved": "https://registry.npmjs.org/react/-/react-18.3.1.tgz", "integrity": "sha512-x"},
            "node_modules/react-dom": {"version": "18.3.1", "resolved": "https://registry.npmjs.org/react-dom/-/react-dom-18.3.1.tgz"},
            "node_modules/scheduler": {"version": "0.23.2", "resolved": "https://registry.npmjs.org/scheduler/-/scheduler-0.23.2.tgz"},
            "node_modules/loose-envify": {"version": "1.4.0", "resolved": "https://registry.npmjs.org/loose-envify/-/loose-envify-1.4.0.tgz"},
            "node_modules/vite": {"version": "5.4.10", "resolved": "https://registry.npmjs.org/vite/-/vite-5.4.10.tgz", "dev": True},
            "node_modules/esbuild": {"version": "0.21.5", "resolved": "https://registry.npmjs.org/esbuild/-/esbuild-0.21.5.tgz", "dev": True},
            "node_modules/@esbuild/darwin-arm64": {"version": "0.21.5", "resolved": "https://registry.npmjs.org/@esbuild/darwin-arm64/-/darwin-arm64-0.21.5.tgz", "dev": True, "optional": True},
            "node_modules/vite/node_modules/rollup": {"version": "4.24.0", "resolved": "https://registry.npmjs.org/rollup/-/rollup-4.24.0.tgz", "dev": True},
            "node_modules/my-local": {"resolved": "packages/my-local", "link": True},
        }}, indent=2))
    write("lock/npm-shrinkwrap/npm-shrinkwrap.json", json.dumps({
        "name": "legacy", "lockfileVersion": 1, "dependencies": {
            "lodash": {"version": "4.17.21", "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz"},
            "mocha": {"version": "10.2.0", "resolved": "https://registry.npmjs.org/mocha/-/mocha-10.2.0.tgz", "dev": True,
                      "dependencies": {"ms": {"version": "2.1.3", "resolved": "https://registry.npmjs.org/ms/-/ms-2.1.3.tgz", "dev": True}}}}}, indent=2))
    write("lock/yarn/package.json", json.dumps({"name": "harbour", "dependencies": {"@babel/core": "^7.25.0", "lodash": "^4.17.21"}, "devDependencies": {"jest": "^29.7.0"}}, indent=2))
    write("lock/yarn/yarn.lock", """# THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.
# yarn lockfile v1


"@babel/code-frame@^7.24.7":
  version "7.24.7"
  resolved "https://registry.yarnpkg.com/@babel/code-frame/-/code-frame-7.24.7.tgz#882fd9e09e8ee324e496bd040401c6f046ef4465"
  integrity sha512-BcYH1CVJBO9tvyIZ2jVeXgSIMvGZ2FDRvDdOIVQyuklNKSsx+eppDEBq/g47Ayw+RqNFE+URvOShmf+f/qwAlA==
  dependencies:
    "@babel/highlight" "^7.24.7"

"@babel/core@^7.25.0":
  version "7.25.2"
  resolved "https://registry.yarnpkg.com/@babel/core/-/core-7.25.2.tgz"

"@babel/highlight@^7.24.7":
  version "7.24.7"
  resolved "https://registry.yarnpkg.com/@babel/highlight/-/highlight-7.24.7.tgz"

jest@^29.7.0:
  version "29.7.0"
  resolved "https://registry.yarnpkg.com/jest/-/jest-29.7.0.tgz"

lodash@^4.17.20, lodash@^4.17.21:
  version "4.17.21"
  resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz"

harbour-ui@github:harbour/ui#main:
  version "0.3.0"
  resolved "git+https://github.com/harbour/ui.git#4f1c2e0"
""")
    write("lock/yarn-berry/yarn.lock", """# This file is generated by running "yarn install" inside your project.

__metadata:
  version: 8
  cacheKey: 10c0

"harbour@workspace:.":
  version: 0.0.0-use.local
  resolution: "harbour@workspace:."
  languageName: unknown
  linkType: soft

"react@npm:^18.3.1":
  version: 18.3.1
  resolution: "react@npm:18.3.1"
  dependencies:
    loose-envify: "npm:^1.1.0"
  checksum: 10c0/283e8c5efcf37802c9d1ce767f302dd569dd97a70d9bb8c7be79a789b9902451e0d16334b05d73299b20f048cbc3c7d288bbbde10b701fa194e2089c237dbea3
  languageName: node
  linkType: hard

"loose-envify@npm:^1.1.0":
  version: 1.4.0
  resolution: "loose-envify@npm:1.4.0"
  languageName: node
  linkType: hard
""")
    write("lock/pnpm/pnpm-lock.yaml", """lockfileVersion: '9.0'

settings:
  autoInstallPeers: true

importers:

  .:
    dependencies:
      express:
        specifier: ^4.21.0
        version: 4.21.1
    devDependencies:
      typescript:
        specifier: ^5.6.0
        version: 5.6.3

packages:

  accepts@1.3.8:
    resolution: {integrity: sha512-PYAthTa2m2VKxuvSD3DPC/Gy+U+sOA1LAuT8mkmRuvw+NACSaeXEQ+NHcVF7rONl6qcaxV3Uuemwawk+7+SJLw==}
    engines: {node: '>= 0.6'}

  express@4.21.1:
    resolution: {integrity: sha512-YSFlK1Ee0/GC8QaO91tHcDxJiE/X4FbpAyQWkxAvG6AXCuR4HYzLR7rS/ICzhA0O6BBbJxjhpI2OHNWJy6JmA==}

  typescript@5.6.3:
    resolution: {integrity: sha512-hjcS1mhfuyi4WW8IWtjP7brDrG2cuDZukyrYrSauoXGNgx0S7zceP07adYkJycEr56BOUTNPzbInooiN3fn1qw==}
    engines: {node: '>=14.17'}
    hasBin: true

  harbour-ui@https://codeload.github.com/harbour/ui/tar.gz/4f1c2e0:
    resolution: {tarball: https://codeload.github.com/harbour/ui/tar.gz/4f1c2e0}
    version: 0.3.0

snapshots:

  accepts@1.3.8: {}
""")
    write("lock/cargo/Cargo.lock", """# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "harbour"
version = "0.1.0"
dependencies = [
 "serde",
 "tokio",
]

[[package]]
name = "serde"
version = "1.0.214"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "f55c3193aca71c12ad7890f1785d2b73e1b9f63a0bbc353c08ef26fe03fc56b5"
dependencies = [
 "serde_derive",
]

[[package]]
name = "serde_derive"
version = "1.0.214"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "de523f781f095e28fa605cdce0f8307e451cc0fd14e2eb4cd2e98a355b147766"

[[package]]
name = "tokio"
version = "1.41.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "145f3413504347a2be84393cc8a7d2fb4d863b375909ea59f2158261aa258bbb"

[[package]]
name = "nautical"
version = "0.2.0"
source = "git+https://github.com/harbour/nautical?branch=main#9b4a3f1"
""")
    write("lock/bundler/Gemfile.lock", """GIT
  remote: https://github.com/harbour/tide.git
  revision: 3c2b1f0d
  specs:
    tide (0.4.0)

GEM
  remote: https://rubygems.org/
  specs:
    actionpack (7.2.1)
      rack (>= 2.2.4)
    nokogiri (1.16.7-arm64-darwin)
      racc (~> 1.4)
    racc (1.8.1)
    rack (3.1.8)
    rspec (3.13.0)

PLATFORMS
  arm64-darwin

DEPENDENCIES
  actionpack (~> 7.2)
  nokogiri
  rspec
  tide!

BUNDLED WITH
   2.5.22
""")
    write("lock/poetry/pyproject.toml", """[tool.poetry]
name = "harbour"
version = "0.1.0"

[tool.poetry.dependencies]
python = "^3.11"
requests = "^2.32"

[tool.poetry.group.dev.dependencies]
pytest = "^8.3"
""")
    write("lock/poetry/poetry.lock", """# This file is automatically @generated by Poetry 1.8.4 and should not be changed by hand.

[[package]]
name = "certifi"
version = "2024.8.30"
description = "Python package for providing Mozilla's CA Bundle."
optional = false
python-versions = ">=3.6"

[[package]]
name = "pytest"
version = "8.3.3"
description = "pytest: simple powerful testing with Python"
optional = false

[[package]]
name = "requests"
version = "2.32.3"
description = "Python HTTP for Humans."
optional = false

[package.dependencies]
certifi = ">=2017.4.17"

[[package]]
name = "harbour-tools"
version = "0.2.0"
description = "Internal tools"
optional = false

[package.source]
type = "legacy"
url = "https://pypi.harbour.example/simple"
reference = "harbour"

[metadata]
lock-version = "2.0"
python-versions = "^3.11"
""")
    write("lock/uv/uv.lock", """version = 1
requires-python = ">=3.12"

[[package]]
name = "harbour"
version = "0.1.0"
source = { editable = "." }
dependencies = [
    { name = "httpx" },
]

[package.dev-dependencies]
dev = [
    { name = "ruff" },
]

[[package]]
name = "httpx"
version = "0.27.2"
source = { registry = "https://pypi.org/simple" }
dependencies = [
    { name = "anyio" },
    { name = "certifi" },
]

[[package]]
name = "anyio"
version = "4.6.2"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "certifi"
version = "2024.8.30"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "ruff"
version = "0.7.1"
source = { registry = "https://pypi.org/simple" }
""")
    write("lock/cocoapods/Podfile.lock", """PODS:
  - Alamofire (5.10.1)
  - Firebase/Analytics (11.4.0):
    - Firebase/Core
  - Firebase/Core (11.4.0):
    - FirebaseAnalytics (~> 11.4.0)
  - FirebaseAnalytics (11.4.0)
  - HarbourKit (0.3.0)

DEPENDENCIES:
  - Alamofire (~> 5.10)
  - Firebase/Analytics
  - HarbourKit (from `../HarbourKit`)

SPEC REPOS:
  trunk:
    - Alamofire
    - Firebase
    - FirebaseAnalytics

EXTERNAL SOURCES:
  HarbourKit:
    :path: "../HarbourKit"

SPEC CHECKSUMS:
  Alamofire: 7193b3b92c74a07f85569e1a6c4f4237291e7496

PODFILE CHECKSUM: 6b2e9d2f2c3d

COCOAPODS: 1.16.2
""")
    write("lock/swiftpm/Package.resolved", json.dumps({
        "originHash": "3f1c0a", "version": 3, "pins": [
            {"identity": "swift-argument-parser", "kind": "remoteSourceControl", "location": "https://github.com/apple/swift-argument-parser.git",
             "state": {"revision": "41982a3656a71c768319979febd796c6fd111d5c", "version": "1.5.0"}},
            {"identity": "swift-collections", "kind": "remoteSourceControl", "location": "https://github.com/apple/swift-collections",
             "state": {"revision": "671108c96644956dddcd89dd59c203dcdb36cec7", "version": "1.1.4"}},
            {"identity": "harbourkit", "kind": "remoteSourceControl", "location": "https://gitlab.example/harbour/HarbourKit.git",
             "state": {"branch": "main", "revision": "9b4a3f1e2d"}}]}, indent=2))
    write("lock/composer/composer.json", json.dumps({"require": {"php": ">=8.2", "monolog/monolog": "^3.7"}, "require-dev": {"phpunit/phpunit": "^11.4"}}, indent=2))
    write("lock/composer/composer.lock", json.dumps({
        "_readme": ["This file locks the dependencies of your project to a known state"], "content-hash": "abc",
        "packages": [
            {"name": "monolog/monolog", "version": "3.7.0", "source": {"type": "git", "url": "https://github.com/Seldaek/monolog.git"}},
            {"name": "psr/log", "version": "3.0.2", "dist": {"type": "zip", "url": "https://api.github.com/repos/php-fig/log/zipball/f16e1d5863e37f8d8c2a01719f5b34baa2b714d3"}}],
        "packages-dev": [
            {"name": "phpunit/phpunit", "version": "11.4.3", "source": {"type": "git", "url": "https://github.com/sebastianbergmann/phpunit.git"}},
            {"name": "sebastian/diff", "version": "6.0.2", "source": {"type": "git", "url": "https://github.com/sebastianbergmann/diff.git"}}]}, indent=4))
    write("lock/go/go.mod", """module example.com/harbour

go 1.23

require (
\tgithub.com/spf13/cobra v1.8.1
\tgolang.org/x/sync v0.8.0 // indirect
)

require github.com/spf13/pflag v1.0.5 // indirect
""")
    write("lock/go/go.sum", """github.com/inconshreveable/mousetrap v1.1.0 h1:wN+x4NVGpMsO7ErUn/mUI3vEoE6Jt13X2s0bqwp9tc8=
github.com/inconshreveable/mousetrap v1.1.0/go.mod h1:vpF70FUmC8bwa3OWnCshd2FqLfsEA9PFc4w1p2J65bw=
github.com/spf13/cobra v1.8.1 h1:e5/vxKd/rZsfSJMUX1agtjeTDf+qv1/JdBF8gg5k9ZM=
github.com/spf13/cobra v1.8.1/go.mod h1:wHxEcudfqmLYa8iTfL+OuZPbBZkmvliBWKIezN3kD9Y=
github.com/spf13/pflag v1.0.5 h1:iy+VFUOCP1a+8yFto/drg2CJ5u0yRoB7fZw3DKv/JXA=
github.com/spf13/pflag v1.0.5/go.mod h1:McXfInJRrz4CZXVZOBLb0bTZqETkiAhM9Iw0y3An2Bg=
golang.org/x/sync v0.8.0 h1:3NFvSEYkUoMifnESzZl15y791HH1qU2xm6eCJU5ZPXQ=
golang.org/x/sync v0.8.0/go.mod h1:Czt+wKu1gCyEFDUtn0jG5QVvpJ6rzVqr5aXyt9drQfk=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E4C/DD0dBAm4ucxyHA2Vv9SLKqMk=
""")
    write("lock/mix/mix.lock", """%{
  "jason": {:hex, :jason, "1.4.4", "b9226785a9aa77b6857ca22832cffa5d5011a667207eb2a0ad56adb5db443b8a", [:mix], [{:decimal, "~> 1.0 or ~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b"},
  "decimal": {:hex, :decimal, "2.1.1", "5611dca5d4b2c3dd497dec8f68751f1f1a54755e8ed2a966c2633cf885973ad6", [:mix], [], "hexpm", "53cfe5f497ed0e7771ae1a475575603d77425099ba5faef9394932b35020ffcc"},
  "tide": {:git, "https://github.com/harbour/tide.git", "3c2b1f0d9e8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c", [branch: "main"]},
}
""")
    write("lock/pub/pubspec.lock", """# Generated by pub
# See https://dart.dev/tools/pub/glossary#lockfile
packages:
  async:
    dependency: transitive
    description:
      name: async
      sha256: "947bfcf187f74dbc5e146c9eb9c0f10c9f8b30743e341481c1e2ed3ecc18c20c"
      url: "https://pub.dev"
    source: hosted
    version: "2.11.0"
  http:
    dependency: "direct main"
    description:
      name: http
      url: "https://pub.dev"
    source: hosted
    version: "1.2.2"
  flutter_test:
    dependency: "direct dev"
    description: flutter
    source: sdk
    version: "0.0.0"
  harbour_ui:
    dependency: "direct main"
    description:
      path: "../harbour_ui"
      relative: true
    source: path
    version: "0.3.0"
sdks:
  dart: ">=3.5.0 <4.0.0"
""")
    write("lock/pipenv/Pipfile.lock", json.dumps({
        "_meta": {"hash": {"sha256": "x"}, "pipfile-spec": 6, "sources": [{"name": "pypi", "url": "https://pypi.org/simple", "verify_ssl": True}]},
        "default": {"requests": {"hashes": [], "index": "pypi", "version": "==2.32.3"}, "urllib3": {"hashes": [], "index": "pypi", "version": "==2.2.3"}},
        "develop": {"pytest": {"hashes": [], "index": "pypi", "version": "==8.3.3"}}}, indent=4))
    write("lock/bun/bun.lock", """{
  "lockfileVersion": 1,
  "workspaces": {
    "": {
      "name": "harbour",
      "dependencies": {
        "hono": "^4.6.0",
      },
      "devDependencies": {
        "@types/bun": "latest",
      },
    },
  },
  "packages": {
    "@types/bun": ["@types/bun@1.1.13", "", { "dependencies": { "bun-types": "1.1.34" } }, "sha512-x"],
    "bun-types": ["bun-types@1.1.34", "", {}, "sha512-y"],
    "hono": ["hono@4.6.9", "", {}, "sha512-z"],
  }
}
""")
    write("lock/nix/flake.lock", json.dumps({
        "nodes": {
            "nixpkgs": {"locked": {"lastModified": 1730272153, "narHash": "sha256-B5WRZYsRlJgwVHIV6DvidFN7VX7Fg9uuwkRW9Ha8z+w=", "owner": "NixOS",
                                    "repo": "nixpkgs", "rev": "2d2a9ddbe3f2c00747398f3dc9b05f7f2ebb0f53", "type": "github"},
                        "original": {"owner": "NixOS", "ref": "nixos-unstable", "repo": "nixpkgs", "type": "github"}},
            "flake-utils": {"inputs": {"systems": "systems"}, "locked": {"lastModified": 1726560853, "narHash": "sha256-X6rJYSESBVr3hBoH0WbKE5KvhPU5bloyZ2L4K60/fPQ=",
                            "owner": "numtide", "repo": "flake-utils", "rev": "c1dfcf08411b08f6b8615f7d8971a2bfa81d5e8a", "type": "github"}},
            "systems": {"locked": {"lastModified": 1681028828, "narHash": "sha256-Vy1rq5AaRuLzOxct8nz4T6wlgyUR7zLU309k9mBC768=", "owner": "nix-systems",
                        "repo": "default", "rev": "da67096a3b9bf56a91d16901293e51ba5b49a27e", "type": "github"}},
            "root": {"inputs": {"flake-utils": "flake-utils", "nixpkgs": "nixpkgs"}}},
        "root": "root", "version": 7}, indent=2))
    write("lock/gradle/gradle.lockfile", """# This is a Gradle generated file for dependency locking.
# Manual edits can break the build and are not advised.
# This file is expected to be part of source control.
com.google.guava:guava:33.3.1-jre=compileClasspath,runtimeClasspath
com.google.guava:failureaccess:1.0.2=compileClasspath,runtimeClasspath
org.junit.jupiter:junit-jupiter:5.11.3=testCompileClasspath,testRuntimeClasspath
org.slf4j:slf4j-api:2.0.16=runtimeClasspath
empty=annotationProcessor
""")
    write("lock/nuget/packages.lock.json", json.dumps({
        "version": 1, "dependencies": {"net8.0": {
            "Newtonsoft.Json": {"type": "Direct", "requested": "[13.0.3, )", "resolved": "13.0.3", "contentHash": "x"},
            "Serilog": {"type": "Direct", "requested": "[4.1.0, )", "resolved": "4.1.0", "contentHash": "y"},
            "System.Diagnostics.DiagnosticSource": {"type": "Transitive", "resolved": "8.0.1", "contentHash": "z"},
            "Harbour.Core": {"type": "Project"}}}}, indent=2))


def string_catalogs():
    catalog = {"sourceLanguage": "en", "version": "1.0", "strings": {
        "Book a cabin": {"comment": "Button on the sailing detail screen", "localizations": {
            "de": {"stringUnit": {"state": "translated", "value": "Kabine buchen"}},
            "el": {"stringUnit": {"state": "translated", "value": "Κράτηση καμπίνας"}},
            "fr": {"stringUnit": {"state": "needs_review", "value": "Réserver une cabine"}},
            "ja": {"stringUnit": {"state": "translated", "value": "客室を予約"}}}},
        "Departs %@": {"comment": "Departure time, e.g. Departs 07:25", "localizations": {
            "de": {"stringUnit": {"state": "translated", "value": "Abfahrt %@"}},
            "el": {"stringUnit": {"state": "translated", "value": "Αναχώρηση %@"}},
            "fr": {"stringUnit": {"state": "translated", "value": "Départ %@"}}}},
        "%lld passengers": {"localizations": {
            "en": {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": "%lld passenger"}},
                                             "other": {"stringUnit": {"state": "translated", "value": "%lld passengers"}}}}},
            "de": {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": "%lld Passagier"}},
                                             "other": {"stringUnit": {"state": "translated", "value": "%lld Passagiere"}}}}},
            "el": {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": "%lld επιβάτης"}},
                                             "other": {"stringUnit": {"state": "needs_review", "value": "%lld επιβάτες"}}}}}}},
        "Sea conditions": {"localizations": {"de": {"stringUnit": {"state": "translated", "value": "Seegang"}},
                                             "fr": {"stringUnit": {"state": "new", "value": ""}}}},
        "Timetable": {"comment": "Tab title", "localizations": {
            "de": {"stringUnit": {"state": "translated", "value": "Fahrplan"}}, "el": {"stringUnit": {"state": "translated", "value": "Δρομολόγια"}},
            "fr": {"stringUnit": {"state": "translated", "value": "Horaires"}}, "ja": {"stringUnit": {"state": "translated", "value": "時刻表"}}}},
        "Cancelled": {"extractionState": "stale", "localizations": {"de": {"stringUnit": {"state": "translated", "value": "Annulliert"}}}},
        "Aegean Ferries": {"shouldTranslate": False, "comment": "App name"},
        "Your ticket for %1$@ to %2$@": {"localizations": {"de": {"stringUnit": {"state": "translated", "value": "Ihr Ticket von %1$@ nach %2$@"}},
                                                          "el": {"stringUnit": {"state": "translated", "value": "Το εισιτήριό σας %1$@ προς %2$@"}}}},
    }}
    write("strings/Localizable.xcstrings", json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True))
    english = [("timetable.title", "Timetable", "Tab title"), ("sailing.book", "Book a cabin", "Button on the sailing screen"),
               ("sailing.departs", "Departs %@", None), ("weather.warning", "Gale warning in the \"Cyclades\"", "Shown when wind is above 7 Beaufort")]
    translations = {"de": {"timetable.title": "Fahrplan", "sailing.book": "Kabine buchen", "sailing.departs": "Abfahrt %@"},
                    "el": {"timetable.title": "Δρομολόγια", "sailing.book": "Κράτηση καμπίνας", "weather.warning": "Προειδοποίηση θυελλωδών ανέμων στις \"Κυκλάδες\""}}
    def strings_text(pairs):
        out = []
        for key, value, comment in pairs:
            if comment:
                out.append(f"/* {comment} */")
            out.append(f'"{key}" = "{value.replace(chr(34), chr(92) + chr(34))}";\n')
        return "\n".join(out)
    write("strings/Resources/en.lproj/Localizable.strings", strings_text(english))
    for language, values in translations.items():
        pairs = [(k, values[k], None) for k, _, _ in english if k in values]
        text = strings_text(pairs)
        with open(path(f"strings/Resources/{language}.lproj/Localizable.strings"), "w", encoding="utf-16") as f:
            f.write(text)
    import plistlib
    with open(path("strings/binary/InfoPlist.strings"), "wb") as f:
        plistlib.dump({"CFBundleDisplayName": "Ferries", "NSLocationWhenInUseUsageDescription": "Shows the ports near you."}, f, fmt=plistlib.FMT_BINARY)
    with open(path("strings/Resources/en.lproj/Localizable.stringsdict"), "wb") as f:
        plistlib.dump({
            "%d sailings": {"NSStringLocalizedFormatKey": "%#@sailings@",
                            "sailings": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d",
                                         "zero": "No sailings", "one": "%d sailing", "other": "%d sailings"}},
            "%d cabins left": {"NSStringLocalizedFormatKey": "%#@cabins@",
                               "cabins": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d",
                                          "one": "Last cabin", "other": "%d cabins left"}}}, f)


def dbf(name, version, fields, records, *, ldid=0x03, memo=None, deleted=(), encoding="cp1252", foxpro=False):
    """fields: (name, type, length, decimals, flags); records: tuples of Python values."""
    header_len = 32 + 32 * len(fields) + 1 + (263 if foxpro else 0)
    record_len = 1 + sum(f[2] for f in fields)
    today = datetime.date(2025, 6, 1)
    out = bytearray(struct.pack("<BBBBIHH", version, today.year - 1900, today.month, today.day, len(records), header_len, record_len))
    out += bytes(16) + bytes([0x02 if memo and foxpro else 0, ldid]) + bytes(2)
    offset = 1
    for fname, ftype, flen, fdec, flags in fields:
        out += fname.encode("ascii").ljust(11, b"\0") + ftype.encode("ascii") + struct.pack("<I", offset if foxpro else 0)
        out += bytes([flen, fdec, flags]) + bytes(13)
        offset += flen
    out += b"\r" + (bytes(263) if foxpro else b"")
    memo_blocks = []
    for index, record in enumerate(records):
        out += b"*" if index in deleted else b" "
        for (fname, ftype, flen, fdec, flags), value in zip(fields, tuple(record) + (None,) * (len(fields) - len(record))):
            if ftype in "CV":
                data = ("" if value is None else str(value)).encode(encoding)[:flen]
                out += data.ljust(flen, b" ")
            elif ftype in "NF":
                out += ("" if value is None else (f"{value:.{fdec}f}" if fdec else str(value))).rjust(flen).encode("ascii")
            elif ftype == "D":
                out += (value.strftime("%Y%m%d") if value else " " * 8).encode("ascii")
            elif ftype == "L":
                out += b"?" if value is None else (b"T" if value else b"F")
            elif ftype == "I":
                out += struct.pack("<i", value)
            elif ftype == "Y":
                out += struct.pack("<q", int(round(value * 10000)))
            elif ftype == "T":
                jd = value.toordinal() + 1721425 if value else 0
                ms = (value.hour * 3600 + value.minute * 60 + value.second) * 1000 if value else 0
                out += struct.pack("<ii", jd, ms)
            elif ftype == "B":
                out += struct.pack("<d", value)
            elif ftype == "M":
                if value is None:
                    out += (struct.pack("<i", 0) if flen == 4 else b" " * flen)
                else:
                    memo_blocks.append(value)
                    block = len(memo_blocks)  # placeholder, fixed below
                    out += (struct.pack("<i", block) if flen == 4 else str(block).rjust(flen).encode("ascii"))
            elif ftype == "0":
                nulls = 0
                bit = 0
                for (fn, ft, fl, fd, ff), v in zip(fields, record):
                    if ft == "0":
                        continue
                    if ff & 0x02:
                        if v is None:
                            nulls |= 1 << bit
                        bit += 1
                out += bytes([nulls]).ljust(flen, b"\0")
    out += b"\x1a"
    with open(path(name), "wb") as f:
        f.write(out)
    if memo:
        base = os.path.splitext(name)[0]
        if memo == "dbt3":
            # dBase III: 512-byte blocks, text ends with 0x1A 0x1A. Block n holds memo n (block 0 is the header).
            data = bytearray(struct.pack("<I", len(memo_blocks) + 1)) + bytes(508)
            for text in memo_blocks:
                block = text.encode(encoding) + b"\x1a\x1a"
                data += block.ljust(((len(block) + 511) // 512) * 512, b"\0")
            assert all(len(t.encode(encoding)) < 500 for t in memo_blocks)
            with open(path(base + ".dbt"), "wb") as f:
                f.write(data)
        elif memo == "dbt4":
            size = 512
            data = bytearray(struct.pack("<I", len(memo_blocks) + 1)) + bytes(16) + struct.pack("<H", size) + bytes(size - 22)
            for text in memo_blocks:
                body = text.encode(encoding)
                block = b"\xff\xff\x08\x00" + struct.pack("<I", len(body) + 8) + body
                data += block.ljust(size, b"\0")
            with open(path(base + ".dbt"), "wb") as f:
                f.write(data)
        elif memo == "fpt":
            size = 64
            data = bytearray(struct.pack(">I", 0) + b"\0\0" + struct.pack(">H", size)) + bytes(512 - 8)
            next_block = 512 // size
            blocks = []
            for text in memo_blocks:
                body = text.encode(encoding)
                blocks.append(next_block)
                chunk = struct.pack(">II", 1, len(body)) + body
                chunk = chunk.ljust(((len(chunk) + size - 1) // size) * size, b"\0")
                data += chunk
                next_block += len(chunk) // size
            data[0:4] = struct.pack(">I", next_block)
            with open(path(base + ".fpt"), "wb") as f:
                f.write(data)
            # Point the records at the real block numbers.
            raw = bytearray(open(path(name), "rb").read())
            memo_field = [f for f in fields if f[1] == "M"][0]
            memo_offset = 1 + sum(f[2] for f in fields[:fields.index(memo_field)])
            counter = 0
            for i in range(len(records)):
                at = header_len + i * record_len + memo_offset
                if struct.unpack("<i", raw[at:at + 4])[0] != 0:
                    raw[at:at + 4] = struct.pack("<i", blocks[counter])
                    counter += 1
            with open(path(name), "wb") as f:
                f.write(raw)


def dbf_files():
    ports = [("Piraeus", "Attica", 37.9425, 23.6469, datetime.date(1835, 5, 1), True, "Main port of Athens and the busiest passenger port in Europe."),
             ("Rafina", "Attica", 38.0207, 24.0094, datetime.date(1960, 6, 12), True, None),
             ("Naxos", "Cyclades", 37.1077, 25.3727, datetime.date(1970, 3, 2), False, "Gateway to the Small Cyclades."),
             ("Syros", "Cyclades", 37.4428, 24.9452, None, True, "Capital of the Cyclades; shipyards since the 19th century."),
             ("Heraklion", "Crete", 35.3439, 25.1386, datetime.date(1922, 9, 9), True, "Overnight ferries to Piraeus.")]
    fields = [("NAME", "C", 20, 0, 0), ("REGION", "C", 12, 0, 0), ("LAT", "N", 9, 4, 0), ("LON", "N", 9, 4, 0),
              ("OPENED", "D", 8, 0, 0), ("YEARROUND", "L", 1, 0, 0), ("NOTES", "M", 10, 0, 0)]
    dbf("dbf/dbase3/ports.dbf", 0x83, fields, ports, ldid=0x03, memo="dbt3", deleted={1})
    harbours = [(p[0], p[1], p[6] or "No notes recorded.") for p in ports]
    dbf("dbf/dbase4/harbours.dbf", 0x8B, [("NAME", "C", 20, 0, 0), ("REGION", "C", 12, 0, 0), ("HISTORY", "M", 10, 0, 0)], harbours, ldid=0x57, memo="dbt4")
    fleet = [(1, "Blue Star Delos", 2011, 2400, 1250.5, datetime.datetime(2025, 5, 30, 7, 25), 0.82, "Λιμάνι Πειραιά", "Flagship on the western Cyclades line."),
             (2, "Champion Jet 2", 1997, 1100, 980.0, datetime.datetime(2025, 5, 30, 17, 30), 0.64, None, None),
             (3, "Αιγαίο Πέλαγος", 1988, 800, 455.25, None, 0.31, "Νάξος", "Ρυμουλκό λιμένος."),
             (4, "Superferry", 2003, 1800, 1500.0, datetime.datetime(2025, 5, 31, 6, 0), 0.9, "Ραφήνα", None)]
    fields = [("ID", "I", 4, 0, 0), ("VESSEL", "C", 24, 0, 0), ("BUILT", "N", 4, 0, 0), ("SEATS", "N", 5, 0, 0), ("FARE", "Y", 8, 4, 0),
              ("DEPARTS", "T", 8, 0, 0x02), ("LOAD", "B", 8, 2, 0), ("HOMEPORT", "C", 20, 0, 0x02), ("REMARKS", "M", 4, 0, 0x02),
              ("_NullFlags", "0", 1, 0, 0x05)]
    dbf("dbf/foxpro/fleet.dbf", 0x30, fields, fleet, ldid=0xCB, memo="fpt", deleted={3}, encoding="cp1253", foxpro=True)


def parquet_files():
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
        import decimal
    except ImportError:
        print("pyarrow not installed: skipping Parquet fixtures")
        return
    n = 400
    start = datetime.datetime(2025, 6, 1, 6, 0)
    table = pa.table({
        "sailing": pa.array([f"S{i:04d}" for i in range(n)]),
        "origin": pa.array([rng.choice(["Piraeus", "Rafina", "Naxos", "Paros", "Syros"]) for _ in range(n)]).dictionary_encode(),
        "departs": pa.array([start + datetime.timedelta(minutes=47 * i) for i in range(n)], type=pa.timestamp("us")),
        "day": pa.array([(start + datetime.timedelta(minutes=47 * i)).date() for i in range(n)], type=pa.date32()),
        "minutes": pa.array([rng.choice([35, 50, 90, 120, 240]) for _ in range(n)], type=pa.int32()),
        "passengers": pa.array([None if i % 13 == 0 else rng.randint(20, 2400) for i in range(n)], type=pa.int64()),
        "fare": pa.array([decimal.Decimal(f"{rng.uniform(9, 90):.2f}") for _ in range(n)], type=pa.decimal128(8, 2)),
        "load": pa.array([rng.random() for _ in range(n)], type=pa.float64()),
        "on_time": pa.array([rng.random() > 0.2 for _ in range(n)]),
        "stops": pa.array([[rng.choice(["Syros", "Tinos", "Mykonos"]) for _ in range(i % 3)] for i in range(n)]),
    })
    pq.write_table(table, path("parquet/sailings.parquet"), compression="snappy", row_group_size=150)
    pq.write_table(table.slice(0, 60), path("parquet/plain.parquet"), compression="none", use_dictionary=False)
    pq.write_table(table.slice(0, 60), path("parquet/gzip.parquet"), compression="gzip", data_page_version="2.0")
    pq.write_table(table.slice(0, 60), path("parquet/zstd.parquet"), compression="zstd")


if __name__ == "__main__":
    islands_tsv()
    voyages_psv()
    harbour_sqlite()
    jsonl()
    har()
    lock_files()
    string_catalogs()
    dbf_files()
    parquet_files()
