import XCTest
@testable import GreeceKit

/// The language catalog: special file names, borrowed grammars and the bundled highlight.js grammars.
final class LanguageTests: XCTestCase {

    /// Bundled grammars no file maps to, and why.
    private let withoutFiles: [String: String] = [
        "markdown": "Markdown files open in the Markdown renderer",
        "python-repl": "REPL transcript, only inside documents",
        "node-repl": "REPL transcript, only inside documents",
        "julia-repl": "REPL transcript, only inside documents",
        "clojure-repl": "REPL transcript, only inside documents",
        "erlang-repl": "REPL transcript, only inside documents",
        "csp": "Content-Security-Policy header values, not files",
        "excel": "spreadsheet formulas, not files",
        "profile": "Python profiler output, printed rather than saved",
        "fix": "FIX protocol messages live in logs without an extension of their own",
        "subunit": "a test result stream, not saved under an extension",
        "tap": "TAP output has no extension; .tap is a binary tape image",
        "ruleslanguage": "Oracle rules live inside the product",
        "isbl": "ISBL scripts live inside Directum",
        "taggerscript": "Picard scripts live in its settings",
        "crmsh": "Pacemaker configuration is typed at the cluster shell",
        "dsconfig": "LDAP server commands, typed at a shell",
        "roboconf": ".graph and .instances are too generic to claim",
        "actionscript": "macOS types .as as an AppleSingle archive",
        "angelscript": "uses .as too, an AppleSingle archive on macOS",
        "basic": ".bas belongs to Visual Basic modules",
        "avrasm": ".asm and .s belong to x86 Assembly",
        "mipsasm": ".asm and .s belong to x86 Assembly",
        "coq": ".v belongs to Verilog",
        "mercury": ".m belongs to Objective-C",
        "oxygene": ".pas belongs to Pascal",
        "cos": "ObjectScript's .cls and .mac belong to LaTeX and others",
        "parser3": ".p is shared with Pascal and OpenEdge",
        "tp": "FANUC programs are .ls (LiveScript) or binary .tp",
        "irpf90": ".irp.f files reach the catalog as Fortran .f",
        "nestedtext": ".nt is shared with N-Triples RDF",
        "step21": "STEP files belong to the 3D model module",
    ]

    func testEveryBundledGrammarIsUsedOrExplained() {
        let bundled = WebAssets.bundledGrammars
        XCTAssertFalse(bundled.isEmpty, "no grammars in the bundle")
        for grammar in bundled.sorted() where withoutFiles[grammar] == nil {
            XCTAssertTrue(LanguageCatalog.allGrammars.contains(grammar), "\(grammar) has no files and no reason in withoutFiles")
        }
        for grammar in withoutFiles.keys.sorted() {
            XCTAssertTrue(bundled.contains(grammar), "\(grammar) is listed but not bundled")
            XCTAssertFalse(LanguageCatalog.allGrammars.contains(grammar), "\(grammar) is used by the catalog; drop it from withoutFiles")
        }
    }

    func testTableKeys() {
        for name in LanguageCatalog.byFileName.keys {
            XCTAssertEqual(name, name.lowercased(), "file names are matched lowercased")
        }
        for ext in LanguageCatalog.byExtension.keys {
            XCTAssertEqual(ext, ext.lowercased())
            // A path extension is only the last component, so "app.src" could never match.
            XCTAssertFalse(ext.contains("."), "\(ext) can never match")
        }
    }

    func testSpecialFileNames() {
        let expected: [(String, String)] = [
            ("Brewfile", "ruby"), ("Podfile", "ruby"), ("Vagrantfile", "ruby"), ("Gemfile", "ruby"), ("Fastfile", "ruby"),
            ("Dangerfile", "ruby"), ("Puppetfile", "ruby"), ("Cartfile", "ruby"), ("Cartfile.resolved", "ruby"), (".irbrc", "ruby"),
            ("Jenkinsfile", "groovy"), ("Jenkinsfile.release", "groovy"),
            ("Justfile", "makefile"), ("Kbuild", "makefile"), ("Makefile.in", "makefile"), ("Makefile.PL", "perl"),
            ("Tiltfile", "python"), ("BUILD.bazel", "python"), ("MODULE.bazel", "python"), ("BUCK", "python"), ("meson.build", "python"), (".pythonrc", "python"),
            ("Caddyfile", "nginx"), ("Corefile", "nginx"), ("nginx.conf", "nginx"), ("mime.types", "nginx"),
            ("Procfile", "yaml"), ("Procfile.dev", "yaml"), ("Podfile.lock", "yaml"), (".clangd", "yaml"), ("Gemfile.lock", "ruby"),
            ("Package.resolved", "json"), ("Pipfile.lock", "json"), (".swift-format", "json"),
            ("Pipfile", "ini"), ("Cargo.lock", "ini"), (".gitconfig", "ini"), (".gitmodules", "ini"), (".editorconfig", "ini"), (".npmrc", "ini"),
            ("COMMIT_EDITMSG", "ini"), ("git-rebase-todo", "ini"),
            ("CODEOWNERS", "properties"), (".gitattributes", "properties"), (".tool-versions", "properties"), ("sshd_config", "properties"), ("ssh_config", "properties"),
            (".bashrc", "bash"), (".zshrc", "bash"), (".profile", "bash"), (".bash_logout", "bash"), (".xinitrc", "bash"), (".Renviron", "bash"),
            (".env", "bash"), (".env.production", "bash"), (".tmux.conf", "bash"), ("crontab", "bash"), ("Kconfig", "bash"), (".swiftformat", "bash"),
            ("Dockerfile", "dockerfile"), ("Dockerfile.dev", "dockerfile"), ("Containerfile", "dockerfile"), ("Earthfile", "dockerfile"),
            (".vimrc", "vim"), (".ideavimrc", "vim"), (".Rprofile", "r"), (".emacs", "lisp"), ("dune", "lisp"),
            ("pf.conf", "pf"), ("access.log", "accesslog"), ("CMakeLists.txt", "cmake"), ("Package.swift", "swift"), ("go.mod", "go"),
            (".gitignore", "plaintext"), (".mailmap", "plaintext"), ("LICENSE", "plaintext"),
        ]
        for (name, grammar) in expected {
            XCTAssertEqual(LanguageCatalog.language(forFileName: name)?.grammar, grammar, name)
        }
        XCTAssertNil(LanguageCatalog.language(forFileName: "notes"))
        XCTAssertNil(LanguageCatalog.language(forFileName: ".envoy.yaml"), "only .env and .env.* are environment files")
        XCTAssertEqual(LanguageCatalog.language(forFileName: "Caddyfile")?.name, "Caddyfile")
        XCTAssertEqual(LanguageCatalog.language(forFileName: "CODEOWNERS")?.name, "Code Owners")
    }

    func testExtensions() {
        let expected: [(String, String, String)] = [
            ("zig", "rust", "Zig"), ("gleam", "rust", "Gleam"), ("odin", "go", "Odin"), ("cue", "go", "CUE"),
            ("tf", "ini", "Terraform"), ("hcl", "ini", "HCL"), ("prisma", "typescript", "Prisma"), ("bicep", "typescript", "Bicep"),
            ("jsonnet", "javascript", "Jsonnet"), ("pkl", "swift", "Pkl"), ("mojo", "python", "Mojo"), ("gd", "python", "GDScript"),
            ("bzl", "python", "Starlark"), ("nu", "bash", "Nushell"), ("gv", "cpp", "Graphviz"), ("purs", "haskell", "PureScript"),
            ("res", "reasonml", "ReScript"), ("vbs", "vbscript", "VBScript"), ("asp", "vbscript-html", "ASP"), ("phtml", "php-template", "PHP Template"),
            ("ino", "arduino", "Arduino"), ("strings", "c", "Strings"), ("xcconfig", "ini", "Xcode Config"), ("xcstrings", "json", "String Catalog"),
            ("ahk", "autohotkey", "AutoHotkey"), ("qml", "qml", "QML"), ("xq", "xquery", "XQuery"), ("ldif", "ldif", "LDIF"),
            ("smali", "smali", "Smali"), ("nsi", "nsis", "NSIS"), ("sh-session", "shell", "Shell Session"), ("y", "cpp", "Yacc"),
        ]
        for (ext, grammar, name) in expected {
            let language = LanguageCatalog.language(forExtension: ext)
            XCTAssertEqual(language?.grammar, grammar, ext)
            XCTAssertEqual(language?.name, name, ext)
        }
    }

    func testShebangs() {
        func grammar(_ firstLine: String) -> String? { LanguageCatalog.language(sniffing: (firstLine + "\n")[...])?.grammar }
        XCTAssertEqual(grammar("#!/usr/bin/env -S uv run --script"), "python")
        XCTAssertEqual(grammar("#!/usr/bin/env ts-node"), "typescript")
        XCTAssertEqual(grammar("#!/usr/bin/env node"), "javascript")
        XCTAssertEqual(grammar("#!/usr/bin/make -f"), "makefile")
        XCTAssertEqual(grammar("#!/usr/bin/env raku"), "perl")
        XCTAssertEqual(LanguageCatalog.language(sniffing: "#!/usr/bin/env raku\n")?.name, "Raku")
        XCTAssertEqual(grammar("#compdef git"), "bash")
        XCTAssertEqual(grammar("#!/bin/sh"), "bash")
        XCTAssertNil(grammar("Just some notes"))
    }
}
