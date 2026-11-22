// Quarterly report for the harbour timetable service.
#import "@preview/tablex:0.0.8": tablex, hlinex

#set document(title: "Timetable Service: Q1 2026", author: "Ingrid Sæther")
#set page(paper: "a4", margin: (x: 2.2cm, y: 2.5cm), numbering: "1 / 1")
#set text(font: "New Computer Modern", size: 11pt, lang: "en")
#set par(justify: true, leading: 0.62em)
#set heading(numbering: "1.1")
#show link: underline

/* A highlighted callout box used for key results. */
#let callout(title, body, accent: rgb("#007aff")) = block(
  fill: accent.lighten(90%),
  stroke: (left: 2pt + accent),
  inset: 10pt,
  radius: 4pt,
  width: 100%,
)[
  *#title* \
  #body
]

#let percent(x) = str(calc.round(x * 100, digits: 1)) + "%"

#align(center)[
  #text(size: 20pt, weight: "bold")[Timetable Service: Q1 2026] \
  #v(4pt)
  Ingrid Sæther · Harbour Authority · #datetime(year: 2026, month: 4, day: 2).display("[month repr:long] [day], [year]")
]

#outline(indent: auto)

= Summary

Punctuality rose to #percent(0.916) after the live delay feed launched in
March. The Skerry evening rotation remains the weak point; see @tbl-routes.

#callout("Key result")[
  Delays now reach passengers in a median of *38 seconds*, down from the next
  morning under the old batch system.
]

= Method

Each sailing's delay is the difference between its actual and scheduled
departure, $d = t_"actual" - t_"scheduled"$. We call a sailing on time when
$d <= 2$ minutes. For knock-on delays we use

$ d_n = max(0, d_0 - n r) + sum_(k=1)^n epsilon_k $ <eq-knock>

where $r$ is the time recovered per turnaround. @eq-knock explains why the
evening rotation never catches up when $r < 1.5$.

== Data

- AIS position reports, every 15 seconds
- The published winter timetable
  - 82 daily sailings
  - 4 vessels
+ Import the timetable
+ Match positions to sailings
+ Compute delays

```python
def on_time(delay_minutes: float) -> bool:
    return delay_minutes <= 2
```

= Results

#figure(
  table(
    columns: (auto, 1fr, 1fr, 1fr),
    align: (left, right, right, right),
    stroke: none,
    table.hline(),
    table.header[*Route*][*Sailings*][*On time*][*Median delay*],
    table.hline(stroke: 0.5pt),
    [Harbour – Skerry], [1,512], [87.9%], [1.4 min],
    [Harbour – Lindholm], [1,020], [95.2%], [0.3 min],
    [Lindholm – Outer], [888], [93.8%], [0.6 min],
    table.hline(),
  ),
  caption: [On-time share by route, January to March 2026.],
) <tbl-routes>

#figure(
  image("figures/delays.svg", width: 80%),
  caption: [Median delay by hour of day.],
) <fig-delays>

= Next steps

/ Notifications: push a notice when a followed sailing is late.
/ Tidal windows: show them on each route page.

More detail is on the #link("https://example.org/ferries")[project site].
