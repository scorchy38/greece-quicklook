/* Greece — indent guides: a hairline at each indentation step inside a line's leading
   whitespace, drawn as one CSS background per line (no extra elements). Blank lines carry the
   guides of the code around them. */
(function () {
  'use strict';
  if (!window.greece || !window.GreeceCodeAnalysis) return;
  const A = window.GreeceCodeAnalysis;

  greece.enhance('code', () => {
    const G = window.greeceCode;
    if (!G) return;
    const { indent, unit, tabs } = A.measureIndent(G.text, G.starts, G.tabWidth);
    const guides = A.guideCounts(indent, unit);
    G.indent = indent;
    G.guides = guides;
    G.indentUnit = tabs ? G.tabWidth : unit;
    const html = document.documentElement;
    html.style.setProperty('--guide-unit', tabs ? 'calc(var(--tab) * 1ch)' : unit + 'ch');
    html.classList.add('has-guides');
    const names = Array.from({ length: 25 }, (_, n) => 'g' + n);
    G.decorate((el, i) => {
      const n = guides[i];
      if (n) el.classList.add('gd', names[Math.min(n, 24)]);
    });
  });
})();
