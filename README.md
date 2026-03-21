# Greece: Preview Files

**A better look at your files.**

Greece extends Finder's Quick Look with rich preview capabilities for every file type. Press Space on any file to instantly preview it with beautiful, native rendering.

Built natively for macOS with Swift. No analytics, no tracking, no accounts. Zero data collected.

---

## Features

### Markdown Preview
- GitHub Flavored Markdown with tables, task lists, and alerts
- KaTeX math formulas (inline `$...$` and block `$$...$$`)
- Mermaid diagrams
- Auto-generated table of contents with active heading highlight
- Emoji shortcodes, syntax-highlighted code blocks with copy button
- TextBundle support
- Remote image caching
- Scroll position memory

### Source Code Highlighting
- **190+ programming languages** with syntax highlighting
- Auto language detection from file content and shebang lines
- Auto-formatting for JSON, CSS, JavaScript, XML, SVG, plist
- Optional line numbers, word wrap, and custom tab width
- Custom fonts, sizes, and weights
- Independent light and dark themes
- Progressive rendering for large files

### Data Format Previews
- **CSV/TSV** rendered as native tables with sortable columns, resizable headers, alternating row colors
- **SQLite** databases with multi-table tab switching and column type/constraint tooltips
- **Diff/Patch** files with color-coded additions (green) and removals (red)

### Archive & Directory Browser
- Browse **ZIP, TAR, GZ, BZ2** contents without extracting
- Pure Swift binary parsing (no shell commands)
- Directory tree with sortable columns and file metadata
- **Folder preview** with Spotlight metadata and Finder tag support

### Fully Customizable
- Independent light and dark themes for Markdown and code
- Custom fonts, sizes, and weights for both Markdown and code
- Scroll position memory across previews
- Remote image caching for Markdown files
- Configurable metadata bar showing file size, dates, and type
- Per-format controls so each preview looks exactly the way you want

---

## Privacy

Greece runs entirely on your device. No analytics, no tracking, no accounts. The only network activity occurs when:
- A Markdown file references a remote image (fetched directly from source, not through any intermediary)
- highlight.js/KaTeX/Mermaid libraries are loaded from CDN for rendering

---

## Project Structure

```
Greece/
├── project.yml                          # XcodeGen project configuration
├── Shared/                              # Shared code between app and extension
│   ├── Constants.swift                  # App group ID, keys, file categories, limits
│   ├── Settings.swift                   # UserDefaults wrapper with all preferences
│   ├── ThemeManager.swift               # Theme definitions and system appearance detection
│   └── FileTypeDetector.swift           # File category detection (extension, UTI, content)
├── Greece/                                # Main application (Settings UI)
│   ├── App/
│   │   ├── GreeceApp.swift                # SwiftUI app entry point
│   │   ├── Info.plist                   # App Info.plist
│   │   └── Greece.entitlements            # Sandbox + App Group entitlements
│   ├── Views/
│   │   └── SettingsView.swift           # Full settings UI (General, Markdown, Code, Data, Archives, Folders)
│   └── Assets.xcassets/                 # App icon and accent color
├── GreeceQuickLook/                       # Quick Look Extension
│   ├── PreviewViewController.swift      # Extension entry point & router
│   ├── Info.plist                       # Extension Info.plist with 190+ UTI declarations
│   ├── GreeceQuickLook.entitlements       # Extension entitlements
│   ├── Renderers/
│   │   ├── MarkdownRenderer.swift       # GFM + KaTeX + Mermaid + TOC + Alerts + Emoji
│   │   ├── SourceCodeRenderer.swift     # 190+ languages, line numbers, auto-format
│   │   ├── CSVRenderer.swift            # Native NSTableView with sorting
│   │   ├── SQLiteRenderer.swift         # Multi-table with column metadata tooltips
│   │   ├── DiffRenderer.swift           # Color-coded unified diff
│   │   ├── ArchiveRenderer.swift        # NSOutlineView tree browser
│   │   └── FolderRenderer.swift         # Directory tree with Spotlight metadata & tags
│   ├── Parsers/
│   │   ├── LanguageDetector.swift       # 190+ extension map, shebang, filename detection
│   │   ├── ZIPParser.swift              # Pure Swift ZIP central directory parser
│   │   └── TARParser.swift              # Pure Swift TAR/GZ/BZ2 parser
│   └── Views/
│       └── MetadataBarView.swift        # Bottom bar: size, date, file type
└── README.md
```

---

## Building

### Prerequisites
- macOS 14.0+ (Sonoma)
- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for generating .xcodeproj)

### Using XcodeGen

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
cd Greece
xcodegen generate

# Open in Xcode
open Greece.xcodeproj
```

### Manual Xcode Setup

If you prefer not to use XcodeGen:

1. Open Xcode → File → New → Project
2. Choose macOS → App
3. Add a new Quick Look Extension target
4. Add all source files to the appropriate targets
5. Configure the App Group (`group.com.scorchy.greece`) in both targets
6. Set the deployment target to macOS 14.0

### Building & Running

1. Select the **Greece** scheme in Xcode
2. Build & Run (⌘R)
3. The main app opens the Settings window
4. Enable the Quick Look extension:
   - System Settings → Privacy & Security → Extensions → Quick Look
   - Toggle **Greece Quick Look** on
5. Navigate to any supported file in Finder and press **Space**

---

## Supported File Types

| Category | Formats |
|----------|---------|
| Markdown | `.md`, `.markdown`, `.mdown`, `.mkd`, `.rmd`, `.qmd`, `.textbundle` |
| Source Code | 190+ languages including Swift, Python, Rust, Go, TypeScript, Kotlin, etc. |
| Data | `.csv`, `.tsv`, `.sqlite`, `.sqlite3`, `.db`, `.diff`, `.patch` |
| Archives | `.zip`, `.tar`, `.gz`, `.tgz`, `.bz2`, `.tbz2`, `.tar.gz`, `.tar.bz2` |
| Folders | Any directory in Finder |
| Config | `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.plist`, `.xml` |

---

## Themes

### Markdown Themes
GitHub Light/Dark, Solarized Light/Dark, Nord, Dracula, One Light/Dark, Monokai, Gruvbox Light/Dark

### Code Themes
Xcode, GitHub, Visual Studio, Atom One Light/Dark, Monokai, Dracula, Nord, Solarized, VS 2015 Dark, Tokyo Night, Catppuccin Mocha, and more

---

## Architecture Notes

- **Pure Swift binary parsers**: ZIP and TAR archives are parsed without shell commands or external tools
- **WKWebView rendering**: Markdown, source code, and diff files use WKWebView with inline HTML/CSS/JS
- **Native AppKit**: CSV, SQLite, archives, and folders use native `NSTableView` / `NSOutlineView`
- **App Group sharing**: Settings are shared between the main app and extension via `UserDefaults(suiteName:)`
- **Sandboxed**: Both app and extension run in the macOS sandbox with minimal permissions

---

© 2026 Scorchy. All rights reserved.
