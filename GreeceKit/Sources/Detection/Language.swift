import Foundation

/// A programming or markup language: how to recognise it and how to highlight it.
public struct Language: Hashable, Sendable {
    /// highlight.js grammar id (always one that ships in `Web/vendor/highlight`).
    public let grammar: String
    /// Human name shown in the info bar.
    public let name: String
    /// SF Symbol used in the info bar.
    public let symbol: String

    public static let plainText = Language(grammar: "plaintext", name: "Plain Text", symbol: "doc.plaintext")

    public var isPlainText: Bool { grammar == "plaintext" }
}

public enum LanguageCatalog {

    // MARK: Lookup

    public static func language(forExtension ext: String) -> Language? {
        byExtension[ext.lowercased()]
    }

    public static func language(forFileName name: String) -> Language? {
        let lower = name.lowercased()
        if let exact = byFileName[lower] { return exact }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return byExtension["dockerfile"] }
        if lower.hasPrefix(".env") { return byExtension["sh"] }
        if lower.hasPrefix("makefile") { return byExtension["mk"] }
        return nil
    }

    /// Shebangs, XML prologues, doctype and friends.
    public static func language(sniffing text: Substring) -> Language? {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" }).lowercased()
        if firstLine.hasPrefix("#!") {
            let interpreters: [(String, String)] = [
                ("python", "py"), ("ruby", "rb"), ("perl", "pl"), ("node", "js"), ("deno", "ts"), ("bun", "ts"),
                ("php", "php"), ("lua", "lua"), ("elixir", "ex"), ("swift", "swift"), ("osascript", "applescript"),
                ("awk", "awk"), ("tclsh", "tcl"), ("pwsh", "ps1"), ("Rscript".lowercased(), "r"),
                ("zsh", "zsh"), ("fish", "fish"), ("bash", "sh"), ("/sh", "sh"), ("env sh", "sh"),
            ]
            for (needle, ext) in interpreters where firstLine.contains(needle) { return byExtension[ext] }
            return byExtension["sh"]
        }
        if firstLine.hasPrefix("<?xml") { return byExtension["xml"] }
        if firstLine.hasPrefix("<!doctype html") || firstLine.hasPrefix("<html") { return byExtension["html"] }
        if firstLine.hasPrefix("<?php") { return byExtension["php"] }
        return nil
    }

    // MARK: Table

    private struct Entry {
        let grammar: String
        let name: String
        let symbol: String
        let extensions: [String]
        let fileNames: [String]
    }

    private static func e(_ grammar: String, _ name: String, _ exts: [String], files: [String] = [],
                          symbol: String = "chevron.left.forwardslash.chevron.right") -> Entry {
        Entry(grammar: grammar, name: name, symbol: symbol, extensions: exts, fileNames: files)
    }

    private static let entries: [Entry] = [
        // Apple
        e("swift", "Swift", ["swift", "swiftinterface"], files: ["package.swift"], symbol: "swift"),
        e("objectivec", "Objective-C", ["m", "mm", "objc"]),
        e("applescript", "AppleScript", ["applescript"], symbol: "applescript"),
        e("xml", "Property List", ["plist", "entitlements", "xcprivacy", "strings", "stringsdict", "xcscheme", "storyboard", "xib"], symbol: "list.bullet.indent"),
        // C family
        e("c", "C", ["c", "h"]),
        e("cpp", "C++", ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp", "ino", "cu", "cuh", "metal", "hlsl", "wgsl"]),
        e("csharp", "C#", ["cs", "csx", "cake"]),
        e("java", "Java", ["java", "jav", "aidl"]),
        e("kotlin", "Kotlin", ["kt", "kts"]),
        e("scala", "Scala", ["scala", "sc", "sbt"]),
        e("groovy", "Groovy", ["groovy", "gvy", "jenkinsfile"], files: ["jenkinsfile"]),
        e("gradle", "Gradle", ["gradle"]),
        e("dart", "Dart", ["dart"]),
        e("go", "Go", ["go"], files: ["go.mod", "go.sum", "go.work"]),
        e("rust", "Rust", ["rs", "ron"]),
        e("d", "D", ["d", "di"]),
        e("vala", "Vala", ["vala", "vapi"]),
        e("crystal", "Crystal", ["cr"]),
        e("nim", "Nim", ["nim", "nims", "nimble"]),
        // Web
        e("javascript", "JavaScript", ["js", "mjs", "cjs", "jsx", "es6", "gs"], symbol: "curlybraces"),
        e("typescript", "TypeScript", ["ts", "tsx", "mts", "cts"], symbol: "curlybraces"),
        e("json", "JSON", ["json", "jsonc", "json5", "jsonl", "ndjson", "geojson", "webmanifest", "har", "jsonld", "babelrc", "eslintrc", "prettierrc"],
          files: [".babelrc", ".eslintrc", ".prettierrc", "composer.lock", "package-lock.json", "flake.lock"], symbol: "curlybraces.square"),
        e("xml", "HTML", ["html", "htm", "xhtml", "shtml", "vue", "svelte", "astro"], symbol: "globe"),
        e("xml", "XML", ["xml", "xsd", "xsl", "xslt", "svg", "rss", "atom", "wsdl", "csproj", "fsproj", "vbproj", "props", "targets", "resx", "kml", "gpx", "plist.xml", "opml"], symbol: "chevron.left.slash.chevron.right"),
        e("css", "CSS", ["css", "pcss", "postcss"]),
        e("scss", "SCSS", ["scss", "sass"]),
        e("less", "Less", ["less"]),
        e("stylus", "Stylus", ["styl", "stylus"]),
        e("graphql", "GraphQL", ["graphql", "gql", "graphqls"]),
        e("handlebars", "Handlebars", ["hbs", "handlebars", "mustache"]),
        e("twig", "Twig", ["twig"]),
        e("erb", "ERB", ["erb", "rhtml"]),
        e("haml", "Haml", ["haml"]),
        e("django", "Jinja", ["j2", "jinja", "jinja2", "njk", "liquid"]),
        e("php", "PHP", ["php", "php3", "php4", "php5", "php7", "phps", "phtml"]),
        e("wasm", "WebAssembly Text", ["wat", "wast"]),
        // Scripting
        e("python", "Python", ["py", "pyw", "pyi", "pyx", "pxd", "gyp", "gypi", "bzl", "star", "rpy"],
          files: ["build", "build.bazel", "workspace", "sconstruct", "sconscript", "snakefile", "tiltfile"]),
        e("ruby", "Ruby", ["rb", "rbw", "rake", "gemspec", "podspec", "ru", "thor", "jbuilder", "rbi"],
          files: ["gemfile", "rakefile", "podfile", "vagrantfile", "brewfile", "fastfile", "appfile", "matchfile", "guardfile", "dangerfile", "gemfile.lock", "podfile.lock"]),
        e("perl", "Perl", ["pl", "pm", "t", "pod", "raku", "rakumod", "p6", "pl6", "pm6"]),
        e("lua", "Lua", ["lua", "luau", "rockspec"]),
        e("r", "R", ["r", "rprofile"]),
        e("julia", "Julia", ["jl"]),
        e("elixir", "Elixir", ["ex", "exs", "eex", "heex", "leex"], files: ["mix.lock"]),
        e("erlang", "Erlang", ["erl", "hrl", "escript", "app.src"], files: ["rebar.config"]),
        e("haskell", "Haskell", ["hs", "lhs", "hsc"]),
        e("ocaml", "OCaml", ["ml", "mli", "mll", "mly"]),
        e("reasonml", "Reason", ["re", "rei"]),
        e("fsharp", "F#", ["fs", "fsi", "fsx", "fsscript"]),
        e("clojure", "Clojure", ["clj", "cljs", "cljc", "edn", "bb"]),
        e("lisp", "Lisp", ["lisp", "lsp", "cl", "el", "elisp", "fnl"], files: [".emacs"]),
        e("scheme", "Scheme", ["scm", "ss", "sld", "rkt", "rktl"]),
        e("elm", "Elm", ["elm"]),
        e("coffeescript", "CoffeeScript", ["coffee", "cson", "iced"], files: ["cakefile"]),
        e("livescript", "LiveScript", ["ls"]),
        e("moonscript", "MoonScript", ["moon"]),
        e("tcl", "Tcl", ["tcl", "tk", "exp"]),
        e("awk", "Awk", ["awk", "gawk"]),
        e("powershell", "PowerShell", ["ps1", "psm1", "psd1"], symbol: "terminal"),
        e("dos", "Batch", ["bat", "cmd"], symbol: "terminal"),
        e("bash", "Shell", ["sh", "bash", "zsh", "ksh", "csh", "tcsh", "fish", "command", "tool", "bats", "ebuild", "envrc", "zshrc", "bashrc", "zprofile", "zshenv", "profile", "bash_profile", "bash_aliases"],
          files: [".bashrc", ".bash_profile", ".bash_aliases", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".profile", ".envrc", "pkgbuild", "apkbuild"], symbol: "terminal"),
        e("vim", "Vim Script", ["vim", "vimrc"], files: [".vimrc", ".gvimrc", "_vimrc"]),
        // Data & config
        e("yaml", "YAML", ["yaml", "yml", "sublime-syntax"], files: [".clang-format", ".clang-tidy", ".gemrc", "pubspec.lock", "yarn.lock", "pnpm-lock.yaml"], symbol: "list.bullet.indent"),
        e("ini", "TOML", ["toml"], files: ["cargo.lock", "pipfile", "poetry.lock", "uv.lock"], symbol: "list.bullet.indent"),
        e("ini", "INI", ["ini", "cfg", "conf", "cnf", "prefs", "desktop", "service", "reg", "editorconfig", "gitconfig", "npmrc", "pypirc", "flake8", "pylintrc", "inputrc"],
          files: [".editorconfig", ".gitconfig", ".gitmodules", ".npmrc", ".yarnrc", ".pypirc", ".flake8", ".pylintrc", ".inputrc", ".curlrc", ".wgetrc", "setup.cfg", "tox.ini"], symbol: "gearshape"),
        e("properties", "Properties", ["properties"]),
        e("sql", "SQL", ["sql", "ddl", "dml", "hql", "psql", "mysql", "sqlite-sql"], symbol: "cylinder"),
        e("pgsql", "PL/pgSQL", ["pgsql", "plpgsql"], symbol: "cylinder"),
        e("protobuf", "Protocol Buffers", ["proto"]),
        e("thrift", "Thrift", ["thrift"]),
        e("capnproto", "Cap’n Proto", ["capnp"]),
        e("dockerfile", "Dockerfile", ["dockerfile", "containerfile"], files: ["dockerfile", "containerfile"], symbol: "shippingbox"),
        e("makefile", "Makefile", ["mk", "mak", "make"], files: ["makefile", "gnumakefile", "bsdmakefile", "justfile", ".justfile"], symbol: "hammer"),
        e("cmake", "CMake", ["cmake"], files: ["cmakelists.txt"], symbol: "hammer"),
        e("nginx", "Nginx", ["nginx", "nginxconf"], files: ["nginx.conf"]),
        e("apache", "Apache", ["htaccess", "vhost"], files: [".htaccess", "httpd.conf", "apache2.conf"]),
        e("nix", "Nix", ["nix"]),
        e("puppet", "Puppet", ["pp"]),
        e("dts", "Device Tree", ["dts", "dtsi"]),
        e("http", "HTTP", ["http", "rest"]),
        e("dns", "DNS Zone", ["zone"]),
        e("plaintext", "Git Ignore", ["gitignore", "dockerignore", "npmignore", "gitattributes", "prettierignore", "eslintignore"],
          files: [".gitignore", ".dockerignore", ".npmignore", ".gitattributes", ".prettierignore", ".eslintignore", ".gcloudignore", ".slugignore"], symbol: "eye.slash"),
        // Science, systems & others
        e("latex", "LaTeX", ["tex", "ltx", "sty", "cls", "dtx", "ins", "bib", "bbx", "cbx"], symbol: "function"),
        e("matlab", "MATLAB", ["matlab"]),
        e("mathematica", "Mathematica", ["nb", "wl", "wls", "mt"]),
        e("fortran", "Fortran", ["f", "for", "f77", "f90", "f95", "f03", "f08", "fpp"]),
        e("ada", "Ada", ["ada", "adb", "ads"]),
        e("delphi", "Pascal", ["pas", "dpr", "lpr", "pp.pas"]),
        e("vbnet", "Visual Basic", ["vb", "bas", "vbs", "frm"]),
        e("smalltalk", "Smalltalk", ["st"]),
        e("prolog", "Prolog", ["pro", "prolog"]),
        e("sml", "Standard ML", ["sml", "sig", "fun"]),
        e("verilog", "Verilog", ["v", "vh", "sv", "svh"]),
        e("vhdl", "VHDL", ["vhd", "vhdl"]),
        e("x86asm", "Assembly", ["asm", "nasm", "s", "S", "inc"]),
        e("armasm", "ARM Assembly", ["arm"]),
        e("llvm", "LLVM IR", ["ll"]),
        e("glsl", "GLSL", ["glsl", "vert", "frag", "geom", "tesc", "tese", "comp", "vsh", "fsh", "shader"]),
        e("gcode", "G-code", ["gcode", "nc", "gco"]),
        e("openscad", "OpenSCAD", ["scad"]),
        e("stata", "Stata", ["do", "ado"]),
        e("sas", "SAS", ["sas"]),
        e("gherkin", "Gherkin", ["feature"]),
        e("haxe", "Haxe", ["hx", "hxml"]),
        e("gml", "GameMaker", ["gml"]),
        e("processing", "Processing", ["pde"]),
        e("arduino", "Arduino", ["ino.cpp"]),
        e("javascript", "Solidity", ["sol"]),
        e("asciidoc", "AsciiDoc", ["adoc", "asciidoc", "asc"], symbol: "doc.richtext"),
        e("plaintext", "reStructuredText", ["rst", "rest.txt"], symbol: "doc.richtext"),
        e("plaintext", "Org", ["org"], symbol: "doc.richtext"),
        e("diff", "Diff", ["diff", "patch", "rej"], symbol: "plus.forwardslash.minus"),
        e("plaintext", "Log", ["log", "out", "err"], symbol: "list.bullet.rectangle"),
        e("plaintext", "Plain Text", ["txt", "text", "me", "1st", "nfo", "srt", "vtt", "license", "lic"],
          files: ["license", "licence", "copying", "authors", "contributors", "notice", "readme", "changelog", "changes", "todo", "codeowners", "version"], symbol: "doc.plaintext"),
    ]

    /// Grammars that need an extra highlight.js file (not in the bundled "common" build).
    public static let commonGrammars: Set<String> = [
        "bash", "c", "cpp", "csharp", "css", "diff", "go", "graphql", "ini", "java", "javascript", "json",
        "kotlin", "less", "lua", "makefile", "markdown", "objectivec", "perl", "php", "php-template",
        "plaintext", "python", "python-repl", "r", "ruby", "rust", "scss", "shell", "sql", "swift",
        "typescript", "vbnet", "wasm", "xml", "yaml",
    ]

    static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        for entry in entries {
            let language = Language(grammar: entry.grammar, name: entry.name, symbol: entry.symbol)
            for ext in entry.extensions where map[ext.lowercased()] == nil { map[ext.lowercased()] = language }
        }
        return map
    }()

    static let byFileName: [String: Language] = {
        var map: [String: Language] = [:]
        for entry in entries {
            let language = Language(grammar: entry.grammar, name: entry.name, symbol: entry.symbol)
            for name in entry.fileNames where map[name] == nil { map[name] = language }
        }
        return map
    }()

    /// Every grammar id referenced by the catalog (used by tests to verify the bundle).
    public static var allGrammars: Set<String> { Set(entries.map(\.grammar)) }
}
