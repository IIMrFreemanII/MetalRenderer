import Foundation
import simd

/// Which part of the open world a scene holds (Scene.worldPlace).
struct WorldPlace {
    var world: World
    /// The world's place that is the scene's origin (x, z): the scene's coordinates are metres from it.
    var anchor: SIMD2<Double>
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
}

extension World {
    /// Where the world is first seen from: on the open ground south of the origin's city, looking at it.
    var start: (place: SIMD3<Double>, yaw: Float) {
        let city = city(cell: SIMD2(0, 0))!
        let x = city.center.x + 30, z = city.center.y + Double(city.radius) + 110
        return (SIMD3(x, Double(height(x, z)) + 1.7, z), 0)
    }

    /// The scenes' origin: the corner of the tile the origin's city has its middle in. (Coordinates stay small
    /// around the first city; a world walked far from it needs the origin to follow.)
    var anchor: SIMD2<Double> {
        let city = city(cell: SIMD2(0, 0))!, side = Double(World.tileSize)
        return SIMD2((city.center.x / side).rounded(.down) * side, (city.center.y / side).rounded(.down) * side)
    }
}

/// The Open world scene: the world's tiles around one of them, each at the level its distance asks for, the trees
/// and the ground cover they hold as instances of the world's plants. The scene is one moment of the world: when the
/// camera moves into another tile, the renderer makes the scene around that one (`SceneSettings.worldTile`), in the
/// background, from the tiles this one already has and the few that are new.
extension Scene {
    /// The tiles of the last scene, by what they were made for: the next scene shares most of them.
    private static var keptTiles: [String: WorldTile] = [:]
    private static let keptLock = NSLock()

    func buildWorld() {
        let start = CFAbsoluteTimeGetCurrent()
        var world = World(seed: UInt64(max(settings.seed, 0)))
        world.treeDensity = Float(max(settings.trees, 0)) / 10.24      // the Forest's square is 10.24 hectares
        world.undergrowth = Float(max(settings.undergrowth, 0)) / 100
        let flora = Flora(self, seed: world.seed)
        let index = flora.index
        let begin = world.start, anchor = world.anchor, side = Double(World.tileSize)
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

        // The city's generated textures, each kind's added the first time a material asks for it (as the City's).
        let maps = settings.city.textures ? ProceduralTextures.sources(SurfaceKind.allCases) : [:]
        var mapIndex: [SurfaceKind: SIMD4<UInt32>] = [:]
        func textures(_ kind: SurfaceKind) -> SIMD4<UInt32> {
            if let known = mapIndex[kind] { return known }
            guard let m = maps[kind] else { return SIMD4(repeating: .max) }
            let made = SIMD4(addTexture(m.base), m.roughness.map { addTexture($0) } ?? .max, addTexture(m.normal), .max)
            mapIndex[kind] = made
            return made
        }

        // The ground's detail: clumps and specks, the same every 5 m (the ground's UVs are the asphalt's).
        let detail = addGeneratedTexture(name: "ground-detail", width: 512, height: 512, key: "v\(FoliageTextures.version)") {
            FoliageTextures.image(512, 512, normalized: true) { u, v in
                let clumps = FoliageTextures.noise(u * 6, v * 6, 6, 6, 21) + 0.6 * FoliageTextures.noise(u * 17, v * 17, 17, 17, 22)
                let specks = FoliageTextures.noise(u * 60, v * 60, 60, 60, 23)
                return SIMD3(repeating: max(0.75 + 0.3 * clumps + 0.22 * specks, 0.1))
            }
        }

        var triangles = 0, trees = 0
        reserveGeometry(vertices: tiles.reduce(0) { $0 + $1!.chunks.reduce(0) { $0 + $1.positions.count } },
                        indices: tiles.reduce(0) { $0 + 3 * $1!.triangles })
        for (k, tile) in tiles.enumerated() {
            guard let tile else { continue }
            let origin = WorldTile.origin(jobs[k].x, jobs[k].z)
            let corner = SIMD3(Float(origin.x - anchor.x), 0, Float(origin.y - anchor.y))
            for chunk in tile.chunks {
                // The chunk's materials, one after the other: its triangles name them from the first.
                var first = -1
                for m in chunk.materials {
                    var material = m
                    if let kind = World.kind(ofTexture: m.textures.x) { material.textures = textures(kind) }
                    if m.textures.x == World.groundDetail { material.textures.x = detail }
                    let added = chunk.glass ? addGlassMaterial(tint: SIMD3(m.albedo.x, m.albedo.y, m.albedo.z)) : addMaterial(material)
                    if first < 0 { first = added }
                }
                let mesh = addMesh((chunk.positions, chunk.normals, chunk.indices), uvs: chunk.uvs, materials: chunk.triangleMaterials)
                addInstance(mesh, first, translate(corner), mask: chunk.glass ? Scene.maskGlass : Scene.maskGeometry)
                triangles += chunk.triangles
            }
            for t in tile.trees {
                flora.place(Foliage.Species(rawValue: Int(t.species))!, Int(t.plant), at: corner + SIMD3(t.x, t.y, t.z), yaw: t.yaw,
                            size: t.size, shade: Int(t.shade))
            }
            trees += tile.trees.count
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
        var plants = 0
        for (c, placements) in cover.enumerated() {
            let corner = SIMD3(Float(lo.x + Double(c % cells) * cell - anchor.x), 0, Float(lo.y + Double(c / cells) * cell - anchor.y))
            for p in placements {
                flora.place(Foliage.Species(rawValue: Int(p.species))!, Int(p.plant), at: corner + SIMD3(p.x, p.y, p.z), yaw: p.yaw,
                            size: p.size, shade: Int(p.shade))
            }
            plants += placements.count
        }

        addDaySun(half: 90)
        var camera = Camera()
        camera.position = SIMD3(Float(begin.place.x - anchor.x), Float(begin.place.y), Float(begin.place.z - anchor.y))
        camera.yaw = begin.yaw
        camera.pitch = 0.05
        defaultCamera = camera
        let center = WorldTile.origin(middle.x, middle.y) + SIMD2(side / 2, side / 2)
        worldPlace = WorldPlace(world: world, anchor: anchor, tile: middle,
                                middle: SIMD3(Float(center.x - anchor.x), world.height(center.x, center.y), Float(center.y - anchor.y)))
        print(String(format: "World: around tile (%d, %d): %d tiles (%d kept), %d triangles, %d trees, %d of ground cover, in %.2f s",
                     middle.x, middle.y, jobs.count, shared, triangles, trees, plants, CFAbsoluteTimeGetCurrent() - start))
    }
}
