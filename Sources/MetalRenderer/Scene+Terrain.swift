import Foundation
import simd

/// What a scene has of its terrain (Terrain/): the field it was made from, and each sector it meshes (a borrowed
/// mesh of its own, named so the next scene of the same terrain takes the same buffer and structure, and an instance
/// at its tile's corner). The renderer meshes the sectors again as the field's edits change them (Renderer+Terrain).
final class SceneTerrain {
    struct Part {
        var sector: TerrainSector
        var mesh: Int
        var instance: Int
        var name: String
        /// The field's revision around the sector when its mesh was made for this scene.
        var revision: Int
    }
    /// The terrain's document's name (TerrainDocuments).
    let name: String
    let field: TerrainField
    let style: TerrainMeshStyle
    /// The world's place that is the scene's origin (x, z): a scene's place is the world's minus it.
    let offset: SIMD2<Double>
    /// The material the sectors' instances name (with the base's kinds, the first of a run: a triangle's is an offset).
    let material: Int
    private(set) var parts: [Part] = []
    /// Layers 1...15's materials, one after the other from `firstLayer` (layer 0 is the sectors' own material), and
    /// where the layer table starts in the procedural parameters (Scene.finishTerrainLayers).
    var firstLayer = -1
    var table = -1
    /// How the sectors are meshed (their weights from the document's layers: the renderer changes them with it).
    var meshStyle: TerrainMeshStyle
    /// Its scatter rules' things and what stands on it (Scene+TerrainScatter.swift).
    var scatter: SceneScatter?
    /// With physics: each full-detail sector's heightfield collider (its part's index: the static's).
    var colliders: [Int: Int] = [:]

    /// A sector's heights as its collider has them: its samples' (rows along z) and where its first is in the scene.
    func colliderHeights(_ p: Part, _ s: TerrainSnapshot) -> (lo: SIMD2<Float>, heights: [Float], side: SIMD2<Int>) {
        let side = p.sector.cells &+ 1
        let lo = field.grid.place(p.sector.first.x, p.sector.first.y) - offset
        return (SIMD2(Float(lo.x), Float(lo.y)), s.heights(from: p.sector.first, count: side, step: p.sector.step), side)
    }

    init(name: String, field: TerrainField, style: TerrainMeshStyle, offset: SIMD2<Double>, material: Int) {
        (self.name, self.field, self.style, self.offset, self.material) = (name, field, style, offset, material)
        meshStyle = style
    }

    /// The layer table (TERRAIN, Shaders/Terrain.metal): a header (the first layer's material, the scene's origin in
    /// the world), then per layer 1...15: its UV per metre, the slope (normal's y) under which it is projected from the
    /// sides too, whether it has a material.
    static func table(_ layers: [TerrainLayer], firstLayer: Int, offset: SIMD2<Double>) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>(Float(firstLayer), Float(offset.x), Float(offset.y), Float(TerrainTile.layers - 1))]
        for l in 1..<TerrainTile.layers {
            let layer = l < layers.count ? layers[l] : TerrainLayer(name: "")
            out.append(SIMD4(1 / max(layer.tileMetres, 0.05), 0.7, 1, 0))
        }
        return out
    }

    func append(_ p: Part) { parts.append(p) }

    /// A scene's place as the world's, and back.
    func world(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x) + offset.x, Double(p.y), Double(p.z) + offset.y) }
    func scene(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x - offset.x), Float(p.y), Float(p.z - offset.y)) }

    /// The ground's height under a scene's place, as the terrain is now.
    func height(_ x: Float, _ z: Float) -> Float { field.snapshot().height(x: Double(x) + offset.x, z: Double(z) + offset.y) }

    /// The sector's instance transform: at its tile's corner, in the scene.
    static func transform(_ sector: TerrainSector, grid: TerrainGrid, offset: SIMD2<Double>) -> float4x4 {
        let c = grid.corner(sector.tile) - offset
        return translate([Float(c.x), 0, Float(c.y)])
    }
}

extension Scene {
    /// The terrain of a scene of the Forest kind (and Mireland's): a square of rolling ground (`Terrain`'s), with the
    /// edits of its document. Opened in TerrainDocuments under `name`.
    static func openTerrain(_ name: String, base: @autoclosure () -> TerrainBase, layers: [TerrainLayer] = TerrainDocument.defaultLayers)
        -> TerrainDocuments.Entry {
        TerrainDocuments.shared.open(name, base: base(), document: TerrainDocument(name: name, layers: layers))
    }

    /// Adds the ground of `field` over the tiles `tiles` (each at its level of detail): a mesh and an instance per
    /// sector, made from `snapshot` (the field as it is now if nil), on every core. `offset`: the world's place that
    /// is the scene's origin. Returns the scene's terrain (also `self.terrain`).
    @discardableResult
    func addTerrain(name: String, field: TerrainField, snapshot: TerrainSnapshot? = nil, tiles: [(tile: SIMD2<Int>, level: Int)],
                    style: TerrainMeshStyle, material: Int, offset: SIMD2<Double> = .zero, mask: UInt32 = Scene.maskGeometry,
                    builtIn: (Int) -> GPUMaterial? = { _ in nil }) -> SceneTerrain {
        let sectors = tiles.flatMap { TerrainSector.sectors(of: $0.tile, level: $0.level, grid: field.grid) }
        return addTerrain(name: name, field: field, snapshot: snapshot, sectors: sectors, style: style, material: material, offset: offset,
                          mask: mask, builtIn: builtIn)
    }

    /// The same for some sectors: added to the scene's terrain if it has this one already (a builder that adds its
    /// ground in two goes: Forest).
    @discardableResult
    func addTerrain(name: String, field: TerrainField, snapshot: TerrainSnapshot? = nil, sectors: [TerrainSector],
                    style: TerrainMeshStyle, material: Int, offset: SIMD2<Double> = .zero, mask: UInt32 = Scene.maskGeometry,
                    builtIn: (Int) -> GPUMaterial? = { _ in nil }) -> SceneTerrain {
        let s = snapshot ?? field.snapshot(), grid = field.grid
        let layers = TerrainDocuments.shared.document(name)?.layers ?? TerrainDocument.defaultLayers
        var style = style
        style.layers = layers
        // The last scene's meshes of the same sectors, unchanged since (the open world's next scene has most of them).
        let key = "\(name) \(s.base.fingerprint)"
        let revisions = sectors.map { s.revision(around: $0) }
        Scene.terrainMeshesLock.lock()
        let kept = Scene.keptTerrainMeshes[key] ?? [:]
        Scene.terrainMeshesLock.unlock()
        var meshes = sectors.indices.map { k in kept[sectors[k]].flatMap { $0.revision == revisions[k] ? $0.mesh : nil } }
        meshes.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: sectors.count) { k in
                if out[k] == nil { out[k] = TerrainSectorMesh(s, sector: sectors[k], style: style) }
            }
        }
        Scene.terrainMeshesLock.lock()
        // (Kept for this terrain only: the scene's first go starts afresh, a second adds to it.)
        var next = terrain?.name == name ? Scene.keptTerrainMeshes[key] ?? [:] : [:]
        for k in sectors.indices { if let m = meshes[k] { next[sectors[k]] = (revisions[k], m) } }
        Scene.keptTerrainMeshes = [key: next]
        Scene.terrainMeshesLock.unlock()
        let t = terrain.flatMap { $0.name == name ? $0 : nil } ?? SceneTerrain(name: name, field: field, style: style, offset: offset, material: material)
        if t.firstLayer < 0 {
            t.firstLayer = addTerrainLayerMaterials(layers, builtIn: builtIn)
            if let doc = TerrainDocuments.shared.document(name), !doc.water.isEmpty {
                addTerrainWater(doc.water, snapshot: s, offset: offset, sectors: sectors)
            }
        }
        for (k, sector) in sectors.enumerated() {
            guard let m = meshes[k] else { continue }
            let meshName = sector.meshName(terrain: name)
            let mesh = addMesh(borrowing: m.borrowed, bounds: m.bounds, name: meshName)
            setDetailLevel(mesh, sector.level)
            label(mesh: mesh, "ground")
            // (Its shadows traced: the virtual shadow maps would keep their pages of it as it was before a brush reshaped it.)
            let instance = addInstance(mesh, material, SceneTerrain.transform(sector, grid: grid, offset: offset),
                                       mask: mask == Scene.maskGeometry ? mask | Scene.maskShadowTraced : mask)
            t.append(SceneTerrain.Part(sector: sector, mesh: mesh, instance: instance, name: meshName, revision: s.revision(around: sector)))
        }
        terrain = t
        let world = offset
        walkGround = { x, z in field.snapshot().height(x: Double(x) + world.x, z: Double(z) + world.y) }
        return t
    }

    /// Layers 1...15's materials, one after the other: a layer's Material Designer graph (baked by the renderer), a
    /// material of the scene's own (`builtIn`: the open world's grounds), or its plain colour over a generated detail
    /// texture. The first one's index.
    func addTerrainLayerMaterials(_ layers: [TerrainLayer], builtIn: (Int) -> GPUMaterial?) -> Int {
        let catalog = MaterialCatalog.resolve(settings.materials)
        let detail = addGeneratedTexture(name: "terrain-detail", width: 512, height: 512, key: "v\(FoliageTextures.version)") {
            FoliageTextures.image(512, 512, normalized: true) { u, v in
                let clumps = FoliageTextures.noise(u * 6, v * 6, 6, 6, 41) + 0.6 * FoliageTextures.noise(u * 17, v * 17, 17, 17, 42)
                let specks = FoliageTextures.noise(u * 60, v * 60, 60, 60, 43)
                return SIMD3(repeating: max(0.75 + 0.3 * clumps + 0.22 * specks, 0.1))
            }
        }
        var first = -1
        for l in 1..<TerrainTile.layers {
            let layer = l < layers.count ? layers[l] : TerrainLayer(name: "")
            let index: Int
            if !layer.material.isEmpty {
                index = addProceduralMaterial(graph: layer.material, catalog: catalog)
            } else if let k = layer.builtIn, let m = builtIn(k) {
                index = addMaterial(m)
            } else {
                var m = GPUMaterial(albedo: SIMD4(layer.color / FoliageTextures.mean, 0), emission: SIMD4(.zero, layer.roughness))
                m.textures.x = detail
                index = addMaterial(m)
            }
            if first < 0 { first = index }
        }
        return first
    }

    /// The terrain's water (TerrainWater): a sea's sheet over the terrain (an endless one's: over these sectors' tiles),
    /// a lake's over its basin, a river's ribbon; each clear water (a dark glossy surface) or its Material Designer
    /// graph.
    func addTerrainWater(_ bodies: [WaterBody], snapshot s: TerrainSnapshot, offset: SIMD2<Double>, sectors: [TerrainSector]) {
        section("Water")
        let catalog = MaterialCatalog.resolve(settings.materials), grid = s.grid
        for body in bodies {
            let material = body.material.isEmpty ? addPBRMaterial(baseColor: body.color, metallic: 0, roughness: 0.03)
                : addProceduralMaterial(graph: body.material, catalog: catalog)
            let made: (MeshGeometry, [SIMD2<Float>])?
            switch body.kind {
            case .sea:
                // Over the terrain (an endless one: the sectors this scene has), a grid of 64 x 64 cells.
                let lo = grid.lo ?? sectors.map(\.first).reduce(SIMD2(Int.max, Int.max), simd_min)
                let hi = grid.hi ?? sectors.map(\.last).reduce(SIMD2(Int.min, Int.min), simd_max)
                guard lo.x < hi.x, lo.y < hi.y else { continue }
                made = TerrainWater.plane(from: grid.place(lo.x, lo.y), to: grid.place(hi.x, hi.y), level: body.level, offset: offset)
            case .lake:
                guard let basin = TerrainWater.basin(s, seed: body.seed, level: body.level) else { continue }
                made = TerrainWater.sheet(grid: grid, lo: basin.lo, size: basin.size, cells: basin.cells, level: body.level, offset: offset)
            case .river:
                made = TerrainWater.ribbon(s, river: body, offset: offset)
            }
            guard let (geometry, uvs) = made else { continue }
            let mesh = addMesh(geometry, uvs: uvs, label: body.name)
            addInstance(mesh, material, matrix_identity_float4x4)
        }
    }

    /// The terrain's layer table, after the procedural programs' parameters (which `buildProceduralPrograms` sets),
    /// and its sectors told where it is.
    func finishTerrainLayers() {
        guard let t = terrain, t.firstLayer >= 0 else { return }
        t.table = proceduralParams.count
        proceduralParams += SceneTerrain.table(t.meshStyle.layers, firstLayer: t.firstLayer, offset: t.offset)
        for p in t.parts { setTerrainTable(p.mesh, t.table) }
    }

    /// With physics in the scene: the terrain's full-detail sectors as heightfield colliders (bodies, particles and
    /// liquids land on the ground; a brush moving it moves them: Renderer.prepareTerrainFrame).
    func addTerrainColliders() {
        guard let t = terrain, physics != nil else { return }
        let s = t.field.snapshot(), world = physicsWorld()
        for (k, p) in t.parts.enumerated() where p.sector.level == 0 {
            let c = t.colliderHeights(p, s)
            t.colliders[k] = world.addStaticHeightfield(lo: c.lo, cell: t.field.grid.cell * Float(p.sector.step), side: c.side, heights: c.heights)
        }
    }

    /// The meshes that are a terrain's sectors (built to be built again: SceneBuffers).
    var terrainMeshSet: Set<Int> { Set(terrain?.parts.map(\.mesh) ?? []) }

    /// The last scene's sectors' meshes, by its terrain and its base, with the revision they were made at.
    fileprivate static var keptTerrainMeshes: [String: [TerrainSector: (revision: Int, mesh: TerrainSectorMesh)]] = [:]
    fileprivate static let terrainMeshesLock = NSLock()
}

extension Terrain {
    /// The terrain as `snapshot` has it now (its edits on its base): a finite field's samples, as a `Terrain` (what
    /// the scenes place their plants with).
    init(_ snapshot: TerrainSnapshot, relief: Float) {
        let grid = snapshot.grid, lo = grid.lo ?? .zero, hi = grid.hi ?? SIMD2(grid.tileCells, grid.tileCells)
        let cells = hi.x - lo.x, n = cells + 1
        var heights = [Float](repeating: 0, count: n * n)
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n) { j in
                for i in 0..<n { out[j * n + i] = snapshot.height(lo.x + i, lo.y + j) }
            }
        }
        self.init(size: grid.cell * Float(cells), cells: cells, relief: relief, heights: heights)
    }
}
