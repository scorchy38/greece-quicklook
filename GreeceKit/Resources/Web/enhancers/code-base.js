/* Greece — the code view's shared model for its features (folding, sticky scroll, find, symbols…).
   Owns the text, line lookup, the file's structure (analysed in a worker for big files), line
   decorations that survive the progressive renderer swapping chunks, the toolbar, keyboard
   shortcuts and copying. Features find it at `window.greeceCode`. */
(function () {
  'use strict';
  if (!window.greece || !window.GreeceCodeAnalysis) return;
  const A = window.GreeceCodeAnalysis;
  const html = document.documentElement;

  /** Small SF Symbol–style icons, drawn on a 16-point grid. */
  const ICONS = {
    search: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="7" cy="7" r="4.6"/><path d="M10.4 10.4 14 14"/></svg>',
    wrap: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 3.5h12M2 8h9.5a2.25 2.25 0 0 1 0 4.5H8M2 12.5h3"/><path d="M9.6 10.6 7.7 12.5l1.9 1.9"/></svg>',
    sidebar: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.2"/><path d="M10 2.75v10.5"/><path d="M11.6 5.5h1.1M11.6 7.5h1.1M11.6 9.5h1.1" stroke-linecap="round"/></svg>',
    tree: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v9.5h3M3 7.75h3"/><path d="M8.5 3h5.5M8.5 7.75H14M8.5 12.5H14"/></svg>',
    code: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 4 2 8l3.5 4M10.5 4 14 8l-3.5 4"/></svg>',
    up: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 10l4-4 4 4"/></svg>',
    down: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6l4 4 4-4"/></svg>',
    close: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/></svg>',
    copy: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><rect x="5.25" y="5.25" width="8.5" height="8.5" rx="1.8"/><path d="M10.75 3.5V3.6A1.6 1.6 0 0 0 9.15 2H3.6A1.6 1.6 0 0 0 2 3.6v5.55a1.6 1.6 0 0 0 1.6 1.6h.15"/></svg>',
  };

  greece.enhance('code', (root, kit) => {
    const view = root.querySelector('.code-view');
    if (!view) return;

    let text = kit.payload.text.replace(/\r\n?/g, '\n');
    if (text.endsWith('\n')) text = text.slice(0, -1);
    const starts = A.lineStarts(text);
    const count = starts.length;
    const lang = kit.payload.language || 'plaintext';
    const tabWidth = parseInt(getComputedStyle(html).getPropertyValue('--tab'), 10) || 4;
    const listeners = {};
    const decorators = [];
    const keys = [];

    const G = window.greeceCode = {
      kit, root, view, text, starts, count, lang, tabWidth,
      large: view.classList.contains('large'),
      analysis: null,
      icons: ICONS,

      /** The text of line `i` (0-based), without its line break. */
      line(i) { return text.slice(starts[i], i + 1 < count ? starts[i + 1] - 1 : text.length); },

      on(name, fn) { (listeners[name] = listeners[name] || []).push(fn); },
      emit(name, detail) {
        for (const fn of listeners[name] || []) { try { fn(detail); } catch (e) { kit.post('log', name + ': ' + (e && e.stack || e)); } }
      },

      /** Runs `fn(element, index)` on every line now and whenever lines are (re)rendered. */
      decorate(fn) {
        decorators.push(fn);
        forEachLine(fn);
      },
      /** Runs every decorator again on lines `from…to` (after a feature's state changes). */
      redecorate(from, to, fn) {
        for (let i = Math.max(0, from); i <= Math.min(to, count - 1); i++) {
          const el = lineElement(i);
          if (el) (fn ? [fn] : decorators).forEach((d) => d(el, i));
        }
      },

      lineElement,
      indexOf(el) { return Number(el.dataset.n) - 1; },
      lineAt,
      rowHeight() { return parseFloat(getComputedStyle(view).lineHeight) || 18; },
      /** Left edge of the code text inside a line, in px from the line's left. */
      codeLeft() { const el = lineElement(0); return el ? parseFloat(getComputedStyle(el).paddingLeft) || 0 : 0; },

      /** Space taken at the top by bars (find), so sticky lines and jumps sit below them. */
      inset: 0,
      setInset(px) {
        G.inset = px;
        html.style.setProperty('--code-inset', px + 'px');
        G.emit('inset', px);
      },

      scrollToLine,
      /** Marks the line a jump landed on, until the next click or key. */
      flash(i) {
        clearTarget();
        target = i;
        const el = lineElement(i);
        if (el) el.classList.add('target');
      },

      /** Adds a button to the floating toolbar, before Copy. Lower `order` comes first. */
      addTool({ id, icon, label, title, order = 50, onClick }) {
        const tools = root.querySelector('.floating-tools');
        if (!tools) return null;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'pill' + (icon ? ' icon' : '');
        if (id) button.id = id;
        button.dataset.order = order;
        button.title = title || label || '';
        button.setAttribute('aria-label', label || title || '');
        button.innerHTML = icon ? ICONS[icon] : kit.esc(label);
        button.addEventListener('click', (e) => { e.preventDefault(); onClick(button, e); });
        const before = Array.from(tools.children).find((c) => !c.dataset.order || Number(c.dataset.order) > order);
        tools.insertBefore(button, before || null);
        return button;
      },

      /** Keyboard shortcuts: `fn(event)` returns true when it handled the key. */
      addKeys(fn) { keys.push(fn); },

      /** Copying a selection: the source text of the selected lines, never line numbers or
          fold placeholders, and every line inside a fold. */
      selectedText,
    };

    // ---------------------------------------------------------------- Lines

    let target = -1;
    function clearTarget() {
      if (target < 0) return;
      const el = lineElement(target);
      if (el) el.classList.remove('target');
      target = -1;
    }
    decorators.push((el, i) => { if (i === target) el.classList.add('target'); });
    document.addEventListener('pointerdown', clearTarget, true);
    document.addEventListener('keydown', clearTarget, true);

    /** Chunk elements and their first lines, refreshed as the renderer appends chunks. */
    let chunks = [];
    let chunkStarts = [];
    function refreshChunks() {
      chunks = Array.from(view.children);
      chunkStarts = chunks.map((c) => Number(c.dataset.start) || 0);
    }
    refreshChunks();

    function lineElement(i) {
      if (i < 0 || i >= count) return null;
      let lo = 0, hi = chunkStarts.length - 1;
      if (hi < 0) return null;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (chunkStarts[mid] <= i) lo = mid; else hi = mid - 1;
      }
      const chunk = chunks[lo];
      const el = chunk && chunk.children[i - chunkStarts[lo]];
      return el && el.dataset.n == i + 1 ? el : null;
    }

    function forEachLine(fn, scope) {
      const lines = (scope || view).getElementsByClassName('ln');
      for (let k = 0; k < lines.length; k++) fn(lines[k], Number(lines[k].dataset.n) - 1);
    }

    // Chunks are appended after the first paint and their contents swapped once highlighted:
    // decorate whatever is new, before it's drawn.
    new MutationObserver((records) => {
      const fresh = new Set();
      let appended = false;
      for (const r of records) {
        if (r.target === view) { appended = true; r.addedNodes.forEach((n) => { if (n.nodeType === 1) fresh.add(n); }); }
        else if (r.target.classList && r.target.classList.contains('chunk') && r.addedNodes.length) fresh.add(r.target);
      }
      if (appended) refreshChunks();
      if (!fresh.size) return;
      fresh.forEach((chunk) => decorators.forEach((fn) => forEachLine(fn, chunk)));
      G.emit('lines', fresh);
    }).observe(view, { childList: true, subtree: true });

    /** The line drawn at viewport height `y`, looking through Greece's own overlays. */
    function lineAt(y) {
      html.classList.add('probing');
      const el = document.elementFromPoint(2, Math.max(0, y));
      html.classList.remove('probing');
      const line = el && el.closest && el.closest('.code-view .ln');
      if (line) return Number(line.dataset.n) - 1;
      const box = view.getBoundingClientRect();
      if (y < box.top) return 0;
      if (y >= box.bottom) return count - 1;
      return -1;
    }

    /** Scrolls line `i` into view (centred, or at the top below sticky lines). */
    function scrollToLine(i, { block = 'center', flash = false } = {}) {
      G.emit('reveal', i);
      const el = lineElement(i);
      if (!el) return false;
      const box = el.getBoundingClientRect();
      const top = box.top + window.scrollY;
      let y;
      if (block === 'start') y = top - G.inset;
      else if (block === 'nearest') {
        const visibleTop = G.inset + (G.stickyHeight || 0);
        if (box.top >= visibleTop && box.bottom <= window.innerHeight - 8) y = window.scrollY;
        else y = top - G.inset - (window.innerHeight - G.inset) / 3;
      } else y = top - G.inset - (window.innerHeight - G.inset - box.height) / 2;
      window.scrollTo(window.scrollX, Math.max(0, y));
      if (flash) G.flash(i);
      return true;
    }

    // ---------------------------------------------------------------- Structure

    function receive(result) {
      G.analysis = result;
      G.emit('analysis', result);
    }

    const small = count <= 3000 && text.length <= 400000;
    if (small) {
      try { receive(A.analyze(text, lang, tabWidth)); } catch (e) { kit.post('log', 'analysis: ' + e); }
    } else {
      // Big files are analysed in a worker once the first screenful is showing.
      kit.afterReady(() => {
        const fallback = () => kit.tick().then(() => { try { receive(A.analyze(text, lang, tabWidth)); } catch (e) { kit.post('log', 'analysis: ' + e); } });
        try {
          const source = 'const A = ' + A.source + ';\nonmessage = (e) => { const r = A.analyze(e.data.text, e.data.lang, e.data.tab); postMessage(r, A.transferables(r)); };';
          const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
          worker.onmessage = (e) => { worker.terminate(); receive(e.data); };
          worker.onerror = (e) => { worker.terminate(); kit.post('log', 'analysis worker: ' + (e && e.message)); fallback(); };
          worker.postMessage({ text, lang, tab: tabWidth });
        } catch (e) {
          fallback();
        }
      });
    }

    // ---------------------------------------------------------------- Keys

    document.addEventListener('keydown', (event) => {
      for (const fn of keys) {
        if (fn(event)) { event.preventDefault(); event.stopPropagation(); return; }
      }
    }, true);

    // ---------------------------------------------------------------- Copy

    function boundary(node, offset) {
      const host = node.nodeType === 1 ? node : node.parentElement;
      const el = host && host.closest('.ln');
      if (!el || !view.contains(el)) return null;
      const range = document.createRange();
      range.selectNodeContents(el);
      range.setEnd(node, offset);
      return { line: Number(el.dataset.n) - 1, col: range.toString().length };
    }

    function selectedText() {
      const selection = window.getSelection();
      if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
      const range = selection.getRangeAt(0);
      const whole = document.createRange();
      whole.selectNodeContents(view);
      let from = boundary(range.startContainer, range.startOffset);
      let to = boundary(range.endContainer, range.endOffset);
      if (!from && range.compareBoundaryPoints(Range.START_TO_START, whole) <= 0 && range.compareBoundaryPoints(Range.END_TO_START, whole) < 0) from = { line: 0, col: 0 };
      if (!to && range.compareBoundaryPoints(Range.END_TO_END, whole) >= 0 && range.compareBoundaryPoints(Range.START_TO_END, whole) > 0) to = { line: count - 1, col: G.line(count - 1).length };
      if (!from || !to) return null;
      const a = starts[from.line] + Math.min(from.col, G.line(from.line).length);
      const b = starts[to.line] + Math.min(to.col, G.line(to.line).length);
      return text.slice(a, Math.max(a, b));
    }

    document.addEventListener('copy', (event) => {
      if (G.mode && G.mode !== 'code') return;
      const value = selectedText();
      if (value == null || !event.clipboardData) return;
      event.clipboardData.setData('text/plain', value);
      event.preventDefault();
    });
  });
})();
