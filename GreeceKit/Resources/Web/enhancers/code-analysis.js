/* Greece — code structure without a DOM: brackets, folding regions, indentation, symbols, and an
   index of JSON for the tree view. Pure functions, so the same source runs on the page, in a worker
   (built from this factory's own text) and in tests. Nothing here may recurse on file content. */
(function (factory) {
  const api = factory();
  api.source = '(' + factory.toString() + ')()';
  (typeof self !== 'undefined' ? self : globalThis).GreeceCodeAnalysis = api;
})(function () {
  'use strict';

  // ------------------------------------------------------------------ Languages

  /** How to read a language: comments, strings, and whether structure follows braces or indentation. */
  function config(lang) {
    const g = String(lang || '').toLowerCase();
    const cLike = (extra) => Object.assign({ line: ['//'], block: [['/*', '*/']], quotes: '"', chars: true, family: 'brace', symbols: 'c' }, extra);
    const hash = (extra) => Object.assign({ line: ['#'], block: [], quotes: '"\'', hashWs: true, family: 'indent', symbols: 'none' }, extra);
    switch (g) {
      case 'javascript': case 'typescript': case 'actionscript': case 'haxe':
        return cLike({ quotes: '"\'', multi: '`', chars: false, template: true, regex: true, symbols: 'js' });
      case 'json': return cLike({ chars: false, symbols: 'json' });
      case 'css': return cLike({ line: [], quotes: '"\'', chars: false, symbols: 'css' });
      case 'scss': case 'less': case 'stylus': return cLike({ quotes: '"\'', chars: false, symbols: 'css' });
      case 'swift': return cLike({ chars: false, triple: ['"""'], interp: true, symbols: 'swift' });
      case 'kotlin': return cLike({ triple: ['"""'], symbols: 'kotlin' });
      case 'scala': return cLike({ triple: ['"""'], symbols: 'scala' });
      case 'groovy': case 'gradle': return cLike({ quotes: '"\'', chars: false, triple: ['"""', "'''"] });
      case 'go': return cLike({ multi: '`', symbols: 'go' });
      case 'rust': return cLike({ symbols: 'rust' });
      case 'objectivec': return cLike({ symbols: 'objc' });
      case 'dart': return cLike({ quotes: '"\'', chars: false, triple: ['"""', "'''"] });
      case 'php': case 'php-template': return cLike({ line: ['//', '#'], quotes: '"\'', chars: false, symbols: 'php' });
      case 'protobuf': case 'thrift': case 'capnproto': return cLike({ chars: false, symbols: 'proto' });
      case 'c': case 'cpp': case 'java': case 'csharp': case 'd': case 'arduino': case 'glsl': case 'processing': case 'vala':
        return cLike();
      case 'perl': return hash({ family: 'brace', symbols: 'perl' });
      case 'graphql': return { line: ['#'], block: [], quotes: '"', triple: ['"""'], family: 'brace', symbols: 'graphql' };
      case 'nginx': return hash({ family: 'brace', symbols: 'nginx' });
      case 'powershell': return { line: ['#'], block: [['<#', '#>']], quotes: '"\'', family: 'brace', symbols: 'ps' };
      case 'tcl': return hash({ quotes: '"', family: 'brace' });
      case 'nix': return { line: ['#'], block: [['/*', '*/']], quotes: '"', family: 'brace', symbols: 'none' };
      case 'lisp': case 'clojure': case 'scheme': case 'racket': case 'hy':
        return { line: [';'], block: [], quotes: '"', family: 'brace', symbols: 'lisp' };
      case 'python': return { line: ['#'], block: [], quotes: '"\'', triple: ['"""', "'''"], family: 'indent', symbols: 'python' };
      case 'ruby': case 'crystal': return hash({ symbols: 'ruby' });
      case 'elixir': return hash({ triple: ['"""', "'''"], symbols: 'elixir' });
      case 'bash': case 'shell': return hash({ symbols: 'shell' });
      case 'yaml': return hash({ quotes: '', symbols: 'yaml' });
      case 'toml': case 'ini': case 'properties': return hash({ line: ['#', ';'], symbols: 'ini' });
      case 'makefile': return hash({ quotes: '', symbols: 'make' });
      case 'dockerfile': return hash({ symbols: 'docker' });
      case 'r': return hash({ symbols: 'r' });
      case 'julia': return hash({ symbols: 'julia' });
      case 'cmake': case 'nim': case 'coffeescript': return hash();
      case 'sql': case 'pgsql': return { line: ['--'], block: [['/*', '*/']], quotes: '\'"`', family: 'indent', symbols: 'sql' };
      case 'lua': return { line: ['--'], block: [['--[[', ']]']], quotes: '"\'', family: 'indent', symbols: 'lua' };
      case 'haskell': case 'elm': return { line: ['--'], block: [['{-', '-}']], quotes: '"', family: 'indent', symbols: 'haskell' };
      case 'ocaml': case 'fsharp': case 'sml': return { line: g === 'fsharp' ? ['//'] : [], block: [['(*', '*)']], quotes: '"', family: 'indent', symbols: 'ml' };
      case 'erlang': return { line: ['%'], block: [], quotes: '"', family: 'indent', symbols: 'erlang' };
      case 'matlab': case 'latex': case 'tex': return { line: ['%'], block: [], quotes: '', family: 'indent', symbols: 'none' };
      case 'vbnet': case 'basic': case 'vbscript': return { line: ["'"], block: [], quotes: '"', family: 'indent', symbols: 'none' };
      case 'xml': case 'html': return { line: [], block: [['<!--', '-->']], quotes: '', family: 'indent', markup: true, symbols: 'xml' };
      case 'markdown': case 'plaintext': case 'text': case 'asciidoc': case 'diff': case '':
        return { line: [], block: [], quotes: '', family: 'indent', symbols: 'none' };
      default: return cLike({ chars: false, family: 'auto' });
    }
  }

  // ------------------------------------------------------------------ Lines

  /** Offsets where each line starts; lines end at '\n'. */
  function lineStarts(text) {
    let count = 1;
    for (let i = text.indexOf('\n'); i !== -1; i = text.indexOf('\n', i + 1)) count++;
    const starts = new Int32Array(count);
    let line = 1;
    for (let i = text.indexOf('\n'); i !== -1; i = text.indexOf('\n', i + 1)) starts[line++] = i + 1;
    return starts;
  }

  /** Leading whitespace of every line in columns (tabs to `tabWidth` stops), -1 for blank lines,
      plus the indentation step the file uses. */
  function measureIndent(text, starts, tabWidth) {
    const count = starts.length;
    const indent = new Int16Array(count);
    const tab = Math.max(1, tabWidth | 0 || 4);
    let tabbed = 0, spaced = 0;
    const steps = new Int32Array(9);
    let previous = -1;
    for (let l = 0; l < count; l++) {
      const end = l + 1 < count ? starts[l + 1] - 1 : text.length;
      let i = starts[l], col = 0, sawTab = false;
      for (; i < end; i++) {
        const c = text.charCodeAt(i);
        if (c === 32) col++;
        else if (c === 9) { col = (Math.floor(col / tab) + 1) * tab; sawTab = true; }
        else if (c === 13 || c === 12 || c === 11) col++;
        else break;
      }
      if (i >= end) { indent[l] = -1; continue; }
      indent[l] = Math.min(col, 32000);
      if (col > 0) { if (sawTab) tabbed++; else spaced++; }
      if (previous >= 0) {
        const step = Math.abs(col - previous);
        if (step > 0 && step <= 8) steps[step]++;
      }
      previous = col;
    }
    let unit = 4;
    if (tabbed > spaced) unit = tab;
    else {
      let best = 0;
      for (const candidate of [2, 4, 3, 8]) if (steps[candidate] > best) { best = steps[candidate]; unit = candidate; }
      // A file indented in fours also steps by eight now and then; twos hide inside fours.
      if (unit === 8 && steps[4] * 3 >= steps[8]) unit = 4;
      if (unit === 4 && steps[2] > steps[4] * 2) unit = 2;
    }
    return { indent, unit, tabs: tabbed > spaced };
  }

  /** How many indent guides each line draws: one per step inside its leading whitespace. Blank
      lines take the depth of the code around them. */
  function guideCounts(indent, unit) {
    const count = indent.length;
    const guides = new Uint8Array(count);
    const step = Math.max(1, unit);
    let next = 0;
    for (let l = count - 1; l >= 0; l--) {
      if (indent[l] >= 0) next = indent[l];
      else indent[l] = -1 - next;   // remember the next non-blank indent, temporarily
    }
    let previous = 0;
    for (let l = 0; l < count; l++) {
      let width;
      if (indent[l] >= 0) { width = indent[l]; previous = width; } else {
        const after = -1 - indent[l];
        indent[l] = -1;
        width = Math.min(previous, after);
      }
      guides[l] = Math.min(40, Math.ceil(width / step));
    }
    return guides;
  }

  // ------------------------------------------------------------------ Lexing

  const OPEN = { 40: 41, 91: 93, 123: 125 };      // ( [ {
  const CLOSE = { 41: 40, 93: 91, 125: 123 };
  const REGEX_AFTER = new Set('(,=:[!&|?{};~+-*%<>^'.split('').map((c) => c.charCodeAt(0)));
  const REGEX_WORDS = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await']);
  const isWord = (c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c === 36 || c > 127;

  /** One pass over the text: bracket pairs outside strings and comments, multi-line comments,
      and whether each line starts inside a comment or string. */
  function lex(text, cfg) {
    const n = text.length;
    const starts = [0];
    const modes = [0];
    const bPos = [], bMatch = [], bLine = [];
    const stack = [];
    const pairs = [];     // openLine, closeLine triples (with the open bracket's index)
    const comments = [];  // startLine, endLine, end offset
    const templates = []; // brace depth inside each open ${ … }
    let line = 0;

    const lineComments = cfg.line || [];
    const blocks = cfg.block || [];
    const quotes = cfg.quotes || '';
    const multi = cfg.multi || '';
    const triples = cfg.triple || [];
    const special = new Uint8Array(128);
    special[10] = 1;
    for (const c of '()[]{}') special[c.charCodeAt(0)] = 1;
    for (const c of quotes + multi) special[c.charCodeAt(0)] = 1;
    for (const p of lineComments) special[p.charCodeAt(0)] = 1;
    for (const [o] of blocks) special[o.charCodeAt(0)] = 1;
    for (const t of triples) special[t.charCodeAt(0)] = 1;
    if (cfg.chars) special[39] = 1;
    if (cfg.regex) special[47] = 1;

    const newline = (at, mode) => { line++; starts.push(at + 1); modes.push(mode); };
    const passTo = (from, to, mode) => {
      for (let k = text.indexOf('\n', from); k !== -1 && k < to; k = text.indexOf('\n', k + 1)) newline(k, mode);
    };

    function skipInterpolation(j) {
      let depth = 1;
      while (j < n && depth > 0) {
        const c = text.charCodeAt(j);
        if (c === 40) depth++;
        else if (c === 41) depth--;
        else if (c === 10) return j;
        j++;
      }
      return j;
    }

    /** Scans a quoted string from just after its opening quote. Returns the index after it, or
        -(index + 1) when a template literal opens a ${ expression there. */
    function scanQuoted(j, quote, multiline, template) {
      while (j < n) {
        const c = text.charCodeAt(j);
        if (c === 92) {
          if (cfg.interp && text.charCodeAt(j + 1) === 40) { j = skipInterpolation(j + 2); continue; }
          j += 2;
          continue;
        }
        if (c === quote) return j + 1;
        if (c === 10) {
          if (!multiline) return j;
          newline(j, 2);
        } else if (template && c === 36 && text.charCodeAt(j + 1) === 123) {
          templates.push(0);
          return -(j + 2) - 1;
        }
        j++;
      }
      return n;
    }

    function regexAllowed(i) {
      let k = i - 1;
      while (k >= 0) { const c = text.charCodeAt(k); if (c === 32 || c === 9 || c === 10 || c === 13) k--; else break; }
      if (k < 0) return true;
      const c = text.charCodeAt(k);
      if (REGEX_AFTER.has(c)) return true;
      if (!isWord(c)) return false;
      let s = k;
      while (s > 0 && isWord(text.charCodeAt(s - 1))) s--;
      return REGEX_WORDS.has(text.slice(s, k + 1));
    }

    let i = 0;
    outer: while (i < n) {
      const c = text.charCodeAt(i);
      if (c >= 128 || !special[c]) { i++; continue; }
      if (c === 10) { newline(i, 0); i++; continue; }

      for (const [open, close] of blocks) {
        if (text.startsWith(open, i)) {
          const startLine = line;
          const found = text.indexOf(close, i + open.length);
          const end = found === -1 ? n : found + close.length;
          passTo(i, end, 1);
          if (line > startLine) comments.push(startLine, line, end);
          i = end;
          continue outer;
        }
      }
      for (const prefix of lineComments) {
        if (text.startsWith(prefix, i)) {
          if (cfg.hashWs && prefix === '#' && i > 0) {
            const before = text.charCodeAt(i - 1);
            if (before !== 32 && before !== 9 && before !== 10 && before !== 59) break;
          }
          const end = text.indexOf('\n', i);
          i = end === -1 ? n : end;
          continue outer;
        }
      }
      for (const triple of triples) {
        if (text.startsWith(triple, i)) {
          const found = text.indexOf(triple, i + triple.length);
          const end = found === -1 ? n : found + triple.length;
          passTo(i, end, 2);
          i = end;
          continue outer;
        }
      }
      if (c === 39 && cfg.chars) {
        // A character literal ('a', '\n', '\u{1F600}'), or a Rust lifetime / stray apostrophe.
        if (text.charCodeAt(i + 1) === 92) {
          const close = text.indexOf("'", i + 3);
          const nl = text.indexOf('\n', i);
          i = close !== -1 && close - i <= 12 && (nl === -1 || close < nl) ? close + 1 : i + 1;
        } else if (text.charCodeAt(i + 2) === 39 && text.charCodeAt(i + 1) !== 10) i += 3;
        else if (text.charCodeAt(i + 3) === 39 && (text.charCodeAt(i + 1) & 0xFC00) === 0xD800) i += 4;
        else i++;
        continue;
      }
      if (quotes.indexOf(text[i]) !== -1 || multi.indexOf(text[i]) !== -1) {
        const isMulti = multi.indexOf(text[i]) !== -1;
        const r = scanQuoted(i + 1, c, isMulti, cfg.template && c === 96);
        i = r < 0 ? -r - 1 : r;
        continue;
      }
      if (c === 47 && cfg.regex && regexAllowed(i)) {
        let j = i + 1, inClass = false, ok = false;
        while (j < n) {
          const d = text.charCodeAt(j);
          if (d === 92) { j += 2; continue; }
          if (d === 10) break;
          if (d === 91) inClass = true;
          else if (d === 93) inClass = false;
          else if (d === 47 && !inClass) { ok = j > i + 1; j++; break; }
          j++;
        }
        if (ok) {
          while (j < n && isWord(text.charCodeAt(j))) j++;
          i = j;
        } else i++;
        continue;
      }
      if (OPEN[c]) {
        if (c === 123 && templates.length) templates[templates.length - 1]++;
        stack.push(bPos.length);
        bPos.push(i); bMatch.push(-1); bLine.push(line);
        i++;
        continue;
      }
      if (CLOSE[c]) {
        if (c === 125 && templates.length) {
          if (templates[templates.length - 1] === 0) {
            templates.pop();
            const r = scanQuoted(i + 1, 96, true, true);
            i = r < 0 ? -r - 1 : r;
            continue;
          }
          templates[templates.length - 1]--;
        }
        const index = bPos.length;
        bPos.push(i); bMatch.push(-1); bLine.push(line);
        const want = CLOSE[c];
        for (let d = stack.length - 1; d >= 0 && d >= stack.length - 4; d--) {
          const open = stack[d];
          if (text.charCodeAt(bPos[open]) !== want) continue;
          stack.length = d;
          bMatch[open] = i;
          bMatch[index] = bPos[open];
          if (bLine[open] < line) pairs.push(bLine[open], line, open);
          break;
        }
        i++;
        continue;
      }
      i++;
    }
    return {
      starts: Int32Array.from(starts),
      modes: Uint8Array.from(modes),
      brackets: { pos: Int32Array.from(bPos), match: Int32Array.from(bMatch) },
      pairs, comments,
    };
  }

  // ------------------------------------------------------------------ Regions

  const CLOSER_ONLY = /^[)\]}]+[)\]};,]*$/;
  const WORD_CLOSER = /^(?:end\b[\w ]*|fi|done|esac|endif|endfor|endwhile|endfunction|endforeach|endswitch|wend|loop)[;,)]*$/i;
  const MARKUP_CLOSER = /^<\/[^<>]+>$/;
  const OPENER_ONLY = /^[([{]+$/;

  function lineText(text, starts, l) {
    const end = l + 1 < starts.length ? starts[l + 1] - 1 : text.length;
    return text.slice(starts[l], end);
  }

  /** Folding regions, sorted and properly nested. Each region has a header line, the last line of
      its scope, and the last line folding hides (a line of closing brackets folds into the header). */
  function buildRegions(text, cfg, lexed, indent) {
    const starts = lexed.starts;
    const count = starts.length;
    const found = new Map();
    const blank = (l) => indent[l] < 0 || lexed.modes[l] !== 0;
    const add = (header, end, hide, tail) => {
      if (hide <= header) return;
      const existing = found.get(header);
      if (!existing || end > existing.end) found.set(header, { end, hide, tail });
    };

    let family = cfg.family;
    if (family === 'auto') {
      let braces = 0, lines = 0;
      for (let l = 0; l < count && l < 4000; l++) {
        if (indent[l] < 0) continue;
        lines++;
        if (/[{[]\s*$/.test(lineText(text, starts, l))) braces++;
      }
      family = braces * 25 >= lines && braces > 0 ? 'brace' : 'indent';
    }

    if (family === 'brace') {
      const pairs = lexed.pairs;
      for (let p = 0; p < pairs.length; p += 3) {
        const open = pairs[p], close = pairs[p + 1];
        let header = open;
        if (OPENER_ONLY.test(lineText(text, starts, open).trim())) {
          // Allman style: the line above names the block.
          let above = open - 1;
          while (above >= 0 && indent[above] < 0) above--;
          if (above >= 0 && lexed.modes[above] === 0 && !/[;,{}[(]\s*$/.test(lineText(text, starts, above))) header = above;
        }
        const closerOnly = CLOSER_ONLY.test(lineText(text, starts, close).trim());
        add(header, close, closerOnly ? close : close - 1, closerOnly);
      }
    } else {
      const stack = [];
      let last = -1;
      const finish = (header, next) => {
        if (last <= header) return;
        let end = last, tail = false;
        if (next >= 0 && indent[next] === indent[header]) {
          const t = lineText(text, starts, next).trim();
          if (CLOSER_ONLY.test(t) || WORD_CLOSER.test(t) || (cfg.markup && MARKUP_CLOSER.test(t))) { end = next; tail = true; }
        }
        add(header, end, end, tail);
      };
      for (let l = 0; l < count; l++) {
        if (blank(l)) continue;
        const depth = indent[l];
        while (stack.length && indent[stack[stack.length - 1]] >= depth) finish(stack.pop(), l);
        stack.push(l);
        last = l;
      }
      while (stack.length) finish(stack.pop(), -1);
    }

    // Comments spanning lines fold too, unless code follows them on their last line.
    const comments = lexed.comments;
    for (let k = 0; k < comments.length; k += 3) {
      const first = comments[k], lastLine = comments[k + 1], endOffset = comments[k + 2];
      const lineEnd = lastLine + 1 < count ? starts[lastLine + 1] - 1 : text.length;
      const codeAfter = text.slice(endOffset, lineEnd).trim() !== '';
      if (!found.has(first)) add(first, lastLine, codeAfter ? lastLine - 1 : lastLine, !codeAfter);
    }

    const headers = Array.from(found.keys()).sort((a, b) => a - b);
    const start = [], end = [], hide = [], tail = [], parent = [];
    const open = [];
    for (const h of headers) {
      const r = found.get(h);
      while (open.length && end[open[open.length - 1]] <= h) open.pop();
      const up = open.length ? open[open.length - 1] : -1;
      // Regions that cross their parent come from unbalanced code: leave them out.
      if (up >= 0 && r.end > end[up]) continue;
      const index = start.length;
      start.push(h); end.push(r.end); hide.push(r.hide); tail.push(r.tail ? 1 : 0); parent.push(up);
      open.push(index);
    }
    const at = new Int32Array(count).fill(-1);
    for (let k = 0; k < start.length; k++) at[start[k]] = k;
    return {
      family,
      start: Int32Array.from(start), end: Int32Array.from(end), hide: Int32Array.from(hide),
      tail: Uint8Array.from(tail), parent: Int32Array.from(parent), at,
    };
  }

  // ------------------------------------------------------------------ Symbols

  const KIND = {
    class: 'class', struct: 'struct', enum: 'enum', protocol: 'protocol', interface: 'protocol', trait: 'protocol',
    extension: 'extension', impl: 'extension', actor: 'class', object: 'class', record: 'struct', union: 'struct',
    namespace: 'namespace', module: 'namespace', mod: 'namespace', package: 'namespace', type: 'type', typealias: 'type',
    implementation: 'extension', data: 'type', newtype: 'type', instance: 'extension',
    query: 'query', mutation: 'query', subscription: 'query', fragment: 'query', input: 'class', scalar: 'type', schema: 'namespace', directive: 'func',
    message: 'struct', service: 'protocol', rpc: 'func', oneof: 'enum',
    table: 'table', view: 'table', index: 'table', function: 'func', procedure: 'func', trigger: 'func', sequence: 'table',
    'materialized view': 'table',
  };
  const CONTROL = new Set(['if', 'for', 'while', 'switch', 'catch', 'return', 'new', 'else', 'do', 'sizeof', 'typeof', 'throw', 'case',
    'await', 'using', 'lock', 'foreach', 'elif', 'when', 'with', 'try', 'delete', 'defer', 'guard', 'match', 'yield', 'select', 'goto', 'function']);
  const OBJC = { interface: 'class', implementation: 'extension', protocol: 'protocol' };
  const KEYFRAME_STEP = /^(?:\d+(?:\.\d+)?%|from|to)(?:\s*,\s*(?:\d+(?:\.\d+)?%|from|to))*$/;

  const MOD = '(?:(?:@[\\w.]+(?:\\([^)]*\\))?|public|private|protected|internal|fileprivate|open|static|final|abstract|sealed|override|virtual|async|export|default|declare|readonly|unsafe|extern|inline|const|constexpr|pub(?:\\([^)]*\\))?|partial|data|value|inner|enum|case|lazy|mutating|nonmutating|nonisolated|isolated|convenience|required|indirect|distributed|dynamic|weak|unowned|class|annotation|companion|tailrec|operator|infix|suspend|expect|actual|synchronized|native|transient|strictfp)\\s+)*';
  const TYPES = 'class|struct|enum|interface|protocol|extension|trait|union|namespace|module|object|record|actor|typealias';
  const MARKS = [
    [/^\s*\/\/\s*MARK:\s*-?\s*(\S.*?)\s*$/, 'mark', 1],
    [/^\s*#pragma\s+mark\s+-?\s*(\S.*?)\s*$/, 'mark', 1],
    [/^\s*(?:\/\/\s*)?#\s*region\b\s*(\S.*?)?\s*$/, 'mark', 1],
  ];
  const re = (source, flags) => new RegExp(source, flags);
  const C_FUNCTION = [re('^\\s*' + MOD + '(?:[\\w$<>\\[\\],.?*&:~]+\\s+)+[*&]*([A-Za-z_~$][\\w$:~]*)\\s*\\('), 'func', 1, 'header'];
  const C_TYPES = [re('^\\s*' + MOD + '(' + TYPES + ')\\s+(?:class\\s+)?([A-Za-z_$][\\w$.]*)'), null, 2];

  const SYMBOLS = {
    c: [...MARKS, C_TYPES, C_FUNCTION],
    swift: [...MARKS,
      [re('^\\s*' + MOD + '(class|struct|enum|protocol|extension|actor|typealias)\\s+([A-Za-z_][\\w.]*)'), null, 2],
      [re('^\\s*' + MOD + 'func\\s+([^\\s(<]+)'), 'func', 1],
      [re('^\\s*' + MOD + '(init[?!]?|deinit|subscript)\\s*[(<{]'), 'func', 1],
      [re('^\\s*' + MOD + '(?:var|let)\\s+([A-Za-z_]\\w*)\\s*:[^={]*\\{\\s*$'), 'property', 1, 'header']],
    js: [...MARKS,
      [/^\s*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(class|interface|enum|namespace|module|type)\s+([A-Za-z_$][\w$]*)/, null, 2],
      [/^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/, 'func', 1],
      [/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[A-Za-z_$][\w$]*\s*=>)/, 'func', 1],
      [/^\s*([A-Za-z_$][\w$]*)\s*:\s*(?:async\s+)?function\b/, 'func', 1],
      [/^\s*(?:(?:public|private|protected|static|async|readonly|override|abstract|get|set)\s+)*\*?\s*(#?[A-Za-z_$][\w$]*)\s*\([^)]*\)\s*(?::\s*[^{=]+)?\{\s*$/, 'method', 1, 'header']],
    go: [[/^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)/, 'func', 1],
      [/^type\s+([A-Za-z_]\w*)\s+(struct|interface)\b/, 'go-type', 1],
      [/^type\s+([A-Za-z_]\w*)\s/, 'type', 1]],
    rust: [[/^\s*(?:pub(?:\([^)]*\))?\s+)?(?:(?:async|const|unsafe|extern(?:\s+"[^"]*")?)\s+)*fn\s+([A-Za-z_]\w*)/, 'func', 1],
      [/^\s*(?:pub(?:\([^)]*\))?\s+)?(struct|enum|trait|union|mod|type)\s+([A-Za-z_]\w*)/, null, 2],
      [/^\s*impl(?:<[^>]*>)?\s+([^{]+?)\s*(?:where\b.*)?\{?\s*$/, 'extension', 1],
      [/^\s*macro_rules!\s*([A-Za-z_]\w*)/, 'func', 1]],
    kotlin: [...MARKS, C_TYPES, [re('^\\s*' + MOD + 'fun\\s+(?:<[^>]*>\\s*)?(?:[\\w.]+\\.)?([A-Za-z_]\\w*)'), 'func', 1]],
    scala: [C_TYPES, [/^\s*(?:(?:override|private|protected|final|implicit|inline)\s+)*def\s+([A-Za-z_][\w]*|[^\s(:[]+)/, 'func', 1]],
    objc: [...MARKS, [/^\s*@(interface|implementation|protocol)\s+([A-Za-z_]\w*)/, 'objc-type', 2],
      [/^\s*[-+]\s*\([^)]*\)\s*([A-Za-z_]\w*:?)/, 'method', 1], C_TYPES, C_FUNCTION],
    php: [[/^\s*(?:(?:abstract|final|readonly)\s+)*(class|interface|trait|enum)\s+([A-Za-z_]\w*)/, null, 2],
      [/^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+&?\s*([A-Za-z_]\w*)/, 'func', 1]],
    proto: [[/^\s*(message|service|enum|rpc|oneof)\s+([A-Za-z_]\w*)/, null, 2]],
    perl: [[/^\s*sub\s+([A-Za-z_][\w:]*)/, 'func', 1], [/^\s*package\s+([A-Za-z_][\w:]*)/, 'namespace', 1]],
    graphql: [[/^\s*(?:extend\s+)?(query|mutation|subscription|fragment|type|interface|enum|input|union|scalar|directive)\s+@?([A-Za-z_]\w*)/, null, 2]],
    nginx: [[/^\s*((?:server|location|upstream|http|events|map|stream)\b[^{]*?)\s*\{\s*$/, 'section', 1, 'header']],
    ps: [[/^\s*function\s+([\w-]+)/i, 'func', 1], [/^\s*class\s+(\w+)/i, 'class', 1]],
    lisp: [[/^\s*\((?:defn-?|defmacro|defun|define|defclass|defstruct|defprotocol|defrecord|deftype|defmethod|defmulti|def)\s+\(?([^\s()]+)/, 'func', 1]],
    python: [[/^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)/, 'func', 1], [/^\s*class\s+([A-Za-z_]\w*)/, 'class', 1], [/^#\s*%%\s*(\S.*?)\s*$/, 'mark', 1]],
    ruby: [[/^\s*def\s+(?:self\.)?([\w?!=\[\]<>+-]+)/, 'func', 1], [/^\s*(class|module)\s+([A-Z][\w:]*)/, null, 2]],
    elixir: [[/^\s*defmodule\s+([\w.]+)/, 'namespace', 1], [/^\s*(?:defp?|defmacrop?|defguard)\s+([\w?!]+)/, 'func', 1]],
    shell: [[/^\s*(?:function\s+)?([A-Za-z_][\w.:-]*)\s*\(\)\s*\{?/, 'func', 1], [/^\s*function\s+([A-Za-z_][\w.:-]*)/, 'func', 1]],
    yaml: [[/^\s*(?:-\s+)?((?:"[^"]*"|'[^']*'|[^\s#:'"][^:#]*?)):\s*(?:[&!]\S*\s*)?(?:#.*)?$/, 'key', 1, 'header']],
    ini: [[/^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(?:[#;].*)?$/, 'section', 1]],
    make: [[/^([A-Za-z0-9_.\/%$()-][^:=#\s]*(?:\s+[^:=#\s]+)*)\s*::?(?!=)/, 'target', 1]],
    docker: [[/^\s*FROM\s+(\S+)(?:\s+AS\s+(\S+))?/i, 'stage', 2]],
    r: [[/^\s*([\w.]+)\s*(?:<-|=)\s*function\b/, 'func', 1]],
    julia: [[/^\s*function\s+([\w.!]+)/, 'func', 1], [/^\s*(?:mutable\s+)?struct\s+(\w+)/, 'struct', 1], [/^\s*module\s+(\w+)/, 'namespace', 1]],
    sql: [[/^\s*create\s+(?:or\s+replace\s+)?(?:(?:temp|temporary|unique|virtual)\s+)*(table|view|index|function|procedure|trigger|sequence|materialized\s+view)\s+(?:if\s+not\s+exists\s+)?([\w."`\[\]]+)/i, null, 2]],
    lua: [[/^\s*(?:local\s+)?function\s+([\w.:]+)/, 'func', 1], [/^\s*(?:local\s+)?([\w.]+)\s*=\s*function\b/, 'func', 1]],
    haskell: [[/^(data|newtype|type|class|instance)\s+([A-Z][\w']*)/, null, 2], [/^([a-z_][\w']*)\s*::/, 'func', 1]],
    ml: [[/^\s*(?:let|and)\s+(?:rec\s+)?(?:inline\s+)?([a-z_][\w']*)/, 'func', 1], [/^\s*(module|type)\s+(?:rec\s+)?([\w']+)/, null, 2]],
    erlang: [[/^([a-z][\w]*)\s*\(/, 'func', 1]],
    css: [[/^\s*(@(?:media|supports|keyframes|font-face|layer|container|page|document)[^{]*?|[^@\s{}][^{}]*?)\s*\{\s*$/, 'rule', 1, 'header']],
    json: [[/^\s*"((?:[^"\\]|\\.)*)"\s*:\s*[[{]/, 'key', 1, 'header']],
    xml: [[/<h([1-6])\b[^>]*>(.*?)<\/h\1\s*>/i, 'mark', 2]],
    none: [],
  };
  const MAX_DEPTH = { rule: 1, key: 1, section: 2 };
  const TYPE_KINDS = new Set(['class', 'struct', 'enum', 'protocol', 'extension', 'namespace', 'type']);

  function findSymbols(text, cfg, lexed, regions) {
    const patterns = SYMBOLS[cfg.symbols] || SYMBOLS.none;
    if (!patterns.length) return [];
    const starts = lexed.starts;
    const count = starts.length;
    const found = [];
    for (let l = 0; l < count && found.length < 5000; l++) {
      const header = regions.at[l] >= 0;
      const s = lineText(text, starts, l);
      if (!s || s.length > 2000) continue;
      for (const [pattern, kind, group, only] of patterns) {
        if (only === 'header' && !header) continue;
        if (kind !== 'mark' && lexed.modes[l] !== 0) continue;
        const m = pattern.exec(s);
        if (!m) continue;
        let name = (m[group] || m[1] || '').trim();
        if (!name) continue;
        let k = kind;
        if (k === null) k = KIND[String(m[1]).toLowerCase().replace(/\s+/g, ' ')] || 'type';
        else if (k === 'go-type') k = m[2] === 'struct' ? 'struct' : 'protocol';
        else if (k === 'objc-type') k = OBJC[m[1]];
        if (k === 'rule' && KEYFRAME_STEP.test(name)) continue;
        if (k === 'func' || k === 'method') {
          const first = s.trim().split(/[\s(]/)[0];
          const bare = name.replace(/^.*[:.]/, '');
          if (CONTROL.has(bare) || (first !== 'function' && CONTROL.has(first))) continue;
        }
        if (k === 'rule' || k === 'section') name = name.replace(/\s+/g, ' ');
        if (name.length > 100) name = name.slice(0, 99) + '…';
        found.push({ line: l, end: header ? regions.end[regions.at[l]] : l, name, kind: k, depth: 0 });
        break;
      }
    }
    // Nesting: symbols inside other symbols' scopes.
    const stack = [];
    const result = [];
    for (const symbol of found) {
      while (stack.length && stack[stack.length - 1].end < symbol.line) stack.pop();
      symbol.depth = stack.length;
      const parent = stack[stack.length - 1];
      if (symbol.kind === 'func' && parent && TYPE_KINDS.has(parent.kind)) symbol.kind = 'method';
      if (MAX_DEPTH[symbol.kind] !== undefined && symbol.depth > MAX_DEPTH[symbol.kind]) continue;
      result.push(symbol);
      if (symbol.end > symbol.line) stack.push(symbol);
    }
    return result;
  }

  // ------------------------------------------------------------------ Everything

  /** Structure of a whole file. `text` uses '\n' line breaks. */
  function analyze(text, lang, tabWidth) {
    const cfg = config(lang);
    const lexed = lex(text, cfg);
    const { indent } = measureIndent(text, lexed.starts, tabWidth || 4);
    const regions = buildRegions(text, cfg, lexed, indent);
    const symbols = findSymbols(text, cfg, lexed, regions);
    return { lineCount: lexed.starts.length, family: regions.family, regions, brackets: lexed.brackets, symbols, modes: lexed.modes };
  }

  /** Typed arrays in an analysis, for transferring it from a worker without copying. */
  function transferables(result) {
    const r = result.regions;
    return [r.start.buffer, r.end.buffer, r.hide.buffer, r.tail.buffer, r.parent.buffer, r.at.buffer,
      result.brackets.pos.buffer, result.brackets.match.buffer, result.modes.buffer];
  }

  // ------------------------------------------------------------------ JSON index

  const T = { object: 1, array: 2, string: 3, number: 4, true: 5, false: 6, null: 7, other: 8 };

  /** Indexes JSON (and JSONC, JSON5-ish, or one value per line) without building objects: every
      value is a node in document order with its type, extent, key, parent and next sibling. Node 0
      is a synthetic root holding the top-level values. Tolerant of comments, trailing commas,
      unquoted keys and single quotes; never recursive. */
  function indexJSON(text, options) {
    const maxNodes = (options && options.maxNodes) || 6000000;
    const n = text.length;
    let cap = Math.max(256, Math.min(maxNodes, (n >> 5) + 16));
    let type = new Uint8Array(cap), start = new Uint32Array(cap), end = new Uint32Array(cap);
    let key = new Int32Array(cap), next = new Uint32Array(cap), parent = new Int32Array(cap);
    let count = 0;
    let truncated = false;
    function grow() {
      const size = Math.min(maxNodes, cap * 2);
      const copy = (Ctor, old) => { const a = new Ctor(size); a.set(old); return a; };
      type = copy(Uint8Array, type); start = copy(Uint32Array, start); end = copy(Uint32Array, end);
      key = copy(Int32Array, key); next = copy(Uint32Array, next); parent = copy(Int32Array, parent);
      cap = size;
    }
    function node(t, s, k, p) {
      if (count >= cap) {
        if (cap >= maxNodes) { truncated = true; return -1; }
        grow();
      }
      type[count] = t; start[count] = s; end[count] = s; key[count] = k; parent[count] = p; next[count] = count + 1;
      return count++;
    }
    function scanString(i) {
      const q = text.charCodeAt(i);
      let j = i + 1;
      for (;;) {
        const k = text.indexOf(q === 39 ? "'" : '"', j);
        if (k === -1) return n;
        let b = k - 1;
        while (b > i && text.charCodeAt(b) === 92) b--;
        if ((k - 1 - b) % 2 === 0) return k + 1;
        j = k + 1;
      }
    }
    const delimiter = (c) => c === 44 || c === 58 || c === 93 || c === 125 || c === 91 || c === 123 || c <= 32 || c === 34 || c === 47;

    node(T.array, 0, -1, -1);
    const stack = [0];
    let pendingKey = -1;
    let i = 0;
    let error = null;
    while (i < n) {
      const c = text.charCodeAt(i);
      if (c <= 32 || c === 44 || c === 0xFEFF) { i++; continue; }
      if (c === 47 && text.charCodeAt(i + 1) === 47) { const e = text.indexOf('\n', i); i = e === -1 ? n : e; continue; }
      if (c === 47 && text.charCodeAt(i + 1) === 42) { const e = text.indexOf('*/', i + 2); i = e === -1 ? n : e + 2; continue; }
      const top = stack[stack.length - 1];
      if (c === 125 || c === 93) {
        if (stack.length > 1) {
          stack.pop();
          end[top] = i + 1;
          next[top] = count;
        } else if (!error) error = { offset: i, message: 'Unexpected ' + text[i] };
        pendingKey = -1;
        i++;
        continue;
      }
      if (type[top] === T.object && pendingKey < 0) {
        // A key: quoted, or bare (JSON5).
        const k = i;
        if (c === 34 || c === 39) i = scanString(i);
        else { while (i < n && !delimiter(text.charCodeAt(i))) i++; if (i === k) i++; }
        let j = i;
        while (j < n && text.charCodeAt(j) <= 32) j++;
        if (text.charCodeAt(j) === 58) { pendingKey = k; i = j + 1; continue; }
        if (!error) error = { offset: k, message: 'Expected a colon after a key' };
        pendingKey = k;
        continue;
      }
      if (c === 58) { i++; continue; }
      const index = node(T.other, i, pendingKey, top);
      pendingKey = -1;
      if (index < 0) break;
      if (c === 123 || c === 91) {
        type[index] = c === 123 ? T.object : T.array;
        stack.push(index);
        i++;
        continue;
      }
      if (c === 34 || c === 39) {
        type[index] = T.string;
        i = scanString(i);
      } else {
        const s = i;
        while (i < n && !delimiter(text.charCodeAt(i))) i++;
        if (i === s) i++;
        const word = text.slice(s, i);
        if (word === 'true') type[index] = T.true;
        else if (word === 'false') type[index] = T.false;
        else if (word === 'null') type[index] = T.null;
        else if (/^[-+]?(?:\d|\.\d|0x[\da-f]|Infinity|NaN)/i.test(word)) type[index] = T.number;
        else if (!error) error = { offset: s, message: 'Unexpected ' + word.slice(0, 20) };
      }
      end[index] = i;
      next[index] = count;
    }
    if (stack.length > 1 && !error && !truncated) error = { offset: n, message: 'Unexpected end of file' };
    while (stack.length > 1) { const top = stack.pop(); end[top] = n; next[top] = count; }
    end[0] = n;
    next[0] = count;
    return {
      count, truncated, error,
      type: type.subarray(0, count), start: start.subarray(0, count), end: end.subarray(0, count),
      key: key.subarray(0, count), next: next.subarray(0, count), parent: parent.subarray(0, count),
    };
  }

  /** The children of a container node, in order. */
  function childrenOf(index, at) {
    const out = [];
    const stop = at.next[index];
    for (let c = index + 1; c < stop && c < at.count; c = at.next[c]) out.push(c);
    return out;
  }

  /** Reads a JSON string token's text (escapes decoded); falls back to the raw characters. */
  function stringValue(text, from, to) {
    const raw = text.slice(from, to);
    if (raw.charCodeAt(0) === 34) { try { return JSON.parse(raw); } catch (_) { } }
    if (raw.length >= 2 && (raw[0] === '"' || raw[0] === "'")) return raw.slice(1, raw[raw.length - 1] === raw[0] ? -1 : undefined);
    return raw;
  }

  /** A key's text, for object members. */
  function keyText(text, at, index) {
    const k = at.key[index];
    if (k < 0) return null;
    const c = text.charCodeAt(k);
    if (c === 34 || c === 39) {
      let j = k + 1;
      for (;;) {
        const e = text.indexOf(text[k], j);
        if (e === -1) return stringValue(text, k, text.length);
        let b = e - 1;
        while (b > k && text.charCodeAt(b) === 92) b--;
        if ((e - 1 - b) % 2 === 0) return stringValue(text, k, e + 1);
        j = e + 1;
      }
    }
    let j = k;
    while (j < text.length && !/[\s:,{}[\]]/.test(text[j])) j++;
    return text.slice(k, j);
  }

  /** `$.berths[0].vessel.name`, with brackets for keys that aren't identifiers. */
  function pathOf(text, at, index) {
    const parts = [];
    for (let i = index; i > 0; i = at.parent[i]) {
      const p = at.parent[i];
      if (p > 0 && at.type[p] === T.object) {
        const k = keyText(text, at, i);
        parts.push(/^[A-Za-z_$][\w$]*$/.test(k) ? '.' + k : '[' + JSON.stringify(k) + ']');
      } else if (p > 0) {
        let position = 0;
        for (let c = p + 1; c < i; c = at.next[c]) position++;
        parts.push('[' + position + ']');
      } else if (at.count > 1 && at.next[1] < at.next[0]) {
        let position = 0;
        for (let c = 1; c < i; c = at.next[c]) position++;
        parts.push('[' + position + ']');
      }
    }
    return '$' + parts.reverse().join('');
  }

  return {
    config, lineStarts, measureIndent, guideCounts, lex, buildRegions, findSymbols, analyze, transferables,
    indexJSON, childrenOf, stringValue, keyText, pathOf, JSON_TYPES: T,
  };
});
