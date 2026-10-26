import EngineCore
import Foundation
import simd

/// What a compiled wrangle works on (WrangleSource generates code that calls these): the geometry's attributes of the
/// class it runs over as flat buffers by name (copied in before, written back after), the inputs to read from, and the
/// points and primitives it adds or removes, applied when it is done (as VEX does).
///
/// The buffers are written by element, each part of a parallel run its own elements; the edits that change the
/// geometry's shape run the snippet on one thread (WrangleSource says when).
package final class WrangleContext {
    package private(set) var geo: ProcGeo
    package let inputs: [ProcGeo?]
    package let runClass: AttributeClass
    /// The elements the group picks (nil: all).
    package let picked: [Bool]?

    private enum Column {
        case float(UnsafeMutableBufferPointer<Float>)
        case int(UnsafeMutableBufferPointer<Int>)
        case vector2(UnsafeMutableBufferPointer<SIMD2<Float>>)
        case vector3(UnsafeMutableBufferPointer<SIMD3<Float>>)
        case vector4(UnsafeMutableBufferPointer<SIMD4<Float>>)
        case string(WrangleStrings)
    }
    private var columns: [(name: String, column: Column, readOnly: Bool)] = []
    private var grids: [Int: PointGrid] = [:]
    private let lock = NSLock()
    // Edits applied after the run.
    private var addedPoints: [SIMD3<Float>] = []
    private var addedPrims: [(points: [Int32], closed: Bool)] = []
    private var removedPoints = Set<Int>()
    private var removedPrims = Set<Int>()
    private var groupEdits: [(name: String, index: Int, on: Bool)] = []

    package init(geo: ProcGeo, inputs: [ProcGeo?], runClass: AttributeClass, picked: [Bool]?) {
        self.geo = geo
        self.inputs = inputs
        self.runClass = runClass
        self.picked = picked
    }

    deinit { release() }

    package var count: Int { geo.count(runClass) }
    package func count(_ c: AttributeClass) -> Int { geo.count(c) }

    // MARK: Columns

    private func existing(_ name: String) -> AttributeValues? {
        if name == "P" {
            switch runClass {
            case .point: return .vector3(geo.P)
            case .vertex: return .vector3(geo.vertexPoint.map { geo.P[Int($0)] })
            case .primitive: return .vector3((0..<geo.primCount).map { geo.primCenter($0) })
            case .detail: return .vector3([geo.bounds.isEmpty ? .zero : geo.bounds.centroid])
            }
        }
        return geo.table(runClass)[name]
    }

    private func column(_ name: String) -> Column? { columns.first { $0.name == name }?.column }

    private func make<T>(_ values: [T]) -> UnsafeMutableBufferPointer<T> {
        let b = UnsafeMutableBufferPointer<T>.allocate(capacity: max(1, values.count))
        _ = b.initialize(from: values)
        return b
    }

    package func floats(_ name: String) -> UnsafeMutablePointer<Float> {
        if case .float(let b)? = column(name) { return b.baseAddress! }
        let v = existing(name).map { $0.type == .float ? $0 : $0.converted(to: .float) } ?? .zeros(.float, count: count)
        guard case .float(let a) = v else { fatalError() }
        let b = make(a)
        columns.append((name, .float(b), name == "P"))
        return b.baseAddress!
    }

    package func ints(_ name: String) -> UnsafeMutablePointer<Int> {
        if case .int(let b)? = column(name) { return b.baseAddress! }
        let v = existing(name).map { $0.type == .int ? $0 : $0.converted(to: .int) } ?? .zeros(.int, count: count)
        guard case .int(let a) = v else { fatalError() }
        let b = make(a.map { Int($0) })
        columns.append((name, .int(b), false))
        return b.baseAddress!
    }

    package func vectors2(_ name: String) -> UnsafeMutablePointer<SIMD2<Float>> {
        if case .vector2(let b)? = column(name) { return b.baseAddress! }
        let v = existing(name).map { $0.type == .vector2 ? $0 : $0.converted(to: .vector2) } ?? .zeros(.vector2, count: count)
        guard case .vector2(let a) = v else { fatalError() }
        let b = make(a)
        columns.append((name, .vector2(b), false))
        return b.baseAddress!
    }

    package func vectors3(_ name: String) -> UnsafeMutablePointer<SIMD3<Float>> {
        if case .vector3(let b)? = column(name) { return b.baseAddress! }
        let v = existing(name).map { $0.type == .vector3 ? $0 : $0.converted(to: .vector3) } ?? .zeros(.vector3, count: count)
        guard case .vector3(let a) = v else { fatalError() }
        let b = make(a)
        // P of anything but points is where the element is, to read.
        columns.append((name, .vector3(b), name == "P" && runClass != .point))
        return b.baseAddress!
    }

    package func vectors4(_ name: String) -> UnsafeMutablePointer<SIMD4<Float>> {
        if case .vector4(let b)? = column(name) { return b.baseAddress! }
        let v = existing(name).map { $0.type == .vector4 ? $0 : $0.converted(to: .vector4) } ?? .zeros(.vector4, count: count)
        guard case .vector4(let a) = v else { fatalError() }
        let b = make(a)
        columns.append((name, .vector4(b), false))
        return b.baseAddress!
    }

    package func strings(_ name: String) -> WrangleStrings {
        if case .string(let s)? = column(name) { return s }
        let v = existing(name).map { $0.type == .string ? $0 : $0.converted(to: .string) } ?? .zeros(.string, count: count)
        let s = WrangleStrings(v)
        columns.append((name, .string(s), false))
        return s
    }

    // MARK: Running

    /// Runs `body` over the elements: in parts on every core, or on this thread.
    package func run(parallel: Bool, _ body: (Range<Int>) -> Void) {
        if parallel { parallelChunks(count, grain: 2048, body) } else if count > 0 { body(0..<count) }
    }

    /// Writes the buffers back and applies the queued edits: the geometry the node outputs.
    package func finish() -> ProcGeo {
        let n = count
        for (name, column, readOnly) in columns where !readOnly {
            let values: AttributeValues
            switch column {
            case .float(let b): values = .float(Array(b.prefix(n)))
            case .int(let b): values = .int(b.prefix(n).map { Int32(truncatingIfNeeded: $0) })
            case .vector2(let b): values = .vector2(Array(b.prefix(n)))
            case .vector3(let b):
                if name == "P" && runClass == .point { geo.P = Array(b.prefix(n)); continue }
                values = .vector3(Array(b.prefix(n)))
            case .vector4(let b): values = .vector4(Array(b.prefix(n)))
            case .string(let s): values = s.values
            }
            geo.modify(runClass) { $0.set(name, values) }
        }
        release()
        // Groups set by element.
        for e in groupEdits {
            let c: AttributeClass = runClass == .detail ? .point : runClass
            var g = geo.table(c).group(e.name) ?? [Bool](repeating: false, count: geo.count(c))
            if e.index >= 0 && e.index < g.count { g[e.index] = e.on }
            geo.modify(c) { $0.setGroup(e.name, g) }
        }
        // Points and primitives added, then those removed.
        if !addedPoints.isEmpty {
            geo.P += addedPoints
            geo.syncCounts()
        }
        for p in addedPrims where p.points.allSatisfy({ $0 >= 0 && Int($0) < geo.pointCount }) { geo.addPrim(p.points, closed: p.closed) }
        if !removedPoints.isEmpty || !removedPrims.isEmpty {
            let keepPrims = (0..<geo.primCount).map { !removedPrims.contains($0) }
            let keepPoints = (0..<geo.pointCount).map { !removedPoints.contains($0) }
            geo = geo.keeping(prims: keepPrims, points: removedPoints.isEmpty ? nil : keepPoints)
        }
        return geo
    }

    private func release() {
        for (_, column, _) in columns {
            switch column {
            case .float(let b): b.deallocate()
            case .int(let b): b.deallocate()
            case .vector2(let b): b.deallocate()
            case .vector3(let b): b.deallocate()
            case .vector4(let b): b.deallocate()
            case .string: break
            }
        }
        columns = []
    }

    // MARK: What a snippet calls

    private func input(_ i: Int) -> ProcGeo? { i == 0 ? (inputs.first ?? nil) ?? geo : (i < inputs.count ? inputs[i] : nil) }

    package func npoints(_ i: Int) -> Int { input(i)?.pointCount ?? 0 }
    package func nprims(_ i: Int) -> Int { input(i)?.primCount ?? 0 }

    package func pointValue(_ i: Int, _ name: String, _ k: Int) -> SIMD4<Float> {
        guard let g = input(i), k >= 0, k < g.pointCount else { return .zero }
        if name == "P" { return SIMD4(g.P[k], 0) }
        return g.points[name]?.vector(k) ?? .zero
    }

    package func primValue(_ i: Int, _ name: String, _ k: Int) -> SIMD4<Float> {
        guard let g = input(i), k >= 0, k < g.primCount else { return .zero }
        if name == "P" { return SIMD4(g.primCenter(k), 0) }
        return g.prims[name]?.vector(k) ?? .zero
    }

    package func detailValue(_ i: Int, _ name: String) -> SIMD4<Float> { input(i)?.detail[name]?.vector(0) ?? .zero }

    /// The points of primitive `k` of input `i`.
    package func primpoints(_ i: Int, _ k: Int) -> [Int] {
        guard let g = input(i), k >= 0, k < g.primCount else { return [] }
        return g.primPoints(k).map { Int($0) }
    }

    private func grid(_ i: Int) -> PointGrid? {
        lock.lock()
        defer { lock.unlock() }
        if let g = grids[i] { return g }
        guard let geo = input(i) else { return nil }
        let g = PointGrid(geo.P)
        grids[i] = g
        return g
    }

    package func nearpoint(_ i: Int, _ p: SIMD3<Float>, maxDistance: Float = .infinity) -> Int {
        Int(grid(i)?.nearest(p, maxDistance: maxDistance) ?? -1)
    }

    package func nearpoints(_ i: Int, _ p: SIMD3<Float>, _ radius: Float, _ maxCount: Int) -> [Int] {
        guard let g = grid(i), let geo = input(i) else { return [] }
        var out: [Int32] = []
        g.within(p, radius: radius, into: &out)
        let sorted = out.map(Int.init).sorted { simd_distance_squared(geo.P[$0], p) < simd_distance_squared(geo.P[$1], p) }
        return Array(sorted.prefix(maxCount))
    }

    package func addpoint(_ p: SIMD3<Float>) -> Int {
        addedPoints.append(p)
        return geo.pointCount + addedPoints.count - 1
    }

    package func addprim(_ points: [Int], closed: Bool) -> Int {
        addedPrims.append((points.map { Int32($0) }, closed))
        return geo.primCount + addedPrims.count - 1
    }

    package func removepoint(_ i: Int) { removedPoints.insert(i) }
    package func removeprim(_ i: Int) { removedPrims.insert(i) }
    package func setgroup(_ name: String, _ i: Int, _ on: Bool) { groupEdits.append((name, i, on)) }
}

/// A string attribute as a wrangle reads and writes it: by element, through its table.
package final class WrangleStrings {
    private var rows: [Int32]
    private var table: [String]
    private var index: [String: Int32]

    init(_ v: AttributeValues) {
        if case .string(let r, let t) = v { rows = r; table = t } else { rows = []; table = [""] }
        index = Dictionary(table.enumerated().map { ($1, Int32($0)) }, uniquingKeysWith: { a, _ in a })
    }

    package subscript(_ i: Int) -> String {
        get { table[Int(rows[i])] }
        set {
            if let k = index[newValue] { rows[i] = k; return }
            index[newValue] = Int32(table.count)
            rows[i] = Int32(table.count)
            table.append(newValue)
        }
    }

    var values: AttributeValues { .string(rows, table: table) }
}
