/* Greece — Markdown syntax beyond GFM, as markdown-it plugins that run before the page renders:
   - Content tabs: Material for MkDocs `=== "Tab"` and `:::tabs` containers (`== Tab` / `@tab Tab`)
   - Callouts: GitHub alerts and Obsidian callouts (`> [!note]- Title`, foldable), MkDocs
     admonitions (`!!! note`, `??? note`), Docusaurus and VitePress containers (`:::tip`)
   - Wiki links `[[Page]]`, `[[Page|Alias]]`, `[[#Heading]]`, embeds `![[image.png]]`
   - Definition lists, abbreviations (`*[HTML]: …`), ==mark==, ~sub~ and ^sup^
   - MDX: ESM lines removed, JSX components shown as labelled blocks
   Everything here emits plain, escaped markup; the page sanitises it afterwards. Interactive
   parts (tab switching) live in their own enhancers. The definition-list and abbreviation
   rules follow markdown-it-deflist and markdown-it-abbr (MIT, see Licenses). */
(function () {
  'use strict';

  const greece = window.greece;
  if (!greece || !Array.isArray(greece.markdownPlugins)) return;
  const esc = greece.kit.esc;
  const fileName = String(greece.kit.fileName || '');
  const isMDX = /\.mdx$/i.test(fileName);

  const isSpace = (code) => code === 0x20 || code === 0x09;
  const isWhitespace = (code) => code === 0x20 || code === 0x09 || code === 0x0A || code === 0x0D;

  /** The text of a block line from its first non-space character. */
  function lineText(state, line) {
    return state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
  }

  /** Same ids as the page's own heading slugs (first occurrence). */
  function slug(text) {
    return String(text).trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-') || 'section';
  }

  // ---------------------------------------------------------------- Callout icons and types

  const OCTICONS = {
    note: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
    tip: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"/></svg>',
    important: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>',
    warning: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>',
    caution: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
  };
  const stroke = (body) => `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
  const ICONS = Object.assign({}, OCTICONS, {
    info: OCTICONS.note,
    danger: stroke('<path d="M9 1.5 3.5 9H8l-1 5.5L12.5 7H8z"/>'),
    abstract: stroke('<rect x="3.25" y="2.75" width="9.5" height="11.5" rx="1.75"/><path d="M6 2.75v-.5h4v.5M5.75 7h4.5M5.75 10h3"/>'),
    todo: stroke('<rect x="2.25" y="2.25" width="11.5" height="11.5" rx="3"/><path d="m5.25 8.2 1.9 1.9 3.6-4"/>'),
    success: stroke('<circle cx="8" cy="8" r="6.5"/><path d="m5.25 8.2 1.9 1.9 3.6-4"/>'),
    question: stroke('<circle cx="8" cy="8" r="6.5"/><path d="M6.1 6.2a2 2 0 0 1 3.85.6c0 1.35-1.95 1.6-1.95 2.85"/><path d="M8 11.6v.05" stroke-width="1.9"/>'),
    failure: stroke('<circle cx="8" cy="8" r="6.5"/><path d="m5.9 5.9 4.2 4.2m0-4.2-4.2 4.2"/>'),
    bug: stroke('<rect x="4.75" y="5.25" width="6.5" height="8.5" rx="3.25"/><path d="M6.1 5.4V5a1.9 1.9 0 0 1 3.8 0v.4M2.5 9.25h2.25m6.5 0h2.25M3 5.75l1.9 1.1m8.1-1.1-1.9 1.1M3 13l1.9-1.2m8.1 1.2-1.9-1.2M8 8.5v5"/>'),
    example: stroke('<path d="M6.25 4h7m-7 4h7m-7 4h7"/><path d="M2.75 4h.5m-.5 4h.5m-.5 4h.5" stroke-width="2"/>'),
    quote: stroke('<path d="M3 12V9.25C3 6.6 4.1 4.9 6.5 4.25M3 9h3v3H3zM9.5 12V9.25c0-2.65 1.1-4.35 3.5-5M9.5 9h3v3h-3z"/>'),
  });

  /** Obsidian, GitHub, MkDocs, Docusaurus and VitePress names → one of Greece's styles. */
  const CALLOUTS = {
    note: 'note', info: 'info', todo: 'todo', tip: 'tip', hint: 'tip', important: 'important',
    warning: 'warning', warn: 'warning', attention: 'warning', caution: 'caution',
    danger: 'danger', error: 'danger', abstract: 'abstract', summary: 'abstract', tldr: 'abstract',
    success: 'success', check: 'success', done: 'success', question: 'question', help: 'question',
    faq: 'question', failure: 'failure', fail: 'failure', missing: 'failure', bug: 'bug',
    example: 'example', quote: 'quote', cite: 'quote', details: 'note', seealso: 'note', 'see-also': 'note',
  };
  const TITLES = { tldr: 'TL;DR', faq: 'FAQ', todo: 'To Do', seealso: 'See Also', 'see-also': 'See Also' };

  function calloutMeta(name, fold, title) {
    const key = String(name).toLowerCase();
    const type = CALLOUTS[key] || 'note';
    const fallback = TITLES[key] || key.replace(/[-_]+/g, ' ').replace(/^./, (c) => c.toUpperCase());
    return { type, fold: fold || '', title: title == null ? fallback : title };
  }

  function calloutRenderers(md) {
    md.renderer.rules.callout_open = (tokens, i) => {
      const meta = tokens[i].meta;
      const cls = `alert callout ${meta.type}`;
      if (meta.fold) return `<details class="${cls}"${meta.fold === '+' ? ' open' : ''}>\n`;
      return `<blockquote class="${cls}">\n`;
    };
    md.renderer.rules.callout_close = (tokens, i) => (tokens[i].meta.fold ? '</details>\n' : '</blockquote>\n');
    md.renderer.rules.callout_title_open = (tokens, i) => {
      const meta = tokens[i].meta;
      const tag = meta.fold ? 'summary' : 'p';
      return `<${tag} class="alert-title">${ICONS[meta.type] || ICONS.note}<span>`;
    };
    md.renderer.rules.callout_title_close = (tokens, i) => `</span></${tokens[i].meta.fold ? 'summary' : 'p'}>\n`;
  }

  /** Pushes a callout's opening tokens, with its title parsed as inline Markdown. */
  function pushCalloutOpen(state, meta, map) {
    const open = state.push('callout_open', meta.fold ? 'details' : 'blockquote', 1);
    open.meta = meta;
    open.block = true;
    open.map = map;
    if (meta.title !== '') {
      state.push('callout_title_open', meta.fold ? 'summary' : 'p', 1).meta = meta;
      const inline = state.push('inline', '', 0);
      inline.content = meta.title;
      inline.map = map;
      inline.children = [];
      state.push('callout_title_close', meta.fold ? 'summary' : 'p', -1).meta = meta;
    }
    return open;
  }

  // ------------------------------------------------------- Obsidian and GitHub callouts (> [!x])

  function calloutPlugin(md) {
    calloutRenderers(md);
    md.core.ruler.before('inline', 'greece_callouts', (state) => {
      const tokens = state.tokens;
      for (let i = 0; i + 2 < tokens.length; i++) {
        const open = tokens[i];
        if (open.type !== 'blockquote_open' || tokens[i + 1].type !== 'paragraph_open' || tokens[i + 2].type !== 'inline') continue;
        const inline = tokens[i + 2];
        const content = inline.content;
        const newline = content.indexOf('\n');
        const first = newline < 0 ? content : content.slice(0, newline);
        const match = /^\[!([A-Za-z][\w-]{0,30})\]([+-]?)(?:[ \t]+(.*))?$/.exec(first);
        if (!match) continue;
        let close = -1;
        for (let j = i + 1; j < tokens.length; j++) {
          if (tokens[j].type === 'blockquote_close' && tokens[j].level === open.level) { close = j; break; }
        }
        if (close < 0) continue;
        const title = match[3] && match[3].trim() ? match[3].trim() : null;
        const meta = calloutMeta(match[1], match[2], title);
        open.type = 'callout_open';
        open.tag = meta.fold ? 'details' : 'blockquote';
        open.meta = meta;
        tokens[close].type = 'callout_close';
        tokens[close].tag = open.tag;
        tokens[close].meta = meta;

        const rest = newline < 0 ? '' : content.slice(newline + 1);
        if (rest.trim()) inline.content = rest;
        else tokens.splice(i + 1, 3);

        const titleOpen = new state.Token('callout_title_open', meta.fold ? 'summary' : 'p', 1);
        titleOpen.meta = meta;
        const titleInline = new state.Token('inline', '', 0);
        titleInline.content = meta.title;
        titleInline.children = [];
        titleInline.map = inline.map;
        const titleClose = new state.Token('callout_title_close', meta.fold ? 'summary' : 'p', -1);
        titleClose.meta = meta;
        tokens.splice(i + 1, 0, titleOpen, titleInline, titleClose);
      }
    });
  }

  // ---------------------------------------------- MkDocs admonitions (!!! note "Title", ??? note)

  /** Lines indented four more than `base` (or blank) after `start`; returns the end of the last one. */
  function indentedBlockEnd(state, start, endLine, base) {
    let last = start;
    for (let line = start + 1; line < endLine; line++) {
      if (state.isEmpty(line)) continue;
      if (state.sCount[line] < base + 4) break;
      last = line;
    }
    return last + 1;
  }

  function tokenizeIndented(state, start, end, indent, parentType) {
    const oldIndent = state.blkIndent;
    const oldMax = state.lineMax;
    const oldParent = state.parentType;
    state.blkIndent = indent;
    state.lineMax = end;
    state.parentType = parentType;
    state.md.block.tokenize(state, start, end);
    state.blkIndent = oldIndent;
    state.lineMax = oldMax;
    state.parentType = oldParent;
  }

  function admonitionPlugin(md) {
    md.block.ruler.before('fence', 'greece_admonition', (state, startLine, endLine, silent) => {
      if (state.sCount[startLine] - state.blkIndent >= 4) return false;
      const match = /^(!!!|\?\?\?\+?)[ \t]+([A-Za-z][\w-]{0,30})(?:[ \t]+"([^"]*)")?[ \t]*$/.exec(lineText(state, startLine));
      if (!match) return false;
      if (silent) return true;
      const base = state.sCount[startLine];
      const end = indentedBlockEnd(state, startLine, endLine, base);
      const fold = match[1] === '!!!' ? '' : match[1] === '???+' ? '+' : '-';
      const meta = calloutMeta(match[2], fold, match[3] === undefined ? null : match[3]);
      pushCalloutOpen(state, meta, [startLine, end]);
      if (end > startLine + 1) tokenizeIndented(state, startLine + 1, end, base + 4, 'admonition');
      state.push('callout_close', meta.fold ? 'details' : 'blockquote', -1).meta = meta;
      state.line = end;
      return true;
    }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  }

  // ------------------------------------------------------------------------- Content tabs

  function tabRenderers(md) {
    md.renderer.rules.md_tabs_open = () => '<div class="md-tabs">\n';
    md.renderer.rules.md_tabs_close = () => '</div>\n';
    md.renderer.rules.md_tab_open = (tokens, i) => {
      const meta = tokens[i].meta;
      return `<section class="md-tab" data-label="${esc(meta.label)}"${meta.selected ? ' data-selected=""' : ''}>\n`;
    };
    md.renderer.rules.md_tab_close = () => '</section>\n';
  }

  function tabMarker(state, line) {
    const match = /^===([+!]?)[ \t]+"([^"\n]{0,200})"[ \t]*$/.exec(lineText(state, line));
    return match && { selected: match[1] === '+', label: match[2] };
  }

  /** Material for MkDocs: `=== "Label"` followed by content indented four spaces. */
  function materialTabs(state, startLine, endLine, silent) {
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    if (!tabMarker(state, startLine)) return false;
    if (silent) return true;
    const base = state.sCount[startLine];
    const tabs = [];
    let line = startLine;
    while (line < endLine && tabs.length < 64) {
      const marker = state.sCount[line] === base && tabMarker(state, line);
      if (!marker) break;
      const end = indentedBlockEnd(state, line, endLine, base);
      tabs.push({ label: marker.label, selected: marker.selected, start: line + 1, end });
      line = end;
      while (line < endLine && state.isEmpty(line)) line++;
    }
    const last = tabs[tabs.length - 1].end;
    const open = state.push('md_tabs_open', 'div', 1);
    open.block = true;
    open.map = [startLine, last];
    for (const tab of tabs) {
      state.push('md_tab_open', 'section', 1).meta = tab;
      if (tab.end > tab.start) tokenizeIndented(state, tab.start, tab.end, base + 4, 'md_tabs');
      state.push('md_tab_close', 'section', -1);
    }
    state.push('md_tabs_close', 'div', -1);
    state.line = last;
    return true;
  }

  // ---------------------------------------------------- ::: containers (tabs, tips, details)

  const CONTAINER = /^(:{3,})[ \t]*([A-Za-z][\w-]{0,30})(?:\[([^\]\n]*)\])?[ \t]*(.*)$/;

  function containers(state, startLine, endLine, silent) {
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    const match = CONTAINER.exec(lineText(state, startLine));
    if (!match) return false;
    const name = match[2].toLowerCase();
    if (name !== 'tabs' && !CALLOUTS[name]) return false;
    if (silent) return true;
    const colons = match[1].length;
    // The closing fence has at least as many colons and nothing else.
    let close = startLine + 1;
    let closed = false;
    for (; close < endLine; close++) {
      if (!state.isEmpty(close) && state.sCount[close] < state.blkIndent) break;
      const text = lineText(state, close);
      const fence = /^(:{3,})[ \t]*$/.exec(text);
      if (fence && fence[1].length >= colons && state.sCount[close] - state.blkIndent < 4) { closed = true; break; }
    }
    const indent = state.sCount[startLine];
    const title = (match[3] !== undefined ? match[3] : match[4]).trim();

    if (name === 'tabs') {
      const tabs = [];
      for (let line = startLine + 1; line < close; line++) {
        const marker = /^(?:==|@tab)[ \t]+(.{1,200})$/.exec(lineText(state, line));
        if (marker && state.sCount[line] === indent) {
          if (tabs.length) tabs[tabs.length - 1].end = line;
          tabs.push({ label: marker[1].trim(), start: line + 1, end: close });
        }
      }
      const open = state.push('md_tabs_open', 'div', 1);
      open.block = true;
      open.map = [startLine, close];
      for (const tab of tabs.slice(0, 64)) {
        state.push('md_tab_open', 'section', 1).meta = tab;
        if (tab.end > tab.start) tokenizeIndented(state, tab.start, tab.end, indent, 'md_tabs');
        state.push('md_tab_close', 'section', -1);
      }
      state.push('md_tabs_close', 'div', -1);
    } else {
      // `details` folds closed; everything else is a callout with an optional custom title.
      const meta = calloutMeta(name, name === 'details' ? '-' : '', title || null);
      if (name === 'details' && !title) meta.title = 'Details';
      pushCalloutOpen(state, meta, [startLine, close]);
      if (close > startLine + 1) tokenizeIndented(state, startLine + 1, close, indent, 'container');
      state.push('callout_close', meta.fold ? 'details' : 'blockquote', -1).meta = meta;
    }
    state.line = close + (closed ? 1 : 0);
    return true;
  }

  function tabsPlugin(md) {
    tabRenderers(md);
    calloutRenderers(md);
    md.block.ruler.before('fence', 'greece_material_tabs', materialTabs, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
    md.block.ruler.before('fence', 'greece_containers', containers, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  }

  // ------------------------------------------------------------------------- Wiki links

  const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|bmp|tiff?|heic|avif)$/i;

  function wikiHref(target) {
    const [path, heading] = target.split('#');
    let file = path.trim();
    if (file && !/\.[A-Za-z0-9]{1,8}$/.test(file.split('/').pop())) file += '.md';
    const encoded = file.split('/').map((part) => encodeURIComponent(part)).join('/');
    return encoded + (heading !== undefined && heading.trim() ? '#' + encodeURIComponent(slug(heading)) : '');
  }

  function wikiPlugin(md) {
    md.inline.ruler.before('link', 'greece_wikilink', (state, silent) => {
      const src = state.src;
      let pos = state.pos;
      const embed = src.charCodeAt(pos) === 0x21;
      if (embed) pos += 1;
      if (src.charCodeAt(pos) !== 0x5B || src.charCodeAt(pos + 1) !== 0x5B) return false;
      const nearby = src.slice(pos + 2, Math.min(state.posMax, pos + 404));
      const found = nearby.indexOf(']]');
      if (found < 0) return false;
      const close = pos + 2 + found;
      const inner = src.slice(pos + 2, close);
      if (!inner.trim() || inner.length > 400 || /[\n[\]]/.test(inner)) return false;
      if (!silent) {
        const bar = inner.indexOf('|');
        const target = (bar < 0 ? inner : inner.slice(0, bar)).trim();
        const alias = bar < 0 ? '' : inner.slice(bar + 1).trim();
        const file = target.split('#')[0].trim();
        if (embed && IMAGE_EXT.test(file)) {
          const size = /^(\d{1,4})(?:x(\d{1,4}))?$/.exec(alias);
          const token = state.push('html_inline', '', 0);
          token.content = `<img class="wiki-embed" src="${esc(wikiHref(file))}" alt="${esc(size ? file : alias || file)}"${size ? ` width="${size[1]}"` : ''}${size && size[2] ? ` height="${size[2]}"` : ''}>`;
        } else {
          const heading = target.includes('#') ? target.slice(target.indexOf('#') + 1).trim() : '';
          const href = file ? wikiHref(target) : '#' + encodeURIComponent(slug(heading));
          const label = alias || (file ? file.split('/').pop() + (heading ? ' › ' + heading : '') : heading);
          const open = state.push('link_open', 'a', 1);
          open.attrs = [['href', href], ['class', embed ? 'wikilink embed' : 'wikilink']];
          open.markup = 'wikilink';
          state.push('text', '', 0).content = label;
          state.push('link_close', 'a', -1).markup = 'wikilink';
        }
      }
      state.pos = close + 2;
      return true;
    });
  }

  // ------------------------------------------------------------- ==mark==, ~sub~, ^sup^

  /** ==mark== as paired delimiters, the way markdown-it pairs ~~strikethrough~~ (linear time,
      however many unmatched markers a paragraph holds). Follows markdown-it-mark (MIT). */
  function markPlugin(md) {
    md.inline.ruler.before('emphasis', 'greece_mark', (state, silent) => {
      if (silent || state.src.charCodeAt(state.pos) !== 0x3D) return false;
      const scanned = state.scanDelims(state.pos, true);
      let length = scanned.length;
      if (length < 2) return false;
      if (length % 2) { state.push('text', '', 0).content = '='; length--; }
      for (let i = 0; i < length; i += 2) {
        state.push('text', '', 0).content = '==';
        if (!scanned.can_open && !scanned.can_close) continue;
        state.delimiters.push({ marker: 0x3D, length: 0, token: state.tokens.length - 1, end: -1, open: scanned.can_open, close: scanned.can_close });
      }
      state.pos += scanned.length;
      return true;
    });

    const pair = (state, delimiters) => {
      const lone = [];
      for (const open of delimiters) {
        if (open.marker !== 0x3D || open.end === -1) continue;
        const close = delimiters[open.end];
        const a = state.tokens[open.token];
        a.type = 'mark_open'; a.tag = 'mark'; a.nesting = 1; a.markup = '=='; a.content = '';
        const b = state.tokens[close.token];
        b.type = 'mark_close'; b.tag = 'mark'; b.nesting = -1; b.markup = '=='; b.content = '';
        const before = state.tokens[close.token - 1];
        if (before && before.type === 'text' && before.content === '=') lone.push(close.token - 1);
      }
      // A lone "=" before a closing marker belongs outside it.
      while (lone.length) {
        const i = lone.pop();
        let j = i + 1;
        while (j < state.tokens.length && state.tokens[j].type === 'mark_close') j++;
        j--;
        if (i !== j) { const t = state.tokens[j]; state.tokens[j] = state.tokens[i]; state.tokens[i] = t; }
      }
    };
    md.inline.ruler2.before('emphasis', 'greece_mark', (state) => {
      pair(state, state.delimiters);
      for (const meta of state.tokens_meta || []) if (meta && meta.delimiters) pair(state, meta.delimiters);
    });
  }

  /** Pandoc-style ~sub~ and ^sup^: no spaces inside, no nested markup. */
  function scriptRule(marker, tag) {
    return (state, silent) => {
      const src = state.src;
      const start = state.pos;
      const max = state.posMax;
      if (src.charCodeAt(start) !== marker || silent || start + 2 >= max) return false;
      if (src.charCodeAt(start + 1) === marker) return false;
      state.pos = start + 1;
      let found = false;
      while (state.pos < max) {
        if (src.charCodeAt(state.pos) === marker) { found = true; break; }
        state.md.inline.skipToken(state);
      }
      const content = src.slice(start + 1, state.pos);
      if (!found || !content || /(^|[^\\])(\\\\)*\s/.test(content)) { state.pos = start; return false; }
      state.push(tag + '_open', tag, 1).markup = String.fromCharCode(marker);
      state.push('text', '', 0).content = content.replace(/\\([ \\!"#$%&'()*+,./:;<=>?@[\]^_`{|}~-])/g, '$1');
      state.push(tag + '_close', tag, -1).markup = String.fromCharCode(marker);
      state.pos += 1;
      return true;
    };
  }

  function subSupPlugin(md) {
    md.inline.ruler.after('emphasis', 'greece_sub', scriptRule(0x7E, 'sub'));
    md.inline.ruler.after('emphasis', 'greece_sup', scriptRule(0x5E, 'sup'));
  }

  // ------------------------------------------------------------------ Definition lists

  function deflistMarker(state, line) {
    let start = state.bMarks[line] + state.tShift[line];
    const max = state.eMarks[line];
    if (start >= max) return -1;
    const marker = state.src.charCodeAt(start++);
    if (marker !== 0x7E && marker !== 0x3A) return -1;
    const pos = state.skipSpaces(start);
    if (start === pos || pos >= max) return -1;
    return start;
  }

  function deflistPlugin(md) {
    md.block.ruler.before('paragraph', 'greece_deflist', (state, startLine, endLine, silent) => {
      if (silent) return state.ddIndent >= 0 && deflistMarker(state, startLine) >= 0;
      if (state.sCount[startLine] - state.blkIndent >= 4) return false;
      let nextLine = startLine + 1;
      if (nextLine >= endLine) return false;
      if (state.isEmpty(nextLine)) { nextLine++; if (nextLine >= endLine) return false; }
      if (state.sCount[nextLine] < state.blkIndent) return false;
      let contentStart = deflistMarker(state, nextLine);
      if (contentStart < 0) return false;

      const listIndex = state.tokens.length;
      let tight = true;
      state.push('dl_open', 'dl', 1).map = [startLine, 0];
      let dtLine = startLine;
      let ddLine = nextLine;
      let terms = 0;

      outer: for (;;) {
        if (++terms > 2000) break;
        let prevEmptyEnd = false;
        state.push('dt_open', 'dt', 1).map = [dtLine, dtLine];
        const term = state.push('inline', '', 0);
        term.map = [dtLine, dtLine];
        term.content = state.getLines(dtLine, dtLine + 1, state.blkIndent, false).trim();
        term.children = [];
        state.push('dt_close', 'dt', -1);

        for (;;) {
          const dd = state.push('dd_open', 'dd', 1);
          const itemLines = [nextLine, 0];
          dd.map = itemLines;
          let pos = contentStart;
          const max = state.eMarks[ddLine];
          let offset = state.sCount[ddLine] + contentStart - (state.bMarks[ddLine] + state.tShift[ddLine]);
          while (pos < max) {
            const ch = state.src.charCodeAt(pos);
            if (!isSpace(ch)) break;
            offset += ch === 0x09 ? 4 - (offset % 4) : 1;
            pos++;
          }
          contentStart = pos;
          const old = {
            tight: state.tight, ddIndent: state.ddIndent, indent: state.blkIndent,
            tShift: state.tShift[ddLine], sCount: state.sCount[ddLine], parent: state.parentType,
          };
          state.blkIndent = state.ddIndent = state.sCount[ddLine] + 2;
          state.tShift[ddLine] = contentStart - state.bMarks[ddLine];
          state.sCount[ddLine] = offset;
          state.tight = true;
          state.parentType = 'deflist';
          state.md.block.tokenize(state, ddLine, endLine, true);
          if (!state.tight || prevEmptyEnd) tight = false;
          prevEmptyEnd = (state.line - ddLine) > 1 && state.isEmpty(state.line - 1);
          state.tShift[ddLine] = old.tShift;
          state.sCount[ddLine] = old.sCount;
          state.tight = old.tight;
          state.parentType = old.parent;
          state.blkIndent = old.indent;
          state.ddIndent = old.ddIndent;
          state.push('dd_close', 'dd', -1);
          itemLines[1] = nextLine = state.line;
          if (nextLine >= endLine) break outer;
          if (state.sCount[nextLine] < state.blkIndent) break outer;
          contentStart = deflistMarker(state, nextLine);
          if (contentStart < 0) break;
          ddLine = nextLine;
        }

        if (nextLine >= endLine) break;
        dtLine = nextLine;
        if (state.isEmpty(dtLine) || state.sCount[dtLine] < state.blkIndent) break;
        ddLine = dtLine + 1;
        if (ddLine >= endLine) break;
        if (state.isEmpty(ddLine)) ddLine++;
        if (ddLine >= endLine || state.sCount[ddLine] < state.blkIndent) break;
        contentStart = deflistMarker(state, ddLine);
        if (contentStart < 0) break;
      }

      state.push('dl_close', 'dl', -1);
      state.tokens[listIndex].map[1] = nextLine;
      state.line = nextLine;
      if (tight) {
        const level = state.level + 2;
        for (let i = listIndex + 2, l = state.tokens.length - 2; i < l; i++) {
          if (state.tokens[i].level === level && state.tokens[i].type === 'paragraph_open') {
            state.tokens[i + 2].hidden = true;
            state.tokens[i].hidden = true;
            i += 2;
          }
        }
      }
      return true;
    }, { alt: ['paragraph', 'reference', 'blockquote'] });
  }

  // ---------------------------------------------------------------------- Abbreviations

  function abbrPlugin(md) {
    md.block.ruler.before('reference', 'greece_abbr_def', (state, startLine, endLine, silent) => {
      if (state.sCount[startLine] - state.blkIndent >= 4) return false;
      const match = /^\*\[([^\]\n]{1,80})\]:[ \t]*(.{0,400})$/.exec(lineText(state, startLine));
      if (!match || !match[1].trim()) return false;
      if (silent) return true;
      const env = state.env;
      if (!env.greeceAbbr) env.greeceAbbr = new Map();
      if (env.greeceAbbr.size < 300 && !env.greeceAbbr.has(match[1].trim())) env.greeceAbbr.set(match[1].trim(), match[2].trim());
      state.line = startLine + 1;
      return true;
    }, { alt: ['paragraph', 'reference'] });

    md.core.ruler.after('linkify', 'greece_abbr', (state) => {
      const abbr = state.env.greeceAbbr;
      if (!abbr || !abbr.size) return;
      const keys = Array.from(abbr.keys()).sort((a, b) => b.length - a.length)
        .map((k) => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
      const pattern = new RegExp(`(^|[^\\p{L}\\p{N}_])(${keys.join('|')})(?=$|[^\\p{L}\\p{N}_])`, 'gu');
      for (const block of state.tokens) {
        if (block.type !== 'inline' || !block.children) continue;
        let children = block.children;
        let insideLink = 0;
        for (let j = children.length - 1; j >= 0; j--) {
          const token = children[j];
          if (token.type === 'link_close') { insideLink++; continue; }
          if (token.type === 'link_open') { insideLink--; continue; }
          if (insideLink > 0 || token.type !== 'text') continue;
          const text = token.content;
          pattern.lastIndex = 0;
          if (!pattern.test(text)) continue;
          pattern.lastIndex = 0;
          const nodes = [];
          let last = 0;
          let m;
          while ((m = pattern.exec(text))) {
            const at = m.index + m[1].length;
            if (at > last) { const t = new state.Token('text', '', 0); t.content = text.slice(last, at); nodes.push(t); }
            const open = new state.Token('abbr_open', 'abbr', 1);
            open.attrs = [['title', abbr.get(m[2])]];
            nodes.push(open);
            const word = new state.Token('text', '', 0);
            word.content = m[2];
            nodes.push(word);
            nodes.push(new state.Token('abbr_close', 'abbr', -1));
            last = at + m[2].length;
            pattern.lastIndex = last;
          }
          if (last < text.length) { const t = new state.Token('text', '', 0); t.content = text.slice(last); nodes.push(t); }
          children = children.slice(0, j).concat(nodes, children.slice(j + 1));
        }
        block.children = children;
      }
    });
  }

  // ------------------------------------------------------------------------------- MDX

  const MDX_CALLOUTS = /^(note|tip|info|warning|caution|danger|important|check|success|error|callout|admonition|aside|alert)$/i;
  const MDX_TABS = /^(tabs|codegroup|code-group)$/i;
  const MDX_TAB = /^(tab|tabitem|tabs\.tab)$/i;
  const MDX_DETAILS = /^(details|accordion|expandable|collapsible|collapse)$/i;

  /** Reads a JSX opening tag at `pos`: name, props and whether it closes itself. */
  function readTag(src, pos) {
    const limit = Math.min(src.length, pos + 6000);
    if (src[pos] !== '<') return null;
    let i = pos + 1;
    const nameMatch = /^[A-Za-z][\w.:-]*|^(?=>)/.exec(src.slice(i, i + 120));
    if (!nameMatch) return null;
    const name = nameMatch[0];
    i += name.length;
    const props = [];
    while (i < limit) {
      while (i < limit && /\s/.test(src[i])) i++;
      if (src.startsWith('/>', i)) return { name, props, selfClosing: true, end: i + 2 };
      if (src[i] === '>') return { name, props, selfClosing: false, end: i + 1 };
      if (src[i] === '{') {
        const end = skipBraces(src, i, limit);
        if (end < 0) return null;
        props.push({ name: '', value: src.slice(i, end), expression: true });
        i = end;
        continue;
      }
      const prop = /^[A-Za-z_$][\w:.$-]*/.exec(src.slice(i, i + 200));
      if (!prop) return null;
      i += prop[0].length;
      while (i < limit && /[ \t]/.test(src[i])) i++;
      if (src[i] !== '=') { props.push({ name: prop[0], value: true }); continue; }
      i++;
      while (i < limit && /[ \t]/.test(src[i])) i++;
      const quote = src[i];
      if (quote === '"' || quote === "'") {
        const end = src.indexOf(quote, i + 1);
        if (end < 0 || end > limit) return null;
        props.push({ name: prop[0], value: src.slice(i + 1, end) });
        i = end + 1;
      } else if (quote === '{') {
        const end = skipBraces(src, i, limit);
        if (end < 0) return null;
        props.push({ name: prop[0], value: src.slice(i, end), expression: true });
        i = end;
      } else {
        return null;
      }
    }
    return null;
  }

  /** Index after the brace that closes the one at `pos`, skipping strings. */
  function skipBraces(src, pos, limit) {
    let depth = 0;
    for (let i = pos; i < limit; i++) {
      const c = src[i];
      if (c === '"' || c === "'" || c === '`') {
        const end = src.indexOf(c, i + 1);
        if (end < 0 || end > limit) return -1;
        i = end;
      } else if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) return i + 1; }
    }
    return -1;
  }

  /** Where `</Name>` closes the element whose opening tag ends at `pos` (same-name nesting counted). */
  function findClose(src, name, pos) {
    const open = `<${name}`;
    const close = `</${name}>`;
    let depth = 1;
    let i = pos;
    for (let guard = 0; guard < 5000; guard++) {
      const nextClose = src.indexOf(close, i);
      if (nextClose < 0) return null;
      let nextOpen = src.indexOf(open, i);
      while (nextOpen >= 0 && nextOpen < nextClose && !/[\s/>]/.test(src[nextOpen + open.length] || '')) nextOpen = src.indexOf(open, nextOpen + 1);
      if (nextOpen >= 0 && nextOpen < nextClose) {
        const tag = readTag(src, nextOpen);
        if (tag && !tag.selfClosing) depth++;
        i = tag ? tag.end : nextOpen + open.length;
        continue;
      }
      depth--;
      if (depth === 0) return { start: nextClose, end: nextClose + close.length };
      i = nextClose + close.length;
    }
    return null;
  }

  function propValue(tag, ...names) {
    for (const name of names) {
      const prop = tag.props.find((p) => p.name.toLowerCase() === name);
      if (prop && typeof prop.value === 'string' && !prop.expression) return prop.value;
    }
    return '';
  }

  /** Nextra's `<Tabs items={['npm', 'pnpm']}>`: labels from a literal array of strings. */
  function itemLabels(tag) {
    const prop = tag.props.find((p) => p.name === 'items' && p.expression);
    if (!prop) return [];
    return (prop.value.match(/(["'`])((?:(?!\1).){0,80})\1/g) || []).map((s) => s.slice(1, -1));
  }

  function propsSummary(tag) {
    return tag.props.slice(0, 6).map((p) => {
      if (!p.name) return '{…}';
      if (p.value === true) return p.name;
      const value = String(p.value).replace(/\s+/g, ' ');
      const short = value.length > 40 ? value.slice(0, 39) + '…' : value;
      return p.expression ? `${p.name}=${short}` : `${p.name}="${short}"`;
    }).join(' ') + (tag.props.length > 6 ? ' …' : '');
  }

  function dedent(text) {
    const lines = text.replace(/^\n+|\s+$/g, '').split('\n');
    const indents = lines.filter((l) => l.trim()).map((l) => l.match(/^[ \t]*/)[0].length);
    const cut = indents.length ? Math.min(...indents) : 0;
    return lines.map((l) => l.slice(Math.min(cut, l.match(/^[ \t]*/)[0].length))).join('\n');
  }

  /** Turns a JSX element into Markdown-friendly HTML whose children stay Markdown. */
  function jsxToMarkdown(tag, children, context, depth) {
    const name = tag.name;
    const inner = children == null ? '' : mdxTransform(dedent(children), depth + 1, tag);
    const body = inner.trim() ? `\n\n${inner}\n\n` : '\n';
    if (MDX_CALLOUTS.test(name)) {
      const kind = propValue(tag, 'type', 'variant', 'kind') || name;
      const meta = calloutMeta(/^(callout|admonition|aside|alert)$/i.test(kind) ? 'note' : kind, '', propValue(tag, 'title', 'label') || null);
      return `<blockquote class="alert callout ${meta.type}"><p class="alert-title">${ICONS[meta.type]}<span>${esc(meta.title)}</span></p>${body}</blockquote>\n`;
    }
    if (MDX_TABS.test(name)) return `<div class="md-tabs">${body}</div>\n`;
    if (MDX_TAB.test(name)) {
      let label = propValue(tag, 'title', 'label', 'value', 'name');
      if (!label && context && context.labels) label = context.labels[context.index] || '';
      if (context) context.index += 1;
      return `<section class="md-tab" data-label="${esc(label || 'Tab')}">${body}</section>\n`;
    }
    if (MDX_DETAILS.test(name)) {
      return `<details class="mdx-details"><summary>${esc(propValue(tag, 'title', 'summary', 'label') || name)}</summary>${body}</details>\n`;
    }
    const summary = propsSummary(tag);
    const leaf = children == null || !inner.trim();
    const label = `<p class="mdx-label">&lt;<span class="mdx-name">${esc(name || 'Fragment')}</span>${summary ? ' ' + esc(summary) : ''}${leaf ? ' /' : ''}&gt;</p>`;
    if (leaf) return `<div class="mdx mdx-leaf" data-mdx="${esc(name)}">${label}</div>\n`;
    return `<div class="mdx" data-mdx="${esc(name)}">${label}${body}</div>\n`;
  }

  /** MDX source → Markdown: ESM and comments removed, JSX blocks rewritten. Code fences are left alone. */
  function mdxTransform(src, depth = 0, parent = null) {
    if (depth > 24) return src;
    const lines = src.split('\n');
    const out = [];
    const context = parent && MDX_TABS.test(parent.name) ? { labels: itemLabels(parent), index: 0 } : null;
    let fence = null;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trimStart();
      if (fence) {
        out.push(line);
        if (trimmed.startsWith(fence) && !trimmed.slice(fence.length).replace(/[`~]/g, '').trim()) fence = null;
        continue;
      }
      const opening = /^(`{3,}|~{3,})/.exec(trimmed);
      if (opening && line.length - trimmed.length < 4) { fence = opening[1]; out.push(line); continue; }
      if (depth === 0 && /^(import|export)(\s|\{|\*|$)/.test(line)) { i = skipStatement(lines, i); continue; }
      if (/^\s*\{\s*\/\*/.test(line)) {
        let end = i;
        while (end < lines.length && !/\*\/\s*\}\s*$/.test(lines[end]) && end - i < 200) end++;
        i = end;
        continue;
      }
      if (/^ {0,3}<([A-Z][\w.]*|>)/.test(line)) {
        // A component spans at most a few thousand lines; never join the whole rest of the file.
        const rest = lines.slice(i, i + 3000).join('\n');
        const start = line.indexOf('<');
        const tag = readTag(rest, start);
        if (tag) {
          let consumed;
          let html;
          if (tag.selfClosing) {
            html = jsxToMarkdown(tag, null, context, depth);
            consumed = rest.slice(0, tag.end);
          } else {
            const close = findClose(rest, tag.name, tag.end);
            if (close) {
              html = jsxToMarkdown(tag, rest.slice(tag.end, close.start), context, depth);
              consumed = rest.slice(0, close.end);
            }
          }
          if (html !== undefined) {
            out.push('', html, '');
            i += consumed.split('\n').length - 1;
            continue;
          }
        }
      }
      out.push(line);
    }
    return out.join('\n');
  }

  /** Skips an `import`/`export` statement, which may span several lines. Returns its last line. */
  function skipStatement(lines, start) {
    let depth = 0;
    for (let i = start; i < lines.length && i < start + 400; i++) {
      const code = lines[i].replace(/(["'`])(?:\\.|(?!\1).)*\1/g, '""');
      for (const c of code) {
        if (c === '{' || c === '(' || c === '[') depth++;
        else if (c === '}' || c === ')' || c === ']') depth--;
      }
      const next = lines[i + 1];
      if (depth <= 0 && (next === undefined || !next.trim() || !/^[\s.)}\]]/.test(next))) return i;
    }
    return start;
  }

  function mdxPlugin(md) {
    md.core.ruler.before('normalize', 'greece_mdx', (state) => {
      if (state.src.length <= 4 * 1024 * 1024) state.src = mdxTransform(state.src);
    });
    // {expressions} and {/* comments */} inside prose.
    md.inline.ruler.before('emphasis', 'greece_mdx_expression', (state, silent) => {
      const src = state.src;
      if (src.charCodeAt(state.pos) !== 0x7B) return false;
      const end = skipBraces(src, state.pos, Math.min(state.posMax, state.pos + 400));
      if (end < 0) return false;
      if (!silent) {
        const inner = src.slice(state.pos + 1, end - 1).trim();
        if (!/^\/\*[\s\S]*\*\/$/.test(inner)) {
          const token = state.push('html_inline', '', 0);
          token.content = `<code class="mdx-expr">${esc(inner)}</code>`;
        }
      }
      state.pos = end;
      return true;
    });
  }

  // ------------------------------------------------------------------------- Register

  if (isMDX) greece.markdownPlugins.push(mdxPlugin);
  greece.markdownPlugins.push(calloutPlugin, admonitionPlugin, tabsPlugin, wikiPlugin, markPlugin, subSupPlugin, deflistPlugin, abbrPlugin);

  // For tests and other enhancers.
  window.GreeceMarkdownSyntax = { mdxTransform, slug, wikiHref, calloutMeta };
})();
