/* Greece — preview renderer.
   Reads the JSON payload embedded by GreeceKit and renders Markdown, code, diffs and notebooks.
   Everything runs locally; untrusted HTML is sanitised and the page has a strict CSP. */
(function () {
  'use strict';

  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
  const html = document.documentElement;
  const payload = JSON.parse($('#payload').textContent);
  const options = payload.options || {};
  const root = $('#root');

  function post(name, body) {
    try { window.webkit.messageHandlers[name].postMessage(body === undefined ? null : body); } catch (_) { }
  }
  window.addEventListener('error', (e) => post('log', String(e.message) + ' @' + e.lineno));
  window.addEventListener('unhandledrejection', (e) => post('log', 'unhandled: ' + (e.reason && (e.reason.stack || e.reason))));

  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

  // ------------------------------------------------------------------ Highlighting

  function grammar(lang) {
    if (!window.hljs || !lang) return null;
    const key = String(lang).toLowerCase().replace(/^\{\.?|\}$/g, '');
    if (key === 'plaintext' || key === 'text' || key === 'txt') return null;
    return hljs.getLanguage(key) ? key : null;
  }

  function highlight(text, lang) {
    const g = grammar(lang);
    if (g) {
      try { return hljs.highlight(text, { language: g, ignoreIllegals: true }).value; } catch (_) { }
    }
    return esc(text);
  }

  function languageTitle(lang) {
    if (!lang) return '';
    const g = grammar(lang);
    const named = g && hljs.getLanguage(g).name;
    if (named && named.length < 24) return named;
    return lang;
  }

  /** Splits highlight.js output into lines, closing and reopening spans so every line is balanced. */
  function splitHighlighted(markup) {
    const lines = [];
    const open = [];
    let current = '';
    const token = /(<span[^>]*>)|(<\/span>)|(\n)|([^<\n]+)/g;
    let m;
    while ((m = token.exec(markup))) {
      if (m[1]) { open.push(m[1]); current += m[1]; }
      else if (m[2]) { open.pop(); current += m[2]; }
      else if (m[3]) { current += '</span>'.repeat(open.length); lines.push(current); current = open.join(''); }
      else current += m[4];
    }
    lines.push(current + '</span>'.repeat(open.length));
    return lines;
  }

  // ------------------------------------------------------------------ Shared UI

  function copyText(text, button) {
    post('copy', text);
    if (!button) return;
    const label = button.dataset.label || button.textContent;
    button.dataset.label = label;
    button.textContent = 'Copied';
    button.classList.add('done');
    clearTimeout(button._t);
    button._t = setTimeout(() => { button.textContent = label; button.classList.remove('done'); }, 1400);
  }

  document.addEventListener('click', (event) => {
    const copy = event.target.closest('.codeblock .copy');
    if (copy) {
      const code = copy.closest('.codeblock').querySelector('pre');
      copyText(code.innerText.replace(/\n$/, ''), copy);
      event.preventDefault();
      return;
    }
    const anchor = event.target.closest('a[href^="#"]');
    if (anchor) {
      event.preventDefault();
      let id = anchor.getAttribute('href').slice(1);
      try { id = decodeURIComponent(id); } catch (_) { }
      const target = id && (document.getElementById(id) || document.getElementsByName(id)[0]);
      if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      else window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  });

  function notice(text) {
    return `<div class="notice">${esc(text)}</div>`;
  }

  function empty(text) {
    root.innerHTML = `<div class="empty">${esc(text)}</div>`;
  }

  // ------------------------------------------------------------------ Code

  function renderCode() {
    html.classList.add('kind-code');
    let text = payload.text.replace(/\r\n?/g, '\n');
    if (text.endsWith('\n')) text = text.slice(0, -1);
    if (!payload.text.length) return empty('Empty file');

    const lines = text.split('\n');
    html.style.setProperty('--gutter', `calc(${String(lines.length).length}ch + 6px)`);

    const tools = `<div class="floating-tools"><button class="pill" id="copy-all" type="button">Copy</button></div>`;
    const truncation = payload.truncated ? notice('Showing the beginning of a very large file.') : '';
    const lang = grammar(payload.language) ? payload.language : null;
    const highlightable = !!lang && text.length <= 8000000;

    // The first screenfuls paint immediately; big files stream in after Quick Look is showing them.
    const CHUNK = 400;
    const FIRST = 2400;
    const large = lines.length > FIRST;
    const lazy = large ? ' lazy' : '';
    const chunk = (start, htmlLines) => {
      let out = `<div class="chunk${lazy}" data-start="${start}">`;
      for (let i = 0; i < htmlLines.length; i++) out += `<div class="ln" data-n="${start + i + 1}">${htmlLines[i]}</div>`;
      return out + '</div>';
    };

    const head = lines.slice(0, FIRST);
    const headHTML = highlightable ? splitHighlighted(highlight(head.join('\n'), lang)) : head.map(esc);
    let body = '';
    for (let s = 0; s < headHTML.length; s += CHUNK) body += chunk(s, headHTML.slice(s, s + CHUNK));
    root.innerHTML = `${tools}<div class="code-view${large ? ' large' : ''}">${body}</div>${truncation}`;
    wireCopyAll(text);
    if (!large) return;

    const view = $('.code-view', root);
    afterReady(async () => {
      for (let s = FIRST; s < lines.length; s += CHUNK * 5) {
        let out = '';
        for (let c = s; c < Math.min(s + CHUNK * 5, lines.length); c += CHUNK) {
          out += chunk(c, lines.slice(c, Math.min(c + CHUNK, lines.length)).map(esc));
        }
        view.insertAdjacentHTML('beforeend', out);
        await tick();
      }
      if (!highlightable) return;
      // Colors arrive segment by segment; each chunk is swapped once all its lines are ready.
      const highlighted = new Array(lines.length);
      const chunks = Array.from(view.children);
      let nextChunk = 0;
      let covered = 0;
      await highlightInSegments(text, lang, async (start, markup) => {
        const segment = splitHighlighted(markup);
        for (let i = 0; i < segment.length; i++) highlighted[start + i] = segment[i];
        covered = start + segment.length;
        while (nextChunk < chunks.length) {
          const first = Number(chunks[nextChunk].dataset.start);
          const last = Math.min(first + CHUNK, lines.length);
          if (last > covered) break;
          let out = '';
          for (let i = first; i < last; i++) out += `<div class="ln" data-n="${i + 1}">${highlighted[i]}</div>`;
          chunks[nextChunk].innerHTML = out;
          nextChunk += 1;
          if (nextChunk % 12 === 0) await tick();
        }
      });
    });
  }

  // Yields to the event loop. MessageChannel tasks aren't throttled for hidden pages the way
  // timers are, and Quick Look prepares previews before they're on screen.
  const tick = () => new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => resolve();
    channel.port2.postMessage(0);
  });
  const readyCallbacks = [];
  function afterReady(callback) { readyCallbacks.push(callback); }

  /** Splits huge files at top-level boundaries (a blank line, then an unindented line). Smaller
      pieces keep highlight.js fast and let colors appear from the top while the rest is working. */
  function segments(lines) {
    const result = [];
    let start = 0;
    while (start < lines.length) {
      let end = Math.min(start + 1500, lines.length);
      while (end < lines.length && end < start + 3000 && !(lines[end - 1].trim() === '' && /^\S/.test(lines[end]))) end++;
      result.push([start, end]);
      start = end;
    }
    return result;
  }

  /** Highlights in a Web Worker so scrolling stays smooth; falls back to the main thread. */
  function highlightInSegments(text, lang, onSegment) {
    return new Promise((resolve) => {
      let settled = false;
      const done = () => { if (!settled) { settled = true; resolve(); } };
      const fallback = async () => {
        const lines = text.split('\n');
        for (const [start, end] of segments(lines)) {
          await onSegment(start, highlight(lines.slice(start, end).join('\n'), lang));
          await tick();
        }
        done();
      };
      // Workers can't reach the custom asset scheme themselves, so the page hands them the
      // highlighter's source and the worker runs self-contained.
      const urls = $$('script[src*="/vendor/highlight/"]').map((s) => s.src);
      Promise.all(urls.map((url) => fetch(url).then((r) => r.text())))
        .then((sources) => {
          const body = [
            segments.toString(),
            'onmessage = (e) => {',
            '  const lines = e.data.text.split("\\n");',
            '  for (const [start, end] of segments(lines)) {',
            '    const html = hljs.highlight(lines.slice(start, end).join("\\n"), { language: e.data.lang, ignoreIllegals: true }).value;',
            '    postMessage({ start, html });',
            '  }',
            '  postMessage({ done: true });',
            '};',
          ].join('\n');
          const source = sources.join('\n;\n') + '\n;\n' + body;
          const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
          let queue = Promise.resolve();
          worker.onmessage = (e) => {
            if (e.data.done) { queue.then(() => { worker.terminate(); done(); }); return; }
            queue = queue.then(() => onSegment(e.data.start, e.data.html));
          };
          worker.onerror = (e) => { worker.terminate(); post('log', 'worker: ' + (e && e.message)); fallback(); };
          worker.postMessage({ text, lang });
        })
        .catch((e) => {
          post('log', 'worker unavailable: ' + e);
          fallback();
        });
    });
  }

  function wireCopyAll(text) {
    const button = $('#copy-all');
    if (button) button.onclick = () => copyText(text, button);
  }

  // ------------------------------------------------------------------ Markdown

  const ALERT_ICONS = {
    note: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
    tip: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"/></svg>',
    important: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>',
    warning: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>',
    caution: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
  };

  function katexHTML(tex, display) {
    if (!window.katex) return `<code class="math">${esc(tex)}</code>`;
    try {
      return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'html', strict: 'ignore', trust: false });
    } catch (_) {
      return `<code class="math">${esc(tex)}</code>`;
    }
  }

  /** $inline$, $$display$$, \(inline\) and \[display\] for markdown-it. */
  function mathPlugin(md) {
    md.inline.ruler.after('escape', 'math_inline', (state, silent) => {
      const src = state.src;
      const pos = state.pos;
      if (src.startsWith('\\(', pos)) {
        const end = src.indexOf('\\)', pos + 2);
        if (end < 0) return false;
        if (!silent) state.push('math_inline', 'math', 0).content = src.slice(pos + 2, end);
        state.pos = end + 2;
        return true;
      }
      if (src[pos] !== '$') return false;
      if (src[pos + 1] === '$') {
        const end = src.indexOf('$$', pos + 2);
        if (end < 0) return false;
        if (!silent) state.push('math_display', 'math', 0).content = src.slice(pos + 2, end);
        state.pos = end + 2;
        return true;
      }
      const next = src[pos + 1];
      if (!next || /\s/.test(next)) return false;
      if (pos > 0 && /\d/.test(src[pos - 1])) return false;
      let end = pos + 1;
      for (;;) {
        end = src.indexOf('$', end);
        if (end < 0) return false;
        if (src[end - 1] === '\\' || /\s/.test(src[end - 1]) || /\d/.test(src[end + 1] || '')) { end += 1; continue; }
        break;
      }
      if (!silent) state.push('math_inline', 'math', 0).content = src.slice(pos + 1, end);
      state.pos = end + 1;
      return true;
    });

    md.block.ruler.before('fence', 'math_block', (state, startLine, endLine, silent) => {
      const start = state.bMarks[startLine] + state.tShift[startLine];
      const line = state.src.slice(start, state.eMarks[startLine]).trim();
      let close;
      if (line.startsWith('$$')) close = '$$';
      else if (line.startsWith('\\[')) close = '\\]';
      else return false;
      const rest = line.slice(2);
      let content;
      let last = startLine;
      if (rest.trim().length >= 2 && rest.trim().endsWith(close)) {
        content = rest.trim().slice(0, -2);
      } else {
        const parts = [rest];
        let found = false;
        for (last = startLine + 1; last < endLine; last++) {
          const text = state.src.slice(state.bMarks[last] + state.tShift[last], state.eMarks[last]);
          if (text.trim().endsWith(close)) { parts.push(text.trim().slice(0, -2)); found = true; break; }
          parts.push(text);
        }
        if (!found) return false;
        content = parts.join('\n');
      }
      if (silent) return true;
      state.line = last + 1;
      const token = state.push('math_block', 'math', 0);
      token.block = true;
      token.content = content;
      token.map = [startLine, state.line];
      return true;
    }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });

    md.renderer.rules.math_inline = (t, i) => katexHTML(t[i].content, false);
    md.renderer.rules.math_display = (t, i) => katexHTML(t[i].content, true);
    md.renderer.rules.math_block = (t, i) => `<div class="math-block">${katexHTML(t[i].content, true)}</div>\n`;
  }

  function codeBlockHTML(code, lang) {
    const body = highlight(code.replace(/\n$/, ''), lang);
    const title = languageTitle(lang);
    return `<figure class="codeblock"><div class="tools">${title ? `<span class="lang">${esc(title)}</span>` : ''}<button class="copy" type="button">Copy</button></div><pre><code class="hljs">${body}</code></pre></figure>\n`;
  }

  function createMarkdown() {
    const md = window.markdownit({ html: true, linkify: true, typographer: true, breaks: false });
    if (window.markdownitFootnote) md.use(window.markdownitFootnote);
    const emoji = window.markdownitEmoji && (window.markdownitEmoji.full || window.markdownitEmoji);
    if (typeof emoji === 'function') md.use(emoji);
    if (options.math && window.katex) md.use(mathPlugin);

    md.renderer.rules.fence = (tokens, idx) => {
      const token = tokens[idx];
      const info = (token.info || '').trim();
      const lang = info.split(/\s+/)[0].toLowerCase();
      if (lang === 'mermaid' && options.diagrams && window.mermaid) {
        return `<div class="mermaid-block"><pre class="mermaid">${esc(token.content)}</pre></div>\n`;
      }
      if ((lang === 'math' || lang === 'katex') && options.math && window.katex) {
        return `<div class="math-block">${katexHTML(token.content, true)}</div>\n`;
      }
      return codeBlockHTML(token.content, lang);
    };
    md.renderer.rules.code_block = (tokens, idx) => codeBlockHTML(tokens[idx].content, '');
    md.renderer.rules.table_open = () => '<div class="table-wrap"><table>\n';
    md.renderer.rules.table_close = () => '</table></div>\n';
    return md;
  }

  const FORBIDDEN = 'script,iframe,frame,frameset,object,embed,applet,link,meta,base,style,form,input:not([type=checkbox]),button:not(.copy),textarea,select,noscript,template,portal';

  /** Removes active content from rendered HTML. The CSP is the second line of defence. */
  function sanitize(container) {
    $$(FORBIDDEN, container).forEach((node) => node.remove());
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_ELEMENT);
    let node;
    while ((node = walker.nextNode())) {
      for (const attr of Array.from(node.attributes)) {
        const name = attr.name.toLowerCase();
        const value = attr.value.trim().toLowerCase();
        if (name.startsWith('on') || name === 'srcdoc' || name === 'formaction' || name === 'style' && /expression|url\s*\(\s*['"]?\s*javascript/.test(value)) {
          node.removeAttribute(attr.name);
        } else if ((name === 'href' || name === 'src' || name === 'xlink:href' || name === 'action') &&
                   (value.startsWith('javascript:') || value.startsWith('vbscript:') || value.startsWith('data:text/html'))) {
          node.removeAttribute(attr.name);
        }
      }
    }
  }

  function slugify(text, used) {
    let base = text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-') || 'section';
    let slug = base;
    let n = 1;
    while (used.has(slug)) slug = `${base}-${n++}`;
    used.add(slug);
    return slug;
  }

  function enhanceMarkdown(article) {
    // GitHub alerts: > [!NOTE] …
    $$('blockquote', article).forEach((quote) => {
      const first = quote.firstElementChild;
      if (!first || first.tagName !== 'P') return;
      const match = first.innerHTML.match(/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(<br>)?\s*/i);
      if (!match) return;
      const type = match[1].toLowerCase();
      first.innerHTML = first.innerHTML.slice(match[0].length);
      if (!first.innerHTML.trim()) first.remove();
      quote.classList.add('alert', type);
      quote.insertAdjacentHTML('afterbegin', `<p class="alert-title">${ALERT_ICONS[type]}${type[0].toUpperCase() + type.slice(1)}</p>`);
    });

    // Task lists: - [ ] and - [x]
    $$('li', article).forEach((li) => {
      const holder = li.firstElementChild && li.firstElementChild.tagName === 'P' ? li.firstElementChild : li;
      const textNode = holder.firstChild;
      if (!textNode || textNode.nodeType !== Node.TEXT_NODE) return;
      const match = textNode.textContent.match(/^\[([ xX])\]\s+/);
      if (!match) return;
      textNode.textContent = textNode.textContent.slice(match[0].length);
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.disabled = true;
      box.checked = match[1] !== ' ';
      holder.insertBefore(box, holder.firstChild);
      li.classList.add('task-list-item');
      if (box.checked) li.classList.add('done');
      if (li.parentElement) li.parentElement.classList.add('contains-task-list');
    });

    // Images: local paths, remote policy.
    $$('img', article).forEach((img) => {
      const src = img.getAttribute('src') || '';
      if (src.startsWith('file://')) img.setAttribute('src', 'greece://file' + src.slice(7));
      if (/^https?:/i.test(src) && !options.remoteImages) {
        const placeholder = document.createElement('span');
        placeholder.className = 'remote-image';
        placeholder.textContent = (img.alt ? img.alt + ' · ' : '') + 'Remote image not loaded';
        img.replaceWith(placeholder);
        return;
      }
      img.loading = 'lazy';
      img.decoding = 'async';
    });

    // Headings: stable ids for links and the outline.
    const used = new Set();
    const headings = $$('h1, h2, h3, h4', article);
    headings.forEach((h) => { if (!h.id) h.id = slugify(h.textContent, used); else used.add(h.id); });
    return headings;
  }

  function buildOutline(headings, doc) {
    if (!options.outline) return;
    const levels = headings.map((h) => Number(h.tagName[1]));
    const entries = headings.filter((h, i) => levels[i] >= 2 || levels.filter((l) => l === 1).length > 1);
    if (entries.length < 3) return;
    const top = Math.min(...entries.map((h) => Number(h.tagName[1])));
    const nav = document.createElement('nav');
    nav.className = 'outline';
    nav.innerHTML = '<p class="title">On This Page</p>' + entries.map((h) => {
      const depth = Math.min(4, Number(h.tagName[1]) - top + 2);
      return `<a href="#${encodeURIComponent(h.id)}" class="d${depth}">${esc(h.textContent)}</a>`;
    }).join('');
    doc.appendChild(nav);
    doc.classList.add('has-outline');

    const links = $$('a', nav);
    let ticking = false;
    function spy() {
      ticking = false;
      let active = 0;
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].getBoundingClientRect().top < 120) active = i; else break;
      }
      if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 4) active = entries.length - 1;
      links.forEach((a, i) => a.classList.toggle('active', i === active));
    }
    window.addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(spy); } }, { passive: true });
    spy();
  }

  function frontMatter(text) {
    const match = text.match(/^(?:---|\+\+\+)[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\+\+\+|\.\.\.)[ \t]*(?:\r?\n|$)/);
    if (!match) return { body: text, html: '' };
    const body = text.slice(match[0].length);
    if (!options.frontMatter) return { body, html: '' };
    const rows = [];
    let current = null;
    match[1].split(/\r?\n/).forEach((line) => {
      const pair = line.match(/^([A-Za-z0-9_.-]+)\s*[:=]\s*(.*)$/);
      if (pair) {
        current = { key: pair[1], values: [] };
        rows.push(current);
        let value = pair[2].trim().replace(/^["']|["']$/g, '');
        if (/^\[.*\]$/.test(value)) {
          current.values = value.slice(1, -1).split(',').map((v) => v.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
          current.list = true;
        } else if (value) {
          current.values.push(value);
        }
      } else if (current && /^\s*-\s+/.test(line)) {
        current.list = true;
        current.values.push(line.replace(/^\s*-\s+/, '').replace(/^["']|["']$/g, ''));
      } else if (current && line.trim()) {
        current.values.push(line.trim());
      }
    });
    if (!rows.length) return { body, html: '' };
    const items = rows.map((r) => `<dt>${esc(r.key)}</dt><dd>${r.list ? r.values.map((v) => `<span class="chip">${esc(v)}</span>`).join('') : esc(r.values.join(' '))}</dd>`).join('');
    return { body, html: `<dl class="front-matter">${items}</dl>` };
  }

  async function renderMermaid(container) {
    if (!window.mermaid) return;
    const nodes = $$('pre.mermaid', container);
    if (!nodes.length) return;
    nodes.forEach((n) => { n.dataset.source = n.dataset.source || n.textContent; });
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      ...mermaidTheme(),
    });
    try { await mermaid.run({ nodes, suppressErrors: true }); } catch (e) { post('log', 'mermaid: ' + e); }
  }

  /** The diagram theme from the page's --mm-* variables (DiagramTheme.swift), for the current appearance. */
  function mermaidTheme() {
    const style = getComputedStyle(html);
    const read = (name) => style.getPropertyValue('--mm-' + name).trim();
    const themeVariables = { fontSize: '13px', darkMode: read('dark') === '1' };
    read('keys').split(/\s+/).forEach((key) => { const value = /^\w+$/.test(key) && read(key); if (value) themeVariables[key] = value; });
    return { theme: read('theme') || 'neutral', themeVariables };
  }

  /** Redraws diagrams when the appearance or the diagram theme changes. */
  function rerenderMermaidOnAppearanceChange(container) {
    let current = JSON.stringify(mermaidTheme());
    const rerender = () => {
      const next = JSON.stringify(mermaidTheme());
      if (next === current) return;
      current = next;
      $$('pre.mermaid', container).forEach((n) => {
        n.removeAttribute('data-processed');
        n.textContent = n.dataset.source || '';
      });
      renderMermaid(container);
    };
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', rerender);
    applyCallbacks.push(rerender);
  }

  async function renderMarkdown() {
    html.classList.add('kind-markdown');
    const { body, html: meta } = frontMatter(payload.text.replace(/^\ufeff/, ''));
    if (!body.trim() && !meta) return empty('Empty document');
    await markdownDocument(body, { prefix: (payload.truncated ? notice('Showing the beginning of a very large document.') : '') + meta });
  }

  /** Renders Markdown as a reading document (sanitised, highlighted, outlined) inside `container`.
      Modules use it for anything that becomes prose: Org, AsciiDoc, EPUB chapters… */
  async function markdownDocument(text, { prefix = '', container = root, outline = true } = {}) {
    const md = createMarkdown();
    const doc = document.createElement('div');
    doc.className = 'doc';
    const article = document.createElement('article');
    const template = document.createElement('template');
    template.innerHTML = prefix + md.render(text);
    sanitize(template.content);
    article.appendChild(template.content);
    doc.appendChild(article);
    container.appendChild(doc);

    const headings = enhanceMarkdown(article);
    if (outline) buildOutline(headings, doc);
    if (options.diagrams) {
      await Promise.race([renderMermaid(article), new Promise((r) => setTimeout(r, 1500))]);
      rerenderMermaidOnAppearanceChange(article);
    }
    return article;
  }

  // ------------------------------------------------------------------ Diff

  function parseDiff(text) {
    const lines = text.replace(/\r\n?/g, '\n').split('\n');
    const files = [];
    const preamble = [];
    let file = null;
    let oldLine = 0;
    let newLine = 0;

    function startFile() {
      file = { from: null, to: null, status: 'modified', rows: [], added: 0, removed: 0, binary: false, notes: [] };
      files.push(file);
    }
    function clean(path) {
      if (!path || path === '/dev/null') return path;
      return path.replace(/^"|"$/g, '').replace(/\t.*$/, '').replace(/^[ab]\//, '');
    }

    // Lines still owed by the current hunk. Inside a hunk every line is content, so a removed
    // "-- " line or a "--- " line can never be mistaken for a header, and trailing text
    // (format-patch signatures) is never counted as a change.
    let oldLeft = 0;
    let newLeft = 0;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (file && (oldLeft > 0 || newLeft > 0)) {
        const c = line[0];
        if (c === '+') { file.rows.push({ type: 'add', n: newLine++, text: line.slice(1) }); file.added++; newLeft--; }
        else if (c === '-') { file.rows.push({ type: 'del', o: oldLine++, text: line.slice(1) }); file.removed++; oldLeft--; }
        else if (c === ' ' || line === '') { file.rows.push({ type: 'ctx', o: oldLine++, n: newLine++, text: line.slice(1) }); oldLeft--; newLeft--; }
        else if (c === '\\') { file.rows.push({ type: 'meta', text: line.slice(2) }); }
        else { oldLeft = 0; newLeft = 0; i--; }
        continue;
      }
      if (file && line[0] === '\\') { file.rows.push({ type: 'meta', text: line.slice(2) }); continue; }
      if (line.startsWith('diff --git ')) {
        startFile();
        const m = line.match(/^diff --git "?a\/(.+?)"? "?b\/(.+?)"?$/);
        if (m) { file.from = m[1]; file.to = m[2]; }
        continue;
      }
      if (line.startsWith('--- ') && lines[i + 1] && lines[i + 1].startsWith('+++ ')) {
        if (!file || file.rows.length) startFile();
        const from = clean(line.slice(4));
        const to = clean(lines[i + 1].slice(4));
        file.from = from === '/dev/null' ? file.from : from;
        file.to = to === '/dev/null' ? file.to : to;
        if (from === '/dev/null') file.status = 'added';
        if (to === '/dev/null') file.status = 'deleted';
        i += 1;
        continue;
      }
      if (!file) { preamble.push(line); continue; }
      if (line.startsWith('@@')) {
        const m = line.match(/^@@+ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@+ ?(.*)$/);
        if (m) {
          oldLine = Number(m[1]);
          newLine = Number(m[3]);
          oldLeft = m[2] === undefined ? 1 : Number(m[2]);
          newLeft = m[4] === undefined ? 1 : Number(m[4]);
        }
        file.rows.push({ type: 'hunk', text: line });
        continue;
      }
      if (!file.rows.length) {
        if (/^new file mode/.test(line)) { file.status = 'added'; continue; }
        if (/^deleted file mode/.test(line)) { file.status = 'deleted'; continue; }
        if (/^rename from /.test(line)) { file.status = 'renamed'; file.from = line.slice(12); continue; }
        if (/^rename to /.test(line)) { file.status = 'renamed'; file.to = line.slice(10); continue; }
        if (/^Binary files /.test(line) || line === 'GIT binary patch') { file.binary = true; continue; }
        if (/^(old mode|new mode)/.test(line)) { file.notes.push(line); continue; }
      }
      // Anything else between hunks (index lines, signatures, trailing text) is not a change.
    }
    files.forEach((f) => { if (f.from === f.to && f.status === 'renamed') f.status = 'modified'; });
    return { files, preamble };
  }

  function diffBar(added, removed) {
    const total = added + removed;
    if (!total) return '';
    let a = Math.round((added / total) * 5);
    if (added && !a) a = 1;
    if (removed && a === 5) a = 4;
    const d = Math.min(5 - a, removed ? Math.max(1, Math.round((removed / total) * 5)) : 0);
    let out = '';
    for (let i = 0; i < 5; i++) out += `<i class="${i < a ? 'a' : i < a + d ? 'd' : ''}"></i>`;
    return `<span class="bar">${out}</span>`;
  }

  /** Splits `git log -p`, `git show` and multi-patch mailboxes into one chunk per commit. */
  function splitCommits(text) {
    const lines = text.replace(/\r\n?/g, '\n').split('\n');
    const starts = [];
    lines.forEach((line, i) => {
      if (/^commit [0-9a-f]{7,64}\b/.test(line) || /^From [0-9a-f]{40} /.test(line)) starts.push(i);
    });
    if (starts.length < 1) return [text];
    const chunks = [];
    if (starts[0] > 0 && lines.slice(0, starts[0]).some((l) => l.trim())) chunks.push(lines.slice(0, starts[0]).join('\n'));
    starts.forEach((s, k) => chunks.push(lines.slice(s, k + 1 < starts.length ? starts[k + 1] : lines.length).join('\n')));
    return chunks;
  }

  /** Subject, author, date and message from a commit's header lines (git log or format-patch). */
  function commitInfo(preamble) {
    const info = {};
    const shaLine = preamble.find((l) => /^commit [0-9a-f]{7,}/.test(l)) || preamble.find((l) => /^From [0-9a-f]{40} /.test(l));
    if (shaLine) info.sha = shaLine.split(' ')[1].slice(0, 9);
    const author = preamble.find((l) => /^(Author|From): /.test(l));
    if (author) {
      const value = author.replace(/^(Author|From):\s*/, '');
      info.author = value.replace(/\s*<[^>]*>\s*$/, '') || value;
      info.email = (value.match(/<([^>]*)>/) || [])[1];
    }
    const date = preamble.find((l) => /^(Date|AuthorDate):\s/.test(l));
    if (date) {
      const raw = date.replace(/^(Date|AuthorDate):\s*/, '');
      const parsed = new Date(raw.replace(/^(\w{3}) (\w{3}) (\d+) (\d+:\d+:\d+) (\d{4}) ([+-]\d{4})$/, '$2 $3 $5 $4 GMT$6'));
      info.date = isNaN(parsed) ? raw : parsed.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
    }
    const subject = preamble.find((l) => /^Subject: /.test(l));
    let body = [];
    if (subject) {
      info.subject = subject.replace(/^Subject:\s*(\[[^\]]*\]\s*)?/, '');
      const from = preamble.indexOf(subject) + 1;
      const stop = preamble.findIndex((l, i) => i > from && /^---$/.test(l));
      body = preamble.slice(from, stop > 0 ? stop : undefined);
    } else {
      // git log: the message is indented by four spaces after the headers.
      const message = preamble.filter((l) => /^    /.test(l)).map((l) => l.slice(4));
      info.subject = (message.find((l) => l.trim()) || '').trim();
      body = message.slice(message.findIndex((l) => l.trim()) + 1);
    }
    info.message = body.join('\n').trim();
    return info;
  }

  function commitHeader(info) {
    if (!info.subject && !info.sha) return '';
    const meta = [info.sha && `<span class="sha">${esc(info.sha)}</span>`,
      info.author && `<span title="${esc(info.email || '')}">${esc(info.author)}</span>`,
      info.date && `<span>${esc(info.date)}</span>`].filter(Boolean).join('');
    return `<header class="commit">${info.subject ? `<h1 class="diff-title">${esc(info.subject)}</h1>` : ''}`
      + (meta ? `<div class="commit-meta">${meta}</div>` : '')
      + (info.message ? `<p class="diff-message">${esc(info.message)}</p>` : '') + '</header>';
  }

  function fileSection(f) {
    const path = f.to || f.from || 'file';
    const ext = (path.split('/').pop().split('.').pop() || '').toLowerCase();
    const lang = (payload.diffLanguages || {})[ext] || ext;
    const pathHTML = f.status === 'renamed' && f.from && f.from !== f.to
      ? `<span class="old">${esc(f.from)} → </span>${esc(f.to)}`
      : esc(path);
    const badge = f.status !== 'modified' ? `<span class="badge ${f.status}">${f.status}</span>` : '';
    let body = '';
    if (f.binary) body = '<div class="file-note">Binary file not shown</div>';
    else if (!f.rows.length) body = `<div class="file-note">${f.notes.length ? esc(f.notes.join(' · ')) : 'No content changes'}</div>`;
    else {
      const rows = f.rows.map((r) => {
        if (r.type === 'hunk') return `<tr class="hunk"><td class="o"></td><td class="n"></td><td colspan="2" class="c">${esc(r.text)}</td></tr>`;
        if (r.type === 'meta') return `<tr class="meta"><td class="o"></td><td class="n"></td><td class="s"></td><td class="c">${esc(r.text)}</td></tr>`;
        const sign = r.type === 'add' ? '+' : r.type === 'del' ? '−' : '';
        const cls = r.type === 'ctx' ? '' : r.type;
        return `<tr class="${cls}"><td class="o">${r.o || ''}</td><td class="n">${r.n || ''}</td><td class="s">${sign}</td><td class="c">${highlight(r.text, lang) || ' '}</td></tr>`;
      }).join('');
      body = `<div class="file-body"><table class="lines">${rows}</table></div>`;
    }
    return `<section class="file"><header class="file-header"><span class="path">${pathHTML}</span>${badge}<span class="stat"><span class="add-n">+${f.added}</span><span class="del-n">−${f.removed}</span>${diffBar(f.added, f.removed)}</span></header>${body}</section>`;
  }

  function summary(files, commits) {
    const added = files.reduce((s, f) => s + f.added, 0);
    const removed = files.reduce((s, f) => s + f.removed, 0);
    const lead = commits > 1 ? `<span><b>${commits}</b> commits</span>` : '';
    return `<div class="diff-summary">${lead}<span><b>${files.length}</b> ${files.length === 1 ? 'file' : 'files'} changed</span><span class="add-n">+${added.toLocaleString()}</span><span class="del-n">−${removed.toLocaleString()}</span></div>`;
  }

  function renderDiff() {
    html.classList.add('kind-diff');
    const commits = splitCommits(payload.text).map((chunk) => {
      const parsed = parseDiff(chunk);
      return { files: parsed.files, info: commitInfo(parsed.preamble) };
    }).filter((c) => c.files.length || c.info.subject);
    const allFiles = commits.flatMap((c) => c.files);
    if (!allFiles.length) {
      payload.language = 'diff';
      html.classList.remove('kind-diff');
      return renderCode();
    }
    let out = '';
    if (commits.length === 1) {
      out = commitHeader(commits[0].info) + summary(allFiles, 1) + allFiles.map(fileSection).join('');
    } else {
      out = summary(allFiles, commits.length) + commits.map((c) =>
        `<article class="commit-block">${commitHeader(c.info)}${c.files.length > 1 ? summary(c.files, 1) : ''}${c.files.map(fileSection).join('')}</article>`).join('');
    }
    root.innerHTML = `<div class="diff">${out}</div>`;
  }

  // ------------------------------------------------------------------ Notebook

  function joinSource(value) { return Array.isArray(value) ? value.join('') : (value || ''); }
  const stripAnsi = (s) => s.replace(/\u001b\[[0-9;]*[A-Za-z]/g, '');

  function renderNotebook() {
    html.classList.add('kind-notebook');
    let nb;
    try { nb = JSON.parse(payload.text); } catch (e) {
      payload.language = 'json';
      html.classList.remove('kind-notebook');
      return renderCode();
    }
    const meta = nb.metadata || {};
    const lang = (meta.kernelspec && meta.kernelspec.language) || (meta.language_info && meta.language_info.name) || 'python';
    const cells = nb.cells || (nb.worksheets && nb.worksheets[0] && nb.worksheets[0].cells) || [];
    const md = createMarkdown();

    const out = cells.map((cell) => {
      const type = cell.cell_type;
      let source = joinSource(cell.source !== undefined ? cell.source : cell.input);
      if (type === 'markdown') {
        if (cell.attachments) {
          source = source.replace(/attachment:([^\s)]+)/g, (m, name) => {
            const data = cell.attachments[name];
            const mime = data && Object.keys(data)[0];
            return mime ? `data:${mime};base64,${joinSource(data[mime]).replace(/\s/g, '')}` : m;
          });
        }
        return `<div class="cell markdown"><div class="prompt"></div><div class="body">${md.render(source)}</div></div>`;
      }
      if (type === 'raw') return `<div class="cell raw"><div class="prompt"></div><div class="output"><pre>${esc(source)}</pre></div></div>`;
      const count = cell.execution_count != null ? cell.execution_count : cell.prompt_number;
      const input = `<div class="cell code"><div class="prompt">[${count != null ? count : ' '}]</div><div class="body">${codeBlockHTML(source || ' ', lang)}</div></div>`;
      const outputs = (cell.outputs || []).map((o) => renderOutput(o, md)).filter(Boolean).join('');
      return input + (outputs ? `<div class="outputs">${outputs}</div>` : '');
    }).join('');

    const template = document.createElement('template');
    template.innerHTML = `<div class="notebook">${out || '<div class="empty">Empty notebook</div>'}</div>`;
    sanitize(template.content);
    root.appendChild(template.content);
    const article = $('.notebook');
    $$('.cell.markdown .body').forEach((body) => {
      const wrapper = document.createElement('article');
      while (body.firstChild) wrapper.appendChild(body.firstChild);
      body.appendChild(wrapper);
      enhanceMarkdown(wrapper);
    });
    if (options.diagrams) renderMermaid(article);
  }

  function renderOutput(o, md) {
    const type = o.output_type;
    const prompt = (type === 'execute_result' && o.execution_count != null) ? `<div class="prompt out">[${o.execution_count}]</div>` : '<div class="prompt out"></div>';
    if (type === 'stream') {
      return `<div class="output">${prompt}<pre class="${o.name === 'stderr' ? 'stderr' : ''}">${esc(stripAnsi(joinSource(o.text)))}</pre></div>`;
    }
    if (type === 'error' || type === 'pyerr') {
      const trace = (o.traceback || []).map(stripAnsi).join('\n') || `${o.ename}: ${o.evalue}`;
      return `<div class="output">${prompt}<pre class="error">${esc(trace)}</pre></div>`;
    }
    const data = o.data || o;
    if (data['image/png']) return `<div class="output">${prompt}<div><img src="data:image/png;base64,${joinSource(data['image/png']).replace(/\s/g, '')}"></div></div>`;
    if (data['image/jpeg']) return `<div class="output">${prompt}<div><img src="data:image/jpeg;base64,${joinSource(data['image/jpeg']).replace(/\s/g, '')}"></div></div>`;
    if (data['image/svg+xml']) return `<div class="output">${prompt}<div><img src="data:image/svg+xml;charset=utf-8,${encodeURIComponent(joinSource(data['image/svg+xml']))}"></div></div>`;
    if (data['text/html']) return `<div class="output">${prompt}<div class="html">${joinSource(data['text/html'])}</div></div>`;
    if (data['text/markdown']) return `<div class="output">${prompt}<div class="html">${md.render(joinSource(data['text/markdown']))}</div></div>`;
    if (data['text/latex'] && window.katex) {
      const tex = joinSource(data['text/latex']).trim().replace(/^\$\$?|\$\$?$/g, '');
      return `<div class="output">${prompt}<div class="math-block">${katexHTML(tex, true)}</div></div>`;
    }
    if (data['application/json']) return `<div class="output">${prompt}<pre>${esc(JSON.stringify(data['application/json'], null, 2))}</pre></div>`;
    if (data['text/plain']) return `<div class="output">${prompt}<pre>${esc(stripAnsi(joinSource(data['text/plain'])))}</pre></div>`;
    return '';
  }

  // ------------------------------------------------------------------ Live styling

  const renderers = {};
  const enhancers = [];
  const applyCallbacks = [];
  let moduleData;

  window.greece = {
    /** Applies appearance changes without re-rendering (used by the app's live preview). */
    apply(config) {
      if (config.themeCSS != null) $('#theme').textContent = config.themeCSS;
      if (config.varsCSS != null) $('#vars').textContent = config.varsCSS;
      if (config.classes) Object.keys(config.classes).forEach((k) => html.classList.toggle(k, !!config.classes[k]));
      applyCallbacks.forEach((callback) => { try { callback(config); } catch (e) { post('log', 'apply: ' + e); } });
    },

    /** A module's renderer for its own document kind: `render(data, kit)`, may be async. */
    register(kind, render) { renderers[kind] = render; },

    /** Adds features to pages of a kind ('code', 'markdown', 'diff', 'notebook', a module's kind, or '*')
        after they render and before they're shown: `enhance(root, kit)`, may be async. */
    enhance(kind, enhance) { enhancers.push({ kind, enhance }); },

    /** What module renderers share with Greece's own: escaping, highlighting, Markdown, notices. */
    kit: {
      $, $$, esc, post, root, payload, options,
      highlight, languageTitle, splitHighlighted, copyText, notice, empty, tick, afterReady,
      katexHTML, createMarkdown, sanitize, markdownDocument, renderCode,
      /** The module's data (the JSON GreeceKit embedded for this page), parsed once. */
      data() {
        if (moduleData === undefined) {
          const element = $('#data');
          moduleData = element ? JSON.parse(element.textContent) : null;
        }
        return moduleData;
      },
      /** Runs after live settings changes (theme, appearance), e.g. to recolour a canvas. */
      onApply(callback) { applyCallbacks.push(callback); },
    },
  };

  // ------------------------------------------------------------------ Boot

  async function boot() {
    try {
      const custom = renderers[payload.kind];
      if (custom) {
        html.classList.add('kind-' + payload.kind);
        await custom(window.greece.kit.data(), window.greece.kit);
      } else {
        switch (payload.kind) {
          case 'markdown': await renderMarkdown(); break;
          case 'diff': renderDiff(); break;
          case 'notebook': renderNotebook(); break;
          default: renderCode();
        }
      }
    } catch (e) {
      post('log', 'render failed: ' + (e && e.stack || e));
      payload.language = null;
      html.className = html.className.replace(/kind-[\w-]+/g, '');
      root.innerHTML = '';
      renderCode();
    }
    for (const { kind, enhance } of enhancers) {
      if (kind !== '*' && kind !== payload.kind) continue;
      try { await enhance(root, window.greece.kit); } catch (e) { post('log', 'enhancer failed: ' + (e && e.stack || e)); }
    }
    const fonts = document.fonts ? document.fonts.ready : Promise.resolve();
    await Promise.race([fonts, new Promise((r) => setTimeout(r, 400))]);
    // Back where you were (after a save, or from last time), before anything is shown.
    if (options.scroll) window.scrollTo(options.scroll[0] || 0, options.scroll[1] || 0);
    // Report where the reader is. No timers: Quick Look's pages count as hidden and their timers
    // barely run, so report from the events themselves, at most every 50 ms, plus where it ends.
    let lastReport = 0;
    const report = () => { lastReport = Date.now(); post('scroll', [window.scrollX, window.scrollY]); };
    window.addEventListener('scroll', () => { if (Date.now() - lastReport >= 50) report(); }, { passive: true });
    for (const name of ['scrollend', 'mouseleave', 'pointerup', 'keyup']) window.addEventListener(name, report, { passive: true });
    // Quick Look prepares previews before they are on screen, where animation frames never fire.
    post('ready', { height: document.body.scrollHeight });
    tick().then(() => readyCallbacks.forEach((callback) => callback()));
  }

  // Module scripts load after this one; start once they have all run and registered.
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();
