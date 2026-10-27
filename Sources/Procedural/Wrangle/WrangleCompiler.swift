import Darwin
import EngineCore
import Foundation

/// Compiles wrangles' Swift (WrangleSource) into bundles this process loads, as the app's scripts are (ScriptCompiler):
/// `swiftc -O` against the build's module files next to the binary (or the test bundle) the code runs in, then a
/// bundle whose engine symbols are this process's. A bundle is kept in the caches folder under a hash of its source
/// and the module it was compiled against, so a snippet compiles once; loaded ones are kept by that hash.
///
/// Needs Xcode's tools and the build's `.swiftmodule` files: an app without them can't compile a new snippet (its
/// placed assets come from the cooked-mesh cache).
package final class WrangleCompiler: @unchecked Sendable {
    package typealias Entry = @convention(c) (UnsafeMutableRawPointer) -> Void
    package static let shared = WrangleCompiler()

    private let lock = NSLock()
    private var loaded: [UInt64: Entry] = [:]
    /// How long the last compile took (seconds; 0: from the cache).
    package private(set) var lastCompileSeconds: Double = 0

    /// The folder holding the modules (`Procedural.swiftmodule`): up from the image this code is in.
    package lazy var products: URL? = {
        var info = Dl_info()
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_wrangle_anchor"), dladdr(sym, &info) != 0,
              let name = info.dli_fname else { return nil }
        var dir = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Procedural.swiftmodule").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    private lazy var packageName: String = {
        String(SourceTree.packageRoot.lastPathComponent.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }()

    private var cacheFolder: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MetalRenderer/wrangles")
    }

    /// Why snippets can't be compiled here, if they can't.
    package func problem() -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return "Wrangles need Xcode's command line tools (xcrun)" }
        guard products != nil else { return "Wrangles need the build's module files next to the app (a SwiftPM build: Tools/build.sh)" }
        return nil
    }

    /// The compiled entry point of `source`, compiling it if no bundle has it yet.
    package func entry(_ source: String) -> Result<Entry, ProcCookError> {
        var h = Hasher64()
        h.add(source)
        if let p = products, let date = (try? FileManager.default.attributesOfItem(atPath: p.appendingPathComponent("Procedural.swiftmodule").path))?[.modificationDate] as? Date {
            h.add(date.timeIntervalSince1970.bitPattern)
        }
        let key = h.value
        lock.lock()
        defer { lock.unlock() }
        if let f = loaded[key] { lastCompileSeconds = 0; return .success(f) }
        if let p = problem() { return .failure(ProcCookError(p)) }
        let folder = cacheFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "wrangle-%016llx", key)
        let bundle = folder.appendingPathComponent(name + ".bundle")
        if !FileManager.default.fileExists(atPath: bundle.path) {
            let start = Date()
            if let e = compile(source, name: name, folder: folder, bundle: bundle) { return .failure(e) }
            lastCompileSeconds = Date().timeIntervalSince(start)
        } else {
            lastCompileSeconds = 0
        }
        guard let handle = dlopen(bundle.path, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "?"
            try? FileManager.default.removeItem(at: bundle)
            return .failure(ProcCookError("Couldn't load the compiled wrangle: \(why)"))
        }
        guard let sym = dlsym(handle, "proc_wrangle_main") else { return .failure(ProcCookError("The compiled wrangle has no entry point")) }
        let f = unsafeBitCast(sym, to: Entry.self)
        loaded[key] = f
        return .success(f)
    }

    private func compile(_ source: String, name: String, folder: URL, bundle: URL) -> ProcCookError? {
        guard let products else { return ProcCookError("No modules") }
        let file = folder.appendingPathComponent(name + ".swift"), object = folder.appendingPathComponent(name + ".o")
        do { try source.write(to: file, atomically: true, encoding: .utf8) } catch { return ProcCookError("Can't write \(file.path)") }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var swiftc = ["swiftc", "-parse-as-library", "-c", file.path, "-o", object.path, "-module-name", "Wrangle",
                      "-package-name", packageName, "-swift-version", "5", "-target", "\(arch)-apple-macos26.0",
                      "-I", products.path, "-O", "-diagnostic-style", "llvm",
                      "-module-cache-path", folder.appendingPathComponent("ModuleCache").path]
        // Physics (which Procedural imports) imports the C atomics, whose module map SwiftPM generates.
        let atomics = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps/CPhysicsAtomics.modulemap")
        if FileManager.default.fileExists(atPath: atomics.path) { swiftc += ["-Xcc", "-fmodule-map-file=\(atomics.path)"] }
        let compiled = WrangleCompiler.xcrun(swiftc)
        guard compiled.status == 0 else { return ProcCookError(WrangleCompiler.errors(compiled.output)) }
        let sdk = WrangleCompiler.xcrun(["--show-sdk-path"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = WrangleCompiler.xcrun(["clang", "-bundle", "-undefined", "dynamic_lookup", object.path, "-isysroot", sdk,
                                            "-L\(sdk)/usr/lib/swift", "-o", bundle.path])
        try? FileManager.default.removeItem(at: object)
        guard linked.status == 0 else { return ProcCookError("Linking the wrangle failed:\n" + linked.output.prefix(2000)) }
        return nil
    }

    /// The snippet's errors (its own lines: `wrangle:3:5: error: …`), warnings left out.
    static func errors(_ output: String) -> String {
        let lines = output.split(separator: "\n").filter { $0.contains("error:") }
        let mine = lines.filter { $0.hasPrefix("wrangle:") }
        let kept = (mine.isEmpty ? lines : mine).prefix(12).map { line -> String in
            guard let r = line.range(of: "wrangle:") else { return String(line) }
            return "line " + line[r.upperBound...]
        }
        return kept.isEmpty ? String(output.prefix(1500)) : kept.joined(separator: "\n")
    }

    private static func xcrun(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "can't run xcrun: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// A symbol to find the image Procedural is in (WrangleCompiler.products).
@_cdecl("proc_wrangle_anchor")
public func procWrangleAnchor() {}
