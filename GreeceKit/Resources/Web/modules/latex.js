/* Greece — LaTeX documents.
   A forgiving LaTeX-to-HTML converter written for previews: it typesets the common subset
   (sections, lists, math, floats, tables, footnotes, citations, Beamer frames) and degrades
   gracefully on everything else, keeping the text. It never evaluates anything and has hard
   limits on expansion, nesting, output and time, so hostile files can't hang the preview.

   `GreeceLaTeX.convert(source, options)` is pure (no DOM) so it also runs in JavaScriptCore. */
(function (global) {
  'use strict';

  const LIMITS = { expansions: 60000, depth: 160, frames: 300, output: 16e6, ms: 4000, items: 40000 };

  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);
  const plain = (h) => String(h).replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();

  class Stop extends Error {}

  // ------------------------------------------------------------------ Character tables

  const ACCENTS = {
    "'": '́', '`': '̀', '^': '̂', '"': '̈', '~': '̃', '=': '̄', '.': '̇',
    u: '̆', v: '̌', H: '̋', c: '̧', k: '̨', r: '̊', d: '̣', b: '̱', t: '͡',
  };

  const SYMBOLS = {
    ' ': ' ', ',': '&thinsp;', ';': '&ensp;', ':': '&ensp;', '!': '', '/': '', '@': '', '-': '&shy;', '&': '&amp;', '%': '%',
    $: '$', '#': '#', _: '_', '{': '{', '}': '}', '|': '‖',
    quad: '&emsp;', qquad: '&emsp;&emsp;', enspace: '&ensp;', thinspace: '&thinsp;', enskip: '&ensp;', negthinspace: '',
    ldots: '…', dots: '…', textellipsis: '…', cdots: '⋯', textendash: '–', textemdash: '—',
    textquoteleft: '‘', textquoteright: '’', textquotedblleft: '“', textquotedblright: '”', textquotedbl: '"',
    guillemotleft: '«', guillemotright: '»', guillemetleft: '«', guillemetright: '»', guilsinglleft: '‹', guilsinglright: '›',
    textbullet: '•', textperiodcentered: '·', textdagger: '†', dag: '†', ddag: '‡', textdaggerdbl: '‡', S: '§', textsection: '§',
    P: '¶', textparagraph: '¶', copyright: '©', textcopyright: '©', textregistered: '®', texttrademark: '™',
    pounds: '£', textsterling: '£', euro: '€', texteuro: '€', textyen: '¥', textdollar: '$', textcent: '¢',
    textdegree: '°', degree: '°', textmu: 'µ', textpm: '±', texttimes: '×', textdiv: '÷', textonehalf: '½',
    textonequarter: '¼', textthreequarters: '¾', textbackslash: '\\', textasciitilde: '~', textasciicircum: '^',
    textunderscore: '_', textbar: '|', textless: '&lt;', textgreater: '&gt;', textbraceleft: '{', textbraceright: '}',
    ss: 'ß', SS: 'SS', ae: 'æ', AE: 'Æ', oe: 'œ', OE: 'Œ', aa: 'å', AA: 'Å', o: 'ø', O: 'Ø', l: 'ł', L: 'Ł', i: 'ı', j: 'ȷ',
    dh: 'ð', DH: 'Ð', th: 'þ', TH: 'Þ', ng: 'ŋ', NG: 'Ŋ', textexclamdown: '¡', textquestiondown: '¿',
    checkmark: '✓', cmark: '✓', xmark: '✗', textrightarrow: '→', textleftarrow: '←', slash: '/', nobreakspace: '&nbsp;',
    space: ' ', textvisiblespace: '␣', textasteriskcentered: '∗', textordfeminine: 'ª', textordmasculine: 'º',
    textperthousand: '‰', textnumero: '№', textcelsius: '℃', textohm: 'Ω', textlnot: '¬', textsuperscript1: '¹',
    lq: '‘', rq: '’', ensuremath: null, newline: '<br>', linebreak: '<br>', break: '<br>', hfill: ' ', hfil: ' ',
    dotfill: ' ', hrulefill: ' ', textcompwordmark: '', nolinebreak: '', allowbreak: '', smallbreak: '',
  };

  const LOGOS = {
    TeX: 'T<span class="tex-e">e</span>X',
    LaTeX: 'L<span class="tex-a">a</span>T<span class="tex-e">e</span>X',
    LaTeXe: 'L<span class="tex-a">a</span>T<span class="tex-e">e</span>X&thinsp;2<sub>ε</sub>',
    BibTeX: 'B<span class="tex-sc">ib</span>T<span class="tex-e">e</span>X',
    XeTeX: 'X<span class="tex-e">ǝ</span>T<span class="tex-e">e</span>X',
    XeLaTeX: 'X<span class="tex-e">ǝ</span>L<span class="tex-a">a</span>T<span class="tex-e">e</span>X',
    LuaTeX: 'LuaT<span class="tex-e">e</span>X', LuaLaTeX: 'LuaL<span class="tex-a">a</span>T<span class="tex-e">e</span>X',
    pdfLaTeX: 'pdfL<span class="tex-a">a</span>T<span class="tex-e">e</span>X', pdfTeX: 'pdfT<span class="tex-e">e</span>X',
    AmS: 'AMS', AMS: 'AMS', MF: 'METAFONT', MP: 'METAPOST', ConTeXt: 'ConT<span class="tex-e">e</span>Xt',
  };

  // Font switches: commands with an argument, and declarations that last until the group ends.
  const FONT_COMMANDS = {
    textbf: ['<b>', '</b>'], textit: ['<i>', '</i>'], textsl: ['<i class="sl">', '</i>'], emph: ['<em>', '</em>'],
    texttt: ['<span class="tt">', '</span>'], textsc: ['<span class="sc">', '</span>'], textsf: ['<span class="sf">', '</span>'],
    textrm: ['<span class="rm">', '</span>'], textnormal: ['<span class="rm">', '</span>'], textup: ['<span class="up">', '</span>'],
    textmd: ['<span class="md">', '</span>'], underline: ['<u>', '</u>'], uline: ['<u>', '</u>'], uuline: ['<u class="double">', '</u>'],
    sout: ['<s>', '</s>'], st: ['<s>', '</s>'], xout: ['<s>', '</s>'], hl: ['<mark>', '</mark>'], textsuperscript: ['<sup>', '</sup>'],
    textsubscript: ['<sub>', '</sub>'], mbox: ['<span class="nobr">', '</span>'], makebox: ['<span>', '</span>'], hbox: ['<span class="nobr">', '</span>'],
    fbox: ['<span class="fbox">', '</span>'], framebox: ['<span class="fbox">', '</span>'], alert: ['<span class="alert-text">', '</span>'],
    structure: ['<span class="structure">', '</span>'], textls: ['<span>', '</span>'], lowercase: ['<span class="lower">', '</span>'],
    uppercase: ['<span class="upper">', '</span>'], MakeUppercase: ['<span class="upper">', '</span>'], MakeLowercase: ['<span class="lower">', '</span>'],
    MakeTextUppercase: ['<span class="upper">', '</span>'], enquote: ['“', '”'], textquote: ['“', '”'], keyword: ['<b>', '</b>'],
    IEEEauthorblockN: ['<span class="author-name">', '</span>'], IEEEauthorblockA: ['<span class="affil">', '</span>'],
    institution: ['<span>', '</span>'], department: ['<span>', '</span>'], streetaddress: ['<span>', '</span>'], city: ['<span>', '</span>'],
    country: ['<span>', '</span>'], postcode: ['<span>', '</span>'], state: ['<span>', '</span>'], orcid: ['', ''],
    textmu: ['µ', ''], foreignlanguage: null, text: ['', ''], textstyle: ['', ''], nolinkurl: ['<span class="tt">', '</span>'],
  };

  const FONT_DECLARATIONS = {
    bfseries: ['<b>', '</b>'], bf: ['<b>', '</b>'], itshape: ['<i>', '</i>'], it: ['<i>', '</i>'], em: ['<em>', '</em>'],
    slshape: ['<i class="sl">', '</i>'], sl: ['<i class="sl">', '</i>'], ttfamily: ['<span class="tt">', '</span>'], tt: ['<span class="tt">', '</span>'],
    scshape: ['<span class="sc">', '</span>'], sc: ['<span class="sc">', '</span>'], sffamily: ['<span class="sf">', '</span>'], sf: ['<span class="sf">', '</span>'],
    rmfamily: ['<span class="rm">', '</span>'], rm: ['<span class="rm">', '</span>'], normalfont: ['<span class="rm">', '</span>'],
    upshape: ['<span class="up">', '</span>'], mdseries: ['<span class="md">', '</span>'],
    tiny: ['<span class="fs-tiny">', '</span>'], scriptsize: ['<span class="fs-script">', '</span>'], footnotesize: ['<span class="fs-foot">', '</span>'],
    small: ['<span class="fs-small">', '</span>'], normalsize: ['<span class="fs-normal">', '</span>'], large: ['<span class="fs-large">', '</span>'],
    Large: ['<span class="fs-Large">', '</span>'], LARGE: ['<span class="fs-LARGE">', '</span>'], huge: ['<span class="fs-huge">', '</span>'],
    Huge: ['<span class="fs-Huge">', '</span>'],
  };

  // Commands whose arguments are skipped. s = star, o = [optional], m = {mandatory}, d = <overlay>.
  const IGNORED = {
    usepackage: 'om o', RequirePackage: 'om o', setlength: 'mm', addtolength: 'mm', setcounter: 'mm', addtocounter: 'mm',
    stepcounter: 'm', refstepcounter: 'm', newcounter: 'mo', newlength: 'm', settowidth: 'mm', settoheight: 'mm',
    vspace: 'sm', hspace: 'sm', pagestyle: 'm', thispagestyle: 'm', pagenumbering: 'm', geometry: 'm', newgeometry: 'm',
    hypersetup: 'm', lstset: 'm', captionsetup: 'om', usetikzlibrary: 'm', pgfplotsset: 'm', tikzset: 'm', theoremstyle: 'm',
    linespread: 'm', fontsize: 'mm', selectfont: '', newpage: '', clearpage: '', cleardoublepage: '', pagebreak: 'o',
    nopagebreak: 'o', smallskip: '', medskip: '', bigskip: '', indent: '', centering: '', raggedright: '', raggedleft: '',
    RaggedRight: '', justifying: '', index: 'm', glossary: 'm', markboth: 'mm', markright: 'm', addcontentsline: 'mmm',
    addtocontents: 'mm', vfill: '', vfil: '', phantom: 'm', hphantom: 'm', vphantom: 'm', protect: '', relax: '',
    makeatletter: '', makeatother: '', balance: '', onecolumn: '', frenchspacing: '', nonfrenchspacing: '', sloppy: '',
    fussy: '', DeclareGraphicsExtensions: 'm', setbeamertemplate: 'mo', usetheme: 'om', usecolortheme: 'om',
    usefonttheme: 'om', useinnertheme: 'om', useoutertheme: 'om', setbeamercolor: 'smm', setbeamerfont: 'smm',
    setbeamersize: 'm', beamertemplatenavigationsymbolsempty: '', AtBeginSection: 'om', AtBeginSubsection: 'om',
    AtBeginDocument: 'm', AtEndDocument: 'm', enlargethispage: 'sm', allowdisplaybreaks: 'o', titleformat: 'smommo',
    titlespacing: 'smmmo', fancyhf: 'om', fancyhead: 'om', fancyfoot: 'om', lhead: 'om', chead: 'om', rhead: 'om',
    lfoot: 'om', cfoot: 'om', rfoot: 'om', renewpagestyle: 'mm', setcopyright: 'm', copyrightyear: 'm', acmYear: 'm',
    acmDOI: 'm', acmConference: 'omm m', acmBooktitle: 'm', acmPrice: 'm', acmISBN: 'm', acmJournal: 'm', acmVolume: 'm',
    acmNumber: 'm', acmArticle: 'm', acmMonth: 'm', ccsdesc: 'om', settopmatter: 'm', received: 'om', titlerunning: 'm',
    authorrunning: 'm', shorttitle: 'm', shortauthors: 'm', IEEEoverridecommandlockouts: '', IEEEpeerreviewmaketitle: '',
    pdfbookmark: 'omm', bookmark: 'om', hypertarget: 'm', nocite: 'm', DeclareFieldFormat: 'omm', ExecuteBibliographyOptions: 'm',
    addbibresource: 'om', bibliographystyle: 'm', graphicspath: 'm', newtheoremstyle: 'mmmmmmmmm', theorembodyfont: 'm',
    crefname: 'mmm', Crefname: 'mmm', newfloat: 'mmmo', floatname: 'mm', floatstyle: 'm', restylefloat: 'sm', SetKw: 'mm',
    SetKwInOut: 'mm', SetKwProg: 'mmmm', SetAlgoLined: '', DontPrintSemicolon: '', LinesNumbered: '', algrenewcommand: 'mom',
    algnewcommand: 'mm', mathtoolsset: 'm', sisetup: 'm', newcolumntype: 'mom', arraystretch: '', tabcolsep: '',
    columnsep: '', baselineskip: '', parskip: '', parindent: '', textwidth: '', linewidth: '', noalign: 'm', strut: '',
    rule: 'omm', midrule: '', vline: '', label: 'm', thanksmarkseries: 'm', keywordsname: '', MakeRobust: 'm',
    PassOptionsToPackage: 'mm', ProvidesPackage: 'mo', ProvidesFile: 'mo', NeedsTeXFormat: 'mo', include: 'm', includeonly: 'm',
    input: 'm', listfiles: '', null: '', leavevmode: '', ignorespaces: '', unskip: '', par: '', footnoterule: '', titlegraphic: 'm',
    logo: 'm', mode: 'd', note: 'om', pgfdeclareimage: 'omm', usebackgroundtemplate: 'm', resetcounteronoverlays: 'm',
    tikzexternalize: 'o', pgfplotsset: 'm', definecolorseries: 'mmmmmmm', colorlet: 'mm', newacronym: 'ommm', makeglossaries: '',
    printglossaries: '', printindex: '', makeindex: '', author_address: 'm', blindtext: 'o', Blindtext: 'o', lipsum: 'o',
  };

  const THEOREM_NAMES = {
    theorem: 'Theorem', thm: 'Theorem', lemma: 'Lemma', lem: 'Lemma', proposition: 'Proposition', prop: 'Proposition',
    corollary: 'Corollary', cor: 'Corollary', definition: 'Definition', defn: 'Definition', def: 'Definition',
    remark: 'Remark', rem: 'Remark', example: 'Example', ex: 'Example', conjecture: 'Conjecture', claim: 'Claim', fact: 'Fact',
    assumption: 'Assumption', observation: 'Observation', note: 'Note', exercise: 'Exercise', problem: 'Problem',
    solution: 'Solution', question: 'Question', hypothesis: 'Hypothesis', notation: 'Notation', property: 'Property',
    axiom: 'Axiom', algorithm_: 'Algorithm', case: 'Case', criterion: 'Criterion', principle: 'Principle', summary: 'Summary',
  };
  const DEFINITION_STYLE = /^(definition|defn|def|example|ex|exercise|problem|assumption|question|hypothesis|axiom)$/;
  const REMARK_STYLE = /^(remark|rem|note|notation|observation|case|summary|solution|claim|fact)$/;

  const NAMED_COLORS = {
    black: [0, 0, 0], white: [255, 255, 255], red: [255, 0, 0], green: [0, 255, 0], blue: [0, 0, 255], cyan: [0, 255, 255],
    magenta: [255, 0, 255], yellow: [255, 255, 0], gray: [128, 128, 128], grey: [128, 128, 128], darkgray: [64, 64, 64],
    lightgray: [191, 191, 191], brown: [191, 128, 64], lime: [191, 255, 0], olive: [128, 128, 0], orange: [255, 128, 0],
    pink: [255, 191, 191], purple: [191, 0, 64], teal: [0, 128, 128], violet: [128, 0, 128], navy: [0, 0, 128], maroon: [128, 0, 0],
  };

  const SECTION_LEVELS = { part: -1, chapter: 0, section: 1, subsection: 2, subsubsection: 3, paragraph: 4, subparagraph: 5 };
  const SECTION_RESETS = { part: [], chapter: ['section', 'subsection', 'subsubsection', 'paragraph'], section: ['subsection', 'subsubsection', 'paragraph'], subsection: ['subsubsection', 'paragraph'], subsubsection: ['paragraph'], paragraph: [], subparagraph: [] };

  const MATH_ENVS = new Set(['equation', 'equation*', 'align', 'align*', 'gather', 'gather*', 'multline', 'multline*', 'flalign',
    'flalign*', 'alignat', 'alignat*', 'eqnarray', 'eqnarray*', 'displaymath', 'math', 'dmath', 'dmath*', 'IEEEeqnarray', 'IEEEeqnarray*']);
  const VERBATIM_ENVS = new Set(['greececode', 'verbatim', 'verbatim*', 'Verbatim', 'BVerbatim', 'lstlisting', 'minted', 'alltt', 'spverbatim', 'code', 'codebox', 'pyglist', 'sourcecode']);
  const SKIPPED_ENVS = new Set(['comment', 'CCSXML', 'filecontents', 'filecontents*', 'lrbox', 'tikzcd*', 'thebibliography*', 'IEEEbiography*']);
  const PICTURE_ENVS = new Set(['tikzpicture', 'pgfpicture', 'picture', 'circuitikz', 'forest', 'tikzcd', 'pspicture', 'axis', 'asy', 'dot2tex', 'mermaid']);

  // ------------------------------------------------------------------ Input

  /** A stack of input frames, so macro expansions splice into the stream without copying it. */
  class Scanner {
    constructor(text) { this.frames = [{ s: text, i: 0 }]; }
    top() {
      let f = this.frames[this.frames.length - 1];
      while (f.i >= f.s.length && this.frames.length > 1) { this.frames.pop(); f = this.frames[this.frames.length - 1]; }
      return f;
    }
    eof() { const f = this.top(); return f.i >= f.s.length; }
    peek(k = 0) {
      for (let n = this.frames.length - 1; n >= 0; n--) {
        const f = this.frames[n];
        const left = f.s.length - f.i;
        if (k < left) return f.s[f.i + k];
        k -= left;
      }
      return '';
    }
    next() { const f = this.top(); return f.i < f.s.length ? f.s[f.i++] : ''; }
    push(text) {
      if (!text) return;
      if (this.frames.length > LIMITS.frames) throw new Stop('nesting');
      this.frames.push({ s: text, i: 0 });
    }
    /** Matches a sticky regex in the current frame. */
    match(re) {
      const f = this.top();
      re.lastIndex = f.i;
      const m = re.exec(f.s);
      if (m) f.i += m[0].length;
      return m;
    }
    startsWith(text) {
      for (let k = 0; k < text.length; k++) if (this.peek(k) !== text[k]) return false;
      return true;
    }
  }

  /** Collects block HTML and the paragraph being written, keeping font switches balanced across paragraphs. */
  class Out {
    constructor() { this.blocks = []; this.p = ''; this.fresh = true; this.open = []; this.pClass = ''; this.size = 0; }
    text(h) {
      if (!h) return;
      if (this.fresh) { this.p = this.open.map((o) => o[0]).join(''); this.fresh = false; }
      this.p += h;
    }
    openTag(pair) { this.open.push(pair); if (!this.fresh) this.p += pair[0]; }
    closeTo(n) { while (this.open.length > n) { const o = this.open.pop(); if (!this.fresh) this.p += o[1]; } }
    flush() {
      if (!this.fresh) {
        const content = this.p + this.open.slice().reverse().map((o) => o[1]).join('');
        if (Out.visible(content)) this.blocks.push(`<p${this.pClass ? ` class="${this.pClass}"` : ''}>${content.trim()}</p>`);
      }
      this.p = '';
      this.fresh = true;
      this.pClass = '';
    }
    block(h) { this.flush(); this.blocks.push(h); }
    html() { this.flush(); return this.blocks.join('\n'); }
    /** For titles, captions and cells: everything on one line. */
    inline() {
      this.flush();
      return this.blocks.map((b) => b.replace(/^<p(?: class="[^"]*")?>([\s\S]*)<\/p>$/, '$1')).join(' ').trim();
    }
    static visible(h) {
      return /<(img|svg|br|hr)\b|class="m\b|class="tex-placeholder|class="fn-ref|class="qed/.test(h) || /\S/.test(h.replace(/<[^>]*>/g, '').replace(/&nbsp;|&thinsp;|&ensp;|&emsp;/g, ''));
    }
  }

  // ------------------------------------------------------------------ Converter

  class Converter {
    constructor(source, options) {
      this.options = options || {};
      this.figures = this.options.figures || {};
      this.s = new Scanner(source);
      this.out = new Out();
      this.macros = new Map();
      this.environments = new Map();
      this.katexMacros = { '\\bm': '\\boldsymbol{#1}', '\\mathbbm': '\\mathbb{#1}', '\\Bbbk': '\\Bbbk', '\\hdots': '\\dots', '\\iddots': '\\dots', '\\abs': '\\left\\lvert #1\\right\\rvert', '\\norm': '\\left\\lVert #1\\right\\rVert', '\\eqqcolon': '=\\vcentcolon', '\\coloneqq': '\\vcentcolon=', '\\given': '\\mid', '\\E': '\\mathbb{E}', '\\Var': '\\operatorname{Var}', '\\argmax': '\\operatorname*{arg\\,max}', '\\argmin': '\\operatorname*{arg\\,min}', '\\T': '^{\\top}' };
      this.colors = Object.assign({}, NAMED_COLORS);
      this.counters = { part: 0, chapter: 0, section: 0, subsection: 0, subsubsection: 0, paragraph: 0, subparagraph: 0, equation: 0, figure: 0, table: 0, footnote: 0, algorithm: 0, listing: 0 };
      this.numberWithin = {};
      this.theorems = new Map();
      this.labels = new Map();
      this.headings = [];
      this.floats = { figure: [], table: [] };
      this.footnotes = [];
      this.math = [];
      this.cited = [];
      this.citedSet = new Set();
      this.bibItems = null;      // from thebibliography / .bbl
      this.bibPlaced = false;
      this.nociteAll = false;
      this.envStack = [];
      this.depth = 0;
      this.expansions = 0;
      this.steps = 0;
      this.started = Date.now();
      this.ids = 0;
      this.target = null;
      this.title = null; this.subtitle = null; this.authors = []; this.date = undefined; this.institute = null; this.keywords = null;
      this.thanks = [];
      this.pendingAbstract = null;
      this.titleMade = false;
      this.inPreamble = /\\begin\s*\{document\}/.test(source);
      this.ended = false;
      this.appendix = false;
      this.docClass = 'article';
      this.classOptions = [];
      this.packages = new Set();
      this.bibStyle = '';
      this.secnumdepth = 3;
      this.slides = [];
      this.slide = null;
      this.section = '';
      this.stopped = null;
      this.float = null;
      this.table = null;
      this.algo = null;
      this.emphDepth = 0;
      this.wordSource = 0;
    }

    // ---------------------------------------------------------- Guards

    check() {
      if ((++this.steps & 1023) === 0) {
        if (Date.now() - this.started > LIMITS.ms) throw new Stop('time');
        if (this.out.blocks.length > LIMITS.items || this.math.length > LIMITS.items) throw new Stop('size');
      }
    }

    nest(fn) {
      if (++this.depth > LIMITS.depth) { this.depth--; throw new Stop('depth'); }
      try { return fn(); } finally { this.depth--; }
    }

    id(prefix) { return `${prefix}-${++this.ids}`; }

    // ---------------------------------------------------------- Reading

    skipSpaces(newlines) {
      const s = this.s;
      for (;;) {
        const c = s.peek();
        if (c === ' ' || c === '\t' || c === '\r') { s.next(); continue; }
        if (c === '%') { this.comment(); continue; }
        if (c === '\n' && newlines) {
          // Never swallow a paragraph break.
          let k = 1;
          while (s.peek(k) === ' ' || s.peek(k) === '\t' || s.peek(k) === '\r') k++;
          if (s.peek(k) === '\n') return;
          s.next();
          continue;
        }
        return;
      }
    }

    comment() {
      const s = this.s;
      while (!s.eof() && s.peek() !== '\n') s.next();
      if (s.peek() === '\n') {
        s.next();
        while (s.peek() === ' ' || s.peek() === '\t') s.next();
      }
    }

    readName() {
      const s = this.s;
      const m = s.match(/[A-Za-z@]+/y);
      if (m) return m[0];
      return s.next();
    }

    /** A mandatory argument: a balanced {group} (without its braces) or a single token. */
    readArg() {
      const s = this.s;
      this.skipSpaces(true);
      const c = s.peek();
      if (c === '{') { s.next(); return this.readBalanced('{', '}'); }
      if (c === '\\') { s.next(); const n = this.readName(); return '\\' + n; }
      if (c === '' || c === '}') return '';
      return s.next();
    }

    readOpt() {
      const s = this.s;
      let k = 0;
      while (s.peek(k) === ' ' || s.peek(k) === '\t' || s.peek(k) === '\n' && s.peek(k + 1) !== '\n') k++;
      if (s.peek(k) !== '[') return null;
      for (let i = 0; i <= k; i++) s.next();
      return this.readBalanced('[', ']');
    }

    readOverlay() {
      const s = this.s;
      if (s.peek() !== '<') return null;
      let text = '';
      for (let k = 1; k < 40; k++) {
        const c = s.peek(k);
        if (c === '>') { for (let i = 0; i <= k; i++) s.next(); return text; }
        if (!/[\w\-+,|.: ]/.test(c)) return null;
        text += c;
      }
      return null;
    }

    readStar() { if (this.s.peek() === '*') { this.s.next(); return true; } return false; }

    /** Raw text up to the matching close (nested pairs and escapes respected, comments removed). */
    readBalanced(open, close) {
      const s = this.s;
      let depth = 1;
      let text = '';
      let brace = 0;
      while (!s.eof()) {
        if ((++this.steps & 4095) === 0 && Date.now() - this.started > LIMITS.ms) throw new Stop('time');
        const c = s.next();
        if (c === '\\') { const n = s.next(); text += c + n; continue; }
        if (c === '%') { while (!s.eof() && s.peek() !== '\n') s.next(); if (s.peek() === '\n') { s.next(); while (s.peek() === ' ' || s.peek() === '\t') s.next(); } continue; }
        if (open === '[') {
          if (c === '{') brace++;
          else if (c === '}') brace--;
          else if (c === ']' && brace <= 0) return text;
          text += c;
          continue;
        }
        if (c === open) depth++;
        else if (c === close && --depth === 0) return text;
        text += c;
      }
      return text;
    }

    /** Raw text up to `\end{name}`, for verbatim and math environments. */
    readUntilEnd(name) {
      const s = this.s;
      const marker = `\\end{${name}}`;
      let text = '';
      while (!s.eof()) {
        if ((++this.steps & 4095) === 0 && Date.now() - this.started > LIMITS.ms) throw new Stop('time');
        if (s.peek() === '\\' && s.startsWith(marker)) {
          for (let i = 0; i < marker.length; i++) s.next();
          return text;
        }
        // \end {name} with spaces
        if (s.peek() === '\\' && s.startsWith('\\end')) {
          let k = 4;
          while (s.peek(k) === ' ') k++;
          if (s.peek(k) === '{') {
            let name2 = '';
            let j = k + 1;
            while (j < k + 60 && s.peek(j) && s.peek(j) !== '}') name2 += s.peek(j++);
            if (name2.trim() === name && s.peek(j) === '}') { for (let i = 0; i <= j; i++) s.next(); return text; }
          }
        }
        text += s.next();
      }
      return text;
    }

    skipArgs(signature) {
      for (const kind of signature) {
        if (kind === 's') this.readStar();
        else if (kind === 'o') this.readOpt();
        else if (kind === 'm') this.readArg();
        else if (kind === 'd') this.readOverlay();
      }
    }

    // ---------------------------------------------------------- Sub-parsing

    /** Parses `raw` into a fresh output and returns it; shares all document state. */
    sub(raw, fn) {
      const savedS = this.s;
      const savedOut = this.out;
      this.s = new Scanner(raw);
      this.out = new Out();
      try {
        return this.nest(() => { this.parse({}); return fn ? fn(this.out) : this.out; });
      } finally {
        this.s = savedS;
        this.out = savedOut;
      }
    }

    inline(raw) { return raw ? this.sub(raw, (o) => o.inline()) : ''; }
    blockHTML(raw) { return raw ? this.sub(raw, (o) => o.html()) : ''; }

    /** Parses the input stream into `out` until a stop condition. */
    parseInto(out, stop) {
      const saved = this.out;
      this.out = out;
      try { return this.nest(() => this.parse(stop)); } finally { this.out = saved; }
    }

    // ---------------------------------------------------------- Main loop

    parse(stop) {
      const s = this.s;
      for (;;) {
        this.check();
        if (this.ended) return 'eof';
        if (s.eof()) return 'eof';
        const c = s.peek();
        switch (c) {
          case '\\': {
            const result = this.command(stop);
            if (result) return result;
            break;
          }
          case '{': s.next(); this.group(); break;
          case '}':
            s.next();
            if (stop.group) return 'group';
            break;
          case '$': this.dollarMath(); break;
          case '%': this.comment(); break;
          case '&':
            s.next();
            if (stop.cell) return 'cell';
            if (this.algo) break;
            this.out.text('&amp;');
            break;
          case '~': s.next(); this.out.text('&nbsp;'); break;
          case '\n': this.newline(); break;
          case ']':
            s.next();
            if (stop.bracket) return 'bracket';
            this.out.text(']');
            break;
          case '-':
            if (s.peek(1) === '-' && s.peek(2) === '-') { s.next(); s.next(); s.next(); this.out.text('—'); }
            else if (s.peek(1) === '-') { s.next(); s.next(); this.out.text('–'); }
            else { s.next(); this.out.text('-'); }
            break;
          case '`':
            s.next();
            if (s.peek() === '`') { s.next(); this.out.text('“'); } else this.out.text('‘');
            break;
          case "'":
            s.next();
            if (s.peek() === "'") { s.next(); this.out.text('”'); } else this.out.text('’');
            break;
          case '<': case '>': case '"':
            s.next();
            if (c === '<' && s.peek() === '<') { s.next(); this.out.text('«'); break; }
            if (c === '>' && s.peek() === '>') { s.next(); this.out.text('»'); break; }
            this.out.text(ESC[c]);
            break;
          case '#': s.next(); break;
          case '^': case '_':
            s.next();
            this.out.text(c);
            break;
          case '\r': case '\t': s.next(); this.out.text(' '); break;
          default: {
            const m = s.match(/[^\\{}$%&~\n\]\-`'<>"#^_\r\t]+/y);
            if (m) { this.out.text(m[0].replace(/ {2,}/g, ' ')); this.wordSource += m[0].length; }
            else { s.next(); }
          }
        }
      }
    }

    newline() {
      const s = this.s;
      s.next();
      let blank = false;
      for (;;) {
        const c = s.peek();
        if (c === ' ' || c === '\t' || c === '\r') { s.next(); continue; }
        if (c === '\n') { s.next(); blank = true; continue; }
        if (c === '%' && !blank) {
          // A comment line between text lines doesn't break the paragraph.
          break;
        }
        break;
      }
      if (blank) this.par();
      else this.out.text(' ');
    }

    par() {
      if (this.algo) return;
      this.out.flush();
    }

    group() {
      const mark = this.out.open.length;
      const emph = this.emphDepth;
      this.nest(() => this.parse({ group: true }));
      this.out.closeTo(mark);
      this.emphDepth = emph;
    }

    // ---------------------------------------------------------- Commands

    command(stop) {
      const s = this.s;
      s.next();
      if (s.eof()) return null;
      const name = this.readName();
      if (/^[A-Za-z@]+$/.test(name)) this.skipSpaces(true);

      // Stops first: they end the construct being parsed.
      if (name === 'end') {
        const env = this.peekEnvName();
        if (env !== null) {
          if (stop.env === env) { this.consumeEnvName(); return 'end'; }
          if (this.envStack.includes(env)) return 'end';   // an ancestor closes: leave it for its owner
          this.consumeEnvName();
          const user = this.environments.get(env);
          if (user && user.endCode) this.s.push(user.endCode);
          return null;
        }
        return null;
      }
      if ((name === '\\' || name === 'tabularnewline' || name === 'cr') && stop.row) {
        this.readStar(); this.readOpt();
        return 'row';
      }
      if ((name === 'item' || (name === 'bibitem' && this.envStack.includes('thebibliography'))) && stop.item) return 'item';
      if (stop.algo && this.algo && this.algoCommand(name)) return null;

      // User macros win, except over the structure Greece understands.
      const user = this.macros.get(name);
      if (user && !Converter.structural.has(name)) { this.expand(user); return null; }

      const handler = Converter.handlers[name];
      if (handler) { handler.call(this, name); return null; }

      if (name in LOGOS) { this.out.text(`<span class="tex-logo">${LOGOS[name]}</span>`); return null; }
      if (name in SYMBOLS && SYMBOLS[name] !== null) { this.out.text(SYMBOLS[name]); return null; }
      if (name in ACCENTS && name.length === 1) { this.accent(name); return null; }
      if (FONT_COMMANDS[name]) { this.fontCommand(name); return null; }
      if (FONT_DECLARATIONS[name]) { this.out.openTag(FONT_DECLARATIONS[name]); return null; }
      if (name in IGNORED) { this.skipArgs(IGNORED[name]); return null; }
      if (/^(if|ifx|ifdefined|ifcsname|ifnum|ifdim|ifthenelse|ifpdf|ifxetex|ifluatex)/.test(name) && name !== 'iffalse') { this.conditional(name, true); return null; }
      if (name === 'iffalse') { this.conditional(name, false); return null; }
      if (name === 'fi' || name === 'else') { if (name === 'else') this.skipConditional(); return null; }
      if (name.length === 1 && !/[A-Za-z]/.test(name)) { this.out.text(esc(name)); return null; }

      // Unknown: drop the command and its options, keep any text that follows.
      this.readStar();
      if (this.isBeamer) this.readOverlay();
      this.readOpt();
      return null;
    }

    peekEnvName() {
      const s = this.s;
      let k = 0;
      while (s.peek(k) === ' ') k++;
      if (s.peek(k) !== '{') return null;
      let name = '';
      for (let j = k + 1; j < k + 80; j++) {
        const c = s.peek(j);
        if (c === '}') return name.trim();
        if (c === '' || c === '\n') return null;
        name += c;
      }
      return null;
    }

    consumeEnvName() { this.skipSpaces(false); this.readArg(); }

    expand(def) {
      if (++this.expansions > LIMITS.expansions) throw new Stop('expansion');
      const args = [];
      let first = 0;
      if (def.opt !== undefined) {
        const o = this.readOpt();
        args.push(o === null ? def.opt : o);
        first = 1;
      }
      for (let i = first; i < def.n; i++) args.push(this.readArg());
      const body = def.body.replace(/##|#([1-9])/g, (m, d) => (d ? (args[Number(d) - 1] ?? '') : '#'));
      // A trailing space after an expansion that ends in a control word would be eaten; keep text separate.
      this.s.push(body);
    }

    fontCommand(name) {
      const pair = FONT_COMMANDS[name];
      if (name === 'emph') {
        const upright = this.emphDepth % 2 === 1;
        this.emphDepth++;
        const raw = this.readArg();
        const inner = this.inline(raw);
        this.emphDepth--;
        this.out.text(upright ? `<em class="up">${inner}</em>` : `<em>${inner}</em>`);
        return;
      }
      if (name === 'makebox' || name === 'framebox') { this.readOpt(); this.readOpt(); }
      if (this.isBeamer) this.readOverlay();
      const inner = this.inline(this.readArg());
      this.out.text(pair[0] + inner + pair[1]);
    }

    accent(name) {
      const raw = this.readArg();
      let base = raw.trim();
      if (base === '\\i' || base === '\\i{}') base = 'i';
      else if (base === '\\j') base = 'j';
      else if (base.startsWith('\\')) base = plain(this.inline(base));
      const text = (base || ' ') + ACCENTS[name];
      this.out.text(esc(text.normalize('NFC')));
    }

    conditional(name, takeFirst) {
      // \ifx\a\b and friends: take the first branch, skip \else. \iffalse skips to \fi.
      if (name === 'ifx') { this.readArg(); this.readArg(); }
      else if (name === 'ifdefined' || name === 'ifcsname') this.readArg();
      else if (name === 'ifthenelse') {
        this.readArg();
        const yes = this.readArg();
        this.readArg();
        this.s.push(yes);
        return;
      }
      if (!takeFirst) this.skipConditional(true);
    }

    skipConditional(includeElse) {
      // Skip to the matching \fi (and stop at \else when asked, so its branch runs).
      const s = this.s;
      let depth = 0;
      while (!s.eof()) {
        if ((++this.steps & 4095) === 0 && Date.now() - this.started > LIMITS.ms) throw new Stop('time');
        const c = s.next();
        if (c === '%') { while (!s.eof() && s.peek() !== '\n') s.next(); continue; }
        if (c !== '\\') continue;
        const name = this.readName();
        if (/^if/.test(name)) depth++;
        else if (name === 'fi') { if (depth === 0) return; depth--; }
        else if (name === 'else' && depth === 0 && includeElse) return;
      }
    }

    // ---------------------------------------------------------- Definitions

    defineCommand(kind) {
      this.readStar();
      this.skipSpaces(true);
      let name = this.readArg().trim();
      if (!name.startsWith('\\')) return;
      name = name.slice(1);
      const n = Number(this.readOpt() || 0) || 0;
      const opt = this.readOpt();
      const body = this.readArg();
      if (kind === 'provide' && (this.macros.has(name) || Converter.handlers[name])) return;
      this.define(name, Math.min(n, 9), body, opt === null ? undefined : opt);
    }

    define(name, n, body, opt) {
      if (!/^[A-Za-z@]+$|^.$/.test(name)) return;
      if (this.macros.size > 5000) return;
      this.macros.set(name, { n, body, opt });
      // KaTeX gets every macro too, so they work in math.
      if (opt === undefined && body.length < 2000) this.katexMacros['\\' + name] = body;
    }

    defPrimitive() {
      this.skipSpaces(true);
      if (this.s.peek() !== '\\') return;
      this.s.next();
      const name = this.readName();
      let params = '';
      while (!this.s.eof() && this.s.peek() !== '{' && params.length < 40) params += this.s.next();
      const body = this.readArg();
      const n = (params.match(/#[1-9]/g) || []).length;
      if (/[^#1-9\s]/.test(params)) return;   // delimited parameters: beyond a preview
      this.define(name, n, body);
    }

    letPrimitive() {
      this.skipSpaces(true);
      const target = this.readArg();
      this.skipSpaces(true);
      if (this.s.peek() === '=') { this.s.next(); this.skipSpaces(true); }
      const source = this.readArg();
      if (!target.startsWith('\\')) return;
      const name = target.slice(1);
      const from = source.startsWith('\\') ? source.slice(1) : null;
      if (from && this.macros.has(from)) this.macros.set(name, this.macros.get(from));
      else if (from) this.define(name, 0, source);
    }

    defineEnvironment(kind) {
      this.readStar();
      const name = this.readArg().trim();
      const n = Number(this.readOpt() || 0) || 0;
      const opt = this.readOpt();
      const begin = this.readArg();
      const end = this.readArg();
      if (!name || this.environments.size > 1000) return;
      if (kind === 'renew' && Converter.environmentHandlers[name]) return;
      this.environments.set(name, { n: Math.min(n, 9), opt: opt === null ? undefined : opt, begin, endCode: end });
    }

    newTheorem() {
      const star = this.readStar();
      const env = this.readArg().trim();
      const shared = this.readOpt();
      const title = this.readArg();
      const within = this.readOpt();
      if (!env) return;
      const style = this.theoremStyle || (DEFINITION_STYLE.test(env) ? 'definition' : REMARK_STYLE.test(env) ? 'remark' : 'plain');
      this.theorems.set(env, { title: plain(this.inline(title)) || env, counter: star ? null : (shared ? shared.trim() : env), within: within ? within.trim() : null, style });
    }

    defineColor() {
      const name = this.readArg().trim();
      const model = this.readArg().trim();
      const spec = this.readArg().trim();
      const rgb = Converter.parseColorSpec(model, spec);
      if (rgb && name) this.colors[name] = rgb;
    }

    static parseColorSpec(model, spec) {
      const parts = spec.split(/[\s,]+/).filter(Boolean).map(Number);
      switch (model.toLowerCase()) {
        case 'rgb': return parts.length === 3 && parts.every((v) => v >= 0 && v <= 1) ? parts.map((v) => Math.round(v * 255)) : null;
        case 'rgb255': return parts.length === 3 ? parts.map((v) => Math.max(0, Math.min(255, Math.round(v)))) : null;
        case 'html': return /^[0-9a-f]{6}$/i.test(spec) ? [0, 2, 4].map((i) => parseInt(spec.slice(i, i + 2), 16)) : null;
        case 'gray': return parts.length === 1 ? [0, 0, 0].map(() => Math.round(parts[0] * 255)) : null;
        case 'cmyk': {
          if (parts.length !== 4) return null;
          const [c, m, y, k] = parts;
          return [c, m, y].map((v) => Math.round(255 * (1 - Math.min(1, v + k))));
        }
        default: return null;
      }
    }

    /** xcolor expressions: name, name!50, name!30!other, -name. */
    color(expr) {
      const text = String(expr).trim();
      if (!text) return null;
      const bits = text.replace(/^-/, '').split('!');
      let rgb = this.colors[bits[0]];
      if (!rgb) return null;
      for (let i = 1; i < bits.length; i += 2) {
        const pct = Math.max(0, Math.min(100, Number(bits[i]) || 0)) / 100;
        const other = this.colors[bits[i + 1]] || [255, 255, 255];
        rgb = rgb.map((v, k) => Math.round(v * pct + other[k] * (1 - pct)));
      }
      return `#${rgb.map((v) => v.toString(16).padStart(2, '0')).join('')}`;
    }

    // ---------------------------------------------------------- Counters and labels

    stepCounter(name) {
      this.counters[name] = (this.counters[name] || 0) + 1;
      for (const child of SECTION_RESETS[name] || []) this.counters[child] = 0;
      if (name === 'chapter' || name === 'section') {
        for (const [counter, within] of Object.entries(this.numberWithin)) if (within === name || (name === 'chapter' && within === 'section')) this.counters[counter] = 0;
        if (name === 'chapter' && this.isBook) { this.counters.figure = 0; this.counters.table = 0; if (!this.numberWithin.equation) this.counters.equation = 0; }
        for (const [, thm] of this.theorems) if (thm.within === name && thm.counter) this.counters['thm:' + thm.counter] = 0;
      }
      return this.counters[name];
    }

    formatCounter(name, value) {
      const within = this.numberWithin[name] || ((name === 'figure' || name === 'table' || name === 'equation') && this.isBook ? 'chapter' : null);
      const prefix = within ? this.sectionNumber(within) : '';
      return prefix ? `${prefix}.${value}` : String(value);
    }

    sectionNumber(level) {
      const c = this.counters;
      const chap = this.appendix && this.isBook ? alpha(c.chapter, true) : String(c.chapter);
      const sec = this.appendix && !this.isBook ? alpha(c.section, true) : String(c.section);
      if (level === 'chapter') return chap;
      const parts = this.isBook ? [chap] : [];
      parts.push(sec);
      if (level === 'section') return parts.join('.');
      parts.push(c.subsection);
      if (level === 'subsection') return parts.join('.');
      parts.push(c.subsubsection);
      if (level === 'subsubsection') return parts.join('.');
      parts.push(c.paragraph);
      return parts.join('.');
    }

    get isBook() { return /^(book|report|memoir|scrbook|scrreprt|thesis|ucthesis|mitthesis)/.test(this.docClass); }
    get isBeamer() { return this.docClass === 'beamer'; }

    label(key) {
      key = key.trim();
      if (!key || !this.target) return;
      if (!this.labels.has(key)) this.labels.set(key, this.target);
    }

    refPlaceholder(key, kind) { return `\u0001R${kind}${encodeURIComponent(key.trim())}\u0002`; }

    // ---------------------------------------------------------- Math

    dollarMath() {
      const s = this.s;
      s.next();
      const display = s.peek() === '$';
      if (display) s.next();
      const tex = this.readMath(display ? '$$' : '$');
      if (tex === null) { this.out.text('$'); return; }
      this.emitMath(tex, display);
    }

    /** Reads math up to its closing delimiter; null (with nothing consumed) if it never closes. */
    readMath(close) {
      const s = this.s;
      let text = '';
      let depth = 0;
      const consumed = [];
      while (!s.eof()) {
        const c = s.next();
        consumed.push(c);
        if (c === '\\') {
          const n = s.next();
          consumed.push(n);
          if (close === '\\)' && n === ')' && depth <= 0) return text;
          if (close === '\\]' && n === ']' && depth <= 0) return text;
          text += c + n;
          continue;
        }
        if (c === '%') { while (!s.eof() && s.peek() !== '\n') consumed.push(s.next()); continue; }
        if (c === '{') depth++;
        if (c === '}') depth--;
        if (c === '$' && depth <= 0 && (close === '$' || close === '$$')) {
          if (close === '$$') { if (s.peek() === '$') { s.next(); return text; } }
          else return text;
        }
        if (c === '\n' && /\n[ \t]*$/.test(text) && close === '$') break;
        text += c;
        if (text.length > 200000) break;
      }
      // Unterminated: put it back and treat the delimiter as text.
      this.s.push(consumed.join(''));
      return null;
    }

    emitMath(tex, display, numbered) {
      // Sweave's \Sexpr{} inside a formula: show the R expression.
      if (tex.includes('\\Sexpr')) tex = tex.replace(/\\Sexpr\s*\{((?:[^{}]|\{[^{}]*\})*)\}/g, (m, e) => `\\texttt{${e.replace(/([$_%&#{}])/g, '\\$1').replace(/\^/g, '\\textasciicircum{}').replace(/~/g, '\\textasciitilde{}')}}`);
      const index = this.math.length;
      this.math.push({ tex, display });
      if (display) {
        this.out.block(`<div class="tex-display"${numbered ? ` id="${numbered}"` : ''}><span class="m" data-i="${index}"></span></div>`);
        this.out.pClass = 'cont';
      } else {
        this.out.text(`<span class="m" data-i="${index}"></span>`);
      }
    }

    mathEnvironment(env) {
      let body = this.readUntilEnd(env);
      const base = env.replace(/\*$/, '');
      const starred = env.endsWith('*') || base === 'displaymath' || base === 'math';
      if (base === 'math') { this.emitMath(body, false); return; }
      if (base === 'alignat') body = body.replace(/^\s*\{[^}]*\}/, '');
      if (base === 'IEEEeqnarray') body = body.replace(/^\s*(\[[^\]]*\])?\s*\{[^}]*\}/, '');

      const multi = /^(align|gather|multline|flalign|alignat|eqnarray|IEEEeqnarray)$/.test(base);
      const rows = multi ? splitRows(body) : [body];
      const tagged = [];
      let anchor = null;
      for (let row of rows) {
        const labels = [];
        row = row.replace(/\\label\s*\{([^}]*)\}/g, (m, key) => { labels.push(key); return ''; });
        const suppressed = /\\(nonumber|notag)\b/.test(row);
        row = row.replace(/\\(nonumber|notag)\b/g, '');
        const custom = row.match(/\\tag\*?\s*\{([^}]*)\}/);
        let number = null;
        if (custom) number = custom[1];
        else if (!starred && !suppressed && !(base === 'multline' && row !== rows[rows.length - 1]) && row.trim()) {
          number = this.formatCounter('equation', this.stepCounter('equation'));
          row += ` \\tag{${number}}`;
        }
        if (number !== null) {
          const id = anchor || (anchor = this.id('eq'));
          for (const key of labels) if (!this.labels.has(key.trim())) this.labels.set(key.trim(), { id, text: number, type: 'equation' });
        }
        if (base === 'eqnarray' || base === 'IEEEeqnarray') {
          const cells = splitCells(row);
          row = cells.length >= 3 ? `${cells[0]} &${cells[1]} ${cells.slice(2).join(' ')}` : cells.join(' & ');
        }
        tagged.push(row);
      }
      let tex;
      if (!multi) tex = tagged[0];
      else if (base === 'gather' || base === 'multline') tex = `\\begin{gather*}${tagged.join('\\\\')}\\end{gather*}`;
      else if (base === 'alignat') tex = `\\begin{align*}${tagged.join('\\\\')}\\end{align*}`;
      else tex = `\\begin{align*}${tagged.join('\\\\')}\\end{align*}`;
      tex = tex.replace(/\\(intertext|shortintertext)\s*\{([^}]*)\}/g, '\\text{$2}');
      this.emitMath(tex, true, anchor);
    }

    // ---------------------------------------------------------- Environments

    beginEnvironment() {
      const name = this.readArg().trim();
      if (!name) return;
      this.check();

      if (name === 'document') {
        this.inPreamble = false;
        this.preambleDone();
        this.envStack.push(name);
        try { this.parse({ env: 'document' }); } finally { this.envStack.pop(); }
        this.ended = true;
        return;
      }
      if (MATH_ENVS.has(name)) { if (name === 'math') { this.emitMath(this.readUntilEnd(name), false); } else this.mathEnvironment(name); return; }
      if (VERBATIM_ENVS.has(name)) { this.verbatim(name); return; }
      if (SKIPPED_ENVS.has(name)) { this.readUntilEnd(name); return; }
      if (PICTURE_ENVS.has(name)) { this.picture(name); return; }

      const user = this.environments.get(name);
      const handler = Converter.environmentHandlers[name];
      if (handler && !(user && !Converter.structuralEnvironments.has(name))) {
        this.envStack.push(name);
        try { handler.call(this, name); } finally { this.envStack.pop(); }
        return;
      }
      if (user) {
        if (++this.expansions > LIMITS.expansions) throw new Stop('expansion');
        const args = [];
        let first = 0;
        if (user.opt !== undefined) { const o = this.readOpt(); args.push(o === null ? user.opt : o); first = 1; }
        for (let i = first; i < user.n; i++) args.push(this.readArg());
        const begin = user.begin.replace(/##|#([1-9])/g, (m, d) => (d ? (args[Number(d) - 1] ?? '') : '#'));
        this.s.push(begin);
        return;   // its \end pushes the end code
      }
      const theorem = this.theorems.get(name) || (THEOREM_NAMES[name.replace(/\*$/, '')] && { title: THEOREM_NAMES[name.replace(/\*$/, '')], counter: name.endsWith('*') ? null : name, style: DEFINITION_STYLE.test(name) ? 'definition' : REMARK_STYLE.test(name) ? 'remark' : 'plain' });
      if (theorem) {
        this.envStack.push(name);
        try { this.theoremEnvironment(name, theorem); } finally { this.envStack.pop(); }
        return;
      }
      // Unknown environment: keep its content.
      this.envStack.push(name);
      try {
        this.readOpt();
        const inner = new Out();
        this.parseInto(inner, { env: name });
        const html = inner.html();
        if (html) this.out.block(`<div class="tex-env">${html}</div>`);
      } finally { this.envStack.pop(); }
    }

    /** Content of the current environment into a fresh output. */
    contentOf(name, stop) {
      const inner = new Out();
      this.parseInto(inner, Object.assign({ env: name }, stop || {}));
      return inner;
    }

    preambleDone() {
      if (this.date === undefined) this.date = null;
    }

    verbatim(name) {
      let language = '';
      if (name === 'minted') { this.readOpt(); language = this.readArg(); }
      if (name === 'lstlisting') {
        const options = this.readOpt() || '';
        const m = options.match(/language\s*=\s*(?:\[[^\]]*\])?\s*\{?([\w+#-]+)/i);
        if (m) language = m[1];
        const caption = options.match(/caption\s*=\s*(\{[^}]*\}|[^,\]]+)/);
        if (caption) {
          const text = caption[1].replace(/^\{|\}$/g, '');
          this.pendingListingCaption = text;
        }
      }
      if (name === 'Verbatim' || name === 'BVerbatim') this.readOpt();
      if (name === 'greececode') {
        // Sweave and knitr chunks: <<label, options>>= … @
        const label = this.readArg().trim();
        const options = this.readArg();
        const chips = [label, ...options.split(',').map((o) => o.trim()).filter(Boolean)].filter(Boolean).map((t) => `<span class="chip">${esc(t)}</span>`).join('');
        if (chips) this.out.block(`<div class="chunk-meta">${chips}</div>`);
        language = 'r';
      }
      if (name === 'code' || name === 'sourcecode') { const opt = this.readOpt(); if (opt) language = opt; }
      let text = this.readUntilEnd(name);
      text = text.replace(/^[ \t]*\n/, '').replace(/\n[ \t]*$/, '');
      this.codeBlock(text, language);
    }

    codeBlock(text, language) {
      const map = { 'c++': 'cpp', python3: 'python', py: 'python', sh: 'bash', matlab: 'matlab', r: 'r', tex: 'latex', 'java': 'java' };
      const lang = (map[String(language).toLowerCase()] || String(language).toLowerCase()).replace(/[^\w+#-]/g, '');
      const highlight = this.options.highlight || ((t) => esc(t));
      const title = this.options.languageTitle ? this.options.languageTitle(lang) : lang;
      const body = highlight(dedent(text), lang);
      let caption = '';
      if (this.pendingListingCaption) {
        const number = this.formatCounter('listing', this.stepCounter('listing'));
        caption = `<figcaption><span class="cap-label">Listing ${number}:</span> ${this.inline(this.pendingListingCaption)}</figcaption>`;
        this.pendingListingCaption = null;
      }
      this.out.block(`<figure class="codeblock tex-code"><div class="tools">${title ? `<span class="lang">${esc(title)}</span>` : ''}<button class="copy" type="button">Copy</button></div><pre><code class="hljs">${body}</code></pre>${caption}</figure>`);
    }

    picture(name) {
      const body = this.readUntilEnd(name);
      const kind = { tikzpicture: 'TikZ drawing', pgfpicture: 'PGF drawing', picture: 'Picture', circuitikz: 'Circuit diagram', forest: 'Tree diagram', tikzcd: 'Commutative diagram', axis: 'Plot', pspicture: 'PSTricks drawing' }[name] || 'Drawing';
      const nodes = [];
      body.replace(/\\node[^{;]*\{([^{}]{1,60})\}/g, (m, text) => { if (nodes.length < 8 && text.trim()) nodes.push(text.trim()); return m; });
      const detail = nodes.length ? `<span class="detail">${nodes.map((n) => this.inline(n)).join(' · ')}</span>` : '';
      this.out.block(`<div class="tex-placeholder"><span class="kind">${kind}</span>${detail}</div>`);
    }

    // ---------------------------------------------------------- Lists

    list(name) {
      const kind = /enum|enumerate/.test(name) ? 'enumerate' : name === 'description' ? 'description' : 'itemize';
      const level = this.envStack.filter((e) => /^(itemize|enumerate|description|compactitem|compactenum|asparaenum|inparaenum|enumerate\*|itemize\*|list)$/.test(e)).length - 1;
      let template = null;
      let start = 1;
      if (name === 'list') { template = this.readArg(); this.readArg(); }
      if (this.isBeamer) this.readOverlay();
      const options = this.readOpt();
      if (options) {
        const label = options.match(/label\s*=\s*(\{(?:[^{}]|\{[^{}]*\})*\}|[^,]+)/);
        const startAt = options.match(/start\s*=\s*(\d+)/);
        if (startAt) start = Number(startAt[1]);
        if (label) template = label[1].replace(/^\{|\}$/g, '');
        else if (!/=/.test(options)) template = options;
      }
      const depth = Math.min(level, 4);
      const items = [];
      let counter = start - 1;
      // Text before the first \item is kept, unlabelled.
      const leadHTML = this.contentOf(name, { item: true }).html();
      if (leadHTML) items.push({ html: leadHTML, label: '' });
      // The loop: each \item starts a new entry until \end{name}.
      while (this.lastStop === 'item') {
        if (this.isBeamer) this.readOverlay();
        const custom = this.readOpt();
        let label;
        let ref;
        if (custom !== null) {
          label = this.inline(custom);
          ref = plain(label);
        } else if (kind === 'enumerate') {
          counter++;
          label = esc(formatEnumLabel(template, counter, depth));
          ref = formatEnumLabel(null, counter, depth).replace(/[.)]$/, '').replace(/^\(/, '');
        } else if (kind === 'itemize') {
          label = template ? this.inline(template) : ['•', '–', '∗', '·'][depth % 4];
        } else label = '';
        const id = this.id('item');
        const savedTarget = this.target;
        this.target = { id, text: ref || '', type: 'item' };
        const out = new Out();
        if (kind === 'description') out.text(`<b class="dt">${label}</b> `);
        else out.text(`<span class="lbl">${label}</span>`);
        this.parseInto(out, { env: name, item: true });
        this.target = savedTarget;
        items.push({ html: out.html(), label, id });
      }
      const tag = kind === 'enumerate' ? 'ol' : 'ul';
      const body = items.map((item) => `<li${item.id ? ` id="${item.id}"` : ''}>${unwrapSingle(item.html)}</li>`).join('');
      this.out.block(`<${tag} class="tex-list ${kind}">${body}</${tag}>`);
    }

    // ---------------------------------------------------------- Floats

    floatEnvironment(name) {
      const type = /^(table|wraptable|sidewaystable)/.test(name) ? 'table' : name === 'algorithm' ? 'algorithm' : 'figure';
      if (name === 'wrapfigure' || name === 'wraptable') { this.readOpt(); this.readArg(); this.readOpt(); this.readArg(); }
      else this.readOpt();
      const id = this.id(type === 'table' ? 'tab' : type === 'algorithm' ? 'alg' : 'fig');
      const savedFloat = this.float;
      const savedTarget = this.target;
      this.float = { type, id, sub: 0 };
      this.target = { id, text: '', type };
      const inner = this.contentOf(name);
      this.float = savedFloat;
      this.target = savedTarget;
      const html = inner.html();
      if (html) this.out.block(`<figure class="tex-float tex-${type}" id="${id}">${html}</figure>`);
    }

    subfloatEnvironment(name) {
      this.readOpt();
      const width = this.readArg();
      const fraction = widthFraction(width);
      const parent = this.float;
      const letter = parent ? alpha(++parent.sub, false) : '';
      const id = this.id('sub');
      const savedTarget = this.target;
      const savedFloat = this.float;
      this.float = { type: parent ? parent.type : 'figure', id, subOf: parent, letter };
      this.target = { id, text: parent && this.counterTextFor(parent) ? this.counterTextFor(parent) + letter : letter, type: 'subfigure' };
      const inner = this.contentOf(name);
      this.float = savedFloat;
      this.target = savedTarget;
      const style = fraction ? ` style="width:${(fraction * 100).toFixed(1)}%"` : '';
      this.out.text(`<span class="tex-subfloat" id="${id}"${style}>${inner.html()}</span>`);
    }

    counterTextFor(float) { return float.number || ''; }

    caption(name) {
      const star = this.readStar();
      let type = this.float ? this.float.type : 'figure';
      if (name === 'captionof') { type = this.readArg().trim().replace(/\*$/, ''); }
      this.readOpt();
      const raw = this.readArg();
      const float = this.float || { type, id: this.id('fig') };
      let labelText = '';
      if (float.subOf) {
        labelText = `(${float.letter})`;
        const parentNumber = float.subOf.number || this.formatCounter(float.subOf.type, (this.counters[float.subOf.type] || 0) + 1);
        float.subNumber = parentNumber + float.letter;
        if (this.target && this.target.type === 'subfigure') this.target.text = float.subNumber;
      } else if (!star && name !== 'caption*') {
        const counter = type === 'algorithm' ? 'algorithm' : type === 'table' ? 'table' : 'figure';
        const number = this.formatCounter(counter, this.stepCounter(counter));
        float.number = number;
        if (this.target && this.target.id === float.id) this.target.text = number;
        else this.target = { id: float.id, text: number, type };
        const word = { table: 'Table', algorithm: 'Algorithm', figure: 'Figure', listing: 'Listing' }[type] || 'Figure';
        labelText = `${word} ${number}:`;
      }
      const text = this.inline(raw);
      if (!float.subOf && labelText) this.floats[type === 'table' ? 'table' : 'figure'].push({ id: float.id, number: float.number, text: plain(this.inline(raw.replace(/\\label\s*\{[^}]*\}/g, ''))) });
      this.out.block(`<figcaption>${labelText ? `<span class="cap-label">${labelText}</span> ` : ''}${text}</figcaption>`);
      if (!this.float) this.target = { id: float.id, text: float.number || '', type };
    }

    includeGraphics() {
      this.readStar();
      if (this.isBeamer) this.readOverlay();
      const options = this.readOpt() || '';
      const path = this.readArg().trim();
      const figure = this.lookupFigure(path);
      this.out.text(this.figureHTML(figure, path, options));
    }

    lookupFigure(path) {
      const figures = this.figures;
      if (figures[path]) return figures[path];
      const clean = path.replace(/^\.\//, '').replace(/^"|"$/g, '');
      if (figures[clean]) return figures[clean];
      const stem = clean.replace(/\.[A-Za-z0-9]+$/, '');
      return figures[stem] || null;
    }

    figureHTML(figure, path, options) {
      const name = esc(path.split('/').pop() || path);
      if (!figure || !figure.kind || figure.kind === 'missing') {
        return `<span class="tex-placeholder figure"><span class="kind">Missing figure</span><span class="detail">${name}</span></span>`;
      }
      if (figure.kind === 'unsupported') {
        return `<span class="tex-placeholder figure"><span class="kind">${esc(figure.note || 'Figure')}</span><span class="detail">${name}</span></span>`;
      }
      const style = sizeStyle(options, figure);
      if (figure.kind === 'svg' && figure.svg) {
        return `<span class="tex-graphic svg"${style ? ` style="${style}"` : ''}>${figure.svg}</span>`;
      }
      if (!/^greece:\/\/(file|module)\//.test(figure.src || '')) return `<span class="tex-placeholder figure"><span class="kind">Figure</span><span class="detail">${name}</span></span>`;
      return `<img class="tex-graphic" src="${esc(figure.src)}" alt="${name}"${style ? ` style="${style}"` : ''}>`;
    }

    // ---------------------------------------------------------- Tables

    tabular(name) {
      if (name === 'tabular*' || name === 'tabularx' || name === 'tabulary' || name === 'xltabular') this.readArg();
      if (this.isBeamer) this.readOverlay();
      this.readOpt();
      const spec = name === 'array' ? this.readArg() : this.readArg();
      const columns = parseColumns(spec);
      const saved = this.table;
      const table = { rows: [], ruleAbove: null };
      this.table = table;
      let row = { cells: [], rule: null, partial: [] };
      let cell = { span: 1, rowspan: 1, align: null };
      const occupied = [];
      for (let guard = 0; guard < 100000; guard++) {
        this.check();
        const out = new Out();
        table.cell = cell;
        table.row = row;
        const reason = this.parseInto(out, { env: name, cell: true, row: true });
        const html = out.inline();
        row.cells.push({ html, span: cell.span, rowspan: cell.rowspan, align: cell.align, empty: !Out.visible(html) });
        cell = { span: 1, rowspan: 1, align: null };
        if (reason === 'cell') continue;
        table.rows.push(row);
        if (reason !== 'row') break;
        row = { cells: [], rule: null, partial: [] };
      }
      this.table = saved;
      // A last row holding only rules closes the table.
      let bottom = null;
      const last = table.rows[table.rows.length - 1];
      if (last && last.cells.every((c) => c.empty)) { bottom = last.rule; table.rows.pop(); }
      const firstMid = table.rows.findIndex((r, i) => i > 0 && (r.rule === 'mid' || r.rule === 'hline') && table.rows[0].rule);
      const headerRows = table.rows.length > 2 && firstMid > 0 && firstMid <= 3 ? firstMid : 0;
      const htmlRows = [];
      table.rows.forEach((r, index) => {
        let col = 0;
        const cells = [];
        r.cells.forEach((c) => {
          while (occupied[col] > 0) { occupied[col]--; col++; }
          if (c.skip) return;
          const spec = columns[col] || columns[columns.length - 1] || { align: 'l' };
          const align = c.align || spec.align;
          const tag = index < headerRows ? 'th' : 'td';
          const attrs = [];
          if (c.span > 1) attrs.push(`colspan="${Math.min(c.span, 50)}"`);
          if (c.rowspan > 1) { attrs.push(`rowspan="${Math.min(c.rowspan, 50)}"`); for (let k = 0; k < c.span; k++) occupied[col + k] = c.rowspan - 1; }
          const classes = [`a-${align}`];
          if (spec.left && col === 0) classes.push('vl');
          if ((columns[col + c.span - 1] || {}).right) classes.push('vr');
          if (r.partial && r.partial.some(([a, b]) => col + 1 >= a && col + 1 <= b)) classes.push('cmid');
          if (spec.width) attrs.push(`style="min-width:${spec.width}"`);
          cells.push(`<${tag} class="${classes.join(' ')}"${attrs.length ? ' ' + attrs.join(' ') : ''}>${c.html}</${tag}>`);
          col += c.span;
        });
        // Cells taken by a \multirow above are skipped (their placeholder cells in the source are empty).
        const rule = r.rule ? ` class="rule-${r.rule}"` : '';
        htmlRows.push(`<tr${rule}>${cells.join('')}</tr>`);
      });
      const head = headerRows ? `<thead>${htmlRows.slice(0, headerRows).join('')}</thead>` : '';
      const body = `<tbody>${htmlRows.slice(headerRows).join('')}</tbody>`;
      const classes = ['tabular'];
      if (bottom) classes.push(`bottom-${bottom}`);
      if (columns.some((c) => c.left || c.right)) classes.push('ruled');
      this.out.block(`<div class="tabular-wrap"><table class="${classes.join(' ')}">${head}${body}</table></div>`);
    }

    rule(kind) {
      const table = this.table;
      if (kind === 'cmid') {
        if (this.s.peek() === "(") this.readParens();   // (lr) trims
        this.readOpt();
        const range = this.readArg();
        const m = range.match(/(\d+)\s*-\s*(\d+)/);
        if (table && m) table.row.partial.push([Number(m[1]), Number(m[2])]);
        return;
      }
      if (kind === 'cline') {
        const range = this.readArg();
        const m = range.match(/(\d+)\s*-\s*(\d+)/);
        if (table && m) table.row.partial.push([Number(m[1]), Number(m[2])]);
        return;
      }
      if (kind === 'top' || kind === 'mid' || kind === 'bottom') this.readOpt();
      if (kind === 'specialrule') { this.readArg(); this.readArg(); this.readArg(); kind = 'mid'; }
      if (!table) { if (kind === 'hline' && !this.table) this.out.block('<hr class="tex-rule">'); return; }
      const row = table.row;
      if (row.cells.length === 0) row.rule = row.rule === 'hline' && kind === 'hline' ? 'double' : (row.rule === 'top' ? 'top' : kind);
    }

    readParens() {
      const s = this.s;
      if (s.peek() !== '(') return null;
      s.next();
      let text = '';
      while (!s.eof() && s.peek() !== ')' && text.length < 20) text += s.next();
      if (s.peek() === ')') s.next();
      return text;
    }

    multicolumn() {
      const n = Math.max(1, Math.min(50, parseInt(this.readArg(), 10) || 1));
      const spec = parseColumns(this.readArg())[0] || { align: 'c' };
      const content = this.inline(this.readArg());
      if (this.table && this.table.cell) { this.table.cell.span = n; this.table.cell.align = spec.align; }
      this.out.text(content);
    }

    multirow() {
      const n = Math.max(1, Math.min(50, parseInt(this.readArg(), 10) || 1));
      this.readOpt();
      this.readArg();
      this.readOpt();
      const content = this.inline(this.readArg());
      if (this.table && this.table.cell) this.table.cell.rowspan = n;
      this.out.text(content);
    }

    // ---------------------------------------------------------- Sections

    sectioning(name) {
      const star = this.readStar();
      if (this.isBeamer) {
        this.readOverlay();
        const short = this.readOpt();
        const title = this.readArg();
        if (name === 'section') this.section = plain(this.inline(short || title));
        if (name === 'subsection') this.subsection = plain(this.inline(short || title));
        return;
      }
      this.readOpt();   // the short title only matters for running heads
      const raw = this.readArg();
      const level = SECTION_LEVELS[name];
      const numbered = !star && level <= this.secnumdepth;
      let number = null;
      if (numbered) {
        this.stepCounter(name);
        number = name === 'part' ? roman(this.counters.part, true) : this.sectionNumber(name);
      }
      const id = this.id('sec');
      this.target = { id, text: number || '', type: name };
      const html = this.inline(raw.replace(/\\label\s*\{([^}]*)\}/g, (m, key) => { this.label(key); return ''; }));
      const text = plain(html);
      if (level >= 4) {
        this.out.flush();
        this.out.text(`<strong class="runin">${number && level <= this.secnumdepth ? `<span class="num">${number}</span>` : ''}${html}</strong> `);
        this.out.pClass = 'runin-p';
        return;
      }
      const tag = { '-1': 'h2', 0: 'h2', 1: this.isBook ? 'h3' : 'h2', 2: this.isBook ? 'h4' : 'h3', 3: this.isBook ? 'h5' : 'h4' }[level] || 'h4';
      const cls = `tex-${name}`;
      this.headings.push({ id, level: Number(tag[1]), number, text, name, starred: star });
      let numberHTML = '';
      if (number) {
        if (name === 'chapter') numberHTML = `<span class="chapter-label">${this.appendix ? 'Appendix' : 'Chapter'} ${number}</span>`;
        else if (name === 'part') numberHTML = `<span class="chapter-label">Part ${number}</span>`;
        else numberHTML = `<span class="num">${number}</span>`;
      }
      this.out.block(`<${tag} id="${id}" class="${cls}">${numberHTML}${html}</${tag}>`);
    }

    // ---------------------------------------------------------- Theorems

    theoremEnvironment(name, theorem) {
      const note = this.readOpt();
      let number = null;
      if (theorem.counter) {
        const key = 'thm:' + theorem.counter;
        this.counters[key] = (this.counters[key] || 0) + 1;
        const within = theorem.within || (this.theorems.get(theorem.counter) || {}).within;
        number = within ? `${this.sectionNumber(within)}.${this.counters[key]}` : String(this.counters[key]);
      }
      const id = this.id('thm');
      const savedTarget = this.target;
      this.target = { id, text: number || '', type: name };
      const out = new Out();
      out.text(`<span class="thm-head">${esc(theorem.title)}${number ? ' ' + number : ''}</span>${note !== null ? ` <span class="thm-note">(${this.inline(note)})</span>` : ''}<span class="thm-head">.</span> `);
      this.parseInto(out, { env: name });
      this.target = savedTarget;
      this.out.block(`<div class="tex-thm ${theorem.style}" id="${id}">${out.html()}</div>`);
    }

    proof(name) {
      const note = this.readOpt();
      const out = new Out();
      out.text(`<em class="proof-head">${note !== null ? this.inline(note) : 'Proof'}.</em> `);
      this.parseInto(out, { env: name });
      if (out.fresh && out.blocks.length) out.blocks[out.blocks.length - 1] = out.blocks[out.blocks.length - 1].replace(/<\/p>$|<\/div>$/, (m) => `<span class="qed"></span>${m}`);
      else out.text('<span class="qed"></span>');
      this.out.block(`<div class="tex-proof">${out.html()}</div>`);
    }

    // ---------------------------------------------------------- Title

    maketitle() {
      this.titleMade = true;
      if (this.isBeamer) { this.titleSlide(); return; }
      const parts = [];
      if (this.title !== null) {
        const thanksMarks = this.thanksMarks(this.titleThanks);
        parts.push(`<h1 class="tex-doc-title">${this.inline(this.title)}${thanksMarks}</h1>`);
      }
      if (this.subtitle) parts.push(`<p class="tex-subtitle">${this.inline(this.subtitle)}</p>`);
      const authors = this.authorBlocks();
      if (authors) parts.push(authors);
      const date = this.date === undefined || this.date === null ? (this.dateSet ? '' : today()) : this.inline(this.date);
      if (date) parts.push(`<p class="tex-date">${date}</p>`);
      if (parts.length) this.out.block(`<header class="tex-title">${parts.join('')}</header>`);
      if (this.pendingAbstract) { this.out.block(this.pendingAbstract); this.pendingAbstract = null; }
      if (this.keywords) { this.out.block(`<p class="tex-keywords"><span class="label">Keywords</span> ${this.inline(this.keywords)}</p>`); this.keywords = null; }
    }

    thanksMarks(list) {
      if (!list || !list.length) return '';
      return list.map((html) => {
        const symbol = THANKS_SYMBOLS[this.thanks.length % THANKS_SYMBOLS.length];
        this.thanks.push({ symbol, html });
        return `<sup class="thanks">${symbol}</sup>`;
      }).join('');
    }

    /** Extracts \thanks{} from title/author text, returning [clean text, thanks HTML list]. */
    extractThanks(raw) {
      const notes = [];
      let out = '';
      let i = 0;
      while (i < raw.length) {
        const at = raw.indexOf('\\thanks', i);
        if (at < 0) { out += raw.slice(i); break; }
        out += raw.slice(i, at);
        let j = at + 7;
        while (raw[j] === ' ') j++;
        if (raw[j] !== '{') { i = j; continue; }
        let depth = 0;
        let k = j;
        for (; k < raw.length; k++) {
          if (raw[k] === '\\') { k++; continue; }
          if (raw[k] === '{') depth++;
          else if (raw[k] === '}' && --depth === 0) break;
        }
        notes.push(raw.slice(j + 1, k));
        out += `\u0003${notes.length - 1}\u0003`;
        i = k + 1;
      }
      return [out, notes];
    }

    authorBlocks() {
      if (!this.authors.length) return '';
      const blocks = [];
      for (const raw of this.authors) {
        for (const one of raw.split(/\\and\b|\\And\b|\\AND\b/)) {
          const [clean, notes] = this.extractThanks(one);
          const lines = splitLines(clean).map((l) => l.trim()).filter(Boolean);
          if (!lines.length) continue;
          const render = (text) => this.inline(text).replace(/\u0003(\d+)\u0003/g, (m, n) => this.thanksMarks([this.inline(notes[Number(n)])]));
          const name = render(lines[0]);
          const rest = lines.slice(1).map((l) => `<span class="affil">${render(l)}</span>`).join('');
          blocks.push(`<div class="author"><span class="name">${name}</span>${rest}</div>`);
        }
      }
      if (this.institute) blocks.push(`<div class="author institute"><span class="affil">${this.inline(this.institute)}</span></div>`);
      return blocks.length ? `<div class="tex-authors">${blocks.join('')}</div>` : '';
    }

    abstract(name) {
      const out = this.contentOf(name);
      const html = `<section class="tex-abstract"><h6>Abstract</h6>${out.html()}</section>`;
      if (!this.titleMade && (this.title !== null || this.inPreamble)) this.pendingAbstract = html;
      else this.out.block(html);
    }

    // ---------------------------------------------------------- Footnotes

    footnote(name) {
      const number = this.readOpt();
      if (name === 'footnotemark') {
        const n = number ? Number(number) : ++this.counters.footnote;
        this.out.text(`<sup class="fn-ref"><a href="#tex-fn-${n}">${n}</a></sup>`);
        return;
      }
      const raw = this.readArg();
      if (name === 'footnotetext') {
        const n = number ? Number(number) : this.counters.footnote;
        this.footnotes.push({ n, html: this.blockHTML(raw), id: `tex-fn-${n}`, ref: null });
        return;
      }
      if (this.slide) {
        const n = ++this.slide.notes;
        this.slide.footnotes.push(`<p><sup>${n}</sup> ${this.inline(raw)}</p>`);
        this.out.text(`<sup class="fn-ref">${n}</sup>`);
        return;
      }
      const n = number ? Number(number) : ++this.counters.footnote;
      const ref = this.id('fnref');
      const savedTarget = this.target;
      const html = this.blockHTML(raw);
      this.target = savedTarget;
      this.footnotes.push({ n, html, id: `tex-fn-${this.footnotes.length + 1}`, ref });
      this.out.text(`<sup class="fn-ref"><a href="#tex-fn-${this.footnotes.length}" id="${ref}">${n}</a></sup>`);
    }

    // ---------------------------------------------------------- Citations

    cite(name) {
      this.readStar();
      if (this.isBeamer) this.readOverlay();
      let pre = this.readOpt();
      let post = this.readOpt();
      if (post === null && pre !== null) { post = pre; pre = null; }
      const keys = this.readArg().split(',').map((k) => k.trim()).filter(Boolean);
      if (name === 'nocite') {
        if (keys.includes('*')) this.nociteAll = true;
        keys.forEach((k) => this.noteCited(k));
        return;
      }
      keys.forEach((k) => this.noteCited(k));
      const payload = encodeURIComponent(JSON.stringify({ name, keys, pre: pre !== null ? this.inline(pre) : null, post: post !== null ? this.inline(post) : null }));
      const html = `\u0001C${payload}\u0002`;
      if (name === 'footcite' || name === 'footfullcite') {
        const n = ++this.counters.footnote;
        const ref = this.id('fnref');
        this.footnotes.push({ n, html: `<p>\u0001C${encodeURIComponent(JSON.stringify({ name: 'cite', keys, pre: null, post: null }))}\u0002</p>`, id: `tex-fn-${this.footnotes.length + 1}`, ref });
        this.out.text(`<sup class="fn-ref"><a href="#tex-fn-${this.footnotes.length}" id="${ref}">${n}</a></sup>`);
        return;
      }
      this.out.text(html);
    }

    noteCited(key) {
      if (key === '*' || this.citedSet.has(key)) return;
      this.citedSet.add(key);
      this.cited.push(key);
    }

    bibliographyCommand(name) {
      if (name === 'printbibliography') this.readOpt();
      else this.readArg();
      if (this.bibPlaced) return;
      this.bibPlaced = true;
      if (this.options.bbl && !this.bibItems) {
        this.sub(this.options.bbl, (o) => { if (o.blocks.length) this.out.block(o.html()); return null; });
        return;
      }
      this.out.block('\u0001BIB\u0002');
    }

    thebibliography(name) {
      this.readArg();
      const items = this.bibItems || (this.bibItems = []);
      const lead = new Out();
      this.parseInto(lead, { env: name, item: true });
      while (this.lastStop === 'item') {
        // \bibitem[label]{key}
        const label = this.readOpt();
        const key = this.readArg().trim();
        const out = new Out();
        this.parseInto(out, { env: name, item: true });
        items.push({ key, label, html: out.inline() });
      }
      this.bibPlaced = true;
      this.out.block('\u0001BIBITEMS\u0002');
    }

    // ---------------------------------------------------------- Beamer

    frame(name) {
      if (!this.isBeamer) { const out = this.contentOf(name); this.out.block(`<div class="tex-env">${out.html()}</div>`); return; }
      this.readOverlay();
      const options = this.readOpt() || '';
      this.readOverlay();
      let title = null;
      let subtitle = null;
      this.skipSpaces(true);
      if (this.s.peek() === '{') title = this.readArg();
      this.skipSpaces(false);
      if (this.s.peek() === '{') subtitle = this.readArg();
      const slide = { title: title !== null ? this.inline(title) : '', subtitle: subtitle !== null ? this.inline(subtitle) : '', html: '', section: this.section, notes: 0, footnotes: [], plain: /\bplain\b/.test(options), options, isTitle: false };
      const saved = this.slide;
      this.slide = slide;
      const out = this.contentOf(name);
      this.slide = saved;
      slide.html = out.html();
      if (slide.isTitle && !plain(slide.html.replace(/<header[\s\S]*<\/header>/, ''))) slide.html = slide.titleHTML;
      this.slides.push(slide);
    }

    frametitle(name) {
      this.readOverlay();
      this.readOpt();
      const text = this.inline(this.readArg());
      if (!this.slide) return;
      if (name === 'framesubtitle') this.slide.subtitle = text;
      else this.slide.title = text;
    }

    titleSlide() {
      const parts = [];
      if (this.title !== null) parts.push(`<h1 class="slide-title">${this.inline(this.extractThanks(this.title)[0].replace(/\u0003\d+\u0003/g, ''))}</h1>`);
      if (this.subtitle) parts.push(`<p class="slide-subtitle">${this.inline(this.subtitle)}</p>`);
      const authors = this.authors.map((a) => this.inline(a.replace(/\\thanks\s*\{[^}]*\}/g, '').split(/\\and\b|\\And\b/).map((n) => n.trim()).filter(Boolean).join(', '))).join(', ');
      if (authors) parts.push(`<p class="slide-author">${authors}</p>`);
      if (this.institute) parts.push(`<p class="slide-institute">${this.inline(this.institute)}</p>`);
      const date = this.date === undefined || this.date === null ? (this.dateSet ? '' : today()) : this.inline(this.date);
      if (date) parts.push(`<p class="slide-date">${date}</p>`);
      const html = `<header class="slide-titlepage">${parts.join('')}</header>`;
      if (this.slide) { this.slide.isTitle = true; this.slide.titleHTML = html; }
      this.out.block(html);
    }

    columns(name) {
      this.readOpt();
      const out = this.contentOf(name);
      this.out.block(`<div class="slide-columns">${out.html()}</div>`);
    }

    column(name) {
      this.readOpt();
      const width = widthFraction(this.readArg());
      const out = this.contentOf(name);
      this.out.block(`<div class="slide-column"${width ? ` style="flex:0 0 ${(width * 100).toFixed(1)}%"` : ''}>${out.html()}</div>`);
    }

    beamerBlock(name) {
      this.readOverlay();
      const title = this.readArg();
      const out = this.contentOf(name);
      const kind = name === 'alertblock' ? 'alert' : name === 'exampleblock' ? 'example' : 'plain';
      this.out.block(`<div class="slide-block ${kind}">${title.trim() ? `<p class="block-title">${this.inline(title)}</p>` : ''}${out.html()}</div>`);
    }

    // ---------------------------------------------------------- Algorithms

    algorithmic(name) {
      this.readOpt();
      const saved = this.algo;
      this.algo = { lines: [], indent: 0, line: new Out() };
      const out = this.algo.line;
      this.parseInto(out, { env: name, algo: true });
      this.endAlgoLine();
      const lines = this.algo.lines;
      this.algo = saved;
      const html = lines.map((l) => `<li style="--indent:${Math.min(l.indent, 12)}">${l.html || '&nbsp;'}</li>`).join('');
      this.out.block(`<ol class="tex-algorithm">${html}</ol>`);
    }

    endAlgoLine() {
      const algo = this.algo;
      const html = algo.line.inline();
      if (html.trim()) algo.lines.push({ indent: algo.lineIndent ?? algo.indent, html });
      algo.line.blocks = [];
      algo.line.p = '';
      algo.line.fresh = true;
      algo.lineIndent = null;
      return algo.line;
    }

    algoLine(prefix, indentBefore, indentAfter) {
      const algo = this.algo;
      this.endAlgoLine();
      algo.indent = Math.max(0, algo.indent + (indentBefore || 0));
      algo.lineIndent = algo.indent;
      if (prefix) algo.line.text(prefix);
      algo.indent = Math.max(0, algo.indent + (indentAfter || 0));
    }

    algoCommand(name) {
      const kw = (w) => `<b class="kw">${w}</b>`;
      const arg = () => this.inline(this.readArg());
      switch (name) {
        case 'State': case 'STATE': case 'Statex': this.algoLine('', 0, 0); return true;
        case 'Require': case 'REQUIRE': this.algoLine(kw('Require:') + ' ', 0, 0); return true;
        case 'Ensure': case 'ENSURE': this.algoLine(kw('Ensure:') + ' ', 0, 0); return true;
        case 'Input': case 'KwIn': this.algoLine(kw('Input:') + ' ' + (name === 'KwIn' ? arg() : ''), 0, 0); return true;
        case 'Output': case 'KwOut': this.algoLine(kw('Output:') + ' ' + (name === 'KwOut' ? arg() : ''), 0, 0); return true;
        case 'KwData': this.algoLine(kw('Data:') + ' ' + arg(), 0, 0); return true;
        case 'KwResult': this.algoLine(kw('Result:') + ' ' + arg(), 0, 0); return true;
        case 'If': case 'IF': {
          const cond = arg();
          this.algoLine(`${kw('if')} ${cond} ${kw('then')}`, 0, 1);
          if (this.s.peek() === '{' || (this.s.peek() === ' ' && this.s.peek(1) === '{')) { this.algoBody(); this.algoLine(kw('end if'), -1, 0); }
          return true;
        }
        case 'eIf': {
          const cond = arg();
          this.algoLine(`${kw('if')} ${cond} ${kw('then')}`, 0, 1);
          this.algoBody();
          this.algoLine(kw('else'), -1, 1);
          this.algoBody();
          this.algoLine(kw('end'), -1, 0);
          return true;
        }
        case 'ElsIf': case 'ELSIF': this.algoLine(`${kw('else if')} ${arg()} ${kw('then')}`, -1, 1); return true;
        case 'Else': case 'ELSE': this.algoLine(kw('else'), -1, 1); return true;
        case 'EndIf': case 'ENDIF': this.algoLine(kw('end if'), -1, 0); return true;
        case 'For': case 'FOR': case 'ForAll': case 'FORALL': case 'ForEach': {
          const cond = arg();
          this.algoLine(`${kw(name.toLowerCase().startsWith('forall') ? 'for all' : 'for')} ${cond} ${kw('do')}`, 0, 1);
          if (this.s.peek() === '{') { this.algoBody(); this.algoLine(kw('end for'), -1, 0); }
          return true;
        }
        case 'EndFor': case 'ENDFOR': this.algoLine(kw('end for'), -1, 0); return true;
        case 'While': case 'WHILE': {
          const cond = arg();
          this.algoLine(`${kw('while')} ${cond} ${kw('do')}`, 0, 1);
          if (this.s.peek() === '{') { this.algoBody(); this.algoLine(kw('end while'), -1, 0); }
          return true;
        }
        case 'EndWhile': case 'ENDWHILE': this.algoLine(kw('end while'), -1, 0); return true;
        case 'Repeat': case 'REPEAT': this.algoLine(kw('repeat'), 0, 1); return true;
        case 'Until': case 'UNTIL': this.algoLine(`${kw('until')} ${arg()}`, -1, 0); return true;
        case 'Loop': case 'LOOP': this.algoLine(kw('loop'), 0, 1); return true;
        case 'EndLoop': case 'ENDLOOP': this.algoLine(kw('end loop'), -1, 0); return true;
        case 'Function': case 'Procedure': {
          const fn = arg();
          const params = arg();
          this.algoLine(`${kw(name.toLowerCase())} <span class="sc">${fn}</span>(${params})`, 0, 1);
          return true;
        }
        case 'EndFunction': case 'EndProcedure': this.algoLine(kw('end ' + name.slice(3).toLowerCase()), -1, 0); return true;
        case 'Return': case 'RETURN': this.algoLine(kw('return') + ' ', 0, 0); return true;
        case 'KwRet': this.algoLine(kw('return') + ' ' + arg(), 0, 0); return true;
        case 'Comment': case 'COMMENT': case 'tcp': case 'tcc': this.algo.line.text(` <span class="algo-comment">▷ ${arg()}</span>`); return true;
        case ';': this.endAlgoLine(); this.algo.lineIndent = null; return true;
        default: return false;
      }
    }

    algoBody() {
      const raw = this.readArg();
      this.s.push(raw);
      // Parse the pushed body until it is exhausted.
      const frames = this.s.frames.length;
      const s = this.s;
      while (s.frames.length >= frames && !(s.frames.length === frames && s.frames[frames - 1].i >= s.frames[frames - 1].s.length)) {
        if (s.eof()) break;
        const before = s.frames.length;
        const c = s.peek();
        if (c === '\\') {
          s.next();
          const name = this.readName();
          if (/^[A-Za-z@]+$/.test(name)) this.skipSpaces(true);
          if (!this.algoCommand(name)) { s.push('\\' + name + ' '); this.parseOneInto(this.algo.line); }
        } else this.parseOneInto(this.algo.line);
        if (s.frames.length < before - 1) break;
      }
    }

    parseOneInto(out) {
      // Parse a single token or text run.
      const saved = this.out;
      this.out = out;
      try {
        const s = this.s;
        const c = s.peek();
        if (c === '\\') { this.command({}); return; }
        if (c === '{') { s.next(); this.group(); return; }
        if (c === '$') { this.dollarMath(); return; }
        if (c === '\n') { this.newline(); return; }
        if (c === '%') { this.comment(); return; }
        const m = s.match(/[^\\{}$%\n]+/y);
        if (m) out.text(esc(m[0])); else s.next();
      } finally { this.out = saved; }
    }

    // ---------------------------------------------------------- Post-processing

    finish() {
      this.out.flush();
      let html = this.out.html();
      if (this.pendingAbstract) { html = this.pendingAbstract + html; this.pendingAbstract = null; }
      const bib = this.buildBibliography();
      html = html.replace('\u0001BIBITEMS\u0002', bib.html).replace('\u0001BIB\u0002', bib.html);
      if (!this.bibPlaced && this.cited.length && (this.options.bib || []).length) html += bib.html;
      html = this.resolve(html, bib);
      html = html.replace('\u0001TOC\u0002', () => this.tocHTML()).replace('\u0001LOF\u0002', () => this.listHTML('figure')).replace('\u0001LOT\u0002', () => this.listHTML('table'));
      const notes = this.notesHTML(bib);
      const slides = this.slides.map((slide) => Object.assign({}, slide, {
        html: this.resolve(slide.html, bib),
        title: this.resolve(slide.title, bib),
        footnotes: slide.footnotes.map((f) => this.resolve(f, bib)),
      }));
      return {
        kind: this.isBeamer ? 'beamer' : 'article',
        docClass: this.docClass,
        html: html + notes,
        slides,
        title: this.title !== null ? plain(this.inline(this.extractThanks(this.title)[0].replace(/\u0003\d+\u0003/g, ''))) : '',
        headings: this.headings,
        math: this.math,
        katexMacros: this.katexMacros,
        labels: Object.fromEntries(Array.from(this.labels.entries()).map(([k, v]) => [k, v.text])),
        stopped: this.stopped,
        citationStyle: bib.style,
        parskip: this.packages.has('parskip'),
      };
    }

    notesHTML(bib) {
      const parts = [];
      for (const note of this.thanks) parts.push(`<li class="thanks-note"><span class="mark">${note.symbol}</span>${note.html}</li>`);
      this.footnotes.forEach((f, i) => {
        const back = f.ref ? ` <a href="#${f.ref}" class="footnote-backref">↩︎</a>` : '';
        const body = unwrapSingle(this.resolve(f.html, bib));
        parts.push(`<li id="tex-fn-${i + 1}" class="footnote-item"><span class="mark">${f.n}</span>${body}${back}</li>`);
      });
      return parts.length ? `<section class="footnotes tex-notes"><ol>${parts.join('')}</ol></section>` : '';
    }

    tocHTML() {
      const entries = this.headings.filter((h) => h.name !== 'paragraph' && !h.starred && !h.bib);
      if (!entries.length) return '';
      const top = Math.min(...entries.map((h) => h.level));
      const items = entries.map((h) => `<li class="toc-${Math.min(h.level - top, 3)}"><a href="#${h.id}">${h.number ? `<span class="num">${esc(h.number)}</span>` : ''}<span class="text">${esc(h.text)}</span></a></li>`).join('');
      return `<nav class="tex-toc"><h2 class="toc-title">Contents</h2><ol>${items}</ol></nav>`;
    }

    listHTML(type) {
      const entries = this.floats[type];
      if (!entries.length) return '';
      const items = entries.map((f) => `<li><a href="#${f.id}"><span class="num">${esc(f.number || '')}</span><span class="text">${esc(f.text)}</span></a></li>`).join('');
      return `<nav class="tex-toc lof"><h2 class="toc-title">${type === 'figure' ? 'List of Figures' : 'List of Tables'}</h2><ol>${items}</ol></nav>`;
    }

    /** Replaces reference and citation placeholders now that every label and citation is known. */
    resolve(html, bib) {
      return html.replace(/\u0001R(.)([^\u0002]*)\u0002/g, (m, kind, encoded) => {
        const key = decodeURIComponent(encoded);
        const target = this.labels.get(key);
        if (!target) return `<span class="ref missing" title="${esc(key)}">??</span>`;
        let text = esc(target.text || '');
        if (kind === 'e') text = `(${text})`;
        if (kind === 'a' || kind === 'c' || kind === 'C') {
          const words = { section: 'Section', subsection: 'Section', subsubsection: 'Section', chapter: 'Chapter', part: 'Part', figure: 'Figure', subfigure: 'Figure', table: 'Table', equation: kind === 'a' ? 'Equation' : 'Eq.', item: 'Item', algorithm: 'Algorithm', paragraph: 'Paragraph' };
          let word = words[target.type] || (this.theorems.get(target.type) || {}).title || (THEOREM_NAMES[target.type] || '');
          if (kind === 'c' && word) word = word.toLowerCase().replace(/^eq\.$/, 'eq.');
          if (target.type === 'equation' && kind !== 'a') text = `(${esc(target.text)})`;
          text = word ? `${esc(word)}&nbsp;${text}` : text;
        }
        if (kind === 'p') text = esc(target.text || '');
        if (kind === 'n') text = esc(target.title || target.text || '');
        return `<a class="ref" href="#${target.id}">${text}</a>`;
      }).replace(/\u0001C([^\u0002]*)\u0002/g, (m, encoded) => {
        let cite;
        try { cite = JSON.parse(decodeURIComponent(encoded)); } catch (_) { return ''; }
        return this.citationHTML(cite, bib);
      });
    }

    // ---------------------------------------------------------- Bibliography

    buildBibliography() {
      const entries = new Map();
      for (const entry of this.options.bib || []) if (entry && entry.key && !entries.has(entry.key)) entries.set(entry.key, entry);
      const items = this.bibItems;
      let style = this.citationStyle();
      const list = [];
      if (items) {
        // thebibliography: order as written, labels from [..] or numbers.
        items.forEach((item, i) => {
          const natbib = item.label && parseNatbibLabel(item.label);
          list.push({ key: item.key, html: item.html, number: i + 1, label: natbib, raw: item.label });
        });
        if (list.some((i) => i.label)) style = 'authoryear';
        else if (list.some((i) => i.raw)) style = 'alpha';
      } else {
        let keys = this.nociteAll ? Array.from(entries.keys()) : this.cited.filter((k) => entries.has(k));
        if (this.nociteAll) for (const k of this.cited) if (!keys.includes(k) && entries.has(k)) keys.push(k);
        const sorted = !/unsrt|ieee|acm|nature|science|vancouver|apsrev|aip|phys/i.test(this.bibStyle) || style === 'authoryear';
        if (sorted) keys = keys.slice().sort((a, b) => sortKey(entries.get(a)).localeCompare(sortKey(entries.get(b))));
        keys.forEach((key, i) => {
          const entry = entries.get(key);
          const label = authorYear(entry);
          list.push({ key, entry, number: i + 1, label });
        });
        if (style === 'authoryear') disambiguate(list);
      }
      const byKey = new Map(list.map((item) => [item.key, item]));
      const rows = list.map((item) => {
        const id = `bib-${item.number}`;
        item.id = id;
        let body = item.html;
        if (!body && item.entry) body = formatEntry(item.entry, (t) => this.inline(t), style === 'authoryear' ? 'authoryear' : 'numeric', item.label);
        const mark = style === 'authoryear' ? '' : `<span class="bib-label">[${item.raw && style === 'alpha' ? this.inline(item.raw) : item.number}]</span>`;
        return `<li id="${id}" class="${style === 'authoryear' ? 'hanging' : ''}">${mark}<span class="bib-body">${body}</span></li>`;
      }).join('');
      const heading = this.isBook ? 'Bibliography' : 'References';
      let html = '';
      if (rows) {
        const id = this.id('sec');
        this.headings.push({ id, level: 2, number: null, text: heading, name: 'section', bib: true });
        html = `<section class="tex-bib ${style}"><h2 id="${id}" class="tex-section">${heading}</h2><ol>${rows}</ol></section>`;
      }
      return { html, byKey, style };
    }

    citationStyle() {
      const style = this.bibStyle.toLowerCase();
      const natbibNumbers = /numbers/.test(this.natbibOptions || '');
      if (/authoryear|apa|chicago|harvard|nat|apalike|agsm|dcu|kluwer|jmlr|aaai-named|abbrvnat|plainnat|unsrtnat|ecta|aer|jf/.test(style) && !natbibNumbers && !/numeric/.test(style)) {
        if (/unsrtnat|plainnat|abbrvnat/.test(style) && natbibNumbers) return 'numeric';
        return 'authoryear';
      }
      if (/authoryear|apa|chicago|harvard/.test(this.biblatexStyle || '')) return 'authoryear';
      return 'numeric';
    }

    citationHTML(cite, bib) {
      const { name, keys } = cite;
      const authoryear = bib.style === 'authoryear';
      const parts = keys.map((key) => {
        const item = bib.byKey.get(key);
        if (!item) return { missing: true, key };
        return { item, key };
      });
      const link = (item, text) => `<a class="cite" href="#${item.id}">${text}</a>`;
      const missing = (key) => `<span class="cite missing" title="Not in the bibliography">${esc(key)}?</span>`;
      const pre = cite.pre ? cite.pre + ' ' : '';
      const post = cite.post ? ', ' + cite.post : '';
      if (name === 'citeauthor' || name === 'citeauthor*' || name === 'Citeauthor') {
        return parts.map((p) => (p.missing ? missing(p.key) : link(p.item, esc(p.item.label ? p.item.label.author : p.key)))).join(', ');
      }
      if (name === 'citeyear' || name === 'citeyearpar') {
        const years = parts.map((p) => (p.missing ? missing(p.key) : link(p.item, esc(p.item.label ? p.item.label.year + (p.item.label.suffix || '') : String(p.item.number))))).join(', ');
        return name === 'citeyearpar' ? `(${years})` : years;
      }
      if (authoryear) {
        const textual = /^(citet|textcite|Textcite|Citet|cite|citet\*)$/.test(name) && name !== 'cite' || (name === 'cite' && !this.biblatexStyle && this.packages.has('natbib'));
        const bare = /^(citealp|citealt|citealp\*)$/.test(name);
        if (textual) {
          return parts.map((p, i) => {
            if (p.missing) return missing(p.key);
            const l = p.item.label || { author: p.key, year: '' };
            const last = i === parts.length - 1;
            return `${esc(l.author)} ${link(p.item, `(${i === 0 ? pre : ''}${esc(l.year + (l.suffix || ''))}${last ? post : ''})`)}`;
          }).join(', ');
        }
        const inner = parts.map((p) => {
          if (p.missing) return missing(p.key);
          const l = p.item.label || { author: p.key, year: '' };
          return link(p.item, `${esc(l.author)}${name === 'citealt' ? ' ' : ', '}${esc(l.year + (l.suffix || ''))}`);
        }).join('; ');
        return bare ? `${pre}${inner}${post}` : `(${pre}${inner}${post})`;
      }
      // Numeric: [1, 3–5]
      const numbers = parts.map((p) => (p.missing ? { missing: p.key } : { n: p.item.number, item: p.item }));
      numbers.sort((a, b) => (a.n || 1e9) - (b.n || 1e9));
      const pieces = [];
      for (let i = 0; i < numbers.length; i++) {
        const a = numbers[i];
        if (a.missing) { pieces.push(missing(a.missing)); continue; }
        let j = i;
        while (j + 1 < numbers.length && numbers[j + 1].n === numbers[j].n + 1) j++;
        if (j - i >= 2) { pieces.push(`${link(a.item, a.n)}–${link(numbers[j].item, numbers[j].n)}`); i = j; }
        else pieces.push(link(a.item, a.n));
      }
      const inner = pieces.join(', ');
      if (/^(citet|textcite|Textcite)$/.test(name) && parts[0] && parts[0].item && parts[0].item.entry) {
        const l = authorYear(parts[0].item.entry);
        return `${esc(l.author)} [${pre}${inner}${post}]`;
      }
      return `[${pre}${inner}${post}]`;
    }
  }

  // ------------------------------------------------------------------ Handlers

  const H = {};
  const ENV = {};
  Converter.handlers = H;
  Converter.environmentHandlers = ENV;
  Converter.structural = new Set(['section', 'subsection', 'subsubsection', 'chapter', 'part', 'paragraph', 'subparagraph',
    'maketitle', 'caption', 'item', 'label', 'ref', 'eqref', 'cite', 'citep', 'citet', 'footnote', 'includegraphics', 'begin', 'end',
    'emph', 'textbf', 'textit', 'texttt', 'url', 'href', 'frametitle', 'tableofcontents', 'bibliography', 'printbibliography',
    'title', 'author', 'date', 'thanks', 'input', 'include', 'appendix', 'newcommand', 'renewcommand', 'def', 'footnotemark',
    'autoref', 'cref', 'Cref', 'pageref', 'textcolor', 'color', 'verb', 'lstinline', 'multicolumn', 'hline', 'toprule', 'midrule', 'bottomrule']);
  Converter.structuralEnvironments = new Set(['document', 'itemize', 'enumerate', 'description', 'figure', 'table', 'tabular', 'frame', 'abstract', 'thebibliography', 'equation', 'align', 'proof']);

  H.begin = function () { this.beginEnvironment(); };
  H.documentclass = function () {
    const options = this.readOpt();
    this.docClass = this.readArg().trim();
    this.classOptions = (options || '').split(',').map((o) => o.trim());
  };
  H.usepackage = H.RequirePackage = function () {
    const options = this.readOpt();
    const names = this.readArg().split(',').map((n) => n.trim()).filter(Boolean);
    this.readOpt();
    names.forEach((n) => this.packages.add(n));
    if (names.includes('natbib')) this.natbibOptions = options || '';
    if (names.includes('biblatex')) {
      const style = (options || '').match(/(?:^|,)\s*(?:style|citestyle)\s*=\s*([\w-]+)/);
      this.biblatexStyle = style ? style[1] : 'numeric';
      if (!this.bibStyle) this.bibStyle = this.biblatexStyle;
    }
    if (names.includes('parskip')) this.packages.add('parskip');
  };
  H.bibliographystyle = function () { this.bibStyle = this.readArg().trim(); };
  H.newcommand = H.renewcommand = H.DeclareRobustCommand = function (name) { this.defineCommand(name === 'renewcommand' ? 'renew' : 'new'); };
  H.providecommand = function () { this.defineCommand('provide'); };
  H.NewDocumentCommand = H.RenewDocumentCommand = H.DeclareDocumentCommand = H.ProvideDocumentCommand = function () {
    let name = this.readArg().trim();
    const spec = this.readArg();
    const body = this.readArg();
    if (!name.startsWith('\\')) return;
    name = name.slice(1);
    const n = (spec.match(/[mogrsdO]/g) || []).filter((c) => c !== 's').length;
    this.define(name, Math.min(n, 9), body);
  };
  H.def = H.gdef = H.edef = H.xdef = function () { this.defPrimitive(); };
  H.let = H.global = function (name) { if (name === 'let') this.letPrimitive(); };
  H.newenvironment = function () { this.defineEnvironment('new'); };
  H.renewenvironment = function () { this.defineEnvironment('renew'); };
  H.NewDocumentEnvironment = H.RenewDocumentEnvironment = function () {
    const name = this.readArg().trim();
    const spec = this.readArg();
    const begin = this.readArg();
    const end = this.readArg();
    const n = (spec.match(/[mogO]/g) || []).length;
    if (name) this.environments.set(name, { n: Math.min(n, 9), begin, endCode: end });
  };
  H.newtheorem = function () { this.newTheorem(); };
  H.theoremstyle = function () { this.theoremStyle = this.readArg().trim(); };
  H.DeclareMathOperator = function () {
    const star = this.readStar();
    const name = this.readArg().trim();
    const body = this.readArg();
    if (name.startsWith('\\')) this.katexMacros[name] = `\\operatorname${star ? '*' : ''}{${body}}`;
  };
  H.definecolor = function () { this.readOpt(); this.defineColor(); };
  H.numberwithin = function () { const counter = this.readArg().trim(); const within = this.readArg().trim(); this.numberWithin[counter] = within; };
  H.counterwithin = H.numberwithin;
  H.setcounter = function () {
    const counter = this.readArg().trim();
    const value = parseInt(this.readArg(), 10);
    if (counter === 'secnumdepth' && !Number.isNaN(value)) this.secnumdepth = value;
    else if (counter in this.counters && !Number.isNaN(value)) this.counters[counter] = value;
  };
  H.title = function () {
    this.readOpt();
    if (this.isBeamer) this.readOverlay();
    const raw = this.readArg();
    const [clean, notes] = this.extractThanks(raw);
    this.title = clean.replace(/\u0003\d+\u0003/g, '');
    this.titleThanks = notes.map((n) => this.inline(n));
  };
  H.subtitle = function () { this.readOpt(); this.subtitle = this.readArg(); };
  H.author = function () {
    this.readOpt();
    const raw = this.readArg();
    if (this.authors.length && !/acmart|revtex|elsarticle|aa|sig|springer|llncs|svjour|IEEEtran/.test(this.docClass)) this.authors = [];
    this.authors.push(raw);
  };
  H.affiliation = H.address = function () {
    this.readOpt();
    const raw = this.readArg();
    if (this.authors.length) this.authors[this.authors.length - 1] += '\\\\' + raw.replace(/\\\\/g, ', ');
  };
  H.email = function () {
    this.readOpt();
    const raw = this.readArg();
    if (this.authors.length && !this.inPreamble && this.titleMade) { this.out.text(`<span class="tt">${this.inline(raw)}</span>`); return; }
    if (this.authors.length) this.authors[this.authors.length - 1] += `\\\\\\texttt{${raw}}`;
  };
  H.institute = function () { this.readOpt(); this.institute = this.readArg(); };
  H.date = function () { this.readOpt(); const raw = this.readArg(); this.dateSet = true; this.date = raw.trim() ? raw : null; };
  H.keywords = function () { this.keywords = this.readArg(); };
  H.thanks = function () { const raw = this.readArg(); this.out.text(this.thanksMarks([this.inline(raw)])); };
  H.maketitle = function () { this.maketitle(); };
  H.titlepage = H.maketitle;
  H.today = function () { this.out.text(esc(today())); };
  H.appendix = function () {
    this.appendix = true;
    if (this.isBook) this.counters.chapter = 0; else this.counters.section = 0;
  };
  H.tableofcontents = function () { this.out.block('\u0001TOC\u0002'); };
  H.listoffigures = function () { this.out.block('\u0001LOF\u0002'); };
  H.listoftables = function () { this.out.block('\u0001LOT\u0002'); };
  for (const name of Object.keys(SECTION_LEVELS)) H[name] = function () { this.sectioning(name); };
  H.addchap = H.addsec = function (name) { this.s.push(`\\${name === 'addchap' ? 'chapter' : 'section'}*`); };
  H.label = function () { this.label(this.readArg()); };
  H.ref = function () { this.out.text(this.refPlaceholder(this.readArg(), 'r')); };
  H.eqref = function () { this.out.text(this.refPlaceholder(this.readArg(), 'e')); };
  H.autoref = H.Autoref = function () { this.readStar(); this.out.text(this.refPlaceholder(this.readArg(), 'a')); };
  H.cref = H.cpageref = function () { this.readStar(); this.out.text(this.readArg().split(',').map((k) => this.refPlaceholder(k, 'c')).join(', ')); };
  H.Cref = H.Cpageref = function () { this.readStar(); this.out.text(this.readArg().split(',').map((k) => this.refPlaceholder(k, 'a')).join(', ')); };
  H.pageref = function () { this.readStar(); this.out.text(this.refPlaceholder(this.readArg(), 'p')); };
  H.nameref = function () { this.readStar(); this.out.text(this.refPlaceholder(this.readArg(), 'n')); };
  H.hyperref = function () {
    const label = this.readOpt();
    const text = this.inline(this.readArg());
    if (label) this.out.text(`\u0001L${encodeURIComponent(label)}\u0002${text}\u0001/L\u0002`);
    else { this.readArg(); this.readArg(); this.readArg(); this.out.text(text); }
  };
  H.url = function () {
    const raw = this.readArg().trim();
    this.out.text(linkHTML(raw, `<span class="url">${esc(raw)}</span>`));
  };
  H.href = function () {
    const raw = this.readArg().trim();
    const text = this.inline(this.readArg());
    this.out.text(linkHTML(raw.replace(/\\([#%&_~])/g, '$1'), text));
  };
  H.doi = function () { const raw = this.readArg().trim(); this.out.text(linkHTML('https://doi.org/' + raw, `doi:${esc(raw)}`)); };
  H.footnote = H.footnotemark = H.footnotetext = function (name) { this.footnote(name); };
  for (const name of ['cite', 'citep', 'citet', 'citealp', 'citealt', 'citeauthor', 'citeyear', 'citeyearpar', 'Citet', 'Citep', 'Citeauthor',
    'parencite', 'Parencite', 'textcite', 'Textcite', 'autocite', 'Autocite', 'footcite', 'footfullcite', 'nocite', 'supercite', 'citenum', 'smartcite']) {
    H[name] = function () {
      const mapped = { parencite: 'citep', Parencite: 'citep', autocite: 'citep', Autocite: 'citep', smartcite: 'citep', Citet: 'citet', Citep: 'citep', supercite: 'cite', citenum: 'cite' }[name] || name;
      this.cite(mapped);
    };
  }
  H.bibliography = H.printbibliography = function (name) { this.bibliographyCommand(name); };
  H.bibitem = function () { this.readOpt(); this.readArg(); };
  H.newblock = function () { this.out.text(' '); };
  H.bibinfo = function () { this.readArg(); this.out.text(this.inline(this.readArg())); };
  H.bibfield = H.bibinfo;
  H.urlprefix = function () {};
  H.natexlab = function () { this.out.text(this.inline(this.readArg())); };
  H.BIBand = function () { this.out.text('and'); };
  H.includegraphics = function () { this.includeGraphics(); };
  H.includepdf = function () { this.readOpt(); const path = this.readArg(); this.out.block(`<div class="tex-placeholder"><span class="kind">Included PDF</span><span class="detail">${esc(path)}</span></div>`); };
  H.greecemissing = function () {
    const path = this.readArg();
    this.out.block(`<div class="tex-placeholder missing-file"><span class="kind">Missing file</span><span class="detail">${esc(path)}</span></div>`);
  };
  H.caption = H.captionof = function (name) { this.caption(this.s.peek() === '*' ? 'caption*' : name); };
  H.subcaption = function () { this.caption('caption'); };
  H.subfloat = H.subfigure = function () {
    const caption = this.readOpt();
    const content = this.readArg();
    const parent = this.float;
    const letter = parent ? alpha(++parent.sub, false) : '';
    const id = this.id('sub');
    const saved = this.target;
    this.target = { id, text: (parent && parent.number ? parent.number : '') + letter, type: 'subfigure' };
    const inner = this.blockHTML(content);
    const cap = caption !== null ? `<figcaption>(${letter}) ${this.inline(caption)}</figcaption>` : '';
    this.target = saved;
    this.out.text(`<span class="tex-subfloat" id="${id}">${inner}${cap}</span>`);
  };
  H.verb = H.lstinline = H.mintinline = H.Verb = function (name) {
    if (name === 'mintinline') this.readArg();
    this.readStar();
    if (name === 'lstinline') this.readOpt();
    const s = this.s;
    const delimiter = s.next();
    if (!delimiter) return;
    const close = delimiter === '{' ? '}' : delimiter;
    let text = '';
    while (!s.eof() && s.peek() !== close && s.peek() !== '\n' && text.length < 2000) text += s.next();
    if (s.peek() === close) s.next();
    this.out.text(`<code class="tt">${esc(text)}</code>`);
  };
  H.textcolor = function () {
    this.readOpt();
    const color = this.color(this.readArg());
    const text = this.inline(this.readArg());
    this.out.text(color ? `<span class="tc" style="--c:${color}">${text}</span>` : text);
  };
  H.color = function () {
    this.readOpt();
    const color = this.color(this.readArg());
    if (color) this.out.openTag([`<span class="tc" style="--c:${color}">`, '</span>']);
  };
  H.colorbox = H.fcolorbox = function (name) {
    this.readOpt();
    if (name === 'fcolorbox') this.readArg();
    const color = this.color(this.readArg());
    const text = this.inline(this.readArg());
    this.out.text(color ? `<span class="cbox" style="--c:${color}">${text}</span>` : text);
  };
  H.ensuremath = function () { this.emitMath(this.readArg(), false); };
  H['('] = function () { const tex = this.readMath('\\)'); if (tex !== null) this.emitMath(tex, false); };
  H['['] = function () { const tex = this.readMath('\\]'); if (tex !== null) this.emitMath(tex, true); };
  H['\\'] = function () {
    this.readStar();
    this.readOpt();
    if (this.algo) { this.endAlgoLine(); return; }
    this.out.text('<br>');
  };
  H.newline = H.linebreak = function () { this.readOpt(); this.out.text('<br>'); };
  H.par = function () { this.par(); };
  H.noindent = function () { this.out.flush(); this.out.pClass = 'ni'; };
  H.item = function () { this.readOpt(); this.out.text(' • '); };
  H.hline = function () { this.rule('hline'); };
  H.toprule = function () { this.rule('top'); };
  H.midrule = function () { this.rule('mid'); };
  H.bottomrule = function () { this.rule('bottom'); };
  H.cmidrule = function () { this.rule('cmid'); };
  H.cline = function () { this.rule('cline'); };
  H.specialrule = function () { this.rule('specialrule'); };
  H.addlinespace = function () { this.readOpt(); };
  H.morecmidrules = function () {};
  H.multicolumn = function () { this.multicolumn(); };
  H.multirow = function () { this.multirow(); };
  H.makecell = function () { this.readOpt(); this.out.text(this.inline(this.readArg())); };
  H.shortstack = H.makecell;
  H.input = H.include = H.subfile = H.import = H.subimport = function (name) {
    // Swift inlines project files; anything left was unreadable or outside the project.
    if (name === 'import' || name === 'subimport') this.readArg();
    const path = this.readArg();
    if (path.trim()) this.out.block(`<div class="tex-placeholder missing-file"><span class="kind">Not included</span><span class="detail">${esc(path.trim())}</span></div>`);
  };
  H.vskip = H.hskip = H.kern = H.vspace = function (name) {
    if (name === 'vspace') { this.readStar(); this.readArg(); return; }
    this.s.match(/\s*-?[\d.]+\s*(pt|em|ex|cm|mm|in|bp|sp|pc|dd|cc|mu|fill|fil|filll)?(\s*plus\s*-?[\d.]+\s*\w*)?(\s*minus\s*-?[\d.]+\s*\w*)?/y);
  };
  H.bigskip = H.medskip = function () { this.out.flush(); };
  H.textcircled = function () { this.out.text(`<span class="circled">${this.inline(this.readArg())}</span>`); };
  H.SI = H.qty = function () { this.readOpt(); const n = this.readArg(); const u = this.readArg(); this.out.text(`${esc(n.replace(/e(-?\d+)/i, '×10^$1'))}&nbsp;${siunit(u)}`); };
  H.si = H.unit = function () { this.readOpt(); this.out.text(siunit(this.readArg())); };
  H.num = function () { this.readOpt(); this.out.text(esc(this.readArg().replace(/e(-?\d+)/i, '×10^$1'))); };
  H.ang = function () { this.readOpt(); this.out.text(esc(this.readArg()) + '°'); };
  H.frac = function () { const a = this.inline(this.readArg()); const b = this.inline(this.readArg()); this.out.text(`<sup>${a}</sup>⁄<sub>${b}</sub>`); };
  H.footnotesize = function () { this.out.openTag(FONT_DECLARATIONS.footnotesize); };
  H.raisebox = function () { this.readArg(); this.readOpt(); this.readOpt(); this.out.text(this.inline(this.readArg())); };
  H.scalebox = H.resizebox = H.rotatebox = function (name) {
    if (name === 'rotatebox') this.readOpt();
    this.readArg();
    if (name === 'resizebox') this.readArg();
    const inner = this.readArg();
    this.out.text(this.inline(inner));
  };
  H.parbox = function () { this.readOpt(); this.readOpt(); this.readOpt(); this.readArg(); this.out.text(this.inline(this.readArg())); };
  H.marginpar = H.marginnote = H.todo = function (name) {
    if (name === 'todo') this.readOpt();
    const html = this.inline(this.readArg());
    this.out.text(`<span class="tex-margin${name === 'todo' ? ' todo' : ''}">${html}</span>`);
  };
  H.twocolumn = function () { const lead = this.readOpt(); if (lead) this.s.push(lead); };
  H.frametitle = H.framesubtitle = function (name) { this.frametitle(name); };
  H.titlepage = function () { this.maketitle(); };
  H.pause = function () { this.readOpt(); };
  H.only = H.uncover = H.visible = H.invisible = H.onslide = H.alt = H.temporal = H.action = function (name) {
    this.readOverlay();
    if (name === 'onslide') { this.readStar(); this.readOverlay(); return; }
    if (this.s.peek() === '{' || /\s/.test(this.s.peek())) {
      this.skipSpaces(true);
      if (this.s.peek() !== '{') return;
      const content = this.readArg();
      if (name === 'alt') this.readArg();
      if (name === 'temporal') { this.readArg(); this.readArg(); }
      if (name !== 'invisible') this.s.push(content);
    }
  };
  H.alert = function () { this.readOverlay(); this.out.text(`<span class="alert-text">${this.inline(this.readArg())}</span>`); };
  H.insertframetitle = function () { if (this.slide) this.out.text(this.slide.title); };
  H.inserttitle = function () { if (this.title) this.out.text(this.inline(this.title)); };
  H.insertauthor = function () { if (this.authors.length) this.out.text(this.inline(this.authors.join(', '))); };
  H.insertdate = function () { this.out.text(this.date ? this.inline(this.date) : esc(today())); };
  H.framebreak = H.newframe = function () {};
  H.tableofcontents = function () {
    this.readOpt();
    if (this.isBeamer) { this.out.block('<div class="slide-toc">\u0001STOC\u0002</div>'); return; }
    this.out.block('\u0001TOC\u0002');
  };
  H.IEEEPARstart = function () { const a = this.readArg(); const b = this.readArg(); this.out.text(`<span class="dropcap">${this.inline(a)}</span>${this.inline(b)}`); };
  H.lettrine = function () { this.readOpt(); const a = this.readArg(); const b = this.readArg(); this.out.text(`<span class="dropcap">${this.inline(a)}</span><span class="sc">${this.inline(b)}</span>`); };
  H.Sexpr = function () { this.out.text(`<code class="tt sexpr">${esc(this.readArg())}</code>`); };
  H.newgeometry = function () { this.readArg(); };
  H.hfill = function () { this.out.text(' '); };
  H.quad = function () { this.out.text('&emsp;'); };
  H.copyright = function () { this.out.text('©'); };
  H.LaTeX = function () { this.out.text(`<span class="tex-logo">${LOGOS.LaTeX}</span>`); };
  H.and = function () { this.out.text(' and '); };
  H.institution = H.department = function () { this.out.text(this.inline(this.readArg())); };
  H.orcid = H.orcidID = H.ORCID = function () { this.readArg(); };
  H.footnoterule = function () {};
  H.selectlanguage = function () { this.readArg(); };
  H.foreignlanguage = function () { this.readOpt(); this.readArg(); this.out.text(this.inline(this.readArg())); };
  H.texorpdfstring = function () { const a = this.readArg(); this.readArg(); this.s.push(a); };
  H.acro = H.ac = H.acs = H.acl = H.acf = H.gls = H.Gls = H.glspl = function () { this.readStar(); this.readOpt(); this.out.text(esc(this.readArg())); };
  H.blindtext = H.lipsum = function () { this.readOpt(); this.out.text('<span class="tex-dim">Lorem ipsum dolor sit amet, consectetuer adipiscing elit.</span>'); };

  ENV.itemize = ENV.enumerate = ENV.description = ENV.compactitem = ENV.compactenum = ENV.asparaenum = ENV.inparaenum = ENV['enumerate*'] = ENV['itemize*'] = ENV.list = function (name) { this.list(name); };
  ENV.figure = ENV['figure*'] = ENV.table = ENV['table*'] = ENV.wrapfigure = ENV.wraptable = ENV.SCfigure = ENV.sidewaysfigure = ENV.sidewaystable = ENV.algorithm = ENV['algorithm*'] = ENV.marginfigure = ENV.margintable = ENV.listing = function (name) { this.floatEnvironment(name.replace('margin', 'wrap')); };
  ENV.subfigure = ENV.subtable = function (name) { this.subfloatEnvironment(name); };
  ENV.tabular = ENV['tabular*'] = ENV.tabularx = ENV.tabulary = ENV.longtable = ENV['longtable*'] = ENV.supertabular = ENV.xltabular = ENV.tblr = function (name) { this.tabular(name); };
  ENV.array = function (name) { this.tabular(name); };
  ENV.center = ENV.flushleft = ENV.flushright = ENV.centering = function (name) {
    const out = this.contentOf(name);
    const html = out.html();
    if (html) this.out.block(`<div class="tex-${name === 'centering' ? 'center' : name}">${html}</div>`);
  };
  ENV.quote = ENV.quotation = ENV.verse = ENV.displayquote = function (name) {
    const out = this.contentOf(name);
    this.out.block(`<blockquote class="tex-${name}">${out.html()}</blockquote>`);
  };
  ENV.abstract = function (name) { this.abstract(name); };
  ENV.keywords = ENV.IEEEkeywords = function (name) {
    const out = this.contentOf(name);
    this.out.block(`<p class="tex-keywords"><span class="label">${name === 'IEEEkeywords' ? 'Index Terms' : 'Keywords'}</span> ${out.inline()}</p>`);
  };
  ENV.titlepage = function (name) {
    const out = this.contentOf(name);
    this.out.block(`<header class="tex-titlepage">${out.html()}</header>`);
  };
  ENV.minipage = function (name) {
    this.readOpt(); this.readOpt(); this.readOpt();
    const width = widthFraction(this.readArg());
    const out = this.contentOf(name);
    this.out.text(`<span class="tex-minipage"${width ? ` style="width:${(width * 100).toFixed(1)}%"` : ''}>${out.html()}</span>`);
  };
  ENV.multicols = ENV['multicols*'] = function (name) {
    const n = Math.max(1, Math.min(4, parseInt(this.readArg(), 10) || 2));
    this.readOpt();
    const out = this.contentOf(name);
    this.out.block(`<div class="tex-multicols" style="column-count:${n}">${out.html()}</div>`);
  };
  ENV.proof = function (name) { this.proof(name); };
  ENV.thebibliography = function (name) { this.thebibliography(name); };
  ENV.frame = function (name) { this.frame(name); };
  ENV.columns = function (name) { this.columns(name); };
  ENV.column = function (name) { this.column(name); };
  ENV.block = ENV.alertblock = ENV.exampleblock = function (name) { this.beamerBlock(name); };
  ENV.algorithmic = ENV.algorithmic_ = ENV.algorithm2e = ENV.algpseudocode = function (name) { this.algorithmic(name); };
  ENV.tcolorbox = ENV.mdframed = ENV.framed = ENV.shaded = ENV.leftbar = ENV.boxedminipage = function (name) {
    const options = this.readOpt() || '';
    const title = options.match(/title\s*=\s*(\{[^}]*\}|[^,]+)/);
    const out = this.contentOf(name);
    this.out.block(`<div class="tex-box">${title ? `<p class="box-title">${this.inline(title[1].replace(/^\{|\}$/g, ''))}</p>` : ''}${out.html()}</div>`);
  };
  ENV.small = ENV.footnotesize = ENV.scriptsize = ENV.large = ENV.Large = ENV.tiny = ENV.normalsize = ENV.sffamily = ENV.bfseries = ENV.itshape = ENV.landscape = ENV.appendices = ENV.subequations = ENV.singlespace = ENV.doublespace = ENV.spacing = ENV.onehalfspace = ENV.otherlanguage = ENV.CJK = ENV.adjustbox = ENV.samepage = ENV.refsection = ENV.raggedright = ENV.sloppypar = ENV.nolinenumbers = ENV.linenumbers = ENV.acknowledgments = ENV.acknowledgements = ENV.acks = function (name) {
    if (name === 'spacing' || name === 'otherlanguage' || name === 'adjustbox' || name === 'CJK') this.readArg();
    if (name === 'CJK') this.readArg();
    const decl = FONT_DECLARATIONS[name];
    if (/^ack/.test(name)) {
      const id = this.id('sec');
      this.headings.push({ id, level: 2, number: null, text: 'Acknowledgments', name: 'section' });
      this.out.block(`<h2 id="${id}" class="tex-section">Acknowledgments</h2>`);
    }
    const mark = this.out.open.length;
    if (decl) this.out.openTag(decl);
    this.parse({ env: name });
    this.out.closeTo(mark);
  };
  ENV.letter = function (name) { this.readArg(); const out = this.contentOf(name); this.out.block(out.html()); };

  // ------------------------------------------------------------------ Helpers

  const THANKS_SYMBOLS = ['*', '†', '‡', '§', '¶', '‖', '**', '††', '‡‡'];

  function today() {
    const d = new Date();
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return `${months[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
  }

  function alpha(n, upper) {
    if (n <= 0) return String(n);
    let s = '';
    while (n > 0) { n -= 1; s = String.fromCharCode(97 + (n % 26)) + s; n = Math.floor(n / 26); }
    return upper ? s.toUpperCase() : s;
  }

  function roman(n, upper) {
    if (n <= 0 || n > 3999) return String(n);
    const table = [[1000, 'm'], [900, 'cm'], [500, 'd'], [400, 'cd'], [100, 'c'], [90, 'xc'], [50, 'l'], [40, 'xl'], [10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i']];
    let s = '';
    for (const [v, r] of table) while (n >= v) { s += r; n -= v; }
    return upper ? s.toUpperCase() : s;
  }

  function formatEnumLabel(template, n, depth) {
    if (template) {
      const t = template.replace(/\\(arabic|alph|Alph|roman|Roman)\*?/, (m, kind) => '\u0000' + kind + '\u0000');
      if (t.includes('\u0000')) {
        return t.replace(/\u0000(\w+)\u0000/, (m, kind) => ({ arabic: String(n), alph: alpha(n), Alph: alpha(n, true), roman: roman(n), Roman: roman(n, true) }[kind])).replace(/[{}]/g, '').replace(/\\[a-z]+\s*/gi, '');
      }
      // enumerate package: the first 1, a, A, i or I is the counter.
      const m = template.match(/^([^1aAiI]*)([1aAiI])(.*)$/);
      if (m) {
        const value = { 1: String(n), a: alpha(n), A: alpha(n, true), i: roman(n), I: roman(n, true) }[m[2]];
        return (m[1] + value + m[3]).replace(/[{}]/g, '');
      }
      return template;
    }
    switch (depth % 4) {
      case 0: return `${n}.`;
      case 1: return `(${alpha(n)})`;
      case 2: return `${roman(n)}.`;
      default: return `${alpha(n, true)}.`;
    }
  }

  function unwrapSingle(html) {
    const m = html.match(/^<p(?: class="[^"]*")?>([\s\S]*)<\/p>$/);
    return m && !m[1].includes('<p') ? m[1] : html;
  }

  function dedent(text) {
    const lines = text.replace(/\t/g, '    ').split('\n');
    const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
    return Number.isFinite(indent) && indent > 0 ? lines.map((l) => l.slice(indent)).join('\n') : lines.join('\n');
  }

  function splitLines(raw) {
    const lines = [];
    let depth = 0;
    let current = '';
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (c === '\\' && raw[i + 1] === '\\' && depth === 0) {
        lines.push(current);
        current = '';
        i++;
        // skip [len]
        if (raw[i + 1] === '[') { const end = raw.indexOf(']', i + 1); if (end > 0) i = end; }
        continue;
      }
      if (c === '\\') { current += c + (raw[i + 1] || ''); i++; continue; }
      if (c === '{') depth++;
      if (c === '}') depth--;
      current += c;
    }
    lines.push(current);
    return lines;
  }

  /** Splits math rows at top-level \\ (not inside braces or nested environments). */
  function splitRows(body) {
    const rows = [];
    let depth = 0;
    let env = 0;
    let current = '';
    for (let i = 0; i < body.length; i++) {
      const c = body[i];
      if (c === '\\') {
        if (body[i + 1] === '\\' && depth === 0 && env === 0) {
          rows.push(current);
          current = '';
          i++;
          if (body[i + 1] === '*') i++;
          const rest = body.slice(i + 1);
          const skip = rest.match(/^\s*\[[^\]]*\]/);
          if (skip) i += skip[0].length;
          continue;
        }
        if (body.startsWith('\\begin', i)) env++;
        else if (body.startsWith('\\end', i)) env--;
        current += c + (body[i + 1] || '');
        i++;
        continue;
      }
      if (c === '{') depth++;
      else if (c === '}') depth--;
      current += c;
    }
    if (current.trim() || !rows.length) rows.push(current);
    return rows;
  }

  function splitCells(row) {
    const cells = [];
    let depth = 0;
    let current = '';
    for (let i = 0; i < row.length; i++) {
      const c = row[i];
      if (c === '\\') { current += c + (row[i + 1] || ''); i++; continue; }
      if (c === '{') depth++;
      else if (c === '}') depth--;
      if (c === '&' && depth === 0) { cells.push(current); current = ''; continue; }
      current += c;
    }
    cells.push(current);
    return cells;
  }

  function parseColumns(spec) {
    const columns = [];
    let i = 0;
    let pendingLeft = false;
    let pendingAlign = null;
    let guard = 0;
    spec = String(spec);
    // Expand *{n}{cols}.
    for (let k = 0; k < 5 && /\*\s*\{\s*\d+\s*\}/.test(spec); k++) {
      spec = spec.replace(/\*\s*\{\s*(\d+)\s*\}\s*\{((?:[^{}]|\{[^{}]*\})*)\}/, (m, n, cols) => cols.repeat(Math.min(Number(n), 40)));
    }
    const braced = () => {
      while (spec[i] === ' ') i++;
      if (spec[i] !== '{') return '';
      let depth = 0;
      const start = i;
      for (; i < spec.length; i++) {
        if (spec[i] === '{') depth++;
        else if (spec[i] === '}' && --depth === 0) { i++; break; }
      }
      return spec.slice(start + 1, i - 1);
    };
    while (i < spec.length && guard++ < 1000) {
      const c = spec[i++];
      if (c === '|') { if (columns.length) columns[columns.length - 1].right = true; else pendingLeft = true; continue; }
      if ('lcrX'.includes(c) || c === 'S' || c === 'D' || c === 'L' || c === 'C' || c === 'R' || c === 'Y' || c === 'Q') {
        const align = pendingAlign || ({ l: 'l', c: 'c', r: 'r', X: 'l', S: 'r', D: 'r', L: 'l', C: 'c', R: 'r', Y: 'c', Q: 'l' }[c]);
        if (c === 'S' || c === 'D' || c === 'Q') { const opt = spec[i] === '[' ? spec.indexOf(']', i) : -1; if (opt > 0) i = opt + 1; braced(); }
        columns.push({ align, left: pendingLeft });
        pendingLeft = false;
        pendingAlign = null;
        continue;
      }
      if ('pmb'.includes(c)) {
        const width = braced();
        columns.push({ align: pendingAlign || 'l', left: pendingLeft, width: cssLength(width) });
        pendingLeft = false;
        pendingAlign = null;
        continue;
      }
      if (c === '>') {
        const inner = braced();
        if (/\\centering/.test(inner)) pendingAlign = 'c';
        else if (/\\raggedleft/.test(inner)) pendingAlign = 'r';
        else if (/\\raggedright/.test(inner)) pendingAlign = 'l';
        continue;
      }
      if (c === '<' || c === '@' || c === '!') { braced(); continue; }
    }
    return columns;
  }

  function cssLength(text) {
    const m = String(text).match(/^\s*([\d.]+)\s*(cm|mm|in|pt|em|ex|bp)?\s*$/);
    if (!m) {
      const f = widthFraction(text);
      return f ? `${Math.round(f * 600)}px` : null;
    }
    const factor = { cm: 37.8, mm: 3.78, in: 96, pt: 1.33, bp: 1.33, em: 16, ex: 8 }[m[2] || 'pt'];
    return `${Math.min(900, Math.round(Number(m[1]) * factor))}px`;
  }

  function widthFraction(text) {
    const m = String(text).match(/^\s*([\d.]*)\s*\\(linewidth|textwidth|columnwidth|hsize|paperwidth|textheight)/);
    if (m) return Math.max(0.05, Math.min(1, m[1] === '' ? 1 : Number(m[1]) || 1));
    return null;
  }

  function sizeStyle(options, figure) {
    const opts = {};
    String(options).split(',').forEach((part) => {
      const [k, v] = part.split('=').map((x) => (x || '').trim());
      if (k) opts[k] = v === undefined ? true : v;
    });
    const styles = [];
    const natural = figure && figure.width ? figure.width : null;   // points
    if (opts.width) {
      const fraction = widthFraction(opts.width);
      if (fraction) styles.push(`width:${(fraction * 100).toFixed(1)}%`);
      else { const css = cssLength(opts.width); if (css) styles.push(`width:min(100%, ${css})`); }
    } else if (opts.height) {
      const css = cssLength(opts.height);
      if (css) styles.push(`height:${css}`, 'width:auto');
    } else if (opts.scale && natural) {
      const px = Math.round(natural * 1.333 * Math.max(0.05, Math.min(4, Number(opts.scale) || 1)));
      styles.push(`width:min(100%, ${px}px)`);
    } else if (natural) {
      styles.push(`width:min(100%, ${Math.round(natural * 1.333)}px)`);
    }
    if (opts.angle && Number(opts.angle)) styles.push(`transform:rotate(${-Number(opts.angle)}deg)`);
    return styles.join(';');
  }

  function linkHTML(url, text) {
    const clean = String(url).trim();
    if (/^(https?:|mailto:)/i.test(clean)) return `<a href="${esc(clean)}">${text}</a>`;
    if (/^www\./i.test(clean)) return `<a href="https://${esc(clean)}">${text}</a>`;
    if (clean.startsWith('#')) return `<a href="${esc(clean)}">${text}</a>`;
    return text;
  }

  function siunit(raw) {
    const units = { meter: 'm', metre: 'm', second: 's', kilogram: 'kg', gram: 'g', ampere: 'A', kelvin: 'K', mole: 'mol', candela: 'cd', hertz: 'Hz', newton: 'N', pascal: 'Pa', joule: 'J', watt: 'W', volt: 'V', ohm: 'Ω', celsius: '°C', degreeCelsius: '°C', percent: '%', byte: 'B', bit: 'bit', liter: 'L', litre: 'L', hour: 'h', minute: 'min', day: 'd', electronvolt: 'eV' };
    const prefixes = { kilo: 'k', mega: 'M', giga: 'G', tera: 'T', milli: 'm', micro: 'µ', nano: 'n', pico: 'p', centi: 'c', deci: 'd' };
    let text = String(raw);
    text = text.replace(/\\per\s*\\(\w+)/g, (m, u) => `/\\${u}`);
    text = text.replace(/\\(squared|cubed)/g, (m, p) => (p === 'squared' ? '²' : '³'));
    text = text.replace(/\\(\w+)/g, (m, w) => prefixes[w] || units[w] || w);
    return esc(text.replace(/\s*\.\s*/g, '·').replace(/~/g, ' ').replace(/[{}]/g, ''));
  }

  // ------------------------------------------------------------------ BibTeX

  /** Splits "Last, First and First Last and others" into names. */
  function parseNames(raw) {
    if (!raw) return [];
    const parts = [];
    let depth = 0;
    let current = '';
    const text = String(raw).replace(/\s+/g, ' ').trim();
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (c === '{') depth++;
      else if (c === '}') depth--;
      if (depth === 0 && /^\s+and\s+/i.test(text.slice(i)) && /\s/.test(c)) {
        const m = text.slice(i).match(/^\s+and\s+/i);
        parts.push(current);
        current = '';
        i += m[0].length - 1;
        continue;
      }
      current += c;
    }
    if (current.trim()) parts.push(current);
    return parts.map((p) => p.trim()).filter(Boolean).slice(0, 200).map((name) => {
      if (/^others$/i.test(name)) return { others: true };
      const commas = splitTop(name, ',');
      let first = '';
      let last = '';
      let von = '';
      let jr = '';
      if (commas.length >= 2) {
        last = commas[0];
        if (commas.length >= 3) { jr = commas[1]; first = commas[2]; } else first = commas[1];
        const words = splitTop(last, ' ');
        const lastLower = words.findIndex((w, i) => i < words.length - 1 && /^[a-z]/.test(w));
        if (lastLower >= 0) { let k = lastLower; while (k < words.length - 1 && /^[a-z]/.test(words[k])) k++; von = words.slice(0, k).join(' '); last = words.slice(k).join(' '); }
      } else {
        const words = splitTop(name, ' ');
        if (words.length === 1) last = words[0];
        else {
          let vonStart = words.findIndex((w, i) => i > 0 && i < words.length - 1 && /^[a-z]/.test(w));
          if (vonStart < 0) { last = words[words.length - 1]; first = words.slice(0, -1).join(' '); }
          else {
            let vonEnd = vonStart;
            while (vonEnd < words.length - 1 && /^[a-z]/.test(words[vonEnd])) vonEnd++;
            first = words.slice(0, vonStart).join(' ');
            von = words.slice(vonStart, vonEnd).join(' ');
            last = words.slice(vonEnd).join(' ');
          }
        }
      }
      return { first: first.trim(), last: last.trim(), von: von.trim(), jr: jr.trim() };
    });
  }

  function splitTop(text, separator) {
    const out = [];
    let depth = 0;
    let current = '';
    for (const c of text) {
      if (c === '{') depth++;
      else if (c === '}') depth--;
      if (c === separator && depth === 0) { if (current.trim() || separator === ',') out.push(current.trim()); current = ''; continue; }
      current += c;
    }
    if (current.trim() || separator === ',') out.push(current.trim());
    return out;
  }

  function stripTeX(text) {
    return String(text || '').replace(/\\[`'^"~=.uvHckrdbt]\s*\{?\s*(\\?[a-zA-Z])\s*\}?/g, (m, base) => {
      const accent = m.match(/^\\(.)/)[1];
      const b = base.replace(/^\\/, '');
      return (b === 'i' ? 'i' : b) + (ACCENTS[accent] || '');
    }).replace(/\\(ss|ae|AE|oe|OE|aa|AA|o|O|l|L)\b\s*/g, (m, k) => SYMBOLS[k]).replace(/\\[a-zA-Z]+\s*/g, '').replace(/[{}]/g, '').replace(/~/g, ' ').normalize('NFC').trim();
  }

  function initials(first) {
    return splitTop(first, ' ').map((w) => w.split('-').map((part) => {
      const clean = stripTeX(part);
      return clean ? clean[0] + '.' : '';
    }).join('-')).filter(Boolean).join(' ');
  }

  function authorYear(entry) {
    if (!entry) return { author: '?', year: '' };
    const f = entry.fields || {};
    const names = parseNames(f.author || f.editor || '');
    const lastOf = (n) => stripTeX([n.von, n.last].filter(Boolean).join(' '));
    let author;
    const real = names.filter((n) => !n.others);
    if (!real.length) author = stripTeX(f.organization || f.institution || f.publisher || f.key || entry.key);
    else if (real.length === 1 && !names.some((n) => n.others)) author = lastOf(real[0]);
    else if (real.length === 2 && !names.some((n) => n.others)) author = `${lastOf(real[0])} and ${lastOf(real[1])}`;
    else author = `${lastOf(real[0])} et al.`;
    const year = stripTeX(f.year || (f.date || '').slice(0, 4) || 'n.d.');
    return { author, year, suffix: '' };
  }

  function sortKey(entry) {
    if (!entry) return '';
    const f = entry.fields || {};
    const names = parseNames(f.author || f.editor || '');
    const first = names.find((n) => !n.others);
    return `${first ? stripTeX(first.last + ' ' + first.first) : stripTeX(f.title || entry.key)} ${f.year || ''} ${stripTeX(f.title || '')}`.toLowerCase();
  }

  function disambiguate(list) {
    const groups = new Map();
    for (const item of list) {
      if (!item.label) continue;
      const key = item.label.author + '|' + item.label.year;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }
    for (const items of groups.values()) if (items.length > 1) items.forEach((item, i) => { item.label = Object.assign({}, item.label, { suffix: alpha(i + 1) }); });
  }

  function parseNatbibLabel(label) {
    // natbib .bbl: {Smith et~al.(2020)Smith, Jones, and Lee}
    const clean = label.replace(/^\{|\}$/g, '');
    const m = clean.match(/^(.*?)\((\d{4}[a-z]?|n\.d\.|in press|[^)]{1,12})\)/);
    if (!m) return null;
    return { author: stripTeX(m[1]).trim(), year: stripTeX(m[2]), suffix: '' };
  }

  const ENTRY_TYPES = {
    article: 'Article', book: 'Book', booklet: 'Booklet', inbook: 'Chapter', incollection: 'In Collection', inproceedings: 'Conference Paper',
    conference: 'Conference Paper', manual: 'Manual', mastersthesis: 'Master’s Thesis', misc: 'Misc', phdthesis: 'PhD Thesis',
    proceedings: 'Proceedings', techreport: 'Report', unpublished: 'Unpublished', online: 'Online', electronic: 'Online', www: 'Online',
    thesis: 'Thesis', report: 'Report', software: 'Software', dataset: 'Dataset', patent: 'Patent', collection: 'Collection',
    mvbook: 'Book', periodical: 'Periodical', standard: 'Standard', video: 'Video', audio: 'Audio', artwork: 'Artwork', preprint: 'Preprint',
  };

  /** One reference, formatted. `inline` renders a field's LaTeX to HTML. */
  function formatEntry(entry, inline, style, label) {
    const f = entry.fields || {};
    const type = String(entry.type || 'misc').toLowerCase();
    const field = (name) => (f[name] ? inline(f[name]) : '');
    const names = (raw) => {
      const list = parseNames(raw);
      const shown = list.slice(0, 12);
      const parts = shown.map((n, i) => {
        if (n.others) return 'et al.';
        const last = inline([n.von, n.last].filter(Boolean).join(' ') + (n.jr ? ', ' + n.jr : ''));
        const first = n.first ? esc(initials(n.first)) : '';
        if (style === 'authoryear') return i === 0 ? `${last}${first ? ', ' + first : ''}` : `${first ? first + ' ' : ''}${last}`;
        return `${first ? first + ' ' : ''}${last}`;
      });
      if (list.length > 12) parts.push('et al.');
      if (parts.length <= 1) return parts.join('');
      if (parts[parts.length - 1] === 'et al.') return parts.slice(0, -1).join(', ') + ' et al.';
      return parts.slice(0, -1).join(', ') + (parts.length > 2 ? ',' : '') + ' and ' + parts[parts.length - 1];
    };
    const authors = f.author ? names(f.author) : f.editor ? names(f.editor) + (parseNames(f.editor).length > 1 ? ', editors' : ', editor') : '';
    const year = field('year') || (f.date ? esc(String(f.date).slice(0, 4)) : '');
    const title = field('title');
    const container = field('journal') || field('journaltitle') || field('booktitle') || field('series') || field('howpublished') || field('publisher') && type === 'misc' && '';
    const bits = [];
    const volume = field('volume');
    const number = field('number') || field('issue');
    const pages = f.pages ? esc(stripTeX(f.pages).replace(/-+/g, '–')) : '';
    const publisher = field('publisher') || field('organization') || field('institution') || field('school');
    const address = field('address') || field('location');
    const edition = field('edition');
    const suffix = label && label.suffix ? label.suffix : '';
    const quoteTitle = /^(article|inproceedings|incollection|inbook|conference|misc|online|unpublished|phdthesis|mastersthesis|techreport|thesis|report|preprint)$/.test(type);
    const titleHTML = title ? (quoteTitle ? `<span class="bib-title">${title}</span>` : `<i class="bib-title">${title}</i>`) : '';

    if (style === 'authoryear') {
      if (authors) bits.push(`<span class="bib-authors">${authors}</span> (${year}${suffix}).`);
      else if (year) bits.push(`(${year}${suffix}).`);
      if (titleHTML) bits.push(titleHTML + '.');
    } else {
      if (authors) bits.push(`<span class="bib-authors">${authors}</span>.`);
      if (titleHTML) bits.push(titleHTML + '.');
    }
    const where = [];
    if (type === 'article') {
      if (container) where.push(`<i>${container}</i>`);
      if (volume) where.push(number ? `${volume}(${number})` : volume);
      if (pages) where.push(pages);
    } else if (/^(inproceedings|conference|incollection|inbook)$/.test(type)) {
      if (container) where.push(`In <i>${container}</i>`);
      if (volume) where.push(`volume ${volume}`);
      if (pages) where.push(`pages ${pages}`);
      if (publisher) where.push(publisher);
      if (address) where.push(address);
    } else if (/thesis/.test(type)) {
      where.push(type === 'phdthesis' ? 'PhD thesis' : type === 'mastersthesis' ? 'Master’s thesis' : field('type') || 'Thesis');
      if (publisher) where.push(publisher);
    } else if (/^(techreport|report)$/.test(type)) {
      where.push(`${field('type') || 'Technical Report'}${number ? ' ' + number : ''}`);
      if (publisher) where.push(publisher);
    } else if (/^(book|mvbook|booklet|manual|proceedings|collection)$/.test(type)) {
      if (edition) where.push(`${edition} edition`);
      if (publisher) where.push(publisher);
      if (address) where.push(address);
    } else {
      const how = field('howpublished') || container;
      if (how) where.push(how);
      if (publisher && !how) where.push(publisher);
    }
    if (f.eprint) {
      const prefix = String(f.archiveprefix || f.eprinttype || '').toLowerCase();
      if (prefix === 'arxiv' || /^\d{4}\.\d{4,5}/.test(f.eprint)) where.push(`<a href="https://arxiv.org/abs/${esc(stripTeX(f.eprint))}">arXiv:${esc(stripTeX(f.eprint))}</a>`);
    }
    if (style !== 'authoryear' && year) where.push(year + suffix);
    if (where.length) bits.push(where.join(', ') + '.');
    if (f.note) bits.push(field('note') + (/[.!?]$/.test(plain(field('note'))) ? '' : '.'));
    const links = [];
    if (f.doi) {
      const doi = stripTeX(f.doi).replace(/^https?:\/\/(dx\.)?doi\.org\//i, '');
      links.push(`<a class="bib-link" href="https://doi.org/${esc(encodeURI(doi))}">doi:${esc(doi)}</a>`);
    }
    const url = f.url ? stripTeX(f.url).replace(/\s/g, '') : '';
    if (url && /^https?:\/\//i.test(url) && !(f.doi && /doi\.org/.test(url))) links.push(`<a class="bib-link" href="${esc(url)}">${esc(url.replace(/^https?:\/\//, '').replace(/\/$/, ''))}</a>`);
    if (links.length) bits.push(links.join(' '));
    return bits.join(' ');
  }

  // ------------------------------------------------------------------ API

  function convert(source, options) {
    const converter = new Converter(String(source || '').replace(/\r\n?/g, '\n'), options || {});
    // `\item` and friends return 'item'; record which stop ended each nested parse.
    const parse = converter.parse;
    converter.parse = function (stop) {
      const reason = parse.call(this, stop);
      this.lastStop = reason;
      return reason;
    };
    try {
      converter.parse({});
    } catch (e) {
      if (e instanceof Stop) converter.stopped = e.message;
      else { converter.stopped = 'error'; converter.error = String(e && e.stack || e); }
    }
    let result;
    try {
      // Finishing gets a fresh time budget for bibliography and references.
      converter.started = Date.now();
      result = converter.finish();
    } catch (e) {
      result = { kind: 'article', html: converter.out.html(), slides: [], headings: converter.headings, math: converter.math, katexMacros: converter.katexMacros, labels: {}, title: '', stopped: 'error' };
    }
    if (converter.error) result.error = converter.error;
    return result;
  }

  /** A field or short text as HTML, with math rendered by `options.katex`. */
  function inlineHTML(text, options) {
    const converter = new Converter('', options || {});
    let html;
    try { html = converter.inline(String(text || '')); } catch (_) { html = esc(text); }
    return html.replace(/<span class="m" data-i="(\d+)"><\/span>/g, (m, i) => {
      const item = converter.math[Number(i)];
      return item && options && options.katex ? options.katex(item.tex, item.display, converter.katexMacros) : esc(item ? item.tex : '');
    });
  }

  global.GreeceLaTeX = { convert, inlineHTML, parseNames, formatEntry, authorYear, stripTeX, ENTRY_TYPES, esc, plain };
})(typeof window !== 'undefined' ? window : globalThis);
