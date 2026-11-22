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


if __name__ == "__main__":
    islands_tsv()
    voyages_psv()
    harbour_sqlite()
