# Writing a format module

A module adds a family of formats to Greece (apps and binaries, 3D models, maps, fonts…) with its own detection, preview and Finder thumbnail, without touching the rest of the engine.

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Swift module | `GreeceKit/Sources/Modules/<Name>/` | A type conforming to `PreviewModule` (see `Modules/PreviewModule.swift`): `claims`, `prepare`, `thumbnail` |
| Registration | `PreviewModules.all` in `PreviewModule.swift` | One line: `<Name>Module.self` |
| Web renderer (optional) | `GreeceKit/Resources/Web/modules/<name>.js` / `.css` | Registers `greece.register('<kind>', (data, kit) => …)` |
| Vendored libraries (optional) | `GreeceKit/Resources/Web/vendor/<lib>/` | Minified builds plus their licence in `GreeceKit/Resources/Licenses/` |
| Types | `Types/preview/<name>.txt`, `Types/thumbnails/<name>.txt`, `Types/declarations/<name>.plist` | Content types to claim; declarations for extensions macOS doesn't know. Then run `scripts/sync-types.py` |
| Tests | `GreeceKitTests/<Name>Tests.swift` | Detection, parsing, malformed and hostile input |
| Fixtures | `Fixtures/<name>/` | Small sample files for tests and visual checks (not shipped in the app) |

`project.yml` picks up new folders by itself. After adding files, run `xcodegen generate`.

## The contract

- **`claims(_ file:)`** runs for every file Quick Look shows, so it has to be cheap: the extension, the lowercased name, and the first 8 KB in `file.probe`. Prefer magic bytes over extensions. Claim only what you're sure of, because modules run before Greece's generic text detection.
- **`prepare(_:settings:)`** runs off the main thread. Read and parse here, with hard limits on everything: file size read, entries listed, nesting depth, and time for anything that could be slow. Return either:
  - `.web(WebDocument(module: .init("<kind>"), data: <Encodable>, scripts: ["modules/<name>.js"], styles: ["modules/<name>.css"]), summary, preferredSize)`, or
  - `.native(summary, preferredSize) { settings in <NSView> }` for AppKit views. Conform the view to `PreviewSettingsAware` to restyle on setting changes.
  - Reusable cases: `.tree(FileNode, …)` (file listings), `.table(DelimitedTable, …)`.
- **`FileSummary`** is the info bar: an SF Symbol, a title ("Font", "3D Model"), facts ("12,480 triangles", "4 layers") and the modified date (`file.modifiedText`).
- **`thumbnail(_:size:settings:)`** draws natively (AppKit/Core Graphics), with no web view. Return nil to leave the file to macOS. Pages use `Thumbnailer.pageSize(fitting:)`; images such as a model render or a map can use their own aspect.

## Web renderers

- `kit.data()` is your module's data. Other parts of `kit` include:
  - `esc` (HTML escaping)
  - `highlight(text, grammar)`
  - `markdownDocument(text, {container, outline})`
  - `katexHTML`
  - `notice`, `empty`, `copyText`, `post('log', …)`
  - `onApply(fn)` (theme and appearance changes)
  - `root` (`<main>`)
- **Reading files**:
  - Set `document.readableDirectory` (usually the file's own folder) and the page can `fetch('greece://file' + absolutePath)` any file inside it: the file itself, a glTF's buffers and textures, a shapefile's `.dbf`.
  - Fonts and images there work in CSS too.
- **Data on demand**: set `document.resources = { path in … }` (runs off the main thread) and the page can fetch `greece://module/<path>`. Use it for map tiles, archive members and database pages. Never ship large data through `data`.
- The page has a strict CSP: scripts only from the bundle; no network unless the user enabled remote images; no inline script. Set `allowsWasm` on the document if you ship a WebAssembly decoder.
- Never put file contents into HTML without `esc` or `kit.sanitize`. File names, metadata and strings are all hostile input.
- Workers must be blob workers whose code is fetched from `greece://asset/…` (see `highlightInSegments` in `greece.js`).

## Design

Greece should feel like part of macOS, and as polished as Apple's own apps:
- **Typography:** system fonts (`var(--ui)`, `var(--read-font)`, `var(--code-font)`).
- **Colour:**
  - System semantic colours (`--text`, `--text-2`, `--hairline`, `--fill`, `--accent`).
  - Hairline separators, generous whitespace, no heavy borders or web-style chrome.
  - Light and dark must both look intentional.
- **Native views** use AppKit controls with system colours, SF Symbols and standard metrics. `SQLiteBrowser.swift` and `FileTreeView.swift` are the reference.
- **Reading pages** follow `.doc` / `article` in `greece.css`.
- **Interactivity is calm:** hover states, keyboard support, no animations longer than 200 ms.
- **First paint within a few hundred milliseconds.** Stream or page anything large.
- **Copy is plain and specific:** "12 tables", not "Database contains 12 tables". No exclamation marks.

## Checking your work

```sh
xcodegen generate
xcodebuild -project Greece.xcodeproj -scheme Greece -configuration Debug -derivedDataPath build/dd build
APP=build/dd/Build/Products/Debug/Greece.app
scripts/render.sh $APP /tmp/out Fixtures/<name>/*          # PNG of each preview, through the Quick Look code path
$APP/Contents/MacOS/Greece --thumbnail <file> /tmp/t.png --size 256
xcodebuild … test                                          # all tests, including type-list sync
```

Look at every PNG, in light and dark (`--appearance dark`). A preview isn't done until it looks right.

## Enhancers

To add features to an existing kind of page without editing `greece.js`, put
`GreeceKit/Resources/Web/enhancers/<kind>-<feature>.js` (and optionally `.css`) in the bundle. Examples: `code-tools.js`, `markdown-tabs.js`. `<kind>` is `code`, `markdown`, `diff`, `notebook`, a module's kind, or `all`. Each feature gets its own file, so features never edit the same file.
- Pages of that kind load them automatically.
- Register with `greece.enhance('<kind>', async (root, kit) => { … })`.
- Enhancers run after the page has rendered and before it's shown. A failing enhancer is logged and skipped.
- To add Markdown syntax, push a markdown-it plugin to `greece.markdownPlugins` when the script loads (`greece.markdownPlugins.push((md) => …)`). Every Markdown renderer uses it: pages, notebooks and modules' prose.
