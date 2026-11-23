#!/usr/bin/env python3
"""Find the fastest ferry connections between Aegean islands."""

from __future__ import annotations

import heapq
from dataclasses import dataclass, field
from datetime import timedelta


@dataclass(order=True)
class Leg:
    minutes: int
    origin: str = field(compare=False)
    destination: str = field(compare=False)
    operator: str = field(compare=False, default="Blue Star")


TIMETABLE = [
    Leg(135, "Piraeus", "Syros"),
    Leg(50, "Syros", "Mykonos", "Seajets"),
    Leg(40, "Mykonos", "Naxos", "Seajets"),
    Leg(35, "Paros", "Naxos"),
    Leg(110, "Naxos", "Santorini"),
]


def fastest(start: str, goal: str) -> tuple[timedelta, list[str]] | None:
    """Dijkstra over the timetable. Ferries run both ways."""
    graph: dict[str, list[Leg]] = {}
    for leg in TIMETABLE:
        graph.setdefault(leg.origin, []).append(leg)
        graph.setdefault(leg.destination, []).append(Leg(leg.minutes, leg.destination, leg.origin, leg.operator))

    queue = [(0, start, [start])]
    seen: set[str] = set()
    while queue:
        minutes, island, path = heapq.heappop(queue)
        if island == goal:
            return timedelta(minutes=minutes), path
        if island in seen:
            continue
        seen.add(island)
        for leg in graph.get(island, []):
            heapq.heappush(queue, (minutes + leg.minutes, leg.destination, [*path, leg.destination]))
    return None


if __name__ == "__main__":
    duration, route = fastest("Piraeus", "Santorini")
    print(f"{' → '.join(route)} in {duration}")
