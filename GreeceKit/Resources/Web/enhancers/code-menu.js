/* Greece — the code view's context menu. Quick Look never passes typed keys to a preview, so
   everything a shortcut does here is also a right-click away: find the selection, copy a line,
   fold, wrap. Elsewhere the shortcuts still work; the menu is simply the pointer's way in. */
(function () {
  'use strict';
  if (!window.greece) return;

  greece.enhance('code', (root, kit) => {
    const G = window.greeceCode;
    if (!G) return;

    /** The line under the pointer, or -1 outside the code (the find bar, the symbols panel…). */
    function lineUnder(event) {
      const target = event.target instanceof Element ? event.target : null;
      if (!target || !target.closest('.code-view') || G.mode === 'tree') return -1;
      const line = target.closest('.ln');
      if (line && line.dataset.n) return Number(line.dataset.n) - 1;
      return G.lineAt(event.clientY);
    }

    greece.contextMenu((event) => {
      const query = kit.selectionQuery();
      if (!query || !G.find) return null;
      return [{ title: kit.t('Find {0}', kit.quoted(query)), run: () => G.find.open(query) }];
    });

    greece.contextMenu((event) => {
      if (String(window.getSelection() || '')) return null;
      const line = lineUnder(event);
      if (line < 0 || line >= G.count) return null;
      const items = [{ title: kit.t('Copy Line {0}', line + 1), run: () => kit.copyText(G.line(line)) }];
      const region = G.fold ? G.fold.regionAt(line) : -1;
      if (region >= 0) {
        const folded = G.fold.isFolded(region);
        items.push({ title: folded ? kit.t('Unfold') : kit.t('Fold'), run: () => G.fold.toggle(region, !folded) });
      }
      return items;
    });

    greece.contextMenu((event) => {
      const target = event.target instanceof Element ? event.target : null;
      if (!target || target.closest('.code-findbar, .code-symbols') || String(window.getSelection() || '')) return null;
      const items = [];
      if (G.wrap && G.mode !== 'tree') {
        items.push({ title: kit.t('Wrap Lines'), checked: document.documentElement.classList.contains('wrap'), run: () => G.wrap.toggle() });
      }
      if (G.fold && G.fold.regionAt && G.mode !== 'tree') {
        items.push({ title: kit.t('Fold All'), run: () => G.fold.foldAll() }, { title: kit.t('Unfold All'), run: () => G.fold.unfoldAll() });
      }
      items.push({ title: kit.t('Copy All'), run: () => kit.copyText(G.text) });
      return items;
    });
  });
})();
