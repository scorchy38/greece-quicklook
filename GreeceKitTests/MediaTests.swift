import XCTest
import UniformTypeIdentifiers
@testable import GreeceKit

/// Fonts, subtitles, SVG, Lottie and palettes: detection, parsing, limits and hostile input.
final class MediaTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private var fixtures: URL { repo.appendingPathComponent("Fixtures/media") }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ path: String) -> URL { fixtures.appendingPathComponent(path) }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func file(_ name: String, data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func format(_ url: URL) -> MediaFormat? { MediaFormat.detect(FileInfo(url: url)) }

    private func web(_ prepared: PreparedPreview) throws -> (WebDocument, FileSummary) {
        guard case .web(let document, let summary, _) = prepared else { throw XCTSkip("not a web preview") }
        return (document, summary)
    }

    // MARK: - Detection

    func testFixturesAreDetected() throws {
        let expected: [String: MediaFormat] = [
            "fonts/Inter-Variable.woff2": .font, "fonts/Inter-Display-Bold.woff": .font, "fonts/Inter-Pair.ttc": .font, "fonts/GreeceIcons.woff2": .font,
            "subtitles/Ferry.srt": .subtitles(.srt), "subtitles/Ferry.vtt": .subtitles(.webvtt), "subtitles/Ferry.ass": .subtitles(.ass),
            "subtitles/Ferry.smi": .subtitles(.sami), "subtitles/Ferry.ttml": .subtitles(.ttml), "subtitles/Ferry.sbv": .subtitles(.sbv),
            "subtitles/Ferry.sub": .subtitles(.microdvd), "subtitles/Harbour Song.lrc": .subtitles(.lrc),
            "svg/Santorini.svg": .svg(compressed: false), "svg/Santorini.svgz": .svg(compressed: true), "svg/Hostile.svg": .svg(compressed: false),
            "lottie/Lighthouse.json": .lottie(packaged: false), "lottie/Harbour.lottie": .lottie(packaged: true),
            "palettes/Aegean.ase": .palette(.ase), "palettes/Aegean.aco": .palette(.aco), "palettes/Aegean.act": .palette(.act),
            "palettes/Aegean.gpl": .palette(.gpl), "palettes/Aegean.swatches": .palette(.procreate),
            "palettes/Aegean.sketchpalette": .palette(.sketch), "palettes/Harbor.clr": .palette(.clr),
        ]
        for (path, format) in expected {
            XCTAssertEqual(self.format(fixture(path)), format, path)
            XCTAssertEqual(FileKind.detect(fixture(path)), .module("media"), path)
        }
    }

    func testSystemFontsAreDetected() {
        XCTAssertEqual(format(URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")), .font)
        XCTAssertEqual(format(URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/AmericanTypewriter.ttc")), .font)
    }

    func testLookalikesAreLeftAlone() throws {
        // Ordinary JSON and XML stay with Greece's code view.
        XCTAssertEqual(FileKind.detect(try file("package.json", #"{"name":"x","version":"1.0.0","layers":[]}"#)), .json)
        XCTAssertNil(format(try file("feed.xml", "<?xml version=\"1.0\"?><rss><channel/></rss>")))
        // Binary VobSub .sub, Aseprite .ase, text that merely ends in .ttf: not ours.
        XCTAssertNil(format(try file("movie.sub", data: Data([0x00, 0x00, 0x01, 0xBA] + [UInt8](repeating: 0x44, count: 64)))))
        XCTAssertNil(format(try file("sprite.ase", data: Data([0x10, 0x20, 0x00, 0x00, 0xE0, 0xA5] + [UInt8](repeating: 0, count: 120)))))
        XCTAssertNil(format(try file("notes.ttf", "just some text")))
        XCTAssertNil(format(try file("plain.svgz", "<svg/>")))
        XCTAssertNil(format(try file("x.srt", "no timings in here at all")))
        XCTAssertNil(format(try file("x.gpl", "Not a GIMP palette")))
        // XML that is TTML is claimed by content.
        XCTAssertEqual(format(try file("captions.xml", #"<tt xmlns="http://www.w3.org/ns/ttml"><body/></tt>"#)), .subtitles(.ttml))
    }

    // MARK: - Fonts

    func testVariableWOFF2() throws {
        let info = try FontFileInfo(data: try Data(contentsOf: fixture("fonts/Inter-Variable.woff2")))
        XCTAssertEqual(info.container, .woff2)
        XCTAssertEqual(info.faces.count, 1)
        let face = info.faces[0]
        XCTAssertEqual(face.family, "Inter")
        XCTAssertEqual(face.variation.axes.map(\.tag), ["opsz", "wght"])
        XCTAssertEqual(face.variation.instances.count, 9)
        XCTAssertTrue(face.variation.instances.contains { $0.name == "Bold" && $0.coordinates["wght"] == 700 })
        let described = FontPreview.describe(face, codepoints: face.codepoints())
        XCTAssertEqual(described.hero, "Aa")
        XCTAssertEqual(described.sample, "The quick brown fox jumps over the lazy dog")
        XCTAssertEqual(described.scripts.first, "Latin")
        XCTAssertFalse(described.icon)
        let tags = described.features.map(\.tag)
        for tag in ["ss01", "cv11", "tnum", "frac", "case", "zero"] { XCTAssertTrue(tags.contains(tag), tag) }
        XCTAssertFalse(tags.contains("locl"), "shaping features aren't choices")
        // Stylistic sets carry their own names; demos show the letters they change.
        let ss02 = try XCTUnwrap(described.features.first { $0.tag == "ss02" })
        XCTAssertEqual(ss02.name, "Disambiguation")
        XCTAssertFalse(ss02.sample.isEmpty)
        XCTAssertLessThanOrEqual(ss02.sample.count, 12)
        XCTAssertTrue(described.features.first { $0.tag == "kern" }?.on ?? false)
        XCTAssertFalse(described.languages.isEmpty)
        XCTAssertFalse(described.characters == 0)
    }

    func testCollectionFacesAreCutOut() throws {
        let data = try Data(contentsOf: fixture("fonts/Inter-Pair.ttc"))
        let info = try FontFileInfo(data: data)
        XCTAssertEqual(info.container, .collection)
        XCTAssertEqual(info.faces.map(\.style), ["Regular", "ExtraBold"])
        // Each face's web bytes are a standalone font CoreText can read on its own.
        for face in info.faces {
            let bytes = try XCTUnwrap(face.webData)
            XCTAssertEqual(FontContainer.sniff([UInt8](bytes.prefix(16))), .sfnt)
            XCTAssertNotNil(CTFontManagerCreateFontDescriptorFromData(bytes as CFData))
            XCTAssertLessThan(bytes.count, data.count, "a face, not the whole collection")
        }
        XCTAssertEqual(info.title, "Font Collection")
        // Faces line up with the directory: each one's PostScript name matches its own name table.
        let reader = MediaReader(data)
        XCTAssertEqual(FontFile.faceOffsets(reader).map { FontFile.postScriptName(reader, at: $0) }, info.faces.map(\.postScriptName))
    }

    func testWOFFAndIconFonts() throws {
        let woff = try FontFileInfo(data: try Data(contentsOf: fixture("fonts/Inter-Display-Bold.woff")))
        XCTAssertEqual(woff.container, .woff)
        XCTAssertEqual(woff.faces[0].os2.weightClass, 700)

        let icons = try FontFileInfo(data: try Data(contentsOf: fixture("fonts/GreeceIcons.woff2")))
        let face = icons.faces[0]
        let codepoints = face.codepoints()
        XCTAssertEqual(codepoints.count, 12, "spaces and synthesised whitespace are left out")
        XCTAssertTrue(FontFaceInfo.isIconFont(codepoints))
        XCTAssertEqual(face.glyph(for: 0xE000).flatMap(face.glyphName), "sun")
        XCTAssertTrue(FontPreview.describe(face, codepoints: codepoints).icon)
    }

    func testFontResourcesServeFacesGlyphsAndDetails() throws {
        let prepared = try MediaModule.prepare(FileInfo(url: fixture("fonts/Inter-Variable.woff2")), settings: PreviewSettings())
        let (document, summary) = try web(prepared)
        XCTAssertEqual(summary.title, "WOFF2 Font")
        XCTAssertTrue(document.html(settings: PreviewSettings()).contains("modules/media.fonts.js"))
        let resources = try XCTUnwrap(document.resources)
        XCTAssertEqual(resources("face/0")?.mimeType, "font/woff2")
        XCTAssertNil(resources("face/7"))
        XCTAssertNil(resources("face/../../etc/passwd"))
        let glyphs = try XCTUnwrap(resources("glyphs/0"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: glyphs.data) as? [String: Any])
        XCTAssertEqual((json["sections"] as? [[String: Any]])?.first?["name"] as? String, "Basic Latin")
        let detail = try XCTUnwrap(resources("glyph/0/0041"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: detail.data) as? [String: Any])
        XCTAssertEqual(decoded["name"] as? String, "LATIN CAPITAL LETTER A")
        XCTAssertEqual(decoded["glyph"] as? String, "A")
        XCTAssertNil(resources("glyph/0/ZZZZ"))
    }

    func testMalformedFontsFailCleanly() throws {
        let real = try Data(contentsOf: fixture("fonts/Inter-Pair.ttc"))
        let attempts: [Data] = [
            Data("OTTO".utf8) + Data(repeating: 0, count: 64),                     // no tables
            Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x05]) + Data(repeating: 0xFF, count: 200), // tables pointing nowhere
            Data("ttcf".utf8) + Data([0, 1, 0, 0, 0, 0, 0x0F, 0xFF]) + Data(repeating: 0xEE, count: 64), // 4095 faces, all bogus
            Data("wOF2".utf8) + Data(repeating: 0x41, count: 300),                    // corrupt WOFF2
            real.prefix(real.count / 3),                                             // truncated collection
            Data(),
        ]
        for data in attempts {
            XCTAssertThrowsError(try FontFileInfo(data: data))
        }
        // The table readers never read out of bounds, whatever the offsets say.
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) })
        _ = FontTables.Name(garbage)
        _ = FontTables.Variation(garbage, names: FontTables.Name(nil))
        _ = FontTables.OS2(garbage)
        _ = FontTables.Head(garbage)
        if let layout = FontTables.Layout(Data([0, 1, 0, 0, 0, 10, 0, 10, 0, 10]) + garbage) {
            for feature in layout.features { _ = layout.inputs(of: feature) }
        }
        XCTAssertNil(FontFile.extractFace(MediaReader(garbage), at: 0))
    }

    func testFontLinksAreWebOnly() {
        XCTAssertEqual(FontPreview.webLink("https://rsms.me"), "https://rsms.me")
        XCTAssertEqual(FontPreview.webLink("www.example.com"), "https://www.example.com")
        XCTAssertNil(FontPreview.webLink("javascript:alert(1)"))
        XCTAssertNil(FontPreview.webLink("file:///etc/passwd"))
        XCTAssertNil(FontPreview.webLink("Licensed under the OFL"))
    }

    // MARK: - Subtitles

    private func parse(_ path: String, _ format: SubtitleFormat) throws -> SubtitleDocument {
        var document = SubtitleParser.parse(try TextFile(url: fixture(path)).text, format: format)
        _ = SubtitleChecks.analyze(&document)
        return document
    }

    func testSubRip() throws {
        var document = SubtitleParser.parse(try TextFile(url: fixture("subtitles/Ferry.srt")).text, format: .srt)
        let stats = SubtitleChecks.analyze(&document)
        XCTAssertEqual(document.cues.count, 10)
        XCTAssertEqual(document.cues[0].start, 1200)
        XCTAssertEqual(document.cues[0].end, 3800)
        XCTAssertEqual(document.cues[0].id, "1")
        XCTAssertEqual(document.cues[1].spans?.first, SubtitleCue.Span(t: "Kalimera.", f: 1))
        XCTAssertEqual(document.cues[4].text, "PIRAEUS PORT · GATE E7", "positioning tags are dropped")
        XCTAssertEqual(document.cues[2].text, "Deck or cabin?\n- Deck. We want the sea air.")
        XCTAssertEqual(stats.fast, 2)
        XCTAssertEqual(stats.overlaps, 1)
        XCTAssertEqual(stats.longLines, 3)
        XCTAssertTrue(document.cues[3].flags & SubtitleChecks.Flag.fast.rawValue != 0)
        XCTAssertEqual(stats.end, 34000)
    }

    func testWebVTT() throws {
        let document = try parse("subtitles/Ferry.vtt", .webvtt)
        XCTAssertEqual(document.title, "The Morning Ferry")
        XCTAssertEqual(document.languages, ["en"])
        XCTAssertEqual(document.cues.count, 8, "STYLE and NOTE blocks aren't cues")
        XCTAssertEqual(document.cues[0].id, "intro")
        XCTAssertEqual(document.cues[1].speaker, "Eleni")
        XCTAssertEqual(document.cues[5].speaker, "Nikos")
        XCTAssertEqual(document.cues[5].text, "Look! Dolphins, right behind the stern!")
        XCTAssertEqual(document.cues[7].text, "Paros first, then Naxos and the Portara.", "karaoke timestamps are dropped")
    }

    func testSubStationAlpha() throws {
        let document = try parse("subtitles/Ferry.ass", .ass)
        XCTAssertEqual(document.title, "The Morning Ferry")
        XCTAssertEqual(document.cues.count, 7, "comments and drawings aren't dialogue")
        XCTAssertEqual(document.cues[1].style, "Sign")
        XCTAssertEqual(document.styleColors["Sign"], "#ffd700")
        XCTAssertEqual(document.cues[2].speaker, "Eleni")
        XCTAssertEqual(document.cues[3].text, "Deck or cabin?\nDeck. We want the sea air.")
        XCTAssertEqual(document.cues[6].spans?.contains(SubtitleCue.Span(t: "blue", f: 2)), true)
        XCTAssertEqual(document.cues[0].flags & SubtitleChecks.Flag.overlap.rawValue, 0)
        XCTAssertEqual(document.cues[1].flags & SubtitleChecks.Flag.overlap.rawValue, 0, "layered formats overlap on purpose")
    }

    func testSAMITTMLSBVMicroDVDAndLRC() throws {
        let sami = try parse("subtitles/Ferry.smi", .sami)
        XCTAssertEqual(sami.title, "The Morning Ferry")
        XCTAssertEqual(sami.languages, ["English", "Greek"])
        XCTAssertEqual(sami.cues.map(\.start), [1200, 4100, 7300, 9500])
        XCTAssertEqual(sami.cues[0].end, 3800)
        XCTAssertEqual(sami.cues[0].text, "The morning ferry leaves Piraeus at seven.", "only the first language")
        XCTAssertEqual(sami.cues[2].text, "Deck or cabin?\nDeck & sea air.")

        let ttml = try parse("subtitles/Ferry.ttml", .ttml)
        XCTAssertEqual(ttml.title, "The Morning Ferry")
        XCTAssertEqual(ttml.cues.count, 5)
        XCTAssertEqual(ttml.cues[1].speaker, "Eleni")
        XCTAssertEqual(ttml.cues[2].start, 7320, "frames at 25 fps")
        XCTAssertEqual(ttml.cues[2].end, 9520, "dur is relative to begin")
        XCTAssertEqual(ttml.cues[3].start, 9800)
        XCTAssertEqual(ttml.cues[2].text, "Deck or cabin?\nDeck. We want the sea air.")
        XCTAssertEqual(ttml.styleColors["yellow"], "#ffd60a")

        let sbv = try parse("subtitles/Ferry.sbv", .sbv)
        XCTAssertEqual(sbv.cues.count, 5)
        XCTAssertEqual(sbv.cues[4].end, 15400)

        let microdvd = try parse("subtitles/Ferry.sub", .microdvd)
        XCTAssertEqual(microdvd.frameRate, 25)
        XCTAssertEqual(microdvd.cues.count, 5)
        XCTAssertEqual(microdvd.cues[0].start, 1200)
        XCTAssertEqual(microdvd.cues[1].text, "Kalimera.\nTwo tickets to Naxos, please.")

        let lrc = try parse("subtitles/Harbour Song.lrc", .lrc)
        XCTAssertEqual(lrc.title, "Harbour Song")
        XCTAssertTrue(lrc.metadata.contains { $0.0 == "Artist" && $0.1 == "The Fixtures" })
        XCTAssertEqual(lrc.cues.count, 8, "one line with two times appears twice; the blank one is a pause")
        XCTAssertEqual(lrc.cues[2].text, "Salt in the evening, wind across the bay")
        XCTAssertEqual(lrc.cues.last?.end, 65000)
        XCTAssertTrue(lrc.cues.allSatisfy { $0.flags == 0 }, "reading speed doesn't apply to songs")
    }

    func testClockParsing() {
        XCTAssertEqual(SubtitleParser.clock("01:02:03,456"), 3_723_456)
        XCTAssertEqual(SubtitleParser.clock("1:02:03.45"), 3_723_450)
        XCTAssertEqual(SubtitleParser.clock("02:03.5"), 123_500)
        XCTAssertNil(SubtitleParser.clock("aa:bb:cc"))
        XCTAssertNil(SubtitleParser.clock("1:2:3:4:5"))
        XCTAssertNil(SubtitleParser.clock("99999999999999999999:00"))
        XCTAssertEqual(SubtitleParser.lrcTime("01:02.34"), 62_340)
        XCTAssertEqual(SubtitleParser.lrcTime("01:02:34"), 62_340)
        XCTAssertNil(SubtitleParser.lrcTime("ar:Someone"))
        XCTAssertEqual(SubtitleParser.assColor("&H0000D7FF"), "#ffd700")
        XCTAssertNil(SubtitleParser.assColor("&HZZZ"))
    }

    func testGiantSubtitlesAreCapped() {
        var text = ""
        text.reserveCapacity(9_000_000)
        for index in 0..<(SubtitleParser.cueLimit + 5000) {
            text += "\(index + 1)\n00:00:\(String(format: "%02d", index % 60)),000 --> 00:00:\(String(format: "%02d", index % 60)),900\nLine \(index)\n\n"
        }
        let start = Date()
        let document = SubtitleParser.parse(text, format: .srt)
        XCTAssertEqual(document.cues.count, SubtitleParser.cueLimit)
        XCTAssertTrue(document.truncated)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    func testHostileSubtitles() throws {
        // SubtitleMarkup is never kept as markup: tags are dropped or become formatting runs.
        let cue = SubtitleMarkup.cue("<script>alert(1)</script><img src=x onerror=alert(2)><i>ok</i> &lt;b&gt;", start: 0, end: 1000)
        XCTAssertEqual(cue.text, "alert(1)ok <b>")
        XCTAssertFalse(cue.text.contains("<script"))
        // Entity bombs in TTML are refused before parsing.
        let bomb = """
        <?xml version="1.0"?><!DOCTYPE tt [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="0s" end="1s">&c;</p></div></body></tt>
        """
        XCTAssertTrue(SubtitleParser.parse(bomb, format: .ttml).cues.isEmpty)
        // Deep nesting stops, with whatever was read.
        let deep = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body>" + String(repeating: "<div>", count: 5000) + "<p begin=\"0s\" end=\"1s\">x</p>" + String(repeating: "</div>", count: 5000) + "</body></tt>"
        _ = SubtitleParser.parse(deep, format: .ttml)
        // Garbage in every format: no crash, no cues out of thin air.
        let noise = String((0..<20000).map { _ in "<>{}[]:,.-\n\\0123456789 abc&;#".randomElement()! })
        for format in SubtitleFormat.allCases {
            let document = SubtitleParser.parse(noise, format: format)
            XCTAssertTrue(document.cues.allSatisfy { $0.start >= 0 }, "\(format)")
        }
        // Timings that run backwards are flagged, not trusted.
        var backwards = SubtitleParser.parse("1\n00:00:05,000 --> 00:00:02,000\nOops\n", format: .srt)
        let stats = SubtitleChecks.analyze(&backwards)
        XCTAssertEqual(stats.badTiming, 1)
    }

    func testSubtitlePreviewServesCuesOnDemand() throws {
        let (document, summary) = try web(try MediaModule.prepare(FileInfo(url: fixture("subtitles/Ferry.srt")), settings: PreviewSettings()))
        XCTAssertEqual(summary.title, "SubRip Subtitles")
        XCTAssertTrue(summary.details.contains("10 cues"))
        XCTAssertTrue(summary.details.contains("2 too fast"))
        let cues = try XCTUnwrap(document.resources?("cues.json"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: cues.data) as? [Any])?.count, 10)
        XCTAssertFalse(document.html(settings: PreviewSettings()).contains("Twenty-four euros"), "cues aren't embedded in the page")
    }

    // MARK: - SVG

    func testSVGSizes() {
        func size(_ root: String) -> (Double, Double) {
            let info = SVGPreview.inspect(Data(root.utf8))
            return (info.width, info.height)
        }
        XCTAssertTrue(size(#"<svg width="24" height="12"/>"#) == (24, 12))
        XCTAssertTrue(size(#"<svg viewBox="0 0 640 420"/>"#) == (640, 420))
        XCTAssertTrue(size(#"<svg width="320" viewBox="0 0 640 420"/>"#) == (320, 210))
        XCTAssertTrue(size(#"<svg width="1in" height="72pt"/>"#) == (96, 96))
        XCTAssertTrue(size(#"<svg width="100%" height="100%" viewBox="0,0,10,5"/>"#) == (10, 5))
        XCTAssertTrue(size(#"<svg/>"#) == (300, 150))
        XCTAssertTrue(size(#"<svg width="-5" height="NaN" viewBox="0 0 0 0"/>"#) == (300, 150))
        XCTAssertTrue(size(#"<?xml version="1.0"?><svg:svg xmlns:svg="http://www.w3.org/2000/svg" width='50' height='40'/>"#) == (50, 40))
        XCTAssertTrue(size(#"<svg width="1e999" height="20"/>"#) == (300, 20), "infinite sizes are ignored")
    }

    func testHostileSVGIsOnlyEverAnImage() throws {
        let (document, summary) = try web(try MediaModule.prepare(FileInfo(url: fixture("svg/Hostile.svg")), settings: PreviewSettings()))
        XCTAssertEqual(summary.title, "SVG Image")
        let html = document.html(settings: PreviewSettings())
        XCTAssertFalse(html.contains("postMessage"), "the markup never reaches the page")
        XCTAssertFalse(html.contains("onload"))
        XCTAssertTrue(html.contains("script-src greece://asset;"))
        XCTAssertNil(document.readableDirectory, "an SVG page can't read neighbouring files")
        let image = try XCTUnwrap(document.resources?("image.svg"))
        XCTAssertEqual(image.mimeType, "image/svg+xml")
        let info = SVGPreview.inspect(image.data)
        XCTAssertTrue(info.hasScripts)
        XCTAssertTrue(info.hasExternalReferences)
    }

    func testSVGZAndInflateLimits() throws {
        let plain = try Data(contentsOf: fixture("svg/Santorini.svg"))
        let expanded = try SVGPreview.load(FileInfo(url: fixture("svg/Santorini.svgz")), compressed: true)
        XCTAssertEqual(expanded, plain)
        // A gzip bomb stops at the limit.
        let zeros = Data(repeating: 0x20, count: 8 * 1024 * 1024)
        let bomb = try XCTUnwrap(gzip(zeros))
        XCTAssertLessThan(bomb.count, 100_000)
        XCTAssertNil(MediaInflate.inflate(bomb, windowBits: 15 + 32, limit: 1024 * 1024))
        XCTAssertEqual(MediaInflate.inflate(bomb, windowBits: 15 + 32, limit: 16 * 1024 * 1024)?.count, zeros.count)
        XCTAssertNil(MediaInflate.inflate(Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02, 0x03]), windowBits: 15 + 32, limit: 1024))
        let broken = try file("broken.svgz", data: Data([0x1F, 0x8B]) + Data(repeating: 0xAB, count: 100))
        XCTAssertThrowsError(try SVGPreview.load(FileInfo(url: broken), compressed: true))
    }

    func testSVGThumbnails() throws {
        let thumbnail = try XCTUnwrap(MediaModule.thumbnail(FileInfo(url: fixture("svg/Santorini.svgz")), size: CGSize(width: 256, height: 256), settings: PreviewSettings()))
        XCTAssertEqual(thumbnail.badge, "SVGZ")
        XCTAssertEqual(thumbnail.size.width, 256)
        XCTAssertEqual(thumbnail.size.height, 168)
        // Entity declarations are refused before CoreSVG sees them.
        let bomb = try file("bomb.svg", #"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaa">]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&a;</text></svg>"#)
        XCTAssertNil(MediaModule.thumbnail(FileInfo(url: bomb), size: CGSize(width: 64, height: 64), settings: PreviewSettings()))
    }

    private func gzip(_ data: Data) -> Data? {
        let input = try? file("bomb-source", data: data)
        let output = directory.appendingPathComponent("bomb.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", input!.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? result.write(to: output)
        return result.isEmpty ? nil : result
    }

    // MARK: - Lottie

    func testLottieJSON() throws {
        XCTAssertTrue(LottiePreview.looksLikeLottie(Array(try Data(contentsOf: fixture("lottie/Lighthouse.json")).prefix(8192))))
        let (payload, animations) = try LottiePreview.load(FileInfo(url: fixture("lottie/Lighthouse.json")), packaged: false)
        let animation = payload.animations[0]
        XCTAssertEqual(animation.name, "Lighthouse")
        XCTAssertEqual(animation.frameRate, 30)
        XCTAssertEqual(animation.duration, 3)
        XCTAssertEqual(animation.layers, 8)
        XCTAssertEqual(animation.markers.map(\.name), ["Sweep", "Return"])
        XCTAssertFalse(animation.hasExpressions)
        XCTAssertEqual(animations.count, 1)
        XCTAssertEqual(payload.generator, "Greece fixtures (hand-built)")
    }

    func testDotLottiePackagesEmbedTheirImages() throws {
        let (payload, animations) = try LottiePreview.load(FileInfo(url: fixture("lottie/Harbour.lottie")), packaged: true)
        XCTAssertEqual(payload.animations.map(\.id), ["lighthouse", "sun-pulse"])
        XCTAssertEqual(payload.generator, "Greece fixtures")
        let pulse = try XCTUnwrap(JSONSerialization.jsonObject(with: animations[1]) as? [String: Any])
        let asset = try XCTUnwrap((pulse["assets"] as? [[String: Any]])?.first)
        XCTAssertTrue((asset["p"] as? String)?.hasPrefix("data:image/png;base64,") ?? false)
        XCTAssertEqual(asset["e"] as? Int, 1)
    }

    func testNotLottieAndBrokenPackages() throws {
        XCTAssertFalse(LottiePreview.looksLikeLottie(Array(#"{"name":"x","layers":[]}"#.utf8)))
        XCTAssertFalse(LottiePreview.looksLikeLottie(Array(#"["v","fr","ip","op"]"#.utf8)))
        XCTAssertNil(LottiePreview.describe(Data(#"{"v":"5","fr":0,"ip":0,"op":10,"w":1,"h":1,"layers":[]}"#.utf8), id: "x"), "zero frame rate")
        XCTAssertNil(LottiePreview.describe(Data(#"{"v":"5","fr":30,"ip":10,"op":10,"w":1,"h":1,"layers":[]}"#.utf8), id: "x"), "no duration")
        let truncated = try Data(contentsOf: fixture("lottie/Harbour.lottie")).prefix(600)
        XCTAssertThrowsError(try LottiePreview.unpack(Data(truncated)))
        XCTAssertThrowsError(try LottiePreview.unpack(Data("PK\u{3}\u{4}nonsense".utf8)))
    }

    func testLottieRendererDrawsAFrame() throws {
        let json = try Data(contentsOf: fixture("lottie/Lighthouse.json"))
        let renderer = try XCTUnwrap(LottieRenderer(json: json))
        let frame = try XCTUnwrap(renderer.representativeFrame())
        XCTAssertTrue((0..<90).contains(frame))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(frame: frame, in: CGRect(x: 0, y: 0, width: 64, height: 64), context: context)
        // The sky fills the frame: the middle pixel is opaque.
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
        XCTAssertEqual(pixels[(32 * 64 + 32) * 4 + 3], 255)
        // Self-referencing precomps and parent loops end; nonsense values are ignored.
        let hostile = #"{"v":"5","fr":30,"ip":0,"op":10,"w":100,"h":100,"assets":[{"id":"p","layers":[{"ty":0,"refId":"p","ind":1,"parent":1,"ip":0,"op":10}]}],"layers":[{"ty":0,"refId":"p","ind":1,"parent":2,"ip":0,"op":10},{"ty":4,"ind":2,"parent":1,"ip":0,"op":10,"shapes":[{"ty":"gr","it":[{"ty":"sh","ks":{"k":{"v":[[0,0],"x",[1e308,1e308]],"i":[],"o":[],"c":true}}},{"ty":"fl","c":{"k":[1,0,0,1]},"o":{"k":100}}]}]}]}"#
        let renderer2 = try XCTUnwrap(LottieRenderer(json: Data(hostile.utf8)))
        renderer2.draw(frame: 5, in: CGRect(x: 0, y: 0, width: 64, height: 64), context: context)
    }

    // MARK: - Palettes

    private func palette(_ name: String, _ format: PaletteFormat) throws -> Palette {
        try PaletteParser.parse(try Data(contentsOf: fixture("palettes/" + name)), format: format)
    }

    func testAdobeSwatchExchange() throws {
        let palette = try palette("Aegean.ase", .ase)
        XCTAssertEqual(palette.count, 10)
        XCTAssertEqual(palette.groups.map(\.name), ["Island", "Print", nil], "groups keep the file's order")
        XCTAssertEqual(palette.groups[0].colors[0].name, "Aegean Blue")
        XCTAssertEqual(palette.groups[0].colors[0].hex, "#0d5eaf")
        XCTAssertEqual(palette.groups[1].colors.map(\.kind), ["Spot", "Spot"])
        XCTAssertEqual(palette.groups[1].colors[0].model, "CMYK")
        XCTAssertEqual(palette.groups[2].colors.map(\.model), ["Lab", "Gray"])
    }

    func testPhotoshopSwatchesAndColorTables() throws {
        let aco = try palette("Aegean.aco", .aco)
        XCTAssertEqual(aco.count, 12)
        XCTAssertEqual(aco.allColors[0].name, "Aegean Blue", "version 2 names win")
        XCTAssertEqual(aco.allColors[0].hex, "#0d5eaf")
        let cmyk = aco.allColors[10]
        XCTAssertEqual(cmyk.model, "CMYK")
        XCTAssertEqual(cmyk.values[1], 92, accuracy: 1, "Photoshop's CMYK is stored inverted")
        XCTAssertEqual(aco.allColors[11].model, "Lab")

        let act = try palette("Aegean.act", .act)
        XCTAssertEqual(act.count, 10, "the colour count after the table")
        XCTAssertEqual(act.allColors[9].hex, "#0b3a5a")
    }

    func testOtherPaletteFormats() throws {
        let gpl = try palette("Aegean.gpl", .gpl)
        XCTAssertEqual(gpl.name, "Aegean")
        XCTAssertEqual(gpl.columns, 5)
        XCTAssertEqual(gpl.allColors.map(\.name).first, "Aegean Blue")

        let procreate = try palette("Aegean.swatches", .procreate)
        XCTAssertEqual(procreate.name, "Aegean")
        XCTAssertEqual(procreate.count, 10, "empty slots are skipped")
        XCTAssertEqual(procreate.allColors[0].hex, "#0d5eaf")

        let sketch = try palette("Aegean.sketchpalette", .sketch)
        XCTAssertEqual(sketch.allColors.map(\.hex).last, "#0b3a5a")

        let clr = try palette("Harbor.clr", .clr)
        XCTAssertEqual(clr.allColors.map(\.name), ["Aegean", "Limestone", "Terracotta", "Poppy (CMYK)", "Charcoal", "Olive leaf"])
        XCTAssertEqual(clr.allColors[0].hex, "#005999")
        XCTAssertEqual(clr.allColors[3].model, "CMYK")
        XCTAssertEqual(clr.allColors[5].model, "Display P3")
        XCTAssertTrue(clr.allColors[5].clipped, "a P3 green outside sRGB")
        XCTAssertEqual(clr.allColors[5].alpha, 0.8, accuracy: 0.01)
    }

    func testColorListsOnlyDecodeColors() throws {
        // An archive that smuggles another class under the colour key is refused.
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(["A"], forKey: "NSKeys")
        archiver.encode([NSURL(fileURLWithPath: "/etc/passwd")], forKey: "NSColors")
        archiver.finishEncoding()
        XCTAssertThrowsError(try PaletteParser.parse(archiver.encodedData, format: .clr))
        XCTAssertThrowsError(try PaletteParser.parse(Data("bplist00garbage".utf8), format: .clr))
    }

    func testHostilePalettes() {
        // Lengths and counts that point far past the end.
        var ase = Data("ASEF".utf8) + Data([0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        ase += Data([0x00, 0x01, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try PaletteParser.parse(ase, format: .ase))
        XCTAssertThrowsError(try PaletteParser.parse(Data([0, 1, 0xFF, 0xFF, 0, 0]), format: .aco))
        XCTAssertThrowsError(try PaletteParser.parse(Data("GIMP Palette\nName: x\n".utf8), format: .gpl))
        XCTAssertThrowsError(try PaletteParser.parse(Data("PK\u{3}\u{4}".utf8), format: .procreate))
        XCTAssertThrowsError(try PaletteParser.parse(Data(#"{"colors":"nope"}"#.utf8), format: .sketch))
        // NaN floats in an ASE colour are skipped, never drawn.
        var body = Data([0, 2, 0x00, 0x41, 0x00, 0x00]) + Data("RGB ".utf8)  // name "A", model
        for _ in 0..<3 { body += Data([0x7F, 0xC0, 0x00, 0x00]) }             // NaN, NaN, NaN
        body += Data([0, 2])                                                   // normal colour
        let length = UInt32(body.count)
        let nanFile = Data("ASEF".utf8) + Data([0, 1, 0, 0, 0, 0, 0, 1]) + Data([0x00, 0x01])
            + Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]) + body
        XCTAssertThrowsError(try PaletteParser.parse(nanFile, format: .ase))
    }

    func testPaletteThumbnailsAndPreview() throws {
        let page = try XCTUnwrap(MediaModule.thumbnail(FileInfo(url: fixture("palettes/Aegean.ase")), size: CGSize(width: 128, height: 128), settings: PreviewSettings()))
        XCTAssertEqual(page.badge, "ASE")
        let (_, summary) = try web(try MediaModule.prepare(FileInfo(url: fixture("palettes/Aegean.ase")), settings: PreviewSettings()))
        XCTAssertEqual(summary.title, "Adobe Swatch Exchange")
        XCTAssertEqual(summary.details, ["10 colors", "2 groups", "2 spot"])
    }

    // MARK: - Thumbnails and coverage

    func testEveryFixtureHasAThumbnail() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixtures.path)
            .filter { !$0.hasSuffix(".py") && !$0.hasSuffix(".md") && !$0.hasSuffix(".txt") && !$0.contains("Hostile") }
            .map { fixture($0) }.filter { !$0.hasDirectoryPath && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false }
        XCTAssertGreaterThan(files.count, 20)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for url in files {
            let page = try XCTUnwrap(Thumbnailer.page(for: url, maximumSize: CGSize(width: 256, height: 256), settings: PreviewSettings()), url.lastPathComponent)
            XCTAssertLessThanOrEqual(page.size.width, 256)
            XCTAssertLessThanOrEqual(page.size.height, 256)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            page.draw()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Every extension the media module reads must reach Greece: it resolves (through Greece's own
    /// declarations, or macOS's) to a content type Greece claims.
    func testEveryMediaExtensionReachesGreece() throws {
        func listed(_ kind: String) throws -> Set<String> {
            var result = Set<String>()
            let folder = repo.appendingPathComponent("Types/\(kind)")
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".txt") {
                for line in try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).split(separator: "\n") {
                    let type = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
                    if !type.isEmpty { result.insert(type.lowercased()) }
                }
            }
            return result
        }
        var declared: [String: String] = [:]
        let folder = repo.appendingPathComponent("Types/declarations")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".plist") {
            let list = try PropertyListSerialization.propertyList(from: try Data(contentsOf: folder.appendingPathComponent(name)), format: nil) as? [[String: Any]] ?? []
            for declaration in list {
                let identifier = declaration["UTTypeIdentifier"] as? String ?? ""
                for ext in ((declaration["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? [] { declared[ext] = identifier.lowercased() }
            }
        }
        let previews = try listed("preview"), thumbnails = try listed("thumbnails")
        let extensions = ["ttf", "otf", "ttc", "otc", "woff", "woff2", "srt", "vtt", "ass", "ssa", "smi", "sami", "ttml", "dfxp", "sbv", "sub", "lrc",
                          "svg", "svgz", "lottie", "json", "xml", "ase", "aco", "act", "clr", "gpl", "swatches", "sketchpalette"]
        // TrueType and OpenType thumbnails stay with Apple's "Aa"; JSON and XML thumbnails are Greece's code pages.
        let appleThumbnails: Set<String> = ["ttf", "otf", "ttc", "otc", "json", "xml"]
        for ext in extensions {
            let type = declared[ext] ?? UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0.identifier.lowercased() }
            let identifier = try XCTUnwrap(type, "\(ext) has no content type")
            XCTAssertTrue(previews.contains(identifier), "\(ext) → \(identifier) isn't claimed for previews")
            if !appleThumbnails.contains(ext) { XCTAssertTrue(thumbnails.contains(identifier), "\(ext) → \(identifier) isn't claimed for thumbnails") }
        }
    }
}
