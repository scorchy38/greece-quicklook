#!/usr/bin/env python3
"""Ferry timetable: loads crossings, finds connections, prints a day's departures."""

from __future__ import annotations

import csv
import datetime as dt
from dataclasses import dataclass, field
from typing import Iterable, Iterator


@dataclass(frozen=True)
class Crossing:
    origin: str
    destination: str
    departs: dt.time
    minutes: int
    operator: str = "Blue Star"

    @property
    def arrives(self) -> dt.time:
        start = dt.datetime.combine(dt.date.today(), self.departs)
        return (start + dt.timedelta(minutes=self.minutes)).time()


@dataclass
class Timetable:
    crossings: list[Crossing] = field(default_factory=list)

    @classmethod
    def load(cls, path: str) -> "Timetable":
        """Reads `origin,destination,departs,minutes[,operator]` rows."""
        table = cls()
        with open(path, newline="") as handle:
            for row in csv.reader(handle):
                if not row or row[0].startswith("#"):
                    continue
                origin, destination, departs, minutes, *rest = row
                table.crossings.append(
                    Crossing(
                        origin=origin.strip(),
                        destination=destination.strip(),
                        departs=dt.time.fromisoformat(departs.strip()),
                        minutes=int(minutes),
                        operator=rest[0].strip() if rest else "Blue Star",
                    )
                )
        return table

    def departures(self, port: str) -> Iterator[Crossing]:
        yield from sorted(
            (c for c in self.crossings if c.origin == port),
            key=lambda c: c.departs,
        )

    def connections(self, origin: str, destination: str, change_minutes: int = 30) -> Iterable[tuple[Crossing, ...]]:
        """Direct crossings first, then journeys with one change."""
        for crossing in self.departures(origin):
            if crossing.destination == destination:
                yield (crossing,)
        for first in self.departures(origin):
            for second in self.departures(first.destination):
                if second.destination != destination:
                    continue
                gap = _minutes_between(first.arrives, second.departs)
                if gap >= change_minutes:
                    yield (first, second)


def _minutes_between(a: dt.time, b: dt.time) -> int:
    today = dt.date.today()
    delta = dt.datetime.combine(today, b) - dt.datetime.combine(today, a)
    return int(delta.total_seconds() // 60)


def main() -> None:
    table = Timetable.load("crossings.csv")
    for journey in table.connections("Piraeus", "Naxos"):
        legs = " → ".join(f"{c.origin} {c.departs:%H:%M}" for c in journey)
        print(f"{legs} → {journey[-1].destination} {journey[-1].arrives:%H:%M}")


if __name__ == "__main__":
    main()
