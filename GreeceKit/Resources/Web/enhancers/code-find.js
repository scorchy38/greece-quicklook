/* Greece — find (⌘F) and go to line (⌘L) in one bar along the top, as in Xcode and Safari.
   Searches the text itself in short slices (never freezing on a huge file), highlights matches
   near the viewport with the CSS Custom Highlight API (the lines' markup is never touched), marks
   every match beside the scroller, and steps with ⏎ / ⇧⏎ or ⌘G / ⇧⌘G. The JSON tree registers its
   own search provider and reuses this bar. */
(function () {
  'use strict';
  if (!window.greece) return;

  const MAX_MATCHES = 500000;
  const supportsHighlights = typeof Highlight === 'function' && window.CSS && CSS.highlights;

  greece.enhance('code', (root, kit) => {
    const G = window.greeceCode;
    if (!G) return;
    const icons = G.icons;

    // ---------------------------------------------------------------- The bar

    const bar = document.createElement('div');
    bar.className = 'findbar code-findbar code-overlay';
    bar.hidden = true;
    bar.setAttribute('role', 'search');
    bar.innerHTML = `
      <span class="bar-title">${kit.esc(kit.t('Go to Line'))}</span>
      <label class="find-field">
        <span class="glyph">${icons.search}</span>
        <input type="text" spellcheck="false" autocomplete="off" autocorrect="off" aria-label="${kit.esc(kit.t('Find'))}">
        <span class="find-count" aria-live="polite"></span>
      </label>
      <div class="find-steps" role="group">
        <button type="button" class="find-prev" title="${kit.esc(kit.t('Previous'))} (⇧⌘G)" aria-label="${kit.esc(kit.t('Previous'))}">${icons.up}</button>
        <button type="button" class="find-next" title="${kit.esc(kit.t('Next'))} (⌘G)" aria-label="${kit.esc(kit.t('Next'))}">${icons.down}</button>
      </div>
      <button type="button" class="find-option find-case" aria-pressed="false" title="${kit.esc(kit.t('Match Case'))} (⌥⌘C)">Aa</button>
      <button type="button" class="find-option find-word" aria-pressed="false" title="${kit.esc(kit.t('Whole Words'))} (⌥⌘W)"><span>ab</span></button>
      <span class="find-spacer"></span>
      <button type="button" class="find-done">${kit.esc(kit.t('Done'))}</button>`;
    document.body.appendChild(bar);
    const input = bar.querySelector('input');
    if (!kit.typing) {
      // Quick Look: keys go to Finder, so the field only shows the query; selecting text sets it.
      input.readOnly = true;
      input.tabIndex = -1;
      bar.classList.add('by-selection');
    }
    const countLabel = bar.querySelector('.find-count');
    const caseButton = bar.querySelector('.find-case');
    const wordButton = bar.querySelector('.find-word');

    const marks = document.createElement('canvas');
    marks.className = 'code-find-marks code-overlay';
    marks.hidden = true;
    document.body.appendChild(marks);

    let mode = 'find';           // or 'goto'
    let options = { caseSensitive: false, wholeWord: false };
    let lastQuery = '';

    /** Where the search should start: the selected occurrence it was opened for, read before the
        field takes focus (focusing it replaces the page's selection). */
    let startAt = -1;

    function open(query, as = 'find') {
      const selected = kit.selectionQuery();
      startAt = as === 'find' && selected && (query === selected || (query === undefined && !kit.typing)) ? selectionOffset() : -1;
      mode = as;
      bar.classList.toggle('goto', as === 'goto');
      if (bar.hidden) {
        bar.hidden = false;
        const height = bar.offsetHeight;
        shift(height);
        if (window.scrollY > 0) window.scrollBy(0, height);
        G.setInset(height);
      }
      if (as === 'goto') {
        input.value = '';
        input.placeholder = kit.t('Line');
        input.setAttribute('aria-label', kit.t('Go to Line'));
        countLabel.textContent = '1–' + kit.number(G.count);
        clearHighlights();
        marks.hidden = true;
      } else {
        input.placeholder = kit.typing ? kit.t('Find') : kit.t('Select text to find it');
        input.setAttribute('aria-label', kit.t('Find'));
        if (typeof query === 'string') input.value = query;
        else if (!kit.typing && kit.selectionQuery()) input.value = kit.selectionQuery();
        else if (!input.value && lastQuery) input.value = lastQuery;
        search();
      }
      if (!kit.typing) return;
      input.focus();
      input.select();
    }

    function close() {
      if (bar.hidden) return;
      const height = G.inset;
      bar.hidden = true;
      shift(0);
      if (window.scrollY > height) window.scrollBy(0, -height);
      G.setInset(0);
      token++;
      provider().clear();
      clearHighlights();
      marks.hidden = true;
      if (document.activeElement === input) input.blur();
    }

    /** The bar pushes the page down, as Safari's does. A transform moves it without a new
        layout (re-laying out a 100,000-line page would take seconds), and scrolling by the same
        amount keeps what you're reading in place. */
    function shift(px) {
      for (const el of root.children) {
        if (el.matches('.code-view, .notice, .json-tree')) el.style.transform = px ? `translateY(${px}px)` : '';
      }
      const tools = root.querySelector('.floating-tools');
      if (tools) tools.style.top = px ? (px + 10) + 'px' : '';
    }

    function setOption(button, key) {
      options[key] = !options[key];
      button.setAttribute('aria-pressed', String(options[key]));
      button.classList.toggle('on', options[key]);
      if (!bar.hidden && mode === 'find') search();
    }

    input.addEventListener('input', () => { if (mode === 'find') search(); else validateLine(); });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        if (mode === 'goto') { go(); return; }
        if (event.shiftKey) previous(); else next();
      } else if (event.key === 'Escape') {
        event.preventDefault();
        close();
      }
    });
    bar.querySelector('.find-prev').addEventListener('click', () => previous());
    bar.querySelector('.find-next').addEventListener('click', () => next());
    caseButton.addEventListener('click', () => setOption(caseButton, 'caseSensitive'));
    wordButton.addEventListener('click', () => setOption(wordButton, 'wholeWord'));
    bar.querySelector('.find-done').addEventListener('click', close);
    bar.addEventListener('mousedown', (event) => { if (event.target !== input || !kit.typing) event.preventDefault(); });

    // Without a keyboard, selecting text while the bar is open searches for it.
    if (!kit.typing) {
      document.addEventListener('mouseup', (event) => {
        // Left button only: a right-click selects a word too, and offers Find in its menu.
        if (event.button !== 0 || bar.hidden || mode !== 'find' || bar.contains(event.target)) return;
        const query = kit.selectionQuery();
        if (query && query !== input.value) open(query, 'find');
      });
    }

    // ---------------------------------------------------------------- Go to line

    function validateLine() {
      const n = parseInt(input.value, 10);
      bar.classList.toggle('invalid', input.value.trim() !== '' && !(n >= 1 && n <= G.count));
    }

    async function go() {
      const n = parseInt(input.value, 10);
      if (!(n >= 1 && n <= G.count)) { validateLine(); return; }
      close();
      if (G.mode === 'tree' && G.tree) await G.tree.hide();
      await whenRendered(n - 1);
      G.scrollToLine(n - 1, { flash: true });
    }

    /** Waits for line `i` to be in the document (big files append lines after the first paint). */
    function whenRendered(i) {
      if (G.lineElement(i)) return Promise.resolve();
      return new Promise((resolve) => {
        G.on('lines', function check() { if (G.lineElement(i)) resolve(); });
      });
    }

    // ---------------------------------------------------------------- Searching the code

    let token = 0;

    const codeSearch = {
      offsets: new Int32Array(1024),
      lengths: new Int32Array(1024),
      count: 0,
      current: -1,
      done: true,

      async run(query, opts, progress) {
        const mine = ++token;
        this.count = 0;
        this.current = -1;
        this.done = false;
        if (!query) { this.done = true; return; }
        const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const source = opts.wholeWord ? `(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])` : escaped;
        let pattern;
        try { pattern = new RegExp(source, 'gu' + (opts.caseSensitive ? '' : 'i')); } catch (_) { this.done = true; return; }
        const text = G.text;
        let sliceStart = performance.now();
        let m;
        while ((m = pattern.exec(text))) {
          if (m[0].length === 0) { pattern.lastIndex++; continue; }
          if (this.count === this.offsets.length) {
            const grow = (a) => { const b = new Int32Array(a.length * 2); b.set(a); return b; };
            this.offsets = grow(this.offsets);
            this.lengths = grow(this.lengths);
          }
          this.offsets[this.count] = m.index;
          this.lengths[this.count] = m[0].length;
          this.count++;
          if (this.count >= MAX_MATCHES) break;
          if ((this.count & 255) === 0 && performance.now() - sliceStart > 40) {
            progress();
            await kit.tick();
            if (mine !== token) return;
            sliceStart = performance.now();
          }
        }
        if (mine !== token) return;
        this.done = true;
      },

      clear() { this.count = 0; this.current = -1; },

      lineOf(offset) {
        const s = G.starts;
        let lo = 0, hi = s.length - 1;
        while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (s[mid] <= offset) lo = mid; else hi = mid - 1; }
        return lo;
      },

      /** The match that starts at text offset `offset`, or -1. */
      indexAt(offset) {
        let lo = 0, hi = this.count;
        while (lo < hi) { const mid = (lo + hi) >> 1; if (this.offsets[mid] < offset) lo = mid + 1; else hi = mid; }
        return lo < this.count && this.offsets[lo] === offset ? lo : -1;
      },

      /** The first match at or after the top of the viewport. */
      nearest() {
        const top = Math.max(0, G.lineAt(G.inset + (G.stickyHeight || 0) + 2));
        const offset = G.starts[top] || 0;
        let lo = 0, hi = this.count;
        while (lo < hi) { const mid = (lo + hi) >> 1; if (this.offsets[mid] < offset) lo = mid + 1; else hi = mid; }
        return lo < this.count ? lo : 0;
      },

      async select(index) {
        this.current = index;
        const offset = this.offsets[index];
        const line = this.lineOf(offset);
        G.emit('reveal', line);
        await whenRendered(line);
        if (this.current !== index) return;
        const range = rangeFor(line, offset - G.starts[line], this.lengths[index]);
        const box = range ? range.getBoundingClientRect() : null;
        const visibleTop = G.inset + (G.stickyHeight || 0);
        if (!box || box.top < visibleTop || box.bottom > window.innerHeight - 8) G.scrollToLine(line);
        const after = range ? range.getBoundingClientRect() : null;
        if (after && (after.right > window.innerWidth - 24 || after.left < G.codeLeft())) {
          window.scrollTo(Math.max(0, window.scrollX + after.left - window.innerWidth / 2), window.scrollY);
        }
        paint();
      },

      /** Ranges for matches on lines near the viewport. */
      visibleRanges() {
        const first = Math.max(0, G.lineAt(G.inset) - 40);
        const last = Math.min(G.count - 1, Math.max(first, G.lineAt(window.innerHeight - 1)) + 40);
        painted = [first, last];
        const from = G.starts[first];
        const to = last + 1 < G.count ? G.starts[last + 1] : G.text.length + 1;
        let lo = 0, hi = this.count;
        while (lo < hi) { const mid = (lo + hi) >> 1; if (this.offsets[mid] < from) lo = mid + 1; else hi = mid; }
        const all = [];
        let current = null;
        for (let k = lo; k < this.count && this.offsets[k] < to && all.length < 2000; k++) {
          const line = this.lineOf(this.offsets[k]);
          if (G.fold && G.fold.isHidden(line)) continue;
          const range = rangeFor(line, this.offsets[k] - G.starts[line], this.lengths[k]);
          if (!range) continue;
          if (k === this.current) current = range; else all.push(range);
        }
        return { all, current };
      },

      /** Where each match sits along the document, 0…1, for the scroller marks. Worked out from
          line numbers (less folded lines), never from layout: measuring a huge file's chunks would
          make WebKit lay out every line. */
      positions() {
        const hidden = G.fold ? G.fold.hiddenBefore() : null;
        const shown = hidden ? G.count - hidden[G.count] : G.count;
        const result = new Float32Array(this.count);
        for (let k = 0; k < this.count; k++) {
          const line = this.lineOf(this.offsets[k]);
          result[k] = (line - (hidden ? hidden[line] : 0)) / Math.max(1, shown);
        }
        return result;
      },
    };

    /** Where the selection starts in the file's text, or -1 when it isn't in the code. */
    function selectionOffset() {
      const selection = window.getSelection();
      if (!selection || !selection.rangeCount) return -1;
      const range = selection.getRangeAt(0);
      const start = range.startContainer;
      const element = start.nodeType === Node.ELEMENT_NODE ? start : start.parentElement;
      const line = element && element.closest('.ln');
      if (!line || !line.dataset.n || start.nodeType !== Node.TEXT_NODE) return -1;
      const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
      let seen = 0, node;
      while ((node = walker.nextNode()) && node !== start) seen += node.nodeValue.length;
      return node ? G.starts[Number(line.dataset.n) - 1] + seen + range.startOffset : -1;
    }

    function rangeFor(line, col, length) {
      const el = G.lineElement(line);
      if (!el) return null;
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      let seen = 0, node, range = null;
      while ((node = walker.nextNode())) {
        const len = node.nodeValue.length;
        if (!range && col < seen + len) {
          range = document.createRange();
          range.setStart(node, col - seen);
        }
        if (range && col + length <= seen + len) {
          range.setEnd(node, col + length - seen);
          return range;
        }
        seen += len;
      }
      return null;
    }

    // ---------------------------------------------------------------- Driving a provider

    const provider = () => (G.mode === 'tree' && G.tree && G.tree.search) || codeSearch;

    async function search() {
      const query = input.value;
      lastQuery = query;
      const p = provider();
      // While searching, only the count moves; highlights and marks are drawn once at the end.
      const run = p.run(query, options, () => updateCount(p, true));
      await run;
      if (p.count && p.current < 0 && query === input.value) {
        // Searching for a selection starts at that very occurrence.
        const index = p === codeSearch && startAt >= 0 ? codeSearch.indexAt(startAt) : -1;
        startAt = -1;
        await p.select(index >= 0 ? index : p.nearest());
      }
      updateCount(p, false);
      paint();
    }

    function updateCount(p, running) {
      if (mode !== 'find') return;
      if (!input.value) { countLabel.textContent = ''; bar.classList.remove('invalid'); return; }
      const capped = p.count >= MAX_MATCHES;
      const total = capped ? kit.t('{0}+', MAX_MATCHES) : kit.number(p.count);
      if (running) countLabel.textContent = total + '…';
      else if (!p.count) countLabel.textContent = kit.t('No matches');
      else if (p.current >= 0) countLabel.textContent = kit.t('{0} of {1}', p.current + 1, total);
      else countLabel.textContent = capped ? kit.t('{0}+ matches', MAX_MATCHES) : kit.plural(p.count, '{0} matches');
      bar.classList.toggle('invalid', !running && p.count === 0);
    }

    async function step(delta) {
      if (bar.hidden || mode !== 'find') { open(undefined, 'find'); return; }
      const p = provider();
      if (!p.count) return;
      const index = p.current < 0 ? p.nearest() : (p.current + delta + p.count) % p.count;
      await p.select(index);
      updateCount(p, !p.done);
    }
    const next = () => step(1);
    const previous = () => step(-1);

    // ---------------------------------------------------------------- Painting

    /* One Highlight per kind, emptied and refilled rather than replaced: WebKit repaints the
       ranges a highlight loses only when that same object changes, so a replaced one can leave
       an old match painted yellow after the query changes. */
    const highlights = supportsHighlights ? { all: new Highlight(), current: new Highlight() } : null;
    if (highlights) {
      CSS.highlights.set('greece-find', highlights.all);
      CSS.highlights.set('greece-find-current', highlights.current);
    }

    function clearHighlights() {
      if (!highlights) return;
      highlights.all.clear();
      highlights.current.clear();
    }

    let painted = [0, -1];

    /** Highlights matches near the viewport, and the scroller marks unless `marksToo` is false. */
    function paint(marksToo = true) {
      if (bar.hidden || mode !== 'find') return;
      const p = provider();
      if (p === codeSearch && highlights) {
        const { all, current } = codeSearch.visibleRanges();
        clearHighlights();
        for (const range of all) highlights.all.add(range);
        if (current) highlights.current.add(current);
      }
      if (p.paint) p.paint();
      if (marksToo) drawMarks(p);
    }

    function drawMarks(p) {
      if (!p.positions || !p.count) { marks.hidden = true; return; }
      const height = window.innerHeight - G.inset;
      const width = 8;
      const scale = window.devicePixelRatio || 1;
      marks.hidden = false;
      marks.style.height = height + 'px';
      marks.width = width * scale;
      marks.height = Math.max(1, Math.round(height * scale));
      const g = marks.getContext('2d');
      const styles = getComputedStyle(marks);
      const color = styles.getPropertyValue('--mark').trim() || '#d9a400';
      const strong = styles.getPropertyValue('--mark-current').trim() || '#ff9f0a';
      g.clearRect(0, 0, marks.width, marks.height);
      g.fillStyle = color;
      const positions = p.positions();
      let lastY = -10;
      const markHeight = Math.max(2, Math.round(2 * scale));
      for (const at of positions) {
        const y = Math.round(at * (marks.height - markHeight));
        if (y === lastY) continue;
        lastY = y;
        g.fillRect(2 * scale, y, (width - 3) * scale, markHeight);
      }
      if (p.current >= 0 && positions[p.current] !== undefined) {
        g.fillStyle = strong;
        g.fillRect(0, Math.round(positions[p.current] * (marks.height - markHeight)) - scale, width * scale, markHeight + 2 * scale);
      }
    }

    let lastPaintTop = -1;
    window.addEventListener('scroll', () => {
      if (bar.hidden || mode !== 'find' || !provider().count) return;
      const top = Math.round(window.scrollY / 200);
      if (top === lastPaintTop) return;
      lastPaintTop = top;
      paint(false);
    }, { passive: true });
    window.addEventListener('resize', () => { if (!bar.hidden) paint(); }, { passive: true });
    G.on('inset', () => { marks.style.top = G.inset + 'px'; marks.style.right = G.insetRight + 'px'; });
    for (const name of ['fold', 'wrap']) G.on(name, () => { if (!bar.hidden) paint(); });
    // Colours stream into a big file long after it opens: re-highlight only when lines on screen
    // were redrawn (doing more per batch would force a layout each time).
    G.on('lines', (fresh) => {
      if (bar.hidden || mode !== 'find' || !codeSearch.count) return;
      for (const chunk of fresh) {
        const first = Number(chunk.dataset.start) || 0, last = first + chunk.children.length - 1;
        if (first <= painted[1] && last >= painted[0]) { paint(false); return; }
      }
    });
    G.on('mode', () => { if (!bar.hidden) { token++; codeSearch.clear(); clearHighlights(); if (mode === 'find') search(); } });

    // ---------------------------------------------------------------- Keys

    G.addKeys((event) => {
      const k = event.key.toLowerCase();
      const command = event.metaKey && !event.ctrlKey;
      if (command && !event.altKey && k === 'f') { open(undefined, 'find'); return true; }
      if (command && !event.altKey && k === 'g') { if (event.shiftKey) previous(); else next(); return true; }
      if (command && !event.altKey && !event.shiftKey && k === 'l') { open(undefined, 'goto'); return true; }
      if (command && !event.altKey && !event.shiftKey && k === 'e') {
        const selected = String(window.getSelection() || '').split('\n')[0];
        if (selected) { open(selected, 'find'); return true; }
        return false;
      }
      if (command && event.altKey && (event.code === 'KeyC' || event.code === 'KeyW') && !bar.hidden && mode === 'find') {
        if (event.code === 'KeyC') setOption(caseButton, 'caseSensitive'); else setOption(wordButton, 'wholeWord');
        return true;
      }
      if (event.key === 'Escape' && !bar.hidden) { close(); return true; }
      return false;
    });

    G.addTool({ icon: 'search', label: kit.t('Find'), title: kit.t('Find') + ' (⌘F)', order: 20, onClick: () => open(undefined, 'find') });

    G.find = {
      open: (query) => open(query, 'find'), close, next, previous,
      goto: () => open(undefined, 'goto'),
      /** For tests and measurements: searches and resolves when every match is counted. */
      async searchAll(query) { open(query, 'find'); await search(); },
      get count() { return provider().count; },
      repaint: paint,
      engine: codeSearch,
    };
    // Renders and tests: GREECE_STATE=find:word opens the bar on "word" once the page is showing.
    const state = String(kit.payload.state || '');
    if (state.startsWith('find:')) kit.afterReady(() => open(state.slice(5), 'find'));
  });
})();
