import Foundation
import simd

/// The texture slots a procedural material's bake fills (MatOutputs' textures).
enum ProcSlot: Int, CaseIterable {
    case baseColor, orm, normal, emissive, height, opacity

    var srgb: Bool { self == .baseColor || self == .emissive }
}

/// A material whose textures a Material Designer graph bakes (MaterialBake): the graph's name (looked up in the
/// scene's material catalog, SceneSettings.materials), its material, the scene's texture slots its bake fills (each a
/// 1 × 1 placeholder until the renderer puts the bake's texture in its place: Renderer.applyProcedural), and what the
/// graph's structure says it has (its output channels: opacity decides how the scene is traced).
struct ProceduralMaterial {
    var graph: String
    var material: Int
    var slots: [UInt32]          // per ProcSlot
    var channels: Set<MatChannel>
    /// The graph as the scene was made with it (its bake's key: MaterialBake.key).
    var made: MaterialGraph?
    /// The material's fingerprint before it was made procedural (MaterialAssignments).
    var fingerprint = ""
}

extension Scene {
    /// A material that `graph` (by name, in `catalog`) bakes: until its bake comes, a neutral grey of its own (the
    /// renderer fills its textures and values as the graph says). Its index.
    @discardableResult
    func addProceduralMaterial(graph name: String, catalog: MaterialCatalog) -> Int {
        let index = addMaterial(GPUMaterial(albedo: SIMD4(0.5, 0.5, 0.5, 0), emission: SIMD4(0, 0, 0, 0.6), params: SIMD4(1, 1, 0, 0)))
        makeProcedural(index, graph: name, catalog: catalog)
        return index
    }

    /// Material `index` as `graph`'s (an assignment: MaterialAssignments): its slots, its extras; a neutral grey until
    /// its bake comes.
    func makeProcedural(_ index: Int, graph name: String, catalog: MaterialCatalog) {
        let g = catalog.graph(name)
        let channels = Set(g?.channels.keys.map { $0 } ?? [])
        let fingerprint = procedural.first { $0.material == index }?.fingerprint ?? MaterialAssignments.fingerprint(materials[index])
        setMaterial(index, GPUMaterial(albedo: SIMD4(0.5, 0.5, 0.5, 0), emission: SIMD4(0, 0, 0, 0.6), params: SIMD4(1, 1, 0, 0)))
        var slots: [UInt32] = []
        for slot in ProcSlot.allCases {
            // A white pixel, named by the graph and the slot: the same graph's slot is the same texture in another scene.
            slots.append(addTexture(TextureSource(data: Data([255, 255, 255, 255]), srgb: slot.srgb, name: "procedural/\(name)/\(slot)",
                                                  modelPath: GeneratedCache.folder.appendingPathComponent("procedural").path,
                                                  cacheKey: "procedural-\(slot)", raw: (1, 1))))
        }
        var extra = GPUMaterialExtra()
        extra.textures.z = 1
        if let g { extra.surface = SIMD4(0, g.surface.uvScale, g.surface.alphaCutoff, 0) }
        if channels.contains(.opacity) { extra.textures.y = slots[ProcSlot.opacity.rawValue] }
        materialExtras[index] = extra
        procedural.removeAll { $0.material == index }
        procedural.append(ProceduralMaterial(graph: name, material: index, slots: slots, channels: channels, made: g, fingerprint: fingerprint))
    }

    /// Some procedural material cuts holes (its graph has an opacity output) in a scene whose instances are its own
    /// (not an open world's blocks): the queries alpha-test those instances (OPACITY).
    var hasOpacity: Bool { !hasGroups && procedural.contains { $0.channels.contains(.opacity) } }

    /// The instances whose material cuts holes: for each, its opacity texture, mesh, cutoff and UV scale (MSL
    /// TraceScene.opacity, per instance: the texture ~0 for every other).
    func opacityRecords() -> [SIMD4<UInt32>] {
        guard hasOpacity else { return [] }
        var records = [SIMD4<UInt32>](repeating: SIMD4(.max, 0, 0, 0), count: instances.count)
        for (i, inst) in instances.enumerated() {
            guard let e = materialExtras[inst.material], e.textures.y != .max, inst.mesh >= 0 else { continue }
            records[i] = SIMD4(e.textures.y, UInt32(inst.mesh), e.surface.z.bitPattern, e.surface.y.bitPattern)
        }
        return records
    }

    /// Whether instance `i` is alpha-tested (its structure's descriptor isn't opaque).
    func cutsHoles(_ i: Int) -> Bool {
        guard hasOpacity, let e = materialExtras[instances[i].material] else { return false }
        return e.textures.y != .max
    }

    /// The meshes the raster leaves to the rays: an alpha-tested instance's.
    var holeMeshes: Set<Int> {
        guard hasOpacity else { return [] }
        return Set(instances.indices.filter { cutsHoles($0) }.map { instances[$0].mesh })
    }

    /// Every material's extras as the GPU reads them (MSL MaterialExtra: the defaults for a material without).
    func extrasArray() -> [GPUMaterialExtra] {
        guard !materialExtras.isEmpty else { return [] }
        var all = [GPUMaterialExtra](repeating: GPUMaterialExtra(), count: materials.count)
        for (i, e) in materialExtras where i < all.count { all[i] = e }
        return all
    }
}
