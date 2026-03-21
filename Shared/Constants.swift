import Foundation

/// Central constants shared between the main app and Quick Look extension.
enum GreeceConstants {

    // MARK: - App Group
    /// Used for UserDefaults sharing between the app and extension.
    static let appGroupIdentifier = "group.com.scorchy.greece"

    // MARK: - Bundle Identifiers
    static let appBundleIdentifier = "com.scorchy.greece"
    static let extensionBundleIdentifier = "com.scorchy.greece.quicklook"

    // MARK: - Defaults Keys
    enum Keys {
        // General
        static let showMetadataBar = "showMetadataBar"
        static let metadataShowSize = "metadataShowSize"
        static let metadataShowDates = "metadataShowDates"
        static let metadataShowType = "metadataShowType"
        static let rememberScrollPosition = "rememberScrollPosition"
        static let cacheRemoteImages = "cacheRemoteImages"

        // Markdown
        static let markdownLightTheme = "markdownLightTheme"
        static let markdownDarkTheme = "markdownDarkTheme"
        static let markdownFontFamily = "markdownFontFamily"
        static let markdownFontSize = "markdownFontSize"
        static let markdownLineHeight = "markdownLineHeight"
        static let markdownShowTOC = "markdownShowTOC"
        static let markdownRenderMath = "markdownRenderMath"
        static let markdownRenderMermaid = "markdownRenderMermaid"
        static let markdownRenderEmoji = "markdownRenderEmoji"

        // Source Code
        static let codeLightTheme = "codeLightTheme"
        static let codeDarkTheme = "codeDarkTheme"
        static let codeFontFamily = "codeFontFamily"
        static let codeFontSize = "codeFontSize"
        static let codeFontWeight = "codeFontWeight"
        static let codeShowLineNumbers = "codeShowLineNumbers"
        static let codeWordWrap = "codeWordWrap"
        static let codeTabWidth = "codeTabWidth"
        static let codeAutoFormat = "codeAutoFormat"

        // Data
        static let csvAlternatingRows = "csvAlternatingRows"
        static let csvMaxRows = "csvMaxRows"
        static let sqliteDefaultTable = "sqliteDefaultTable"

        // Archives
        static let archiveSortColumn = "archiveSortColumn"
        static let archiveSortAscending = "archiveSortAscending"
        static let archiveShowHidden = "archiveShowHidden"

        // Folders
        static let folderShowHidden = "folderShowHidden"
        static let folderShowSize = "folderShowSize"
        static let folderShowDate = "folderShowDate"
        static let folderShowKind = "folderShowKind"
        static let folderShowTags = "folderShowTags"

        // Scroll positions cache
        static let scrollPositions = "scrollPositions"
    }

    // MARK: - File Categories
    enum FileCategory: String, CaseIterable {
        case markdown
        case sourceCode
        case csv
        case sqlite
        case diff
        case archive
        case folder
        case textBundle
        case unknown
    }

    // MARK: - Supported Markdown Extensions
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext",
        "rmd", "qmd"
    ]

    // MARK: - Supported Archive Extensions
    static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "tar.gz", "tar.bz2"
    ]

    // MARK: - Supported Data Extensions
    static let csvExtensions: Set<String> = ["csv", "tsv", "tab"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "sdb", "s3db"]
    static let diffExtensions: Set<String> = ["diff", "patch"]

    // MARK: - Source Code Extensions (mirrors LanguageDetector.extensionMap keys)
    static let sourceCodeExtensions: Set<String> = [
        "abap", "ada", "adb", "ads", "adoc", "ahk", "ahkl", "aidl", "als", "applescript",
        "scpt", "arc", "as", "asm", "asp", "aspx", "awk",
        "bas", "bat", "bb", "bf", "bib", "blade.php", "bqn", "bsl", "bzl",
        "c", "cats", "cbl", "cob", "cc", "cfc", "cfm", "cfg", "cjs", "cl", "clj", "cljc",
        "cljs", "cls", "cmake", "cmd", "coffee", "conf", "cpp", "cr", "cs", "csh", "cshtml",
        "cson", "css", "cu", "cue", "cxx",
        "d", "dart", "dfy", "dhall", "di", "djt", "dml", "do", "dockerfile", "dot", "dtd", "dts",
        "e", "eex", "el", "elm", "emacs", "epp", "erb", "erl", "ex", "exs",
        "f", "f03", "f08", "f77", "f90", "f95", "factor", "feature", "fish", "fnl", "for",
        "forth", "fpp", "fs", "fsi", "fsx", "ftl", "fth",
        "g4", "gd", "gemspec", "gleam", "glsl", "gml", "gn", "gni", "go", "gql", "gradle",
        "graphql", "groovy", "gv", "gyp",
        "h", "h++", "haml", "hbs", "hcl", "heex", "hh", "hlsl", "hocon", "hpp", "hrl", "hs",
        "htm", "html", "http", "hx", "hxx", "hy",
        "ics", "idr", "ijs", "ino", "ini", "ipp", "ipynb", "iss",
        "j2", "java", "jinja", "jinja2", "jl", "js", "json", "json5", "jsonc", "jsonl",
        "jsonnet", "jsx", "just",
        "kak", "kicad_pcb", "ksh", "kt", "kts",
        "l", "lasso", "latte", "lean", "less", "lex", "lhs", "lidr", "lisp", "lkml", "ll",
        "log", "lsp", "lua",
        "m", "m4", "mak", "matlab", "meson", "mips", "mjs", "mk", "ml", "mli", "mm", "mo",
        "mojom", "moon", "move", "mpl", "mq4", "mq5", "mql", "mql4", "mql5", "mts",
        "nasm", "nb", "ncl", "ne", "nginx", "nim", "nimble", "nix", "nsi", "nsh", "nu",
        "objc", "ocaml", "odin", "opam", "org", "os", "oxygene",
        "p", "p4", "p6", "pas", "pb", "pbt", "pde", "perl", "pgsql", "php", "php3", "php4",
        "php5", "php7", "phps", "phtml", "pig", "pk", "pkl", "pl", "plist", "plsql", "pm",
        "po", "pony", "postcss", "pp", "pq", "prisma", "pro", "properties", "proto", "ps",
        "ps1", "psm1", "pug", "puppet", "py", "pyi", "pyw", "pyx",
        "q", "qml", "qs",
        "r", "raku", "rb", "rbw", "re", "regex", "rei", "res", "resi", "rkt", "robot", "ron",
        "rpy", "rs", "rss", "rst", "ru",
        "s", "sas", "sass", "sbt", "sc", "scala", "scm", "scss", "sh", "shader", "slim", "sls",
        "sml", "smali", "snap", "sol", "sparql", "spl", "sql", "ss", "st", "stl", "sty", "styl",
        "svelte", "svg", "swift",
        "t", "tcc", "tcl", "tcsh", "tex", "tf", "tfvars", "thrift", "tk", "tla", "toml", "tpp",
        "ts", "tsx", "tt", "twig", "typ", "txt",
        "uc",
        "v", "vala", "vb", "vbs", "vcl", "vhdl", "vhd", "vim", "vue",
        "wasm", "wgsl", "wl", "wls", "wren", "wxi", "wxs",
        "x", "xhtml", "xls", "xml", "xq", "xquery", "xsd", "xsl", "xslt",
        "y", "yaml", "yml",
        "zap", "zig", "zsh",
    ]

    // MARK: - TextBundle
    static let textBundleExtensions: Set<String> = ["textbundle", "textpack"]

    // MARK: - Auto-Formattable Types
    static let autoFormatExtensions: Set<String> = [
        "json", "css", "js", "javascript", "xml", "svg", "plist", "html"
    ]

    // MARK: - Max Preview Sizes
    static let maxFileSize: Int = 10_000_000       // 10 MB
    static let maxCSVRows: Int = 10_000
    static let maxCodeLines: Int = 50_000
    static let maxArchiveEntries: Int = 100_000

    // MARK: - Image Cache
    static let imageCacheDirectory = "GreeceImageCache"
    static let maxImageCacheSize: Int = 100_000_000 // 100 MB
}
