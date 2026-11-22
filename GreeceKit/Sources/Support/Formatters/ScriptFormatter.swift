import Foundation
import JavaScriptCore

/// Runs the bundled JavaScript formatters (js-beautify, sql-formatter) in JavaScriptCore, off the
/// main thread and against a deadline. A call that runs over is abandoned: its context finishes
/// in the background and is never used again, so a hostile file can't hold up the next preview.
final class ScriptFormatter {
    static let shared = ScriptFormatter()

    enum Library: String {
        case beautifier = "vendor/js-beautify/beautifier.min.js"
        case sql = "vendor/sql-formatter/sql-formatter.min.js"
    }

    private final class Engine {
        let queue = DispatchQueue(label: "com.scorchy.greece.formatter", qos: .userInitiated)
        private var context: JSContext?
        private var loaded = Set<Library>()

        func run(_ library: Library, _ expression: String, input: String) -> String? {
            if context == nil {
                guard let fresh = JSContext() else { return nil }
                fresh.evaluateScript("var window = this, self = this, global = this;")
                context = fresh
            }
            guard let context else { return nil }
            if !loaded.contains(library) {
                guard let url = WebAssets.url(library.rawValue), let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                context.evaluateScript(source)
                guard context.exception == nil else { context.exception = nil; return nil }
                loaded.insert(library)
            }
            context.exception = nil
            context.setObject(input, forKeyedSubscript: "__input" as NSString)
            defer { context.setObject(NSNull(), forKeyedSubscript: "__input" as NSString) }
            guard let value = context.evaluateScript(expression), context.exception == nil, value.isString else {
                context.exception = nil
                return nil
            }
            return value.toString()
        }
    }

    private final class Box: @unchecked Sendable { var value: String? }

    private let lock = NSLock()
    private var engine: Engine?

    /// Evaluates `expression` (which reads the text as `__input`) and returns its string result.
    func call(_ library: Library, _ expression: String, input: String, timeout: TimeInterval) -> String? {
        lock.lock()
        let engine = self.engine ?? Engine()
        self.engine = engine
        lock.unlock()

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        engine.queue.async {
            box.value = engine.run(library, expression, input: input)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            if self.engine === engine { self.engine = nil }
            lock.unlock()
            return nil
        }
        return box.value
    }
}
