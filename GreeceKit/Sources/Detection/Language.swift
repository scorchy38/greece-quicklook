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
        let variant = variantBases.first { base in
            lower.hasPrefix(base) && lower.dropFirst(base.count).first.map { ".-_".contains($0) } == true
        }
        return variant.flatMap { byFileName[$0] }
    }

    /// Names whose variants keep their language: Dockerfile.dev, Makefile.in, Procfile.web, .env.production
    /// (but not .envoy.yaml). Exact names win first, so Makefile.PL stays Perl.
    private static let variantBases = ["dockerfile", "containerfile", "makefile", "procfile", "caddyfile", "jenkinsfile", ".env"]

    /// Shebangs, XML prologues, doctype and friends.
    public static func language(sniffing text: Substring) -> Language? {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" }).lowercased()
        if firstLine.hasPrefix("#!") {
            let interpreters: [(String, String)] = [
                ("python", "py"), ("pypy", "py"), ("uv run", "py"), ("ruby", "rb"), ("raku", "raku"), ("perl6", "raku"), ("perl", "pl"),
                ("ts-node", "ts"), ("tsx", "ts"), ("node", "js"), ("deno", "ts"), ("bun", "ts"),
                ("php", "php"), ("lua", "lua"), ("elixir", "ex"), ("escript", "erl"), ("swift", "swift"), ("osascript", "applescript"),
                ("crystal", "cr"), ("julia", "jl"), ("racket", "rkt"), ("guile", "scm"), ("sbcl", "lisp"),
                ("runghc", "hs"), ("runhaskell", "hs"), ("scala", "scala"), ("kotlin", "kts"), ("groovy", "groovy"), ("dart", "dart"),
                ("awk", "awk"), ("tclsh", "tcl"), ("wish", "tcl"), ("expect", "exp"), ("pwsh", "ps1"), ("rscript", "r"), ("make -f", "mk"),
                ("zsh", "zsh"), ("fish", "fish"), ("env nu", "nu"), ("bin/nu", "nu"), ("bash", "sh"), ("/sh", "sh"), ("env sh", "sh"),
            ]
            for (needle, ext) in interpreters where firstLine.contains(needle) { return byExtension[ext] }
            return byExtension["sh"]
        }
        if firstLine.hasPrefix("#compdef") || firstLine.hasPrefix("#autoload") { return byExtension["zsh"] }
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

    /// Each extension and file name appears once. Where a language has no grammar of its own, it borrows the
    /// closest one under its own name (Zig reads well as Rust, Terraform as INI).
    private static let entries: [Entry] = [
        // Apple
        e("swift", "Swift", ["swift", "swiftinterface"], files: ["package.swift"], symbol: "swift"),
        e("objectivec", "Objective-C", ["m", "mm", "objc", "pch"]),
        e("applescript", "AppleScript", ["applescript"], symbol: "applescript"),
        e("xml", "Property List", ["plist", "entitlements", "xcprivacy", "stringsdict", "intentdefinition", "tmlanguage", "tmtheme", "tmpreferences", "tmsnippet"], symbol: "list.bullet.indent"),
        e("xml", "Interface Builder", ["storyboard", "xib"], symbol: "chevron.left.slash.chevron.right"),
        e("c", "Strings", ["strings"], symbol: "character.bubble"),
        e("json", "String Catalog", ["xcstrings"], symbol: "character.bubble"),
        e("json", "Test Plan", ["xctestplan"], symbol: "curlybraces.square"),
        e("ini", "Xcode Config", ["xcconfig"], symbol: "gearshape"),
        e("cpp", "Module Map", ["modulemap"]),
        e("c", "MIG", ["defs", "mig"]),
        e("cpp", "Lex", ["l", "lm", "lmm", "lpp", "lxx"]),
        e("cpp", "Yacc", ["y", "ym", "ymm", "ypp", "yxx", "yy"]),
        // C family & systems
        e("c", "C", ["c", "h"]),
        e("cpp", "C++", ["cpp", "cc", "cxx", "c++", "cp", "hpp", "hh", "hxx", "h++", "hp", "ipp", "tpp", "tcc", "inl", "cppm", "ixx", "ccm", "cxxm", "iig"]),
        e("cpp", "CUDA", ["cu", "cuh", "hip"]),
        e("cpp", "Metal", ["metal"]),
        e("cpp", "HLSL", ["hlsl", "hlsli", "fx", "fxh", "cginc", "usf", "ush"]),
        e("rust", "WGSL", ["wgsl"]),
        e("arduino", "Arduino", ["ino"]),
        e("csharp", "C#", ["cs", "csx", "cake"]),
        e("java", "Java", ["java", "jav", "aidl"]),
        e("aspectj", "AspectJ", ["aj"]),
        e("kotlin", "Kotlin", ["kt", "kts"]),
        e("scala", "Scala", ["scala", "sc", "sbt"]),
        e("groovy", "Groovy", ["groovy", "gvy", "gy", "jenkinsfile"], files: ["jenkinsfile"]),
        e("groovy", "Nextflow", ["nf"], files: ["nextflow.config"]),
        e("gradle", "Gradle", ["gradle"]),
        e("ceylon", "Ceylon", ["ceylon"]),
        e("golo", "Golo", ["golo"]),
        e("dart", "Dart", ["dart"]),
        e("go", "Go", ["go"], files: ["go.mod", "go.sum", "go.work", "go.work.sum"]),
        e("go", "Odin", ["odin"]),
        e("go", "CUE", ["cue"]),
        e("rust", "Rust", ["rs", "ron"]),
        e("rust", "Zig", ["zig", "zon"]),
        e("rust", "Gleam", ["gleam"]),
        e("d", "D", ["d", "di"]),
        e("vala", "Vala", ["vala", "vapi"]),
        e("crystal", "Crystal", ["cr"]),
        e("nim", "Nim", ["nim", "nims", "nimble"]),
        e("pony", "Pony", ["pony"]),
        e("cpp", "Squirrel", ["nut"]),
        e("zephir", "Zephir", ["zep"]),
        // Web
        e("javascript", "JavaScript", ["js", "mjs", "cjs", "jsx", "es6", "gs", "jscript", "javascript", "pac", "jake"], files: ["jakefile"], symbol: "curlybraces"),
        e("typescript", "TypeScript", ["ts", "tsx", "mts", "cts"], symbol: "curlybraces"),
        e("javascript", "Jsonnet", ["jsonnet", "libsonnet"], symbol: "curlybraces"),
        e("json", "JSON", ["json", "jsonc", "json5", "jsonl", "ndjson", "geojson", "webmanifest", "har", "jsonld", "babelrc", "eslintrc", "prettierrc", "jshintrc", "swcrc",
                           "code-workspace", "code-snippets", "sublime-settings", "sublime-project", "sublime-keymap", "sublime-commands", "sublime-build",
                           "sublime-menu", "sublime-macro", "sublime-mousemap", "sublime-completions", "sublime-theme", "sublime-color-scheme",
                           "avsc", "tfstate", "mcmeta", "arb"],
          files: [".babelrc", ".eslintrc", ".prettierrc", ".jshintrc", ".swcrc", ".swift-format", ".watchmanconfig", ".firebaserc", ".bowerrc",
                  "composer.lock", "package-lock.json", "flake.lock", "package.resolved", "pipfile.lock", "deno.lock", "bun.lock"], symbol: "curlybraces.square"),
        e("xml", "HTML", ["html", "htm", "xhtml", "shtml"], symbol: "globe"),
        e("xml", "Vue", ["vue"], symbol: "globe"),
        e("xml", "Svelte", ["svelte"], symbol: "globe"),
        e("xml", "Astro", ["astro"], symbol: "globe"),
        e("xml", "JSP", ["jsp", "jspf"], symbol: "globe"),
        e("xml", "ASP.NET", ["aspx", "ascx"], symbol: "globe"),
        e("xml", "Razor", ["cshtml", "razor"], symbol: "globe"),
        e("vbscript-html", "ASP", ["asp"], symbol: "globe"),
        e("xml", "XML", ["xml", "xsd", "xsl", "xslt", "svg", "rss", "atom", "wsdl", "dtd", "csproj", "fsproj", "vbproj", "vcxproj", "proj", "props", "targets", "nuspec",
                         "resx", "resw", "xaml", "axaml", "xlf", "xliff", "xcscheme", "xcworkspacedata", "config", "xul", "fxml", "mxml", "glade", "qrc",
                         "xspf", "rdf", "jnlp", "tld", "wxs", "wxi", "wxl", "sublime-snippet", "kml", "gpx", "opml"], symbol: "chevron.left.slash.chevron.right"),
        e("css", "CSS", ["css", "pcss", "postcss"]),
        e("scss", "SCSS", ["scss"]),
        e("scss", "Sass", ["sass"]),
        e("less", "Less", ["less"]),
        e("stylus", "Stylus", ["styl", "stylus"]),
        e("graphql", "GraphQL", ["graphql", "gql", "graphqls"]),
        e("typescript", "Prisma", ["prisma"]),
        e("typescript", "Bicep", ["bicep", "bicepparam"]),
        e("php", "PHP", ["php", "php3", "php4", "php5", "php7", "phps", "ph3", "ph4"]),
        e("wasm", "WebAssembly Text", ["wat", "wast"]),
        // Templates
        e("php-template", "PHP Template", ["phtml"]),
        e("handlebars", "Handlebars", ["hbs", "handlebars", "mustache"]),
        e("twig", "Twig", ["twig"]),
        e("erb", "ERB", ["erb", "rhtml"]),
        e("erb", "EJS", ["ejs"]),
        e("haml", "Haml", ["haml"]),
        e("django", "Jinja", ["j2", "jinja", "jinja2"]),
        e("django", "Nunjucks", ["njk"]),
        e("django", "Liquid", ["liquid"]),
        e("django", "Tera", ["tera"]),
        e("django", "Go Template", ["gohtml", "gotmpl"]),
        e("dust", "Dust", ["dust"]),
        e("leaf", "Leaf", ["leaf"]),
        e("mojolicious", "Mojolicious", ["ep"]),
        // Scripting
        e("python", "Python", ["py", "pyw", "pyi", "pyx", "pxd", "pxi", "gyp", "gypi", "rpy", "ipy", "wsgi", "smk"],
          files: ["sconstruct", "sconscript", "snakefile", ".pythonrc"]),
        e("python", "Starlark", ["bzl", "star", "bazel"], files: ["build", "build.bazel", "workspace", "workspace.bazel", "module.bazel", "buck", "tiltfile"]),
        e("python", "Meson", [], files: ["meson.build", "meson_options.txt", "meson.options"], symbol: "hammer"),
        e("python", "GN", ["gn", "gni"], symbol: "hammer"),
        e("python", "Mojo", ["mojo"]),
        e("python", "GDScript", ["gd"]),
        e("python", "Vyper", ["vy"]),
        e("python", "SageMath", ["sage"]),
        e("hy", "Hy", ["hy"]),
        e("ruby", "Ruby", ["rb", "rbw", "rake", "gemspec", "podspec", "ru", "thor", "jbuilder", "rbi", "rbs"],
          files: ["gemfile", "gemfile.lock", "rakefile", "podfile", "vagrantfile", "brewfile", "berksfile", "capfile", "puppetfile", "thorfile", "guardfile",
                  "dangerfile", "cheffile", "steepfile", "appraisals", "fastfile", "appfile", "matchfile", "gymfile", "scanfile", "snapfile", "deliverfile",
                  "pluginfile", "screengrabfile", ".irbrc", ".pryrc"]),
        e("ruby", "Cartfile", [], files: ["cartfile", "cartfile.private", "cartfile.resolved"]),
        e("perl", "Perl", ["pl", "pm", "t", "pod", "psgi", "plx"], files: ["cpanfile", "makefile.pl"]),
        e("perl", "Raku", ["raku", "rakumod", "rakutest", "p6", "pl6", "pm6"]),
        e("lua", "Lua", ["lua", "luau", "rockspec", "nse"], files: [".luacheckrc"]),
        e("r", "R", ["r", "rprofile"], files: [".rprofile"]),
        e("julia", "Julia", ["jl"]),
        e("elixir", "Elixir", ["ex", "exs", "eex", "heex", "leex"], files: ["mix.lock"]),
        e("erlang", "Erlang", ["erl", "hrl", "escript", "yrl", "xrl"], files: ["rebar.config", "rebar.lock", "sys.config"]),
        e("haskell", "Haskell", ["hs", "lhs", "hsc", "hs-boot"], files: [".ghci"]),
        e("haskell", "PureScript", ["purs"]),
        e("haskell", "Idris", ["idr", "lidr"]),
        e("ocaml", "OCaml", ["ml", "mli", "mll", "mly", "eliom"], files: [".ocamlinit"]),
        e("reasonml", "Reason", ["re", "rei"]),
        e("reasonml", "ReScript", ["res", "resi"]),
        e("fsharp", "F#", ["fs", "fsi", "fsx", "fsscript"]),
        e("clojure", "Clojure", ["clj", "cljs", "cljc", "edn", "bb"]),
        e("clojure", "Janet", ["janet"]),
        e("lisp", "Lisp", ["lisp", "lsp", "cl", "el", "elisp", "asd"], files: [".emacs", ".spacemacs", ".sbclrc"]),
        e("lisp", "Fennel", ["fnl"]),
        e("lisp", "Dune", [], files: ["dune", "dune-project", "dune-workspace"], symbol: "hammer"),
        e("scheme", "Scheme", ["scm", "ss", "sld", "sps"]),
        e("scheme", "Racket", ["rkt", "rktl", "rktd"]),
        e("elm", "Elm", ["elm"]),
        e("coffeescript", "CoffeeScript", ["coffee", "cson", "iced"], files: ["cakefile"]),
        e("livescript", "LiveScript", ["ls"]),
        e("moonscript", "MoonScript", ["moon"]),
        e("wren", "Wren", ["wren"]),
        e("tcl", "Tcl", ["tcl", "tk", "exp", "tm", "xdc"]),
        e("awk", "Awk", ["awk", "gawk"]),
        e("powershell", "PowerShell", ["ps1", "psm1", "psd1"], symbol: "terminal"),
        e("dos", "Batch", ["bat", "cmd"], symbol: "terminal"),
        e("vbscript", "VBScript", ["vbs"], symbol: "terminal"),
        e("autohotkey", "AutoHotkey", ["ahk"]),
        e("autoit", "AutoIt", ["au3"]),
        e("nsis", "NSIS", ["nsi", "nsh"]),
        // Shell & dotfiles
        e("bash", "Shell", ["sh", "bash", "zsh", "ksh", "csh", "tcsh", "command", "tool", "bats", "ebuild", "eclass", "env", "envrc", "zsh-theme",
                            "zshrc", "bashrc", "zprofile", "zshenv", "profile", "bash_profile", "bash_aliases"],
          files: [".env", ".envrc", ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_aliases", ".zshrc", ".zshenv", ".zprofile",
                  ".zlogin", ".zlogout", ".kshrc", ".cshrc", ".tcshrc", ".login", ".logout", ".xinitrc", ".xprofile", ".xsession", ".xsessionrc",
                  ".aliases", ".functions", ".exports", ".renviron", "bashrc", "bash_profile", "zshrc", "zprofile", "pkgbuild", "apkbuild"], symbol: "terminal"),
        e("bash", "Fish", ["fish"], symbol: "terminal"),
        e("bash", "Nushell", ["nu"], symbol: "terminal"),
        e("shell", "Shell Session", ["sh-session"], symbol: "terminal"),
        e("bash", "tmux", [], files: [".tmux.conf", "tmux.conf"], symbol: "terminal"),
        e("bash", "Crontab", [], files: ["crontab"], symbol: "clock"),
        e("bash", "SwiftFormat", [], files: [".swiftformat"], symbol: "gearshape"),
        e("bash", "Bazel RC", [], files: [".bazelrc"], symbol: "gearshape"),
        e("bash", "ProGuard", [], files: ["proguard-rules.pro", "consumer-rules.pro"], symbol: "gearshape"),
        e("bash", "Mintfile", [], files: ["mintfile"], symbol: "shippingbox"),
        e("vim", "Vim Script", ["vim", "vimrc"], files: [".vimrc", ".gvimrc", "_vimrc", "_gvimrc", ".ideavimrc", ".exrc", ".nvimrc", "vimrc", "gvimrc"]),
        // Data & config
        e("yaml", "YAML", ["yaml", "yml", "sublime-syntax", "cff"],
          files: [".clang-format", "_clang-format", ".clang-tidy", ".clangd", ".gemrc", ".condarc", ".yamllint",
                  "pubspec.lock", "yarn.lock", "podfile.lock", "glide.lock", "shard.lock", "pixi.lock"], symbol: "list.bullet.indent"),
        e("yaml", "Procfile", [], files: ["procfile"], symbol: "list.bullet.indent"),
        e("yaml", "Salt State", ["sls"], symbol: "list.bullet.indent"),
        e("ini", "TOML", ["toml"], files: ["cargo.lock", "pipfile", "poetry.lock", "uv.lock", "pdm.lock", "gopkg.lock", "makefile.toml"], symbol: "list.bullet.indent"),
        e("ini", "INI", ["ini", "cfg", "conf", "cnf", "prefs", "desktop", "service", "socket", "timer", "mount", "automount", "slice", "nmconnection",
                         "reg", "editorconfig", "gitconfig", "npmrc", "pypirc", "flake8", "pylintrc", "inputrc", "hgrc"],
          files: [".editorconfig", ".gitconfig", "gitconfig", ".gitmodules", ".npmrc", ".yarnrc", ".pypirc", ".flake8", ".pylintrc", "pylintrc", ".coveragerc",
                  ".inputrc", "inputrc", ".curlrc", ".wgetrc", ".hgrc", "hgrc", "setup.cfg", "tox.ini"], symbol: "gearshape"),
        e("ini", "Terraform", ["tf", "tfvars", "tofu", "tfbackend"], symbol: "gearshape"),
        e("ini", "HCL", ["hcl", "nomad"], symbol: "gearshape"),
        e("ini", "Godot", ["tscn", "tres", "godot", "gdextension"], symbol: "gearshape"),
        e("ini", "Inno Setup", ["iss"], symbol: "gearshape"),
        e("ini", "Doxyfile", [], files: ["doxyfile"], symbol: "gearshape"),
        e("properties", "Properties", ["properties"], symbol: "gearshape"),
        e("properties", "SSH Config", [], files: ["ssh_config", "sshd_config"], symbol: "gearshape"),
        e("properties", "Tool Versions", [], files: [".tool-versions"], symbol: "gearshape"),
        e("properties", "X Resources", [], files: [".xresources", ".xdefaults"], symbol: "gearshape"),
        e("properties", "Hosts", [], files: ["hosts"], symbol: "network"),
        e("sql", "SQL", ["sql", "ddl", "dml", "hql", "psql", "mysql", "sqlite-sql"], symbol: "cylinder"),
        e("sql", "PL/SQL", ["plsql", "pkb", "pks", "pck"], symbol: "cylinder"),
        e("sql", "CQL", ["cql"], symbol: "cylinder"),
        e("pgsql", "PL/pgSQL", ["pgsql", "plpgsql"], symbol: "cylinder"),
        e("n1ql", "N1QL", ["n1ql"], symbol: "cylinder"),
        e("xquery", "XQuery", ["xq", "xql", "xqm", "xquery", "xqy"]),
        e("ldif", "LDIF", ["ldif"]),
        e("swift", "Pkl", ["pkl"]),
        e("protobuf", "Protocol Buffers", ["proto"]),
        e("thrift", "Thrift", ["thrift"]),
        e("capnproto", "Cap’n Proto", ["capnp"]),
        // Build & infrastructure
        e("dockerfile", "Dockerfile", ["dockerfile", "containerfile"], files: ["dockerfile", "containerfile"], symbol: "shippingbox"),
        e("dockerfile", "Earthfile", [], files: ["earthfile"], symbol: "shippingbox"),
        e("dockerfile", "Modelfile", [], files: ["modelfile"], symbol: "shippingbox"),
        e("makefile", "Makefile", ["mk", "mak", "make", "gmk", "am"], files: ["makefile", "gnumakefile", "bsdmakefile"], symbol: "hammer"),
        e("makefile", "Justfile", ["just"], files: ["justfile", ".justfile"], symbol: "hammer"),
        e("makefile", "Kbuild", [], files: ["kbuild"], symbol: "hammer"),
        e("makefile", "Ninja", ["ninja"], symbol: "hammer"),
        e("bash", "Kconfig", [], files: ["kconfig"], symbol: "hammer"),
        e("cmake", "CMake", ["cmake"], files: ["cmakelists.txt"], symbol: "hammer"),
        e("nginx", "Nginx", ["nginx", "nginxconf"], files: ["nginx.conf", "mime.types", "fastcgi_params", "fastcgi.conf", "uwsgi_params", "scgi_params", "proxy_params"], symbol: "server.rack"),
        e("nginx", "Caddyfile", ["caddyfile"], files: ["caddyfile"], symbol: "server.rack"),
        e("nginx", "Corefile", [], files: ["corefile"], symbol: "server.rack"),
        e("apache", "Apache", ["htaccess", "vhost", "apacheconf"], files: [".htaccess", "httpd.conf", "apache2.conf"], symbol: "server.rack"),
        e("pf", "Packet Filter", [], files: ["pf.conf"], symbol: "server.rack"),
        e("routeros", "RouterOS Script", ["rsc"], symbol: "server.rack"),
        e("accesslog", "Access Log", [], files: ["access.log", "access_log"], symbol: "list.bullet.rectangle"),
        e("nix", "Nix", ["nix"]),
        e("puppet", "Puppet", ["pp"]),
        e("dts", "Device Tree", ["dts", "dtsi", "dtso"]),
        e("http", "HTTP", ["http", "rest"]),
        e("dns", "DNS Zone", ["zone"]),
        e("jboss-cli", "JBoss CLI", ["cli"], symbol: "terminal"),
        // Git
        e("properties", "Git Attributes", ["gitattributes"], files: [".gitattributes"], symbol: "arrow.triangle.branch"),
        e("properties", "Code Owners", [], files: ["codeowners"], symbol: "person.2"),
        e("ini", "Commit Message", [], files: ["commit_editmsg", "merge_msg", "tag_editmsg", "squash_msg"], symbol: "arrow.triangle.branch"),
        e("ini", "Rebase Plan", [], files: ["git-rebase-todo"], symbol: "arrow.triangle.branch"),
        e("plaintext", "Git Mailmap", [], files: [".mailmap"], symbol: "arrow.triangle.branch"),
        e("plaintext", "Git Ignore", ["gitignore", "dockerignore", "npmignore", "prettierignore", "eslintignore"],
          files: [".gitignore", ".dockerignore", ".npmignore", ".prettierignore", ".eslintignore", ".gcloudignore", ".slugignore", ".hgignore",
                  ".vscodeignore", ".helmignore", ".stylelintignore", ".ignore", ".rgignore", ".fdignore", ".cvsignore", ".bzrignore",
                  ".terraformignore", ".vercelignore", ".funcignore", ".cfignore"], symbol: "eye.slash"),
        // Science, hardware & graphics
        e("latex", "LaTeX", ["tex", "ltx", "sty", "cls", "dtx", "ins", "bib", "bbx", "cbx"], symbol: "function"),
        e("matlab", "MATLAB", ["matlab"], symbol: "function"),
        e("mathematica", "Mathematica", ["nb", "wl", "wls", "mt"], symbol: "function"),
        e("maxima", "Maxima", ["wxm"], symbol: "function"),
        e("scilab", "Scilab", ["sci", "sce"], symbol: "function"),
        e("stan", "Stan", ["stan"], symbol: "function"),
        e("gams", "GAMS", ["gms"], symbol: "function"),
        e("gauss", "GAUSS", ["gss"], symbol: "function"),
        e("mizar", "Mizar", ["miz"], symbol: "function"),
        e("q", "Q", ["q"]),
        e("stata", "Stata", ["do", "ado"]),
        e("sas", "SAS", ["sas"]),
        e("fortran", "Fortran", ["f", "for", "ftn", "f77", "f90", "f95", "f03", "f08", "f18", "fpp"]),
        e("ada", "Ada", ["ada", "adb", "ads", "gpr"]),
        e("delphi", "Pascal", ["pas", "dpr", "dpk", "lpr"]),
        e("vbnet", "Visual Basic", ["vb", "bas", "frm", "vba"]),
        e("smalltalk", "Smalltalk", ["st"]),
        e("prolog", "Prolog", ["pro", "prolog"]),
        e("sml", "Standard ML", ["sml", "sig", "fun"]),
        e("clean", "Clean", ["icl", "dcl"]),
        e("flix", "Flix", ["flix"]),
        e("verilog", "Verilog", ["v", "vh", "sv", "svh"]),
        e("vhdl", "VHDL", ["vhd", "vhdl"]),
        e("x86asm", "Assembly", ["asm", "nasm", "s", "inc"]),
        e("armasm", "ARM Assembly", ["arm"]),
        e("llvm", "LLVM IR", ["ll"]),
        e("smali", "Smali", ["smali"]),
        e("glsl", "GLSL", ["glsl", "vert", "frag", "geom", "tesc", "tese", "comp", "vsh", "fsh", "gsh", "vs", "fragsh", "vertex", "fragment", "geometry",
                           "rgen", "rchit", "rmiss", "rahit", "rint", "rcall", "shader"]),
        e("glsl", "Godot Shader", ["gdshader"]),
        e("rsl", "RenderMan Shader", ["rsl", "sl"]),
        e("rib", "RenderMan RIB", ["rib"]),
        e("mel", "MEL", ["mel"]),
        e("cpp", "Graphviz", ["gv"]),
        e("gcode", "G-code", ["gcode", "nc", "gco", "ngc"]),
        e("openscad", "OpenSCAD", ["scad"]),
        e("gherkin", "Gherkin", ["feature"]),
        e("abnf", "ABNF", ["abnf"]),
        e("bnf", "BNF", ["bnf"]),
        e("ebnf", "EBNF", ["ebnf"]),
        // Games, platforms & others
        e("haxe", "Haxe", ["hx", "hxml"]),
        e("gml", "GameMaker", ["gml"]),
        e("processing", "Processing", ["pde"]),
        e("qml", "QML", ["qml", "qbs", "qmlproject"]),
        e("lsl", "LSL", ["lsl"]),
        e("sqf", "SQF", ["sqf"]),
        e("monkey", "Monkey", ["monkey", "monkey2"]),
        e("purebasic", "PureBasic", ["pbi"]),
        e("hsp", "HSP", ["hsp"]),
        e("livecodeserver", "LiveCode", ["lc", "livecodescript"]),
        e("lasso", "Lasso", ["lasso", "lasso9"]),
        e("inform7", "Inform 7", ["ni", "i7x"]),
        e("1c", "1C:Enterprise", ["bsl"]),
        e("axapta", "X++", ["xpp"]),
        e("cal", "AL", ["al"]),
        e("arcade", "Arcade", ["arcade"]),
        e("xl", "XL", ["xl"]),
        e("brainfuck", "Brainfuck", ["bf"]),
        e("javascript", "Solidity", ["sol"]),
        // Text
        e("asciidoc", "AsciiDoc", ["adoc", "asciidoc"], symbol: "doc.richtext"),
        e("plaintext", "reStructuredText", ["rst"], symbol: "doc.richtext"),
        e("plaintext", "Org", ["org"], symbol: "doc.richtext"),
        e("plaintext", "ASCII Armor", ["asc"], symbol: "lock.doc"),
        e("diff", "Diff", ["diff", "patch", "rej"], symbol: "plus.forwardslash.minus"),
        e("plaintext", "Log", ["log", "out", "err"], symbol: "list.bullet.rectangle"),
        e("plaintext", "Crash Report", ["crash"], symbol: "exclamationmark.triangle"),
        e("plaintext", "Plain Text", ["txt", "text", "me", "1st", "nfo", "srt", "vtt", "license", "lic"],
          files: ["license", "licence", "copying", "authors", "contributors", "notice", "readme", "changelog", "changes", "todo", "version"], symbol: "doc.plaintext"),
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

    /// Distinct languages Greece names (for Settings).
    public static var languageCount: Int { Set(entries.map(\.name)).count }

    /// File extensions Greece recognises (for Settings).
    public static var extensionCount: Int { byExtension.count }
}
