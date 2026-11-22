/* Greece — Code / Tree for JSON (and JSONC, JSON lines, property lists). The tree is an outline
   like Xcode's property list editor: Key, Type and Value columns, type-coloured values, child
   counts, disclosure with the keyboard (arrows, ⌥-click to open everything below), the key path
   of the selection ($.berths[0].vessel.name) to copy, and search through the shared find bar.
   It stays fast on very large files: the text is indexed once (in a worker when big) without
   building objects, only the rows on screen exist, and long arrays open in ranges of 100. */
(function () {
  'use strict';
  if (!window.greece || !window.GreeceCodeAnalysis) return;
  const A = window.GreeceCodeAnalysis;
  const T = A.JSON_TYPES;
  const ROW = 24;
  const BUCKET = 100;
  const DATE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/;
  const DATA = /^<[0-9a-f ]*…?>  \([\d,.\s]+ bytes?\)$/;

  greece.enhance('code', (root, kit) => {
    const G = window.greeceCode;
    if (!G) return;
    const dataElement = document.getElementById('data');
    const plist = !!dataElement && kit.payload.language === 'xml';
    if (kit.payload.language !== 'json' && !plist) return;
    const html = document.documentElement;
    G.mode = 'code';

    let source = null;      // the JSON text the tree reads
    let at = null;          // its index
    let ready = null;       // promise of both
    let displayRoot = 0;
    const children = new Map();
    const expanded = new Set();
    let rows = { node: [], from: [], to: [], depth: [] };
    let selected = -1;      // a row
    let firstShown = -1, lastShown = -1;
    const scroll = { code: [0, 0], tree: [0, 0] };

    // ---------------------------------------------------------------- Elements

    const tree = document.createElement('div');
    tree.className = 'json-tree';
    tree.hidden = true;
    tree.tabIndex = 0;
    tree.setAttribute('role', 'tree');
    tree.innerHTML = `<div class="tree-head"><span>Key</span><span>Type</span><span>Value</span></div>
      <div class="tree-message" hidden></div><div class="tree-body"><div class="tree-rows"></div></div>`;
    root.appendChild(tree);
    const head = tree.querySelector('.tree-head');
    const body = tree.querySelector('.tree-body');
    const rowsBox = tree.querySelector('.tree-rows');
    const message = tree.querySelector('.tree-message');

    const pathBar = document.createElement('div');
    pathBar.className = 'tree-path code-overlay';
    pathBar.hidden = true;
    pathBar.innerHTML = `<span class="path-text"></span><button type="button" class="copy-path">Copy Path</button><button type="button" class="copy-value">Copy Value</button>`;
    document.body.appendChild(pathBar);
    const pathText = pathBar.querySelector('.path-text');

    // The Code / Tree switch, first in the toolbar.
    const tools = root.querySelector('.floating-tools');
    const switcher = document.createElement('div');
    switcher.className = 'pill segmented';
    switcher.dataset.order = '10';
    switcher.setAttribute('role', 'group');
    switcher.innerHTML = '<button type="button" data-mode="code" class="on" title="Code">Code</button><button type="button" data-mode="tree" title="Tree">Tree</button>';
    if (tools) tools.insertBefore(switcher, tools.firstChild);
    switcher.addEventListener('click', (event) => {
      const b = event.target.closest('button');
      if (b) b.dataset.mode === 'tree' ? show() : hide();
    });

    // A big file's code view only holds its beginning: offer the whole thing as a tree.
    const notice = root.querySelector('.notice');
    if (notice && kit.payload.truncated && !plist) {
      const offer = document.createElement('button');
      offer.type = 'button';
      offer.className = 'notice-action';
      offer.textContent = 'Show the Whole File as a Tree';
      offer.addEventListener('click', () => show());
      notice.appendChild(offer);
    }

    // ---------------------------------------------------------------- Loading

    function load() {
      if (ready) return ready;
      ready = (async () => {
        if (plist) source = dataElement.textContent;
        else if (kit.payload.truncated) {
          setMessage('Reading the whole file…');
          try { source = await (await fetch('greece://module/source')).text(); } catch (_) { source = G.text; }
        } else source = G.text;
        if (source.length > 2000000) {
          setMessage('Indexing ' + (source.length / 1048576).toFixed(0) + ' MB…');
          at = await indexInWorker(source);
        } else at = A.indexJSON(source);
        const top = A.childrenOf(0, at);
        displayRoot = top.length === 1 ? top[0] : 0;
        expanded.add(displayRoot);
        if (at.error && at.count <= 1) setMessage('This isn’t valid JSON: ' + at.error.message + ' on line ' + lineOf(at.error.offset) + '.');
        else if (at.error) setMessage('Showing what could be read. ' + at.error.message + ' on line ' + lineOf(at.error.offset) + '.', true);
        else if (at.truncated) setMessage('Showing the first ' + at.count.toLocaleString() + ' values.', true);
        else setMessage('');
        rebuild();
      })();
      return ready;
    }

    function indexInWorker(text) {
      return new Promise((resolve) => {
        try {
          const code = 'const A = ' + A.source + ';\nonmessage = (e) => { const r = A.indexJSON(e.data); postMessage(r, [r.type.buffer, r.start.buffer, r.end.buffer, r.key.buffer, r.next.buffer, r.parent.buffer]); };';
          const worker = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
          worker.onmessage = (e) => { worker.terminate(); resolve(e.data); };
          worker.onerror = () => { worker.terminate(); resolve(A.indexJSON(text)); };
          worker.postMessage(text);
        } catch (_) { resolve(A.indexJSON(text)); }
      });
    }

    function lineOf(offset) {
      let line = 1;
      for (let i = source.indexOf('\n'); i !== -1 && i < offset; i = source.indexOf('\n', i + 1)) line++;
      return line.toLocaleString();
    }

    function setMessage(text, quiet) {
      message.hidden = !text;
      message.textContent = text;
      message.classList.toggle('quiet', !!quiet);
    }

    // ---------------------------------------------------------------- Model

    const isContainer = (n) => at.type[n] === T.object || at.type[n] === T.array;
    function kids(n) {
      let list = children.get(n);
      if (!list) { list = Int32Array.from(A.childrenOf(n, at)); children.set(n, list); }
      return list;
    }
    function bucketSize(count) { let size = BUCKET; while (count / size > BUCKET) size *= BUCKET; return size; }
    const bucketKey = (n, from, to) => 'b' + n + ':' + from + ':' + to;

    /** Rows for children `from…to` of `n`: the children themselves, or ranges of them. */
    function addChildren(n, from, to, depth) {
      const count = to - from;
      if (count > BUCKET) {
        const size = bucketSize(count);
        for (let s = from; s < to; s += size) {
          const e = Math.min(to, s + size);
          push(n, s, e, depth);
          if (expanded.has(bucketKey(n, s, e))) addChildren(n, s, e, depth + 1);
        }
        return;
      }
      const list = kids(n);
      for (let k = from; k < to; k++) addNode(list[k], depth);
    }
    function addNode(n, depth) {
      push(n, -1, -1, depth);
      if (isContainer(n) && expanded.has(n)) addChildren(n, 0, kids(n).length, depth + 1);
    }
    function push(n, from, to, depth) { rows.node.push(n); rows.from.push(from); rows.to.push(to); rows.depth.push(depth); }

    /** Row of node `n` (or of its range starting at `from`), or -1. */
    function rowOf(n, from = -1) {
      for (let r = 0; r < rows.node.length; r++) if (rows.node[r] === n && rows.from[r] === from) return r;
      return -1;
    }

    /** Lays the outline out again after it opens or closes, keeping the selected row. */
    function rebuild() {
      const keep = selected >= 0 ? [rows.node[selected], rows.from[selected]] : null;
      rows = { node: [], from: [], to: [], depth: [] };
      if (displayRoot === 0) addChildren(0, 0, kids(0).length, 0);
      else addNode(displayRoot, 0);
      selected = keep ? rowOf(keep[0], keep[1]) : -1;
      body.style.height = rows.node.length * ROW + 'px';
      firstShown = lastShown = -1;
      paint(true);
      updatePath();
    }

    function toggle(r, open, deep) {
      const n = rows.node[r];
      const key = rows.from[r] >= 0 ? bucketKey(n, rows.from[r], rows.to[r]) : n;
      if (rows.from[r] < 0 && !isContainer(n)) return;
      const target = open === undefined ? !expanded.has(key) : open;
      if (target) expanded.add(key); else expanded.delete(key);
      if (deep && rows.from[r] < 0) {
        let budget = 5000;
        const stack = [n];
        while (stack.length && budget > 0) {
          const c = stack.pop();
          if (!isContainer(c)) continue;
          if (target) expanded.add(c); else expanded.delete(c);
          budget--;
          const list = kids(c);
          if (list.length > BUCKET) continue;
          for (let k = 0; k < list.length; k++) stack.push(list[k]);
        }
      }
      const from = rows.from[r];
      const hadSelection = selected >= 0;
      rebuild();
      // A selection folded away moves to the row that closed over it.
      if (hadSelection && selected < 0) select(rowOf(n, from), false);
    }

    /** Opens every ancestor (and range) of node `n` and returns its row. */
    function reveal(n) {
      const chain = [];
      for (let p = at.parent[n], c = n; p >= 0; c = p, p = at.parent[p]) chain.push([p, c]);
      for (const [p, c] of chain.reverse()) {
        if (p !== 0 || displayRoot === 0) {
          if (p !== 0) expanded.add(p);
          const list = kids(p);
          if (list.length > BUCKET) {
            let lo = 0, hi = list.length - 1;
            while (lo < hi) { const mid = (lo + hi) >> 1; if (list[mid] < c) lo = mid + 1; else hi = mid; }
            let from = 0, to = list.length;
            while (to - from > BUCKET) {
              const size = bucketSize(to - from);
              const s = from + Math.floor((lo - from) / size) * size;
              const e = Math.min(to, s + size);
              expanded.add(bucketKey(p, s, e));
              from = s; to = e;
            }
          }
        }
      }
      rebuild();
      return rowOf(n);
    }

    // ---------------------------------------------------------------- Rows

    function typeName(n) {
      switch (at.type[n]) {
        case T.object: return plist ? 'Dictionary' : 'Object';
        case T.array: return 'Array';
        case T.string: {
          if (plist) { const v = text(n); if (DATE.test(v)) return 'Date'; if (DATA.test(v)) return 'Data'; }
          return 'String';
        }
        case T.number: return 'Number';
        case T.true: case T.false: return 'Boolean';
        case T.null: return 'Null';
        default: return '—';
      }
    }
    function text(n) {
      const s = at.start[n], e = at.end[n];
      if (e - s > 4000) return source.slice(s + 1, s + 400) + '…';
      return at.type[n] === T.string ? A.stringValue(source, s, e) : source.slice(s, e);
    }
    function keyOf(n) {
      const p = at.parent[n];
      if (n === displayRoot) return { label: plist ? 'Root' : '$', index: false };
      if (p >= 0 && at.type[p] === T.object) return { label: A.keyText(source, at, n), index: false };
      const list = kids(p);
      let lo = 0, hi = list.length - 1;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (list[mid] < n) lo = mid + 1; else hi = mid; }
      return { label: (plist ? 'Item ' : '') + lo, index: true };
    }
    const plural = (n, one, many) => n.toLocaleString() + ' ' + (n === 1 ? one : many);

    let marker = null;   // the find query, as a pattern, while searching
    function marked(value) {
      const safe = kit.esc(value);
      if (!marker) return safe;
      marker.lastIndex = 0;
      let out = '', last = 0, m;
      while ((m = marker.exec(value)) && out.length < 20000) {
        if (!m[0].length) { marker.lastIndex++; continue; }
        out += kit.esc(value.slice(last, m.index)) + '<mark>' + kit.esc(m[0]) + '</mark>';
        last = m.index + m[0].length;
      }
      return last ? out + kit.esc(value.slice(last)) : safe;
    }

    function rowHTML(r) {
      const n = rows.node[r], depth = rows.depth[r];
      const classes = ['row'];
      if (r === selected) classes.push('sel');
      if (search.currentNode === n && rows.from[r] < 0) classes.push('current');
      if (rows.from[r] >= 0) {
        const open = expanded.has(bucketKey(n, rows.from[r], rows.to[r]));
        return `<div class="${classes.join(' ')} bucket" data-r="${r}" style="--depth:${depth}" role="treeitem" aria-expanded="${open}">`
          + `<span class="cell key"><i class="disclosure${open ? ' open' : ''}"></i><span class="k index">[${rows.from[r].toLocaleString()} … ${(rows.to[r] - 1).toLocaleString()}]</span></span><span class="cell type"></span><span class="cell value"></span></div>`;
      }
      const container = isContainer(n);
      const open = container && expanded.has(n);
      const key = keyOf(n);
      let value, tone;
      if (container) {
        const count = kids(n).length;
        value = at.type[n] === T.object ? plural(count, plist ? 'item' : 'key', plist ? 'items' : 'keys') : plural(count, 'item', 'items');
        tone = 'count';
      } else {
        const t = at.type[n];
        value = marked(text(n));
        tone = t === T.string ? 'string' : t === T.number ? 'number' : t === T.other ? 'other' : 'literal';
      }
      return `<div class="${classes.join(' ')}" data-r="${r}" style="--depth:${depth}" role="treeitem"${container ? ` aria-expanded="${open}"` : ''}>`
        + `<span class="cell key">${container ? `<i class="disclosure${open ? ' open' : ''}"></i>` : '<i class="leaf"></i>'}`
        + `<span class="k${key.index ? ' index' : ''}">${marked(String(key.label))}</span></span>`
        + `<span class="cell type">${typeName(n)}</span><span class="cell value ${tone}">${container ? kit.esc(value) : value}</span></div>`;
    }

    function paint(force) {
      if (tree.hidden || !at) return;
      const top = body.getBoundingClientRect().top;
      const first = Math.max(0, Math.floor((G.inset + head.offsetHeight - top) / ROW) - 12);
      const last = Math.min(rows.node.length - 1, first + Math.ceil(window.innerHeight / ROW) + 24);
      if (!force && first === firstShown && last === lastShown) return;
      firstShown = first; lastShown = last;
      let out = '';
      for (let r = first; r <= last; r++) out += rowHTML(r);
      rowsBox.style.transform = `translateY(${first * ROW}px)`;
      rowsBox.innerHTML = out;
    }

    function select(r, scrollIntoView = true) {
      if (r < 0 || r >= rows.node.length) return;
      selected = r;
      if (scrollIntoView) {
        const top = body.getBoundingClientRect().top + window.scrollY + r * ROW;
        const visibleTop = window.scrollY + G.inset + head.offsetHeight;
        const visibleBottom = window.scrollY + window.innerHeight - pathBar.offsetHeight;
        if (top < visibleTop) window.scrollTo(0, top - G.inset - head.offsetHeight - ROW);
        else if (top + ROW > visibleBottom) window.scrollTo(0, top + 2 * ROW - window.innerHeight + pathBar.offsetHeight);
      }
      paint(true);
      updatePath();
    }

    function updatePath() {
      if (selected < 0 || rows.from[selected] >= 0) {
        pathText.textContent = selected < 0 ? 'Select a row to see its path' : '';
        pathBar.classList.toggle('empty', true);
        return;
      }
      pathBar.classList.remove('empty');
      pathText.textContent = pathOf(rows.node[selected]);
    }
    const pathOf = (n) => A.pathOf(source, at, n);

    // ---------------------------------------------------------------- Showing

    async function show() {
      if (G.mode === 'tree') return;
      scroll.code = [window.scrollX, window.scrollY];
      G.mode = 'tree';
      html.classList.add('tree-mode');
      switcher.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.mode === 'tree'));
      G.view.hidden = true;
      if (notice) notice.hidden = true;
      tree.hidden = false;
      pathBar.hidden = false;
      window.scrollTo(0, 0);
      G.emit('mode', 'tree');
      await load();
      window.scrollTo(scroll.tree[0], scroll.tree[1]);
      paint(true);
      if (G.mode === 'tree' && !G.typing()) tree.focus({ preventScroll: true });
    }

    async function hide() {
      if (G.mode !== 'tree') return;
      scroll.tree = [window.scrollX, window.scrollY];
      G.mode = 'code';
      html.classList.remove('tree-mode');
      switcher.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.mode === 'code'));
      tree.hidden = true;
      pathBar.hidden = true;
      G.view.hidden = false;
      if (notice) notice.hidden = false;
      window.scrollTo(scroll.code[0], scroll.code[1]);
      G.emit('mode', 'code');
    }

    // ---------------------------------------------------------------- Interaction

    rowsBox.addEventListener('mousedown', (event) => {
      const row = event.target.closest('.row');
      if (!row) return;
      const r = Number(row.dataset.r);
      if (event.target.closest('.disclosure')) { event.preventDefault(); toggle(r, undefined, event.altKey); return; }
      select(r, false);
    });
    rowsBox.addEventListener('dblclick', (event) => {
      const row = event.target.closest('.row');
      if (row) toggle(Number(row.dataset.r));
    });

    function copy(what) {
      if (selected < 0 || rows.from[selected] >= 0) return;
      const n = rows.node[selected];
      const value = what === 'path' ? pathOf(n) : source.slice(at.start[n], at.end[n]);
      kit.copyText(value, pathBar.querySelector(what === 'path' ? '.copy-path' : '.copy-value'));
    }
    pathBar.querySelector('.copy-path').addEventListener('click', () => copy('path'));
    pathBar.querySelector('.copy-value').addEventListener('click', () => copy('value'));
    pathBar.addEventListener('mousedown', (event) => event.preventDefault());

    document.addEventListener('copy', (event) => {
      if (G.mode !== 'tree' || selected < 0) return;
      const sel = window.getSelection();
      if (sel && !sel.isCollapsed) return;
      const n = rows.node[selected];
      if (rows.from[selected] >= 0 || !event.clipboardData) return;
      event.clipboardData.setData('text/plain', source.slice(at.start[n], at.end[n]));
      event.preventDefault();
    });

    G.addKeys((event) => {
      if (G.mode !== 'tree' || !at || G.typing()) return false;
      if (event.metaKey && event.altKey && event.code === 'KeyC') { copy('path'); return true; }
      if (event.metaKey || event.ctrlKey) return false;
      const r = selected;
      switch (event.key) {
        case 'ArrowDown': select(Math.min(rows.node.length - 1, r + 1)); return true;
        case 'ArrowUp': select(Math.max(0, r < 0 ? 0 : r - 1)); return true;
        case 'Home': select(0); return true;
        case 'End': select(rows.node.length - 1); return true;
        case 'ArrowRight': {
          if (r < 0) { select(0); return true; }
          const n = rows.node[r];
          const bucket = rows.from[r] >= 0;
          const open = bucket ? expanded.has(bucketKey(n, rows.from[r], rows.to[r])) : expanded.has(n);
          if ((bucket || isContainer(n)) && !open) toggle(r, true, event.altKey);
          else if (bucket || isContainer(n)) select(r + 1);
          return true;
        }
        case 'ArrowLeft': {
          if (r < 0) return true;
          const n = rows.node[r];
          const bucket = rows.from[r] >= 0;
          const open = bucket ? expanded.has(bucketKey(n, rows.from[r], rows.to[r])) : isContainer(n) && expanded.has(n);
          if (open) { toggle(r, false, event.altKey); return true; }
          for (let k = r - 1; k >= 0; k--) if (rows.depth[k] < rows.depth[r]) { select(k); break; }
          return true;
        }
        case 'Enter': case ' ': if (r >= 0) toggle(r); return true;
        default: return false;
      }
    });

    window.addEventListener('scroll', () => { if (G.mode === 'tree') paint(false); }, { passive: true });
    // Rows are rebuilt when the width changes, so truncated values are measured afresh.
    let lastWidth = 0;
    new ResizeObserver(() => {
      const width = tree.clientWidth;
      if (width !== lastWidth && G.mode === 'tree') { lastWidth = width; paint(true); }
    }).observe(tree);

    // ---------------------------------------------------------------- Search

    let token = 0;
    const search = {
      offsets: new Int32Array(256),
      count: 0,
      current: -1,
      currentNode: -1,
      done: true,
      async run(query, opts, progress) {
        await load();
        const mine = ++token;
        this.count = 0; this.current = -1; this.currentNode = -1; this.done = false;
        marker = null;
        if (!query) { this.done = true; paint(true); return; }
        const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const pattern = opts.wholeWord ? `(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])` : escaped;
        const flags = 'gu' + (opts.caseSensitive ? '' : 'i');
        marker = new RegExp(pattern, flags);
        const finder = new RegExp(pattern, flags);
        let slice = performance.now(), m;
        while ((m = finder.exec(source))) {
          if (!m[0].length) { finder.lastIndex++; continue; }
          if (this.count === this.offsets.length) { const b = new Int32Array(this.offsets.length * 2); b.set(this.offsets); this.offsets = b; }
          this.offsets[this.count++] = m.index;
          if (this.count >= 500000) break;
          if ((this.count & 255) === 0 && performance.now() - slice > 12) {
            progress();
            await kit.tick();
            if (mine !== token) return;
            slice = performance.now();
          }
        }
        if (mine !== token) return;
        this.done = true;
        paint(true);
      },
      clear() { this.count = 0; this.current = -1; this.currentNode = -1; marker = null; paint(true); },
      nearest() { return 0; },
      /** The value or key holding text offset `offset`. */
      nodeFor(offset) {
        const rowStart = (n) => (at.key[n] >= 0 ? at.key[n] : at.start[n]);
        let lo = 1, hi = at.count - 1;
        while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (rowStart(mid) <= offset) lo = mid; else hi = mid - 1; }
        return lo;
      },
      async select(index) {
        this.current = index;
        const n = this.nodeFor(this.offsets[index]);
        this.currentNode = n;
        const r = reveal(n);
        if (r >= 0) {
          selected = r;
          const top = body.getBoundingClientRect().top + window.scrollY + r * ROW;
          window.scrollTo(0, Math.max(0, top - (window.innerHeight - G.inset) / 2));
        }
        paint(true);
        updatePath();
      },
    };

    G.tree = {
      show, hide, search,
      async expandPath(spec) {
        await load();
        let n = displayRoot;
        for (const part of spec.split('.')) {
          if (!part) continue;
          expanded.add(n);
          const list = kids(n);
          const found = Array.from(list).find((c, i) => (at.type[n] === T.object ? A.keyText(source, at, c) === part : String(i) === part));
          if (found === undefined) break;
          n = found;
        }
        if (isContainer(n)) expanded.add(n);
        select(reveal(n));
      },
      selectRow(r) { select(r); },
    };
  });
})();
