import CryptoKit
import Foundation

/// A cache file of arrays: what a generator made, as the bytes the renderer uses, so that nothing is parsed on the
/// way back in. A header names the file's format, the key it was made for and its sections; each section is an array
/// of one fixed-size type, at an offset that is a multiple of the page size (a buffer can be made over it in place).
///
///   UInt32 magic, UInt32 version, UInt32 key length, UInt32 section count, the key (UTF-8),
///   per section: UInt32 id, UInt32 stride, UInt64 offset, UInt64 bytes; then zeros to the next page; the sections.
///
/// A file is read mapped. One of another format, for another key, or cut short is a miss (`init?` gives nil): the
/// caller makes the content again and writes the file over it.
struct SectionFile {
    static let magic: UInt32 = 0x4653_524D       // "MRSF"
    static let version: UInt32 = 1
    static let pageSize = 16384                   // Apple silicon's; a multiple of Intel's 4096

    /// A section's name: four characters.
    static func id(_ name: String) -> UInt32 {
        precondition(name.utf8.count == 4, "a section's name is four characters")
        return name.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private let data: Data
    private var sections: [UInt32: (offset: Int, bytes: Int, stride: Int)] = [:]

    init?(url: URL, key: String) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 16 else { return nil }
        func word(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        func long(_ at: Int) -> UInt64 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) } }
        guard word(0) == SectionFile.magic, word(4) == SectionFile.version else { return nil }
        let keyLength = Int(word(8)), count = Int(word(12))
        let table = 16 + keyLength
        guard keyLength < 4096, count < 4096, data.count >= table + count * 24,
              data.subdata(in: 16..<table) == Data(key.utf8) else { return nil }
        for s in 0..<count {
            let at = table + s * 24
            let offset = long(at + 8), bytes = long(at + 16), stride = Int(word(at + 4))
            guard stride > 0, offset % UInt64(SectionFile.pageSize) == 0, bytes % UInt64(stride) == 0,
                  offset <= UInt64(data.count), bytes <= UInt64(data.count) - offset else { return nil }
            sections[word(at)] = (Int(offset), Int(bytes), stride)
        }
        self.data = data
    }

    /// Section `id` as an array of `T`, copied out of the mapping; nil if the file has none, or one of another type's
    /// size.
    func array<T>(_ id: UInt32, of type: T.Type = T.self) -> [T]? {
        guard let s = sections[id], s.stride == MemoryLayout<T>.stride else { return nil }
        let count = s.bytes / s.stride
        return [T](unsafeUninitializedCapacity: count) { out, initialized in
            data.withUnsafeBytes { raw in
                UnsafeMutableRawBufferPointer(out).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[s.offset..<(s.offset + s.bytes)]))
            }
            initialized = count
        }
    }

    /// Section `id`'s bytes in the mapping, which stays mapped while the file (or what `body` keeps of it) lives.
    func withBytes<R>(_ id: UInt32, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        guard let s = sections[id] else { return nil }
        return try data.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[s.offset..<(s.offset + s.bytes)])) }
    }

    /// The sections of a file to write. The types are plain values without references (the GPU's structs, numbers).
    struct Writer {
        private var sections: [(id: UInt32, stride: Int, bytes: Data)] = []

        mutating func add<T>(_ id: UInt32, _ values: [T]) {
            sections.append((id, MemoryLayout<T>.stride, values.withUnsafeBytes { Data($0) }))
        }

        func write(to url: URL, key: String) throws {
            let keyBytes = Data(key.utf8)
            func aligned(_ n: Int) -> Int { (n + SectionFile.pageSize - 1) / SectionFile.pageSize * SectionFile.pageSize }
            var out = Data()
            func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
            put(SectionFile.magic); put(SectionFile.version); put(UInt32(keyBytes.count)); put(UInt32(sections.count))
            out.append(keyBytes)
            var offset = aligned(out.count + sections.count * 24)
            for s in sections {
                put(s.id); put(UInt32(s.stride)); put(UInt64(offset)); put(UInt64(s.bytes.count))
                offset = aligned(offset + s.bytes.count)
            }
            for s in sections {
                out.append(Data(count: aligned(out.count) - out.count))
                out.append(s.bytes)
            }
            try CacheFile.write(out, to: url)
        }
    }
}

/// The cache of what the generated scenes derive (generated textures' mip chains, the meshes' bottom-level trees,
/// the plants' voxels): files in ~/Library/Caches/MetalRenderer/generated, named by what they were made from, so a
/// change of the input is another file and a stale one is never read. `METALRENDERER_CACHE=0` reads and writes
/// none of it, `=1` all of it; `METALRENDERER_CACHE_MB` caps the folder (4096): the files used longest ago go
/// first, once per launch.
enum GeneratedCache {
    private static let choice = ProcessInfo.processInfo.environment["METALRENDERER_CACHE"]
    static let enabled = choice != "0"
    /// The trees and the voxels are cached where making them is slow: in an unoptimised build, which takes 6.5 s over
    /// the forest's and 0.35 s to read them back. An optimised one builds a city's trees (5.3 M triangles, 0.13 s)
    /// as fast as it hashes its meshes and copies the trees out of a file, so there the cache only costs disk.
    static let cachesTrees: Bool = {
        if let choice { return choice != "0" }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    static let folder: URL = {
        let folder = CacheFile.userFolder.appendingPathComponent("generated")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private static let capBytes = (Int(ProcessInfo.processInfo.environment["METALRENDERER_CACHE_MB"] ?? "") ?? 4096) << 20
    private static let swept: Void = { DispatchQueue.global(qos: .utility).async { sweep() } }()

    /// A hash of arrays' bytes, as a file name: 128 bits of SHA-256 (hardware's, so tens of megabytes cost
    /// milliseconds in a debug build too).
    struct Hasher {
        private var sha = SHA256()
        mutating func add<T>(_ values: [T]) { values.withUnsafeBytes { sha.update(bufferPointer: $0) } }
        mutating func add(_ text: String) { sha.update(data: Data(text.utf8)) }
        func name() -> String { sha.finalize().prefix(16).map { String(format: "%02x", $0) }.joined() }
    }

    /// The file `name` if it is there and was written for `key`. Reading it marks it as used now.
    static func load(_ name: String, key: String) -> SectionFile? {
        guard enabled else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let file = SectionFile(url: url, key: key) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return file
    }

    /// Writes the file `name` for `key`. A failure only means the content is made again next time.
    static func store(_ name: String, key: String, _ writer: SectionFile.Writer) {
        guard enabled else { return }
        _ = swept
        do { try writer.write(to: folder.appendingPathComponent(name), key: key) } catch { print("Cache: \(name) not written: \(error)") }
    }

    /// Deletes the files used longest ago until the folder fits its cap.
    private static func sweep() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, bytes: Int, used: Date)] = []
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.bytes }
        for file in files.sorted(by: { $0.used < $1.used }) where total > capBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.bytes
        }
    }
}
