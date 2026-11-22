/* Greece — document pages: LaTeX papers and Beamer decks, PGF figures, BibTeX libraries,
   EPUB books, Org / AsciiDoc / reStructuredText / Quarto prose and Mermaid diagrams.
   Everything here is built from data GreeceKit prepared; file content is escaped or sanitised. */
(function () {
  'use strict';

  const greece = window.greece;
  if (!greece) return;
  const kit = greece.kit;
  const { $, $$, esc, post } = kit;
  const html = document.documentElement;
  const dark = () => window.matchMedia('(prefers-color-scheme: dark)').matches;
  /** A translated template whose placeholders take HTML: the text is escaped, the parts aren't, and
      a space beside a placeholder doesn't break ("vol. 12" stays on one line). */
  const fillHTML = (template, ...parts) => esc(template).replace(/ (?=\{\d+\})|(?<=\{\d+\}) /g, '&nbsp;')
    .replace(/\{(\d+)\}/g, (m, i) => (i < parts.length ? parts[i] : m));

  // ------------------------------------------------------------------ Shared

  function katexHTML(tex, display, macros) {
    if (!window.katex) return `<code class="math-fallback">${esc(tex)}</code>`;
    try {
      return katex.renderToString(tex, { displayMode: display, throwOnError: true, strict: 'ignore', trust: false, output: 'html', macros, maxExpand: 1000, maxSize: 40 });
    } catch (_) {
      return `<code class="math-fallback" title="${esc(kit.t('This formula uses commands Greece can’t typeset'))}">${esc(tex)}</code>`;
    }
  }

  /** The same outline as Markdown's, built from headings that already have ids. */
  function buildOutline(headings, doc, label) {
    if (!kit.options.outline || headings.length < 3) return;
    const top = Math.min(...headings.map((h) => Number(h.tagName[1])));
    const nav = document.createElement('nav');
    nav.className = 'outline';
    nav.innerHTML = `<p class="title">${esc(label || kit.t('On This Page'))}</p>` + headings.map((h) => {
      const depth = Math.min(4, Number(h.tagName[1]) - top + 2);
      const number = h.querySelector(':scope > .num');
      const clone = h.cloneNode(true);
      $$('.num, .chapter-label, .org-tags, .org-priority, .org-cookie, sup, .katex-mathml', clone).forEach((n) => n.remove());
      const todo = $('.org-todo', clone);
      if (todo) todo.remove();
      const text = clone.textContent.trim();
      return `<a href="#${encodeURIComponent(h.id)}" class="d${depth}">${number ? `<span class="n">${esc(number.textContent)}</span>` : ''}${esc(text)}</a>`;
    }).join('');
    doc.appendChild(nav);
    doc.classList.add('has-outline');
    const links = $$('a', nav);
    let ticking = false;
    function spy() {
      ticking = false;
      let active = 0;
      for (let i = 0; i < headings.length; i++) {
        if (headings[i].getBoundingClientRect().top < 120) active = i; else break;
      }
      if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 4) active = headings.length - 1;
      links.forEach((a, i) => a.classList.toggle('active', i === active));
    }
    window.addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(spy); } }, { passive: true });
    spy();
  }

  function formatDate(value) {
    if (!value) return '';
    const text = String(value).trim();
    const m = text.match(/^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?/);
    if (!m) return text;
    if (!m[2]) return m[1];
    const date = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3] || 1));
    if (Number.isNaN(date.getTime())) return text;
    return kit.date(date, m[3] ? { year: 'numeric', month: 'long', day: 'numeric' } : { year: 'numeric', month: 'long' });
  }

  function copyButton(button, text) {
    button.addEventListener('click', (e) => { e.preventDefault(); kit.copyText(text, button); });
  }

  /** Renders math placeholders: the first screens now, the rest after Quick Look is showing the page. */
  function renderMath(container, math, macros, labels) {
    const nodes = $$('span.m[data-i]', container);
    const fill = (node) => {
      const item = math[Number(node.dataset.i)];
      if (!item) return;
      let tex = item.tex;
      if (/\\(eq)?ref\s*\{/.test(tex)) {
        tex = tex.replace(/\\(eq)?ref\s*\{([^}]*)\}/g, (m, eq, key) => {
          const value = labels[key.trim()];
          return value ? `\\text{${eq ? '(' + value + ')' : value}}` : '\\text{??}';
        });
      }
      node.outerHTML = katexHTML(tex, item.display, macros);
    };
    const FIRST = 500;
    nodes.slice(0, FIRST).forEach(fill);
    if (nodes.length > FIRST) {
      kit.afterReady(async () => {
        for (let i = FIRST; i < nodes.length; i += 150) {
          nodes.slice(i, i + 150).forEach(fill);
          await kit.tick();
        }
      });
    }
  }

  function wrapReading(article, outlineLabel) {
    const doc = document.createElement('div');
    doc.className = 'doc';
    doc.appendChild(article);
    return doc;
  }

  // ------------------------------------------------------------------ LaTeX

  greece.register('latex', async (data) => {
    let result;
    try {
      result = GreeceLaTeX.convert(data.source, {
        figures: data.figures || {}, bib: data.bib || [], bbl: data.bbl,
        highlight: kit.highlight, languageTitle: kit.languageTitle,
      });
    } catch (e) {
      post('log', 'latex: ' + (e && e.stack || e));
      return fallbackToSource(data.source);
    }
    if (result.error) post('log', 'latex: ' + result.error);
    if (result.kind === 'beamer' && result.slides.length) return renderDeck(result, data);
    return renderPaper(result, data);
  });

  function fallbackToSource(source) {
    kit.payload.text = source || '';
    kit.payload.language = 'latex';
    html.className = html.className.replace(/kind-[\w-]+/g, '');
    kit.root.innerHTML = '';
    kit.renderCode();
  }

  function stoppedNotice(result) {
    if (!result.stopped) return '';
    if (result.stopped === 'time') return kit.notice(kit.t('The rest of this document took too long to typeset.'));
    if (result.stopped === 'error') return kit.notice(kit.t('The rest of this document couldn’t be typeset.'));
    return kit.notice(kit.t('The rest of this document is too large or too deeply nested to typeset.'));
  }

  function renderPaper(result, data) {
    const article = document.createElement('article');
    article.className = 'tex';
    const template = document.createElement('template');
    let prefix = '';
    if (data.truncated) prefix += kit.notice(kit.t('Showing the beginning of a very large project.'));
    template.innerHTML = prefix + result.html + stoppedNotice(result);
    kit.sanitize(template.content);
    article.appendChild(template.content);
    if (!article.textContent.trim() && !$('img, svg', article)) {
      kit.empty(kit.t('Empty document'));
      return;
    }
    const doc = wrapReading(article);
    doc.classList.add('tex-doc');
    if (result.parskip) doc.classList.add('parskip');
    kit.root.appendChild(doc);
    renderMath(article, result.math, result.katexMacros, result.labels);
    const headings = $$('h2[id], h3[id], h4[id]', article).filter((h) => !h.closest('.tex-toc'));
    buildOutline(headings, doc, kit.t('Contents'));
    // Wide tables and figures scroll on their own rather than the page.
    $$('img.tex-graphic', article).forEach((img) => { img.decoding = 'async'; });
  }

  function renderDeck(result, data) {
    html.classList.add('deck-page');
    const deck = document.createElement('div');
    deck.className = 'deck';
    const sections = [];
    result.slides.forEach((s) => { if (s.section && !sections.includes(s.section)) sections.push(s.section); });
    let previousSection = '';
    let n = 0;
    const parts = [];
    if (data.truncated) parts.push(kit.notice(kit.t('Showing the beginning of a very large presentation.')));
    for (const slide of result.slides) {
      n += 1;
      if (slide.section && slide.section !== previousSection) {
        parts.push(`<p class="deck-section"><span class="n">${sections.indexOf(slide.section) + 1}</span>${esc(slide.section)}</p>`);
        previousSection = slide.section;
      }
      let body = slide.html.replace('\u0001STOC\u0002', sections.length ? `<ol class="slide-toc">${sections.map((s) => `<li>${esc(s)}</li>`).join('')}</ol>` : '');
      const classes = ['slide'];
      if (slide.isTitle) classes.push('title-slide');
      if (/standout/.test(slide.options || '')) classes.push('standout');
      const header = slide.title && !slide.isTitle ? `<header class="frame-title"><h2>${slide.title}</h2>${slide.subtitle ? `<p class="frame-subtitle">${slide.subtitle}</p>` : ''}</header>` : '';
      const notes = slide.footnotes.length ? `<div class="frame-notes">${slide.footnotes.join('')}</div>` : '';
      parts.push(`<section class="${classes.join(' ')}" id="slide-${n}" aria-label="${esc(kit.t('Slide {0}', n))}"><div class="frame">${header}<div class="frame-body">${body}</div>${notes}<span class="frame-number">${n}</span></div></section>`);
    }
    const template = document.createElement('template');
    template.innerHTML = parts.join('') + stoppedNotice(result);
    kit.sanitize(template.content);
    deck.appendChild(template.content);
    kit.root.appendChild(deck);
    renderMath(deck, result.math, result.katexMacros, result.labels);
    fitSlides(deck);
    window.addEventListener('resize', () => fitSlides(deck));
    kit.onApply(() => fitSlides(deck));
  }

  /** Shrinks text on slides that overflow, as Beamer's shrink option would. */
  function fitSlides(deck) {
    $$('.slide .frame', deck).forEach((frame) => {
      frame.style.setProperty('--fit', '1');
      let fit = 1;
      for (let k = 0; k < 7 && frame.scrollHeight > frame.clientHeight + 2; k++) {
        fit -= 0.07;
        frame.style.setProperty('--fit', fit.toFixed(2));
      }
    });
  }

  // ------------------------------------------------------------------ PGF figure

  greece.register('pgf', (data) => {
    const width = Math.round((data.width || 400) * 1.333);
    kit.root.innerHTML = `<div class="figure-page"><figure class="figure-card" style="max-width:${width}px">${data.svg}</figure></div>`;
    kit.sanitize(kit.root);
  });

  // ------------------------------------------------------------------ BibTeX

  /** EPUB contributors credited under the title, by MARC relator code (authors and publishers are shown elsewhere). */
  const ROLE = {
    ill: (names) => kit.t('Illustrated by {0}', names), edt: (names) => kit.t('Edited by {0}', names),
    trl: (names) => kit.t('Translated by {0}', names), nrt: (names) => kit.t('Narrated by {0}', names),
    aui: (names) => kit.t('Introduction by {0}', names), aft: (names) => kit.t('Afterword by {0}', names),
    ctb: (names) => kit.t('With contributions by {0}', names), ann: (names) => kit.t('Annotated by {0}', names),
    com: (names) => kit.t('Compiled by {0}', names), cov: (names) => kit.t('Cover by {0}', names),
    adp: (names) => kit.t('Adapted by {0}', names), art: (names) => kit.t('Art by {0}', names),
    pht: (names) => kit.t('Photographs by {0}', names),
  };

  greece.register('bibtex', (data) => {
    const L = window.GreeceLaTeX;
    const entries = data.entries || [];
    if (!entries.length) return kit.empty(kit.t('No references'));
    const inline = (text) => L.inlineHTML(text, { katex: (tex, display, macros) => katexHTML(tex, display, macros) });
    const fieldText = (entry, name) => (entry.fields[name] ? inline(entry.fields[name]) : '');
    const counts = {};
    entries.forEach((e) => { counts[e.type] = (counts[e.type] || 0) + 1; });
    const summary = Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([type, n]) => `<span class="chip">${esc(typeCount(type, n))}</span>`).join('');

    const items = entries.map((entry, index) => {
      const f = entry.fields || {};
      const names = L.parseNames(f.author || f.editor || '');
      const people = names.map((n) => (n.others ? 'et al.' : inline([n.first, n.von, n.last].filter(Boolean).join(' ') + (n.jr ? ', ' + n.jr : '')))).join(', ');
      const year = fieldText(entry, 'year') || (f.date ? esc(String(f.date).slice(0, 10)) : '');
      const venueBits = [];
      const container = fieldText(entry, 'journal') || fieldText(entry, 'journaltitle') || fieldText(entry, 'booktitle');
      if (container) venueBits.push(`<i>${container}</i>`);
      if (f.volume) venueBits.push(fillHTML(kit.t('vol. {0}'), `${fieldText(entry, 'volume')}${f.number ? `(${fieldText(entry, 'number')})` : ''}`));
      if (f.pages) venueBits.push(fillHTML(kit.t('pp. {0}'), esc(L.stripTeX(f.pages).replace(/-+/g, '–'))));
      const publisher = fieldText(entry, 'publisher') || fieldText(entry, 'school') || fieldText(entry, 'institution') || fieldText(entry, 'organization');
      if (publisher) venueBits.push(publisher);
      if (f.address || f.location) venueBits.push(fieldText(entry, 'address') || fieldText(entry, 'location'));
      if (f.howpublished && !container) venueBits.push(fieldText(entry, 'howpublished'));
      if (f.edition) venueBits.push(fillHTML(kit.t('{0} ed.'), fieldText(entry, 'edition')));
      if (f.editor && f.author) venueBits.push(fillHTML(kit.t('ed. {0}'), L.parseNames(f.editor).map((n) => inline([n.first, n.last].filter(Boolean).join(' '))).join(', ')));
      const links = [];
      if (f.doi) {
        const doi = L.stripTeX(f.doi).replace(/^https?:\/\/(dx\.)?doi\.org\//i, '');
        links.push(`<a class="bib-pill" href="https://doi.org/${esc(encodeURI(doi))}">DOI&nbsp;${esc(doi)}</a>`);
      }
      if (f.eprint && /arxiv/i.test(f.archiveprefix || f.eprinttype || 'arxiv')) {
        const id = L.stripTeX(f.eprint);
        links.push(`<a class="bib-pill" href="https://arxiv.org/abs/${esc(id)}">arXiv&nbsp;${esc(id)}</a>`);
      }
      const url = f.url ? L.stripTeX(f.url).replace(/\s/g, '') : '';
      if (/^https?:\/\//i.test(url)) links.push(`<a class="bib-pill" href="${esc(url)}">${esc(url.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, '').slice(0, 48))}</a>`);
      if (f.isbn) links.push(`<span class="bib-pill plain">ISBN&nbsp;${esc(L.stripTeX(f.isbn))}</span>`);
      const keywords = f.keywords ? L.stripTeX(f.keywords).split(/[,;]/).map((k) => k.trim()).filter(Boolean).slice(0, 12) : [];
      const note = f.note ? `<p class="bib-note">${fieldText(entry, 'note')}</p>` : '';
      const abstract = f.abstract ? `<details class="bib-abstract"><summary>${esc(kit.t('Abstract'))}</summary><p>${fieldText(entry, 'abstract')}</p></details>` : '';
      const search = [entry.key, L.stripTeX(f.title || ''), L.stripTeX(f.author || f.editor || ''), L.stripTeX(f.year || ''), L.stripTeX(f.journal || f.booktitle || ''), keywords.join(' ')].join(' ').toLowerCase();
      return `<li class="bib-entry" data-search="${esc(search)}" id="entry-${index}">
        <div class="bib-head"><span class="bib-type t-${esc(entry.type.replace(/[^a-z]/g, ''))}">${esc(typeName(entry.type))}</span><span class="bib-key" role="button" tabindex="0" title="${esc(kit.t('Copy citation key'))}">${esc(entry.key)}</span>${year ? `<span class="bib-year">${year}</span>` : ''}</div>
        <p class="bib-title">${fieldText(entry, 'title') || `<span class="untitled">${esc(kit.t('Untitled'))}</span>`}</p>
        ${people ? `<p class="bib-people">${people}</p>` : ''}
        ${venueBits.length ? `<p class="bib-venue">${venueBits.join(' · ')}</p>` : ''}
        ${note}
        ${links.length || keywords.length ? `<div class="bib-links">${links.join('')}${keywords.map((k) => `<span class="chip">${esc(k)}</span>`).join('')}</div>` : ''}
        ${abstract}
      </li>`;
    }).join('');

    const count = [kit.plural(entries.length, '{0} references')];
    if (data.strings) count.push(kit.plural(data.strings, '{0} string macros'));
    if (data.preambles) count.push(kit.plural(data.preambles, '{0} preambles'));
    const content = document.createElement('template');
    content.innerHTML = `<div class="bib-summary">${summary}</div>${data.truncated ? kit.notice(kit.t('Showing the first references of a very large library.')) : ''}<ol class="bib-list">${items}</ol><p class="bib-none" hidden>${esc(kit.t('No matching references'))}</p>`;
    kit.sanitize(content.content);
    const page = document.createElement('div');
    page.className = 'bib-page';
    page.innerHTML = `<header class="bib-header">
        <div class="bib-heading"><h1>${esc(data.fileName || kit.t('Bibliography'))}</h1><p class="bib-count">${esc(count.join(' · '))}</p></div>
        <input class="bib-filter" type="search" placeholder="${esc(kit.t('Filter'))}" aria-label="${esc(kit.t('Filter references'))}" autocomplete="off" spellcheck="false">
      </header>`;
    page.appendChild(content.content);
    kit.root.appendChild(page);
    $$('.bib-key').forEach((button) => copyButton(button, button.textContent));
    const filter = $('.bib-filter');
    if (!kit.typing) filter.hidden = true;   // Quick Look keeps typed keys for Finder
    const list = $$('.bib-entry');
    const none = $('.bib-none');
    filter.addEventListener('input', () => {
      const terms = filter.value.toLowerCase().split(/\s+/).filter(Boolean);
      let shown = 0;
      list.forEach((li) => {
        const match = terms.every((t) => li.dataset.search.includes(t));
        li.hidden = !match;
        if (match) shown++;
      });
      none.hidden = shown > 0;
    });
    document.addEventListener('keydown', (e) => {
      if ((e.metaKey && e.key === 'f') || (e.key === '/' && document.activeElement !== filter)) { e.preventDefault(); filter.focus(); }
      if (e.key === 'Escape' && document.activeElement === filter) { filter.value = ''; filter.dispatchEvent(new Event('input')); filter.blur(); }
    });
  });

  /** BibTeX and BibLaTeX entry types: the name on an entry, and the count in the library's summary. */
  const ENTRY_TYPES = {
    article: [() => kit.t('Article'), (n) => kit.plural(n, '{0} Articles')],
    book: [() => kit.t('Book'), (n) => kit.plural(n, '{0} Books')],
    booklet: [() => kit.t('Booklet'), (n) => kit.plural(n, '{0} Booklets')],
    inbook: [() => kit.t('Chapter'), (n) => kit.plural(n, '{0} Chapters')],
    incollection: [() => kit.t('In Collection'), (n) => kit.plural(n, '{0} In Collection')],
    inproceedings: [() => kit.t('Conference Paper'), (n) => kit.plural(n, '{0} Conference Papers')],
    manual: [() => kit.t('Manual [document]'), (n) => kit.plural(n, '{0} Manuals')],
    mastersthesis: [() => kit.t('Master’s Thesis'), (n) => kit.plural(n, '{0} Master’s Theses')],
    misc: [() => kit.t('Misc'), (n) => kit.plural(n, '{0} Misc')],
    phdthesis: [() => kit.t('PhD Thesis'), (n) => kit.plural(n, '{0} PhD Theses')],
    proceedings: [() => kit.t('Proceedings'), (n) => kit.plural(n, '{0} Proceedings')],
    report: [() => kit.t('Report'), (n) => kit.plural(n, '{0} Reports')],
    unpublished: [() => kit.t('Unpublished'), (n) => kit.plural(n, '{0} Unpublished')],
    online: [() => kit.t('Online'), (n) => kit.plural(n, '{0} Online')],
    thesis: [() => kit.t('Thesis'), (n) => kit.plural(n, '{0} Theses')],
    software: [() => kit.t('Software'), (n) => kit.plural(n, '{0} Software')],
    dataset: [() => kit.t('Dataset'), (n) => kit.plural(n, '{0} Datasets')],
    patent: [() => kit.t('Patent'), (n) => kit.plural(n, '{0} Patents')],
    collection: [() => kit.t('Collection'), (n) => kit.plural(n, '{0} Collections')],
    periodical: [() => kit.t('Periodical'), (n) => kit.plural(n, '{0} Periodicals')],
    standard: [() => kit.t('Standard'), (n) => kit.plural(n, '{0} Standards')],
    video: [() => kit.t('Video'), (n) => kit.plural(n, '{0} Videos')],
    audio: [() => kit.t('Audio'), (n) => kit.plural(n, '{0} Audio')],
    artwork: [() => kit.t('Artwork'), (n) => kit.plural(n, '{0} Artworks')],
    preprint: [() => kit.t('Preprint'), (n) => kit.plural(n, '{0} Preprints')],
  };
  // Types that are another's synonym.
  Object.assign(ENTRY_TYPES, {
    conference: ENTRY_TYPES.inproceedings, techreport: ENTRY_TYPES.report, electronic: ENTRY_TYPES.online,
    www: ENTRY_TYPES.online, mvbook: ENTRY_TYPES.book,
  });
  const ownType = (type) => (Object.prototype.hasOwnProperty.call(ENTRY_TYPES, type) ? ENTRY_TYPES[type] : null);

  function typeName(type) {
    const known = ownType(type);
    if (known) return known[0]();
    return type ? type[0].toUpperCase() + type.slice(1) : kit.t('Entry');
  }

  /** "3 Articles"; a type Greece doesn't know keeps its own name, with the count beside it. */
  function typeCount(type, n) {
    const known = ownType(type);
    return known ? known[1](n) : kit.t('{0} ({1})', typeName(type), n);
  }

  // ------------------------------------------------------------------ EPUB

  greece.register('epub', (data) => {
    const contributors = (data.contributors || []).filter((c) => c.role && Object.prototype.hasOwnProperty.call(ROLE, c.role));
    const byRole = {};
    contributors.forEach((c) => { (byRole[c.role] = byRole[c.role] || []).push(c.name); });
    const credits = Object.entries(byRole).map(([role, names]) => `<p class="credit">${esc(ROLE[role](kit.list(names)))}</p>`).join('');
    const facts = [];
    if (data.publisher) facts.push([kit.t('Publisher'), esc(data.publisher)]);
    if (data.date) facts.push([kit.t('Published'), esc(formatDate(data.date))]);
    if (data.languageName || data.language) facts.push([kit.t('Language'), esc(data.languageName || data.language)]);
    if (data.isbn) facts.push(['ISBN', `<span class="mono">${esc(data.isbn)}</span>`]);
    else if (data.identifier) facts.push([kit.t('Identifier'), `<span class="mono id">${esc(data.identifier.replace(/^urn:(uuid|isbn):/i, ''))}</span>`]);
    if (data.words) {
      const minutes = data.words / 230;
      const length = minutes < 60
        ? kit.plural(data.words, '{0} words · {1} min read', Math.max(1, Math.round(minutes)))
        : kit.plural(data.words, '{0} words · {1} h {2} min read', Math.floor(minutes / 60), Math.round(minutes % 60));
      facts.push([kit.t('Length'), esc(length)]);
    }
    if (data.version) facts.push([kit.t('Format'), `EPUB ${esc(String(data.version).replace(/\.0$/, ''))}`]);
    const series = data.series ? `<p class="series">${esc(data.series)}${data.seriesIndex ? ` · ${esc(kit.t('Book {0}', String(data.seriesIndex).replace(/\.0$/, '')))}` : ''}</p>` : '';
    const subjects = (data.subjects || []).length ? `<div class="subjects">${data.subjects.map((s) => `<span class="chip">${esc(s)}</span>`).join('')}</div>` : '';
    const description = data.description ? `<div class="description">${data.description.split('\n').filter(Boolean).map((p) => `<p>${esc(p)}</p>`).join('')}</div>` : '';
    const cover = data.cover ? `<div class="cover"><img src="${esc(data.cover)}" alt="${esc(kit.t('Cover'))}"></div>` : `<div class="cover typeset"><div class="cover-art"><p class="t">${esc(data.title)}</p><p class="a">${esc((data.authors || []).join(', '))}</p></div></div>`;

    const tocItem = (entry, depth) => {
      if (depth > 5) return '';
      const label = esc(entry.title || kit.t('Untitled'));
      const link = entry.chapter != null ? `<a href="#" data-chapter="${entry.chapter}"${entry.anchor ? ` data-anchor="c${entry.chapter}-${esc(entry.anchor)}"` : ''}>${label}</a>` : `<span>${label}</span>`;
      const children = (entry.children || []).length ? `<ol>${entry.children.map((c) => tocItem(c, depth + 1)).join('')}</ol>` : '';
      return `<li>${link}${children}</li>`;
    };
    const tocCount = (list) => list.reduce((n, e) => n + 1 + tocCount(e.children || []), 0);
    const toc = (data.toc || []).length ? `<section class="book-contents${tocCount(data.toc) > 14 ? ' long' : ''}"><h2>${esc(kit.t('Contents'))}</h2><ol>${data.toc.map((e) => tocItem(e, 0)).join('')}</ol></section>` : '';
    const protectedNote = data.encrypted ? kit.notice(kit.t('This book is protected, so its chapters can’t be shown.')) : '';

    const page = `<div class="book">
      <header class="book-hero">
        ${cover}
        <div class="book-meta">
          ${series}
          <h1 class="book-title">${esc(data.title)}</h1>
          ${data.subtitle ? `<p class="book-subtitle">${esc(data.subtitle)}</p>` : ''}
          ${(data.authors || []).length ? `<p class="byline">${esc(data.authors.join(', '))}</p>` : ''}
          ${credits}
          ${facts.length ? `<dl class="facts">${facts.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join('')}</dl>` : ''}
          ${subjects}
          ${description}
        </div>
      </header>
      ${toc}
      ${protectedNote}
      <article class="book-chapter" aria-live="polite"></article>
    </div>`;
    const template = document.createElement('template');
    template.innerHTML = page;
    kit.sanitize(template.content);
    kit.root.appendChild(template.content);

    const chapter = $('.book-chapter');
    const nav = document.createElement('nav');
    nav.className = 'chapter-nav';
    nav.innerHTML = `<button class="prev pill-button" type="button">${esc(kit.t('Previous [chapter]'))}</button><span class="where"></span><button class="next pill-button" type="button">${esc(kit.t('Next [chapter]'))}</button>`;
    chapter.after(nav);
    const contents = $('.book-contents.long');
    if (contents) {
      const more = document.createElement('button');
      more.className = 'show-all';
      more.type = 'button';
      more.textContent = kit.t('Show All');
      contents.appendChild(more);
    }
    let current = data.chapter;
    const show = (htmlText, index, title, anchor) => {
      const t = document.createElement('template');
      t.innerHTML = htmlText || '';
      kit.sanitize(t.content);
      // Book images load from the archive; anything else never loads.
      $$('img', t.content).forEach((img) => { if (!/^greece:\/\/module\//.test(img.getAttribute('src') || '')) img.remove(); });
      chapter.innerHTML = '';
      chapter.appendChild(t.content);
      current = index;
      const label = title || (findTitle(data.toc, index) || '');
      $('.where', nav).textContent = label ? label : kit.t('Section {0}', index + 1);
      $('.prev', nav).disabled = index <= 0;
      $('.next', nav).disabled = index >= data.chapters - 1;
      nav.hidden = data.encrypted || data.chapters <= 1;
      if (anchor) {
        const target = document.getElementById(anchor);
        if (target) target.scrollIntoView({ block: 'start' });
      }
    };
    const load = async (index, anchor) => {
      if (data.encrypted || index < 0 || index >= data.chapters) return;
      try {
        const response = await fetch(`greece://module/chapter/${index}`);
        if (!response.ok) throw new Error(String(response.status));
        const json = await response.json();
        show(json.html, index, json.title, anchor);
        if (!anchor) chapter.scrollIntoView({ block: 'start', behavior: 'smooth' });
      } catch (e) { post('log', 'epub chapter: ' + e); }
    };
    if (data.chapterHTML) show(data.chapterHTML, data.chapter, data.chapterTitle);
    else nav.hidden = true;
    $('.prev', nav).addEventListener('click', () => load(current - 1));
    $('.next', nav).addEventListener('click', () => load(current + 1));
    document.addEventListener('click', (e) => {
      const link = e.target.closest('a[data-chapter]');
      if (!link) return;
      e.preventDefault();
      e.stopPropagation();
      const index = Number(link.dataset.chapter);
      if (index === current && link.dataset.anchor) {
        const target = document.getElementById(link.dataset.anchor);
        if (target) target.scrollIntoView({ block: 'start', behavior: 'smooth' });
        return;
      }
      load(index, link.dataset.anchor);
    }, true);
    const showAll = $('.show-all');
    if (showAll) showAll.addEventListener('click', () => { showAll.closest('.book-contents').classList.remove('long'); showAll.remove(); });
  });

  function findTitle(toc, index) {
    for (const entry of toc || []) {
      if (entry.chapter === index && !entry.anchor) return entry.title;
      const inner = findTitle(entry.children, index);
      if (inner) return inner;
    }
    for (const entry of toc || []) if (entry.chapter === index) return entry.title;
    return null;
  }

  // ------------------------------------------------------------------ Prose (Org, AsciiDoc, rST, Quarto…)

  greece.register('prose', async (data) => {
    html.classList.add('kind-markdown');
    const head = [];
    if (data.title) head.push(`<h1 class="prose-title">${esc(data.title)}</h1>`);
    if (data.subtitle) head.push(`<p class="prose-subtitle">${esc(data.subtitle)}</p>`);
    const byline = [];
    if ((data.authors || []).length) byline.push(esc(data.authors.join(', ')));
    if (data.date) byline.push(esc(formatDate(data.date)));
    if (byline.length) head.push(`<p class="prose-byline">${byline.join('<span class="dot">·</span>')}</p>`);
    const chips = (data.tags || []).map((t) => `<span class="chip tag">${esc(t)}</span>`);
    if (chips.length) head.push(`<div class="prose-tags">${chips.join('')}</div>`);
    if ((data.meta || []).length) head.push(`<dl class="front-matter prose-meta">${data.meta.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl>`);
    if (data.abstract) head.push(`<p class="prose-abstract">${esc(data.abstract)}</p>`);
    const prefix = (kit.payload.truncated ? kit.notice(kit.t('Showing the beginning of a very large document.')) : '') + (head.length ? `<header class="prose-head">${head.join('')}</header>` : '');
    const text = kit.payload.text || '';
    if (!text.trim() && !head.length) return kit.empty(kit.t('Empty document'));
    const article = await kit.markdownDocument(text, { prefix, outline: false });
    const doc = article.parentElement;
    const headings = $$('h1, h2, h3, h4', article).filter((h) => !h.classList.contains('prose-title'));
    const levels = headings.map((h) => Number(h.tagName[1]));
    const entries = headings.filter((h, i) => levels[i] >= 2 || levels.filter((l) => l === 1).length > 1);
    buildOutline(entries, doc);
  });

  // ------------------------------------------------------------------ Mermaid

  const MERMAID_THEME = {
    light: {
      background: 'transparent', primaryColor: '#eef4fd', primaryBorderColor: '#8fb2e6', primaryTextColor: '#1d1d1f',
      secondaryColor: '#f3f0fa', secondaryBorderColor: '#b9a6e3', tertiaryColor: '#f2f2f4', tertiaryBorderColor: '#c7c7cc',
      lineColor: '#8e8e93', textColor: '#1d1d1f', mainBkg: '#eef4fd', nodeBorder: '#8fb2e6', clusterBkg: '#f7f7f9',
      clusterBorder: '#d1d1d6', edgeLabelBackground: '#ffffff', noteBkgColor: '#fff8e1', noteBorderColor: '#e8cf80', noteTextColor: '#1d1d1f', sequenceNumberColor: '#ffffff',
      actorBkg: '#eef4fd', actorBorder: '#8fb2e6', signalColor: '#3a3a3c', labelBoxBkgColor: '#eef4fd',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif', fontSize: '14px',
    },
    dark: {
      darkMode: true, background: 'transparent', primaryColor: '#1f2b3d', primaryBorderColor: '#4a77b8', primaryTextColor: '#f5f5f7',
      secondaryColor: '#2a2438', secondaryBorderColor: '#7d68b0', tertiaryColor: '#2c2c2e', tertiaryBorderColor: '#48484a',
      lineColor: '#8e8e93', textColor: '#f5f5f7', mainBkg: '#1f2b3d', nodeBorder: '#4a77b8', clusterBkg: '#252527',
      clusterBorder: '#48484a', edgeLabelBackground: '#1e1e1e', noteBkgColor: '#3a3324', noteBorderColor: '#8a7440', noteTextColor: '#f5f5f7', sequenceNumberColor: '#1e1e1e',
      actorBkg: '#1f2b3d', actorBorder: '#4a77b8', signalColor: '#d1d1d6', labelBoxBkgColor: '#1f2b3d',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif', fontSize: '14px',
    },
  };

  /** Mermaid escapes < and > in labels before KaTeX sees them; KaTeX's \lt and \gt survive. */
  function mathSafe(source) {
    return source.replace(/\$\$([\s\S]*?)\$\$/g, (m, tex) => '$$' + tex.replace(/</g, '\\lt ').replace(/>/g, '\\gt ') + '$$');
  }

  // Categorical colours for charts (pie, XY, git, timeline, mind maps), after the system palette.
  const CHART = {
    light: ['#5b9cf0', '#f2a24f', '#6cc17a', '#a98bec', '#ee7fa3', '#4fc3c6', '#eec64f', '#8b97ee', '#ec8576', '#97cc66', '#76bdf0', '#c39d76'],
    dark: ['#4c8de6', '#e0913f', '#56ad66', '#9478dc', '#dc6d92', '#3faeb2', '#d9b13f', '#7884df', '#da7264', '#82b955', '#63a9de', '#ae8963'],
  };
  function chartVariables(isDark) {
    const colors = isDark ? CHART.dark : CHART.light;
    const vars = {};
    colors.forEach((c, i) => {
      vars['pie' + (i + 1)] = c;
      vars['cScale' + i] = c;
      vars['cScaleLabel' + i] = '#ffffff';
      if (i < 8) { vars['git' + i] = c; vars['gitBranchLabel' + i] = '#ffffff'; }
    });
    vars.pieStrokeColor = isDark ? '#1e1e1e' : '#ffffff';
    vars.pieStrokeWidth = '1.5px';
    vars.pieOuterStrokeWidth = '0px';
    vars.pieSectionTextColor = '#ffffff';
    vars.pieTitleTextColor = isDark ? '#f5f5f7' : '#1d1d1f';
    vars.pieLegendTextColor = isDark ? '#f5f5f7' : '#1d1d1f';
    vars.xyChart = { plotColorPalette: colors.join(', '), backgroundColor: 'transparent' };
    vars.radar = { curveOpacity: 0.35, graticuleColor: isDark ? '#48484a' : '#d1d1d6' };
    return vars;
  }

  greece.register('mermaid-file', async (data) => {
    const source = String(data.source || '').replace(/\r\n?/g, '\n');
    if (!source.trim()) return kit.empty(kit.t('Empty diagram'));
    kit.root.innerHTML = `<div class="diagram-stage" tabindex="0"><div class="diagram-canvas"></div></div>
      <div class="diagram-tools floating-tools" role="toolbar">
        <button class="pill" type="button" data-zoom="out" title="${esc(kit.t('Zoom out'))} (−)">−</button>
        <button class="pill zoom-level" type="button" data-zoom="fit" title="${esc(kit.t('Zoom to fit'))} (0)">${esc(kit.t('Fit'))}</button>
        <button class="pill" type="button" data-zoom="in" title="${esc(kit.t('Zoom in'))} (+)">+</button>
        <button class="pill" type="button" data-copy title="${esc(kit.t('Copy the diagram’s source'))}">${esc(kit.t('Copy'))}</button>
      </div>`;
    const stage = $('.diagram-stage');
    const canvas = $('.diagram-canvas');
    const level = $('.zoom-level');
    let scale = 1;
    let x = 0;
    let y = 0;
    let natural = { width: 0, height: 0 };
    let fitted = false;

    const apply = () => {
      canvas.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
      level.textContent = kit.number(Math.round(scale * 100) / 100, { style: 'percent' });
      fitted = false;
    };
    const fit = () => {
      const pad = 48;
      const w = stage.clientWidth - pad * 2;
      const h = stage.clientHeight - pad * 2;
      if (!natural.width || !natural.height) return;
      scale = Math.min(2, Math.max(0.05, Math.min(w / natural.width, h / natural.height)));
      x = (stage.clientWidth - natural.width * scale) / 2;
      y = (stage.clientHeight - natural.height * scale) / 2;
      apply();
      level.textContent = kit.t('Fit');
      fitted = true;
    };
    const zoomAt = (factor, cx, cy) => {
      const next = Math.min(8, Math.max(0.05, scale * factor));
      const k = next / scale;
      x = cx - (cx - x) * k;
      y = cy - (cy - y) * k;
      scale = next;
      apply();
    };

    const render = async () => {
      if (!window.mermaid) { showError(kit.t('Mermaid isn’t available.')); return; }
      const theme = Object.assign({}, dark() ? MERMAID_THEME.dark : MERMAID_THEME.light, chartVariables(dark()));
      mermaid.initialize({
        startOnLoad: false, securityLevel: 'strict', theme: 'base', themeVariables: theme,
        fontFamily: theme.fontFamily, flowchart: { htmlLabels: true, curve: 'basis' }, legacyMathML: false,
        gantt: { useWidth: 1100 }, sequence: { showSequenceNumbers: false },
      });
      try {
        const id = 'greece-diagram-' + Math.random().toString(36).slice(2);
        // Mermaid sanitises labels itself (securityLevel strict) and the page's CSP blocks
        // scripts; its SVG keeps its own <style>, which the generic sanitiser would strip.
        const { svg } = await mermaid.render(id, mathSafe(source));
        canvas.innerHTML = svg;
        const element = $('svg', canvas);
        if (!element) throw new Error(kit.t('No diagram'));
        const box = element.viewBox && element.viewBox.baseVal && element.viewBox.baseVal.width ? element.viewBox.baseVal : element.getBBox();
        natural = { width: box.width, height: box.height };
        element.setAttribute('width', box.width);
        element.setAttribute('height', box.height);
        element.style.maxWidth = 'none';
        fit();
      } catch (e) {
        showError(String(e && e.message || e).split('\n')[0]);
      }
    };

    let failed = false;
    const showError = (message) => {
      if (failed) return;
      failed = true;
      // Mermaid leaves its own error drawing in the body; keep only ours.
      $$('body > :not(#root):not(script)').forEach((n) => n.remove());
      kit.root.innerHTML = `<div class="diagram-error"><p class="title">${esc(kit.t('This diagram couldn’t be drawn'))}</p><p class="detail">${esc(message)}</p></div><div class="diagram-source"><pre class="code-src">${esc(source)}</pre></div>`;
    };

    await Promise.race([render(), new Promise((r) => setTimeout(r, 2500))]);

    stage.addEventListener('wheel', (e) => {
      e.preventDefault();
      const rect = stage.getBoundingClientRect();
      if (e.ctrlKey || e.metaKey) zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX - rect.left, e.clientY - rect.top);
      else { x -= e.deltaX; y -= e.deltaY; apply(); }
    }, { passive: false });
    let gestureStart = 1;
    stage.addEventListener('gesturestart', (e) => { e.preventDefault(); gestureStart = scale; });
    stage.addEventListener('gesturechange', (e) => {
      e.preventDefault();
      const rect = stage.getBoundingClientRect();
      zoomAt((gestureStart * e.scale) / scale, e.clientX - rect.left, e.clientY - rect.top);
    });
    let drag = null;
    stage.addEventListener('pointerdown', (e) => { if (e.button !== 0) return; drag = { x: e.clientX - x, y: e.clientY - y }; stage.setPointerCapture(e.pointerId); stage.classList.add('dragging'); });
    stage.addEventListener('pointermove', (e) => { if (!drag) return; x = e.clientX - drag.x; y = e.clientY - drag.y; apply(); });
    const end = () => { drag = null; stage.classList.remove('dragging'); };
    stage.addEventListener('pointerup', end);
    stage.addEventListener('pointercancel', end);
    stage.addEventListener('dblclick', fit);
    $$('[data-zoom]').forEach((button) => button.addEventListener('click', () => {
      const kind = button.dataset.zoom;
      if (kind === 'fit') return fit();
      zoomAt(kind === 'in' ? 1.25 : 0.8, stage.clientWidth / 2, stage.clientHeight / 2);
    }));
    const copy = $('[data-copy]');
    if (copy) copy.addEventListener('click', () => kit.copyText(source, copy));
    document.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === '+' || e.key === '=') zoomAt(1.25, stage.clientWidth / 2, stage.clientHeight / 2);
      else if (e.key === '-') zoomAt(0.8, stage.clientWidth / 2, stage.clientHeight / 2);
      else if (e.key === '0') fit();
    });
    window.addEventListener('resize', () => { if (fitted) fit(); });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => render());
  });
})();
