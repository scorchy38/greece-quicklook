// Drives the installed Greece app through the macOS accessibility API (as VoiceOver or UI tests
// would), checks the outcome of every action, and captures Greece's own windows at each step.
//
//   swift scripts/ui-check.swift [/Applications/Greece.app] [out-dir]
//
// Needs Accessibility permission for the terminal running it. Starts with Greece's Quick Look
// extension switched off so the onboarding "Turn On Greece" path runs for real, and leaves it on.
// It ends by restoring default preview settings (that is one of the things it checks).
import AppKit
import ApplicationServices

let appURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Applications/Greece.app")
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/greece-ui-check")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let extensionID = "com.scorchy.greece.quicklook"

var results: [(String, Bool)] = []
func record(_ name: String, _ passed: Bool) {
    results.append((name, passed))
    print("\(passed ? "PASS" : "FAIL")  \(name)")
    fflush(stdout)
}

@discardableResult
func shell(_ tool: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        pause(0.25)
    }
    return condition()
}

// MARK: - Accessibility helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func names(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, kAXLabelValueAttribute]
        .compactMap { attribute(element, $0) as? String }
}

func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }

/// Depth-first search for an element whose title, description or value equals `label`.
func find(_ root: AXUIElement, _ label: String, roles: Set<String>? = nil, depth: Int = 0) -> AXUIElement? {
    guard depth < 80 else { return nil }
    if names(root).contains(label), roles.map({ $0.contains(role(root)) }) ?? true { return root }
    for child in children(root) {
        if let match = find(child, label, roles: roles, depth: depth + 1) { return match }
    }
    return nil
}

/// The nearest ancestor (or self) with one of the given roles.
func ancestor(_ element: AXUIElement, roles: Set<String>) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<12 {
        guard let node = current else { return nil }
        if roles.contains(role(node)) { return node }
        current = attribute(node, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    return nil
}

func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }

func windows(_ app: AXUIElement) -> [AXUIElement] { (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func title(_ window: AXUIElement) -> String { attribute(window, kAXTitleAttribute) as? String ?? "" }
func quickLookPanel(_ app: AXUIElement) -> AXUIElement? {
    windows(app).first { (attribute($0, kAXSubroleAttribute) as? String) == "Quick Look" }
}
func closePanel(_ app: AXUIElement) {
    if let panel = quickLookPanel(app), let close = attribute(panel, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }) { _ = press(close) }
}

/// A switch is labelled by the text it points to through AXTitleUIElement (standard macOS Forms).
func toggle(_ root: AXUIElement, labelled label: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 80 else { return nil }
    if role(root) == kAXCheckBoxRole,
       let titleElement = attribute(root, kAXTitleUIElementAttribute).map({ $0 as! AXUIElement }),
       names(titleElement).contains(label) || names(root).contains(label) { return root }
    for child in children(root) {
        if let match = toggle(child, labelled: label, depth: depth + 1) { return match }
    }
    return nil
}

/// Window numbers for screencapture, from the window server, matched by title.
func capture(pid: pid_t, titled: String?, name: String) {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { window in
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (window[kCGWindowOwnerPID as String] as? pid_t) == pid && (bounds["Width"] ?? 0) > 300 && (bounds["Height"] ?? 0) > 200
    }
    // The Quick Look panel has no window-server title; it is the window that isn't the main one.
    func area(_ window: [String: Any]) -> Double {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    let onScreen = mine.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.sorted { area($0) > area($1) }
    let match = titled == nil
        ? onScreen.first { (($0[kCGWindowName as String] as? String) ?? "").isEmpty }
        : onScreen.first { (($0[kCGWindowName as String] as? String) ?? "").contains(titled!) }
    guard let number = match?[kCGWindowNumber as String] as? Int else { return }
    shell("/usr/sbin/screencapture", ["-x", "-o", "-l\(number)", outDir.appendingPathComponent("\(name).png").path])
}

func extensionEnabled() -> Bool {
    shell("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", extensionID]).split(separator: "\n").first?.hasPrefix("+") ?? false
}

// MARK: - Run

guard AXIsProcessTrusted() else {
    print("This terminal needs Accessibility permission (System Settings → Privacy & Security → Accessibility).")
    exit(2)
}

shell("/usr/bin/pluginkit", ["-e", "ignore", "-i", extensionID])
// Right after an install, the plugin registry can still be settling: wait until it reports "off".
if !waitUntil(10, { !extensionEnabled() }) {
    shell("/usr/bin/pluginkit", ["-e", "ignore", "-i", extensionID])
    _ = waitUntil(10) { !extensionEnabled() }
}
NSRunningApplication.runningApplications(withBundleIdentifier: "com.scorchy.greece").forEach { $0.terminate() }
pause(1)

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
let launched = DispatchSemaphore(value: 0)
var running: NSRunningApplication?
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in running = app; launched.signal() }
launched.wait()
guard let pid = running?.processIdentifier else { print("FAIL  launch"); exit(1) }
let app = AXUIElementCreateApplication(pid)
_ = waitUntil(10) { windows(app).contains { title($0) == "Welcome" } }
guard let main = windows(app).first(where: { title($0) == "Welcome" }) else { print("FAIL  no main window"); exit(1) }
pause(1.5)
capture(pid: pid, titled: "Welcome", name: "01-welcome-quicklook-off")

// Onboarding repairs a switched-off extension.
let turnOnAppeared = waitUntil(8) { find(main, "Turn On Greece", roles: [kAXButtonRole]) != nil }
record("Welcome offers Turn On Greece while Quick Look is off", turnOnAppeared)
if let button = find(main, "Turn On Greece", roles: [kAXButtonRole]) {
    _ = press(button)
    record("Turn On Greece re-enables the extension", waitUntil(15) { extensionEnabled() })
    record("Welcome then reports Quick Look is on", waitUntil(8) { find(main, "Quick Look previews are on") != nil })
}
pause(1)
capture(pid: pid, titled: "Welcome", name: "02-welcome-quicklook-on")

// A sample tile opens the real Quick Look panel on that file.
if let tile = find(main, "Preview Markdown sample") {
    _ = press(tile)
    let opened = waitUntil(6) { quickLookPanel(app) != nil }
    record("Markdown sample tile opens the Quick Look panel", opened)
    pause(2.5)
    capture(pid: pid, titled: nil, name: "03-quicklook-from-tile")
    closePanel(app)
} else {
    record("Markdown sample tile opens the Quick Look panel", false)
}
pause(0.8)

// Sidebar navigation reaches every page.
func open(_ page: String) -> Bool {
    guard let text = find(main, page, roles: [kAXStaticTextRole]), let row = ancestor(text, roles: [kAXRowRole]) else { return false }
    AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    return waitUntil(4) { title(main) == page }
}
for (index, page) in ["Markdown", "Code", "Data", "Archives & Folders", "General", "About"].enumerated() {
    record("Sidebar opens \(page)", open(page))
    pause(1.6)
    capture(pid: pid, titled: page, name: String(format: "%02d-page-", 4 + index) + page.lowercased().replacingOccurrences(of: " & ", with: "-"))
}

// Code settings: a theme thumbnail and a toggle change what the live preview shows.
_ = open("Code")
pause(1.2)
func isOn(_ label: String) -> Bool? { toggle(main, labelled: label).flatMap { attribute($0, kAXValueAttribute) as? Int }.map { $0 == 1 } }
if let one = find(main, "One theme") {
    _ = press(one)
    pause(0.8)
    let selected = find(main, "One theme").flatMap { attribute($0, kAXSelectedAttribute) as? Bool } == true
    let others = find(main, "Xcode theme").flatMap { attribute($0, kAXSelectedAttribute) as? Bool } ?? false
    record("One theme thumbnail becomes the only selection", selected && !others)
}
let before = isOn("Line numbers")
if let lineNumbers = toggle(main, labelled: "Line numbers") { _ = press(lineNumbers) }
pause(1)
record("Line numbers toggle flips", before != nil && isOn("Line numbers") == !(before!))
capture(pid: pid, titled: "Code", name: "10-code-one-theme-no-line-numbers")

// Sample switcher in the toolbar.
if let python = find(main, "Python", roles: [kAXRadioButtonRole, kAXButtonRole]) {
    _ = press(python)
    pause(1.5)
    record("Toolbar switches the live preview to the Python sample", (attribute(python, kAXValueAttribute) as? Int) == 1)
    capture(pid: pid, titled: "Code", name: "11-code-python-sample")
}

// The toolbar's Quick Look button opens the current sample in the real panel.
if let eye = find(main, "Open in Quick Look") {
    _ = press(eye)
    let opened = waitUntil(6) { quickLookPanel(app) != nil }
    record("Toolbar button opens the sample in Quick Look", opened)
    pause(2.5)
    capture(pid: pid, titled: nil, name: "12-quicklook-from-toolbar")
    closePanel(app)
}
pause(0.8)

// General: restoring defaults goes through the confirmation dialog and resets everything.
_ = open("General")
pause(1.2)
if let restore = find(main, "Restore Default Settings…", roles: [kAXButtonRole]) {
    _ = press(restore)
    pause(1)
    let confirm = windows(app).lazy.compactMap { find($0, "Restore Defaults", roles: [kAXButtonRole]) }.first
    record("Restore asks for confirmation", confirm != nil)
    if let confirm { _ = press(confirm) }
    pause(1)
    _ = open("Code")
    pause(1.2)
    record("Restore Defaults turns line numbers back on", isOn("Line numbers") == true)
    capture(pid: pid, titled: "Code", name: "13-code-after-restore")
}

running?.terminate()
if !extensionEnabled() { shell("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID]) }
let failed = results.filter { !$0.1 }.count
print("DONE \(results.count - failed)/\(results.count) passed · screenshots in \(outDir.path)")
exit(failed == 0 ? 0 : 1)
