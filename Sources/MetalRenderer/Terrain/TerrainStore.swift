import EngineCore
import Foundation
import Physics
import Plants
import simd

/// Terrains on disk: `Assets/Terrains/<slug>.terrain/`, a folder each — `terrain.json` (the document, the base it was
/// edited over and its edited tiles) and per edited tile its arrays as they are in memory (`tiles/<x>_<z>.delta`: a
/// float a sample; `.paint`: 16 bytes a sample; `.mask`, `.protect`: a byte a sample). Only edited tiles are written:
/// the open world's terrain is its few edited tiles. The folder is `METALRENDERER_TERRAINS` if set (`none`: nothing
/// is read or written, for benchmarks that must draw the procedural ground), or `Terrains` in the assets folder.
enum TerrainStore {
    static let suffix = ".terrain"

    static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_TERRAINS"] {
        case "none": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Terrains")
        }
    }

    static func package(_ name: String, in folder: URL? = TerrainStore.folder) -> URL? {
        folder?.appendingPathComponent(TerrainDocument.slug(name) + suffix)
    }

    /// What `terrain.json` holds besides the document.
    struct Manifest: Codable {
        var document: TerrainDocument
        var base: String                // TerrainBase.fingerprint
        var grid: TerrainGrid
        var tiles: [TileRecord]
    }
    struct TileRecord: Codable {
        var x: Int, z: Int
        var paint: Bool
        var protect: Bool
    }

    /// The saved terrain of that name: its document, and its tiles if they were edited over this `base` (over
    /// another, they would be edits of other ground: left out, with a word on the console).
    static func load(_ name: String, base: TerrainBase, in folder: URL? = TerrainStore.folder)
        -> (document: TerrainDocument, tiles: [SIMD2<Int>: TerrainTile])? {
        guard let package = package(name, in: folder), let data = try? Data(contentsOf: package.appendingPathComponent("terrain.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        guard manifest.base == base.fingerprint, manifest.grid == base.grid else {
            print("Terrain \(name): saved over another ground (\(manifest.base)), its edits are left out")
            return (manifest.document, [:])
        }
        let n = base.grid.tileCells
        var tiles: [SIMD2<Int>: TerrainTile] = [:]
        let folder = package.appendingPathComponent("tiles")
        for r in manifest.tiles {
            let stem = folder.appendingPathComponent("\(r.x)_\(r.z)")
            guard let delta = read(stem.appendingPathExtension("delta"), Float.self, count: n * n) else { continue }
            var tile = TerrainTile(delta: delta)
            if r.paint {
                tile.paint = read(stem.appendingPathExtension("paint"), UInt8.self, count: n * n * TerrainTile.layers)
                tile.mask = read(stem.appendingPathExtension("mask"), UInt8.self, count: n * n)
                if tile.paint == nil || tile.mask == nil { (tile.paint, tile.mask) = (nil, nil) }
            }
            if r.protect { tile.protect = read(stem.appendingPathExtension("protect"), UInt8.self, count: n * n) }
            tiles[SIMD2(r.x, r.z)] = tile
        }
        return (manifest.document, tiles)
    }

    private static func read<T>(_ url: URL, _ type: T.Type, count: Int) -> [T]? {
        guard let data = try? Data(contentsOf: url), data.count == count * MemoryLayout<T>.stride else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }

    private static func write<T>(_ array: [T], to url: URL) throws {
        try array.withUnsafeBytes { Data($0) }.write(to: url, options: .atomic)
    }

    /// Writes the document and the edited tiles (the others' files go).
    static func save(_ document: TerrainDocument, snapshot: TerrainSnapshot, in folder: URL? = TerrainStore.folder) throws {
        guard let package = package(document.name, in: folder) else { return }
        let folder = package.appendingPathComponent("tiles")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [TileRecord] = [], kept = Set<String>()
        for (t, tile) in snapshot.tiles.sorted(by: { ($0.key.y, $0.key.x) < ($1.key.y, $1.key.x) }) where !tile.isEmpty {
            let stem = folder.appendingPathComponent("\(t.x)_\(t.y)")
            try write(tile.delta, to: stem.appendingPathExtension("delta"))
            kept.insert("\(t.x)_\(t.y).delta")
            let painted = tile.paint != nil && tile.mask != nil
            if painted, let paint = tile.paint, let mask = tile.mask {
                try write(paint, to: stem.appendingPathExtension("paint"))
                try write(mask, to: stem.appendingPathExtension("mask"))
                kept.formUnion(["\(t.x)_\(t.y).paint", "\(t.x)_\(t.y).mask"])
            }
            if let protect = tile.protect {
                try write(protect, to: stem.appendingPathExtension("protect"))
                kept.insert("\(t.x)_\(t.y).protect")
            }
            records.append(TileRecord(x: t.x, z: t.y, paint: painted, protect: tile.protect != nil))
        }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        let manifest = Manifest(document: document, base: snapshot.base.fingerprint, grid: snapshot.grid, tiles: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: package.appendingPathComponent("terrain.json"), options: .atomic)
    }

    /// The names of the saved terrains.
    static func names() -> [String] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(suffix) }.compactMap { file in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file).appendingPathComponent("terrain.json")),
                  let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
            return m.document.name
        }.sorted()
    }
}

/// The terrains the scenes are made with, by name (each scene's own: "forest-7", "world-1"...): what the editor
/// edits (in memory, its edits shown at once) and what is saved (TerrainStore). A terrain is opened the first time a
/// scene asks for it, from its file if it has one. Any thread.
package final class TerrainDocuments {
    package static let shared = TerrainDocuments()

    package final class Entry {
        package var document: TerrainDocument
        package let field: TerrainField
        /// Counts the document's edits (its layers', rules', water's...): the renderer takes them in place.
        package var version = 0
        /// The field's revision and the document's version when it was last saved (or opened).
        package var savedRevision = 0
        package var savedVersion = 0

        package init(document: TerrainDocument, field: TerrainField) {
            self.document = document
            self.field = field
            savedRevision = field.revision
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// The terrain of that name over `base`: the open one, or opened now (from its file, else new with `document`'s
    /// layers). One whose base changed (another seed under the same name) is opened again over the new one.
    package func open(_ name: String, base: @autoclosure () -> TerrainBase, document: @autoclosure () -> TerrainDocument) -> Entry {
        lock.lock()
        if let e = entries[name] { lock.unlock(); return e }
        lock.unlock()
        let b = base()
        let loaded = TerrainStore.load(name, base: b)
        var doc = loaded?.document ?? document()
        doc.name = name
        let entry = Entry(document: doc, field: TerrainField(base: b, tiles: loaded?.tiles ?? [:]))
        lock.lock(); defer { lock.unlock() }
        if let e = entries[name] { return e }
        entries[name] = entry
        return entry
    }

    /// The open terrain of that name, if it is open.
    package func entry(_ name: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[name]
    }

    /// An edit of a document (its layers, rules, generator, scatter or water).
    package func update(_ document: TerrainDocument) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[document.name] else { return }
        e.document = document
        e.version += 1
    }

    package func document(_ name: String) -> TerrainDocument? {
        lock.lock(); defer { lock.unlock() }
        return entries[name]?.document
    }

    package func version(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries[name]?.version ?? 0
    }

    /// Whether it has edits that aren't saved.
    package func isDirty(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[name] else { return false }
        return e.field.revision != e.savedRevision || e.version != e.savedVersion
    }

    /// Saves it (TerrainStore).
    package func save(_ name: String) throws {
        guard let e = entry(name) else { return }
        lock.lock()
        let document = e.document, version = e.version
        lock.unlock()
        let snapshot = e.field.snapshot(), revision = e.field.revision
        try TerrainStore.save(document, snapshot: snapshot)
        lock.lock(); defer { lock.unlock() }
        e.savedRevision = revision
        e.savedVersion = version
    }

    /// The names of the open terrains.
    package var openNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.sorted()
    }

    /// Forgets an open terrain (tests; a terrain whose base changed).
    package func close(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        entries[name] = nil
    }
}
