import Foundation
import simd

/// What a scene has of its terrain (Terrain/): the field it was made from, and each sector it meshes (a borrowed
/// mesh of its own, named so the next scene of the same terrain takes the same buffer and structure, and an instance
/// at its tile's corner). The renderer meshes the sectors again as the field's edits change them (Renderer+Terrain).
package final class SceneTerrain {
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
    /// The scene's own water on it (made from its seed, shaped into its base: SceneWaterMaker), after its document's.
    var generatedWater: [WaterBody] = []
    /// The realistic look (SceneSettings.realism): its table's rows past the layers', and the scene's own ground made
    /// of scans (Scene.addGroundLook; nil: layer 0 is the sectors' material as it is).
    var realistic = false
    var high = false
    var ground: GroundRows?
    /// The generated detail texture the plain layers' colours are multiplied by.
    var detail: UInt32 = .max
    /// The realistic ground's tiling noise (Scene.terrainMacroTexture).
    var macro: UInt32 = .max
    /// The scanned layers' repeats, metres (by layer).
    var scanMetres: [Int: Float] = [:]

    /// A sector's heights as its collider has them: its samples' (rows along z) and where its first is in the scene.
    func colliderHeights(_ p: Part, _ s: TerrainSnapshot) -> (lo: SIMD2<Float>, heights: [Float], side: SIMD2<Int>) {
        let side = p.sector.cells &+ 1
        let lo = field.grid.place(p.sector.first.x, p.sector.first.y) - offset
        return (SIMD2(Float(lo.x), Float(lo.y)), s.heights(from: p.sector.first, count: side, step: p.sector.step), side)
    }

    package init(name: String, field: TerrainField, style: TerrainMeshStyle, offset: SIMD2<Double>, material: Int) {
        (self.name, self.field, self.style, self.offset, self.material) = (name, field, style, offset, material)
        meshStyle = style
    }

    /// The layer table (TERRAIN, Shaders/Surface.metal): a header (the first layer's material, the scene's origin in
    /// the world, 15, or 16 with the realistic look), then per layer 1...15: its UV per metre, the slope (normal's y)
    /// under which it is projected from the sides too, and with the realistic look its height's contrast and its
    /// occlusion's strength (else 1, 0). With the realistic look, then: how many layers the scene's own ground has, its
    /// maps' and the macro noise's textures; the maps' rectangle; its rock layer and slopes; and per ground layer its
    /// material, UV per metre, contrast.
    static func table(_ layers: [TerrainLayer], firstLayer: Int, offset: SIMD2<Double>, realistic: Bool = false, high: Bool = false,
                      ground: GroundRows? = nil, macro: UInt32 = .max, metres: (Int) -> Float? = { _ in nil }) -> [SIMD4<Float>] {
        let header = realistic ? (high ? 17 : 16) : TerrainTile.layers - 1   // (17: realism high, its parallax)
        var out = [SIMD4<Float>(Float(firstLayer), Float(offset.x), Float(offset.y), Float(header))]
        for l in 1..<TerrainTile.layers {
            let layer = l < layers.count ? layers[l] : TerrainLayer(name: "")
            out.append(realistic ? SIMD4(1 / max(metres(l) ?? layer.tileMetres, 0.05), 0.7, 1, 1) : SIMD4(1 / max(layer.tileMetres, 0.05), 0.7, 1, 0))
        }
        guard realistic else { return out }
        func index(_ v: UInt32) -> Float { v == .max ? -1 : Float(v) }
        let g = ground ?? GroundRows()
        out.append(SIMD4(Float(g.materials.count), index(g.mapA), index(g.mapB), index(macro)))
        out.append(SIMD4(g.lo.x, g.lo.y, 1 / max(g.size.x, 1e-3), 1 / max(g.size.y, 1e-3)))
        out.append(SIMD4(Float(g.rock), g.slope.x, g.slope.y, 0))
        for k in g.materials.indices {
            out.append(SIMD4(Float(g.materials[k]), 1 / max(g.metres[k], 0.05), g.contrast[k], 1))
        }
        return out
    }

    func append(_ p: Part) { parts.append(p) }
    /// Part `k` as another sector of the same ground (refined: Scene.refineTerrain).
    func replace(_ k: Int, sector: TerrainSector, name: String) {
        parts[k].sector = sector
        parts[k].name = name
    }
    /// The realistic look's fine parts (realism high: their mesh has the scans' relief, the parallax the finer detail
    /// between its vertices).
    var fineParts: Set<Int> = []
    /// The ground look to refine the near sectors by, once they are all in (Scene.addGroundLook, realism high).
    var pendingRefine: (look: GroundLook, rows: GroundRows, maps: (FoliageTextures.Image, FoliageTextures.Image))?

    /// A scene's place as the world's, and back.
    func world(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x) + offset.x, Double(p.y), Double(p.z) + offset.y) }
    func scene(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x - offset.x), Float(p.y), Float(p.z - offset.y)) }

    /// The ground's height under a scene's place, as the terrain is now.
    package func height(_ x: Float, _ z: Float) -> Float { field.snapshot().height(x: Double(x) + offset.x, z: Double(z) + offset.y) }

    /// The sector's instance transform: at its tile's corner, in the scene.
    static func transform(_ sector: TerrainSector, grid: TerrainGrid, offset: SIMD2<Double>) -> float4x4 {
        let c = grid.corner(sector.tile) - offset
        return translate([Float(c.x), 0, Float(c.y)])
    }
}

extension Scene {
    /// The terrain of a scene of the Forest kind (and Mireland's): a square of rolling ground (`Terrain`'s), with the
    /// edits of its document. Opened in TerrainDocuments under `name`.
    package static func openTerrain(_ name: String, base: @autoclosure () -> TerrainBase, layers: [TerrainLayer] = TerrainDocument.defaultLayers)
        -> TerrainDocuments.Entry {
        TerrainDocuments.shared.open(name, base: base(), document: TerrainDocument(name: name, layers: layers))
    }

    /// A scene's ground as a terrain of its own (a workshop's, a square's): `base` (its shapes over it) under `name`
    /// (which says the base: another base, another name), all its tiles at full detail, in `material`, with its own
    /// water. The Terrain Editor edits it like any other.
    @discardableResult
    package func addGroundTerrain(_ name: String, base: TerrainBase, material: Int, water: [WaterBody] = []) -> SceneTerrain {
        let entry = Scene.openTerrain(name, base: base, layers: TerrainDocument.sceneLayers())
        let grid = entry.field.grid
        return addTerrain(name: entry.document.name, field: entry.field, tiles: grid.tiles!.map { ($0, 0) },
                          style: TerrainMeshStyle(uvOrigin: grid.origin, uvScale: 1), material: material, generatedWater: water)
    }

    /// A pond for a scene's own ground at `center`: its water a little under the lowest of `base` round its rim, so it
    /// stays in its bowl.
    static func pond(on base: TerrainBase, center: SIMD2<Float>, radii: SIMD2<Float>, depth: Float, look: WaterLook = .preset(.lake))
        -> (body: WaterBody, bowl: TerrainShapes.Bowl) {
        var rim = Float.infinity
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * .pi, p = center + SIMD2(cos(a), sin(a)) * radii * 1.25
            rim = min(rim, SceneWaterMaker.height(base, Double(p.x), Double(p.y)))
        }
        return SceneWaterMaker.pond(name: "Pond", center: center, radii: radii, level: rim - 0.25, depth: depth, look: look)
    }

    /// Adds the ground of `field` over the tiles `tiles` (each at its level of detail): a mesh and an instance per
    /// sector, made from `snapshot` (the field as it is now if nil), on every core. `offset`: the world's place that
    /// is the scene's origin. Returns the scene's terrain (also `self.terrain`).
    /// `generatedWater`: the scene's own (its document's water comes first).
    @discardableResult
    package func addTerrain(name: String, field: TerrainField, snapshot: TerrainSnapshot? = nil, tiles: [(tile: SIMD2<Int>, level: Int)],
                    style: TerrainMeshStyle, material: Int, offset: SIMD2<Double> = .zero, mask: UInt32 = Scene.maskGeometry,
                    generatedWater: [WaterBody] = [], builtIn: (Int) -> GPUMaterial? = { _ in nil }) -> SceneTerrain {
        let sectors = tiles.flatMap { TerrainSector.sectors(of: $0.tile, level: $0.level, grid: field.grid) }
        return addTerrain(name: name, field: field, snapshot: snapshot, sectors: sectors, style: style, material: material, offset: offset,
                          mask: mask, generatedWater: generatedWater, builtIn: builtIn)
    }

    /// The same for some sectors: added to the scene's terrain if it has this one already (a builder that adds its
    /// ground in two goes: Forest).
    @discardableResult
    package func addTerrain(name: String, field: TerrainField, snapshot: TerrainSnapshot? = nil, sectors: [TerrainSector],
                    style: TerrainMeshStyle, material: Int, offset: SIMD2<Double> = .zero, mask: UInt32 = Scene.maskGeometry,
                    generatedWater: [WaterBody] = [], builtIn: (Int) -> GPUMaterial? = { _ in nil }) -> SceneTerrain {
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
            let made = addTerrainLayerMaterials(layers, builtIn: builtIn)
            t.firstLayer = made.first
            t.detail = made.detail
            t.scanMetres = made.scans
            if settings.realism != .off {
                t.realistic = true
                t.high = settings.realism == .high
                t.macro = terrainMacroTexture()
            }
            t.generatedWater = generatedWater
            let bodies = (TerrainDocuments.shared.document(name)?.water ?? []) + generatedWater
            if !bodies.isEmpty { addTerrainWater(bodies, snapshot: s, offset: offset, sectors: sectors) }
        }
        for (k, sector) in sectors.enumerated() {
            guard let m = meshes[k] else { continue }
            let meshName = sector.meshName(terrain: name)
            let mesh = addMesh(borrowing: m.borrowed, bounds: m.bounds, name: meshName)
            setDetailLevel(mesh, sector.level)
            label(mesh: mesh, "ground")
            let instance = addInstance(mesh, material, SceneTerrain.transform(sector, grid: grid, offset: offset), mask: mask)
            t.append(SceneTerrain.Part(sector: sector, mesh: mesh, instance: instance, name: meshName, revision: s.revision(around: sector)))
        }
        terrain = t
        let world = offset
        walkGround = { x, z in field.snapshot().height(x: Double(x) + world.x, z: Double(z) + world.y) }
        return t
    }

    /// Layers 1...15's materials, one after the other: a layer's Material Designer graph (baked by the renderer), a
    /// material of the scene's own (`builtIn`: the open world's grounds), or its plain colour over a generated detail
    /// texture; with the realistic look, its scan first (TextureSet, by its `scanSet`). The first one's index, the
    /// detail texture, and each scanned layer's repeat in metres.
    func addTerrainLayerMaterials(_ layers: [TerrainLayer], builtIn: (Int) -> GPUMaterial?) -> (first: Int, detail: UInt32, scans: [Int: Float]) {
        let catalog = MaterialCatalog.resolve(settings.materials)
        let detail = terrainDetailTexture()
        var first = -1
        var scans: [Int: Float] = [:]
        for l in 1..<TerrainTile.layers {
            let layer = l < layers.count ? layers[l] : TerrainLayer(name: "")
            let index: Int
            if settings.realism != .off, layer.material.isEmpty, let set = layer.scanSet, let scan = addScanMaterial(set) {
                index = scan
                scans[l] = TextureSet.find(set)?.metres
            } else if !layer.material.isEmpty {
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
        return (first, detail, scans)
    }

    /// The terrain's water (TerrainWater): a sea's sheet over the terrain (an endless one's: over these sectors' tiles),
    /// a lake's over its basin, a river's ribbon; each a water surface (Scene+Water.swift) of its look, with its
    /// Material Designer graph floating on it if it has one (a sheet a few millimetres up, cut out by its opacity).
    /// Where it all is goes to the water map (TerrainWaterField).
    func addTerrainWater(_ bodies: [WaterBody], snapshot s: TerrainSnapshot, offset: SIMD2<Double>, sectors: [TerrainSector]) {
        guard !WaterSystem.off else { return }
        // (Inside whatever section the builder has open, which goes on after it: the Forest adds its water before its plants.)
        beginObject("Water")
        defer { endObject() }
        let catalog = MaterialCatalog.resolve(settings.materials), grid = s.grid
        var looks: [Int?] = []
        for body in bodies {
            let made: (MeshGeometry, [SIMD2<Float>])?
            switch body.kind {
            case .sea:
                // Over the terrain (an endless one: the sectors this scene has), a grid of 64 x 64 cells.
                let lo = grid.lo ?? sectors.map(\.first).reduce(SIMD2(Int.max, Int.max), simd_min)
                let hi = grid.hi ?? sectors.map(\.last).reduce(SIMD2(Int.min, Int.min), simd_max)
                made = lo.x < hi.x && lo.y < hi.y
                    ? TerrainWater.plane(from: grid.place(lo.x, lo.y), to: grid.place(hi.x, hi.y), level: body.level, offset: offset) : nil
            case .lake:
                made = TerrainWater.basin(s, seed: body.seed, level: body.level).flatMap {
                    TerrainWater.sheet(grid: grid, lo: $0.lo, size: $0.size, cells: $0.cells, level: body.level, offset: offset)
                }
            case .river:
                made = TerrainWater.ribbon(s, river: body, offset: offset)
            }
            guard let (geometry, uvs) = made else { looks.append(nil); continue }
            let look = addWaterLook(body.appearance)
            looks.append(look)
            addWaterSurface(geometry, look: look)
            if !body.material.isEmpty {
                let floating = addProceduralMaterial(graph: body.material, catalog: catalog)
                let lifted = (geometry.positions.map { $0 + SIMD3(0, 0.003, 0) }, geometry.normals, geometry.indices)
                addInstance(addMesh(lifted, uvs: uvs, label: "\(body.name) cover"), floating, matrix_identity_float4x4)
            }
        }
        guard let w = water else { return }
        w.bodyLooks = looks
        w.field = TerrainWaterField(snapshot: s, bodies: bodies, looks: looks)
        w.offset = offset
        // (Sorted keys: JSONEncoder writes an object's keys in an order that can change from one encoding to the next, and
        // the same water would then look like other water: its map drawn again where it was kept, or kept where not.)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let described = (try? encoder.encode(bodies)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        w.key = "\(terrain?.name ?? "")|\(described.hashValue)|\(s.editsFingerprint)"
    }

    /// The terrain's layer table, after the procedural programs' parameters (which `buildProceduralPrograms` sets),
    /// and its sectors told where it is.
    func finishTerrainLayers() {
        guard let t = terrain, t.firstLayer >= 0 else { return }
        if let r = t.pendingRefine {
            t.pendingRefine = nil
            refineTerrain(r.look, rows: r.rows, maps: r.maps)
        }
        t.table = proceduralParams.count
        proceduralParams += SceneTerrain.table(t.meshStyle.layers, firstLayer: t.firstLayer, offset: t.offset, realistic: t.realistic,
                                               high: t.high, ground: t.ground, macro: t.macro, metres: { t.scanMetres[$0] })
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
    package init(_ snapshot: TerrainSnapshot, relief: Float) {
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
