/* Greece — hovering a bracket highlights it and its partner (strings, comments and regular
   expressions don't count). Painted with the CSS Custom Highlight API, so lines are untouched. */
(function () {
  'use strict';
  if (!window.greece) return;
  const supported = typeof Highlight === 'function' && window.CSS && CSS.highlights;

  greece.enhance('code', () => {
    const G = window.greeceCode;
    if (!G || !supported) return;
    let B = null;
    let shown = -1;

    /** Index into the bracket table for text offset `offset`, or -1. */
    function bracketAt(offset) {
      const pos = B.pos;
      let lo = 0, hi = pos.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (pos[mid] === offset) return mid;
        if (pos[mid] < offset) lo = mid + 1; else hi = mid - 1;
      }
      return -1;
    }

    function rangeAt(offset) {
      const s = G.starts;
      let lo = 0, hi = s.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (s[mid] <= offset) lo = mid; else hi = mid - 1; }
      if (G.fold && G.fold.isHidden(lo)) return null;
      const el = G.lineElement(lo);
      if (!el) return null;
      let col = offset - s[lo];
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (col < node.nodeValue.length) {
          const range = document.createRange();
          range.setStart(node, col);
          range.setEnd(node, col + 1);
          return range;
        }
        col -= node.nodeValue.length;
      }
      return null;
    }

    function show(index) {
      if (index === shown) return;
      shown = index;
      if (index < 0 || B.match[index] < 0) { CSS.highlights.delete('greece-bracket'); return; }
      const ranges = [rangeAt(B.pos[index]), rangeAt(B.match[index])].filter(Boolean);
      CSS.highlights.set('greece-bracket', new Highlight(...ranges));
    }

    function highlightAt(line, col) {
      if (!B) return;
      show(bracketAt(G.starts[line] + col));
    }

    function onMove(event) {
      if (!B) return;
      const el = event.target.closest && event.target.closest('.ln');
      if (!el || !G.view.contains(el)) { show(-1); return; }
      const line = G.indexOf(el);
      if (G.line(line).length > 4000) { show(-1); return; }
      const caret = document.caretRangeFromPoint(event.clientX, event.clientY);
      if (!caret || !el.contains(caret.startContainer)) { show(-1); return; }
      const before = document.createRange();
      before.selectNodeContents(el);
      before.setEnd(caret.startContainer, caret.startOffset);
      const col = before.toString().length;
      const base = G.starts[line];
      // The caret falls between characters: take the bracket on the side the pointer is over.
      const box = caret.getBoundingClientRect();
      const right = bracketAt(base + col), left = col > 0 ? bracketAt(base + col - 1) : -1;
      show(event.clientX >= box.left ? (right >= 0 ? right : left) : (left >= 0 ? left : right));
    }

    function start(analysis) {
      B = analysis.brackets;
      if (!B || !B.pos.length) { B = null; return; }
      G.view.addEventListener('mousemove', onMove, { passive: true });
      G.view.addEventListener('mouseleave', () => show(-1), { passive: true });
      G.on('lines', () => { if (shown >= 0) { const s = shown; shown = -2; show(s); } });
    }
    if (G.analysis) start(G.analysis); else G.on('analysis', start);
    G.brackets = { highlightAt };
  });
})();
