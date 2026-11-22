/* Greece — font specimen: hero with metric lines, type tester, variable axes, OpenType features,
   waterfall, paragraphs, the character set by Unicode block, and everything the font says about itself.
   The font is loaded with FontFace from greece://module; every string from the file is text. */
(function () {
  'use strict';
  const M = window.GreeceMedia;
  const { el } = M;

  /** Quick Look keeps typed keys for Finder, so the tester offers ready-made texts to try instead. */
  function sampleChoices(face, sample, kit) {
    const latin = face.scripts[0] === 'Latin' || !face.scripts.length;
    const choices = [[kit.t('Sample'), face.sample]];
    // The texts themselves are specimens, the same in every language.
    if (latin) {
      choices.push([kit.t('Pangram'), 'Sphinx of black quartz, judge my vow.'],
                   [kit.t('Alphabet'), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz'],
                   [kit.t('Figures'), '0123456789 $€£¥ ½ % & @ # ( ) [ ] { } ? ! , . ; :']);
    }
    const group = el('div', { class: 'sample-choices', role: 'group', 'aria-label': kit.t('Sample text') });
    choices.forEach(([label, text], i) => {
      const chip = el('button', { type: 'button', class: 'm-chip' + (i === 0 ? ' on' : ''), text: label, 'aria-pressed': String(i === 0) });
      chip.addEventListener('click', () => {
        sample.textContent = text;
        group.querySelectorAll('.m-chip').forEach((c) => { c.classList.toggle('on', c === chip); c.setAttribute('aria-pressed', String(c === chip)); });
      });
      group.appendChild(chip);
    });
    return group;
  }

  const PARAGRAPH = 'Typography exists to honour content. Each letter is drawn to sit comfortably beside its neighbours, ' +
    'and the space between them matters as much as the strokes themselves. Good type disappears into reading: the eye ' +
    'moves along the line, the mind follows the meaning, and only later do we notice the care in the details.';

  let pageReady = false;

  /** Runs now if Quick Look is already showing the page, otherwise once it is. */
  function whenShown(kit, callback) {
    if (pageReady) callback(); else kit.afterReady(callback);
  }

  window.greece.register('media-font', async (data, kit) => {
    kit.afterReady(() => { pageReady = true; });
    const root = kit.root;
    const faces = data.faces || [];
    if (!faces.length) return kit.empty(kit.t('No faces in this font'));
    const families = {};

    async function load(index) {
      if (!families[index]) {
        const family = 'greece-face-' + index;
        const face = new FontFace(family, `url("greece://module/face/${index}")`);
        families[index] = face.load().then((loaded) => { document.fonts.add(loaded); return family; }).catch(() => null);
      }
      return families[index];
    }

    async function show(index) {
      const face = faces[index];
      const family = await load(index);
      root.innerHTML = '';
      const container = page(face, index, family, data, kit, show);
      root.appendChild(container);
      // Measurements need the page in the document and the font loaded.
      (container.attached || []).forEach((callback) => callback());
      await container.glyphsLoaded;
    }

    await show(0);
  });

  function page(face, index, family, data, kit, show) {
    const container = el('div', { class: 'font-page' });
    container.style.setProperty('--specimen-family', family ? `"${family}"` : 'var(--ui)');
    const state = { features: {}, axes: {} };
    for (const axis of face.axes) state.axes[axis.tag] = axis.default;

    const applyVariations = () => {
      const fvs = Object.keys(state.axes).map((tag) => `"${tag}" ${state.axes[tag]}`).join(', ');
      container.style.setProperty('--fvs', fvs || 'normal');
    };
    const applyFeatures = () => {
      const tags = Object.keys(state.features);
      container.style.setProperty('--ffs', tags.length ? tags.map((tag) => `"${tag}" ${state.features[tag] ? 1 : 0}`).join(', ') : 'normal');
    };
    applyVariations();

    // ----------------------------------------------------------- Navigation
    const sections = [];
    const nav = el('div', { class: 'font-nav' }, [
      el('div', { class: 'title' }, [el('span', { class: 'family', text: face.family }), el('span', { class: 'style', text: face.style })]),
    ]);
    if (data.faces.length > 1) {
      // Faces are named as briefly as tells them apart: style, then full name, then PostScript name.
      const sameFamily = data.faces.every((f) => f.family === data.faces[0].family);
      const distinct = (key) => new Set(data.faces.map(key)).size === data.faces.length;
      const label = sameFamily && distinct((f) => f.style) ? (f) => f.style
        : distinct((f) => f.fullName) ? (f) => f.fullName : (f) => f.postScriptName;
      nav.appendChild(M.select(data.faces.map((f, i) => ({ value: i, label: label(f) })), index, (value) => show(value)));
    }
    const links = el('div', { class: 'm-segmented' });
    nav.appendChild(links);
    container.appendChild(nav);
    // `link` names the section in the navigation, when shorter than its title.
    const addSection = (id, title, count, link) => {
      const heading = el('h2', null, [title, count != null ? el('span', { class: 'count', text: count }) : null, el('span', { class: 'spacer' })]);
      const section = el('section', { class: 'font-section', id: 'section-' + id }, [heading]);
      sections.push({ id, link: link || title, section });
      return section;
    };

    if (!family) {
      container.appendChild(el('div', { class: 'notice', style: { margin: '18px 0 0' }, text: kit.t('WebKit couldn’t load this font for display. Its details are below.') }));
    }

    // ----------------------------------------------------------------- Hero
    const icon = face.icon;
    container.attached = [];
    if (family && !icon) {
      const art = hero(face, kit);
      container.appendChild(art);
      container.attached.push(art.layout);
    }
    else if (family && icon) container.appendChild(el('div', { class: 'font-hero' }, [
      el('div', { class: 'specimen', style: { fontSize: '96px', lineHeight: '1.1', letterSpacing: '.12em', overflowWrap: 'anywhere' }, text: face.hero }),
      facts(face, kit),
    ]));

    if (family && !icon) {
      // --------------------------------------------------------- Tester
      const specimen = addSection('specimen', kit.t('Specimen'));
      const sample = el('div', kit.typing
        ? { class: 'sample specimen', contenteditable: 'plaintext-only', spellcheck: 'false', dir: face.direction, text: face.sample }
        : { class: 'sample specimen', dir: face.direction, text: face.sample });
      const sizeLabel = el('span', { class: 'size', text: '64 pt' });
      const tester = el('div', { class: 'tester' }, [
        el('div', { class: 'controls' }, [
          el('span', { text: kit.t('Size') }),
          M.range(10, 200, 1, 64, (value) => { tester.style.setProperty('--tester-size', value + 'px'); sizeLabel.textContent = value + ' pt'; }),
          sizeLabel,
          el('span', { style: { flex: '1' } }),
          kit.typing ? el('span', { text: kit.t('Click the sample to type your own') }) : sampleChoices(face, sample, kit),
        ]),
        sample,
      ]);
      specimen.appendChild(tester);

      // ------------------------------------------------------------ Axes
      if (face.axes.length) {
        const visible = face.axes.filter((axis) => !axis.hidden);
        const section = addSection('axes', kit.t('Variable Axes'), kit.plural(face.axes.length, '{0} axes'), kit.t('Axes'));
        const sliders = {};
        if (face.instances.length) {
          const chips = el('div', { class: 'instances' });
          face.instances.slice(0, 64).forEach((instance) => {
            const chip = el('button', { type: 'button', class: 'm-chip', text: instance.name });
            chip.addEventListener('click', () => {
              for (const tag of Object.keys(instance.coordinates)) {
                state.axes[tag] = instance.coordinates[tag];
                if (sliders[tag]) sliders[tag].set(instance.coordinates[tag]);
              }
              chips.querySelectorAll('.m-chip').forEach((c) => c.classList.toggle('on', c === chip));
              applyVariations();
            });
            chips.appendChild(chip);
          });
          section.appendChild(chips);
        }
        const grid = el('div', { class: 'axes' });
        for (const axis of visible) {
          const value = el('span', { class: 'value', text: M.trimNumber(axis.default) });
          const step = axis.max - axis.min <= 2 ? 0.01 : axis.max - axis.min <= 20 ? 0.1 : 1;
          const input = M.range(axis.min, axis.max, step, axis.default, (v) => {
            state.axes[axis.tag] = v;
            value.textContent = M.trimNumber(v);
            section.querySelectorAll('.instances .m-chip').forEach((c) => c.classList.remove('on'));
            applyVariations();
          });
          sliders[axis.tag] = { set(v) { input.value = v; M.paintRange(input); value.textContent = M.trimNumber(v); } };
          grid.appendChild(el('div', { class: 'axis' }, [
            el('div', { class: 'head' }, [el('span', null, [el('span', { class: 'name', text: axis.name }), el('span', { class: 'tag', text: axis.tag })]), value]),
            input,
            el('div', { class: 'range' }, [el('span', { text: M.trimNumber(axis.min) }), el('span', { text: M.trimNumber(axis.max) })]),
          ]));
        }
        section.appendChild(grid);
      }

      // -------------------------------------------------------- Features
      if (face.features.length) {
        const section = addSection('features', kit.t('OpenType Features'), M.number(face.features.length), kit.t('Features [font]'));
        const grid = el('div', { class: 'features' });
        for (const feature of face.features) {
          const card = el('div', { class: 'feature', role: 'switch', 'aria-checked': 'false', tabindex: '0', title: kit.t('Apply {0} to the specimen', feature.tag) });
          const demo = el('div', { class: 'demo specimen' }, [
            el('span', { class: 'off', style: { fontFeatureSettings: `"${feature.tag}" 0` }, text: feature.sample }),
            el('span', { class: 'arrow', text: '→' }),
            el('span', { class: 'on', style: { fontFeatureSettings: `"${feature.tag}" 1` }, text: feature.sample }),
          ]);
          card.append(el('div', null, [el('div', { class: 'name', text: feature.name }), el('div', { class: 'tag', text: feature.on ? kit.t('{0} · on by default', feature.tag) : feature.tag })]),
            el('div', { class: 'switch' }), demo);
          const sync = () => {
            const on = feature.tag in state.features ? state.features[feature.tag] : feature.on;
            card.classList.toggle('on', on);
            card.setAttribute('aria-checked', String(on));
          };
          const toggle = () => {
            const on = feature.tag in state.features ? state.features[feature.tag] : feature.on;
            if (!on === feature.on) delete state.features[feature.tag]; else state.features[feature.tag] = !on;
            sync();
            applyFeatures();
          };
          card.addEventListener('click', toggle);
          card.addEventListener('keydown', (event) => { if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); toggle(); } });
          sync();
          grid.appendChild(card);
        }
        section.appendChild(grid);
      }

      // ------------------------------------------------------- Waterfall
      const sizes = addSection('sizes', kit.t('Sizes'));
      const waterfall = el('div', { class: 'waterfall' });
      for (const size of [96, 72, 48, 36, 28, 21, 16, 13]) {
        waterfall.appendChild(el('div', { class: 'row' }, [
          el('span', { class: 'size', text: String(size) }),
          el('div', { class: 'line specimen', dir: face.direction, style: { fontSize: size + 'px' }, text: face.sample }),
        ]));
      }
      sizes.appendChild(waterfall);
      const latin = face.scripts[0] === 'Latin' || !face.scripts.length;
      // A Latin specimen paragraph, the same in every language; other scripts repeat the font's sample.
      const text = latin ? PARAGRAPH : [face.sample, face.sample, face.sample].join(' ');
      sizes.appendChild(el('div', { class: 'paragraphs', style: { marginTop: '26px' } }, [
        el('div', null, [el('div', { class: 'label', text: '18 pt' }), el('p', { class: 'specimen', dir: face.direction, style: { fontSize: '18px', lineHeight: '1.55' }, text })]),
        el('div', null, [el('div', { class: 'label', text: '13 pt' }), el('p', { class: 'specimen', dir: face.direction, style: { fontSize: '13px', lineHeight: '1.6' }, text })]),
      ]));
    } else if (family && icon && face.features.length) {
      // Icon fonts: features rarely matter, but list them if present.
    }

    // -------------------------------------------------------------- Glyphs
    const glyphs = addSection('glyphs', icon ? kit.t('Icons') : kit.t('Characters'), M.number(face.characters));
    const glyphHolder = el('div');
    glyphs.appendChild(glyphHolder);

    // ---------------------------------------------------------------- Info
    container.appendChild(info(face, data, addSection('info', kit.t('Information')), kit));

    for (const { id, link: name, section } of sections) {
      container.appendChild(section);
      const link = el('button', { type: 'button', text: name });
      link.addEventListener('click', () => section.scrollIntoView({ behavior: 'smooth', block: 'start' }));
      if (!['sizes'].includes(id)) links.appendChild(link);
    }
    const linkButtons = Array.from(links.children);
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const position = sections.findIndex((s) => s.section === entry.target);
        const visibleSections = sections.filter((s) => s.id !== 'sizes');
        const index = visibleSections.findIndex((s) => s.section === entry.target);
        if (position >= 0 && index >= 0) linkButtons.forEach((b, i) => b.classList.toggle('on', i === index));
      }
    }, { rootMargin: '-60px 0px -70% 0px' });
    sections.forEach((s) => observer.observe(s.section));
    if (linkButtons[0]) linkButtons[0].classList.add('on');

    container.glyphsLoaded = loadGlyphs(glyphHolder, index, face, family, kit);
    return container;
  }

  function hero(face, kit) {
    const m = face.metrics;
    const S = 1000;
    const upm = Math.max(m.upm, 1);
    const asc = Math.max(m.ascender, m.capHeight) / upm * S, desc = Math.max(m.descender, 0) / upm * S;
    const cap = m.capHeight / upm * S, xh = m.xHeight / upm * S;
    const top = 40, baseline = top + asc;
    const height = baseline + desc + 30;
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('class', 'metrics');
    const text = document.createElementNS(ns, 'text');
    text.setAttribute('class', 'glyphs specimen');
    text.setAttribute('x', '0');
    text.setAttribute('y', String(baseline));
    text.setAttribute('font-size', String(S));
    if (face.direction === 'rtl') { text.setAttribute('direction', 'rtl'); text.setAttribute('text-anchor', 'end'); }
    text.textContent = face.hero;
    svg.appendChild(text);

    // Guides are HTML lines across the whole hero, placed at the same heights as the SVG's metrics.
    const art = el('div', { class: 'hero-art' });
    const guides = [
      [kit.t('Ascender'), baseline - asc, ''], [kit.t('Cap height'), baseline - cap, ''], [kit.t('x-height'), baseline - xh, ''],
      [kit.t('Baseline'), baseline, ' base'], [kit.t('Descender'), baseline + desc, ''],
    ];
    const used = [];
    for (const [label, y, kind] of guides) {
      if (!isFinite(y) || y < 0 || y > height) continue;
      // Labels that would collide with one above are left off; the line stays.
      const crowded = used.some((other) => Math.abs(other - y) < 0.05 * S);
      if (!crowded) used.push(y);
      art.appendChild(el('div', { class: 'guide' + kind, style: { top: (y / height * 100) + '%' } }, crowded ? [] : [el('span', { text: label })]));
    }
    art.appendChild(svg);
    const wrap = el('div', { class: 'font-hero' }, [art, facts(face, kit)]);
    // The glyphs' width is known once the page is in the document with the font loaded.
    const layout = () => {
      let width = 1200;
      try { width = Math.max(text.getComputedTextLength(), 400); } catch (_) { }
      if (face.direction === 'rtl') text.setAttribute('x', String(width));
      svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
      const room = Math.max(art.clientWidth - 90, 120);
      const target = Math.min(Math.max(window.innerHeight * 0.36, 170), 330);
      const fitted = Math.min(target, room * height / width);
      svg.style.height = fitted + 'px';
      svg.style.width = (fitted * width / height) + 'px';
      art.style.height = fitted + 'px';
    };
    svg.setAttribute('viewBox', `0 0 1200 ${height}`);
    window.addEventListener('resize', layout);
    wrap.layout = layout;
    return wrap;
  }

  function facts(face, kit) {
    const items = [];
    items.push([kit.t('Glyphs'), M.number(face.glyphs)]);
    if (face.axes.length) items.push([kit.t('Variable'), face.axes.filter((a) => !a.hidden).map((a) => a.name).join(', ') || kit.plural(face.axes.length, '{0} axes')]);
    if (face.version) items.push([kit.t('Version'), face.version]);
    if (face.designer || face.manufacturer) items.push([kit.t('Designer'), face.designer || face.manufacturer]);
    if (face.scripts.length) items.push([kit.t('Scripts [writing]'), face.scripts.slice(0, 4).join(', ') + (face.scripts.length > 4 ? ` +${face.scripts.length - 4}` : '')]);
    return el('div', { class: 'font-facts' }, items.slice(0, 5).map(([k, v]) => el('div', { class: 'fact' }, [el('div', { class: 'k', text: k }), el('div', { class: 'v', text: v })])));
  }

  function info(face, data, section, kit) {
    const grid = el('div', { class: 'info-grid' });
    const row = (key, value, options) => {
      if (value == null || value === '' || (Array.isArray(value) && !value.length)) return;
      const cell = el('div', { class: 'v' });
      if (options && options.link) {
        cell.appendChild(el('a', { href: options.link, text: value }));
      } else if (options && options.clamp && String(value).length > 280) {
        const text = el('div', { class: 'clamp', text: value });
        const more = el('button', { class: 'more', type: 'button', text: kit.t('Show more') });
        more.addEventListener('click', () => { const open = text.classList.toggle('clamp'); more.textContent = open ? kit.t('Show more') : kit.t('Show less'); });
        cell.append(text, more);
      } else {
        cell.textContent = value;
      }
      grid.append(el('div', { class: 'k', text: key }), cell);
    };
    const m = face.metrics;
    row(kit.t('Family'), face.family);
    row(kit.t('Style'), face.style);
    row(kit.t('Full name'), face.fullName);
    row(kit.t('PostScript name'), face.postScriptName);
    row(kit.t('Version'), face.version);
    row(kit.t('Designer'), face.designer, face.designerURL && !face.designer.includes('://') ? { link: face.designerURL } : null);
    if (face.designerURL && (!face.designer)) row(kit.t('Designer URL'), face.designerURL, { link: face.designerURL });
    row(kit.t('Manufacturer'), face.manufacturer, face.vendorURL ? { link: face.vendorURL } : null);
    if (face.vendorURL && !face.manufacturer) row(kit.t('Vendor URL'), face.vendorURL, { link: face.vendorURL });
    row(kit.t('Vendor ID'), face.vendor);
    row(kit.t('Description'), face.description, { clamp: true });
    const format = [kit.t('{0} · {1} outlines', data.format, face.outlines)];
    if (face.color.length) format.push(kit.t('Color ({0})', face.color.join(', ')));
    row(kit.t('Format'), format.join(' · '));
    row(kit.t('Glyphs'), M.number(face.glyphs));
    row(kit.t('Characters'), M.number(face.characters));
    row(kit.t('Units per em'), M.number(m.upm));
    row(kit.t('Metrics'), kit.t('Ascender {0} · Descender {1} · Cap height {2} · x-height {3}', String(m.ascender), String(m.descender), String(m.capHeight), String(m.xHeight)));
    if (face.weight) row(kit.t('Weight class'), String(face.weight));
    if (face.width && face.width !== 5) row(kit.t('Width class'), String(face.width));
    const traits = [face.italic ? kit.t('Italic') : null, face.monospaced ? kit.t('Monospaced') : null].filter(Boolean);
    row(kit.t('Traits'), traits.length ? kit.list(traits) : '');
    row(kit.t('Scripts [writing]'), face.scripts.join(', '));
    if (face.languages.length) row(kit.t('Languages'), `${M.number(face.languages.length)}: ${face.languages.join(', ')}`, { clamp: true });
    row(kit.t('Embedding'), face.embedding);
    row(kit.t('Created'), face.created);
    row(kit.t('Modified'), face.modified);
    row(kit.t('Copyright'), face.copyright, { clamp: true });
    row(kit.t('Trademark'), face.trademark, { clamp: true });
    row(kit.t('License'), face.license, { clamp: true });
    if (face.licenseURL) row(kit.t('License URL'), face.licenseURL, { link: face.licenseURL });
    section.appendChild(grid);
    return section;
  }

  async function loadGlyphs(holder, index, face, family, kit) {
    let result;
    try { result = await M.fetchJSON('glyphs/' + index); } catch (_) { return; }
    if (!family) { holder.appendChild(el('div', { class: 'm-note', text: kit.t('Characters can’t be drawn without the font.') })); return; }
    if (result.shown < result.total) {
      holder.appendChild(el('div', { class: 'notice', style: { margin: '0 0 14px' }, text: kit.plural(result.total, 'Showing the first {1} of {0} characters.', result.shown) }));
    }
    let selected = null;
    let inspector = null;
    const closeInspector = () => { if (inspector) inspector.remove(); inspector = null; if (selected) selected.classList.remove('selected'); selected = null; };
    document.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeInspector(); });

    const open = async (cell) => {
      if (selected) selected.classList.remove('selected');
      selected = cell;
      cell.classList.add('selected');
      const cp = Number(cell.dataset.cp);
      const hex = cp.toString(16).toUpperCase().padStart(4, '0');
      const character = String.fromCodePoint(cp);
      if (!inspector) { inspector = el('div', { class: 'inspector specimen' }); document.body.appendChild(inspector); }
      inspector.innerHTML = '';
      const close = M.button({ icon: 'close', title: kit.t('Close') });
      close.classList.add('close');
      close.addEventListener('click', closeInspector);
      const list = el('dl');
      const add = (k, v) => { if (v != null && v !== '') list.append(el('dt', { text: k }), el('dd', { text: v })); };
      add(kit.t('Code point'), 'U+' + hex);
      inspector.append(close, el('div', { class: 'big', text: character }), list, el('div', { class: 'actions' }, [
        M.button({ icon: 'copy', text: kit.t('Character'), title: kit.t('Copy the character'), onClick: () => M.copy(character) }),
        M.button({ text: 'U+' + hex, title: kit.t('Copy the code point'), onClick: () => M.copy('U+' + hex) }),
      ]));
      try {
        const detail = await M.fetchJSON(`glyph/${index}/${hex}`);
        if (selected !== cell) return;
        list.innerHTML = '';
        add(kit.t('Name'), detail.name ? detail.name.toLowerCase().replace(/(^|\s)\S/g, (s) => s.toUpperCase()) : kit.t('Unnamed'));
        add(kit.t('Code point'), 'U+' + hex);
        add(kit.t('Glyph'), detail.glyph);
        add(kit.t('Glyph ID'), detail.id != null ? String(detail.id) : null);
        add(kit.t('Advance'), detail.advance != null ? kit.plural(detail.advance, '{0} units') : null);
      } catch (_) { }
    };

    const renderBlock = (section, icons) => {
      const block = el('div', { class: 'glyph-block' }, [el('h3', null, [section.name, el('span', { class: 'n', text: M.number(section.codepoints.length) })])]);
      const CHUNK = 600;
      for (let start = 0; start < section.codepoints.length; start += CHUNK) {
        const grid = el('div', { class: 'glyph-grid specimen' + (icons ? ' icons' : '') });
        const parts = [];
        const end = Math.min(start + CHUNK, section.codepoints.length);
        for (let i = start; i < end; i++) {
          const cp = section.codepoints[i];
          const label = icons ? (section.names && section.names[i]) || cp.toString(16).toUpperCase() : cp.toString(16).toUpperCase().padStart(4, '0');
          parts.push(`<div class="glyph" data-cp="${cp}" title="U+${cp.toString(16).toUpperCase().padStart(4, '0')}">${kit.esc(String.fromCodePoint(cp))}<span class="cp">${kit.esc(label)}</span></div>`);
        }
        grid.innerHTML = parts.join('');
        block.appendChild(grid);
      }
      return block;
    };

    holder.addEventListener('click', (event) => {
      const cell = event.target.closest('.glyph');
      if (cell) open(cell);
    });

    const sections = result.sections;
    let painted = 0;
    // The first blocks paint with the page; the rest stream in once Quick Look is showing it.
    for (; painted < sections.length && painted < 3; painted++) holder.appendChild(renderBlock(sections[painted], face.icon));
    whenShown(kit, async () => {
      for (; painted < sections.length; painted++) {
        holder.appendChild(renderBlock(sections[painted], face.icon));
        await kit.tick();
      }
    });
  }
})();
