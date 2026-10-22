import Effects
import EngineCore
import Foundation
import simd

/// What a layer can write: the texture set's channels (the normal is the height's and the graphs' normals', never
/// painted as such).
package enum PaintChannel: String, Codable, CaseIterable, Identifiable {
    case color, roughness, metallic, height, emissive, opacity
    package var id: String { rawValue }
    package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// Its paint texture holds rgb + coverage (else value + coverage).
    package var isColor: Bool { self == .color || self == .emissive }
    /// Its index in the GPU's layer records (PaintGPULayer) and the stroke's channel mask.
    package var bit: UInt32 { UInt32(1) << UInt32(PaintChannel.allCases.firstIndex(of: self)!) }
}

/// How a layer's colour goes over what is under it (Material Designer's blend modes, as MatBlendMode numbers them).
package enum PaintBlend: Int, Codable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, add, subtract, darken, lighten, softLight
    package var id: Int { rawValue }
    package var title: String {
        switch self {
        case .softLight: return "Soft light"
        default: return "\(self)".prefix(1).uppercased() + "\(self)".dropFirst()
        }
    }
}

/// How a layer's height goes over what is under it: replaced, raised by it (above 0.5), lowered by it.
package enum PaintHeightBlend: Int, Codable, CaseIterable, Identifiable {
    case normal, add, subtract
    package var id: Int { rawValue }
    package var title: String { "\(self)".prefix(1).uppercased() + "\(self)".dropFirst() }
}

/// A layer's values where it has no texture (a fill's), and a brush's.
package struct PaintValues: Codable, Equatable {
    package var color = SIMD3<Float>(0.5, 0.5, 0.5)     // linear
    package var roughness: Float = 0.5
    package var metallic: Float = 0
    package var height: Float = 0.5                     // 0.5 = the surface; 0...1 is -depth...+depth (PaintDocument.heightDepth)
    package var emissive = SIMD3<Float>(0, 0, 0)        // linear, x PaintDocument.emissiveIntensity
    package var opacity: Float = 1

    /// (As the memberwise initializer, for the modules above this one.)
    package init(color: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5), roughness: Float = 0.5, metallic: Float = 0, height: Float = 0.5, emissive: SIMD3<Float> = SIMD3<Float>(0, 0, 0), opacity: Float = 1) {
        self.color = color
        self.roughness = roughness
        self.metallic = metallic
        self.height = height
        self.emissive = emissive
        self.opacity = opacity
    }
}

/// A mask's generated part: from the object's bakes (PaintBake: curvature, occlusion, thickness, position, normal),
/// noise, or a Material Designer graph that reads them.
package struct PaintGenerator: Codable, Equatable {
    package enum Kind: String, Codable, CaseIterable, Identifiable {
        case edgeWear, cavityDirt, dust, rustLeaks, curvature, occlusion, thickness, height, graph
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .edgeWear: return "Edge wear"
            case .cavityDirt: return "Dirt in cavities"
            case .dust: return "Dust on top"
            case .rustLeaks: return "Rust and leaks"
            case .curvature: return "Curvature"
            case .occlusion: return "Ambient occlusion"
            case .thickness: return "Thickness"
            case .height: return "Height (Y)"
            case .graph: return "Graph"
            }
        }
    }
    package var kind = Kind.edgeWear
    package var amount: Float = 0.5        // how much of the surface it takes
    package var contrast: Float = 0.5      // how hard its edge is
    package var scale: Float = 4           // its noise's features per metre
    package var seed = 1
    package var invert = false
    package var graph = ""                 // .graph: the Material Designer graph's name (its output "mask" or base colour's luminance)

    /// (As the memberwise initializer, for the modules above this one.)
    package init(kind: Kind = Kind.edgeWear, amount: Float = 0.5, contrast: Float = 0.5, scale: Float = 4, seed: Int = 1, invert: Bool = false, graph: String = "") {
        self.kind = kind
        self.amount = amount
        self.contrast = contrast
        self.scale = scale
        self.seed = seed
        self.invert = invert
        self.graph = graph
    }
}

/// A layer's mask: `base` (white or black) where nothing is generated, or the generator; then what is painted on it
/// (a paint channel of its own: the mask's value and coverage, over the base).
package struct PaintMask: Codable, Equatable {
    package var base: Float = 1
    package var generator: PaintGenerator? = nil
    package var painted = false             // has a painted part (its texture: PaintLayerData.mask)

    /// (As the memberwise initializer, for the modules above this one.)
    package init(base: Float = 1, generator: PaintGenerator? = nil, painted: Bool = false) {
        self.base = base
        self.generator = generator
        self.painted = painted
    }
}

/// One layer of a painted object: a fill (values, or a Material Designer graph's bake projected onto it) or a paint
/// layer (what the brush put there, channel by channel), through its mask, at its opacity, by its blend modes.
package struct PaintLayer: Codable, Equatable, Identifiable {
    package enum Kind: String, Codable { case fill, paint }
    package enum Projection: String, Codable, CaseIterable, Identifiable {
        case triplanar, uv
        package var id: String { rawValue }
        package var title: String { self == .uv ? "UV" : "Triplanar" }
    }
    package var id = UUID()
    package var name = "Layer"
    package var kind = Kind.paint
    package var visible = true
    package var opacity: Float = 1
    package var blend = PaintBlend.normal
    package var heightBlend = PaintHeightBlend.normal
    package var channels: Set<PaintChannel> = [.color, .roughness, .metallic, .height]
    package var values = PaintValues()
    /// A fill's graph (by name: MaterialCatalog's), its projection and its tiles per metre.
    package var graph: String? = nil
    package var projection = Projection.triplanar
    package var tiling: Float = 1
    package var mask: PaintMask? = nil
    /// "original": a paint layer filled, when it is first made, from the object as it was (its materials' textures at
    /// its own UVs); nil: empty.
    package var source: String? = nil

    package static func fill(_ name: String, _ values: PaintValues, channels: Set<PaintChannel> = [.color, .roughness, .metallic]) -> PaintLayer {
        PaintLayer(name: name, kind: .fill, channels: channels, values: values)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(id: UUID = UUID(), name: String = "Layer", kind: Kind = Kind.paint, visible: Bool = true, opacity: Float = 1, blend: PaintBlend = PaintBlend.normal, heightBlend: PaintHeightBlend = PaintHeightBlend.normal, channels: Set<PaintChannel> = [.color, .roughness, .metallic, .height], values: PaintValues = PaintValues(), graph: String? = nil, projection: Projection = Projection.triplanar, tiling: Float = 1, mask: PaintMask? = nil, source: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.visible = visible
        self.opacity = opacity
        self.blend = blend
        self.heightBlend = heightBlend
        self.channels = channels
        self.values = values
        self.graph = graph
        self.projection = projection
        self.tiling = tiling
        self.mask = mask
        self.source = source
    }
}

/// A painted object's document: its layers, bottom first, and how its texture set is made (resolution, the height's
/// depth, the emission's strength). Its pixels (paint layers and painted masks) are the renderer's while it is open
/// (PainterSession) and PNGs in its package when saved (PainterStore).
package struct PaintDocument: Codable, Equatable {
    package var name: String
    package var resolution = 2048
    package var layers: [PaintLayer] = [PaintDocument.baseLayer]
    /// How far height 0 and 1 are from the surface (metres): the normal the height gives, and parallax if any.
    package var heightDepth: Float = 0.004
    package var parallax = false
    package var emissiveIntensity: Float = 4
    package var normalStrength: Float = 1
    package var aoStrength: Float = 1
    package var alphaCutoff: Float = 0.5

    package static let resolutions = [1024, 2048, 4096]
    package static let baseLayer = PaintLayer(name: "Base", kind: .fill, channels: [.color, .roughness, .metallic],
                                      values: PaintValues(color: [0.5, 0.5, 0.5], roughness: 0.55))

    package init(name: String, resolution: Int = 2048) {
        self.name = name
        self.resolution = resolution
    }

    /// What its layers write, together: opacity and emission decide how the scene is made (the painted material's
    /// holes; its emission's strength).
    package var channels: Set<PaintChannel> { layers.filter(\.visible).reduce(into: []) { $0.formUnion($1.channels) } }
    package var opacity: Bool { channels.contains(.opacity) }
    package var emissive: Bool { channels.contains(.emissive) }

    /// A short file name for it.
    package static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        resolution = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? 2048
        layers = try c.decodeIfPresent([PaintLayer].self, forKey: .layers) ?? [PaintDocument.baseLayer]
        heightDepth = try c.decodeIfPresent(Float.self, forKey: .heightDepth) ?? 0.004
        parallax = try c.decodeIfPresent(Bool.self, forKey: .parallax) ?? false
        emissiveIntensity = try c.decodeIfPresent(Float.self, forKey: .emissiveIntensity) ?? 4
        normalStrength = try c.decodeIfPresent(Float.self, forKey: .normalStrength) ?? 1
        aoStrength = try c.decodeIfPresent(Float.self, forKey: .aoStrength) ?? 1
        alphaCutoff = try c.decodeIfPresent(Float.self, forKey: .alphaCutoff) ?? 0.5
    }
}

/// The documents the scenes paint with, by name: what the painter edits (in memory, its edits shown at once), and
/// what is saved (PainterStore) for the others. Any thread (the painter's window edits on the main thread, the scenes
/// are made and the frames read on others).
package final class PaintDocuments {
    package static let shared = PaintDocuments()
    private let lock = NSLock()
    private var open: [String: PaintDocument] = [:]
    private var versions: [String: Int] = [:]

    package func document(_ name: String) -> PaintDocument {
        lock.lock()
        if let d = open[name] { lock.unlock(); return d }
        lock.unlock()
        let d = PainterStore.load(name) ?? PaintDocument(name: name)
        lock.lock(); defer { lock.unlock() }
        if let d = open[name] { return d }
        open[name] = d
        return d
    }

    /// An edit of a document's layers (the renderer's sessions composite it again).
    package func update(_ d: PaintDocument) {
        lock.lock(); defer { lock.unlock() }
        open[d.name] = d
        versions[d.name, default: 0] += 1
    }

    /// How many edits a document has had.
    package func version(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return versions[name] ?? 0
    }

    package func forget(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        open[name] = nil
        versions[name] = nil
    }
}
