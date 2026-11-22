# Sources of the documents fixtures

Sample files for the documents module's tests and visual checks. They are not shipped in the app.

| Path | Source |
|---|---|
| `latex/paper/main.tex`, `sections/method.tex`, `sections/results.tex` | Original writing for this repository. The paper, authors and results are fictional. |
| `latex/paper/references.bib` | Original. Bibliographic details of real, published works, written by hand; `sieve2026code` and `muller2024sparse` are fictional. |
| `latex/paper/figures/attention.png`, `pipeline.pdf` | Generated with matplotlib from synthetic data. |
| `latex/paper/figures/loss.pgf` | Real matplotlib 3.9 PGF backend output (synthetic data). No LaTeX was installed, so text metrics came from matplotlib's Agg renderer. |
| `latex/beamer/talk.tex` | Original. |
| `latex/notes.tex` | Original. The cited works (Banach 1922; Granas and Dugundji 2003; Kreyszig 1978) are real. |
| `bib/library.bib` | Original. Mostly real, published works, with details written by hand; `marsh2026sieve` and `ostergaard2015kerning` are fictional. |
| `epub/alice.epub` | Chapters I–III of Lewis Carroll's *Alice's Adventures in Wonderland*, from Project Gutenberg eBook #11 (public domain in the USA). Packaged as EPUB 3 by a script. The ISBN `978-1-234-56789-7` is an example ISBN, not a real edition. Cover and illustration were drawn with PIL. |
| `epub/minimal-epub2.epub` | Two of Aesop's fables, after George Fyler Townsend's 1867 translation (public domain). Packaged as EPUB 2. Cover drawn with PIL. |
| `org/project.org`, `asciidoc/guide.adoc`, `rst/readme.rst` | Original. |
| `asciidoc/diagram.png`, `rst/tide-curve.png` | Generated with matplotlib. |
| `quarto/analysis.qmd`, `rmarkdown/report.Rmd`, `sweave/report.Rnw`, `livebook/intro.livemd` | Original. They refer to R's public `cars` and `faithful` data sets. The Livebook sample quotes a sentence from *Alice* (public domain). |
| `mermaid/*` | Original. One file per Mermaid diagram type (22). All parse with Mermaid 11.17.2; `radar.mmd` and `treemap.mmd` are not recognised by Mermaid 11.4.1. |
| `typst/report.typ` | Original. |
