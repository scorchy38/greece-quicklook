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


if __name__ == "__main__":
    islands_tsv()
    voyages_psv()
