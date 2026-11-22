/* Greece — HTTP Archive (HAR) viewer: a network waterfall with request and response details.
   Entry details load on demand from greece://module/entry/<n>. Every string from the capture is
   escaped before it reaches the page. */
(function () {
  'use strict';

  const TYPES = [
    ['all', 'All'], ['document', 'Doc'], ['fetch', 'Fetch/XHR'], ['script', 'JS'], ['stylesheet', 'CSS'],
    ['image', 'Img'], ['font', 'Font'], ['media', 'Media'], ['websocket', 'WS'], ['other', 'Other'],
  ];
  const TYPE_NAMES = {
    document: 'Document', fetch: 'Fetch', script: 'Script', stylesheet: 'Stylesheet', image: 'Image',
    font: 'Font', media: 'Media', websocket: 'WebSocket', other: 'Other',
  };
  const PHASES = [
    ['blocked', 'Queued'], ['dns', 'DNS Lookup'], ['connect', 'Connection'], ['ssl', 'TLS'],
    ['send', 'Request Sent'], ['wait', 'Waiting (TTFB)'], ['receive', 'Download'],
  ];
  const MAX_ROWS = 5000;

  function bytes(n) {
    if (!(n > 0)) return '—';
    if (n < 1000) return n + ' B';
    const units = ['KB', 'MB', 'GB'];
    let v = n / 1000, u = 0;
    while (v >= 1000 && u < units.length - 1) { v /= 1000; u++; }
    return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + ' ' + units[u];
  }

  function ms(n) {
    if (n == null || !(n >= 0)) return '—';
    if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 1 : 2) + ' s';
    if (n >= 10) return Math.round(n) + ' ms';
    return n.toFixed(1) + ' ms';
  }

  function statusClass(row) {
    if (row.failed) return 'failed';
    if (row.status >= 500) return 's5';
    if (row.status >= 400) return 's4';
    if (row.status >= 300) return 's3';
    return 's2';
  }

  /** Pretty JSON when it parses, the text unchanged otherwise. */
  function prettyJSON(text) {
    try { return JSON.stringify(JSON.parse(text), null, 2); } catch (_) { return text; }
  }

  function grammarFor(mime) {
    mime = (mime || '').toLowerCase();
    if (mime.includes('json')) return 'json';
    if (mime.includes('javascript') || mime.includes('ecmascript')) return 'javascript';
    if (mime.includes('css')) return 'css';
    if (mime.includes('html') || mime.includes('xml') || mime.includes('svg')) return 'xml';
    return null;
  }

  greece.register('har', (data, kit) => {
    const { esc, root } = kit;
    const entries = data.entries || [];
    const total = Math.max(data.duration || 0, 1);
    const state = { filter: '', type: 'all', sort: null, asc: true, selected: null, tab: 'headers' };

    root.innerHTML = `
      <div class="har">
        <header class="har-bar">
          <input class="har-search" type="search" placeholder="Filter" spellcheck="false" aria-label="Filter requests">
          <nav class="har-types" role="tablist">${TYPES.map(([id, label]) =>
            `<button type="button" data-type="${id}" class="${id === 'all' ? 'on' : ''}">${label}</button>`).join('')}</nav>
          <span class="har-count"></span>
        </header>
        <div class="har-main">
          <div class="har-list" tabindex="0">
            <table class="har-table">
              <colgroup><col class="c-status"><col class="c-method"><col class="c-name"><col class="c-type"><col class="c-size"><col class="c-time"><col class="c-fall"></colgroup>
              <thead><tr>
                <th data-sort="status">Status</th><th data-sort="method">Method</th><th data-sort="path">Name</th>
                <th data-sort="type">Type</th><th data-sort="size" class="num">Size</th><th data-sort="time" class="num">Time</th>
                <th data-sort="start" class="fall">Waterfall${scaleMarks()}</th>
              </tr></thead>
              <tbody></tbody>
            </table>
          </div>
          <section class="har-detail"></section>
        </div>
      </div>`;

    const tbody = kit.$('tbody', root);
    const list = kit.$('.har-list', root);
    const detail = kit.$('.har-detail', root);
    const count = kit.$('.har-count', root);

    function scaleMarks() {
      const marks = [];
      for (const page of data.pages || []) {
        if (page.contentLoad != null) marks.push(`<i class="mark dcl" style="left:${(page.contentLoad / total * 100).toFixed(3)}%" title="DOMContentLoaded ${esc(ms(page.contentLoad))}"></i>`);
        if (page.load != null) marks.push(`<i class="mark load" style="left:${(page.load / total * 100).toFixed(3)}%" title="Load ${esc(ms(page.load))}"></i>`);
      }
      return `<span class="marks">${marks.join('')}</span>`;
    }

    function visible() {
      const q = state.filter.toLowerCase();
      let rows = entries.map((row, index) => ({ row, index }));
      if (state.type !== 'all') rows = rows.filter(({ row }) => row.type === state.type);
      if (q) rows = rows.filter(({ row }) => row.url.toLowerCase().includes(q) || String(row.status).includes(q) || row.method.toLowerCase() === q || row.mime.includes(q));
      if (state.sort) {
        const key = state.sort, dir = state.asc ? 1 : -1;
        rows.sort((a, b) => {
          const x = a.row[key], y = b.row[key];
          if (typeof x === 'number') return (x - y) * dir || a.index - b.index;
          return String(x).localeCompare(String(y), undefined, { numeric: true }) * dir || a.index - b.index;
        });
      }
      return rows;
    }

    function bar(row) {
      const left = row.start / total * 100;
      const width = Math.max(row.time / total * 100, 0.15);
      const t = row.timings || {};
      const parts = PHASES.map(([key]) => [key, t[key] || 0]).filter(([, v]) => v > 0);
      const sum = parts.reduce((s, [, v]) => s + v, 0);
      const segments = sum > 0
        ? parts.map(([key, v]) => `<i class="ph ${key}" style="width:${(v / sum * 100).toFixed(2)}%"></i>`).join('')
        : '<i class="ph wait" style="width:100%"></i>';
      return `<span class="bar ${row.failed ? 'failed' : ''}" style="left:${left.toFixed(3)}%;width:${width.toFixed(3)}%">${segments}</span>`;
    }

    function render() {
      const rows = visible();
      const shown = rows.slice(0, MAX_ROWS);
      let html = '';
      for (const { row, index } of shown) {
        const name = row.path === '/' ? row.host : (row.path.split('?')[0].split('/').filter(Boolean).pop() || row.path);
        html += `<tr data-i="${index}" class="${index === state.selected ? 'sel' : ''}">`
          + `<td class="status ${statusClass(row)}">${row.failed && !row.status ? 'Failed' : esc(row.status)}</td>`
          + `<td class="method">${esc(row.method)}</td>`
          + `<td class="name" title="${esc(row.url)}"><span class="fname">${esc(decodeSafe(name))}</span><span class="host">${esc(row.host)}${esc(row.path.length > 1 ? row.path : '')}</span></td>`
          + `<td class="type">${esc(TYPE_NAMES[row.type] || row.type)}</td>`
          + `<td class="num">${esc(bytes(row.size))}</td>`
          + `<td class="num">${esc(ms(row.time))}</td>`
          + `<td class="fall">${bar(row)}</td></tr>`;
      }
      tbody.innerHTML = html || `<tr class="none"><td colspan="7">No matching requests</td></tr>`;
      const size = rows.reduce((s, { row }) => s + (row.size || 0), 0);
      count.textContent = (rows.length === entries.length ? `${entries.length.toLocaleString()} requests` : `${rows.length.toLocaleString()} of ${entries.length.toLocaleString()} requests`)
        + ` · ${bytes(size)} · ${ms(data.duration)}` + (shown.length < rows.length ? ` · first ${MAX_ROWS.toLocaleString()} shown` : '');
      kit.$$('th[data-sort]', root).forEach((th) => {
        th.classList.toggle('sorted', th.dataset.sort === state.sort);
        th.classList.toggle('desc', th.dataset.sort === state.sort && !state.asc);
      });
    }

    function decodeSafe(s) { try { return decodeURIComponent(s); } catch (_) { return s; } }

    // ---------------------------------------------------------------- Summary (nothing selected)

    function renderSummary() {
      root.classList.remove('has-selection');
      const byType = {};
      for (const row of entries) {
        const t = byType[row.type] || (byType[row.type] = { n: 0, size: 0 });
        t.n++; t.size += row.size || 0;
      }
      const largest = Math.max(1, ...Object.values(byType).map((t) => t.size));
      const page = (data.pages || [])[0];
      const failed = entries.filter((r) => r.failed || r.status >= 400).length;
      const facts = [
        ['Requests', entries.length.toLocaleString() + (data.total > entries.length ? ` of ${data.total.toLocaleString()}` : '')],
        ['Transferred', bytes(data.bytes)],
        ['Finished', ms(data.duration)],
      ];
      if (page && page.contentLoad != null) facts.push(['DOMContentLoaded', ms(page.contentLoad)]);
      if (page && page.load != null) facts.push(['Load', ms(page.load)]);
      if (failed) facts.push(['Errors', String(failed)]);
      detail.innerHTML = `
        <div class="har-summary">
          <div class="who">
            <h2>${esc(page && page.title ? page.title : 'Network capture')}</h2>
            <p>${esc([data.browser, data.creator ? 'recorded with ' + data.creator : ''].filter(Boolean).join(' · ') || 'HTTP Archive')}</p>
          </div>
          <dl class="facts">${facts.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>
          <div class="types">${Object.entries(byType).sort((a, b) => b[1].size - a[1].size).map(([type, t]) => `
            <div class="type-row"><span class="tname">${esc(TYPE_NAMES[type] || type)}</span>
              <span class="tbar"><i class="ty-${esc(type)}" style="width:${Math.max(1.5, t.size / largest * 100).toFixed(1)}%"></i></span>
              <span class="tnum">${t.n.toLocaleString()}</span><span class="tsize">${esc(bytes(t.size))}</span></div>`).join('')}
          </div>
          <p class="hint">Select a request to see its headers, payload, response and timing.</p>
        </div>`;
    }

    // ---------------------------------------------------------------- Details

    async function select(index) {
      state.selected = index;
      kit.$$('tr.sel', tbody).forEach((tr) => tr.classList.remove('sel'));
      const tr = kit.$(`tr[data-i="${index}"]`, tbody);
      // The list shrinks when the details open: reveal the row after that.
      root.classList.add('has-selection');
      if (tr) { tr.classList.add('sel'); tr.scrollIntoView({ block: 'nearest' }); }
      const row = entries[index];
      detail.innerHTML = `<div class="har-loading">${esc(row.url)}</div>`;
      let info;
      try {
        info = await (await fetch('greece://module/entry/' + index)).json();
      } catch (e) {
        detail.innerHTML = kit.notice('This request’s details couldn’t be read.');
        return;
      }
      if (state.selected !== index) return;
      renderDetail(row, info);
    }

    function table(pairs, empty) {
      if (!pairs || !pairs.length) return `<p class="none">${esc(empty)}</p>`;
      return `<dl class="kv">${pairs.map((p) => `<dt>${esc(p.name)}</dt><dd>${esc(p.value)}</dd>`).join('')}</dl>`;
    }

    function renderDetail(row, info) {
      const hasPayload = (info.query && info.query.length) || info.postText || (info.postParams && info.postParams.length);
      const tabs = [['headers', 'Headers'], hasPayload ? ['payload', 'Payload'] : null, ['response', 'Response'], ['timing', 'Timing']].filter(Boolean);
      if (!tabs.some(([id]) => id === state.tab)) state.tab = 'headers';
      detail.innerHTML = `
        <header class="detail-head">
          <span class="status ${statusClass(row)}">${row.failed && !row.status ? 'Failed' : esc(String(info.status || ''))}</span>
          <span class="method">${esc(info.method)}</span>
          <span class="url" title="${esc(info.url)}">${esc(info.url)}</span>
          <button class="close" type="button" aria-label="Close" title="Close (Esc)">×</button>
        </header>
        <nav class="detail-tabs" role="tablist">${tabs.map(([id, label]) => `<button type="button" data-tab="${id}" class="${id === state.tab ? 'on' : ''}">${label}</button>`).join('')}</nav>
        <div class="detail-body"></div>`;
      const body = kit.$('.detail-body', detail);
      const show = (tab) => {
        state.tab = tab;
        kit.$$('.detail-tabs button', detail).forEach((b) => b.classList.toggle('on', b.dataset.tab === tab));
        body.innerHTML = '';
        if (tab === 'headers') body.innerHTML = headersTab(row, info);
        else if (tab === 'payload') body.innerHTML = payloadTab(info);
        else if (tab === 'response') body.innerHTML = responseTab(info);
        else body.innerHTML = timingTab(row, info);
        body.scrollTop = 0;
      };
      kit.$$('.detail-tabs button', detail).forEach((b) => b.addEventListener('click', () => show(b.dataset.tab)));
      kit.$('.close', detail).addEventListener('click', clearSelection);
      show(state.tab);
    }

    function headersTab(row, info) {
      const general = [
        { name: 'Request URL', value: info.url },
        { name: 'Method', value: info.method },
        { name: 'Status', value: [info.status, info.statusText].filter(Boolean).join(' ') || (info.error || 'Failed') },
        info.server ? { name: 'Remote Address', value: info.server + (info.connection ? ' · connection ' + info.connection : '') } : null,
        info.responseVersion ? { name: 'Protocol', value: info.responseVersion } : null,
        info.redirect ? { name: 'Redirects To', value: info.redirect } : null,
        info.error ? { name: 'Error', value: info.error } : null,
      ].filter(Boolean);
      return `<h3>General</h3>${table(general, '')}
        <h3>Response Headers <span class="n">${(info.responseHeaders || []).length}</span></h3>${table(info.responseHeaders, 'No response headers')}
        <h3>Request Headers <span class="n">${(info.requestHeaders || []).length}</span></h3>${table(info.requestHeaders, 'No request headers')}
        ${info.requestCookies && info.requestCookies.length ? `<h3>Cookies Sent</h3>${table(info.requestCookies, '')}` : ''}
        ${info.responseCookies && info.responseCookies.length ? `<h3>Cookies Set</h3>${table(info.responseCookies, '')}` : ''}`;
    }

    function codeBlock(text, mime) {
      const grammar = grammarFor(mime);
      const shown = grammar === 'json' ? prettyJSON(text) : text;
      const capped = shown.length > 400000 ? shown.slice(0, 400000) : shown;
      return `<pre class="body-code"><code class="hljs">${grammar ? kit.highlight(capped, grammar) : esc(capped)}</code></pre>`
        + (capped.length < shown.length ? kit.notice('Showing the beginning of a long body.') : '');
    }

    function payloadTab(info) {
      let html = '';
      if (info.query && info.query.length) html += `<h3>Query String <span class="n">${info.query.length}</span></h3>${table(info.query, '')}`;
      if (info.postParams && info.postParams.length) html += `<h3>Form Data</h3>${table(info.postParams, '')}`;
      else if (info.postText) html += `<h3>Request Body <span class="n">${esc(info.postMime || '')}</span></h3>${codeBlock(info.postText, info.postMime)}`;
      return html;
    }

    function responseTab(info) {
      const mime = (info.mime || '').split(';')[0].trim().toLowerCase();
      const meta = `<p class="body-meta">${esc([mime, info.size > 0 ? bytes(info.size) : '', info.encoding].filter(Boolean).join(' · '))}</p>`;
      if (info.body == null || info.body === '') return meta + `<p class="none">No response body was recorded.</p>`;
      if (/^image\/(png|jpe?g|gif|webp|avif|bmp|x-icon|vnd\.microsoft\.icon|svg\+xml)$/.test(mime)) {
        const src = info.encoding === 'base64'
          ? `data:${mime};base64,${info.body.replace(/[^A-Za-z0-9+/=]/g, '')}`
          : (mime === 'image/svg+xml' ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(info.body)}` : null);
        if (src) return meta + `<div class="image"><img alt="" src="${esc(src)}"></div>`;
      }
      if (info.encoding === 'base64') {
        let decoded = null;
        try { decoded = decodeURIComponent(escape(atob(info.body.replace(/\s/g, '')))); } catch (_) { decoded = null; }
        if (decoded == null || /[\u0000-\u0008]/.test(decoded.slice(0, 2000))) return meta + `<p class="none">Binary content.</p>`;
        return meta + codeBlock(decoded, mime);
      }
      return meta + codeBlock(info.body, mime) + (info.bodyTruncated ? kit.notice('Showing the first 3 MB.') : '');
    }

    function timingTab(row, info) {
      const t = info.timings || {};
      const phases = PHASES.map(([key, label]) => [key, label, typeof t[key] === 'number' && t[key] >= 0 ? t[key] : null]).filter(([, , v]) => v != null);
      const sum = phases.reduce((s, [, , v]) => s + v, 0) || 1;
      let offset = 0;
      const rows = phases.map(([key, label, v]) => {
        const html = `<div class="tm"><span class="tl">${esc(label)}</span><span class="tt"><i class="ph ${key}" style="margin-left:${(offset / sum * 100).toFixed(2)}%;width:${Math.max(0.6, v / sum * 100).toFixed(2)}%"></i></span><span class="tv">${esc(ms(v))}</span></div>`;
        offset += v;
        return html;
      }).join('');
      return `<p class="body-meta">Started at ${esc(ms(row.start))} · total ${esc(ms(info.time))}</p><div class="timing">${rows || '<p class="none">No timing recorded.</p>'}</div>`;
    }

    function clearSelection() {
      state.selected = null;
      kit.$$('tr.sel', tbody).forEach((tr) => tr.classList.remove('sel'));
      renderSummary();
    }

    // ---------------------------------------------------------------- Wiring

    kit.$('.har-search', root).addEventListener('input', (e) => { state.filter = e.target.value.trim(); render(); });
    // Quick Look keeps typed keys for Finder: the type tabs filter instead.
    if (!kit.typing) kit.$('.har-search', root).hidden = true;
    kit.$$('.har-types button', root).forEach((button) => button.addEventListener('click', () => {
      state.type = button.dataset.type;
      kit.$$('.har-types button', root).forEach((b) => b.classList.toggle('on', b === button));
      render();
    }));
    kit.$$('th[data-sort]', root).forEach((th) => th.addEventListener('click', () => {
      const key = th.dataset.sort;
      if (state.sort === key) state.asc = !state.asc; else { state.sort = key; state.asc = key !== 'size' && key !== 'time'; }
      render();
    }));
    tbody.addEventListener('click', (e) => {
      const tr = e.target.closest('tr[data-i]');
      if (tr) select(Number(tr.dataset.i));
    });
    list.addEventListener('keydown', (e) => {
      const rows = kit.$$('tr[data-i]', tbody);
      if (!rows.length) return;
      const at = rows.findIndex((tr) => Number(tr.dataset.i) === state.selected);
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        const next = rows[Math.min(rows.length - 1, Math.max(0, at + (e.key === 'ArrowDown' ? 1 : -1)))];
        select(Number(next.dataset.i));
      } else if (e.key === 'Escape') {
        clearSelection();
      }
    });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && state.selected != null) clearSelection(); });

    render();
    if (data.select != null && entries[data.select]) select(data.select); else renderSummary();
  });
})();
