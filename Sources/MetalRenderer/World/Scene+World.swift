import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// Which part of the open world a scene holds (Scene.worldPlace).
package struct WorldPlace {
    var world: World
    /// The world's place that is the scene's origin (x, z): the scene's coordinates are metres from it. A tile's
    /// corner (`anchorTile`'s).
    var anchor: SIMD2<Double> { WorldTile.origin(anchorTile.x, anchorTile.y) }
    var anchorTile: SIMD2<Int>
    /// The tile the scene is made around.
    var tile: SIMD2<Int>
    /// The middle of that tile's ground, in the scene.
    var middle: SIMD3<Float>

    /// The tile to make the scene around for a camera at `p` (the scene's coordinates): the one it has, until the
    /// camera is a quarter of a tile into another (so that pacing across a tile's side changes nothing).
    func wanted(for p: SIMD3<Float>) -> SIMD2<Int> {
        let side = Double(World.tileSize)
        // In tiles, from this tile's middle.
        let off = SIMD2((Double(p.x) + anchor.x) / side - Double(tile.x) - 0.5, (Double(p.z) + anchor.y) / side - Double(tile.y) - 0.5)
        func step(_ d: Double) -> Int { abs(d) > 0.75 ? Int((d + 0.5).rounded(.down)) : 0 }
        return SIMD2(tile.x + step(off.x), tile.y + step(off.y))
    }

    /// How far the scene's middle may be from its origin, in tiles: 2 km, so with what is in sight no coordinate is
    /// beyond 4.3 km, where a float still steps by half a millimetre.
    static let reach = 8

    /// The origin for a scene around `tile`: this one, or once the tile is `reach` tiles from it, a corner near
    /// the tile (every `reach` tiles, so that the origin moves rarely).
    func anchorTile(around tile: SIMD2<Int>) -> SIMD2<Int> {
        let off = tile &- anchorTile
        guard max(abs(off.x), abs(off.y)) > WorldPlace.reach else { return anchorTile }
        func snap(_ t: Int) -> Int { Int((Double(t) / Double(WorldPlace.reach)).rounded()) * WorldPlace.reach }
        return SIMD2(snap(tile.x), snap(tile.y))
    }
}

extension World {
    /// Where the world is first seen from: in the fields south of the origin's city, looking at it. (So near its
    /// level ground the belt is always open: `belt`.)
    package var start: (place: SIMD3<Double>, yaw: Float) {
        let city = city(cell: SIMD2(0, 0))!
        let x = city.center.x + 30, z = city.center.y + Double(city.radius + World.cityApron) + 24
        return (SIMD3(x, Double(height(x, z)) + 1.7, z), 0)
    }

    /// The scenes' first origin: the tile the origin's city has its middle in. (The origin follows the camera from
    /// afar: WorldPlace.anchorTile(around:).)
    package var anchorTile: SIMD2<Int> {
        let city = city(cell: SIMD2(0, 0))!, side = Double(World.tileSize)
        return SIMD2(Int((city.center.x / side).rounded(.down)), Int((city.center.y / side).rounded(.down)))
    }
}

/// The Open world scene: the world's tiles around one of them, each at the level its distance asks for, the trees
/// and the ground cover they hold as instances of the world's plants. The scene is one moment of the world: when the
/// camera moves into another tile, the renderer makes the scene around that one (`SceneSettings.worldTile`), in the
/// background, from the tiles this one already has and the few that are new. A tile's trees are a group of instances
/// (`Scene.InstanceGroup`), which the renderer keeps from one scene to the next as it keeps the tile's meshes.
///
/// Its day (`Heavens`) goes through dusk into night: the scene's light from the sky is the sun, then the moon, and the
/// cities' lamps and windows come on as the sun sets, each material's emission at its own time (`setCityLights`).
/// From a little before that until a little after they go off in the morning, the scene is one made with
/// `SceneSettings.worldLit`: its lights are then the nearer tiles' own too (`WorldTile.lights`), everything lit in the
/// tiles next to the camera and the street lamps of the ones beyond them. Further out a lit window is seen, and
/// lights nothing. By day nothing samples them.
extension Scene {
    /// `METALRENDERER_WORLD_GROUPS=0`: a tile's trees are the scene's own instances, made again with every scene (as
    /// they were before the tiles had groups: for comparing).
    package static let groupsTrees = ProcessInfo.processInfo.environment["METALRENDERER_WORLD_GROUPS"] != "0"

    /// The tiles of the last scene, by what they were made for: the next scene shares most of them.
    private static var keptTiles: [String: WorldTile] = [:]
    private static let keptLock = NSLock()

    package func buildWorld() {
        let start = CFAbsoluteTimeGetCurrent()
        var world = World(seed: UInt64(max(settings.seed, 0)))
        world.treeDensity = Float(max(settings.trees, 0)) / 10.24      // the Forest's square is 10.24 hectares
        world.undergrowth = Float(max(settings.undergrowth, 0)) / 100
        let lit = settings.worldLit
        world.lit = settings.city.lit
        let catalog = PlantCatalog.resolve(settings.plantCatalog)
        if !catalog.placesAsBuiltIn { world.plants = catalog.placementFingerprint }
        let buildings = BuildingCatalog.resolve(settings.buildingCatalog)
        world.buildingCatalog = buildings
        if buildings != .builtIn { world.buildings = buildings.fingerprint }
        world.interior = settings.interior
        let flora = Flora(self, seed: world.seed, catalog: catalog, borrowing: true)
        // Every plant and its materials, first and in the library's order: every scene of the world then has the same
        // textures (the renderer keeps them) and the same numbers for its plants (so it keeps the tiles' trees too).
        // (The tiles' meshes stay in their files and the baked plants' in the library, `addMesh(borrowing:)`: the
        // scene's arrays hold what plants are assemblies.)
        let plantGeometry = flora.geometry
        reserveGeometry(vertices: plantGeometry.vertices, indices: plantGeometry.indices)
        flora.addAll()
        let index = flora.index
        let begin = world.start, side = Double(World.tileSize)
        let anchorTile = settings.worldAnchor ?? world.anchorTile, anchor = WorldTile.origin(anchorTile.x, anchorTile.y)
        let home = SIMD2(Int((begin.place.x / side).rounded(.down)), Int((begin.place.z / side).rounded(.down)))
        let middle = settings.worldTile ?? home

        // The tiles: the kept ones, the rest from their files or made now, on every core.
        var jobs: [(x: Int, z: Int, level: Int, key: String)] = []
        for j in -8...8 {
            for i in -8...8 {
                guard let level = WorldTile.level(rings: max(abs(i), abs(j))) else { continue }
                jobs.append((middle.x + i, middle.y + j, level, WorldTile.key(world, x: middle.x + i, z: middle.y + j, level: level)))
            }
        }
        Scene.keptLock.lock()
        let kept = Scene.keptTiles
        Scene.keptLock.unlock()
        var tiles = jobs.map { kept[$0.key] }
        let shared = tiles.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        tiles.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                if out[k] == nil { out[k] = WorldTile.make(world, x: jobs[k].x, z: jobs[k].z, level: jobs[k].level, flora: index) }
            }
        }
        Scene.keptLock.lock()
        Scene.keptTiles = Dictionary(uniqueKeysWithValues: zip(jobs.map(\.key), tiles.map { $0! }))
        Scene.keptLock.unlock()

        // The city's generated textures: every kind's, whether a tile in sight has it or not (the same textures in
        // every scene of the world).
        let maps = settings.city.textures ? ProceduralTextures.sources(SurfaceKind.allCases) : [:]
        var mapIndex: [SurfaceKind: SIMD4<UInt32>] = [:]
        for kind in SurfaceKind.allCases {
            guard let m = maps[kind] else { continue }
            mapIndex[kind] = SIMD4(addTexture(m.base), m.roughness.map { addTexture($0) } ?? .max, addTexture(m.normal), .max)
        }
        func textures(_ kind: SurfaceKind) -> SIMD4<UInt32> { mapIndex[kind] ?? SIMD4(repeating: .max) }

        // The ground's detail: clumps and specks, the same every 5 m (World.groundTile).
        let detail = addGeneratedTexture(name: "ground-detail", width: 512, height: 512, key: "v\(FoliageTextures.version)") {
            FoliageTextures.image(512, 512, normalized: true) { u, v in
                let clumps = FoliageTextures.noise(u * 6, v * 6, 6, 6, 21) + 0.6 * FoliageTextures.noise(u * 17, v * 17, 17, 17, 22)
                let specks = FoliageTextures.noise(u * 60, v * 60, 60, 60, 23)
                return SIMD3(repeating: max(0.75 + 0.3 * clumps + 0.22 * specks, 0.1))
            }
        }

        // A field's rows: eight to the 5 m, running along z, none of them quite straight.
        let rows = addGeneratedTexture(name: "field-rows", width: 512, height: 512, key: "v\(FoliageTextures.version)") {
            FoliageTextures.image(512, 512, normalized: true) { u, v in
                let wander = 0.012 * FoliageTextures.noise(u * 3, v * 3, 3, 3, 31) + 0.004 * FoliageTextures.noise(u * 9, v * 9, 9, 9, 32)
                let row = 0.5 + 0.5 * cos(2 * Float.pi * 8 * (u + wander))
                let specks = FoliageTextures.noise(u * 60, v * 60, 60, 60, 33), clumps = FoliageTextures.noise(u * 7, v * 7, 7, 7, 34)
                return SIMD3(repeating: max(0.55 + 0.5 * row + 0.2 * specks + 0.12 * clumps, 0.1))
            }
        }

        // Bushes, ferns and grass: the 32 m cells of the middle tile and 96 m around it.
        let cell = 32.0, around = 3
        let lo = WorldTile.origin(middle.x, middle.y) - SIMD2(Double(around) * cell, Double(around) * cell)
        let cells = Int(side / cell) + 2 * around
        var cover = [[World.Placement]](repeating: [], count: cells * cells)
        cover.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: cells * cells) { c in
                out[c] = world.groundCover(x0: lo.x + Double(c % cells) * cell, z0: lo.y + Double(c / cells) * cell, side: cell, flora: index)
            }
        }

        // The ground: the world's terrain "world-<seed>" (its edits: Terrain Editor), each tile's sectors at its level,
        // in the world's ground materials (a cell's kind is its material's offset from the first).
        let worldTerrain = Scene.openTerrain("world-\(world.seed)", base: WorldTerrainBase(world: world), layers: TerrainDocument.worldLayers())
        if let base = worldTerrain.field.base as? WorldTerrainBase {
            for (k, job) in jobs.enumerated() {
                guard let tile = tiles[k] else { continue }
                base.setKinds(tile.groundKinds, tile: SIMD2(job.x, job.z), level: job.level)
                base.setHeights(tile.groundHeights, tile: SIMD2(job.x, job.z), level: job.level)
            }
        }
        let snapshot = worldTerrain.field.snapshot()
        // The next tiles' heights in full, from their files (what the brushes reach and the sectors read).
        for (k, job) in jobs.enumerated() where job.level == 0 {
            if let tile = tiles[k], !snapshot.baseCache.isCached(SIMD2(job.x, job.z)) {
                snapshot.baseCache.set(SIMD2(job.x, job.z), heights: tile.groundHeights.array)
            }
        }
        var triangles = 0, trees = 0
        // (A plant is an instance, or where plants are baked two: its wood and its leaves.) A tile's trees are a group
        // of their own, not among the scene's instances; the ground cover changes with the middle tile and is.
        let placements = cover.reduce(0) { $0 + $1.count }
        reserveGeometry(vertices: 0, indices: 0, instances: tiles.reduce(0) { $0 + $1!.chunks.count } + placements * (usesAssemblies ? 1 : 2)
                        + jobs.count * 16)
        for (k, tile) in tiles.enumerated() {
            guard let tile else { continue }
            let origin = WorldTile.origin(jobs[k].x, jobs[k].z)
            let corner = SIMD3(Float(origin.x - anchor.x), 0, Float(origin.y - anchor.y))
            var placed: [Int] = []       // the chunks' instances
            for (c, chunk) in tile.chunks.enumerated() {
                // The chunk's materials, one after the other: its triangles name them from the first.
                var first = -1
                for m in chunk.materials {
                    var material = m
                    if let kind = World.kind(ofTexture: m.textures.x) { material.textures = textures(kind) }
                    if m.textures.x == World.groundDetail { material.textures.x = detail }
                    if m.textures.x == World.fieldRows { material.textures.x = rows }
                    // What is a light at night is off until the time of day says otherwise (`setCityLights`).
                    let emission = SIMD3(m.emission.x, m.emission.y, m.emission.z), light = !chunk.glass && emission != .zero
                    if light { material.emission = SIMD4(.zero, m.emission.w) }
                    let added = chunk.glass ? addGlassMaterial(tint: SIMD3(m.albedo.x, m.albedo.y, m.albedo.z)) : addMaterial(material)
                    if first < 0 { first = added }
                    if light {
                        // A window's time is its material's own, the same in every scene of the world.
                        let own = World.hash(world.seed, jobs[k].x, jobs[k].z, UInt64(c) << 32 | UInt64(added - first) << 8 | UInt64(tile.level))
                        cityLights.append(CityLight(material: added, emission: emission,
                                                    window: emission == World.lampEmission ? nil : Float(own >> 40) / Float(1 << 24)))
                    }
                }
                let mesh = addMesh(borrowing: BorrowedMesh(positions: chunk.positions, normals: chunk.normals, uvs: chunk.uvs,
                                                           indices: chunk.indices, materials: chunk.triangleMaterials),
                                   bounds: chunk.bounds, name: "\(jobs[k].key) chunk \(c)")
                setDetailLevel(mesh, jobs[k].level)
                placed.append(addInstance(mesh, first, translate(corner), mask: chunk.glass ? Scene.maskGlass : Scene.maskGeometry))
                triangles += chunk.triangles
            }
            // Its lights, where they are near enough to light what is seen: all of them next to the camera, the
            // street lamps a ring further out.
            for light in tile.lights where lit && tile.level <= 1 {
                let material = tile.chunks[Int(light.chunk)].materials[Int(light.material)]
                let lamp = SIMD3(material.emission.x, material.emission.y, material.emission.z) == World.lampEmission
                guard tile.level == 0 || lamp else { continue }
                let first = Int(light.first), c = light.center, n = light.normal
                addMeshLight(BorrowedLight(light: MeshLight(instance: placed[Int(light.chunk)], firstTriangle: 0, triangleCount: Int(light.count),
                                                            center: SIMD3(c.x, c.y, c.z), radius: c.w, normal: SIMD3(n.x, n.y, n.z),
                                                            flatness: n.w, power: SIMD3(light.power.x, light.power.y, light.power.z),
                                                            materialOffset: Int(light.material)),
                                           triangles: tile.emissive, range: first..<(first + Int(light.count))))
            }
            // Its trees, the same at every level: a group, which the renderer keeps from scene to scene. (Where they
            // are from this scene's origin is in the group's name.)
            let standing = tile.trees
            func species(_ t: World.Placement) -> Foliage.Species { Foliage.Species(rawValue: Int(t.species)) }
            trees += standing.count
            guard Scene.groupsTrees else {
                for t in standing {
                    flora.place(species(t), Int(t.plant), at: corner + SIMD3(t.x, t.y, t.z), yaw: t.yaw, size: t.size, shade: Int(t.shade))
                }
                continue
            }
            let count = standing.reduce(0) { $0 + flora.instanceCount(species($1), Int($1.plant)) }
            guard count > 0 else { continue }
            // (On the terrain as its edits have it: a tree stands as much higher or lower as they moved the ground; the
            // group's name says which edits, so another is made once they change.)
            let tileOrigin = WorldTile.origin(jobs[k].x, jobs[k].z), edited = snapshot.tiles[SIMD2(jobs[k].x, jobs[k].z)]?.revision ?? 0
            addGroup(name: "trees of \(WorldTile.place(world, x: jobs[k].x, z: jobs[k].z)) from \(anchorTile.x) \(anchorTile.y), \(flora.name)"
                        + (edited > 0 ? " edits \(worldTerrain.document.name) \(edited)" : ""),
                     count: count) {
                var out: [Instance] = []
                out.reserveCapacity(count)
                for t in standing {
                    let lift = edited > 0 ? snapshot.delta(x: tileOrigin.x + Double(t.x), z: tileOrigin.y + Double(t.z)) : 0
                    flora.instances(species(t), Int(t.plant), at: corner + SIMD3(t.x, t.y + lift, t.z), yaw: t.yaw, size: t.size,
                                    shade: Int(t.shade), into: &out)
                }
                return out
            }
        }

        // The realistic look: each ground's scan (one repeat in its own metres on the tiles' 5 m UVs), and a map of them
        // round the middle tile that the shading blends by height (Terrain/GroundLook.swift).
        let realistic = settings.realism != .off
        var firstGround = -1
        for (k, m) in World.groundMaterials.enumerated() {
            var material = m
            if m.textures.x == World.groundDetail { material.textures.x = detail }
            if m.textures.x == World.fieldRows { material.textures.x = rows }
            let scan = World.groundScans[k]
            let added: Int
            if realistic, let index = addScanMaterial(scan.set, tint: scan.tint) {
                materialExtras[index]?.surface.y = World.groundTile / (TextureSet.find(scan.set)?.metres ?? World.groundTile)
                added = index
            } else {
                added = addMaterial(material)
            }
            if firstGround < 0 { firstGround = added }
        }
        let terrain = addTerrain(name: worldTerrain.document.name, field: worldTerrain.field, snapshot: snapshot,
                                 tiles: jobs.map { (SIMD2($0.x, $0.z), $0.level) },
                                 style: TerrainMeshStyle(uvScale: 1 / World.groundTile, tileLocal: true, skirts: true, rock: UInt8(World.Ground.rock)),
                                 material: firstGround, offset: anchor) { k in
            var m = World.groundMaterials[k]
            if m.textures.x == World.groundDetail { m.textures.x = detail }
            if m.textures.x == World.fieldRows { m.textures.x = rows }
            return m
        }
        triangles += terrain.parts.reduce(0) { $0 + $1.sector.triangleCount }
        if realistic {
            let middleCenter = WorldTile.origin(middle.x, middle.y) + SIMD2(side / 2, side / 2)
            let lo = SIMD2<Float>(Float(middleCenter.x - anchor.x) - 1024, Float(middleCenter.y - anchor.y) - 1024)
            terrainDetailCenter = lo + 1024   // (realism high: the middle tile's near ground refined)
            let shown = world
            addGroundLook(GroundLook(
                layers: World.groundScans.enumerated().map { k, g in
                    let a = World.groundMaterials[k].albedo
                    return .init(set: g.set, color: SIMD3(a.x, a.y, a.z) * FoliageTextures.mean, tint: g.tint, contrast: g.set == "rock" ? 1.4 : 0.7)
                },
                rock: World.Ground.rock, slope: [0.6, 0.78], lo: lo, size: [2048, 2048], texels: 2048,
                key: "world \(world.seed) \(middle.x) \(middle.y) \(anchorTile.x) \(anchorTile.y) \(snapshot.editsFingerprint) v1") { x, z in
                let wx = Double(x) + anchor.x, wz = Double(z) + anchor.y
                let k = shown.ground(wx, wz, up: 1, city: shown.city(near: wx, wz))
                var w = [Float](repeating: 0, count: 8)
                w[min(max(k, 0), 7)] = 1
                return w
            })
        }
        addWorldWater(world, tiles: jobs.map { SIMD2($0.x, $0.z) }, anchor: anchor)

        var plants = 0
        for (c, placements) in cover.enumerated() {
            let corner = SIMD3(Float(lo.x + Double(c % cells) * cell - anchor.x), 0, Float(lo.y + Double(c / cells) * cell - anchor.y))
            let cellOrigin = SIMD2(lo.x + Double(c % cells) * cell, lo.y + Double(c / cells) * cell)
            for p in placements {
                let lift = snapshot.delta(x: cellOrigin.x + Double(p.x), z: cellOrigin.y + Double(p.z))
                flora.place(Foliage.Species(rawValue: Int(p.species)), Int(p.plant), at: corner + SIMD3(p.x, p.y + lift, p.z), yaw: p.yaw,
                            size: p.size, shade: Int(p.shade))
            }
            plants += placements.count
        }

        // The buildings next to the camera, for the renderer to choose the one whose interior to make (lotAreas), and
        // that one with its interior (its tile left it out): still (the world's scenes are), its doors open.
        let kit = BuildingKit(self, mapIndex: mapIndex)
        kit.still = true
        for (k, job) in jobs.enumerated() where job.level == 0 && tiles[k] != nil {
            let o = WorldTile.origin(job.x, job.z)
            guard let (city, blocks) = world.blocks(x0: o.x, z0: o.y, side: side) else { continue }
            for block in blocks {
                for (i, lot) in block.plan.lots.enumerated() {
                    let ref = world.lotRef(city, block, i)
                    let c = SIMD2(Float(city.center.x - anchor.x), Float(city.center.y - anchor.y))
                    lotAreas.append((ref.key, CityPlan.Rect(lo: lot.rect.lo + c, hi: lot.rect.hi + c), Float(lot.floors) * 3.4 + 6))
                    guard ref.key == settings.interior else { continue }
                    var spec = BuildingSpec(lot: lot, city: settings.city, night: true, catalog: buildings)
                    if let o = buildings.override(for: ref) { spec.apply(o, catalog: buildings) }
                    spec.interior = true
                    let building = BuildingGenerator.generate(spec)
                    let transform = translate([c.x, city.level, c.y]) * lot.transform
                    kit.addBuilding(building, at: transform)
                    walkAreas.append(WalkArea(rect: CityPlan.Rect(lo: lot.rect.lo + c, hi: lot.rect.hi + c), building: building, at: transform))
                }
            }
        }
        walkColliders = kit.colliders   // (and the terrain's walkGround)
        kit.addFlashlight()

        // The realistic look's meadow grass and rocks round the middle tile (out to its corners and a little beyond):
        // grass on the meadows (not on the roads, in the cities or the water), rocks where it is steep and in the woods.
        if realistic {
            let mc = WorldTile.origin(middle.x, middle.y) + SIMD2(side / 2, side / 2)
            let c = SIMD2<Float>(Float(mc.x - anchor.x), Float(mc.y - anchor.y))
            let shown = world, waterField = water?.field, ground = self.terrain?.field.snapshot()
            let tileSeed = world.seed ^ (UInt64(bitPattern: Int64(middle.x)) &* 0x9E37_79B9) ^ (UInt64(bitPattern: Int64(middle.y)) &* 0x85EB_CA6B)
            func place(_ x: Float, _ z: Float) -> (x: Double, z: Double, city: World.City?) {
                let wx = Double(x) + anchor.x, wz = Double(z) + anchor.y
                return (wx, wz, shown.city(near: wx, wz))
            }
            func open(_ x: Float, _ z: Float) -> Bool {
                let p = place(x, z)
                // (Not on a city's blocks and streets; its apron's meadows are meadows.)
                if let city = p.city, simd_distance(SIMD2(p.x, p.z), city.center) < Double(city.radius) + 6 { return false }
                if let road = shown.highway(p.city, p.x, p.z), road.distance < road.half + 1.5 { return false }
                return waterField?.wet(p.x, p.z, margin: 1) != true   // (the world's field: the world's places)
            }
            let grass = addMeadowGrass(center: c, reach: 190, seed: tileSeed, flora: flora) { x, z in
                let p = place(x, z)
                guard shown.ground(p.x, p.z, up: 1, city: p.city) == World.Ground.meadow, open(x, z) else { return 0 }
                return 0.8 + 0.2 * GroundLook.smooth(-0.3, 0.4, Terrain.noise(SIMD2(x, z) / 19, seed: UInt32(truncatingIfNeeded: tileSeed)))
            }
            let rocks = addRocks(count: 9000, lo: c - 170, hi: c + 170, seed: tileSeed &+ 0x80C) { x, z in
                guard open(x, z) else { return (0, 0.2...0.3) }
                let p = place(x, z), kind = shown.ground(p.x, p.z, up: 1, city: p.city)
                // (Not on the fields or the sand.)
                if [World.Ground.wheat, World.Ground.crop, World.Ground.ploughed, World.Ground.sand].contains(kind) { return (0, 0.2...0.3) }
                let up = ground?.normal(x: p.x, z: p.z).y ?? 1
                let steep = 1 - GroundLook.smooth(0.72, 0.9, up)
                let woods = shown.woods(p.x, p.z)
                return (min(0.04 + 0.7 * steep + 0.12 * woods, 1) * 0.5, 0.2...(0.7 + 1.8 * steep + 0.3 * woods))
            }
            print("World: the realistic look's \(grass) grass patches and \(rocks) rocks round tile \(middle.x), \(middle.y)")
        }

        // The light from the sky: the sun, and once it has set the moon (its colour is the atmosphere's to say).
        addLight(.sun(angularRadius: Heavens.discRadius), color: [1, 1, 1]) { t in
            LightPose(position: .zero, direction: Heavens(at: t).light)
        }
        if lit { forcesLightTable = true }
        let center = WorldTile.origin(middle.x, middle.y) + SIMD2(side / 2, side / 2)
        let ground = SIMD3(Float(center.x - anchor.x), world.height(center.x, center.y), Float(center.y - anchor.y))
        var camera = Camera()
        if settings.worldTile == nil {
            camera.position = SIMD3(Float(begin.place.x - anchor.x), Float(begin.place.y), Float(begin.place.z - anchor.y))
            camera.yaw = begin.yaw
            camera.pitch = 0.05
        } else {
            // A scene asked for somewhere else in the world: from above its middle.
            camera.position = ground + SIMD3(0, 40, 0)
            camera.pitch = -0.15
        }
        defaultCamera = camera
        worldPlace = WorldPlace(world: world, anchorTile: anchorTile, tile: middle, middle: ground)
        print(String(format: "World: around tile (%d, %d), origin at tile (%d, %d): %d tiles (%d kept), %d triangles, %d trees, %d of ground cover, in %.2f s",
                     middle.x, middle.y, anchorTile.x, anchorTile.y, jobs.count, shared, triangles, trees, plants,
                     CFAbsoluteTimeGetCurrent() - start))
    }
}
