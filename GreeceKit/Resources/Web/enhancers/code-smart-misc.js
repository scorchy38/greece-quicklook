/* Greece — crontabs (every schedule in plain English, with its next run), Makefiles and
   justfiles (targets with their `##` descriptions), and SSH configs (the hosts). */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};

  // =============================================================================== Cron

  const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const SHORT_DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const SHORT_MONTHS = MONTHS.map((m) => m.slice(0, 3));
  const NAMES = {
    month: { JAN: 1, FEB: 2, MAR: 3, APR: 4, MAY: 5, JUN: 6, JUL: 7, AUG: 8, SEP: 9, OCT: 10, NOV: 11, DEC: 12 },
    dow: { SUN: 0, MON: 1, TUE: 2, WED: 3, THU: 4, FRI: 5, SAT: 6 },
  };
  const SPECIAL = {
    '@yearly': '0 0 1 1 *', '@annually': '0 0 1 1 *', '@monthly': '0 0 1 * *', '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *', '@midnight': '0 0 * * *', '@hourly': '0 * * * *',
  };

  /** One cron field → { all, star, values (sorted), step, range } or null when it isn't valid. */
  function field(spec, min, max, names) {
    const out = new Set();
    let step = 0;
    let range = null;
    const parts = String(spec).toUpperCase().split(',');
    if (!parts.length || parts.length > 60) return null;
    const dow = names === NAMES.dow;
    const top = dow ? 7 : max;  // 7 is Sunday too
    const value = (s) => (names && names[s] !== undefined ? names[s] : /^\d{1,2}$/.test(s) ? Number(s) : NaN);
    for (const part of parts) {
      const m = /^(\*|\?|[A-Z0-9]+)(?:-([A-Z0-9]+))?(?:\/(\d{1,2}))?$/.exec(part);
      if (!m) return null;
      let lo;
      let hi;
      if (m[1] === '*' || m[1] === '?') {
        if (m[2] !== undefined) return null;
        lo = min;
        hi = max;
      } else {
        lo = value(m[1]);
        hi = m[2] !== undefined ? value(m[2]) : (m[3] ? max : lo);
      }
      if (!Number.isInteger(lo) || !Number.isInteger(hi) || lo < min || hi > top || lo > hi) return null;
      const by = m[3] ? Number(m[3]) : 1;
      if (by < 1) return null;
      if (parts.length === 1 && m[3]) step = by;
      if (parts.length === 1 && m[2] !== undefined && !m[3]) range = [lo, hi];
      for (let v = lo; v <= hi; v += by) out.add(dow && v === 7 ? 0 : v);
    }
    const values = Array.from(out).sort((a, b) => a - b);
    return { all: values.length === max - min + 1, star: parts.length === 1 && /^[*?](\/\d+)?$/.test(parts[0]), values, step, range };
  }

  /** "06:30" */
  const hhmm = (h, m) => `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  const ordinal = (n) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : ['th', 'st', 'nd', 'rd'][n % 10] || 'th'}`;
  const list = (items) => (items.length <= 1 ? items.join('') : `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`);

  /** The five fields of an expression (special names expanded), or null. */
  function cronFields(expression) {
    const text = String(expression).trim();
    const expanded = SPECIAL[text.toLowerCase()] || text;
    const parts = expanded.split(/\s+/);
    if (parts.length !== 5) return null;
    const f = {
      minute: field(parts[0], 0, 59), hour: field(parts[1], 0, 23), dom: field(parts[2], 1, 31),
      month: field(parts[3], 1, 12, NAMES.month), dow: field(parts[4], 0, 6, NAMES.dow),
    };
    return Object.values(f).every(Boolean) ? f : null;
  }

  function daysPhrase(f) {
    const dowAll = f.dow.all;
    const domAll = f.dom.all;
    const monthAll = f.month.all;
    const months = list(f.month.values.map((m) => MONTHS[m - 1]));
    const weekdays = (() => {
      const v = f.dow.values;
      if (v.join() === '1,2,3,4,5') return { every: 'every weekday', on: 'on weekdays' };
      if (v.join() === '0,6') return { every: 'every Saturday and Sunday', on: 'at weekends' };
      if (f.dow.range && v.length > 2) {
        const [a, b] = f.dow.range.map((d) => DAYS[d % 7]);
        return { every: `every ${a} to ${b}`, on: `${a} to ${b}` };
      }
      const names = list(v.map((d) => DAYS[d]));
      return { every: `every ${names}`, on: `on ${names}` };
    })();
    const monthDays = () => {
      if (f.dom.step) return `every ${f.dom.step} days`;
      if (f.dom.range && f.dom.values.length > 2) return `days ${f.dom.values[0]}–${f.dom.values[f.dom.values.length - 1]}`;
      return `the ${list(f.dom.values.map(ordinal))}`;
    };
    if (domAll && dowAll) {
      if (monthAll) return { daily: true, every: 'every day', on: '' };
      return { every: `every day in ${months}`, on: `in ${months}` };
    }
    if (domAll) {
      const suffix = monthAll ? '' : ` in ${months}`;
      return { every: weekdays.every + suffix, on: weekdays.on + suffix };
    }
    let dates;
    if (!monthAll && f.dom.values.length === 1 && f.month.values.length === 1 && !f.dom.step) {
      dates = `on ${f.dom.values[0]} ${MONTHS[f.month.values[0] - 1]}`;
      if (dowAll) return { every: `every year ${dates}`, on: dates };
    } else {
      dates = `on ${monthDays()} of ${monthAll ? 'every month' : months}`;
    }
    if (dowAll) return { every: dates, on: dates };
    // Cron runs when either the day of the month or the weekday matches.
    return { every: `${dates} and ${weekdays.every}`, on: `${dates} and ${weekdays.on}` };
  }

  /** A cron expression in plain English: "Every weekday at 06:30". */
  function describe(expression) {
    const text = String(expression).trim();
    if (/^@reboot$/i.test(text)) return 'At startup';
    const f = cronFields(text);
    if (!f) return null;
    const days = daysPhrase(f);
    const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
    const { minute: m, hour: h } = f;
    const recurring = (phrase) => cap(days.daily ? phrase : `${phrase} ${days.on}`);
    const hours = h.values;

    // Specific times of day.
    if (m.values.length <= 4 && !m.star && hours.length * m.values.length <= 6 && !h.star) {
      const times = [];
      for (const hour of hours) for (const minute of m.values) times.push(hhmm(hour, minute));
      return `${cap(days.every)} at ${list(times)}`;
    }
    let phrase;
    if (m.star && !m.step && h.star && !h.step) phrase = 'every minute';
    else if (m.star && m.step && h.star && !h.step) phrase = `every ${m.step} minutes`;
    else if (m.values.length === 1 && h.star && !h.step) phrase = m.values[0] === 0 ? 'every hour' : `every hour at :${String(m.values[0]).padStart(2, '0')}`;
    else if (m.values.length === 1 && h.step && h.star) phrase = `every ${h.step} hours${m.values[0] ? ` at :${String(m.values[0]).padStart(2, '0')}` : ''}`;
    else if (m.values.length === 1 && h.step && !h.star) phrase = `every ${h.step} hours from ${hhmm(hours[0], m.values[0])} to ${hhmm(hours[hours.length - 1], m.values[0])}`;
    else if (m.values.length === 1 && h.range) phrase = `every hour from ${hhmm(h.range[0], m.values[0])} to ${hhmm(h.range[1], m.values[0])}`;
    else if (m.star && m.step && h.range) phrase = `every ${m.step} minutes from ${hhmm(h.range[0], 0)} to ${hhmm(h.range[1], 59)}`;
    else if (m.star && !m.step && hours.length === 1) phrase = `every minute from ${hhmm(hours[0], 0)} to ${hhmm(hours[0], 59)}`;
    else if (m.star && m.step && hours.length <= 3) phrase = `every ${m.step} minutes during ${list(hours.map((x) => hhmm(x, 0).slice(0, 2) + ':xx'))}`;
    else if (h.star && !h.step) phrase = `every hour at ${list(m.values.slice(0, 8).map((x) => ':' + String(x).padStart(2, '0')))}`;
    else if (m.values.length === 1) phrase = `at ${list(hours.slice(0, 8).map((x) => hhmm(x, m.values[0])))}${hours.length > 8 ? ' and more' : ''}`;
    else phrase = `at ${Smart.plural(m.values.length, 'minute')} past ${Smart.plural(hours.length, 'hour')}`;
    if (phrase.startsWith('at ')) return `${cap(days.every)} ${phrase}`;
    return recurring(phrase);
  }

  /** The next time the schedule runs after `from` (local time), or null. */
  function nextRun(expression, from = new Date()) {
    const f = cronFields(expression);
    if (!f) return null;
    const restrictedDom = !f.dom.star || f.dom.step;
    const restrictedDow = !f.dow.star || f.dow.step;
    const start = new Date(from.getFullYear(), from.getMonth(), from.getDate());
    for (let d = 0; d < 366 * 5; d++) {
      const day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + d);
      if (!f.month.values.includes(day.getMonth() + 1)) continue;
      const domOK = f.dom.values.includes(day.getDate());
      const dowOK = f.dow.values.includes(day.getDay());
      const ok = restrictedDom && restrictedDow ? domOK || dowOK : domOK && dowOK;
      if (!ok) continue;
      for (const hour of f.hour.values) {
        for (const minute of f.minute.values) {
          const at = new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour, minute);
          if (at > from) return at;
        }
      }
    }
    return null;
  }

  function relative(date, now = new Date()) {
    if (!date) return '';
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const days = Math.round((new Date(date.getFullYear(), date.getMonth(), date.getDate()) - today) / 86400000);
    const time = hhmm(date.getHours(), date.getMinutes());
    if (days === 0) return `Today ${time}`;
    if (days === 1) return `Tomorrow ${time}`;
    if (days < 7) return `${SHORT_DAYS[date.getDay()]} ${time}`;
    return `${date.getDate()} ${SHORT_MONTHS[date.getMonth()]}${date.getFullYear() !== now.getFullYear() ? ' ' + date.getFullYear() : ''}, ${time}`;
  }

  /** "Now" as the wall clock reads in `zone` (CRON_TZ), or local time. */
  function wallClock(date, zone) {
    if (!zone) return date;
    try {
      const parts = {};
      new Intl.DateTimeFormat('en-US', { timeZone: zone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' })
        .formatToParts(date).forEach((p) => { parts[p.type] = Number(p.value); });
      return new Date(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
    } catch (_) {
      return date;
    }
  }

  const COMMANDS = new Set(['cd', 'sh', 'bash', 'zsh', 'test', 'run-parts', 'python', 'python3', 'node', 'php', 'ruby', 'perl', 'curl', 'wget', 'echo', 'find', 'rm', 'cp', 'mv', 'tar', 'rsync', 'docker', 'make', 'flock', 'sleep', 'nice', 'ionice', 'timeout', 'env', 'source', 'true', 'false', 'git', 'npm', 'npx', 'yarn', 'java', 'cat', 'touch', 'date', 'logrotate', 'certbot', 'systemctl', 'service', 'pg_dump', 'mysqldump', 'aws', 'gsutil', 'kubectl', 'exec', 'nohup', 'cron', 'bundle', 'rake', 'rails', 'go', 'cargo', 'deno', 'bun']);

  function parseCrontab(text) {
    const lines = String(text).replace(/\r\n?/g, '\n').split('\n').slice(0, 20000);
    const jobs = [];
    const env = [];
    lines.forEach((raw, index) => {
      const line = raw.trim();
      if (!line || line.startsWith('#')) return;
      const assign = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
      if (assign && !/^[\d*@]/.test(line)) { env.push({ name: assign[1], value: assign[2], line: index + 1 }); return; }
      const special = /^(@\w+)\s+(.*)$/.exec(line);
      if (special) {
        if (SPECIAL[special[1].toLowerCase()] || /^@reboot$/i.test(special[1])) jobs.push({ schedule: special[1], tokens: special[2].split(/\s+/), line: index + 1 });
        return;
      }
      const parts = line.split(/\s+/);
      if (parts.length >= 6 && cronFields(parts.slice(0, 5).join(' '))) jobs.push({ schedule: parts.slice(0, 5).join(' '), tokens: parts.slice(5), line: index + 1, raw: line });
    });
    // System crontabs (/etc/crontab, cron.d) put a user before the command.
    const users = jobs.map((j) => j.tokens[0]);
    const system = jobs.length > 0 && jobs.every((j) => j.tokens.length >= 2) &&
      users.every((u) => /^[a-z_][a-z0-9_-]{0,31}$/.test(u) && !COMMANDS.has(u)) && new Set(users).size <= 4;
    for (const job of jobs) {
      job.user = system ? job.tokens[0] : '';
      job.command = (system ? job.tokens.slice(1) : job.tokens).join(' ');
      job.description = describe(job.schedule) || job.schedule;
      delete job.tokens;
    }
    const tz = env.find((e) => e.name === 'CRON_TZ' || e.name === 'TZ');
    return { jobs, env, system, timeZone: tz ? tz.value.replace(/^["']|["']$/g, '') : '' };
  }

  function looksLikeCrontab(text) {
    const lines = String(text).split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#') && !/^[A-Za-z_]\w*\s*=/.test(l)).slice(0, 40);
    if (!lines.length) return false;
    const hits = lines.filter((l) => /^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)\s+\S/i.test(l) ||
      (l.split(/\s+/).length >= 6 && /[*\d]/.test(l.split(/\s+/)[0]) && cronFields(l.split(/\s+/).slice(0, 5).join(' ')))).length;
    return hits / lines.length >= 0.6;
  }

  // =========================================================================== Makefile

  function parseMakefile(text, just) {
    const raw = String(text).replace(/\r\n?/g, '\n').split('\n').slice(0, 50000);
    const lines = [];
    for (let i = 0; i < raw.length; i++) {
      let line = raw[i];
      const start = i;
      while (/\\$/.test(line) && i + 1 < raw.length && !just) line = line.slice(0, -1) + ' ' + raw[++i].trim();
      lines.push({ text: line, line: start + 1 });
    }
    const usesDoubleHash = lines.some((l) => /##/.test(l.text));
    const targets = [];
    const phony = new Set();
    let defaultGoal = '';
    let pending = [];
    let inDefine = false;
    for (const { text: line, line: number } of lines) {
      if (inDefine) { if (/^\s*endef\b/.test(line)) inDefine = false; continue; }
      if (/^\s*define\b/.test(line)) { inDefine = true; continue; }
      if (/^\t/.test(line) || (just && /^ {2,}\S/.test(line))) { pending = []; continue; }
      const comment = just ? /^#\s?(.*)$/.exec(line) : (usesDoubleHash ? /^##\s?(.*)$/.exec(line) : /^#\s?(.*)$/.exec(line));
      if (comment) { pending.push(comment[1].trim()); continue; }
      if (!line.trim()) { pending = []; continue; }
      const goal = /^\.DEFAULT_GOAL\s*:?=\s*(\S+)/.exec(line);
      if (goal) { defaultGoal = goal[1]; pending = []; continue; }
      if (/^\s*[A-Za-z_][\w.]*\s*(?::{1,3}=|\?=|\+=|!=|=)/.test(line) || /^\s*(export|override|include|-include|sinclude|ifeq|ifneq|ifdef|ifndef|else|endif|vpath|unexport|set|alias|import|mod)\b/.test(line)) { pending = []; continue; }
      let m;
      if (just) {
        m = /^@?([A-Za-z_][\w-]*)((?:\s+[^:=]+?)?)\s*:(?!=)\s*([^#]*?)\s*(?:#\s*(.*))?$/.exec(line);
        if (m) {
          const attributes = pending.filter((p) => /^\[.*\]$/.test(p));
          targets.push({ name: m[1], params: m[2].trim(), deps: m[3].trim().split(/\s+/).filter(Boolean), description: pending.filter((p) => !/^\[.*\]$/.test(p)).join(' ') || (m[4] || ''), private: m[1].startsWith('_') || attributes.some((a) => /private/.test(a)), line: number });
        }
        pending = [];
        continue;
      }
      if (/^\s*\[/.test(line)) { pending.push(line.trim()); continue; }
      m = /^([^\s:#=][^:#=]*?)\s*(::?)(?![=])\s*([^#;]*?)\s*(?:;.*?)?(?:##\s*(.*))?$/.exec(line);
      if (!m) { pending = []; continue; }
      const names = m[1].trim().split(/\s+/);
      const deps = m[3].trim().split(/\s+/).filter(Boolean);
      if (names[0] === '.PHONY') { deps.forEach((d) => phony.add(d)); pending = []; continue; }
      for (const name of names) {
        if (/^\.[A-Z_]+$/.test(name) || name.includes('%') || /\$[({]/.test(name)) continue;
        targets.push({ name, deps, description: (m[4] || pending.join(' ')).trim(), line: number });
      }
      pending = [];
    }
    // A target can appear on several lines; keep the first, merge descriptions.
    const unique = [];
    const byName = new Map();
    for (const t of targets) {
      const seen = byName.get(t.name);
      if (seen) { if (!seen.description && t.description) seen.description = t.description; continue; }
      byName.set(t.name, t);
      unique.push(t);
    }
    unique.forEach((t) => { t.phony = phony.has(t.name); });
    const visible = unique.filter((t) => !t.private);
    const goal = defaultGoal || (visible.find((t) => !t.name.startsWith('.') && !t.name.includes('/')) || visible[0] || {}).name || '';
    return { targets: visible, defaultGoal: goal, phony: phony.size };
  }

  // ========================================================================= SSH config

  function parseSSHConfig(text) {
    const lines = String(text).replace(/\r\n?/g, '\n').split('\n').slice(0, 20000);
    const hosts = [];
    const includes = [];
    let current = null;
    lines.forEach((raw, index) => {
      const line = raw.trim();
      if (!line || line.startsWith('#')) return;
      const m = /^(\S+?)(?:\s*=\s*|\s+)(.*)$/.exec(line);
      if (!m) return;
      const key = m[1].toLowerCase();
      const value = m[2].replace(/\s+#.*$/, '').trim();
      if (key === 'host' || key === 'match') {
        current = { kind: key, patterns: key === 'host' ? value.split(/\s+/).filter(Boolean) : [value], options: {}, line: index + 1 };
        if (hosts.length < 2000) hosts.push(current);
        return;
      }
      if (key === 'include') { includes.push(value); return; }
      if (current && current.options[key] === undefined) current.options[key] = value.replace(/^"(.*)"$/, '$1');
    });
    return { hosts, includes };
  }

  function looksLikeSSHConfig(text) {
    return /^\s*Host\s+\S/im.test(text) && /^\s*(HostName|IdentityFile|User|Port|ProxyJump|ProxyCommand|ForwardAgent|ServerAliveInterval|IdentitiesOnly|AddKeysToAgent|UseKeychain)\b/im.test(text) &&
      !/^\s*(PermitRootLogin|PasswordAuthentication|Subsystem|ChallengeResponseAuthentication|UsePAM)\b/im.test(text);
  }

  // ============================================================================== Cards

  function cronCard({ root, file, Smart }) {
    const esc = Smart.esc;
    const tab = parseCrontab(file.text);
    if (!tab.jobs.length) return;
    const now = wallClock(new Date(), tab.timeZone);
    const rows = tab.jobs.map((job) => {
      const next = /^@reboot$/i.test(job.schedule) ? '' : relative(nextRun(job.schedule, now), now);
      return `<tr><td class="cron-when"><span class="cron-text">${esc(job.description)}</span><code class="cron-expr">${esc(job.schedule)}</code></td>` +
        `<td class="cron-next">${next ? `<span class="smart-dim">Next</span> ${esc(next)}` : ''}</td>` +
        `<td class="cron-command"><code title="${esc(job.command)}">${esc(job.command)}</code>${job.user ? `<span class="smart-dim">as ${esc(job.user)}</span>` : ''}</td></tr>`;
    });
    const env = tab.env.filter((e) => e.name !== 'CRON_TZ' && e.name !== 'TZ').map((e) => `<li><code class="smart-name">${esc(e.name)}</code><span class="smart-command" title="${esc(e.value)}">${esc(e.value)}</span><span></span></li>`);
    Smart.card(root, {
      kind: 'cron', icon: 'clock', title: 'Crontab', label: tab.system ? 'System' : '',
      subtitle: [Smart.plural(tab.jobs.length, 'job'), tab.timeZone ? `Times in ${tab.timeZone}` : 'Times in local time'].join(' · '),
      body: `<table class="smart-table cron"><tbody>${rows.join('')}</tbody></table>` + (env.length ? Smart.section('Environment', `<ul class="smart-list scripts">${Smart.more(env, 6, '')}</ul>`, { count: env.length }) : ''),
    });
  }

  function makeCard({ root, file, Smart }) {
    const esc = Smart.esc;
    const just = /^\.?justfile$/.test(file.lower);
    const make = parseMakefile(file.text, just);
    if (!make.targets.length) return;
    const described = make.targets.filter((t) => t.description).length;
    // With descriptions, the documented targets lead; the rest follow.
    const ordered = described ? make.targets.filter((t) => t.description).concat(make.targets.filter((t) => !t.description)) : make.targets;
    const rows = ordered.map((t) => `<li><code class="smart-name">${esc(t.name)}${t.params ? ` <span class="smart-dim">${esc(t.params)}</span>` : ''}</code>` +
      `${t.description ? `<span class="smart-description">${esc(t.description)}</span>` : t.deps.length ? `<span class="smart-command">${esc(t.deps.join(' '))}</span>` : '<span></span>'}` +
      `${t.name === make.defaultGoal ? `<span>${Smart.tag('default', 'accent')}</span>` : '<span></span>'}</li>`);
    Smart.card(root, {
      kind: 'make', icon: 'hammer', title: just ? 'Justfile' : 'Makefile',
      subtitle: [Smart.plural(make.targets.length, just ? 'recipe' : 'target'), make.defaultGoal ? `Default: ${make.defaultGoal}` : ''].filter(Boolean).join(' · '),
      body: `<ul class="smart-list targets">${Smart.more(rows, 12, '')}</ul>`,
    });
  }

  function sshCard({ root, file, Smart }) {
    const esc = Smart.esc;
    const config = parseSSHConfig(file.text);
    const hosts = config.hosts.filter((h) => h.kind === 'host');
    if (!config.hosts.length) return;
    const rows = config.hosts.map((h) => {
      const o = h.options;
      const all = h.kind === 'host' && h.patterns.length === 1 && h.patterns[0] === '*';
      const name = h.kind === 'match' ? `Match ${h.patterns[0]}` : all ? 'All hosts' : h.patterns.join(' ');
      const address = `${o.user ? esc(o.user) + '<span class="smart-dim">@</span>' : ''}${esc(o.hostname || (all ? '' : h.patterns[0]))}${o.port && o.port !== '22' ? `<span class="smart-dim">:${esc(o.port)}</span>` : ''}`;
      const key = o.identityfile ? o.identityfile.split('/').pop() : '';
      const via = o.proxyjump || (o.proxycommand ? 'command' : '');
      const extras = Object.keys(o).filter((k) => !['hostname', 'user', 'port', 'identityfile', 'proxyjump', 'proxycommand'].includes(k)).length;
      return `<tr class="${all ? 'defaults' : ''}"><td class="ssh-host"><code>${esc(name)}</code></td><td class="ssh-address">${all ? `<span class="smart-dim">${Smart.plural(Object.keys(o).length, 'default')}</span>` : address}</td>` +
        `<td class="ssh-key">${key ? `<span class="smart-dim">key</span> ${esc(key)}` : ''}</td><td class="ssh-via">${via ? `<span class="smart-dim">via</span> ${esc(via)}` : ''}${extras && !all ? `<span class="smart-dim">${Smart.plural(extras, 'option')}</span>` : ''}</td></tr>`;
    });
    Smart.card(root, {
      kind: 'ssh', icon: 'terminal', title: 'SSH Config',
      subtitle: [Smart.plural(hosts.filter((h) => !(h.patterns.length === 1 && h.patterns[0] === '*')).length, 'host'), config.includes.length ? Smart.plural(config.includes.length, 'include') : ''].filter(Boolean).join(' · '),
      body: `<table class="smart-table ssh"><tbody>${rows.slice(0, 12).join('')}</tbody>${rows.length > 12 ? `<tbody class="smart-rest" hidden>${rows.slice(12).join('')}</tbody>` : ''}</table>` +
        (rows.length > 12 ? `<button type="button" class="smart-more table" data-more="${rows.length - 12}">Show ${Smart.number(rows.length - 12)} More</button>` : ''),
    });
  }

  Smart.cron = { describe, nextRun, relative, wallClock, fields: cronFields };

  (Smart.kinds = Smart.kinds || []).push({
    id: 'cron', order: 40,
    detect(file) {
      if (/^(crontab|root|cron)$|\.(cron|crontab)$|^crontab\./.test(file.lower)) return true;
      return (file.language === 'plaintext' || file.language === '') && !file.ext && looksLikeCrontab(file.head);
    },
    parse: parseCrontab, enhance: cronCard,
  });
  (Smart.kinds = Smart.kinds || []).push({
    id: 'make', order: 30,
    detect: (file) => /^(gnu|bsd)?makefile$|^makefile\.|\.mk$|\.make$/.test(file.lower) || /^\.?justfile$/.test(file.lower),
    parse: parseMakefile, enhance: makeCard,
  });
  (Smart.kinds = Smart.kinds || []).push({
    id: 'ssh', order: 45,
    detect: (file) => (/^(ssh_config|config|.*\.ssh_config|.*\.sshconfig)$/.test(file.lower) || file.lower === 'config.ssh') && looksLikeSSHConfig(file.head),
    parse: parseSSHConfig, enhance: sshCard,
  });
})(typeof window !== 'undefined' ? window : globalThis);
