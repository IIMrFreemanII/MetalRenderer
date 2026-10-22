import EngineCore
import Foundation
import ImageIO
import simd

extension Scene {
    // MARK: - Physics

    package func physicsWorld() -> PhysicsWorld {
        if let physics { return physics }
        let world = PhysicsWorld(substeps: settings.physics.substeps)
        physics = world
        return world
    }

    /// A rigid body: an instance of SDF shape `sdf` that the physics moves, starting at `transform` (a rotation and a
    /// translation). `density` kg/m^3; `friction` and `restitution` are mixed with what it touches (the geometric
    /// mean and the larger).
    @discardableResult
    package func addBody(sdf: Int, _ material: Int, _ transform: float4x4, density: Float = 500, friction: Float = 0.5,
                 restitution: Float = 0.2, velocity: SIMD3<Float> = .zero, spin: SIMD3<Float> = .zero,
                 mask: UInt32 = Scene.maskGeometry) -> Int {
        let i = addInstance(sdf: sdf, material, transform, mask: mask)
        instances[i].simulated = true
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        world.addBody(sdf: sdf, sdfShapes[sdf], transform: transform, instance: i, density: density, friction: friction,
                      restitution: restitution, velocity: velocity, spin: spin)
        return i
    }

    /// A loose piece of furniture (Scene+Interiors.swift): an instance of `mesh` (drawn as it is) that the physics moves
    /// as a box of `halfExtents` round the mesh's origin, `mass` kg. The box is the physics' alone: nothing draws it.
    @discardableResult
    package func addMeshBody(_ mesh: Int, _ material: Int, _ transform: float4x4, halfExtents: SIMD3<Float>, mass: Float, friction: Float = 0.55) -> Int {
        let i = addInstance(mesh, material, transform)
        instances[i].simulated = true
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        let shape = SDFShape(.box(halfExtents: halfExtents, rounding: min(0.008, halfExtents.min() * 0.2)))
        let sdf = addSDFShape(shape)
        let volume = 8 * halfExtents.x * halfExtents.y * halfExtents.z
        return world.addBody(sdf: sdf, shape, transform: transform, instance: i, density: mass / max(volume, 1e-4), friction: friction,
                             restitution: 0.1)
    }

    /// A box the physics' bodies meet (a wall, a floor, a cupboard), from `lo` to `hi`; nothing draws it.
    package func addStaticBox(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, friction: Float = 0.6) {
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        let half = simd_max((hi - lo) / 2, SIMD3(repeating: 0.005))
        let shape = SDFShape(.box(halfExtents: half))
        world.addStatic(sdf: addSDFShape(shape), shape, transform: translate((lo + hi) / 2), friction: friction, restitution: 0.1)
    }

    /// A kinematic body (PhysicsFlesh.swift): an instance of SDF shape `sdf` that its column of the physics' pose table
    /// moves, starting at `transform`; `mask` 0 to keep it out of sight (a bone under flesh). Returns its body.
    @discardableResult
    package func addKinematicBody(sdf: Int, _ material: Int, _ transform: float4x4, mask: UInt32 = Scene.maskGeometry, friction: Float = 0.6) -> Int {
        let i = addInstance(sdf: sdf, material, transform, mask: mask)
        instances[i].simulated = true
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        return world.addKinematicBody(sdf: sdf, sdfShapes[sdf], transform: transform, instance: i, friction: friction)
    }

    /// A figure's flesh drawn (PhysicsFlesh.swift): `mesh`, in the figure's rest space, embedded in `flesh`'s lattice
    /// (each vertex in the tet `own` gives it, or on figure bone `rigid[v]` where that is -1), as a deforming mesh the
    /// GPU writes every frame, starting where the flesh is. `weld`: its vertices at one place share their normal.
    package func addFleshMesh(_ flesh: PhysicsWorld.Flesh, figure: FleshFigure, mesh: MeshGeometry, uvs: [SIMD2<Float>]? = nil,
                      materials: [UInt8]? = nil, own: [Int], rigid: [Int], weld: Bool, material: Int, bounds: AABB, skin: SkinShell? = nil) {
        var drawn = flesh
        drawn.model.embed(mesh, in: own, weld: weld)
        let m = addDeformingMesh(mesh, uvs: uvs, materials: materials, bounds: bounds, label: skin == nil ? "flesh" : "skin")
        addDeformingInstance(m, material)
        softMeshes.append(m)
        let world = physicsWorld(), base = deforming.last!.first, firstVertex = world.softVertices.count
        world.addFleshSurface(drawn, figure: figure, vertexBase: base, rigid: rigid, skin: skin)
        for v in firstVertex..<world.softVertices.count { positions[Int(world.softVertices[v].info.x)] = world.drawnSoftVertex(v) }
    }


    /// A cloth: `columns` x `rows` vertices from `origin` along `across` and `down` (its whole width and height),
    /// `pinned` ones (row-major) held where they are; the physics moves the rest, the GPU writes the mesh every frame.
    package func addCloth(_ material: Int, origin: SIMD3<Float>, across: SIMD3<Float>, down: SIMD3<Float>, columns: Int, rows: Int,
                  pinned: Set<Int>, thickness: Float = 0.008, friction: Float = 0.6) {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        let normal = normalize(cross(down, across))
        for r in 0..<rows {
            for c in 0..<columns {
                let u = Float(c) / Float(columns - 1), v = Float(r) / Float(rows - 1)
                positions.append(origin + across * u + down * v)
                uvs.append(SIMD2(u, v))
            }
        }
        // Wound as PhysicsGPU's normals face: along a row, then down a column.
        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let a = UInt32(r * columns + c), b = a + 1, d = a + UInt32(columns), e = d + 1
                indices += [a, d, b, b, d, e]
            }
        }
        // As far as it can get: its size every way from where it starts, and down to the floor.
        var box = AABB()
        for p in positions { box.grow(p) }
        let reach = max(length(across), length(down)) + 0.1
        box.lo = simd_min(box.lo - reach, SIMD3(box.lo.x - reach, -0.1, box.lo.z - reach))
        box.hi += reach
        let mesh = addDeformingMesh((positions, [SIMD3<Float>](repeating: normal, count: positions.count), indices), uvs: uvs, bounds: box,
                                    label: "cloth")
        addDeformingInstance(mesh, material)
        clothMeshes.append(mesh)
        physicsWorld().addCloth(origin: origin, across: across, down: down, columns: columns, rows: rows, pinned: pinned,
                                thickness: thickness, friction: friction, vertexBase: deforming.last!.first)
    }


    /// A soft body made of `model` (PhysicsSoft.swift), placed by `transform` (a rotation and a translation): the
    /// physics moves its lattice, the GPU writes its surface every frame. `edge` and `volume`: its links' and tets'
    /// compliance; `bounds`: where it can get to (the mesh's box whatever it does).
    package func addSoftBody(_ model: SoftModel, _ material: Int, _ transform: float4x4, bounds: AABB, velocity: SIMD3<Float> = .zero,
                     density: Float = 1000, edge: Float = 1e-3, volume: Float = 1e-9, damping: Float = PhysicsWorld.softLinkDamping,
                     friction: Float = 0.6) {
        let rotation = simd_float3x3(columns: (PhysicsMath.xyz(transform.columns.0), PhysicsMath.xyz(transform.columns.1),
                                               PhysicsMath.xyz(transform.columns.2)))
        let positions = model.surface.positions.map { PhysicsMath.xyz(transform * SIMD4($0, 1)) }
        let mesh = addDeformingMesh((positions, model.surface.normals.map { rotation * $0 }, model.surface.indices), bounds: bounds,
                                    label: "soft body")
        addDeformingInstance(mesh, material)
        softMeshes.append(mesh)
        physicsWorld().addSoftBody(model, transform: transform, vertexBase: deforming.last!.first, velocity: velocity, density: density,
                                   edge: edge, volume: volume, damping: damping, friction: friction)
    }

    /// The soft bodies' drawn vertices: where their meshes' last-frame vertices are (once `finishDeforming` put them).
    package func finishSoftBodies() {
        guard let physics, !softMeshes.isEmpty else { return }
        for v in physics.softVertices.indices {
            physics.softVertices[v].info.y = meshes[softMeshes[Int(physics.softVertices[v].info.z)]].prevOffset
        }
    }

    /// Particles: balls of `radius` at `positions` that the physics moves (each an instance of one sphere shape).
    package func addParticles(_ material: Int, radius: Float, positions: [SIMD3<Float>], density: Float = 1500, friction: Float = 0.5) {
        guard !positions.isEmpty else { return }
        let sphere = addSDFShape(SDFShape(.sphere(radius: radius)))
        let world = physicsWorld()
        for p in positions {
            let i = addInstance(sdf: sphere, material, translate(p))
            instances[i].simulated = true
            world.addParticle(at: p, radius: radius, instance: i, density: density, friction: friction)
        }
    }

    /// A liquid (PhysicsFluid.swift) held in `domain`, poured from `nozzle` (straight down) until it has `capacity`
    /// particles. After the static colliders it meets.
    /// Its surface is a mesh the GPU makes again every frame (FluidSurface.swift), whose structure is built again every
    /// frame (`rebuiltMeshes`): it holds a fixed number of vertices (one spare) and triangles. It is drawn as the
    /// liquid it is (`addLiquidMaterial`), or with `material` as an opaque surface.
    package func addLiquid(_ kind: LiquidKind, solver: PhysicsSettings.Solver, domain: AABB, nozzle: SIMD3<Float>, capacity: Int,
                   material: Int? = nil) {
        let world = physicsWorld()
        world.addLiquid(kind, solver: solver, domain: domain, nozzle: nozzle, capacity: capacity)
        let system = world.fluid!.systems.count - 1, s = world.fluid!.systems[system]
        let bounds = s.surfaceBounds(s.surface), middle = (bounds.lo + bounds.hi) / 2
        let v = Int(s.surface.mesh.w) + 1, t = Int(s.surface.triangles.x)
        let mesh = addDeformingMesh(([SIMD3<Float>](repeating: middle, count: v), [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: v),
                                     [UInt32](repeating: UInt32(v - 1), count: 3 * t)), bounds: bounds, label: "\(kind) surface")
        rebuiltMeshes.insert(mesh)
        if let material {
            addDeformingInstance(mesh, material)
        } else {
            let i = addInstance(mesh, addLiquidMaterial(kind.look), matrix_identity_float4x4, mask: Scene.maskLiquid)
            instances[i].deforms = true
        }
        liquidMeshes.append((system, mesh, deforming.last!.first))
    }

    /// The last body added held where it is until `time` (s), then dropped (PhysicsWorld.hold).
    package func holdBody(until time: Float) {
        let world = physicsWorld()
        world.hold(body: world.bodies.count - 1, until: time)
    }


    /// The liquids' surfaces: where their meshes' vertices, indices and last-frame vertices are (once
    /// `finishDeforming` put them).
    package func finishLiquids() {
        guard let physics else { return }
        for (system, m, first) in liquidMeshes {
            physics.fluid!.systems[system].surface.mesh.x = UInt32(first)   // (its indices are the buffer's, as every mesh's)
            physics.fluid!.systems[system].surface.mesh.y = meshes[m].firstIndex
            physics.fluid!.systems[system].surface.mesh.z = meshes[m].prevOffset
        }
    }

    /// Something bodies bounce off that never moves: SDF shape `sdf` at `transform` (draw it, or not, apart).
    package func addStaticCollider(sdf: Int, _ transform: float4x4, friction: Float = 0.6, restitution: Float = 0.2) {
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        world.addStatic(sdf: sdf, sdfShapes[sdf], transform: transform, friction: friction, restitution: restitution)
    }

    /// An endless static plane bodies rest on.
    package func addStaticPlane(point: SIMD3<Float>, normal: SIMD3<Float>, friction: Float = 0.6, restitution: Float = 0.2) {
        physicsWorld().addPlane(point: point, normal: normal, friction: friction, restitution: restitution)
    }

    /// Generated plants were placed (Flora): see `hasPlants`.
    package func notePlants() { hasPlants = true }

    /// A metallic-roughness material with a specular lobe (the gallery's floor and plinths).
    /// A generated character's run of materials (CharacterBuilder.materials), its first returned: an instance of the
    /// character names it. `glossy` false: diffuse ones (a crowd's: glossy materials turn on the reflection pass for
    /// the whole frame, about 3 ms at 1920 x 1200 on an M1 Max, for eyes a few pixels across). `maps`: the skin's
    /// textures (colour, roughness, normals: `addSkinTextures`), for its skin's materials; `hair`: a hair cap's colour
    /// (CharacterHair.colour); `strandBrows`: brows of strands, not painted.
    package func addCharacterMaterials(_ look: CharacterDNA.Look, skin: SIMD3<Float>, glossy: Bool = true, maps: SIMD3<UInt32>? = nil,
                               hair: SIMD3<Float> = [0.08, 0.05, 0.03], strandBrows: Bool = false) -> Int {
        let run = CharacterBuilder.materials(look, skin: skin, hair: hair, strandBrows: strandBrows).map { m in
            var material = GPUMaterial(albedo: SIMD4(m.color, 0), emission: SIMD4(.zero, glossy ? m.roughness : 1),
                                       params: SIMD4(glossy ? 1 : 0, 1, 0, -m.skin))
            if let maps, m.textured {
                // The colour texture holds its multiplier scaled down (SkinTextures.colourScale), the roughness its too.
                material.albedo = SIMD4(m.color / SkinTextures.colourScale, 0)
                material.emission.w = min(m.roughness / SkinTextures.roughnessScale, 1)
                material.textures = SIMD4(maps.x, glossy ? maps.y : .max, maps.z, .max)
            }
            return addMaterial(material)
        }
        return run[0]
    }

    /// The skin's textures for `dna` (SkinTextures, over the kit's chart): colour, roughness and normals, drawn only
    /// when no cache has them (a remade workshop asks again at every edit).
    package func addSkinTextures(_ dna: CharacterDNA, kit: CharacterKit) -> SIMD3<UInt32> {
        let marks = SkinTextures.Marks(dna), wrinkles = SkinTextures.wrinkles(age: dna.macro.age)
        let size = SkinChart.defaultSize
        let colour = addGeneratedTexture(name: "skin-colour", width: size, height: size, key: marks.key, srgb: false) {
            SkinTextures.cached("colour \(marks.key)") { SkinTextures.colour(kit.chart, marks) }
        }
        let roughness = addGeneratedTexture(name: "skin-roughness", width: size / 2, height: size / 2, key: SkinTextures.versionKey,
                                            srgb: false) {
            SkinTextures.cached("roughness") { SkinTextures.roughness(kit.chart) }
        }
        let normals = addGeneratedTexture(name: "skin-normals", width: size, height: size,
                                          key: "\(SkinTextures.versionKey)-w\(Int(wrinkles * 12))", srgb: false) {
            SkinTextures.cached("normals \(wrinkles)") { SkinTextures.normals(kit.chart, wrinkles: wrinkles) }
        }
        return SIMD3(colour, roughness, normals)
    }

    package func addPBRMaterial(baseColor: SIMD3<Float>, metallic: Float, roughness: Float) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(baseColor, metallic), emission: SIMD4<Float>(.zero, roughness),
                                     params: SIMD4(1, 1, 0, 0)))
        return materials.count - 1
    }

    /// A liquid (Shaders/Liquid.metal), for instances with `maskLiquid`: its absorption in the albedo's colour, its index
    /// of refraction in its alpha, its roughness in the emission's alpha.
    package func addLiquidMaterial(_ look: LiquidKind.Look) -> Int {
        hasLiquid = true
        return addMaterial(GPUMaterial(albedo: SIMD4(look.absorption, look.ior), emission: SIMD4(.zero, look.roughness), params: SIMD4(0, 1, 0, 0)))
    }

    /// Window glass tinted `tint` (white = clear), for instances with `maskGlass`.
    package func addGlassMaterial(tint: SIMD3<Float>) -> Int {
        hasGlass = true
        return addMaterial(GPUMaterial(albedo: SIMD4(tint, 0), emission: SIMD4(.zero, 0), params: SIMD4(0, 1, 0, 0)))
    }

    /// Any material, as it is.
    package func addMaterial(_ material: GPUMaterial) -> Int {
        materials.append(material)
        if material.params.w < 0 { hasSkin = true }
        return materials.count - 1
    }

    /// An image for materials to sample: its index for `GPUMaterial.textures`.
    package func addTexture(_ source: TextureSource) -> UInt32 {
        textures.append(source)
        return UInt32(textures.count - 1)
    }

    /// Room for this much more geometry (a builder that knows how much it is about to add): an array that grows by
    /// itself doubles, and ends up to twice as large as what it holds.
    package func reserveGeometry(vertices: Int, indices count: Int, instances more: Int = 0) {
        positions.reserveCapacity(positions.count + vertices)
        normals.reserveCapacity(normals.count + vertices)
        uvs.reserveCapacity(uvs.count + vertices)
        indices.reserveCapacity(indices.count + count)
        // In steps of 65536: a scene made again with a few more instances then asks for a block of the size the last
        // one let go of, which the allocator hands back, instead of a new one (it keeps what was freed).
        if more > 0 { instances.reserveCapacity((instances.count + more + 0xFFFF) & ~0xFFFF) }
    }

    /// A diffuse material (metallic 0, roughness 1, no specular: how every generated object has always looked).
    /// `translucency`: a leaf's, the share of its light that comes through from the far side.
    /// `texture`: its base colour's detail (the colour is multiplied by it), from `addGeneratedTexture`.
    package func addMaterial(albedo: SIMD3<Float>, emission: SIMD3<Float> = .zero, translucency: Float = 0, texture: UInt32 = .max) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(albedo, 0), emission: SIMD4<Float>(emission, 1), params: SIMD4(0, 1, 0, translucency),
                                     textures: SIMD4(texture, .max, .max, .max)))
        return materials.count - 1
    }

    /// A strand's (Hair.metal): its colour, the one it is seen to have (the pigment's absorption is fitted to it).
    /// Marked by params.z < 0 (an emissive-mesh light's is > 0).
    package func addHairMaterial(color: SIMD3<Float>) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(color, 0), emission: SIMD4<Float>(.zero, 1), params: SIMD4(0, 1, -1, 0)))
        return materials.count - 1
    }

    package func addLeafMaterial(_ material: LeafMaterial) { leafMaterials.append(material) }

    /// A texture made here rather than read from a model (FoliageTextures): the index a material names it by. The
    /// streamer keeps one cache file for all of a scene kind's, named by their pixels, so a change remakes it.
    /// `srgb`: its pixels are colours (false: data, such as a normal map's).
    package func addGeneratedTexture(_ image: FoliageTextures.Image, name: String, srgb: Bool = true) -> UInt32 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in image.pixels { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        // (With the cache off, a file of its own: the mip chains named by parameters stay as they are.)
        textures.append(TextureSource(data: Data(image.pixels), srgb: srgb, name: "generated/\(name)",
                                      modelPath: GeneratedCache.folder.appendingPathComponent("\(settings.kind)\(GeneratedCache.enabled ? "" : "-uncached")").path,
                                      cacheKey: "\(name)-\(image.width)x\(image.height)-\(String(hash, radix: 16))",
                                      raw: (image.width, image.height)))
        return UInt32(textures.count - 1)
    }

    /// A generated texture that `draw` draws only if no cache holds it: the caches name it by `key`, which says
    /// everything its pixels depend on (the generator's version, a seed). With the cache off it is drawn here and
    /// named by its pixels, as above.
    package func addGeneratedTexture(name: String, width: Int, height: Int, key: String, srgb: Bool = true,
                             _ draw: @escaping () -> FoliageTextures.Image) -> UInt32 {
        guard GeneratedCache.enabled else { return addGeneratedTexture(draw(), name: name, srgb: srgb) }
        textures.append(TextureSource(data: Data(), srgb: srgb, name: "generated/\(name)",
                                      modelPath: GeneratedCache.folder.appendingPathComponent("\(settings.kind)").path,
                                      cacheKey: "\(name)-\(width)x\(height)-\(key)", raw: (width, height),
                                      pixels: { Data(draw().pixels) }))
        return UInt32(textures.count - 1)
    }

    /// Whether the scene's generated plants are baked into meshes even though assemblies were asked for: the open
    /// world's, which stand still there (one set of variants at rest), while no leaves have fallen (only variants drop
    /// them), leaves aren't cards (only assemblies have them) and far plants aren't voxels (VoxelLOD would rebuild its
    /// half a million instances' structure). On an M4 Max
    /// the assemblies' third level of instancing made every ray that meets a plant cost about twice as much: whole
    /// frames 14-15% faster baked, for about 100 MB more of ray-tracing structures.
    package static func bakesPlants(_ settings: SceneSettings, leafFall: Float) -> Bool {
        settings.kind.isWorld && leafFall == 0 && !settings.leafCards && !settings.voxelBoxes
    }

    /// The share of the deciduous plants' leaves that have fallen at `season` (the plants' variants drop them).
    package static func leafFall(season: Float) -> Float {
        let t = min(max((season - 0.62) / 0.33, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The leaves at `season`: 0 = spring (fresh, light), 0.3 = summer, from 0.5 they turn, each material in its own
    /// time, and by winter (1) what is left is brown; evergreens stay as they are. `translucency` scales how much
    /// light every leaf lets through (0 = none: opaque leaves). Only the materials change (the renderer uploads the range).
    package func setLeaves(season s: Float, translucency: Float = 1) {
        guard leafState != SIMD2(s, translucency), !leafMaterials.isEmpty else { return }
        leafState = SIMD2(s, translucency)
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        var lo = Int.max, hi = 0
        for m in leafMaterials {
            var color = m.summer
            if let autumn = m.autumn {
                color *= 1 + SIMD3<Float>(0.25, 0.3, 0.1) * (1 - smooth(0, 0.25, s))
                color += (autumn - color) * smooth(m.turn - 0.1, m.turn + 0.1, s)
                color += (SIMD3<Float>(0.2, 0.13, 0.07) - color) * smooth(0.82, 1, s) * 0.8
            }
            let albedo = SIMD4(color * m.gain, materials[m.material].albedo.w), through = m.translucency * translucency
            guard materials[m.material].albedo != albedo || materials[m.material].params.w != through else { continue }
            materials[m.material].albedo = albedo
            materials[m.material].params.w = through
            lo = min(lo, m.material); hi = max(hi, m.material + 1)
        }
        guard lo < hi else { return }
        materialsDirty = materialsDirty.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi
    }

    /// The open world's lights, as far on as they are with the sun `sunElevation` high (radians): what their
    /// materials emit. (A light the scene samples takes what it emits from its material; how likely it is to be
    /// picked stays what it is when it is on.)
    /// The same goes into the light table's triangles (`GPUTriangleInfo.radianceLum`), which say how bright a light
    /// is to whoever picks one among many: a light that is off is not picked.
    package func setCityLights(sunElevation: Float) {
        // Above and below the heights between which lights come on, nothing changes.
        let degree = Float.pi / 180, elevation = min(max(sunElevation, -9 * degree), 4 * degree)
        guard cityLightsElevation != elevation, !cityLights.isEmpty else { return }
        cityLightsElevation = elevation
        var lo = Int.max, hi = 0, first = Int.max, last = 0
        for i in cityLights.indices {
            let light = cityLights[i], on = World.lightOn(elevation: elevation, window: light.window)
            guard on != light.on else { continue }
            cityLights[i].on = on
            materials[light.material].emission = SIMD4(light.emission * on, materials[light.material].emission.w)
            lo = min(lo, light.material); hi = max(hi, light.material + 1)
            for range in light.triangles {
                for t in range { lightTable.triangles[t].radianceLum = cityLightRadiance[t] * on }
                first = min(first, range.lowerBound); last = max(last, range.upperBound)
            }
        }
        if lo < hi { materialsDirty = materialsDirty.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi }
        if first < last {
            lightTrianglesDirty = lightTrianglesDirty.map { min($0.lowerBound, first)..<max($0.upperBound, last) } ?? first..<last
        }
    }

    /// Which of the light table's triangles each city light has: its material's mesh lights'. They start as their
    /// lights do, off.
    package func bindCityLights() {
        guard !cityLights.isEmpty, !meshLights.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: cityLights.enumerated().map { ($1.material, $0) })
        cityLightRadiance = lightTable.triangles.map(\.radianceLum)
        for light in meshLights {
            guard let c = index[instances[light.instance].material + light.materialOffset] else { continue }
            let range = light.firstTriangle..<(light.firstTriangle + light.triangleCount)
            cityLights[c].triangles.append(range)
            for t in range { lightTable.triangles[t].radianceLum = cityLightRadiance[t] * cityLights[c].on }
        }
    }

    /// The light table's triangles changed since the last call (`setCityLights`), for the renderer to write again.
    package func takeLightTrianglesDirty() -> Range<Int>? {
        defer { lightTrianglesDirty = nil }
        return lightTrianglesDirty
    }

    @discardableResult
    package func addInstance(_ mesh: Int, _ material: Int, _ transform: float4x4,
                             mask: UInt32 = Scene.maskGeometry,
                             animation: ((Float) -> float4x4)? = nil) -> Int {
        instances.append(Instance(mesh: mesh, material: material, mask: mask,
                                  transform: transform, prevTransform: transform, animation: animation,
                                  normalMatrix: transform.inverse.transpose))
        return instances.count - 1
    }

    /// A moving sphere light (the original scenes' lights), drawn with `sphereMesh`.
    package func addLight(color: SIMD3<Float>, radius: Float, sphereMesh: Int, path: @escaping (Float) -> SIMD3<Float>) {
        addLight(.sphere(radius: radius), color: color, proxyMesh: sphereMesh) { LightPose(position: path($0)) }
    }


    /// Adds a light and, but for the sun, the emissive shape that shows it (maskLights: it never blocks light).
    /// The shape's radiance makes it look as bright as the light is: I / (pi r^2) for a sphere of intensity I,
    /// the radiance itself for a rect, 2 I / (pi r length) for a tube (a cylinder whose broadside intensity per unit
    /// length, radiance x 2r, is the 4 I / (pi length) the shaders give it).
    @discardableResult
    package func addLight(_ kind: LightKind, color: SIMD3<Float>, proxyMesh: Int? = nil, proxyEmission: SIMD3<Float>? = nil,
                  reach: Float = 0, motion: LightMotion = .animated, proxy: Bool = true, pose: @escaping (Float) -> LightPose) -> Int {
        var light = Light(kind: kind, color: color, pose: pose, motion: motion, order: lights.count)
        light.reach = reach
        var mesh = -1, emission = SIMD3<Float>(repeating: 0)
        if !proxy {
            // Nothing drawn where it is (the walker's flashlight, at the eye).
            lights.append(light)
            return lights.count - 1
        }
        switch kind {
        case .sphere(let r), .spot(let r, _, _):
            if proxyMesh == nil && lightSphereMesh < 0 { lightSphereMesh = addMesh(Scene.icosphere(subdivisions: 2), label: "ball") }
            mesh = proxyMesh ?? lightSphereMesh
            emission = color / (.pi * r * r)
        case .rect:
            if proxyMesh == nil && lightQuadMesh < 0 { lightQuadMesh = addMesh(Scene.quadMesh(), label: "quad") }
            mesh = proxyMesh ?? lightQuadMesh
            emission = color
        case .tube(let length, let r):
            if proxyMesh == nil && lightCapsuleMeshes[SIMD2(length, r)] == nil {
                lightCapsuleMeshes[SIMD2(length, r)] = addMesh(Scene.capsuleMesh(halfLength: length / 2, radius: r))
            }
            mesh = proxyMesh ?? lightCapsuleMeshes[SIMD2(length, r)]!
            emission = 2 * color / (.pi * r * length)
        case .sun, .mesh:
            break
        }
        if mesh >= 0 {
            emission = proxyEmission ?? emission   // (a rect over a room's panels: theirs, brighter than its own)
            light.proxyMaterial = addMaterial(albedo: .zero, emission: emission)
            light.proxyEmission = emission
            light.proxyInstance = addInstance(mesh, light.proxyMaterial, matrix_identity_float4x4, mask: Scene.maskLights)
            instances[light.proxyInstance].poseAnimated = motion == .animated   // otherwise init's first update places it for good
        }
        lights.append(light)
        return lights.count - 1
    }
}
