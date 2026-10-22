import Foundation

/// A script's text made into the Swift file the app compiles (ScriptCompiler): its imports first, with the engine's;
/// its code under `#sourceLocation`, so the compiler's errors name the script's own lines; then the entry point the
/// app calls (`metalrenderer_script_main`) and a `print` that sends what it prints to whoever ran it (ScriptRun.write).
///
/// Two forms (README, "Scripts"):
/// - full: the script declares `func run(_ run: ScriptRun)`, called on the script's own thread, where it can wait
///   between its steps (`run.waitForScene()`, `run.wait(frames:)`);
/// - short: plain statements, run once on the render thread before the next frame, with `renderer`, `scene` and
///   `run` in scope. A short script can declare local functions and types, but no extensions.
package enum ScriptSource {
    /// What every script imports without saying so.
    package static let defaultImports = ["Foundation", "simd", "EngineCore", "MetalRenderer"]
    /// The C name of the entry point the app looks up in the script's bundle.
    package static let entry = "metalrenderer_script_main"

    /// Whether `text` declares the full form's `func run(`.
    package static func isFullForm(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let t = line.drop { $0 == " " || $0 == "\t" }
            guard t.hasPrefix("func ") else { return false }
            let name = t.dropFirst(5).drop { $0 == " " }
            return name.hasPrefix("run") && name.dropFirst(3).drop { $0 == " " }.hasPrefix("(")
        }
    }

    /// The module `line` imports, if it is an import line (`import X`, `@testable import X`, `import struct X.Y`).
    package static func importedModule(_ line: Substring) -> String? {
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.first == "@testable" || words.first == "@_exported" { words.removeFirst() }
        guard words.first == "import", words.count >= 2 else { return nil }
        let kinds: Set<Substring> = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
        let path = kinds.contains(words[1]) && words.count >= 3 ? words[2] : words[1]
        let module = path.split(separator: ".").first.map(String.init) ?? ""
        return module.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !module.isEmpty ? module : nil
    }

    /// The Swift file for the script at `path` with text `text`.
    package static func generate(_ text: String, path: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var imports = defaultImports
        // The script's imports go to the top; their lines stay, empty, so the line numbers hold.
        for k in lines.indices {
            guard let module = importedModule(Substring(lines[k])) else { continue }
            if !imports.contains(module) { imports.append(module) }
            lines[k] = ""
        }
        let full = isFullForm(text)
        var out = imports.map { "import \($0)\n" }.joined()
        if !full {
            // The short form's statements in a closure the render thread runs: one line before the script's first.
            out += "func run(_ run: ScriptRun) throws { try run.render { (renderer: Renderer) throws -> Void in let scene = renderer.scene; _ = scene\n"
        }
        out += "#sourceLocation(file: \"\(escaped(path))\", line: 1)\n"
        out += lines.joined(separator: "\n") + "\n"
        out += "#sourceLocation()\n"
        if !full { out += "} }\n" }
        out += """
        private var _scriptRun: ScriptRun?
        /// What the script prints goes to whoever ran it, and to the app's output.
        func print(_ items: Any..., separator: String = " ", terminator: String = "\\n") {
            let text = items.map { "\\($0)" }.joined(separator: separator) + terminator
            if let run = _scriptRun { run.write(text) } else { Swift.print(text, terminator: "") }
        }
        @_cdecl("\(entry)") public func _scriptMain(_ handle: UnsafeRawPointer) {
            let script = Unmanaged<ScriptRun>.fromOpaque(handle).takeUnretainedValue()
            _scriptRun = script
            do { try run(script) } catch { script.fail(error) }
        }

        """
        return out
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
