import Foundation

/// A stack of layers kept to be dropped on any object (the Material Painter's smart materials): their masks generated
/// from the object's bakes (edge wear, dirt in cavities, dust, rust), so they fit wherever they go. The built-in ones,
/// and any saved as `Assets/Painter/Smart/<name>.smart.json`.
struct SmartMaterial: Codable, Equatable, Identifiable {
    var name: String
    var layers: [PaintLayer]
    var id: String { name }

    static let suffix = ".smart.json"
    static var folder: URL? { PainterStore.folder?.appendingPathComponent("Smart") }

    /// Its layers with new ids (a second drop is layers of its own), named after it.
    func instantiate() -> [PaintLayer] {
        layers.map { l in
            var c = l
            c.id = UUID()
            c.name = "\(name): \(l.name)"
            return c
        }
    }

    static func fill(_ name: String, _ v: PaintValues, _ channels: Set<PaintChannel>, mask: PaintGenerator? = nil, base: Float = 1) -> PaintLayer {
        var l = PaintLayer.fill(name, v, channels: channels)
        if let mask { l.mask = PaintMask(base: base, generator: mask) }
        return l
    }

    static let builtIn: [SmartMaterial] = [
        SmartMaterial(name: "Worn Painted Metal", layers: [
            fill("Steel", PaintValues(color: [0.56, 0.57, 0.58], roughness: 0.32, metallic: 1), [.color, .roughness, .metallic]),
            fill("Paint", PaintValues(color: [0.42, 0.05, 0.035], roughness: 0.45, metallic: 0, height: 0.56), [.color, .roughness, .metallic, .height],
                 mask: PaintGenerator(kind: .edgeWear, amount: 0.22, contrast: 0.7, scale: 6, seed: 3, invert: true)),
            fill("Grime", PaintValues(color: [0.07, 0.06, 0.05], roughness: 0.9, metallic: 0), [.color, .roughness, .metallic],
                 mask: PaintGenerator(kind: .cavityDirt, amount: 0.3, contrast: 0.4, scale: 8, seed: 5)),
        ]),
        SmartMaterial(name: "Rusty Iron", layers: [
            fill("Iron", PaintValues(color: [0.33, 0.33, 0.35], roughness: 0.5, metallic: 1), [.color, .roughness, .metallic]),
            fill("Rust", PaintValues(color: [0.32, 0.12, 0.045], roughness: 0.92, metallic: 0, height: 0.58), [.color, .roughness, .metallic, .height],
                 mask: PaintGenerator(kind: .rustLeaks, amount: 0.55, contrast: 0.45, scale: 5, seed: 7)),
            fill("Dust", PaintValues(color: [0.5, 0.45, 0.38], roughness: 0.95, metallic: 0), [.color, .roughness, .metallic],
                 mask: PaintGenerator(kind: .dust, amount: 0.25, contrast: 0.5, scale: 10, seed: 2)),
        ]),
        SmartMaterial(name: "Dusty Plastic", layers: [
            fill("Plastic", PaintValues(color: [0.08, 0.22, 0.55], roughness: 0.35, metallic: 0), [.color, .roughness, .metallic]),
            fill("Dust", PaintValues(color: [0.55, 0.52, 0.47], roughness: 0.95, metallic: 0), [.color, .roughness, .metallic],
                 mask: PaintGenerator(kind: .dust, amount: 0.45, contrast: 0.45, scale: 12, seed: 4)),
            fill("Scuffs", PaintValues(color: [0.2, 0.35, 0.62], roughness: 0.6, metallic: 0), [.color, .roughness],
                 mask: PaintGenerator(kind: .edgeWear, amount: 0.2, contrast: 0.6, scale: 9, seed: 8)),
        ]),
        SmartMaterial(name: "Old Wood", layers: [
            { var l = fill("Planks", PaintValues(), [.color, .roughness, .metallic, .height]); l.graph = "Oak Planks"; l.tiling = 0.8; return l }(),
            fill("Worn edges", PaintValues(color: [0.62, 0.5, 0.34], roughness: 0.7, metallic: 0), [.color, .roughness],
                 mask: PaintGenerator(kind: .edgeWear, amount: 0.3, contrast: 0.5, scale: 7, seed: 6)),
            fill("Dirt", PaintValues(color: [0.09, 0.07, 0.05], roughness: 0.95, metallic: 0), [.color, .roughness],
                 mask: PaintGenerator(kind: .cavityDirt, amount: 0.4, contrast: 0.35, scale: 6, seed: 9)),
        ]),
        SmartMaterial(name: "Grimy Concrete", layers: [
            fill("Concrete", PaintValues(color: [0.5, 0.49, 0.46], roughness: 0.85, metallic: 0), [.color, .roughness, .metallic]),
            fill("Grime", PaintValues(color: [0.16, 0.14, 0.12], roughness: 0.95, metallic: 0), [.color, .roughness],
                 mask: PaintGenerator(kind: .cavityDirt, amount: 0.45, contrast: 0.4, scale: 5, seed: 11)),
            fill("Leaks", PaintValues(color: [0.22, 0.2, 0.17], roughness: 0.8, metallic: 0), [.color, .roughness],
                 mask: PaintGenerator(kind: .rustLeaks, amount: 0.45, contrast: 0.5, scale: 4, seed: 13)),
        ]),
    ]

    /// The built-in ones, then the saved ones (a saved one of a built-in's name replaces it).
    static func all() -> [SmartMaterial] {
        var out = builtIn
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return out }
        for f in files where f.lastPathComponent.hasSuffix(suffix) {
            guard let data = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(SmartMaterial.self, from: data) else { continue }
            out.removeAll { $0.name == m.name }
            out.append(m)
        }
        return out
    }

    /// Saved under its name.
    func save() throws {
        guard let folder = SmartMaterial.folder else { throw MatError("no painter folder") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(PaintDocument.slug(name) + SmartMaterial.suffix), options: .atomic)
    }
}
