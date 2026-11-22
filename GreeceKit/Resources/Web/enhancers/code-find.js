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
    bar.className = 'code-findbar code-overlay';
    bar.hidden = true;
    bar.setAttribute('role', 'search');
    bar.innerHTML = `
      <span class="bar-title">Go to Line</span>
      <label class="find-field">
        <span class="glyph">${icons.search}</span>
        <input type="text" spellcheck="false" autocomplete="off" autocorrect="off" aria-label="Find">
        <span class="find-count" aria-live="polite"></span>
      </label>
      <div class="find-steps" role="group">
        <button type="button" class="find-prev" title="Previous (⇧⌘G)" aria-label="Previous">${icons.up}</button>
        <button type="button" class="find-next" title="Next (⌘G)" aria-label="Next">${icons.down}</button>
      </div>
      <button type="button" class="find-option find-case" aria-pressed="false" title="Match Case (⌥⌘C)">Aa</button>
      <button type="button" class="find-option find-word" aria-pressed="false" title="Whole Words (⌥⌘W)"><span>ab</span></button>
      <span class="find-spacer"></span>
      <button type="button" class="find-done">Done</button>`;
    document.body.appendChild(bar);
    const input = bar.querySelector('input');
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

    function open(query, as = 'find') {
      mode = as;
      bar.classList.toggle('goto', as === 'goto');
      if (bar.hidden) {
        bar.hidden = false;
        document.documentElement.classList.add('bar-open');
        // The bar pushes the page down, as Safari's does, without moving what you're reading.
        const height = bar.offsetHeight;
        root.style.paddingTop = height + 'px';
        if (window.scrollY > 0) window.scrollBy(0, height);
        G.setInset(height);
      }
      if (as === 'goto') {
        input.value = '';
        input.placeholder = 'Line';
        input.setAttribute('aria-label', 'Go to line');
        countLabel.textContent = '1–' + G.count.toLocaleString();
        clearHighlights();
        marks.hidden = true;
      } else {
        input.placeholder = 'Find';
        input.setAttribute('aria-label', 'Find');
        if (typeof query === 'string') input.value = query;
        else if (!input.value && lastQuery) input.value = lastQuery;
        search();
      }
      input.focus();
      input.select();
    }

    function close() {
      if (bar.hidden) return;
      const height = G.inset;
      bar.hidden = true;
      document.documentElement.classList.remove('bar-open');
      root.style.paddingTop = '';
      if (window.scrollY > height) window.scrollBy(0, -height);
      G.setInset(0);
      token++;
      provider().clear();
      clearHighlights();
      marks.hidden = true;
      if (document.activeElement === input) input.blur();
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
    bar.addEventListener('mousedown', (event) => { if (event.target !== input) event.preventDefault(); });

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
          if ((this.count & 255) === 0 && performance.now() - sliceStart > 12) {
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

      /** Where each match sits along the document, 0…1, for the scroller marks. */
      positions() {
        const chunks = Array.from(G.view.children).map((c) => ({ start: Number(c.dataset.start) || 0, top: c.offsetTop, height: c.offsetHeight, lines: c.children.length || 1 }));
        const viewTop = G.view.offsetTop;
        const total = document.documentElement.scrollHeight || 1;
        const result = [];
        let c = 0;
        for (let k = 0; k < this.count; k++) {
          const line = this.lineOf(this.offsets[k]);
          while (c + 1 < chunks.length && chunks[c + 1].start <= line) c++;
          const chunk = chunks[c];
          if (!chunk) break;
          const y = viewTop + chunk.top + ((line - chunk.start) / chunk.lines) * chunk.height;
          result.push(y / total);
        }
        return result;
      },
    };

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
      const run = p.run(query, options, () => { updateCount(p, true); paint(); });
      await run;
      if (p.count && p.current < 0 && query === input.value) await p.select(p.nearest());
      updateCount(p, false);
      paint();
    }

    function updateCount(p, running) {
      if (mode !== 'find') return;
      if (!input.value) { countLabel.textContent = ''; bar.classList.remove('invalid'); return; }
      const total = p.count >= MAX_MATCHES ? MAX_MATCHES.toLocaleString() + '+' : p.count.toLocaleString();
      if (running) countLabel.textContent = total + '…';
      else if (!p.count) countLabel.textContent = 'No matches';
      else if (p.current >= 0) countLabel.textContent = `${(p.current + 1).toLocaleString()} of ${total}`;
      else countLabel.textContent = total + (p.count === 1 ? ' match' : ' matches');
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

    function clearHighlights() {
      if (!supportsHighlights) return;
      CSS.highlights.delete('greece-find');
      CSS.highlights.delete('greece-find-current');
    }

    function paint() {
      if (bar.hidden || mode !== 'find') return;
      const p = provider();
      if (p === codeSearch && supportsHighlights) {
        const { all, current } = codeSearch.visibleRanges();
        CSS.highlights.set('greece-find', new Highlight(...all));
        if (current) CSS.highlights.set('greece-find-current', new Highlight(current));
        else CSS.highlights.delete('greece-find-current');
      }
      if (p.paint) p.paint();
      drawMarks(p);
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
      paint();
    }, { passive: true });
    window.addEventListener('resize', () => { if (!bar.hidden) paint(); }, { passive: true });
    for (const name of ['lines', 'fold', 'wrap']) G.on(name, () => { if (!bar.hidden) paint(); });
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

    G.addTool({ icon: 'search', label: 'Find', title: 'Find (⌘F)', order: 20, onClick: () => open(undefined, 'find') });

    G.find = {
      open: (query) => open(query, 'find'), close, next, previous,
      goto: () => open(undefined, 'goto'),
      /** For tests and measurements: searches and resolves when every match is counted. */
      async searchAll(query) { open(query, 'find'); await search(); },
      get count() { return provider().count; },
      repaint: paint,
    };
  });
})();
