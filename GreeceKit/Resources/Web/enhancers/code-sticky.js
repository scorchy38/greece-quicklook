/* Greece — sticky scroll: the headers of the blocks you're scrolled into (class, function, the
   `if` around you, a YAML key…) stay pinned at the top, the innermost one pushed away as its block
   ends. Clicking a pinned line scrolls back to it. Driven by scroll events, never timers. */
(function () {
  'use strict';
  if (!window.greece) return;

  const MAX_ROWS = 5;
  const TRIVIAL = /^[\s(){}[\],;:]*$/;

  greece.enhance('code', (root, kit) => {
    const G = window.greeceCode;
    if (!G) return;
    let R = null;
    let shown = [];
    let lastKey = '';

    const overlay = document.createElement('div');
    overlay.className = 'code-sticky code-overlay';
    overlay.hidden = true;
    overlay.setAttribute('aria-hidden', 'true');
    const inner = document.createElement('div');
    inner.className = 'code-sticky-rows';
    overlay.appendChild(inner);
    root.insertBefore(overlay, G.view);

    /** Regions enclosing line `l` whose headers are above it, outermost first. */
    function chain(l) {
      let lo = 0, hi = R.start.length - 1, k = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (R.start[mid] < l) { k = mid; lo = mid + 1; } else hi = mid - 1;
      }
      const out = [];
      while (k >= 0) {
        if (R.end[k] >= l && !TRIVIAL.test(G.line(R.start[k]))) out.push(k);
        k = R.parent[k];
      }
      return out.reverse();
    }

    function update() {
      if (!R || G.mode === 'tree') { hide(); return; }
      const rowH = G.rowHeight();
      const top = G.inset;
      const rows = Math.min(MAX_ROWS, Math.floor((window.innerHeight - top) / rowH / 3));
      const chosen = [];
      for (let d = 0; d < rows; d++) {
        const line = G.lineAt(top + d * rowH + 1);
        if (line < 0) break;
        const regions = chain(line);
        if (regions.length <= d) break;
        let consistent = true;
        for (let k = 0; k < d; k++) if (regions[k] !== chosen[k]) { consistent = false; break; }
        if (!consistent) break;
        chosen.push(regions[d]);
      }
      if (!chosen.length) { hide(); return; }

      // The innermost row slides up as its block's last line arrives beneath it.
      let push = 0;
      const last = chosen[chosen.length - 1];
      const endEl = G.lineElement(R.end[last]);
      if (endEl && !G.fold?.isHidden(R.end[last])) {
        const bottom = endEl.getBoundingClientRect().bottom;
        const limit = top + chosen.length * rowH;
        if (bottom < limit) push = Math.max(-rowH, bottom - limit);
      }

      const key = chosen.join(',');
      if (key !== lastKey) {
        lastKey = key;
        shown = chosen;
        inner.innerHTML = chosen.map((r, d) => {
          const line = R.start[r];
          const el = G.lineElement(line);
          const body = el ? contentOf(el) : kit.esc(G.line(line));
          return `<div class="ln sticky-row" data-n="${line + 1}" data-depth="${d}">${body}</div>`;
        }).join('');
      }
      overlay.hidden = false;
      overlay.style.height = (chosen.length * rowH + push) + 'px';
      const lastRow = inner.lastElementChild;
      if (lastRow) lastRow.style.transform = push ? `translateY(${push}px)` : '';
      inner.style.transform = window.scrollX ? `translateX(${-window.scrollX}px)` : '';
      G.stickyHeight = chosen.length * rowH + push;
    }

    /** A line's highlighted markup, without fold pills or other decorations. */
    function contentOf(el) {
      const pill = el.querySelector('.fold-ph');
      if (!pill) return el.innerHTML;
      const copy = el.cloneNode(true);
      copy.querySelectorAll('.fold-ph').forEach((n) => n.remove());
      return copy.innerHTML;
    }

    function hide() {
      if (!overlay.hidden) overlay.hidden = true;
      shown = [];
      lastKey = '';
      G.stickyHeight = 0;
    }

    overlay.addEventListener('mousedown', (event) => event.preventDefault());
    overlay.addEventListener('click', (event) => {
      const row = event.target.closest('.sticky-row');
      if (!row) return;
      const line = Number(row.dataset.n) - 1;
      const depth = Number(row.dataset.depth);
      const el = G.lineElement(line);
      if (!el) return;
      // Bring the header back into the page, just below the rows above it.
      const y = el.getBoundingClientRect().top + window.scrollY - G.inset - depth * G.rowHeight();
      window.scrollTo(window.scrollX, Math.max(0, y));
    });

    function start(analysis) {
      R = analysis.regions;
      if (!R.start.length) return;
      update();
    }
    if (G.analysis) start(G.analysis); else G.on('analysis', start);

    window.addEventListener('scroll', () => { if (R) update(); }, { passive: true });
    window.addEventListener('resize', () => { if (R) update(); }, { passive: true });
    for (const name of ['fold', 'inset', 'wrap', 'mode', 'lines']) G.on(name, () => { if (R) { lastKey = ''; update(); } });
    kit.onApply(() => { if (R) { lastKey = ''; update(); } });
    kit.afterReady(() => { if (R) update(); });
    G.sticky = { update, get rows() { return shown.length; } };
  });
})();
