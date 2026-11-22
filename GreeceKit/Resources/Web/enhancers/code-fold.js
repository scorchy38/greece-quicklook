/* Greece — code folding. Chevrons appear in the gutter on hover for every brace or indentation
   block; a folded block shows its header with a "⋯ 12 lines" pill (and the closing bracket when
   the block ends on a line of its own). Option-click folds or unfolds everything inside too.
   Hidden lines stay in the document, so copying across a fold still copies them. */
(function () {
  'use strict';
  if (!window.greece) return;

  greece.enhance('code', () => {
    const G = window.greeceCode;
    if (!G) return;
    const count = G.count;
    const hidden = new Uint8Array(count);
    let R = null;
    let folded = null;

    let hiddenPrefix = null;
    G.fold = {
      isHidden: (i) => hidden[i] === 1,
      /** For each line, how many lines above it are folded away (and the total at `count`). */
      hiddenBefore() {
        if (!hiddenPrefix) {
          hiddenPrefix = new Int32Array(count + 1);
          for (let i = 0; i < count; i++) hiddenPrefix[i + 1] = hiddenPrefix[i] + hidden[i];
        }
        return hiddenPrefix;
      },
      isFolded: (r) => !!(folded && folded[r]),
      toggle, foldAll, unfoldAll, reveal,
      regionAt: (i) => (R ? R.at[i] : -1),
    };

    function linesLabel(n) { return n === 1 ? '1 line' : n.toLocaleString() + ' lines'; }

    function decorate(el, i) {
      // Touch classes only when they change: this runs on every line of a huge file.
      const r = R.at[i];
      const cl = el.classList;
      if (hidden[i]) cl.add('fh'); else if (cl.contains('fh')) cl.remove('fh');
      if (r < 0) return;
      if (!cl.contains('fs')) cl.add('fs');
      const isFolded = folded[r] === 1;
      if (cl.contains('fo') !== isFolded) cl.toggle('fo', isFolded);
      let pill = el.lastElementChild && el.lastElementChild.classList.contains('fold-ph') ? el.lastElementChild : null;
      if (isFolded && !pill) {
        pill = document.createElement('span');
        pill.className = 'fold-ph';
        el.appendChild(pill);
      } else if (!isFolded && pill) {
        pill.remove();
        pill = null;
      }
      if (pill) {
        pill.dataset.lines = '⋯  ' + linesLabel(R.hide[r] - R.start[r]);
        pill.dataset.tail = R.tail[r] ? G.line(R.end[r]).trim() : '';
        pill.title = 'Show ' + linesLabel(R.hide[r] - R.start[r]);
      }
    }

    /** Recomputes which lines are hidden from `from` to `to`, honouring folds nested inside. */
    function refresh(from, to) {
      const changed = [];
      let l = from;
      while (l <= to) {
        if (hidden[l]) { hidden[l] = 0; changed.push(l); }
        const r = R.at[l];
        if (r >= 0 && folded[r]) {
          const end = R.hide[r];
          for (let k = l + 1; k <= end; k++) if (!hidden[k]) { hidden[k] = 1; changed.push(k); }
          l = end + 1;
        } else l++;
      }
      return changed;
    }

    function apply(changed, headers) {
      for (const i of changed) {
        const el = G.lineElement(i);
        if (el) el.classList.toggle('fh', hidden[i] === 1);
      }
      for (const h of headers) {
        const el = G.lineElement(h);
        if (el) decorate(el, h);
      }
      hideEmptyChunks();
      hiddenPrefix = null;
      G.emit('fold');
    }

    /** Chunks whose every line is folded away are taken out of layout altogether. */
    function hideEmptyChunks() {
      for (const chunk of G.view.children) {
        const first = Number(chunk.dataset.start) || 0;
        const last = Math.min(count, first + chunk.children.length) - 1;
        let all = last >= first;
        for (let i = first; i <= last && all; i++) if (!hidden[i]) all = false;
        chunk.classList.toggle('folded-away', all);
      }
    }

    function toggle(r, fold, deep) {
      if (!R || r < 0) return;
      const target = fold === undefined ? !folded[r] : fold;
      const headers = [R.start[r]];
      if (deep) {
        for (let k = r + 1; k < R.start.length && R.start[k] <= R.end[r]; k++) {
          folded[k] = target ? 1 : 0;
          headers.push(R.start[k]);
        }
      }
      folded[r] = target ? 1 : 0;
      // A fold inside a folded block stays hidden either way.
      let outer = R.parent[r];
      let covered = false;
      while (outer >= 0) { if (folded[outer]) { covered = true; break; } outer = R.parent[outer]; }
      const changed = covered ? [] : refresh(R.start[r], R.hide[r]);
      apply(changed, headers);
    }

    function setAll(value) {
      if (!R) return;
      folded.fill(value);
      const changed = refresh(0, count - 1);
      apply(changed, Array.from(R.start));
    }
    function foldAll() { setAll(1); }
    function unfoldAll() { setAll(0); }

    /** Unfolds whatever hides line `i`. */
    function reveal(i) {
      if (!R || !hidden[i]) return;
      const opened = [];
      for (let r = 0; r < R.start.length; r++) {
        if (folded[r] && R.start[r] < i && R.hide[r] >= i) { folded[r] = 0; opened.push(r); }
      }
      if (!opened.length) return;
      const from = Math.min(...opened.map((r) => R.start[r]));
      const to = Math.max(...opened.map((r) => R.hide[r]));
      apply(refresh(from, to), opened.map((r) => R.start[r]));
    }
    G.on('reveal', reveal);

    function start(analysis) {
      R = analysis.regions;
      folded = new Uint8Array(R.start.length);
      if (!R.start.length) return;
      G.decorate(decorate);
    }
    if (G.analysis) start(G.analysis); else G.on('analysis', start);

    // Chevrons sit in the gap between line numbers and code.
    G.view.addEventListener('mousedown', (event) => {
      if (!R || event.button !== 0) return;
      const pill = event.target.closest('.fold-ph');
      const el = event.target.closest('.ln');
      if (!el) return;
      const i = G.indexOf(el);
      const r = R.at[i];
      if (r < 0) return;
      if (pill) { event.preventDefault(); toggle(r, false); return; }
      const x = event.clientX - el.getBoundingClientRect().left;
      const left = G.codeLeft();
      if (x >= left - 21 && x <= left - 2) {
        event.preventDefault();
        toggle(r, undefined, event.altKey);
      }
    });

    G.addKeys((event) => {
      if (!R || !event.metaKey || !event.altKey) return false;
      // ⌥⌘← folds everything, ⌥⌘→ unfolds everything (as Xcode's ⌥⌘⇧ arrows).
      if (event.key === 'ArrowLeft') { foldAll(); return true; }
      if (event.key === 'ArrowRight') { unfoldAll(); return true; }
      return false;
    });
  });
})();
