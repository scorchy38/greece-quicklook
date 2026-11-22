/* Greece — subtitles and captions: a timeline overview and every cue with its timing, duration,
   speaker and reading speed. Cues that break common guidelines are marked, and can be filtered. */
(function () {
  'use strict';
  const M = window.GreeceMedia;
  const { el } = M;

  const FLAGS = [
    { bit: 1, key: 'fast', label: (n) => `${M.number(n)} too fast`, reason: (c, l) => `Reading speed ${c.c} cps (over ${l.cps})` },
    { bit: 2, key: 'longLines', label: (n) => `${M.number(n)} long ${n === 1 ? 'line' : 'lines'}`, reason: (c, l) => `A line over ${l.line} characters` },
    { bit: 32, key: 'manyLines', label: (n) => `${M.number(n)} over ${2} lines`, reason: (c, l) => `More than ${l.lines} lines` },
    { bit: 4, key: 'brief', label: (n) => `${M.number(n)} brief`, reason: (c, l) => `On screen under ${(l.min / 1000).toFixed(2)} s` },
    { bit: 8, key: 'lingering', label: (n) => `${M.number(n)} lingering`, reason: (c, l) => `On screen over ${l.max / 1000} s` },
    { bit: 16, key: 'overlaps', label: (n) => `${M.number(n)} ${n === 1 ? 'overlap' : 'overlaps'}`, reason: () => 'Starts before the previous cue ends' },
    { bit: 64, key: 'badTiming', label: (n) => `${M.number(n)} bad timing`, reason: () => 'Ends before it starts' },
  ];

  let shown = false;

  window.greece.register('media-subtitles', async (data, kit) => {
    kit.afterReady(() => { shown = true; });
    const root = kit.root;
    let cues = [];
    try { cues = await M.fetchJSON('cues.json'); } catch (_) { return kit.empty('These subtitles couldn’t be read'); }
    const stats = data.stats;
    const limits = data.limits;
    const lyrics = data.format === 'LRC';
    const total = Math.max(stats.end, 1);
    const page = el('div', { class: 'subs' });

    // --------------------------------------------------------------- Header
    const head = el('div', { class: 'subs-head' });
    const search = el('input', { class: 'm-search', type: 'search', placeholder: lyrics ? 'Filter lines' : 'Filter cues', 'aria-label': 'Filter' });
    head.appendChild(el('div', { class: 'row' }, [el('h1', { text: data.title || data.kind }), search]));

    const chips = el('div', { class: 'stats' });
    chips.appendChild(el('span', { class: 'm-chip', text: M.plural(stats.cues, lyrics ? 'line' : 'cue') }));
    if (stats.end > 0) chips.appendChild(el('span', { class: 'm-chip', text: M.timecode(stats.end).replace(/\.\d+$/, '') }));
    if (data.checks && stats.averageCPS != null) chips.appendChild(el('span', { class: 'm-chip', title: 'Average reading speed, in characters per second', text: `${M.trimNumber(stats.averageCPS, 1)} cps average` }));
    if (stats.speakers > 0) chips.appendChild(el('span', { class: 'm-chip', text: M.plural(stats.speakers, 'speaker') }));
    for (const language of data.languages || []) chips.appendChild(el('span', { class: 'm-chip', text: language }));
    if (data.frameRate) chips.appendChild(el('span', { class: 'm-chip', text: `Timed at ${M.trimNumber(data.frameRate, 3)} fps` }));
    for (const [key, value] of data.metadata || []) chips.appendChild(el('span', { class: 'm-chip', text: `${key}: ${value}` }));

    let flagFilter = 0;
    const flagChips = [];
    if (data.checks) {
      for (const flag of FLAGS) {
        const count = stats[flag.key];
        if (!count) continue;
        const chip = el('button', { type: 'button', class: 'm-chip warn', title: 'Show only these', text: flag.label(count) });
        chip.addEventListener('click', () => {
          flagFilter = flagFilter === flag.bit ? 0 : flag.bit;
          flagChips.forEach((c) => c.classList.toggle('on', c === chip && flagFilter !== 0));
          applyFilter();
        });
        flagChips.push(chip);
        chips.appendChild(chip);
      }
    }
    head.appendChild(chips);

    // ------------------------------------------------------------- Timeline
    const timeline = el('div', { class: 'timeline', title: 'Jump to a moment' });
    const canvas = el('canvas');
    const hover = el('div', { class: 'hover' });
    timeline.append(canvas, hover);
    head.appendChild(timeline);
    head.appendChild(el('div', { class: 'ticks' }, [
      el('span', { text: M.timecode(0).replace(/\.\d+$/, '') }),
      el('span', { text: M.timecode(total / 2).replace(/\.\d+$/, '') }),
      el('span', { text: M.timecode(total).replace(/\.\d+$/, '') }),
    ]));
    page.appendChild(head);

    if (data.truncated) page.appendChild(el('div', { class: 'notice', style: { margin: '14px 28px 0' }, text: `Showing the first ${M.number(cues.length)} cues.` }));

    const list = el('div', { class: 'cues' });
    page.appendChild(list);
    root.appendChild(page);

    function resolved(variable, fallback) {
      const probe = el('span', { style: { color: `var(${variable})`, display: 'none' } });
      document.body.appendChild(probe);
      const color = getComputedStyle(probe).color;
      probe.remove();
      return color || fallback;
    }

    function drawTimeline() {
      const ratio = window.devicePixelRatio || 1;
      const width = timeline.clientWidth, height = timeline.clientHeight;
      if (!width) return;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      const context = canvas.getContext('2d');
      context.scale(ratio, ratio);
      context.clearRect(0, 0, width, height);
      const accent = resolved('--accent', '#007aff');
      const warn = resolved('--m-warn', '#c27c0e');
      // Cues as slim bars; flagged ones drawn last, in amber.
      const bar = 8, top = (height - bar) / 2;
      for (const pass of [0, 1]) {
        context.fillStyle = pass ? warn : accent;
        context.globalAlpha = pass ? 0.95 : 0.6;
        for (const cue of cues) {
          if (!!cue.f !== !!pass) continue;
          const x = cue.s / total * width;
          const w = Math.max((cue.e - cue.s) / total * width - 1, 1);
          context.beginPath();
          if (context.roundRect) context.roundRect(x, top, w, bar, Math.min(2, w / 2)); else context.rect(x, top, w, bar);
          context.fill();
        }
      }
    }

    timeline.addEventListener('mousemove', (event) => {
      const box = timeline.getBoundingClientRect();
      hover.style.left = (event.clientX - box.left) + 'px';
    });
    timeline.addEventListener('click', (event) => {
      const box = timeline.getBoundingClientRect();
      const time = (event.clientX - box.left) / box.width * total;
      let best = null;
      for (const index of visible) {
        if (cues[index].e >= time) { best = index; break; }
      }
      if (best == null && visible.length) best = visible[visible.length - 1];
      if (best != null) reveal(best);
    });

    function reveal(index) {
      ensureRendered(index);
      const row = document.getElementById('cue-' + index);
      if (!row) return;
      row.scrollIntoView({ block: 'center' });
      list.querySelectorAll('.cue.target').forEach((r) => r.classList.remove('target'));
      row.classList.add('target');
    }

    // ----------------------------------------------------------------- List
    let visible = cues.map((_, i) => i);
    let rendered = 0;
    let generation = 0;
    const CHUNK = 250;

    function row(index) {
      const cue = cues[index];
      const number = cue.i && /^\d{1,7}$/.test(cue.i) ? cue.i : String(index + 1);
      let text;
      if (cue.r) {
        text = cue.r.map((span) => {
          let html = kit.esc(span.t);
          if (span.f & 1) html = `<i>${html}</i>`;
          if (span.f & 2) html = `<b>${html}</b>`;
          if (span.f & 4) html = `<u>${html}</u>`;
          return html;
        }).join('');
      } else if (data.checks && (cue.f & 2)) {
        // The part of a long line past the limit is underlined.
        text = cue.t.split('\n').map((line) => line.length > limits.line
          ? kit.esc(line.slice(0, limits.line)) + `<span class="over">${kit.esc(line.slice(limits.line))}</span>` : kit.esc(line)).join('\n');
      } else {
        text = kit.esc(cue.t);
      }
      let label = '';
      if (cue.p) label += `<span class="speaker">${kit.esc(cue.p)}</span>`;
      if (cue.y) {
        const color = data.styleColors && data.styleColors[cue.y];
        const dot = color && /^#[0-9a-f]{6}$/i.test(color) ? `<i style="background:${color}"></i>` : '';
        label += `<span class="style">${dot}${kit.esc(cue.y)}</span>`;
      }
      if (label) label = `<span class="label">${label}</span>`;
      const reasons = FLAGS.filter((flag) => cue.f & flag.bit).map((flag) => flag.reason(cue, limits));
      const flag = reasons.length ? `<span class="flag" title="${kit.esc(reasons.join('\n'))}"></span>` : '';
      const duration = ((cue.e - cue.s) / 1000).toFixed(1) + ' s';
      const cps = data.checks && cue.c != null ? `<span class="cps${cue.f & 1 ? ' warn' : ''}">${M.trimNumber(cue.c, 1)} cps</span>` : '';
      return `<div class="cue" id="cue-${index}"><div class="n">${flag}${kit.esc(number)}</div>` +
        `<div class="t">${M.timecode(cue.s, total >= 3600000)}<br><span class="end">${M.timecode(cue.e, total >= 3600000)}</span></div>` +
        `<div class="text">${label}${text}</div><div class="meta"><span>${duration}</span>${cps}</div></div>`;
    }

    function appendChunk() {
      const end = Math.min(rendered + CHUNK, visible.length);
      let html = '';
      for (let i = rendered; i < end; i++) html += row(visible[i]);
      list.insertAdjacentHTML('beforeend', `<div class="cue-chunk">${html}</div>`);
      rendered = end;
    }

    function ensureRendered(index) {
      const position = visible.indexOf(index);
      while (position >= rendered && rendered < visible.length) appendChunk();
    }

    async function renderList() {
      const run = ++generation;
      list.innerHTML = '';
      rendered = 0;
      if (!visible.length) {
        list.appendChild(el('div', { class: 'empty-list', text: cues.length ? 'No matching cues' : 'No cues found' }));
        return;
      }
      // Four screens now, the rest streamed in once the page is on screen.
      appendChunk();
      const rest = async () => {
        while (rendered < visible.length && run === generation) {
          appendChunk();
          await kit.tick();
        }
      };
      if (shown) rest(); else kit.afterReady(rest);
    }

    let filterTimer;
    function applyFilter() {
      const query = search.value.trim().toLowerCase();
      visible = [];
      cues.forEach((cue, index) => {
        if (flagFilter && !(cue.f & flagFilter)) return;
        if (query && !(cue.t.toLowerCase().includes(query) || (cue.p && cue.p.toLowerCase().includes(query)))) return;
        visible.push(index);
      });
      renderList();
    }
    search.addEventListener('input', () => { clearTimeout(filterTimer); filterTimer = setTimeout(applyFilter, 120); });

    renderList();
    drawTimeline();
    window.addEventListener('resize', drawTimeline);
    kit.onApply(drawTimeline);
    if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', drawTimeline);
  });
})();
