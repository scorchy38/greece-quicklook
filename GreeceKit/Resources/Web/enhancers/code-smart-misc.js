/* Greece — crontabs (every schedule in plain English, with its next run), Makefiles and
   justfiles (targets with their `##` descriptions), and SSH configs (the hosts). */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  /** The page's strings (Smart.kit), looked up when used: code-smart.js, which sets it, may load after this file. */
  const kit = new Proxy({}, { get: (_, name) => Smart.kit[name] });

  // =============================================================================== Cron

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
  /** A time of day as the page's locale writes it: "06:30", "6:30 AM". */
  const timeOfDay = (h, m) => kit.date(new Date(2024, 0, 1, h, m), { timeStyle: 'short' });
  /** Weekday (0 = Sunday) and month (1 = January) names, and "1 January", in the page's language. */
  const dayName = (d) => kit.date(new Date(2023, 0, 1 + d), { weekday: 'long' });
  const monthName = (m) => kit.date(new Date(2023, m - 1, 1), { month: 'long' });
  const dayOfYear = (day, month) => kit.date(new Date(2024, month - 1, day), { day: 'numeric', month: 'long' });
  /** Capitalises a description that starts with a phrase ("every weekday at 06:30"). */
  const cap = (s) => s.charAt(0).toLocaleUpperCase(kit.lang) + s.slice(1);

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

  /** When in the year, month and week a schedule runs: `every` leads a sentence ("every weekday"),
      `on` follows a recurring one ("Every hour on weekdays"). Every day: `daily`. */
  function daysPhrase(f) {
    const dowAll = f.dow.all;
    const domAll = f.dom.all;
    const monthAll = f.month.all;
    const months = kit.list(f.month.values.map(monthName));
    const weekdays = (inMonths) => {
      const v = f.dow.values;
      if (v.join() === '1,2,3,4,5') {
        return inMonths ? { every: kit.t('every weekday in {0}', inMonths), on: kit.t('on weekdays in {0}', inMonths) }
          : { every: kit.t('every weekday'), on: kit.t('on weekdays') };
      }
      if (v.join() === '0,6') {
        return inMonths ? { every: kit.t('every Saturday and Sunday in {0}', inMonths), on: kit.t('at weekends in {0}', inMonths) }
          : { every: kit.t('every Saturday and Sunday'), on: kit.t('at weekends') };
      }
      if (f.dow.range && v.length > 2) {
        const [a, b] = f.dow.range.map((d) => dayName(d % 7));
        return inMonths ? { every: kit.t('every {0} to {1} in {2}', a, b, inMonths), on: kit.t('{0} to {1} in {2}', a, b, inMonths) }
          : { every: kit.t('every {0} to {1}', a, b), on: kit.t('{0} to {1}', a, b) };
      }
      const names = kit.list(v.map(dayName));
      return inMonths ? { every: kit.t('every {0} in {1}', names, inMonths), on: kit.t('on {0} in {1}', names, inMonths) }
        : { every: kit.t('every {0}', names), on: kit.t('on {0}', names) };
    };
    const monthDays = (ofMonths) => {
      const v = f.dom.values;
      if (f.dom.step) {
        return ofMonths ? kit.plural(f.dom.step, 'on every {0} days of {1}', ofMonths) : kit.plural(f.dom.step, 'on every {0} days of every month');
      }
      if (f.dom.range && v.length > 2) {
        return ofMonths ? kit.t('on days {0}–{1} of {2}', v[0], v[v.length - 1], ofMonths) : kit.t('on days {0}–{1} of every month', v[0], v[v.length - 1]);
      }
      const days = kit.list(v.map((d) => kit.ordinal(d, '{0}th')));
      return ofMonths ? kit.t('on the {0} of {1}', days, ofMonths) : kit.t('on the {0} of every month', days);
    };
    if (domAll && dowAll) {
      if (monthAll) return { daily: true, every: kit.t('every day'), on: '' };
      return { every: kit.t('every day in {0}', months), on: kit.t('in {0}', months) };
    }
    if (domAll) return weekdays(monthAll ? '' : months);
    let dates;
    if (!monthAll && f.dom.values.length === 1 && f.month.values.length === 1 && !f.dom.step) {
      const date = dayOfYear(f.dom.values[0], f.month.values[0]);
      if (dowAll) return { every: kit.t('every year on {0}', date), on: kit.t('on {0} every year', date) };
      dates = kit.t('on {0} every year', date);
    } else {
      dates = monthDays(monthAll ? '' : months);
    }
    if (dowAll) return { every: dates, on: dates };
    // Cron runs when either the day of the month or the weekday matches.
    const days = weekdays('');
    return { every: kit.list([dates, days.every]), on: kit.list([dates, days.on]) };
  }

  /** A cron expression in plain words: "Every weekday at 06:30". */
  function describe(expression) {
    const text = String(expression).trim();
    if (/^@reboot$/i.test(text)) return kit.t('At startup');
    const f = cronFields(text);
    if (!f) return null;
    const days = daysPhrase(f);
    const { minute: m, hour: h } = f;
    const hours = h.values;
    // A step of one is no step: "*/1" runs every minute.
    const mStep = m.step > 1 ? m.step : 0;
    const hStep = h.step > 1 ? h.step : 0;
    // A recurring schedule, alone when it runs every day, or followed by its days ("on weekdays").
    const say = (alone, withDays) => cap(days.daily ? alone() : withDays(days.on));
    const pastHour = (minutes) => kit.list(minutes.map((x) => kit.t(':{0}', String(x).padStart(2, '0'))));

    // Specific times of day.
    if (m.values.length <= 4 && !m.star && hours.length * m.values.length <= 6 && !h.star) {
      const times = [];
      for (const hour of hours) for (const minute of m.values) times.push(timeOfDay(hour, minute));
      return cap(kit.t('{0} at {1}', days.every, kit.list(times)));
    }
    const one = m.values[0];
    if (m.star && !mStep && h.star && !hStep) return say(() => kit.t('Every minute'), (d) => kit.t('Every minute {0}', d));
    if (m.star && mStep && h.star && !hStep) return say(() => kit.plural(mStep, 'Every {0} minutes'), (d) => kit.plural(mStep, 'Every {0} minutes {1}', d));
    if (m.values.length === 1 && h.star && !hStep) {
      if (one === 0) return say(() => kit.t('Every hour'), (d) => kit.t('Every hour {0}', d));
      return say(() => kit.t('Every hour at {0}', pastHour([one])), (d) => kit.t('Every hour at {0} {1}', pastHour([one]), d));
    }
    if (m.values.length === 1 && hStep && h.star) {
      if (!one) return say(() => kit.plural(hStep, 'Every {0} hours'), (d) => kit.plural(hStep, 'Every {0} hours {1}', d));
      return say(() => kit.plural(hStep, 'Every {0} hours at {1}', pastHour([one])), (d) => kit.plural(hStep, 'Every {0} hours at {1} {2}', pastHour([one]), d));
    }
    if (m.values.length === 1 && hStep && !h.star) {
      const from = timeOfDay(hours[0], one);
      const to = timeOfDay(hours[hours.length - 1], one);
      return say(() => kit.plural(hStep, 'Every {0} hours from {1} to {2}', from, to), (d) => kit.plural(hStep, 'Every {0} hours from {1} to {2} {3}', from, to, d));
    }
    if (m.values.length === 1 && h.range) {
      const from = timeOfDay(h.range[0], one);
      const to = timeOfDay(h.range[1], one);
      return say(() => kit.t('Every hour from {0} to {1}', from, to), (d) => kit.t('Every hour from {0} to {1} {2}', from, to, d));
    }
    if (m.star && mStep && h.range) {
      const from = timeOfDay(h.range[0], 0);
      const to = timeOfDay(h.range[1], 59);
      return say(() => kit.plural(mStep, 'Every {0} minutes from {1} to {2}', from, to), (d) => kit.plural(mStep, 'Every {0} minutes from {1} to {2} {3}', from, to, d));
    }
    if (m.star && !mStep && hours.length === 1) {
      const from = timeOfDay(hours[0], 0);
      const to = timeOfDay(hours[0], 59);
      return say(() => kit.t('Every minute from {0} to {1}', from, to), (d) => kit.t('Every minute from {0} to {1} {2}', from, to, d));
    }
    if (m.star && mStep && hours.length <= 3) {
      const during = kit.list(hours.map((x) => hhmm(x, 0).slice(0, 2) + ':xx'));
      return say(() => kit.plural(mStep, 'Every {0} minutes during {1}', during), (d) => kit.plural(mStep, 'Every {0} minutes during {1} {2}', during, d));
    }
    if (h.star && !hStep) {
      const at = pastHour(m.values.slice(0, 8));
      return say(() => kit.t('Every hour at {0}', at), (d) => kit.t('Every hour at {0} {1}', at, d));
    }
    if (m.values.length === 1) {
      const times = kit.list(hours.slice(0, 8).map((x) => timeOfDay(x, one)));
      return cap(hours.length > 8 ? kit.t('{0} at {1} and more', days.every, times) : kit.t('{0} at {1}', days.every, times));
    }
    return cap(kit.t('{0} at {1} past {2}', days.every, kit.plural(m.values.length, '{0} minutes'), kit.plural(hours.length, '{0} hours')));
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

  /** When a run is, from now: "Today 06:30", "Tomorrow 06:30", "Mon 06:30", "3 Dec, 06:30". */
  function relative(date, now = new Date()) {
    if (!date) return '';
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const days = Math.round((new Date(date.getFullYear(), date.getMonth(), date.getDate()) - today) / 86400000);
    const time = timeOfDay(date.getHours(), date.getMinutes());
    if (days === 0) return kit.t('Today {0}', time);
    if (days === 1) return kit.t('Tomorrow {0}', time);
    if (days < 7) return kit.date(date, { weekday: 'short', hour: 'numeric', minute: '2-digit' });
    const year = date.getFullYear() !== now.getFullYear() ? { year: 'numeric' } : {};
    return kit.date(date, { day: 'numeric', month: 'short', ...year, hour: 'numeric', minute: '2-digit' });
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
        `<td class="cron-next">${next ? `<span class="smart-dim">${esc(kit.t('Next run'))}</span> <span class="cron-when-next">${esc(next)}</span>` : ''}</td>` +
        `<td class="cron-command"><code title="${esc(job.command)}">${esc(job.command)}</code>${job.user ? `<span class="smart-dim">${esc(kit.t('as {0}', job.user))}</span>` : ''}</td></tr>`;
    });
    const env = tab.env.filter((e) => e.name !== 'CRON_TZ' && e.name !== 'TZ').map((e) => `<li><code class="smart-name">${esc(e.name)}</code><span class="smart-command" title="${esc(e.value)}">${esc(e.value)}</span><span></span></li>`);
    Smart.card(root, {
      kind: 'cron', icon: 'clock', title: 'Crontab', label: tab.system ? kit.t('System') : '',
      subtitle: [kit.plural(tab.jobs.length, '{0} jobs'), tab.timeZone ? kit.t('Times in {0}', tab.timeZone) : kit.t('Times in local time')].join(' · '),
      body: `<table class="smart-table cron"><tbody>${rows.join('')}</tbody></table>` + (env.length ? Smart.section(kit.t('Environment'), `<ul class="smart-list scripts">${Smart.more(env, 6)}</ul>`, { count: env.length }) : ''),
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
      `${t.name === make.defaultGoal ? `<span>${Smart.tag(kit.t('default'), 'accent')}</span>` : '<span></span>'}</li>`);
    Smart.card(root, {
      kind: 'make', icon: 'hammer', title: just ? 'Justfile' : 'Makefile',
      subtitle: [just ? kit.plural(make.targets.length, '{0} recipes') : kit.plural(make.targets.length, '{0} targets'), make.defaultGoal ? kit.t('Default: {0}', make.defaultGoal) : ''].filter(Boolean).join(' · '),
      body: `<ul class="smart-list targets">${Smart.more(rows, 12)}</ul>`,
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
      const name = h.kind === 'match' ? `Match ${h.patterns[0]}` : all ? kit.t('All hosts') : h.patterns.join(' ');
      const address = `${o.user ? esc(o.user) + '<span class="smart-dim">@</span>' : ''}${esc(o.hostname || (all ? '' : h.patterns[0]))}${o.port && o.port !== '22' ? `<span class="smart-dim">:${esc(o.port)}</span>` : ''}`;
      const key = o.identityfile ? o.identityfile.split('/').pop() : '';
      const via = o.proxyjump || (o.proxycommand ? kit.t('command') : '');
      const extras = Object.keys(o).filter((k) => !['hostname', 'user', 'port', 'identityfile', 'proxyjump', 'proxycommand'].includes(k)).length;
      return `<tr class="${all ? 'defaults' : ''}"><td class="ssh-host"><code>${esc(name)}</code></td><td class="ssh-address">${all ? `<span class="smart-dim">${esc(kit.plural(Object.keys(o).length, '{0} defaults'))}</span>` : address}</td>` +
        `<td class="ssh-key">${key ? `<span class="smart-dim">${esc(kit.t('key'))}</span> ${esc(key)}` : ''}</td><td class="ssh-via">${via ? `<span class="smart-dim">${esc(kit.t('via'))}</span> ${esc(via)}` : ''}${extras && !all ? `<span class="smart-dim">${esc(kit.plural(extras, '{0} options'))}</span>` : ''}</td></tr>`;
    });
    Smart.card(root, {
      kind: 'ssh', icon: 'terminal', title: kit.t('SSH Config'),
      subtitle: [kit.plural(hosts.filter((h) => !(h.patterns.length === 1 && h.patterns[0] === '*')).length, '{0} hosts'), config.includes.length ? kit.plural(config.includes.length, '{0} includes') : ''].filter(Boolean).join(' · '),
      body: `<table class="smart-table ssh"><tbody>${rows.slice(0, 12).join('')}</tbody>${rows.length > 12 ? `<tbody class="smart-rest" hidden>${rows.slice(12).join('')}</tbody>` : ''}</table>` +
        (rows.length > 12 ? `<button type="button" class="smart-more table" data-more="${rows.length - 12}">${esc(Smart.moreLabel(rows.length - 12))}</button>` : ''),
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
