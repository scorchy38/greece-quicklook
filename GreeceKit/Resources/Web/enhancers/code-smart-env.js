/* Greece — .env files: values hidden until you reveal them (one line, or all), comments kept,
   duplicate keys and empty values flagged, a count of keys in the card.

   Secrets never sit in the page: the highlighted code is rebuilt with masks, the page's copy
   of the file is replaced by the masked text, and revealed values come from memory only. The
   same rules (EnvMask in Swift) keep Finder thumbnails masked. */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  const MASK = '••••••••';

  function isEnvName(lower) {
    return /^\.env(\.[^/]*)?$/.test(lower) || /\.env$/.test(lower) || lower === '.flaskenv' ||
      lower === '.dev.vars' || /^\.?env\.(local|example|sample|template|dist|defaults?|development|production|staging|test)$/.test(lower);
  }

  const ASSIGNMENT = /^([ \t]*)(export[ \t]+)?([A-Za-z_][A-Za-z0-9_.-]*)([ \t]*=[ \t]*)(.*)$/;
  const COMMENTED = /^([ \t]*#[ \t]*)(export[ \t]+)?([A-Za-z_][A-Za-z0-9_.-]*)(=)(.*)$/;

  /** Splits a raw value into the value itself and a trailing ` # comment` (unquoted values only). */
  function splitComment(raw) {
    if (/^["'`]/.test(raw)) {
      const quote = raw[0];
      let i = 1;
      while (i < raw.length && raw[i] !== quote) i += raw[i] === '\\' && quote === '"' ? 2 : 1;
      const end = Math.min(i + 1, raw.length);
      return { value: raw.slice(0, end), rest: raw.slice(end) };
    }
    const hash = raw.search(/[ \t]#/);
    return hash < 0 ? { value: raw.replace(/[ \t]+$/, ''), rest: raw.slice(raw.replace(/[ \t]+$/, '').length) } : { value: raw.slice(0, hash), rest: raw.slice(hash) };
  }

  /**
   * Parses dotenv text into lines: { type: 'blank'|'comment'|'entry'|'commented'|'continuation'|'other',
   * indent, export, key, eq, value, rest, secret, entry }. `secret` is the text to hide. Quoted
   * values may span lines; their continuation lines are secret too.
   */
  function parse(text) {
    const lines = String(text).replace(/\r\n?/g, '\n').split('\n');
    if (lines.length && lines[lines.length - 1] === '') lines.pop();
    const out = [];
    const seen = new Map();
    const entries = [];
    let open = null; // the quote of a value still running onto later lines
    for (let n = 0; n < lines.length; n++) {
      const line = lines[n];
      if (open) {
        const close = line.indexOf(open.quote);
        out.push({ type: 'continuation', secret: close < 0 ? line : line.slice(0, close + 1), rest: close < 0 ? '' : line.slice(close + 1), entry: open.entry });
        if (close >= 0) open = null;
        continue;
      }
      if (!line.trim()) { out.push({ type: 'blank', text: line }); continue; }
      const commented = COMMENTED.exec(line);
      if (commented && commented[5].trim()) {
        out.push({ type: 'commented', indent: commented[1], export: commented[2] || '', key: commented[3], eq: commented[4], secret: commented[5] });
        continue;
      }
      if (/^[ \t]*#/.test(line)) { out.push({ type: 'comment', text: line }); continue; }
      const match = ASSIGNMENT.exec(line);
      if (!match) { out.push({ type: 'other', secret: line }); continue; }
      const { value, rest } = splitComment(match[5]);
      const entry = { key: match[3], line: n + 1, empty: false, duplicateOf: 0 };
      const quote = /^["'`]/.test(value) ? value[0] : '';
      const unterminated = quote && (value.length < 2 || value[value.length - 1] !== quote || (quote === '"' && /(^|[^\\])(\\\\)*\\"$/.test(value) && value.length > 2));
      const bare = quote && !unterminated ? value.slice(1, -1) : value;
      entry.empty = !unterminated && !bare.trim();
      if (seen.has(entry.key)) entry.duplicateOf = seen.get(entry.key);
      else seen.set(entry.key, entry.line);
      entries.push(entry);
      out.push({ type: 'entry', indent: match[1], export: match[2] || '', key: match[3], eq: match[4], secret: value, rest, entry });
      if (unterminated) open = { quote, entry };
    }
    const keys = new Set(entries.map((e) => e.key));
    return {
      lines: out,
      entries,
      keyCount: keys.size,
      duplicates: entries.filter((e) => e.duplicateOf),
      empties: entries.filter((e) => e.empty),
    };
  }

  /** The file as text with every secret replaced by the mask (what thumbnails and copies of the page see). */
  function masked(parsed) {
    return parsed.lines.map((l) => {
      switch (l.type) {
        case 'blank': case 'comment': return l.text;
        case 'commented': return `${l.indent}${l.export}${l.key}${l.eq}${MASK}`;
        case 'continuation': return (l.secret ? MASK : '') + l.rest;
        case 'other': return MASK;
        default: return `${l.indent}${l.export}${l.key}${l.eq}${l.secret ? MASK : ''}${l.rest}`;
      }
    }).join('\n');
  }

  function enhance({ root, kit, Smart }) {
    const esc = Smart.esc;
    const parsed = parse(kit.payload.text);
    const secrets = [];
    const secret = (value, cls = '') => {
      secrets.push(value);
      return `<span class="env-secret${cls}" data-i="${secrets.length - 1}" role="button" tabindex="0" title="${esc(kit.t('Reveal value'))}">${MASK}</span>`;
    };

    const rows = parsed.lines.map((l, index) => {
      let body;
      switch (l.type) {
        case 'blank': body = ''; break;
        case 'comment': body = `<span class="hljs-comment">${esc(l.text)}</span>`; break;
        case 'commented':
          body = `<span class="hljs-comment">${esc(l.indent)}${esc(l.export)}${esc(l.key)}${esc(l.eq)}</span>${secret(l.secret, ' in-comment')}`;
          break;
        case 'continuation':
          body = (l.secret ? secret(l.secret) : '') + (l.rest ? `<span class="hljs-comment">${esc(l.rest)}</span>` : '');
          break;
        case 'other':
          body = secret(l.secret, ' whole-line');
          break;
        default: {
          const e = l.entry;
          const flags = [];
          if (e.duplicateOf) flags.push(`<span class="env-flag is-duplicate" title="${esc(kit.t('Also set on line {0}; this value wins', e.duplicateOf))}">${esc(kit.t('Duplicate'))}</span>`);
          if (e.empty) flags.push(`<span class="env-flag is-empty">${esc(kit.t('Empty'))}</span>`);
          const value = l.secret && !e.empty ? secret(l.secret) : esc(l.secret);
          body = `${esc(l.indent)}${l.export ? `<span class="hljs-keyword">${esc(l.export)}</span>` : ''}<span class="env-key${e.duplicateOf ? ' duplicate' : ''}">${esc(l.key)}</span><span class="env-eq">${esc(l.eq)}</span>${value}${l.rest ? `<span class="hljs-comment">${esc(l.rest)}</span>` : ''}${flags.join('')}`;
        }
      }
      return `<div class="ln" data-n="${index + 1}">${body}</div>`;
    });

    // Replace the page's copies of the file: the rendered code, and the payload text.
    const old = root.querySelector('.code-view');
    const view = document.createElement('div');
    view.className = 'code-view env-view';
    let html = '';
    for (let i = 0; i < rows.length; i += 400) html += `<div class="chunk${rows.length > 2400 ? ' lazy' : ''}">${rows.slice(i, i + 400).join('')}</div>`;
    view.innerHTML = html;
    old.replaceWith(view);
    kit.payload.text = masked(parsed);
    const payloadNode = document.getElementById('payload');
    if (payloadNode) payloadNode.textContent = '{}';

    const reveal = (node, on) => {
      const i = Number(node.dataset.i);
      if (on) {
        node.textContent = secrets[i];
        node.classList.add('revealed');
        node.title = kit.t('Hide value');
      } else {
        node.textContent = MASK;
        node.classList.remove('revealed');
        node.title = kit.t('Reveal value');
      }
    };
    view.addEventListener('click', (event) => {
      const node = event.target.closest('.env-secret');
      if (node) reveal(node, !node.classList.contains('revealed'));
    });
    view.addEventListener('keydown', (event) => {
      const node = event.target.closest('.env-secret');
      if (node && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); reveal(node, !node.classList.contains('revealed')); }
    });

    // Card
    const issues = [];
    parsed.duplicates.slice(0, 50).forEach((e) => issues.push(`<li><span class="env-flag is-duplicate">${esc(kit.t('Duplicate'))}</span><code>${esc(e.key)}</code><span class="smart-dim">${esc(kit.t('line {0}, first set on line {1}', e.line, e.duplicateOf))}</span></li>`));
    parsed.empties.slice(0, 50).forEach((e) => issues.push(`<li><span class="env-flag is-empty">${esc(kit.t('Empty'))}</span><code>${esc(e.key)}</code><span class="smart-dim">${esc(kit.t('line {0}', e.line))}</span></li>`));
    const template = /\.(example|sample|template|dist)$/.test(kit.fileName.toLowerCase());
    const subtitleParts = [kit.plural(parsed.keyCount, '{0} keys')];
    if (parsed.duplicates.length) subtitleParts.push(kit.plural(parsed.duplicates.length, '{0} duplicates'));
    if (parsed.empties.length) subtitleParts.push(kit.plural(parsed.empties.length, '{0} empty'));
    subtitleParts.push(kit.t('Values hidden'));
    const card = Smart.card(root, {
      kind: 'env',
      icon: 'key',
      title: template ? kit.t('Environment Template') : kit.t('Environment Variables'),
      subtitle: subtitleParts.join(' · '),
      body: issues.length ? `<ul class="env-issues">${Smart.more(issues, 6)}</ul>` : '',
      actions: secrets.length ? `<button type="button" class="smart-button env-toggle" aria-pressed="false">${esc(kit.t('Reveal All'))}</button>` : '',
    });
    const toggle = card.querySelector('.env-toggle');
    const subtitle = card.querySelector('.smart-subtitle');
    if (toggle) {
      toggle.addEventListener('click', () => {
        const on = toggle.getAttribute('aria-pressed') !== 'true';
        view.querySelectorAll('.env-secret').forEach((node) => reveal(node, on));
        toggle.setAttribute('aria-pressed', on ? 'true' : 'false');
        toggle.textContent = on ? kit.t('Hide All') : kit.t('Reveal All');
        if (subtitle) subtitle.textContent = subtitleParts.slice(0, -1).concat(on ? kit.t('Values shown') : kit.t('Values hidden')).join(' · ');
      });
    }
  }

  (Smart.kinds = Smart.kinds || []).push({
    id: 'env',
    order: 1,
    detect(file) {
      if (isEnvName(file.lower)) return true;
      // direnv files that are only exports.
      if (file.lower === '.envrc') {
        const lines = file.head.split('\n').filter((l) => l.trim() && !/^\s*#/.test(l));
        return lines.length > 0 && lines.filter((l) => ASSIGNMENT.test(l)).length / lines.length >= 0.8;
      }
      return false;
    },
    parse,
    masked: (text) => masked(parse(text)),
    enhance,
  });
})(typeof window !== 'undefined' ? window : globalThis);
