/* Greece — the symbol navigator: types, functions, MARK sections, keys and rules in a sidebar,
   nested as in the source, following along as you scroll. Click to jump; type to filter. Opens
   from the toolbar or ⇧⌘O, and on its own when the preview is wide and the outline setting is on. */
(function () {
  'use strict';
  if (!window.greece) return;

  const BADGES = {
    class: ['C', 'type'], struct: ['S', 'type'], enum: ['E', 'type'], protocol: ['P', 'type'], extension: ['Ex', 'type'],
    namespace: ['N', 'type'], type: ['T', 'type'], table: ['T', 'type'], query: ['Q', 'type'],
    func: ['ƒ', 'func'], method: ['M', 'func'], property: ['V', 'prop'], key: ['K', 'prop'],
    rule: ['#', 'rule'], section: ['§', 'rule'], target: ['T', 'func'], stage: ['S', 'type'],
  };

  greece.enhance('code', (root, kit) => {
    const G = window.greeceCode;
    if (!G) return;
    const WIDTH = 248;
    let symbols = [];
    let active = -1;
    let items = [];

    const panel = document.createElement('aside');
    panel.className = 'code-symbols code-overlay';
    panel.hidden = true;
    panel.innerHTML = `
      <header><span class="title">Symbols</span><span class="count"></span></header>
      <label class="symbols-filter"><span class="glyph">${G.icons.search}</span><input type="text" placeholder="Filter" spellcheck="false" autocomplete="off" aria-label="Filter symbols"></label>
      <nav class="symbols-list" aria-label="Symbols"></nav>`;
    document.body.appendChild(panel);
    const list = panel.querySelector('.symbols-list');
    const filter = panel.querySelector('input');
    if (!kit.typing) panel.querySelector('.symbols-filter').hidden = true;
    const countLabel = panel.querySelector('.count');
    let button = null;

    function render() {
      const query = filter.value.trim().toLowerCase();
      const shown = symbols.map((s, i) => [s, i]).filter(([s]) => !query || s.name.toLowerCase().includes(query));
      list.innerHTML = shown.map(([s, i]) => {
        if (s.kind === 'mark') {
          return `<a class="sym mark" data-i="${i}" style="--depth:${query ? 0 : s.depth}">${kit.esc(s.name)}</a>`;
        }
        const [letter, tone] = BADGES[s.kind] || ['•', 'prop'];
        return `<a class="sym" data-i="${i}" style="--depth:${query ? 0 : s.depth}" title="${kit.esc(s.name)} — line ${(s.line + 1).toLocaleString()}">`
          + `<i class="badge ${tone}">${letter}</i><span class="name">${kit.esc(s.name)}</span></a>`;
      }).join('') || `<p class="none">${query ? 'No matching symbols' : 'No symbols'}</p>`;
      items = Array.from(list.querySelectorAll('.sym'));
      active = -1;
      track();
    }

    function open(focus) {
      if (!symbols.length) return;
      panel.hidden = false;
      G.setRightInset(WIDTH);
      if (button) button.classList.add('on');
      track();
      if (focus && kit.typing) filter.focus();
      G.emit('layout');
    }
    function close() {
      panel.hidden = true;
      G.setRightInset(0);
      if (button) button.classList.remove('on');
      if (document.activeElement === filter) filter.blur();
      G.emit('layout');
    }
    const toggle = () => (panel.hidden ? open(false) : close());

    /** Highlights the innermost symbol around the top of the viewport. */
    function track() {
      if (panel.hidden || !symbols.length) return;
      const top = G.lineAt(G.inset + (G.stickyHeight || 0) + 4);
      let best = -1;
      for (let i = 0; i < symbols.length && symbols[i].line <= top; i++) {
        if (symbols[i].end >= top || symbols[i].kind === 'mark' || best < 0 || symbols[best].end < top) best = i;
      }
      if (best === active) return;
      active = best;
      let current = null;
      for (const item of items) {
        const on = Number(item.dataset.i) === best;
        item.classList.toggle('active', on);
        if (on) current = item;
      }
      if (current) {
        const top = current.offsetTop, bottom = top + current.offsetHeight;
        if (top < list.scrollTop + 4) list.scrollTop = Math.max(0, top - 24);
        else if (bottom > list.scrollTop + list.clientHeight - 4) list.scrollTop = bottom - list.clientHeight + 24;
      }
    }

    list.addEventListener('click', (event) => {
      const item = event.target.closest('.sym');
      if (!item) return;
      event.preventDefault();
      const symbol = symbols[Number(item.dataset.i)];
      G.scrollToLine(symbol.line, { flash: true });
    });
    filter.addEventListener('input', render);
    filter.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') { event.preventDefault(); if (filter.value) { filter.value = ''; render(); } else filter.blur(); }
      if (event.key === 'Enter') {
        const first = list.querySelector('.sym');
        if (first) first.click();
      }
    });

    function start(analysis) {
      symbols = analysis.symbols || [];
      if (!symbols.length) return;
      countLabel.textContent = symbols.filter((s) => s.kind !== 'mark').length.toLocaleString();
      button = G.addTool({ icon: 'sidebar', label: 'Symbols', title: 'Symbols (⇧⌘O)', order: 40, onClick: toggle });
      render();
      const wide = window.innerWidth >= 1240 && kit.options.outline && symbols.length >= 6;
      if (wide && !G.large) open(false);
    }
    if (G.analysis) start(G.analysis); else G.on('analysis', start);

    window.addEventListener('scroll', track, { passive: true });
    G.on('inset', () => { panel.style.top = G.inset + 'px'; });
    G.on('fold', track);
    G.on('mode', () => { if (G.mode === 'tree') close(); });
    G.addKeys((event) => {
      if (event.metaKey && event.shiftKey && !event.altKey && event.code === 'KeyO' && symbols.length) {
        if (panel.hidden) open(true); else if (document.activeElement === filter) close(); else filter.focus();
        return true;
      }
      return false;
    });
    G.symbols = { open: () => open(false), close, toggle, get list() { return symbols; } };
  });
})();
