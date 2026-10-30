import EngineCore
import Foundation

/// Compiles a plant's Swift file into a program this process runs: the file as it is, as Programs/'s are (a copy of a
/// built-in one compiles), its `PlantProgram` found by its declaration and handed over by an entry point added at the end.
package final class PlantCompiler: @unchecked Sendable {
    package static let shared = PlantCompiler()

    private let lock = NSLock()
    private let compiler = SwiftBundleCompiler(anchor: "plants_program_anchor", module: "Plants", cacheName: "plants")
    private var loaded: [String: any PlantProgram.Type] = [:]
    private let queue = DispatchQueue(label: "plants.compile", qos: .utility)
    private let ticketLock = NSLock()
    private var latest = 0
    /// How long the last compile took (seconds; 0: from the cache).
    package private(set) var lastCompileSeconds: Double = 0

    /// Why files can't be compiled here, if they can't.
    package func problem() -> String? { compiler.problem("Plant files") }

    /// What names a source, whatever it is compiled against.
    package static func hash(_ source: String) -> String {
        var hasher = GeneratedCache.Hasher()
        hasher.add(source)
        return String(hasher.name().prefix(16))
    }

    /// The name of the type in `source` that is a `PlantProgram`.
    package static func programName(in source: String) -> String? {
        let declaration = #/\b(?:enum|struct|class)\s+([A-Za-z_][A-Za-z_0-9]*)\s*:[^{]*\bPlantProgram\b/#
        return source.firstMatch(of: declaration).map { String($0.1) }
    }

    /// Compiles `def`'s file on a queue of its own, one at a time, then tells `finished` (on the queue). `latest`: what
    /// another `latest` compile has replaced before its turn is let go.
    package func compileBehind(_ def: Foliage.SpeciesDef, latest isLatest: Bool = false, finished: @escaping (Result<(program: any PlantProgram.Type, hash: String), SwiftBundleCompiler.Failure>) -> Void) {
        ticketLock.lock()
        latest += isLatest ? 1 : 0
        let ticket = latest
        ticketLock.unlock()
        queue.async { [self] in
            if isLatest {
                ticketLock.lock()
                let stale = ticket != latest
                ticketLock.unlock()
                if stale { return }
            }
            finished(program(of: def))
        }
    }

    /// `def`'s file compiled: what grows its graph from now on (PlantPrograms).
    package func program(of def: Foliage.SpeciesDef) -> Result<(program: any PlantProgram.Type, hash: String), SwiftBundleCompiler.Failure> {
        let result = program(PlantSwift.emit(def).text)
        if case .success(let made) = result { PlantPrograms.register(made.program, for: def.grownGraph) }
        return result
    }

    /// `source`'s program, and the hash that names it.
    package func program(_ source: String) -> Result<(program: any PlantProgram.Type, hash: String), SwiftBundleCompiler.Failure> {
        let hash = PlantCompiler.hash(source)
        lock.lock()
        defer { lock.unlock() }
        if let made = loaded[hash] { lastCompileSeconds = 0; return .success((made, hash)) }
        if let why = problem() { return .failure(.failed(why)) }
        guard let name = PlantCompiler.programName(in: source) else { return .failure(.failed("No type in it is a PlantProgram")) }
        let module = "Plant_\(hash)"
        var key = hash
        if let date = compiler.moduleDate { key += String(format: "-%.0f", date.timeIntervalSince1970) }
        let wrapped = """
        import Plants
        #sourceLocation(file: "plant", line: 1)
        \(source)
        #sourceLocation()
        @_cdecl("metalrenderer_plant")
        public func metalrendererPlant() -> UnsafeMutableRawPointer { PlantProgramBox.export(\(name).self) }
        """
        let start = Date()
        switch compiler.bundle(wrapped, name: "plant-\(key)", moduleName: module, errorFile: "plant") {
        case .failure(let why): return .failure(why)
        case .success(let made):
            lastCompileSeconds = made.compiled ? Date().timeIntervalSince(start) : 0
            switch compiler.symbol("metalrenderer_plant", in: made.url) {
            case .failure(let why): return .failure(why)
            case .success(let sym):
                let entry = unsafeBitCast(sym, to: (@convention(c) () -> UnsafeMutableRawPointer).self)
                let program = Unmanaged<PlantProgramBox>.fromOpaque(entry()).takeRetainedValue().program
                loaded[hash] = program
                return .success((program, hash))
            }
        }
    }
}

/// What a compiled file hands its program over in.
package final class PlantProgramBox {
    let program: any PlantProgram.Type

    private init(_ program: any PlantProgram.Type) { self.program = program }

    package static func export(_ program: any PlantProgram.Type) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(PlantProgramBox(program)).toOpaque()
    }
}

/// A symbol to find the image Plants is in (PlantCompiler).
@_cdecl("plants_program_anchor")
public func plantsProgramAnchor() {}
