import EngineCore
import Foundation

/// Compiles a script (ScriptSource) into a bundle the running app loads: `swiftc` against the module files next to
/// the running binary (the dev build's `.build-dev/out/Products/Debug`, the release build's
/// `.build/out/Products/Release`), then `clang -bundle -bundle_loader <binary>`, so the script calls this process's
/// engine, not a copy of it. The binary exports every symbol of the modules, in both builds.
package struct ScriptCompiler {
    package struct Failure: Error, CustomStringConvertible {
        package let description: String
        init(_ message: String) { description = message }
    }

    /// The running binary, its build's products (the modules) and scratch folder (`.build-dev`, `.build`).
    package let binary: URL
    package let products: URL
    package let scratch: URL
    /// The package's name to the compiler (`-package-name`), so a script can use the engine's `package` API: SwiftPM's
    /// identity of the package (its folder's name, lowercased), not the manifest's `name`.
    package let packageName: String
    /// The binary's modification date when the app started: a build since then has other modules than the process.
    private let binaryStamp: Date?

    package init(binary: URL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()) {
        self.binary = binary
        products = binary.deletingLastPathComponent()
        scratch = products.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pif = try? String(contentsOf: scratch.appendingPathComponent("manifest.pif"), encoding: .utf8)
        packageName = pif.flatMap(ScriptCompiler.packageName(pif:))
            ?? ScriptCompiler.packageName(folder: SourceTree.packageRoot.lastPathComponent)
        binaryStamp = ScriptCompiler.modified(binary)
    }

    /// `SWIFT_PACKAGE_NAME` in SwiftPM's `manifest.pif`.
    package static func packageName(pif: String) -> String? {
        guard let key = pif.range(of: "\"SWIFT_PACKAGE_NAME\"") else { return nil }
        let rest = pif[key.upperBound...].drop { $0 == " " || $0 == ":" || $0 == "\t" }
        guard rest.first == "\"" else { return nil }
        let name = rest.dropFirst().prefix { $0 != "\"" }
        return name.isEmpty ? nil : String(name)
    }

    /// SwiftPM's identity of a package in folder `folder`: lowercased, `-` (and anything not a letter, digit or `_`)
    /// as `_`.
    package static func packageName(folder: String) -> String {
        String(folder.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    /// Where the scripts' generated files, bundles and the compiler's module cache go.
    package var workDirectory: URL { scratch.appendingPathComponent("scripts") }

    /// Why scripts can't be compiled against this binary, if they can't.
    package func problem() -> String? {
        let engine = products.appendingPathComponent("MetalRenderer.swiftmodule")
        guard FileManager.default.fileExists(atPath: engine.path) else {
            return "no MetalRenderer.swiftmodule next to \(binary.path): run a SwiftPM build of the app (Tools/build.sh or Tools/release.sh)"
        }
        if let stamp = binaryStamp, let now = ScriptCompiler.modified(binary), now > stamp {
            return "the app was built again since it started: relaunch it to run scripts"
        }
        // A build under way: its modules are newer than the binary that runs.
        let modules = (try? FileManager.default.contentsOfDirectory(atPath: products.path))?.filter { $0.hasSuffix(".swiftmodule") } ?? []
        for m in modules {
            let dir = products.appendingPathComponent(m)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".swiftmodule") } ?? []
            for f in files {
                if let stamp = binaryStamp, let date = ScriptCompiler.modified(dir.appendingPathComponent(f)), date > stamp.addingTimeInterval(1) {
                    return "\(m) is newer than the running app (a build since it started): relaunch it to run scripts"
                }
            }
        }
        return nil
    }

    /// Compiles `text` (the script at `path`) as script number `n`; returns its bundle, or the compiler's errors.
    package func compile(_ text: String, path: String, number n: Int) -> Result<URL, Failure> {
        if let problem = problem() { return .failure(Failure(problem)) }
        let dir = workDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure("can't make \(dir.path): \(error)"))
        }
        let source = dir.appendingPathComponent("Script-\(n).swift")
        let object = dir.appendingPathComponent("Script-\(n).o")
        let bundle = dir.appendingPathComponent("Script-\(n).bundle")
        do {
            try ScriptSource.generate(text, path: path).write(to: source, atomically: true, encoding: .utf8)
        } catch {
            return .failure(Failure("can't write \(source.path): \(error)"))
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var swiftc = ["swiftc", "-parse-as-library", "-c", source.path, "-o", object.path,
                      "-module-name", "Script\(n)", "-package-name", packageName, "-swift-version", "5",
                      "-target", "\(arch)-apple-macos13.0", "-I", products.path, "-Onone", "-diagnostic-style", "llvm",
                      "-module-cache-path", dir.appendingPathComponent("ModuleCache").path]
        // Physics imports the C atomics, whose module map SwiftPM generates.
        let maps = scratch.appendingPathComponent("out/Intermediates.noindex/GeneratedModuleMaps")
        let atomics = maps.appendingPathComponent("CPhysicsAtomics.modulemap")
        if FileManager.default.fileExists(atPath: atomics.path) { swiftc += ["-Xcc", "-fmodule-map-file=\(atomics.path)"] }
        let compiled = ScriptCompiler.xcrun(swiftc)
        guard compiled.status == 0 else { return .failure(Failure(ScriptCompiler.errors(in: compiled.output))) }
        let sdk = ScriptCompiler.xcrun(["--show-sdk-path"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = ScriptCompiler.xcrun(["clang", "-bundle", "-bundle_loader", binary.path, object.path, "-isysroot", sdk,
                                           "-L\(sdk)/usr/lib/swift", "-o", bundle.path])
        guard linked.status == 0 else { return .failure(Failure("link failed:\n" + linked.output)) }
        return .success(bundle)
    }

    /// The compiler's errors and their notes, each with the source line and caret under it; warnings left out.
    package static func errors(in output: String) -> String {
        var kept: [String] = [], keeping = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(": error: ") || line.contains(": note: ") || line.hasPrefix("error: ") {
                keeping = true
            } else if line.contains(": warning: ") || line.contains(": remark: ") {
                keeping = false
                continue
            }
            if keeping && !line.isEmpty { kept.append(String(line)) }
        }
        return kept.isEmpty ? output : kept.prefix(60).joined(separator: "\n")
    }

    private static func xcrun(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "can't run xcrun \(arguments.first ?? ""): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
