/* Greece — logs: every line coloured by level (plain text, JSON lines, logfmt, syslog, glog,
   logcat, Ruby, Python, nginx/Apache…), repeated lines collapsed (×12), a filter bar with counts,
   next/previous error, an overview strip of errors and warnings beside the scrollbar, and a card
   with the time span and the most frequent errors. Built for 100k-line files: one pass of
   regexes, rows streamed in chunks the browser only lays out when they're on screen. */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  /** The page's strings (Smart.kit), looked up when used: code-smart.js, which sets it, may load after this file. */
  const kit = new Proxy({}, { get: (_, name) => Smart.kit[name] });

  const NONE = 0; const TRACE = 1; const DEBUG = 2; const INFO = 3; const WARN = 4; const ERROR = 5;
  const LETTER = ['n', 't', 'd', 'i', 'w', 'e'];
  /** Each level's name on its filter chip and in the card. */
  const NAMES = [() => kit.t('Other'), () => kit.t('Trace'), () => kit.t('Debug'), () => kit.t('Info'), () => kit.t('Warnings'), () => kit.t('Errors')];

  const WORDS = {
    FATAL: ERROR, CRITICAL: ERROR, CRIT: ERROR, EMERG: ERROR, EMERGENCY: ERROR, ALERT: ERROR, PANIC: ERROR,
    SEVERE: ERROR, ERROR: ERROR, ERR: ERROR, EROR: ERROR, FAULT: ERROR, FAIL: ERROR, FAILURE: ERROR,
    WARN: WARN, WARNING: WARN, WRN: WARN,
    NOTICE: INFO, INFO: INFO, INF: INFO, INFORMATION: INFO, DEFAULT: INFO,
    DEBUG: DEBUG, DBG: DEBUG, CONFIG: DEBUG, FINE: DEBUG,
    TRACE: TRACE, TRC: TRACE, VERBOSE: TRACE, FINER: TRACE, FINEST: TRACE,
  };
  const LETTERS = { V: TRACE, D: DEBUG, I: INFO, W: WARN, E: ERROR, F: ERROR, A: ERROR, U: INFO };

  const STRUCTURED = /(?:^|[\s,{])"?(?:level|lvl|severity|loglevel|log\.level|levelname|@l|@level)"?\s*[=:]\s*"?([A-Za-z]{3,11}|\d{1,2})\b"?/i;
  const UPPER = /(^|[\s[(<|:"'=/.])(FATAL|CRITICAL|CRIT|EMERG(?:ENCY)?|ALERT|PANIC|SEVERE|ERROR|ERR|EROR|FAULT|WARN(?:ING)?|WRN|NOTICE|INFO(?:RMATION)?|INF|DEBUG|DBG|TRACE|TRC|VERBOSE|FINEST|FINER|FINE)(?=$|[\s\]):>|,.;"'=/-])/;
  const BRACKETED = /[[<(|]\s*(fatal|critical|crit|emerg|alert|panic|error|err|warn|warning|notice|info|debug|trace|verbose)\s*[\]>)|]/i;
  const TITLE = /^(Error|Warning|Fatal|Panic|Notice|Info|Debug|Trace)(?=[:!\s])/;
  const MACOS = /\s0x[0-9a-f]+\s+(Default|Info|Debug|Error|Fault)\s+0x/;
  const GLOG = /^([IWEF])\d{4} \d\d:\d\d:\d\d/;
  const LOGCAT = /^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+\d+\s+\d+\s+([VDIWEFA])\s/;
  const LOGCAT_BRIEF = /^([VDIWEFA])\/[^(:]{1,80}\(\s*\d+\):/;
  const RUBY = /^([DIWEFU]), \[/;
  const SYSLOG_PRI = /^<(\d{1,3})>/;
  const ACCESS = /"(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|CONNECT|TRACE|PROPFIND) [^"]{0,2000}" (\d{3}) /;
  const TS = /^\[?(?:\d{4}[-/.]\d\d[-/.]\d\d(?:[T ]\d\d:\d\d(?::\d\d(?:[.,]\d{1,9})?)?(?:Z|[+-]\d\d:?\d\d)?)?|[A-Z][a-z]{2} {1,2}\d{1,2} \d\d:\d\d:\d\d(?:\.\d+)?|\d\d-\d\d \d\d:\d\d:\d\d\.\d+|\d\d:\d\d:\d\d(?:[.,]\d{1,9})?|\d{10}(?:\.\d{1,9})?)\]?/;
  const JSON_MESSAGE = /"(?:msg|message|error|err|event)"\s*:\s*"((?:[^"\\]|\\.){1,400})"/;
  const JSON_TIME = /"(?:time|timestamp|ts|@timestamp|datetime|date)"\s*:\s*"(\d{4}-\d\d-\d\d[T ][^"]{4,40})"/;
  const CONTINUATION = /^(\s|at |Caused by|Traceback|\.\.\. \d+ more|During handling|[}\]])/;

  function numericLevel(n) {
    if (n >= 50) return ERROR;
    if (n >= 40) return WARN;
    if (n >= 30) return INFO;
    if (n >= 20) return DEBUG;
    if (n >= 10) return TRACE;
    // syslog severities (0 emergency … 7 debug)
    return n <= 3 ? ERROR : n === 4 ? WARN : n <= 6 ? INFO : DEBUG;
  }

  /** The level of one line and where its level word is: [level, start, end]. */
  function classify(line) {
    const head = line.length > 240 ? line.slice(0, 240) : line;
    let m;
    if (head[0] === '{' || head.includes('level') || head.includes('severity') || head.includes('lvl')) {
      m = STRUCTURED.exec(head);
      if (m) {
        const word = m[1];
        const level = /^\d+$/.test(word) ? numericLevel(Number(word)) : WORDS[word.toUpperCase()];
        if (level) { const at = m.index + m[0].lastIndexOf(word); return [level, at, at + word.length]; }
      }
    }
    if ((m = GLOG.exec(head)) || (m = RUBY.exec(head)) || (m = LOGCAT_BRIEF.exec(head))) return [LETTERS[m[1]], 0, 1];
    if ((m = LOGCAT.exec(head))) { const at = m[0].length - 2; return [LETTERS[m[1]], at, at + 1]; }
    if ((m = SYSLOG_PRI.exec(head))) return [numericLevel(Number(m[1]) & 7), 0, m[0].length];
    if ((m = MACOS.exec(head))) { const at = m.index + m[0].indexOf(m[1]); return [WORDS[m[1].toUpperCase()], at, at + m[1].length]; }
    if ((m = UPPER.exec(head))) { const at = m.index + m[1].length; return [WORDS[m[2]], at, at + m[2].length]; }
    if ((m = BRACKETED.exec(head))) { const at = m.index + m[0].indexOf(m[1]); return [WORDS[m[1].toUpperCase()], at, at + m[1].length]; }
    if ((m = TITLE.exec(head))) return [WORDS[m[1].toUpperCase()], 0, m[1].length];
    if ((m = ACCESS.exec(line.length > 4000 ? line.slice(0, 4000) : line))) {
      const status = Number(m[1]);
      const at = m.index + m[0].length - 4;
      return [status >= 500 ? ERROR : status >= 400 ? WARN : INFO, at, at + 3];
    }
    return [NONE, 0, 0];
  }

  /** Does this text read like a log? Most non-empty lines start with a time or carry a level. */
  function looksLikeLog(text) {
    const lines = String(text).slice(0, 20000).split('\n').filter((l) => l.trim()).slice(0, 60);
    if (lines.length < 3) return false;
    let hits = 0;
    for (const line of lines) if (TS.test(line) || classify(line)[0] !== NONE) hits++;
    return hits / lines.length >= 0.6;
  }

  function formatName(lines) {
    const sample = lines.slice(0, 200).filter((l) => l.trim());
    if (!sample.length) return '';
    const share = (re) => sample.filter((l) => re.test(l)).length / sample.length;
    if (share(/^\s*\{.*\}\s*$/) > 0.6) return 'JSON Lines';
    if (share(ACCESS) > 0.6) return kit.t('Access Log');
    if (share(LOGCAT) > 0.6 || share(LOGCAT_BRIEF) > 0.6) return 'Android Logcat';
    if (share(/^(<\d{1,3}>)?[A-Z][a-z]{2} {1,2}\d{1,2} \d\d:\d\d:\d\d \S+ [^:\s]+(\[\d+\])?:/) > 0.6) return 'syslog';
    if (share(MACOS) > 0.6) return kit.t('macOS Unified Log');
    if (share(/\blevel=|\bmsg=/) > 0.6) return 'logfmt';
    return '';
  }

  function parseTime(stamp, year) {
    let s = stamp.replace(/^\[|\]$/g, '');
    if (/^\d{10}(\.\d+)?$/.test(s)) return new Date(Number(s) * 1000);
    if (/^\d{4}/.test(s)) {
      s = s.replace(/^(\d{4})[/.](\d\d)[/.](\d\d)/, '$1-$2-$3').replace(' ', 'T').replace(',', '.');
      if (/^\d{4}-\d\d-\d\d$/.test(s)) s += 'T00:00';
      const t = Date.parse(s);
      return isNaN(t) ? null : new Date(t);
    }
    if (/^[A-Z][a-z]{2} /.test(s)) {
      const t = Date.parse(`${s.replace(/\.\d+$/, '').replace(/ +/g, ' ')} ${year}`);
      return isNaN(t) ? null : new Date(t);
    }
    return null;
  }

  /** One pass over the whole log. Typed arrays keep 100k+ lines cheap. */
  function analyse(text, options = {}) {
    const lines = String(text).replace(/\r\n?/g, '\n').split('\n');
    if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
    const n = lines.length;
    const level = new Uint8Array(n);
    const own = new Uint8Array(n);  // 1 where a line starts an entry with its own level
    const lvStart = new Uint32Array(n);
    const lvEnd = new Uint32Array(n);
    const tsEnd = new Uint16Array(n);
    let stamped = 0;
    const sample = Math.min(n, 2000);
    for (let i = 0; i < sample; i++) if (TS.test(lines[i])) stamped++;
    const timestamped = sample > 0 && stamped / sample >= 0.4;

    let previous = NONE;
    for (let i = 0; i < n; i++) {
      const line = lines[i];
      const ts = TS.exec(line);
      if (ts) tsEnd[i] = Math.min(ts[0].length, 65535);
      const [lv, s, e] = line ? classify(line) : [NONE, 0, 0];
      if (lv) {
        level[i] = lv; own[i] = 1; lvStart[i] = s; lvEnd[i] = e; previous = lv;
      } else if (line && (CONTINUATION.test(line) || (timestamped && !ts))) {
        level[i] = previous;  // stack traces and wrapped messages belong to their entry
      } else {
        level[i] = NONE; previous = NONE;
      }
    }

    // Consecutive repeats (ignoring the timestamp) collapse into one row.
    const rowStart = new Uint32Array(n);
    const rowCount = new Uint32Array(n);
    let rows = 0;
    let collapsed = 0;
    const collapse = options.collapse !== false;
    for (let i = 0; i < n; i++) {
      if (collapse && rows > 0) {
        const p = rowStart[rows - 1];
        const a = lines[i];
        const b = lines[p];
        if (a.length - tsEnd[i] === b.length - tsEnd[p] && a.length > tsEnd[i] && level[i] === level[p] &&
            a.slice(tsEnd[i]) === b.slice(tsEnd[p])) {
          rowCount[rows - 1]++;
          collapsed++;
          continue;
        }
      }
      rowStart[rows] = i;
      rowCount[rows] = 1;
      rows++;
    }

    const counts = [0, 0, 0, 0, 0, 0];
    // Entries, not lines: a stack trace belongs to the error above it.
    for (let r = 0; r < rows; r++) if (own[rowStart[r]] || level[rowStart[r]] === NONE) counts[level[rowStart[r]]] += rowCount[r];

    // The most frequent error messages, with numbers and ids folded together.
    const groups = new Map();
    for (let i = 0; i < n; i++) {
      if (level[i] !== ERROR || (i > 0 && level[i - 1] === ERROR && (CONTINUATION.test(lines[i]) || (timestamped && !tsEnd[i])))) continue;
      const line = lines[i];
      let message;
      const field = line[0] === '{' && JSON_MESSAGE.exec(line.slice(0, 2000));
      if (field) message = field[1].replace(/\\(.)/g, '$1');
      else {
        message = line.slice(Math.max(tsEnd[i], lvEnd[i] > lvStart[i] && lvStart[i] >= tsEnd[i] ? lvEnd[i] : tsEnd[i]), tsEnd[i] + 400)
          .replace(/^[\s\]:|>)-]+/, '').replace(/^\[[^\]]{1,40}\]:?\s*/, '').trim();
      }
      if (!message) continue;
      // Ids, hashes and numbers vary between otherwise identical errors.
      const key = message.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '…')
        .replace(/\b0x[0-9a-f]+\b/gi, '0x…').replace(/\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{3,}\b/gi, '…').replace(/\d+/g, '#').slice(0, 160);
      const group = groups.get(key);
      if (group) group.count++;
      else if (groups.size < 5000) groups.set(key, { message: message.slice(0, 160), count: 1, line: i + 1 });
    }
    const topErrors = Array.from(groups.values()).sort((a, b) => b.count - a.count || a.line - b.line).slice(0, options.top || 3);

    let first = null;
    let last = null;
    const year = options.year || new Date().getFullYear();
    const stampOf = (i) => {
      if (tsEnd[i]) return parseTime(lines[i].slice(0, tsEnd[i]), year);
      const m = lines[i][0] === '{' && JSON_TIME.exec(lines[i].slice(0, 2000));
      return m ? parseTime(m[1], year) : null;
    };
    for (let i = 0; i < Math.min(n, 5000) && !first; i++) first = stampOf(i);
    for (let i = n - 1; i >= Math.max(0, n - 5000) && !last; i--) last = stampOf(i);

    return { lines, level, own, lvStart, lvEnd, tsEnd, rows, rowStart, rowCount, collapsed, counts, topErrors, first, last, format: formatName(lines), timestamped };
  }

  // ----------------------------------------------------------------------------- View

  const CHUNK = 400;
  const FIRST = 2000;
  const MAX_LINE = 20000;
  /** "3 Mar, 10:00" and "10:00", as the page's locale writes them. */
  const when = (d) => kit.date(d, { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' });
  const clock = (d) => kit.date(d, { timeStyle: 'short' });

  function span(a, b) {
    if (!a || !b || isNaN(a) || isNaN(b)) return '';
    const sameDay = a.toDateString() === b.toDateString();
    const range = sameDay ? `${when(a)} – ${clock(b)}` : `${when(a)} – ${when(b)}`;
    const length = Smart.duration(b - a);
    return b >= a && length ? `${range} (${length})` : range;
  }

  async function enhance({ root, kit, Smart }) {
    const esc = Smart.esc;
    const data = analyse(kit.payload.text);
    const { lines, level, own, lvStart, lvEnd, tsEnd, rows, rowStart, rowCount, counts } = data;

    const rowHTML = (r) => {
      const i = rowStart[r];
      let t = lines[i];
      let cut = '';
      if (t.length > MAX_LINE) { cut = `<span class="lg-cut">… ${esc(kit.plural(t.length - MAX_LINE, '{0} more characters'))}</span>`; t = t.slice(0, MAX_LINE); }
      const ts = tsEnd[i];
      const ls = lvStart[i];
      const le = Math.min(lvEnd[i], t.length);
      let body = ts ? `<span class="lg-ts">${esc(t.slice(0, ts))}</span>` : '';
      if (le > ls && ls >= ts) body += esc(t.slice(ts, ls)) + `<span class="lg-lv">${esc(t.slice(ls, le))}</span>` + esc(t.slice(le));
      else body += esc(t.slice(ts));
      if (rowCount[r] > 1) body += `<span class="lg-rep" title="${esc(kit.plural(rowCount[r], 'Repeated {0} times'))}">×${kit.number(rowCount[r])}</span>`;
      return `<div class="ln lg-${LETTER[level[i]]}" data-n="${i + 1}">${body}${cut}</div>`;
    };
    const chunkCount = Math.ceil(rows / CHUNK);
    // How many rows of each level every chunk holds, for exact sizes while filtered.
    const chunkLevels = Array.from({ length: chunkCount }, () => [0, 0, 0, 0, 0, 0]);
    for (let r = 0; r < rows; r++) chunkLevels[(r / CHUNK) | 0][level[rowStart[r]]]++;
    const chunkHTML = (c) => {
      let out = `<div class="lg-chunk" data-c="${c}">`;
      for (let r = c * CHUNK, end = Math.min(rows, (c + 1) * CHUNK); r < end; r++) out += rowHTML(r);
      return out + '</div>';
    };

    const old = root.querySelector('.code-view');
    const view = document.createElement('div');
    view.className = 'code-view large log-view';
    let first = '';
    const firstChunks = Math.min(chunkCount, Math.ceil(FIRST / CHUNK));
    for (let c = 0; c < firstChunks; c++) first += chunkHTML(c);
    view.innerHTML = first;
    old.replaceWith(view);
    document.documentElement.classList.add('has-log');

    const sample = view.querySelector('.ln');
    const rowHeight = sample ? sample.getBoundingClientRect().height || 20 : 20;
    const wraps = () => document.documentElement.classList.contains('wrap');
    const hidden = new Set();
    const visibleIn = (c) => chunkLevels[c].reduce((sum, count, lv) => sum + (hidden.has(lv) ? 0 : count), 0);
    const sizeChunk = (chunk) => {
      const c = Number(chunk.dataset.c);
      const count = visibleIn(c);
      chunk.classList.toggle('is-empty', count === 0);
      chunk.style.containIntrinsicHeight = (wraps() ? 'auto ' : '') + Math.max(1, count * rowHeight) + 'px';
    };
    let streamed = firstChunks;
    view.querySelectorAll('.lg-chunk').forEach(sizeChunk);
    kit.afterReady(async () => {
      while (streamed < chunkCount) {
        let html = '';
        const end = Math.min(chunkCount, streamed + 6);
        for (let c = streamed; c < end; c++) html += chunkHTML(c);
        view.insertAdjacentHTML('beforeend', html);
        for (let c = streamed; c < end; c++) sizeChunk(view.children[c]);
        streamed = end;
        await kit.tick();
      }
      drawStrip();
    });
    const rowElement = (r) => {
      const chunk = view.children[(r / CHUNK) | 0];
      return chunk ? chunk.children[r % CHUNK] : null;
    };

    // ---- Card: what this log covers.
    const facts = [];
    const levelsPresent = [ERROR, WARN, INFO, DEBUG, TRACE].filter((lv) => counts[lv]);
    levelsPresent.forEach((lv) => facts.push({ label: NAMES[lv](), value: kit.number(counts[lv]) }));
    if (data.collapsed) facts.push({ label: kit.t('Repeats folded'), value: kit.number(data.collapsed) });
    const top = data.topErrors.filter((g) => g.count > 0);
    const topHTML = top.length ? `<ol class="log-top">${top.map((g) => `<li><button type="button" class="log-jump" data-line="${g.line}"><span class="log-top-count">×${kit.number(g.count)}</span><span class="log-top-text">${esc(g.message)}</span><span class="smart-dim">${esc(kit.t('line {0}', g.line))}</span></button></li>`).join('')}</ol>` : '';
    const subtitle = [kit.plural(lines.length, '{0} lines'), span(data.first, data.last)].filter(Boolean).join(' · ');
    const card = Smart.card(root, {
      kind: 'log',
      icon: 'log',
      title: kit.t('Log'),
      label: data.format,
      subtitle,
      body: Smart.facts(facts) + (topHTML ? Smart.section(top.length === 1 ? kit.t('Most Frequent Error') : kit.t('Most Frequent Errors'), topHTML, { wide: true }) : ''),
    });

    // ---- Filter bar
    const target = counts[ERROR] ? ERROR : counts[WARN] ? WARN : 0;
    const bar = document.createElement('div');
    bar.className = 'log-bar';
    bar.setAttribute('role', 'toolbar');
    const chips = [ERROR, WARN, INFO, DEBUG, TRACE, NONE].filter((lv) => counts[lv] && (lv !== NONE || levelsPresent.length))
      .map((lv) => `<button type="button" class="log-chip lg-${LETTER[lv]}" data-level="${lv}" aria-pressed="true"><i></i>${esc(NAMES[lv]())}<b>${kit.number(counts[lv])}</b></button>`).join('');
    bar.innerHTML = `<div class="log-chips">${chips}</div>` + (target ? `<div class="log-nav"><span class="log-pos"></span>` +
      `<button type="button" class="log-step" data-step="-1" title="${esc(target === ERROR ? kit.t('Previous Error') : kit.t('Previous Warning'))} (⇧N)" aria-label="${esc(kit.t('Previous'))}"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 10 4.5-4.5 4.5 4.5"/></svg></button>` +
      `<button type="button" class="log-step next" data-step="1" title="${esc(target === ERROR ? kit.t('Next Error') : kit.t('Next Warning'))} (N)"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 6 4.5 4.5L12.5 6"/></svg><span class="label">${esc(target === ERROR ? kit.t('Next Error') : kit.t('Next Warning'))}</span></button></div>` : '');
    if (levelsPresent.length) document.body.appendChild(bar);

    const strip = document.createElement('canvas');
    strip.className = 'log-strip';
    strip.title = kit.t('Errors and warnings');
    if (counts[ERROR] || counts[WARN]) document.body.appendChild(strip);

    // Rows to step through: every row at the target level.
    const targets = [];
    if (target) for (let r = 0; r < rows; r++) if (level[rowStart[r]] === target && own[rowStart[r]]) targets.push(r);
    let position = -1;
    const pos = bar.querySelector('.log-pos');

    function rowAtViewTop() {
      const viewTop = view.getBoundingClientRect().top;
      const y = Math.max(0, -viewTop + 8);
      // Walk chunks by their laid-out heights, then rows inside the chunk.
      let acc = 0;
      for (let c = 0; c < view.children.length; c++) {
        const h = view.children[c].offsetHeight;
        if (acc + h > y) {
          const rowsIn = view.children[c].children;
          for (let k = 0; k < rowsIn.length; k++) {
            if (rowsIn[k].offsetParent === null) continue;
            if (rowsIn[k].getBoundingClientRect().bottom - viewTop > y) return c * CHUNK + k;
          }
          return (c + 1) * CHUNK;
        }
        acc += h;
      }
      return rows;
    }

    function focusRow(r) {
      const el = rowElement(r);
      if (!el) return;
      if (hidden.has(target)) setHidden(target, false);
      view.querySelectorAll('.lg-focus').forEach((x) => x.classList.remove('lg-focus'));
      el.classList.add('lg-focus');
      const rect = el.getBoundingClientRect();
      window.scrollTo(window.scrollX, window.scrollY + rect.top - window.innerHeight / 3);
    }

    function step(direction) {
      if (!targets.length) return;
      const current = position >= 0 && rowElement(targets[position]) && rowElement(targets[position]).classList.contains('lg-focus') ? targets[position] : null;
      const from = current != null ? current : rowAtViewTop() - (direction > 0 ? 1 : 0);
      let next;
      if (direction > 0) { next = targets.findIndex((r) => r > from); if (next < 0) next = 0; }
      else { next = -1; for (let k = targets.length - 1; k >= 0; k--) if (targets[k] < from) { next = k; break; } if (next < 0) next = targets.length - 1; }
      position = next;
      focusRow(targets[position]);
      if (pos) pos.textContent = kit.t('{0} of {1}', position + 1, targets.length);
    }

    function setHidden(lv, on) {
      if (on) hidden.add(lv); else hidden.delete(lv);
      view.classList.toggle('hide-' + LETTER[lv], on);
      const chip = bar.querySelector(`.log-chip[data-level="${lv}"]`);
      if (chip) chip.setAttribute('aria-pressed', on ? 'false' : 'true');
      Array.from(view.children).forEach(sizeChunk);
      drawStrip();
    }

    bar.addEventListener('click', (event) => {
      const chip = event.target.closest('.log-chip');
      if (chip) {
        const lv = Number(chip.dataset.level);
        // ⌥-click shows only this level.
        if (event.altKey) {
          [ERROR, WARN, INFO, DEBUG, TRACE, NONE].forEach((other) => { if (counts[other]) setHidden(other, other !== lv); });
        } else {
          setHidden(lv, !hidden.has(lv));
        }
        return;
      }
      const stepper = event.target.closest('.log-step');
      if (stepper) step(Number(stepper.dataset.step));
    });
    card.addEventListener('click', (event) => {
      const jump = event.target.closest('.log-jump');
      if (!jump) return;
      const line = Number(jump.dataset.line) - 1;
      let r = 0;
      while (r + 1 < rows && rowStart[r + 1] <= line) r++;
      focusRow(r);
    });
    document.addEventListener('keydown', (event) => {
      if (event.metaKey || event.ctrlKey || event.altKey || !targets.length) return;
      if (event.target && /^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName)) return;
      if (event.key === 'n' || event.key === 'N') { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
    });

    // ---- Overview strip: where errors and warnings are, beside the scrollbar.
    function drawStrip() {
      if (!strip.isConnected) return;
      // Nothing to overview when everything fits on screen.
      strip.hidden = document.documentElement.scrollHeight <= window.innerHeight + 4;
      if (strip.hidden) return;
      const height = Math.max(1, window.innerHeight - (bar.isConnected ? bar.offsetHeight : 0));
      const scale = window.devicePixelRatio || 1;
      strip.style.height = height + 'px';
      strip.width = 8 * scale;
      strip.height = Math.round(height * scale);
      const ctx = strip.getContext('2d');
      if (!ctx) return;
      ctx.clearRect(0, 0, strip.width, strip.height);
      const total = document.documentElement.scrollHeight || 1;
      const top = view.getBoundingClientRect().top + window.scrollY;
      const style = getComputedStyle(strip);
      const colours = { [ERROR]: style.getPropertyValue('--strip-error').trim() || '#e5484d', [WARN]: style.getPropertyValue('--strip-warn').trim() || '#e2a336' };
      let visible = 0;
      const marks = [];
      for (let r = 0; r < rows; r++) {
        const lv = level[rowStart[r]];
        if (hidden.has(lv)) continue;
        if (lv === ERROR || lv === WARN) marks.push([lv, visible]);
        visible++;
      }
      // Warnings first so errors draw on top.
      for (const wanted of [WARN, ERROR]) {
        ctx.fillStyle = colours[wanted];
        let lastY = -10;
        for (const [lv, index] of marks) {
          if (lv !== wanted) continue;
          const y = Math.round(((top + index * rowHeight) / total) * strip.height);
          if (y - lastY < scale) continue;
          ctx.fillRect(2 * scale, y, 5 * scale, Math.max(2 * scale, Math.round(rowHeight / total * strip.height)));
          lastY = y;
        }
      }
    }
    strip.addEventListener('click', (event) => {
      const rect = strip.getBoundingClientRect();
      const fraction = (event.clientY - rect.top) / rect.height;
      window.scrollTo(window.scrollX, fraction * document.documentElement.scrollHeight - window.innerHeight / 2);
    });
    window.addEventListener('resize', drawStrip);
    // Folding the card or loading the rest of the log moves everything; redraw then too.
    if (window.ResizeObserver) new ResizeObserver(() => drawStrip()).observe(document.body);
    drawStrip();
  }

  (Smart.kinds = Smart.kinds || []).push({
    id: 'log',
    order: 90,
    detect(file) {
      if (/\.(log|out|err)(\.\d+)?$/.test(file.lower) || /\.log\.(old|bak|\d+)$/.test(file.lower) || /^(syslog|messages|system\.log)(\.\d+)?$/.test(file.lower)) return true;
      if (/\.(jsonl|ndjson)$/.test(file.lower)) {
        const lines = file.head.split('\n').filter((l) => l.trim()).slice(0, 20);
        return lines.length >= 2 && lines.filter((l) => STRUCTURED.test(l)).length / lines.length >= 0.8;
      }
      if ((file.language === 'plaintext' || file.language === '' || file.ext === 'txt') && !/^(license|licence|copying|readme|changelog|changes|notice)/.test(file.lower)) {
        return looksLikeLog(file.head);
      }
      return false;
    },
    classify,
    analyse,
    looksLikeLog,
    enhance,
  });
})(typeof window !== 'undefined' ? window : globalThis);
