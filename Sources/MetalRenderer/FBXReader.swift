import Compression
import Foundation

enum FBXError: Error, CustomStringConvertible {
    case invalid(String)
    case unsupported(String)
    var description: String {
        switch self {
        case .invalid(let s): return "invalid FBX: \(s)"
        case .unsupported(let s): return "unsupported FBX feature: \(s)"
        }
    }
}

/// A file mapped into memory, read only: its pages are read from disk when they are first touched.
final class MappedFile {
    let base: UnsafeRawPointer
    let count: Int

    init(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FBXError.invalid("cannot open \(url.lastPathComponent)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { throw FBXError.invalid("\(url.lastPathComponent) is empty") }
        guard let map = mmap(nil, Int(info.st_size), PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else {
            throw FBXError.invalid("cannot map \(url.lastPathComponent)")
        }
        base = UnsafeRawPointer(map)
        count = Int(info.st_size)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), count) }
}

/// An element type of an FBX array property.
protocol FBXArrayElement {
    static var fbxCode: UInt8 { get }
}
extension Double: FBXArrayElement { static let fbxCode = UInt8(ascii: "d") }
extension Float: FBXArrayElement { static let fbxCode = UInt8(ascii: "f") }
extension Int32: FBXArrayElement { static let fbxCode = UInt8(ascii: "i") }
extension Int64: FBXArrayElement { static let fbxCode = UInt8(ascii: "l") }

/// A binary FBX file (7.x), read for speed (CharacterLibrary imports characters and animation clips from it):
/// * the file is memory-mapped and never copied: a node is a 24-byte record of offsets into it, names are compared
///   as bytes, and a value is decoded where it lies when it is asked for;
/// * a node holds the offset of its end, so what the reader doesn't want is skipped without being looked at: only
///   `GlobalSettings`, `Objects` and `Connections`, and of the objects only the kinds in `Contents` (a clip file
///   carries a whole copy of its character's mesh that is never touched);
/// * an array is inflated once, when asked for, straight into the Swift array it becomes (its element count is in
///   its header). Every method is safe to call from several threads at once, so the big arrays are inflated in
///   parallel.
/// Every offset read from the file is checked against its size: a truncated or corrupt file throws.
final class FBXFile {
    /// One node: its name and properties by file offset, its first child and next sibling by index into `nodes`.
    struct Node {
        var nameStart: UInt32
        var nameLength: UInt32
        var propertyStart: UInt32
        var propertyCount: UInt32
        var firstChild: Int32 = -1
        var nextSibling: Int32 = -1
    }

    /// The kinds of object to read besides the models (the scene's nodes: bones and meshes), which always are.
    struct Contents: OptionSet {
        let rawValue: Int
        static let geometry = Contents(rawValue: 1)    // Geometry: vertices, polygons, normals, UVs
        static let skin = Contents(rawValue: 2)        // Deformer: skins and their clusters (a joint's vertices and weights)
        static let materials = Contents(rawValue: 4)   // Material
        static let animation = Contents(rawValue: 8)   // AnimationStack, AnimationLayer, AnimationCurveNode, AnimationCurve
    }

    /// One `C` record of `Connections`: object `child` belongs to object `parent` (`node`'s property 3 names the
    /// parent's property for an "OP" connection).
    struct Connection {
        var child: Int64
        var parent: Int64
        var node: Int32
    }

    /// FBX time (KTime) units per second.
    static let ticksPerSecond: Double = 46_186_158_000

    let url: URL
    let version: UInt32
    let byteCount: Int
    private(set) var nodes: [Node] = []
    /// The objects by id: their nodes (the children of `Objects` that were kept).
    private(set) var objects: [Int64: Int32] = [:]
    private(set) var connections: [Connection] = []
    private let file: MappedFile
    private let base: UnsafeRawPointer

    init(url: URL, contents: Contents) throws {
        self.url = url
        file = try MappedFile(url)
        base = file.base
        byteCount = file.count
        let magic: StaticString = "Kaydara FBX Binary  "
        guard byteCount > 27, memcmp(base, magic.utf8Start, magic.utf8CodeUnitCount) == 0 else {
            throw FBXError.unsupported("\(url.lastPathComponent) is not a binary FBX file")
        }
        version = base.loadUnaligned(fromByteOffset: 23, as: UInt32.self)
        guard byteCount < Int(UInt32.max) else { throw FBXError.unsupported("files of 4 GB and more") }
        guard version >= 7000 else { throw FBXError.unsupported("FBX version \(version) (7.0 and later are read)") }
        try parse(contents)
        try index()
    }

    // MARK: - Reading the file

    @inline(__always)
    private func load<T>(_ offset: Int, as type: T.Type) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= byteCount else {
            throw FBXError.invalid("\(url.lastPathComponent) is truncated")
        }
        return base.loadUnaligned(fromByteOffset: offset, as: type)
    }

    @inline(__always)
    private func matches(_ start: Int, _ length: Int, _ name: StaticString) -> Bool {
        length == name.utf8CodeUnitCount && memcmp(base + start, name.utf8Start, length) == 0
    }

    /// The node records of what `contents` asks for, in file order. Everything else is stepped over by its end offset.
    private func parse(_ contents: Contents) throws {
        // A node starts with its end offset, property count and property bytes (64-bit from version 7.5), then the
        // length of its name. A list of nodes ends with a record of zeros.
        let wide = version >= 7500
        let header = wide ? 25 : 13
        nodes.reserveCapacity(4096)

        func wanted(_ start: Int, _ length: Int, level: Int) -> Bool {
            switch level {
            case 0:
                return matches(start, length, "Objects") || matches(start, length, "Connections")
                    || matches(start, length, "GlobalSettings")
            case 1:
                if matches(start, length, "Model") { return true }
                if matches(start, length, "Geometry") { return contents.contains(.geometry) }
                if matches(start, length, "Deformer") { return contents.contains(.skin) }
                if matches(start, length, "Material") { return contents.contains(.materials) }
                return contents.contains(.animation)
                    && (matches(start, length, "AnimationCurve") || matches(start, length, "AnimationCurveNode")
                        || matches(start, length, "AnimationLayer") || matches(start, length, "AnimationStack"))
            default:
                return true
            }
        }

        // `level`: 0 = the file's top, 1 = the children of Objects, 2 = anything else (all kept).
        func walk(from start: Int, to end: Int, parent: Int32, level: Int) throws {
            var pos = start
            var last: Int32 = -1
            while pos + header <= end {
                let endOffset: Int, propertyCount: Int, propertyBytes: Int
                if wide {
                    let e = try load(pos, as: UInt64.self), c = try load(pos + 8, as: UInt64.self)
                    let b = try load(pos + 16, as: UInt64.self)
                    guard e <= UInt64(byteCount), c <= UInt64(byteCount), b <= UInt64(byteCount) else {
                        throw FBXError.invalid("a node reaches past the end of \(url.lastPathComponent)")
                    }
                    (endOffset, propertyCount, propertyBytes) = (Int(e), Int(c), Int(b))
                } else {
                    endOffset = Int(try load(pos, as: UInt32.self))
                    propertyCount = Int(try load(pos + 4, as: UInt32.self))
                    propertyBytes = Int(try load(pos + 8, as: UInt32.self))
                }
                if endOffset == 0 { return }
                let nameLength = Int(try load(pos + header - 1, as: UInt8.self))
                let nameStart = pos + header
                let propertyStart = nameStart + nameLength
                let childStart = propertyStart + propertyBytes
                guard endOffset > pos, endOffset <= end, childStart <= endOffset else {
                    throw FBXError.invalid("a node of \(url.lastPathComponent) is out of bounds")
                }
                if wanted(nameStart, nameLength, level: level) {
                    let index = Int32(nodes.count)
                    nodes.append(Node(nameStart: UInt32(nameStart), nameLength: UInt32(nameLength),
                                      propertyStart: UInt32(propertyStart), propertyCount: UInt32(propertyCount)))
                    if last >= 0 { nodes[Int(last)].nextSibling = index } else if parent >= 0 { nodes[Int(parent)].firstChild = index }
                    last = index
                    if childStart < endOffset {
                        let objects = level == 0 && matches(nameStart, nameLength, "Objects")
                        try walk(from: childStart, to: endOffset, parent: index, level: objects ? 1 : 2)
                    }
                }
                pos = endOffset
            }
        }
        try walk(from: 27, to: byteCount, parent: -1, level: 0)
    }

    /// The objects by id and the connections between them.
    private func index() throws {
        if let list = top("Objects") {
            var count = 0
            for _ in children(list) { count += 1 }
            objects.reserveCapacity(count)
            for n in children(list) { objects[try int(n, 0)] = Int32(n) }
        }
        if let list = top("Connections") {
            var count = 0
            for _ in children(list) { count += 1 }
            connections.reserveCapacity(count)
            for n in children(list) where nodes[n].propertyCount >= 3 {
                connections.append(Connection(child: try int(n, 1), parent: try int(n, 2), node: Int32(n)))
            }
        }
    }

    // MARK: - Nodes

    struct Children: Sequence, IteratorProtocol {
        fileprivate let nodes: [Node]
        fileprivate var next_: Int32
        mutating func next() -> Int? {
            guard next_ >= 0 else { return nil }
            defer { next_ = nodes[Int(next_)].nextSibling }
            return Int(next_)
        }
    }

    /// The file's top-level nodes that were read.
    var topLevel: Children { Children(nodes: nodes, next_: nodes.isEmpty ? -1 : 0) }
    func children(_ n: Int) -> Children { Children(nodes: nodes, next_: nodes[n].firstChild) }

    func isNamed(_ n: Int, _ name: StaticString) -> Bool {
        matches(Int(nodes[n].nameStart), Int(nodes[n].nameLength), name)
    }
    func name(_ n: Int) -> String {
        String(decoding: UnsafeRawBufferPointer(start: base + Int(nodes[n].nameStart), count: Int(nodes[n].nameLength)), as: UTF8.self)
    }
    func top(_ name: StaticString) -> Int? { topLevel.first { isNamed($0, name) } }
    func child(_ n: Int, _ name: StaticString) -> Int? { children(n).first { isNamed($0, name) } }
    /// The node of the object with this id, if it is one that was read.
    func object(_ id: Int64) -> Int? { objects[id].map(Int.init) }

    // MARK: - Properties

    /// Where property `i` of node `n` lies (its type code).
    private func property(_ n: Int, _ i: Int) throws -> Int {
        let node = nodes[n]
        guard i >= 0, i < Int(node.propertyCount) else { throw FBXError.invalid("\(name(n)) has no property \(i)") }
        var pos = Int(node.propertyStart)
        for _ in 0..<i {
            switch try load(pos, as: UInt8.self) {
            case UInt8(ascii: "C"): pos += 2
            case UInt8(ascii: "Y"): pos += 3
            case UInt8(ascii: "I"), UInt8(ascii: "F"): pos += 5
            case UInt8(ascii: "D"), UInt8(ascii: "L"): pos += 9
            case UInt8(ascii: "S"), UInt8(ascii: "R"): pos += 5 + Int(try load(pos + 1, as: UInt32.self))
            case UInt8(ascii: "f"), UInt8(ascii: "d"), UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "b"):
                pos += 13 + Int(try load(pos + 9, as: UInt32.self))
            default: throw FBXError.invalid("\(name(n)) has a property of an unknown type")
            }
        }
        return pos
    }

    /// An integer property (of any width).
    func int(_ n: Int, _ i: Int) throws -> Int64 {
        let pos = try property(n, i)
        switch try load(pos, as: UInt8.self) {
        case UInt8(ascii: "L"): return try load(pos + 1, as: Int64.self)
        case UInt8(ascii: "I"): return Int64(try load(pos + 1, as: Int32.self))
        case UInt8(ascii: "Y"): return Int64(try load(pos + 1, as: Int16.self))
        case UInt8(ascii: "C"): return Int64(try load(pos + 1, as: UInt8.self))
        default: throw FBXError.invalid("property \(i) of \(name(n)) is not an integer")
        }
    }

    /// A number property (float, double or integer).
    func double(_ n: Int, _ i: Int) throws -> Double {
        let pos = try property(n, i)
        switch try load(pos, as: UInt8.self) {
        case UInt8(ascii: "D"): return try load(pos + 1, as: Double.self)
        case UInt8(ascii: "F"): return Double(try load(pos + 1, as: Float.self))
        default: return Double(try int(n, i))
        }
    }

    /// A string or raw property's bytes, in the mapped file (valid while this object lives).
    func bytes(_ n: Int, _ i: Int) throws -> UnsafeRawBufferPointer {
        let pos = try property(n, i)
        let type = try load(pos, as: UInt8.self)
        guard type == UInt8(ascii: "S") || type == UInt8(ascii: "R") else {
            throw FBXError.invalid("property \(i) of \(name(n)) is not a string")
        }
        let length = Int(try load(pos + 1, as: UInt32.self))
        guard pos + 5 + length <= byteCount else { throw FBXError.invalid("\(url.lastPathComponent) is truncated") }
        return UnsafeRawBufferPointer(start: base + pos + 5, count: length)
    }

    /// A string property up to its first zero byte: an object's name without its class ("name\0\u{1}Model").
    func string(_ n: Int, _ i: Int) throws -> String {
        let b = try bytes(n, i)
        return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }

    func propertyIs(_ n: Int, _ i: Int, _ text: StaticString) -> Bool {
        guard let b = try? bytes(n, i) else { return false }
        return b.count == text.utf8CodeUnitCount && memcmp(b.baseAddress, text.utf8Start, b.count) == 0
    }

    /// An array property, inflated if it is stored compressed. `T` must be the type the file holds.
    func array<T: FBXArrayElement>(_ n: Int, _ i: Int = 0, as type: T.Type = T.self) throws -> [T] {
        let pos = try property(n, i)
        guard try load(pos, as: UInt8.self) == T.fbxCode else {
            throw FBXError.invalid("property \(i) of \(name(n)) is not an array of \(T.self)")
        }
        let length = Int(try load(pos + 1, as: UInt32.self)), encoding = try load(pos + 5, as: UInt32.self)
        let stored = Int(try load(pos + 9, as: UInt32.self))
        let bytes = length * MemoryLayout<T>.stride
        guard pos + 13 + stored <= byteCount else { throw FBXError.invalid("\(url.lastPathComponent) is truncated") }
        // Before anything is allocated: a stored array has its size, and deflate packs at most about 1030 to 1.
        guard encoding == 0 ? stored == bytes : bytes / 1100 <= stored else {
            throw FBXError.invalid("an array of \(name(n)) has the wrong size")
        }
        let source = base + pos + 13
        return try [T](unsafeUninitializedCapacity: length) { out, initialized in
            initialized = 0
            guard length > 0, let destination = UnsafeMutableRawPointer(out.baseAddress) else { return }
            switch encoding {
            case 0:
                memcpy(destination, source, bytes)
            case 1:
                // A zlib stream: two header bytes, then the deflate data Compression's "ZLIB" reads.
                guard stored > 2 else { throw FBXError.invalid("an array of \(name(n)) is empty") }
                let written = compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), bytes,
                                                        (source + 2).assumingMemoryBound(to: UInt8.self), stored - 2,
                                                        nil, COMPRESSION_ZLIB)
                guard written == bytes else {
                    throw FBXError.invalid("an array of \(name(n)) inflates to \(written) bytes instead of \(bytes)")
                }
            default:
                throw FBXError.unsupported("array encoding \(encoding)")
            }
            initialized = length
        }
    }

    // MARK: - Properties70

    /// The `P` record called `name` in the object's `Properties70`, if it has one (its values start at property 4).
    func property70(_ object: Int, _ name: StaticString) -> Int? {
        guard let list = child(object, "Properties70") else { return nil }
        return children(list).first { propertyIs($0, 0, name) }
    }

    /// A three-component `Properties70` value (a translation, rotation or colour).
    func vector70(_ object: Int, _ name: StaticString) throws -> SIMD3<Double>? {
        guard let p = property70(object, name), nodes[p].propertyCount >= 7 else { return nil }
        return SIMD3(try double(p, 4), try double(p, 5), try double(p, 6))
    }
}
