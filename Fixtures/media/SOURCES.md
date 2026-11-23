# Media fixtures

Small sample files for the media module's tests and visual checks. None ship in the app.

## Fonts (`fonts/`)

- **Inter-Variable.woff2**: [Inter](https://github.com/rsms/inter) by Rasmus Andersson, from Google Fonts (`ofl/inter/Inter[opsz,wght].ttf`), subset to Latin with `pyftsubset` (all layout features and names kept). SIL Open Font License 1.1, see `Inter-OFL.txt`.
- **Inter-Display-Bold.woff**: a static instance of the same font (wght 700, opsz 28), saved as WOFF 1.0 with fontTools. Same licence.
- **Inter-Pair.ttc**: two static instances (Regular, ExtraBold) subset to Basic Latin and saved as a TrueType collection. Same licence.
- **GreeceIcons.woff2**: an icon font drawn from scratch with fontTools' FontBuilder: twelve shapes in the Private Use Area with glyph names. Public domain.

The script that builds the last three from the subset lives with the module's working notes; the font data itself comes only from Inter.

## Subtitles (`subtitles/`)

Written for Greece: the same short scene ("The Morning Ferry") in SubRip, WebVTT, ASS, SAMI, TTML, YouTube SBV and MicroDVD, plus an LRC song ("Harbour Song"). They include italics, speakers, styles, a cue that's too fast, long lines, an overlap, a comment, a drawing, frame-based times and multi-language SAMI on purpose. Public domain.

## SVG (`svg/`)

- **Santorini.svg** and **Santorini.svgz** (the same file, gzipped): drawn by hand for Greece. Public domain.
- **Anchor.svg**: a black stroke icon with only a viewBox, for fit-to-window and dark-mode contrast. Public domain.
- **Hostile.svg**: scripts, event handlers, remote references and a foreignObject that must never run or load.

## Lottie (`lottie/`)

`make_lottie.py` writes both files: **Lighthouse.json** (a hand-built Lottie with shapes, gradients, strokes, eased keyframes and markers) and **Harbour.lottie** (a dotLottie package with that animation, a second one and a generated PNG). Public domain.

## Palettes (`palettes/`)

`make_palettes.py` writes the Aegean palette in ASE (groups, spot CMYK, Lab, gray), ACO (versions 1 and 2), ACT, GIMP, Procreate and Sketch formats. **Harbor.clr** was written by AppKit's `NSColorList.write(to:)` with sRGB, calibrated, CMYK, gray and Display P3 colours. Public domain.
