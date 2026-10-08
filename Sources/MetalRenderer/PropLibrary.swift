import Foundation
import simd

/// Furniture from glTF files, in place of the generated pieces (FurnitureKit): `Assets/Props/props.json` lists them,
///
///     {"props": [{"file": "Props/armchair.glb", "replaces": "armchair", "rooms": ["living"], "chance": 0.5}]}
///
/// each a model (its path from the assets folder), the generated piece it stands in for, in which rooms (all, if
/// none are named) and how often. A model is fitted into the piece's box (scaled evenly, standing on its floor, its
/// front, +z, into the room) wherever the furnishing put that piece; the piece's colliders stay. The folder is
/// `METALRENDERER_PROPS` if set (`none`: no models).
final class PropLibrary {
    struct Entry: Codable, Equatable {
        var file: String
        var replaces: FurnitureItem.Kind
        var rooms: [RoomType]? = nil
        var chance: Float? = nil
    }
    struct File: Codable {
        var props: [Entry]
    }

    let entries: [Entry]
    let folder: URL
    /// The models, loaded the first time they are asked for: each with its bounds.
    private var models: [Int: (model: GLTFModel, url: URL, lo: SIMD3<Float>, hi: SIMD3<Float>)?] = [:]
    private let lock = NSLock()

    init(entries: [Entry], folder: URL) {
        self.entries = entries
        self.folder = folder
    }

    /// The assets folder's list, read once (a test sets its own).
    static var shared: PropLibrary = {
        let env = ProcessInfo.processInfo.environment["METALRENDERER_PROPS"]
        let assets = Scene.assetsDirectory
        guard env != "none" else { return PropLibrary(entries: [], folder: assets) }
        let list = env.map { URL(fileURLWithPath: $0) } ?? assets.appendingPathComponent("Props/props.json")
        guard let data = try? Data(contentsOf: list) else { return PropLibrary(entries: [], folder: assets) }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            print("Props: \(file.props.count) models from \(list.path)")
            return PropLibrary(entries: file.props, folder: assets)
        } catch {
            print("Props: \(list.path) doesn't read: \(error)")
            return PropLibrary(entries: [], folder: assets)
        }
    }()

    /// What the list holds, said in a few characters (the interiors' storeys are made of it).
    lazy var fingerprint: Int = {
        var h = Hasher()
        for e in entries { h.combine(e.file); h.combine(e.replaces); h.combine(e.rooms); h.combine(e.chance) }
        return h.finalize()
    }()

    /// The entry for a piece of `kind` in a room of `room`, if one takes its place (by `u`, 0...1).
    func entry(for kind: FurnitureItem.Kind, in room: RoomType, u: Float) -> Int? {
        entries.indices.first { i in
            let e = entries[i]
            return e.replaces == kind && (e.rooms?.contains(room) ?? true) && u < (e.chance ?? 1)
        }
    }

    /// Entry `i`'s model and its bounds, loaded the first time (nil if it doesn't load).
    func model(_ i: Int) -> (model: GLTFModel, url: URL, lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        lock.lock()
        defer { lock.unlock() }
        if let made = models[i] { return made }
        let url = folder.appendingPathComponent(entries[i].file)
        var made: (model: GLTFModel, url: URL, lo: SIMD3<Float>, hi: SIMD3<Float>)?
        do {
            let model = try GLTFLoader.load(url)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for mesh in model.meshes { for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
            if lo.x <= hi.x { made = (model, url, lo, hi) }
        } catch {
            print("Props: \(url.path) doesn't load: \(error)")
        }
        models[i] = made
        return made
    }

    /// Where model `i` goes to fill a piece's box of `size` (its own frame: x along the wall, z into the room, y up):
    /// scaled evenly to fit, standing on the floor in the box's middle.
    func fit(_ i: Int, into size: SIMD3<Float>) -> float4x4? {
        guard let m = model(i) else { return nil }
        let extent = simd_max(m.hi - m.lo, SIMD3(repeating: 1e-4))
        let s = min(size.x / extent.x, size.z / extent.z, size.y > 0.05 ? size.y / extent.y : .infinity)
        let base = SIMD3((m.lo.x + m.hi.x) / 2, m.lo.y, (m.lo.z + m.hi.z) / 2)
        return translate([size.x / 2, 0, size.z / 2]) * float4x4(diagonal: SIMD4(s, s, s, 1)) * translate(-base)
    }
}
