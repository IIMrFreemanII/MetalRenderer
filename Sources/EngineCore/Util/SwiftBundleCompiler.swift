import Darwin
import Foundation

/// Compiles Swift this process then loads: `swiftc` against the build's module files next to the binary (or the test
/// bundle) the code runs in, then a bundle whose engine symbols are this process's. A bundle is kept in the caches
/// folder under its name, so the same source compiles once (a name holds a hash of the source and the module it was
/// compiled against: `name(source)`). What a wrangle's snippet and a plant's file are made with.
///
/// Needs Xcode's tools and the build's `.swiftmodule` files.
package final class SwiftBundleCompiler: @unchecked Sendable {
    private let anchor: String
    private let module: String
    private let cacheName: String

    /// `anchor`: a C symbol of the module `module`, which finds the image it is in.
    package init(anchor: String, module: String, cacheName: String) {
        self.anchor = anchor
        self.module = module
        self.cacheName = cacheName
    }

    /// The folder holding the modules: up from the image this code is in.
    package lazy var products: URL? = {
        var info = Dl_info()
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), anchor), dladdr(sym, &info) != 0,
              let name = info.dli_fname else { return nil }
        var dir = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(module).swiftmodule").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    /// What `package` declarations are visible under: SwiftPM's name of this package.
    private lazy var packageName: String = {
        let scratch = products?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pif = scratch.flatMap { try? String(contentsOf: $0.appendingPathComponent("manifest.pif"), encoding: .utf8) }
        return pif.flatMap(SwiftBundleCompiler.packageName(pif:)) ?? SwiftBundleCompiler.packageName(folder: SourceTree.packageRoot.lastPathComponent)
    }()

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

    private var cacheFolder: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MetalRenderer/\(cacheName)")
    }

    /// Why this process can't compile, if it can't.
    package func problem(_ what: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return "\(what) need Xcode's command line tools (xcrun)" }
        guard products != nil else { return "\(what) need the build's module files next to the app (a SwiftPM build: Tools/build.sh)" }
        return nil
    }

    /// When the module was built: what's compiled against it is good until it changes.
    package var moduleDate: Date? {
        guard let products else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: products.appendingPathComponent("\(module).swiftmodule").path))?[.modificationDate] as? Date
    }

    package enum Failure: Error {
        case failed(String)
    }

    /// The bundle of `source`, named `name`; compiled now unless it was before. `errorFile`: the name its errors are
    /// reported under (`#sourceLocation`), the only ones told if it has any. `compiled`: whether it took a compile.
    package func bundle(_ source: String, name: String, moduleName: String, errorFile: String) -> Result<(url: URL, compiled: Bool), Failure> {
        let folder = cacheFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = folder.appendingPathComponent(name + ".bundle")
        if FileManager.default.fileExists(atPath: bundle.path) { return .success((bundle, false)) }
        guard let products else { return .failure(.failed("No modules")) }
        let file = folder.appendingPathComponent(name + ".swift"), object = folder.appendingPathComponent(name + ".o")
        do { try source.write(to: file, atomically: true, encoding: .utf8) } catch { return .failure(.failed("Can't write \(file.path)")) }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var swiftc = ["swiftc", "-parse-as-library", "-c", file.path, "-o", object.path, "-module-name", moduleName,
                      "-package-name", packageName, "-swift-version", "5", "-target", "\(arch)-apple-macos26.0",
                      "-I", products.path, "-O", "-diagnostic-style", "llvm",
                      "-module-cache-path", folder.appendingPathComponent("ModuleCache").path]
        // Physics (which the modules above it import) imports the C atomics, whose module map SwiftPM generates.
        let atomics = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps/CPhysicsAtomics.modulemap")
        if FileManager.default.fileExists(atPath: atomics.path) { swiftc += ["-Xcc", "-fmodule-map-file=\(atomics.path)"] }
        let compiled = SwiftBundleCompiler.xcrun(swiftc)
        guard compiled.status == 0 else { return .failure(.failed(SwiftBundleCompiler.errors(compiled.output, file: errorFile))) }
        let sdk = SwiftBundleCompiler.xcrun(["--show-sdk-path"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = SwiftBundleCompiler.xcrun(["clang", "-bundle", "-undefined", "dynamic_lookup", object.path, "-isysroot", sdk,
                                                "-L\(sdk)/usr/lib/swift", "-o", bundle.path])
        try? FileManager.default.removeItem(at: object)
        guard linked.status == 0 else { return .failure(.failed("Linking failed:\n" + linked.output.prefix(2000))) }
        return .success((bundle, true))
    }

    /// The symbol `entry` of the bundle, loaded (for good: bundles are never unloaded).
    package func symbol(_ entry: String, in bundle: URL) -> Result<UnsafeMutableRawPointer, Failure> {
        guard let handle = dlopen(bundle.path, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "?"
            try? FileManager.default.removeItem(at: bundle)
            return .failure(.failed("Couldn't load the compiled code: \(why)"))
        }
        guard let sym = dlsym(handle, entry) else { return .failure(.failed("The compiled code has no entry point")) }
        return .success(sym)
    }

    /// The errors in the code's own lines (`<file>:3:5: error: …`), warnings left out.
    static func errors(_ output: String, file: String) -> String {
        let lines = output.split(separator: "\n").filter { $0.contains("error:") }
        let mine = lines.filter { $0.hasPrefix(file + ":") }
        let kept = (mine.isEmpty ? lines : mine).prefix(12).map { line -> String in
            guard let r = line.range(of: file + ":") else { return String(line) }
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
