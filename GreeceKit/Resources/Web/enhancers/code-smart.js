/* Greece — smart files: code pages that explain themselves.
   A calm card above the highlighted code says what the file is (a package's scripts and
   dependencies, a Compose stack's services, a workflow's jobs…); some kinds go further (.env
   values masked until revealed, logs coloured and filterable). The code always stays.

   This file is the foundation: detection, shared parsers (a TOML subset, YAML via the bundled
   js-yaml, loaded only when needed), the card UI and the enhancer that dispatches to each kind.
   Kinds live in code-smart-*.js and register with `GreeceSmart.register(kind)`. Parsers never
   touch the DOM, so tests run them in JavaScriptCore. Every input is hostile: sizes, depths and
   counts are capped, and everything shown is escaped. */
(function (global) {
  'use strict';

  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  const kinds = Smart.kinds = Smart.kinds || [];

  /** A kind: { id, order, detect(file) → bool, enhance(context) → Promise|void, yaml? }. */
  Smart.register = (kind) => { kinds.push(kind); };

  // ------------------------------------------------------------------------- Helpers

  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = Smart.esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ESC[c]);
  const isObject = Smart.isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
  /** Own string-keyed entries of an object, capped. Safe on anything. */
  Smart.entries = (v, limit = 2000) => (isObject(v) ? Object.keys(v).slice(0, limit).map((k) => [k, v[k]]) : []);
  /** A short, single-line, printable version of any value. */
  Smart.text = (v, max = 200) => {
    let s;
    if (v == null) s = '';
    else if (typeof v === 'string') s = v;
    else if (typeof v === 'number' || typeof v === 'boolean') s = String(v);
    else if (Array.isArray(v)) s = v.slice(0, 20).map((x) => Smart.text(x, 60)).join(', ');
    else if (v instanceof Date) s = isNaN(v) ? '' : v.toISOString().slice(0, 10);
    else s = '';
    s = s.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim();
    return s.length > max ? s.slice(0, max - 1) + '…' : s;
  };
  Smart.plural = (n, one, many) => `${Number(n).toLocaleString('en-US')} ${n === 1 ? one : (many || one + 's')}`;
  Smart.number = (n) => Number(n).toLocaleString('en-US');

  function baseName(name) { return String(name || '').split('/').pop(); }

  /** What detectors look at: the name, extension, language and the first 16 KB. */
  Smart.file = (fileName, text, language) => {
    const name = baseName(fileName);
    const lower = name.toLowerCase();
    const dot = lower.lastIndexOf('.');
    return {
      name, lower,
      ext: dot > 0 ? lower.slice(dot + 1) : '',
      language: String(language || '').toLowerCase(),
      text: String(text || ''),
      head: String(text || '').slice(0, 16384),
    };
  };
  Smart.isYAML = (file) => file.language === 'yaml' || /\.(ya?ml)$/.test(file.lower);
  Smart.isJSON = (file) => file.language === 'json' || /\.json$/.test(file.lower);

  /** The kind that explains this file, or null. */
  Smart.detect = (file) => {
    const sorted = kinds.slice().sort((a, b) => (a.order || 50) - (b.order || 50));
    for (const kind of sorted) {
      try { if (kind.detect(file)) return kind; } catch (_) { }
    }
    return null;
  };
  Smart.kind = (id) => kinds.find((k) => k.id === id) || null;

  // ---------------------------------------------------------------------------- YAML

  let yamlLoading = null;
  /** Loads the bundled js-yaml on first use (only YAML pages that look smart pay for it). */
  Smart.loadYAML = () => {
    if (global.jsyaml) return Promise.resolve(global.jsyaml);
    if (!global.document) return Promise.reject(new Error('no YAML parser'));
    if (!yamlLoading) {
      yamlLoading = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = 'greece://asset/vendor/js-yaml/js-yaml.min.js';
        script.onload = () => (global.jsyaml ? resolve(global.jsyaml) : reject(new Error('js-yaml missing')));
        script.onerror = () => reject(new Error('js-yaml failed to load'));
        document.head.appendChild(script);
      });
    }
    return yamlLoading;
  };

  /** Every document in a YAML stream that parses; broken documents are skipped, not fatal. */
  Smart.yamlDocuments = (text, maxDocuments = 200) => {
    const yaml = global.jsyaml;
    if (!yaml || text.length > 3 * 1024 * 1024) return [];
    try {
      const all = [];
      yaml.loadAll(text, (doc) => { if (all.length < maxDocuments) all.push(doc); }, { json: true });
      return all;
    } catch (_) {
      // One bad document (a Helm template, say) shouldn't hide the others.
      const docs = [];
      for (const part of text.split(/^---[ \t]*(?:#.*)?$/m).slice(0, maxDocuments)) {
        try { docs.push(yaml.load(part, { json: true })); } catch (_) { }
      }
      return docs;
    }
  };
  Smart.yaml = (text) => {
    const docs = Smart.yamlDocuments(text, 1);
    return docs.length ? docs[0] : null;
  };

  // ---------------------------------------------------------------------------- TOML

  /** A forgiving TOML 1.0 reader: tables, arrays of tables, dotted keys, strings of every
      kind, numbers, booleans, dates (kept as text), arrays and inline tables. Errors skip a line. */
  Smart.toml = (src, maxLength = 2 * 1024 * 1024) => {
    const text = String(src).slice(0, maxLength);
    const root = Object.create(null);
    const errors = [];
    let i = 0;
    let table = root;
    const n = text.length;

    const fail = (message) => { throw new Error(message); };
    const ws = () => { while (i < n && (text[i] === ' ' || text[i] === '\t')) i++; };
    const comment = () => { if (text[i] === '#') while (i < n && text[i] !== '\n') i++; };
    const blank = () => { for (;;) { ws(); comment(); if (text[i] === '\n' || text[i] === '\r') i++; else break; } };
    const nextLine = () => { while (i < n && text[i] !== '\n') i++; };

    function basicString(multi) {
      let out = '';
      if (multi && text[i] === '\r') i++;
      if (multi && text[i] === '\n') i++;
      for (;;) {
        if (i >= n) fail('unterminated string');
        const c = text[i];
        if (!multi && c === '\n') fail('newline in string');
        if (multi ? text.startsWith('"""', i) : c === '"') {
          if (multi) {
            let q = 0;
            while (text[i + q] === '"' && q < 5) q++;
            out += '"'.repeat(q - 3);
            i += q;
          } else i++;
          return out;
        }
        if (c === '\\') {
          const e = text[i + 1];
          const map = { b: '\b', t: '\t', n: '\n', f: '\f', r: '\r', '"': '"', '\\': '\\', e: '\u001b' };
          if (map[e] !== undefined) { out += map[e]; i += 2; continue; }
          if (e === 'u' || e === 'U') {
            const len = e === 'u' ? 4 : 8;
            const hex = text.slice(i + 2, i + 2 + len);
            const code = parseInt(hex, 16);
            out += /^[0-9a-fA-F]+$/.test(hex) && code <= 0x10FFFF ? String.fromCodePoint(code) : '';
            i += 2 + len;
            continue;
          }
          if (multi && /[ \t\r\n]/.test(e)) { i++; while (i < n && /[ \t\r\n]/.test(text[i])) i++; continue; }
          out += e || '';
          i += 2;
          continue;
        }
        out += c;
        i++;
      }
    }

    function literalString(multi) {
      const close = multi ? "'''" : "'";
      if (multi && text[i] === '\r') i++;
      if (multi && text[i] === '\n') i++;
      const end = text.indexOf(close, i);
      if (end < 0) fail('unterminated string');
      let stop = end;
      if (multi) while (text[stop + 3] === "'" && stop - end < 2) stop++;
      const value = text.slice(i, stop);
      if (!multi && value.includes('\n')) fail('newline in string');
      i = stop + close.length;
      return value;
    }

    function key() {
      const parts = [];
      for (;;) {
        ws();
        if (text[i] === '"') { i++; parts.push(basicString(false)); }
        else if (text[i] === "'") { i++; parts.push(literalString(false)); }
        else {
          const m = /^[A-Za-z0-9_-]+/.exec(text.slice(i, i + 256));
          if (!m) fail('bad key');
          parts.push(m[0]);
          i += m[0].length;
        }
        ws();
        if (text[i] === '.') { i++; continue; }
        if (parts.length > 64) fail('key too deep');
        return parts;
      }
    }

    function value(depth) {
      if (depth > 64) fail('too deep');
      const c = text[i];
      if (text.startsWith('"""', i)) { i += 3; return basicString(true); }
      if (c === '"') { i++; return basicString(false); }
      if (text.startsWith("'''", i)) { i += 3; return literalString(true); }
      if (c === "'") { i++; return literalString(false); }
      if (c === '[') {
        i++;
        const list = [];
        for (;;) {
          blank();
          if (text[i] === ']') { i++; return list; }
          if (list.length > 100000) fail('array too long');
          list.push(value(depth + 1));
          blank();
          if (text[i] === ',') { i++; continue; }
          if (text[i] === ']') { i++; return list; }
          fail('bad array');
        }
      }
      if (c === '{') {
        i++;
        const object = Object.create(null);
        blank();
        if (text[i] === '}') { i++; return object; }
        for (;;) {
          blank();
          const path = key();
          if (text[i] !== '=') fail('expected =');
          i++;
          ws();
          assign(object, path, value(depth + 1));
          blank();
          if (text[i] === ',') { i++; blank(); if (text[i] === '}') { i++; return object; } continue; }
          if (text[i] === '}') { i++; return object; }
          fail('bad inline table');
        }
      }
      const m = /^[^\s,\]}#]+(?: \d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?)?/.exec(text.slice(i, i + 128));
      if (!m) fail('bad value');
      i += m[0].length;
      const raw = m[0];
      if (raw === 'true') return true;
      if (raw === 'false') return false;
      if (/^[+-]?(inf|nan)$/.test(raw)) return raw.includes('nan') ? NaN : (raw[0] === '-' ? -Infinity : Infinity);
      if (/^[+-]?(0|[1-9](_?\d)*)$/.test(raw)) return Number(raw.replace(/_/g, ''));
      if (/^0x[0-9a-fA-F_]+$/.test(raw)) return parseInt(raw.slice(2).replace(/_/g, ''), 16);
      if (/^0o[0-7_]+$/.test(raw)) return parseInt(raw.slice(2).replace(/_/g, ''), 8);
      if (/^0b[01_]+$/.test(raw)) return parseInt(raw.slice(2).replace(/_/g, ''), 2);
      if (/^[+-]?\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d[\d_]*)?$/.test(raw)) return Number(raw.replace(/_/g, ''));
      if (/^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}/.test(raw)) return raw;
      fail('bad value');
    }

    function child(object, name) {
      if (name === '__proto__' || name === 'constructor' || name === 'prototype') fail('reserved key');
      if (!isObject(object[name]) && !Array.isArray(object[name])) object[name] = Object.create(null);
      const next = object[name];
      return Array.isArray(next) ? (isObject(next[next.length - 1]) ? next[next.length - 1] : fail('not a table')) : next;
    }
    function assign(object, path, v) {
      let target = object;
      for (let k = 0; k < path.length - 1; k++) target = child(target, path[k]);
      const last = path[path.length - 1];
      if (last === '__proto__' || last === 'constructor' || last === 'prototype') fail('reserved key');
      target[last] = v;
    }

    while (i < n) {
      blank();
      if (i >= n) break;
      const lineStart = i;
      try {
        if (text[i] === '[') {
          const array = text[i + 1] === '[';
          i += array ? 2 : 1;
          const path = key();
          if (array ? !text.startsWith(']]', i) : text[i] !== ']') fail('bad table header');
          i += array ? 2 : 1;
          if (array) {
            let parent = root;
            for (let k = 0; k < path.length - 1; k++) parent = child(parent, path[k]);
            const last = path[path.length - 1];
            if (last === '__proto__' || last === 'constructor' || last === 'prototype') fail('reserved key');
            if (!Array.isArray(parent[last])) parent[last] = [];
            if (parent[last].length > 100000) fail('too many tables');
            table = Object.create(null);
            parent[last].push(table);
          } else {
            table = root;
            for (const part of path) table = child(table, part);
          }
        } else {
          const path = key();
          if (text[i] !== '=') fail('expected =');
          i++;
          ws();
          assign(table, path, value(0));
        }
        ws();
        comment();
        if (i < n && text[i] !== '\n' && text[i] !== '\r') fail('unexpected text');
      } catch (e) {
        if (errors.length < 50) errors.push({ line: text.slice(0, lineStart).split('\n').length, message: e.message });
        i = Math.max(i, lineStart + 1);
        nextLine();
      }
    }
    return { data: root, errors };
  };

  // --------------------------------------------------------------- Plain-English time

  /** "2 h 28 min", "45 s", "3 days". */
  Smart.duration = (ms) => {
    if (!isFinite(ms) || ms < 0) return '';
    const s = Math.round(ms / 1000);
    if (s < 60) return `${s} s`;
    const m = Math.round(s / 60);
    if (m < 60) return `${m} min`;
    const h = Math.floor(m / 60);
    if (h < 48) return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
    return `${Math.round(h / 24)} days`;
  };

  // ------------------------------------------------------------------- Layered graphs

  /** A left-to-right layered drawing of a small DAG, as SVG markup. Nodes: {id, label, sub?};
      edges: [from, to] meaning "from comes before to". Cycles are tolerated. */
  Smart.graph = (nodes, edges, options = {}) => {
    const list = nodes.slice(0, 80);
    const ids = new Map(list.map((node, index) => [node.id, index]));
    const links = edges.filter(([a, b]) => ids.has(a) && ids.has(b) && a !== b).slice(0, 400);
    if (!list.length) return '';
    const preds = list.map(() => []);
    links.forEach(([a, b]) => preds[ids.get(b)].push(ids.get(a)));
    const layer = new Array(list.length).fill(-1);
    const visiting = new Array(list.length).fill(false);
    const depth = (k, guard) => {
      if (layer[k] >= 0) return layer[k];
      if (visiting[k] || guard > 100) return 0;
      visiting[k] = true;
      let d = 0;
      for (const p of preds[k]) d = Math.max(d, depth(p, guard + 1) + 1);
      visiting[k] = false;
      layer[k] = d;
      return d;
    };
    list.forEach((_, k) => depth(k, 0));
    const columns = [];
    list.forEach((_, k) => { (columns[layer[k]] = columns[layer[k]] || []).push(k); });
    // Order each column by where its predecessors sit, so edges cross less.
    const row = new Array(list.length).fill(0);
    columns.forEach((column, c) => {
      if (c > 0) {
        const score = (k) => (preds[k].length ? preds[k].reduce((s, p) => s + row[p], 0) / preds[k].length : 1e6 + k);
        column.sort((a, b) => score(a) - score(b));
      }
      column.forEach((k, r) => { row[k] = r; });
    });

    const font = options.font || 12;
    const measure = Smart.measureText || ((s) => s.length * font * 0.6);
    const nodeH = list.some((node) => node.sub) ? 40 : 28;
    const gapX = 44;
    const gapY = 12;
    const widths = list.map((node) => Math.min(220, Math.max(64, Math.max(measure(node.label, font, 600), node.sub ? measure(node.sub, font - 1.5, 400) : 0) + 24)));
    const colWidth = columns.map((column) => Math.max(...column.map((k) => widths[k])));
    const colX = [];
    let x = 0;
    columns.forEach((_, c) => { colX[c] = x; x += colWidth[c] + gapX; });
    const tallest = Math.max(...columns.map((column) => column.length));
    const height = tallest * nodeH + (tallest - 1) * gapY;
    const pos = list.map((_, k) => {
      const column = columns[layer[k]];
      const offset = (height - (column.length * nodeH + (column.length - 1) * gapY)) / 2;
      return { x: colX[layer[k]], y: offset + row[k] * (nodeH + gapY), w: colWidth[layer[k]] };
    });
    const width = x - gapX;
    const clip = (s, w, size, weight) => {
      let out = String(s);
      while (out.length > 1 && measure(out, size, weight) > w - 22) out = out.slice(0, -2) + '…';
      return out;
    };
    let svg = `<svg class="smart-graph" viewBox="-2 -2 ${width + 4} ${height + 4}" width="${width + 4}" height="${height + 4}" role="img" aria-label="${esc(options.label || 'Graph')}">`;
    for (const [a, b] of links) {
      const s = pos[ids.get(a)];
      const t = pos[ids.get(b)];
      const x1 = s.x + s.w;
      const y1 = s.y + nodeH / 2;
      const x2 = t.x;
      const y2 = t.y + nodeH / 2;
      if (x2 <= x1) continue;
      const mid = (x1 + x2) / 2;
      svg += `<path class="edge" d="M${x1} ${y1}C${mid} ${y1} ${mid} ${y2} ${x2 - 3} ${y2}"/><path class="arrow" d="M${x2 - 6} ${y2 - 3.5}L${x2} ${y2}L${x2 - 6} ${y2 + 3.5}"/>`;
    }
    list.forEach((node, k) => {
      const p = pos[k];
      svg += `<g class="node${node.tone ? ' ' + esc(node.tone) : ''}"><rect x="${p.x}" y="${p.y}" width="${p.w}" height="${nodeH}" rx="7"/>`;
      if (node.sub) {
        svg += `<text x="${p.x + 11}" y="${p.y + 16}" class="label">${esc(clip(node.label, p.w, font, 600))}</text>`;
        svg += `<text x="${p.x + 11}" y="${p.y + 31}" class="sub">${esc(clip(node.sub, p.w, font - 1.5, 400))}</text>`;
      } else {
        svg += `<text x="${p.x + 11}" y="${p.y + nodeH / 2 + 4}" class="label">${esc(clip(node.label, p.w, font, 600))}</text>`;
      }
      svg += '</g>';
    });
    return svg + '</svg>';
  };

  // ------------------------------------------------------------------------ Card UI

  const ICONS = Smart.icons = {
    package: '<path d="M8 1.6 13.6 4.6v6.8L8 14.4 2.4 11.4V4.6Z"/><path d="M2.6 4.7 8 7.6l5.4-2.9M8 7.6v6.6M5.2 3.1l5.5 3"/>',
    key: '<circle cx="5.2" cy="10.8" r="3.2"/><path d="m7.5 8.5 6-6M11.2 4.8l1.6 1.6M9.7 6.3l1.2 1.2"/>',
    log: '<rect x="2.2" y="2.2" width="11.6" height="11.6" rx="2.4"/><path d="M5 5.6h6M5 8h6M5 10.4h3.6"/>',
    container: '<rect x="2" y="5.5" width="12" height="8" rx="1.6"/><path d="M4.5 5.5v-2h7v2M5 8v3M8 8v3M11 8v3"/>',
    stack: '<path d="M8 2 14 5 8 8 2 5Z"/><path d="m2 8 6 3 6-3M2 11l6 3 6-3"/>',
    workflow: '<circle cx="3.6" cy="4" r="1.9"/><circle cx="12.4" cy="4" r="1.9"/><circle cx="12.4" cy="12" r="1.9"/><path d="M5.5 4h5M12.4 5.9v4.2"/>',
    cluster: '<path d="M8 1.8 13.5 4.5 14 10.4 10.2 14.2H5.8L2 10.4l.5-5.9Z"/><circle cx="8" cy="8.2" r="2"/>',
    api: '<path d="M5.5 3.5 2 8l3.5 4.5M10.5 3.5 14 8l-3.5 4.5M9.2 2.8 6.8 13.2"/>',
    clock: '<circle cx="8" cy="8" r="6.2"/><path d="M8 4.6V8l2.4 1.6"/>',
    hammer: '<path d="M9.4 6.6 3.1 12.9a1.3 1.3 0 0 0 1.8 1.8l6.3-6.3"/><path d="m8.2 3.4 2.6-1.6 3.4 3.4-1.6 2.6-1.3-.5-1.6 1.6-2.5-2.5 1.6-1.6Z"/>',
    terminal: '<rect x="1.8" y="2.6" width="12.4" height="10.8" rx="2.2"/><path d="m4.6 6.2 2.2 1.9-2.2 1.9M8.4 10.2h3"/>',
  };
  Smart.icon = (name) => `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ICONS.package}</svg>`;
  const CHEVRON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5 10.5 8 6 12.5"/></svg>';

  const store = {
    get(key) { try { return global.localStorage.getItem(key); } catch (_) { return null; } },
    set(key, value) { try { if (value == null) global.localStorage.removeItem(key); else global.localStorage.setItem(key, value); } catch (_) { } },
  };
  Smart.store = store;

  /** A list that shows `limit` items and a "Show All" control for the rest. */
  Smart.more = (itemsHTML, limit, noun) => {
    if (itemsHTML.length <= limit) return itemsHTML.join('');
    return itemsHTML.slice(0, limit).join('') +
      `<div class="smart-rest" hidden>${itemsHTML.slice(limit).join('')}</div>` +
      `<button type="button" class="smart-more" data-more="${itemsHTML.length - limit}">Show ${Smart.number(itemsHTML.length - limit)} More ${esc(noun || '')}</button>`;
  };

  /** One labelled part of a card. `body` is trusted markup built with `esc`. */
  Smart.section = (title, body, options = {}) => {
    if (!body) return '';
    const count = options.count != null ? `<span class="smart-count">${esc(typeof options.count === 'number' ? Smart.number(options.count) : options.count)}</span>` : '';
    return `<section class="smart-section${options.wide ? ' wide' : ''}${options.className ? ' ' + options.className : ''}"><h3>${esc(title)}${count}${options.aside ? `<span class="smart-aside">${options.aside}</span>` : ''}</h3>${body}</section>`;
  };

  /** Label/value pairs in a row (licence, engines…). Values are plain text unless `html`. */
  Smart.facts = (facts) => {
    const items = facts.filter((f) => f && f.value !== undefined && f.value !== null && f.value !== '');
    if (!items.length) return '';
    return `<dl class="smart-facts">${items.map((f) => `<div><dt>${esc(f.label)}</dt><dd${f.mono ? ' class="mono"' : ''}>${f.html ? f.value : esc(f.value)}</dd></div>`).join('')}</dl>`;
  };

  /** A link only for plain web addresses; anything else is shown as text. */
  Smart.link = (url, label) => {
    const s = Smart.text(url, 300);
    if (/^https?:\/\/[^\s"'<>]+$/i.test(s)) return `<a href="${esc(s)}" class="smart-link" title="${esc(s)}">${esc(label || s.replace(/^https?:\/\/(www\.)?/i, '').replace(/\/$/, ''))}</a>`;
    return esc(label || s);
  };

  Smart.tag = (label, tone) => `<span class="smart-tag${tone ? ' ' + tone : ''}">${esc(label)}</span>`;

  /**
   * Builds a card and puts it above the code. Options: { kind, icon, title, version, subtitle,
   * label (what the file is, e.g. "npm package"), body (markup), actions (markup), open }.
   */
  Smart.card = (root, options) => {
    const view = root.querySelector('.code-view');
    const card = document.createElement('section');
    card.className = 'smart-card';
    card.dataset.kind = options.kind;
    const foldKey = 'greece.smart.folded:' + options.kind;
    const folded = store.get(foldKey) === '1';
    card.innerHTML =
      `<header class="smart-head">` +
      `<button type="button" class="smart-fold" aria-expanded="${folded ? 'false' : 'true'}" title="${folded ? 'Show Details' : 'Hide Details'}">${CHEVRON}</button>` +
      `<span class="smart-icon">${Smart.icon(options.icon)}</span>` +
      `<div class="smart-titles"><div class="smart-title-row"><span class="smart-title">${esc(options.title)}</span>` +
      (options.version ? `<span class="smart-version">${esc(options.version)}</span>` : '') +
      (options.label ? `<span class="smart-label">${esc(options.label)}</span>` : '') + `</div>` +
      (options.subtitle ? `<div class="smart-subtitle">${esc(options.subtitle)}</div>` : '') +
      `</div>` +
      (options.actions ? `<div class="smart-actions">${options.actions}</div>` : '') +
      `</header>` +
      (options.body ? `<div class="smart-body"${folded ? ' hidden' : ''}>${options.body}</div>` : '');
    if (!options.body) card.querySelector('.smart-fold').hidden = true;
    card.classList.toggle('folded', folded);

    const fold = card.querySelector('.smart-fold');
    const body = card.querySelector('.smart-body');
    const toggle = () => {
      if (!body) return;
      const nowFolded = !body.hidden;
      body.hidden = nowFolded;
      card.classList.toggle('folded', nowFolded);
      fold.setAttribute('aria-expanded', nowFolded ? 'false' : 'true');
      fold.title = nowFolded ? 'Show Details' : 'Hide Details';
      store.set(foldKey, nowFolded ? '1' : null);
    };
    fold.addEventListener('click', toggle);
    card.querySelector('.smart-titles').addEventListener('dblclick', toggle);
    card.addEventListener('click', (event) => {
      const more = event.target.closest('.smart-more');
      if (!more) return;
      const rest = more.previousElementSibling;
      if (!rest || !rest.classList.contains('smart-rest')) return;
      rest.hidden = !rest.hidden;
      more.textContent = rest.hidden ? `Show ${Smart.number(Number(more.dataset.more))} More` : 'Show Less';
    });

    const holder = document.createElement('div');
    holder.className = 'smart';
    holder.appendChild(card);
    if (view) view.parentNode.insertBefore(holder, view);
    else root.insertBefore(holder, root.firstChild);
    document.documentElement.classList.add('has-smart');
    return card;
  };

  // ---------------------------------------------------------------------- Dispatcher

  if (global.document && global.greece && typeof global.greece.enhance === 'function') {
    const canvas = document.createElement('canvas');
    const context = canvas.getContext && canvas.getContext('2d');
    if (context) {
      Smart.measureText = (s, size = 12, weight = 400) => {
        context.font = `${weight} ${size}px -apple-system, BlinkMacSystemFont, sans-serif`;
        return context.measureText(String(s)).width;
      };
    }

    global.greece.enhance('code', async (root, kit) => {
      if (kit.payload.kind !== 'code' || !root.querySelector('.code-view')) return;
      const file = Smart.file(kit.fileName, kit.payload.text, kit.payload.language);
      const kind = Smart.detect(file);
      if (!kind) return;
      if (kind.yaml === true || (typeof kind.yaml === 'function' && kind.yaml(file))) {
        try { await Smart.loadYAML(); } catch (e) { kit.post('log', 'smart: ' + e.message); return; }
      }
      const started = Date.now();
      await kind.enhance({ root, kit, file, Smart });
      const took = Date.now() - started;
      if (took > 150) kit.post('log', `smart ${kind.id}: ${took} ms`);
    });
  }
})(typeof window !== 'undefined' ? window : globalThis);
