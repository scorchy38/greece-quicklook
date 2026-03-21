import Foundation

/// Maps file extensions and shebangs to highlight.js language identifiers.
/// Covers 190+ programming and markup languages.
struct LanguageDetector {

    // MARK: - Extension → Language mapping

    /// Returns the highlight.js language identifier for a file extension, or nil if unknown.
    static func language(forExtension ext: String) -> String? {
        return extensionMap[ext.lowercased()]
    }

    /// Detect language from file content (shebang lines, etc.)
    static func language(fromContent content: String) -> String? {
        let firstLine = String(content.prefix(256)).components(separatedBy: .newlines).first ?? ""

        // Shebang detection
        if firstLine.hasPrefix("#!") {
            let shebang = firstLine.lowercased()
            if shebang.contains("python") { return "python" }
            if shebang.contains("ruby") { return "ruby" }
            if shebang.contains("perl") { return "perl" }
            if shebang.contains("node") { return "javascript" }
            if shebang.contains("bash") || shebang.contains("/sh") { return "bash" }
            if shebang.contains("zsh") { return "zsh" }
            if shebang.contains("fish") { return "fish" }
            if shebang.contains("php") { return "php" }
            if shebang.contains("lua") { return "lua" }
            if shebang.contains("elixir") { return "elixir" }
            if shebang.contains("awk") { return "awk" }
            if shebang.contains("sed") { return "sed" }
            if shebang.contains("tcl") { return "tcl" }
            if shebang.contains("expect") { return "tcl" }
            if shebang.contains("osascript") { return "applescript" }
            return "bash" // Default for shebangs
        }

        // XML declaration
        if firstLine.hasPrefix("<?xml") { return "xml" }

        // HTML doctype
        if firstLine.lowercased().hasPrefix("<!doctype html") { return "html" }

        return nil
    }

    /// Combined detection: try extension first, then content.
    static func detect(url: URL, content: String? = nil) -> String {
        let ext = url.pathExtension.lowercased()

        // Try extension map first
        if let lang = language(forExtension: ext) {
            return lang
        }

        // Try filename-based detection
        let filename = url.lastPathComponent.lowercased()
        if let lang = filenameMap[filename] {
            return lang
        }

        // Try content-based detection
        if let content = content, let lang = language(fromContent: content) {
            return lang
        }

        return "plaintext"
    }

    // MARK: - Display name

    static func displayName(forLanguage lang: String) -> String {
        return displayNames[lang] ?? lang.capitalized
    }

    // MARK: - Filename-based mapping (extensionless files)

    private static let filenameMap: [String: String] = [
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "dockerfile": "dockerfile",
        "containerfile": "dockerfile",
        "vagrantfile": "ruby",
        "gemfile": "ruby",
        "rakefile": "ruby",
        "guardfile": "ruby",
        "podfile": "ruby",
        "fastfile": "ruby",
        "appfile": "ruby",
        "matchfile": "ruby",
        "brewfile": "ruby",
        "cmakelists.txt": "cmake",
        "cakefile": "coffeescript",
        "gruntfile.js": "javascript",
        "gulpfile.js": "javascript",
        "procfile": "yaml",
        "justfile": "makefile",
        ".gitignore": "gitignore",
        ".gitattributes": "gitattributes",
        ".gitmodules": "ini",
        ".editorconfig": "ini",
        ".env": "bash",
        ".env.local": "bash",
        ".env.development": "bash",
        ".env.production": "bash",
        ".bashrc": "bash",
        ".bash_profile": "bash",
        ".zshrc": "zsh",
        ".zshenv": "zsh",
        ".zprofile": "zsh",
        ".profile": "bash",
        ".vimrc": "vim",
        ".npmrc": "ini",
        ".yarnrc": "yaml",
        ".htaccess": "apache",
        ".dockerignore": "dockerfile",
        "robots.txt": "plaintext",
        "license": "plaintext",
        "changelog": "markdown",
        "authors": "plaintext",
        "todo": "plaintext",
    ]

    // MARK: - 190+ Extension Map

    private static let extensionMap: [String: String] = [
        // A
        "abap": "abap",
        "ada": "ada",
        "adb": "ada",
        "ads": "ada",
        "adoc": "asciidoc",
        "ahk": "autohotkey",
        "ahkl": "autohotkey",
        "aidl": "java",
        "als": "alloy",
        "applescript": "applescript",
        "scpt": "applescript",
        "arc": "lisp",
        "as": "actionscript",
        "asm": "x86asm",
        "asp": "asp",
        "aspx": "asp",
        "awk": "awk",

        // B
        "bas": "basic",
        "bat": "dos",
        "bb": "clojure",
        "bf": "brainfuck",
        "bib": "bibtex",
        "blade.php": "blade",
        "bqn": "bqn",
        "bsl": "1c",
        "bzl": "python",

        // C
        "c": "c",
        "cats": "c",
        "cbl": "cobol",
        "cob": "cobol",
        "cc": "cpp",
        "cfc": "cfscript",
        "cfm": "cfscript",
        "cfg": "ini",
        "cjs": "javascript",
        "cl": "lisp",
        "clj": "clojure",
        "cljc": "clojure",
        "cljs": "clojurescript",
        "cls": "latex",
        "cmake": "cmake",
        "cmd": "dos",
        "cob": "cobol",
        "coffee": "coffeescript",
        "conf": "nginx",
        "cpp": "cpp",
        "cr": "crystal",
        "cs": "csharp",
        "csh": "tcsh",
        "cshtml": "cshtml-razor",
        "cson": "coffeescript",
        "css": "css",
        "csv": "csv",
        "cu": "cuda",
        "cue": "cue",
        "cxx": "cpp",

        // D
        "d": "d",
        "dart": "dart",
        "dfy": "dafny",
        "dhall": "dhall",
        "di": "d",
        "diff": "diff",
        "djt": "django",
        "dml": "sql",
        "do": "stata",
        "dockerfile": "dockerfile",
        "dot": "graphviz",
        "dtd": "xml",
        "dts": "dts",

        // E
        "e": "eiffel",
        "eex": "elixir",
        "el": "lisp",
        "elm": "elm",
        "emacs": "lisp",
        "epp": "puppet",
        "erb": "erb",
        "erl": "erlang",
        "ex": "elixir",
        "exs": "elixir",

        // F
        "f": "fortran",
        "f03": "fortran",
        "f08": "fortran",
        "f77": "fortran",
        "f90": "fortran",
        "f95": "fortran",
        "factor": "factor",
        "feature": "gherkin",
        "fish": "fish",
        "fnl": "fennel",
        "for": "fortran",
        "forth": "forth",
        "fpp": "fortran",
        "fs": "fsharp",
        "fsi": "fsharp",
        "fsx": "fsharp",
        "ftl": "ftl",
        "fth": "forth",

        // G
        "g4": "antlr4",
        "gd": "gdscript",
        "gemspec": "ruby",
        "gleam": "gleam",
        "glsl": "glsl",
        "gml": "xml",
        "gn": "gn",
        "gni": "gn",
        "go": "go",
        "gql": "graphql",
        "gradle": "gradle",
        "graphql": "graphql",
        "groovy": "groovy",
        "gv": "graphviz",
        "gyp": "python",

        // H
        "h": "c",
        "h++": "cpp",
        "haml": "haml",
        "hbs": "handlebars",
        "hcl": "hcl",
        "heex": "elixir",
        "hh": "cpp",
        "hlsl": "hlsl",
        "hocon": "hocon",
        "hpp": "cpp",
        "hrl": "erlang",
        "hs": "haskell",
        "htm": "html",
        "html": "html",
        "http": "http",
        "hx": "haxe",
        "hxx": "cpp",
        "hy": "hy",

        // I
        "ics": "plaintext",
        "idr": "idris",
        "ijs": "j",
        "ino": "arduino",
        "ini": "ini",
        "ipp": "cpp",
        "ipynb": "json",
        "iss": "innosetup",

        // J
        "j2": "jinja2",
        "java": "java",
        "jinja": "jinja2",
        "jinja2": "jinja2",
        "jl": "julia",
        "js": "javascript",
        "json": "json",
        "json5": "json5",
        "jsonc": "jsonc",
        "jsonl": "json",
        "jsonnet": "jsonnet",
        "jsx": "jsx",
        "just": "makefile",

        // K
        "kak": "kakoune",
        "kicad_pcb": "plaintext",
        "ksh": "bash",
        "kt": "kotlin",
        "kts": "kotlin",

        // L
        "l": "lex",
        "lasso": "lasso",
        "latte": "latte",
        "lean": "lean",
        "less": "less",
        "lex": "lex",
        "lhs": "haskell",
        "lidr": "idris",
        "lisp": "lisp",
        "lkml": "lookml",
        "ll": "llvm",
        "log": "accesslog",
        "lsp": "lisp",
        "lua": "lua",

        // M
        "m": "objectivec",
        "m4": "m4",
        "mak": "makefile",
        "markdown": "markdown",
        "matlab": "matlab",
        "md": "markdown",
        "meson": "meson",
        "mips": "mips",
        "mjs": "javascript",
        "mk": "makefile",
        "ml": "ocaml",
        "mli": "ocaml",
        "mm": "objectivec",
        "mo": "motoko",
        "mojom": "mojom",
        "moon": "moonscript",
        "move": "move",
        "mpl": "maple",
        "mq4": "mql4",
        "mq5": "mql5",
        "mql": "mql4",
        "mql4": "mql4",
        "mql5": "mql5",
        "mts": "typescript",

        // N
        "nasm": "x86asm",
        "nb": "mathematica",
        "ncl": "ncl",
        "ne": "never",
        "nginx": "nginx",
        "nim": "nim",
        "nimble": "nim",
        "nix": "nix",
        "nsi": "nsis",
        "nsh": "nsis",
        "nu": "nushell",

        // O
        "objc": "objectivec",
        "ocaml": "ocaml",
        "odin": "odin",
        "opam": "ocaml",
        "org": "plaintext",
        "os": "openscad",
        "oxygene": "oxygene",

        // P
        "p": "parser3",
        "p4": "p4",
        "p6": "raku",
        "pas": "delphi",
        "patch": "diff",
        "pb": "protobuf",
        "pbt": "protobuf",
        "pde": "processing",
        "perl": "perl",
        "pgsql": "pgsql",
        "php": "php",
        "php3": "php",
        "php4": "php",
        "php5": "php",
        "php7": "php",
        "phps": "php",
        "phtml": "php",
        "pig": "pig",
        "pk": "pike",
        "pkl": "pkl",
        "pl": "perl",
        "plist": "xml",
        "plsql": "sql",
        "pm": "perl",
        "po": "gettext",
        "pony": "pony",
        "postcss": "css",
        "pp": "puppet",
        "pq": "powerquery",
        "prisma": "prisma",
        "pro": "prolog",
        "properties": "properties",
        "proto": "protobuf",
        "ps": "powershell",
        "ps1": "powershell",
        "psm1": "powershell",
        "pug": "pug",
        "puppet": "puppet",
        "py": "python",
        "pyi": "python",
        "pyw": "python",
        "pyx": "python",

        // Q
        "q": "q",
        "qml": "qml",
        "qs": "qsharp",

        // R
        "r": "r",
        "raku": "raku",
        "rb": "ruby",
        "rbw": "ruby",
        "re": "reasonml",
        "regex": "regex",
        "rei": "reasonml",
        "res": "rescript",
        "resi": "rescript",
        "rkt": "racket",
        "rmd": "markdown",
        "robot": "robot",
        "ron": "ron",
        "rpy": "python",
        "rs": "rust",
        "rss": "xml",
        "rst": "plaintext",
        "ru": "ruby",

        // S
        "s": "x86asm",
        "sas": "sas",
        "sass": "sass",
        "sbt": "scala",
        "sc": "scala",
        "scala": "scala",
        "scm": "scheme",
        "scss": "scss",
        "sh": "bash",
        "shader": "glsl",
        "slim": "slim",
        "sls": "salt",
        "sml": "sml",
        "smali": "smali",
        "snap": "plaintext",
        "sol": "solidity",
        "sparql": "sparql",
        "spl": "spl",
        "sql": "sql",
        "ss": "scheme",
        "st": "smalltalk",
        "stl": "plaintext",
        "sty": "latex",
        "styl": "stylus",
        "svelte": "svelte",
        "svg": "xml",
        "swift": "swift",

        // T
        "t": "perl",
        "tcc": "cpp",
        "tcl": "tcl",
        "tcsh": "tcsh",
        "tex": "latex",
        "tf": "terraform",
        "tfvars": "terraform",
        "thrift": "thrift",
        "tk": "tcl",
        "tla": "tla",
        "toml": "toml",
        "tpp": "cpp",
        "ts": "typescript",
        "tsv": "csv",
        "tsx": "tsx",
        "tt": "plaintext",
        "twig": "twig",
        "typ": "typst",
        "txt": "plaintext",

        // U
        "uc": "unrealscript",

        // V
        "v": "verilog",
        "vala": "vala",
        "vb": "vbnet",
        "vbs": "vbscript",
        "vcl": "vcl",
        "vhdl": "vhdl",
        "vhd": "vhdl",
        "vim": "vim",
        "vue": "vue",

        // W
        "wasm": "wasm",
        "wgsl": "wgsl",
        "wl": "mathematica",
        "wls": "mathematica",
        "wren": "wren",
        "wxi": "xml",
        "wxs": "xml",

        // X
        "x": "lex",
        "xhtml": "html",
        "xls": "excel",
        "xml": "xml",
        "xq": "xquery",
        "xquery": "xquery",
        "xsd": "xml",
        "xsl": "xml",
        "xslt": "xml",

        // Y
        "y": "yacc",
        "yaml": "yaml",
        "yml": "yaml",

        // Z
        "zap": "zap",
        "zig": "zig",
        "zsh": "zsh",
    ]

    // MARK: - Display Names

    private static let displayNames: [String: String] = [
        "abap": "ABAP",
        "actionscript": "ActionScript",
        "ada": "Ada",
        "apache": "Apache",
        "applescript": "AppleScript",
        "arduino": "Arduino",
        "asciidoc": "AsciiDoc",
        "autohotkey": "AutoHotKey",
        "awk": "AWK",
        "bash": "Bash",
        "basic": "BASIC",
        "brainfuck": "Brainfuck",
        "c": "C",
        "clojure": "Clojure",
        "clojurescript": "ClojureScript",
        "cmake": "CMake",
        "cobol": "COBOL",
        "coffeescript": "CoffeeScript",
        "cpp": "C++",
        "crystal": "Crystal",
        "csharp": "C#",
        "css": "CSS",
        "cuda": "CUDA",
        "d": "D",
        "dart": "Dart",
        "delphi": "Delphi",
        "diff": "Diff",
        "dockerfile": "Dockerfile",
        "dos": "DOS Batch",
        "eiffel": "Eiffel",
        "elixir": "Elixir",
        "elm": "Elm",
        "erlang": "Erlang",
        "factor": "Factor",
        "fennel": "Fennel",
        "fish": "Fish",
        "forth": "Forth",
        "fortran": "Fortran",
        "fsharp": "F#",
        "gdscript": "GDScript",
        "gherkin": "Gherkin",
        "gleam": "Gleam",
        "glsl": "GLSL",
        "go": "Go",
        "gradle": "Gradle",
        "graphql": "GraphQL",
        "graphviz": "Graphviz/DOT",
        "groovy": "Groovy",
        "haml": "HAML",
        "handlebars": "Handlebars",
        "haskell": "Haskell",
        "haxe": "Haxe",
        "hcl": "HCL",
        "hlsl": "HLSL",
        "html": "HTML",
        "http": "HTTP",
        "idris": "Idris",
        "ini": "INI",
        "java": "Java",
        "javascript": "JavaScript",
        "jinja2": "Jinja2",
        "json": "JSON",
        "json5": "JSON5",
        "jsonc": "JSONC",
        "jsonnet": "Jsonnet",
        "jsx": "JSX",
        "julia": "Julia",
        "kakoune": "Kakoune",
        "kotlin": "Kotlin",
        "latex": "LaTeX",
        "lean": "Lean",
        "less": "Less",
        "lisp": "Lisp",
        "llvm": "LLVM IR",
        "lua": "Lua",
        "makefile": "Makefile",
        "markdown": "Markdown",
        "mathematica": "Mathematica",
        "matlab": "MATLAB",
        "mips": "MIPS",
        "moonscript": "MoonScript",
        "nginx": "Nginx",
        "nim": "Nim",
        "nix": "Nix",
        "nsis": "NSIS",
        "objectivec": "Objective-C",
        "ocaml": "OCaml",
        "odin": "Odin",
        "perl": "Perl",
        "pgsql": "PL/pgSQL",
        "php": "PHP",
        "pike": "Pike",
        "pkl": "Pkl",
        "plaintext": "Plain Text",
        "pony": "Pony",
        "powershell": "PowerShell",
        "prisma": "Prisma",
        "processing": "Processing",
        "prolog": "Prolog",
        "properties": "Properties",
        "protobuf": "Protocol Buffers",
        "pug": "Pug",
        "puppet": "Puppet",
        "python": "Python",
        "q": "Q",
        "qml": "QML",
        "qsharp": "Q#",
        "r": "R",
        "racket": "Racket",
        "raku": "Raku",
        "reasonml": "ReasonML",
        "rescript": "ReScript",
        "robot": "Robot Framework",
        "ruby": "Ruby",
        "rust": "Rust",
        "sas": "SAS",
        "sass": "Sass",
        "scala": "Scala",
        "scheme": "Scheme",
        "scss": "SCSS",
        "slim": "Slim",
        "smalltalk": "Smalltalk",
        "smali": "Smali",
        "sml": "SML",
        "solidity": "Solidity",
        "sparql": "SPARQL",
        "sql": "SQL",
        "stylus": "Stylus",
        "svelte": "Svelte",
        "swift": "Swift",
        "tcl": "Tcl",
        "tcsh": "Tcsh",
        "terraform": "Terraform",
        "thrift": "Thrift",
        "toml": "TOML",
        "tsx": "TSX",
        "twig": "Twig",
        "typescript": "TypeScript",
        "typst": "Typst",
        "vala": "Vala",
        "vbnet": "VB.NET",
        "vbscript": "VBScript",
        "verilog": "Verilog",
        "vhdl": "VHDL",
        "vim": "Vim Script",
        "vue": "Vue",
        "wasm": "WebAssembly",
        "wgsl": "WGSL",
        "wren": "Wren",
        "x86asm": "x86 Assembly",
        "xml": "XML",
        "xquery": "XQuery",
        "yaml": "YAML",
        "zig": "Zig",
        "zsh": "Zsh",
    ]
}
