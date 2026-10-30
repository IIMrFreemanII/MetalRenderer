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
    private let compiler = SwiftBundleCompiler(anchor: "proc_wrangle_anchor", module: "Procedural", cacheName: "wrangles")
    /// How long the last compile took (seconds; 0: from the cache).
    package private(set) var lastCompileSeconds: Double = 0

    /// Why snippets can't be compiled here, if they can't.
    package func problem() -> String? { compiler.problem("Wrangles") }

    /// The compiled entry point of `source`, compiling it if no bundle has it yet.
    package func entry(_ source: String) -> Result<Entry, ProcCookError> {
        var h = Hasher64()
        h.add(source)
        if let date = compiler.moduleDate { h.add(date.timeIntervalSince1970.bitPattern) }
        let key = h.value
        lock.lock()
        defer { lock.unlock() }
        if let f = loaded[key] { lastCompileSeconds = 0; return .success(f) }
        if let p = problem() { return .failure(ProcCookError(p)) }
        let start = Date()
        switch compiler.bundle(source, name: String(format: "wrangle-%016llx", key), moduleName: "Wrangle", errorFile: "wrangle") {
        case .failure(.failed(let why)): return .failure(ProcCookError(why))
        case .success(let made):
            lastCompileSeconds = made.compiled ? Date().timeIntervalSince(start) : 0
            switch compiler.symbol("proc_wrangle_main", in: made.url) {
            case .failure(.failed(let why)): return .failure(ProcCookError(why))
            case .success(let sym):
                let f = unsafeBitCast(sym, to: Entry.self)
                loaded[key] = f
                return .success(f)
            }
        }
    }
}

/// A symbol to find the image Procedural is in (WrangleCompiler.products).
@_cdecl("proc_wrangle_anchor")
public func procWrangleAnchor() {}
