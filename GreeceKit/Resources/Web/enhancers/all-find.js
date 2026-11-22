/* Greece — find in documents: Markdown, notebooks, diffs, books, papers and word-processor
   files. The same bar as the code view. Where keys reach the page it opens with ⌘F and steps
   with ⏎ / ⇧⏎ or ⌘G / ⇧⌘G. In Quick Look, which keeps typed keys for Finder, right-click a word
   for Find “word”, and select text while the bar is open to search for it.

   Searches the rendered text (what you read, not the source), across inline styling, and paints
   matches with the CSS Custom Highlight API so the page's markup is never touched. */
(function () {
  'use strict';
  if (!window.greece) return;

  /** Pages that read as documents. The code view has its own find, with Go to Line. */
  const KINDS = new Set(['markdown', 'notebook', 'diff', 'prose', 'epub', 'latex', 'bibtex']);
  const MAX_MATCHES = 20000;
  /** Text that isn't part of the document: controls, overlays, MathML twins of rendered maths. */
  const SKIP = 'script, style, noscript, template, button, input, select, textarea, nav.outline, .findbar, .floating-tools, '
    + '.katex-mathml, [aria-hidden="true"], .lightbox, .mermaid-viewer, .outline-show';
  /** Elements that end a run of text: a match never spans two of them. */
  const BLOCKS = new Set(['P', 'LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'TD', 'TH', 'PRE', 'BLOCKQUOTE', 'DT', 'DD',
    'FIGCAPTION', 'SUMMARY', 'CAPTION', 'TR', 'DIV', 'SECTION', 'ARTICLE', 'HEADER', 'FOOTER', 'TABLE', 'UL', 'OL', 'DL', 'BR', 'HR']);
  const ICONS = {
    search: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="7" cy="7" r="4.6"/><path d="m10.4 10.4 3.4 3.4"/></svg>',
    up: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 10 4-4 4 4"/></svg>',
    down: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 6 4 4 4-4"/></svg>',
  };

  greece.enhance('*', (root, kit) => {
    if (!KINDS.has(kit.payload.kind) || typeof Highlight !== 'function' || !window.CSS || !CSS.highlights) return;
    const html = document.documentElement;

    const bar = document.createElement('div');
    bar.className = 'findbar doc-findbar';
    bar.hidden = true;
    bar.setAttribute('role', 'search');
    bar.innerHTML = `
      <label class="find-field">
        <span class="glyph">${ICONS.search}</span>
        <input type="text" spellcheck="false" autocomplete="off" autocorrect="off" aria-label="Find">
        <span class="find-count" aria-live="polite"></span>
      </label>
      <div class="find-steps" role="group">
        <button type="button" class="find-prev" title="${kit.typing ? 'Previous (⇧⌘G)' : 'Previous'}" aria-label="Previous">${ICONS.up}</button>
        <button type="button" class="find-next" title="${kit.typing ? 'Next (⌘G)' : 'Next'}" aria-label="Next">${ICONS.down}</button>
      </div>
      <button type="button" class="find-option find-case" aria-pressed="false" title="Match Case">Aa</button>
      <button type="button" class="find-option find-word" aria-pressed="false" title="Whole Words"><span>ab</span></button>
      <span class="find-spacer"></span>
      <button type="button" class="find-done">Done</button>`;
    document.body.appendChild(bar);
    const input = bar.querySelector('input');
    const countLabel = bar.querySelector('.find-count');
    const caseButton = bar.querySelector('.find-case');
    const wordButton = bar.querySelector('.find-word');
    input.placeholder = kit.typing ? 'Find' : 'Select text to find it';
    if (!kit.typing) {
      input.readOnly = true;
      input.tabIndex = -1;
      bar.classList.add('by-selection');
    }

    const options = { caseSensitive: false, wholeWord: false };
    const all = new Highlight();
    const current = new Highlight();
    CSS.highlights.set('greece-find', all);
    CSS.highlights.set('greece-find-current', current);
    let matches = [];       // [start, end] offsets into the index's text
    let at = -1;
    let startAt = -1;       // the selected occurrence a search was opened for

    // ---------------------------------------------------------------- The text, indexed

    /** The document's text as one string, with where each text node starts in it. Rebuilt only
        after the page changes (diagrams and maths render late; details open and close). */
    let index = null;
    new MutationObserver(() => { index = null; }).observe(root, { childList: true, subtree: true, characterData: true });

    function build() {
      const nodes = [], starts = [];
      let text = '';
      let lastBlock = null;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          const parent = node.parentElement;
          if (!parent || !node.nodeValue || parent.closest(SKIP)) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        },
      });
      let node;
      while ((node = walker.nextNode())) {
        let block = node.parentElement;
        while (block && block !== root && !BLOCKS.has(block.tagName)) block = block.parentElement;
        if (block !== lastBlock && text) text += '\n';
        lastBlock = block;
        nodes.push(node);
        starts.push(text.length);
        // A line break in running text reads as a space (Markdown keeps soft breaks as "\n");
        // same length, so offsets still point into the node. Code blocks keep their lines.
        text += node.parentElement.closest('pre') ? node.nodeValue : node.nodeValue.replace(/[\n\r\t]/g, ' ');
      }
      return { text, nodes, starts };
    }

    function rangeFor(start, end) {
      const { nodes, starts } = index;
      const locate = (offset, isEnd) => {
        let lo = 0, hi = starts.length - 1;
        while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] < offset + (isEnd ? 0 : 1)) lo = mid; else hi = mid - 1; }
        return [nodes[lo], Math.min(offset - starts[lo], nodes[lo].nodeValue.length)];
      };
      const range = document.createRange();
      try {
        range.setStart(...locate(start, false));
        range.setEnd(...locate(end, true));
      } catch (_) { return null; }
      return range;
    }

    /** Where the selection starts in the index's text, or -1 when it isn't in the document. */
    function selectionOffset() {
      const selection = window.getSelection();
      if (!selection || !selection.rangeCount) return -1;
      const range = selection.getRangeAt(0);
      if (range.startContainer.nodeType !== Node.TEXT_NODE) return -1;
      if (!index) index = build();
      const i = index.nodes.indexOf(range.startContainer);
      return i < 0 ? -1 : index.starts[i] + range.startOffset;
    }

    // ---------------------------------------------------------------- Searching

    function search() {
      const query = input.value;
      all.clear();
      current.clear();
      matches = [];
      at = -1;
      if (query) {
        if (!index) index = build();
        const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const source = options.wholeWord ? `(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])` : escaped;
        let pattern = null;
        try { pattern = new RegExp(source, 'gu' + (options.caseSensitive ? '' : 'i')); } catch (_) { /* nothing matches */ }
        let m;
        while (pattern && (m = pattern.exec(index.text)) && matches.length < MAX_MATCHES) {
          if (!m[0].length) { pattern.lastIndex++; continue; }
          matches.push([m.index, m.index + m[0].length]);
        }
        for (const [start, end] of matches) { const range = rangeFor(start, end); if (range) all.add(range); }
      }
      if (matches.length) {
        const chosen = startAt >= 0 ? matches.findIndex(([start]) => start === startAt) : -1;
        select(chosen >= 0 ? chosen : nearest());
      }
      startAt = -1;
      updateCount();
    }

    /** The first match at or below the top of the window. */
    function nearest() {
      const top = (bar.hidden ? 0 : bar.offsetHeight) + 4;
      for (let k = 0; k < matches.length; k++) {
        const range = rangeFor(matches[k][0], matches[k][1]);
        if (range && range.getBoundingClientRect().bottom >= top) return k;
      }
      return 0;
    }

    function select(k) {
      at = k;
      const range = rangeFor(matches[k][0], matches[k][1]);
      current.clear();
      if (!range) return;
      current.add(range);
      const element = range.startContainer.parentElement;
      // A match inside a closed disclosure (a folded callout, <details>) opens it.
      for (let d = element && element.closest('details:not([open])'); d; d = d.parentElement && d.parentElement.closest('details:not([open])')) d.open = true;
      reveal(range, element);
    }

    /** Scrolls a match into view when it isn't already. */
    function reveal(range, element) {
      const top = bar.hidden ? 0 : bar.offsetHeight;
      let box = range.getBoundingClientRect();
      const hidden = box.top < top + 8 || box.bottom > window.innerHeight - 8 || box.left < 0 || box.right > window.innerWidth;
      if (!hidden) return;
      // Scroll any inner scroller (a wide table, a code block) first, then the window.
      if (element) element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      box = range.getBoundingClientRect();
      if (box.top < top + 8 || box.bottom > window.innerHeight - 8) {
        window.scrollTo(window.scrollX, Math.max(0, window.scrollY + box.top - top - (window.innerHeight - top) / 3));
      }
    }

    function step(delta) {
      if (bar.hidden) { open(); return; }
      if (!matches.length) return;
      select(at < 0 ? nearest() : (at + delta + matches.length) % matches.length);
      updateCount();
    }

    function updateCount() {
      if (!input.value) { countLabel.textContent = ''; bar.classList.remove('invalid'); return; }
      const total = matches.length >= MAX_MATCHES ? MAX_MATCHES.toLocaleString() + '+' : matches.length.toLocaleString();
      countLabel.textContent = !matches.length ? 'No matches' : at >= 0 ? `${(at + 1).toLocaleString()} of ${total}` : total;
      bar.classList.toggle('invalid', !matches.length);
    }

    // ---------------------------------------------------------------- Opening and closing

    let lastQuery = '';

    function open(query) {
      const selected = kit.selectionQuery();
      startAt = selected && (query === selected || (query === undefined && !kit.typing)) ? selectionOffset() : -1;
      if (bar.hidden) {
        bar.hidden = false;
        html.classList.add('findbar-open');
        if (window.scrollY > 0) window.scrollBy(0, bar.offsetHeight);
      }
      if (typeof query === 'string') input.value = query;
      else if (!kit.typing && selected) input.value = selected;
      else if (!input.value && lastQuery) input.value = lastQuery;
      lastQuery = input.value;
      search();
      if (kit.typing) { input.focus(); input.select(); }
    }

    function close() {
      if (bar.hidden) return;
      const height = bar.offsetHeight;
      bar.hidden = true;
      html.classList.remove('findbar-open');
      if (window.scrollY > height) window.scrollBy(0, -height);
      all.clear();
      current.clear();
      matches = [];
      at = -1;
      if (document.activeElement === input) input.blur();
    }

    function toggleOption(button, key) {
      options[key] = !options[key];
      button.classList.toggle('on', options[key]);
      button.setAttribute('aria-pressed', String(options[key]));
      if (!bar.hidden) search();
    }

    input.addEventListener('input', () => { lastQuery = input.value; search(); });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
      else if (event.key === 'Escape') { event.preventDefault(); close(); }
    });
    bar.querySelector('.find-prev').addEventListener('click', () => step(-1));
    bar.querySelector('.find-next').addEventListener('click', () => step(1));
    caseButton.addEventListener('click', () => toggleOption(caseButton, 'caseSensitive'));
    wordButton.addEventListener('click', () => toggleOption(wordButton, 'wholeWord'));
    bar.querySelector('.find-done').addEventListener('click', close);
    bar.addEventListener('mousedown', (event) => { if (event.target !== input || !kit.typing) event.preventDefault(); });

    // Without a keyboard, selecting text (left button) while the bar is open searches for it.
    if (!kit.typing) {
      document.addEventListener('mouseup', (event) => {
        if (event.button !== 0 || bar.hidden || bar.contains(event.target)) return;
        const query = kit.selectionQuery();
        if (query && query !== input.value) open(query);
      });
    }

    window.addEventListener('keydown', (event) => {
      const command = event.metaKey && !event.ctrlKey && !event.altKey;
      const k = event.key.toLowerCase();
      if (command && !event.shiftKey && k === 'f') { event.preventDefault(); open(); }
      else if (command && k === 'g') { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
      else if (command && !event.shiftKey && k === 'e' && kit.selectionQuery()) { event.preventDefault(); open(kit.selectionQuery()); }
      else if (event.key === 'Escape' && !bar.hidden && event.target !== input) { event.preventDefault(); close(); }
    });

    greece.contextMenu(() => {
      const query = kit.selectionQuery();
      return query ? [{ title: 'Find ' + kit.quoted(query), run: () => open(query) }] : null;
    });

    window.greeceFind = { open, close, next: () => step(1), previous: () => step(-1),
                          get count() { return matches.length; }, get current() { return at; } };
  });
})();
