import Foundation
import simd

/// The city scenes: a generated city (CityPlan lays it out, BuildingGenerator makes each lot's building) by day,
/// under the sun and the atmosphere's sky with a day cycle, or at night, lit by its windows, its street lamps and
/// the moon. Every building is its own, in its lot's frame: one mesh of several materials for everything opaque,
/// one for its glass (Scene.maskGlass) and at night one for its lit blinds and one for its rooms' lamps (a mesh
/// light each). The roads, sidewalks, lamp posts and trees are one mesh too, and at night each block's lamp heads
/// are one emissive mesh.
/// Seeded: the same settings build the same city.
extension Scene {
    func buildCity(_ city: CitySettings, seed: Int, night: Bool) {
        let start = CFAbsoluteTimeGetCurrent()
        let plan = CityPlan(city, seed: seed)

        // The generated textures, each kind's added the first time a material asks for it.
        let maps = city.textures ? ProceduralTextures.sources(SurfaceKind.allCases) : [:]
        var mapIndex: [SurfaceKind: SIMD4<UInt32>] = [:]
        func textures(_ kind: SurfaceKind) -> SIMD4<UInt32>? {
            if let index = mapIndex[kind] { return index }
            guard let m = maps[kind] else { return nil }
            let index = SIMD4(addTexture(m.base), m.roughness.map { addTexture($0) } ?? .max, addTexture(m.normal), .max)
            mapIndex[kind] = index
            return index
        }
        func gpuMaterial(_ m: SurfaceMaterial) -> GPUMaterial {
            var gpu = GPUMaterial(albedo: SIMD4(m.color, m.metallic), emission: SIMD4(m.emission, m.roughness),
                                  params: SIMD4(m.specular ? 1 : 0, 1, 0, 0))
            if let kind = m.surface, let index = textures(kind) { gpu.textures = index }
            return gpu
        }
        // Glass and lights are instances of their own (their mask, a mesh light each): those materials are shared.
        var shared: [SurfaceMaterial: Int] = [:]
        func sharedMaterial(_ m: SurfaceMaterial) -> Int {
            if let i = shared[m] { return i }
            let i = m.glass ? addGlassMaterial(tint: m.color) : addMaterial(gpuMaterial(m))
            shared[m] = i
            return i
        }
        var triangles = 0
        /// Adds meshes that belong together (a building's parts) at `transform`: everything opaque and unlit as one
        /// mesh of several materials, so a ray that meets the building walks one tree, not one per material.
        func add(_ parts: [(material: SurfaceMaterial, mesh: MeshBuilder)], at transform: float4x4 = matrix_identity_float4x4) {
            var merged = MeshBuilder(), offsets: [UInt8] = [], first = -1
            for (m, mesh) in parts where !mesh.isEmpty {
                triangles += mesh.triangleCount
                if m.glass || m.emission != .zero {
                    addInstance(addMesh(mesh.geometry, uvs: mesh.uvs), sharedMaterial(m), transform,
                                mask: m.glass ? Scene.maskGlass : Scene.maskGeometry)
                } else {
                    let index = addMaterial(gpuMaterial(m))
                    if first < 0 { first = index }
                    offsets += [UInt8](repeating: UInt8(index - first), count: mesh.triangleCount)
                    merged.append(mesh)
                }
            }
            if first >= 0 { addInstance(addMesh(merged.geometry, uvs: merged.uvs, materials: offsets), first, transform) }
        }
        func builder(_ m: SurfaceMaterial) -> MeshBuilder { MeshBuilder(uvScale: m.uvScale) }

        // The ground: the roads' asphalt under everything, open ground around the city.
        let asphalt = SurfaceMaterial(color: [0.1, 0.1, 0.11], surface: .asphalt)
        let paving = SurfaceMaterial(color: [0.52, 0.5, 0.47], surface: .paving)
        let earth = SurfaceMaterial(color: [0.3, 0.33, 0.2])
        let grass = SurfaceMaterial(color: [0.2, 0.34, 0.12])
        let e = plan.extent, far = CityPlan.margin
        var roads = builder(asphalt), around = builder(earth)
        roads.floor(x0: e.lo.x, x1: e.hi.x, z0: e.lo.y, z1: e.hi.y, y: 0)
        around.floor(x0: e.lo.x - far, x1: e.hi.x + far, z0: e.lo.y - far, z1: e.hi.y + far, y: -0.03)

        // The roads' centre lines: dashes a centimetre proud of the asphalt, none where two roads cross.
        let paint = SurfaceMaterial(color: [0.7, 0.7, 0.66])
        var lines = builder(paint)
        for street in plan.streets {
            let along = street.along, r = street.rect
            let length = along == 1 ? r.size.y : r.size.x, start = along == 1 ? r.lo.y : r.lo.x
            let middle = along == 1 ? r.center.x : r.center.y
            for k in 0..<Int(length / 8) {
                let at = start + 4 + Float(k) * 8
                let c = along == 1 ? SIMD2(middle, at) : SIMD2(at, middle)
                if plan.streets.contains(where: { $0.along != along && $0.rect.inset(-2).contains(CityPlan.Rect(lo: c, hi: c)) }) { continue }
                let half: SIMD2<Float> = along == 1 ? SIMD2(0.08, 1.5) : SIMD2(1.5, 0.08)
                lines.box([c.x - half.x, 0, c.y - half.y], [c.x + half.x, 0.012, c.y + half.y], faces: [.sides, .top])
            }
        }

        // The blocks: a raised sidewalk under each (its top is the courtyards' ground too), a lawn on a park.
        var sidewalks = builder(paving), lawns = builder(grass)
        for block in plan.blocks {
            let r = block.rect
            sidewalks.box([r.lo.x, 0, r.lo.y], [r.hi.x, 0.15, r.hi.y], faces: [.sides, .top])
            if block.park {
                let lawn = r.inset(CityPlan.sidewalk)
                lawns.box([lawn.lo.x, 0.15, lawn.lo.y], [lawn.hi.x, 0.22, lawn.hi.y], faces: [.sides, .top])
            }
        }

        // Street lamps (at night their heads are one emissive mesh per block) and trees.
        let iron = SurfaceMaterial(color: [0.07, 0.075, 0.08])
        let bark = SurfaceMaterial(color: [0.25, 0.18, 0.12])
        let leaves = SurfaceMaterial(color: [0.12, 0.26, 0.08])
        let lampLight = SurfaceMaterial(color: .zero, emission: SIMD3<Float>(1.0, 0.78, 0.5) * 140)
        var posts = builder(iron), heads = [MeshBuilder](repeating: MeshBuilder(), count: plan.blocks.count)
        for lamp in plan.lamps {
            let p = SIMD3<Float>(lamp.position.x, 0.15, lamp.position.y), out = SIMD3<Float>(lamp.toRoad.x, 0, lamp.toRoad.y)
            let side = SIMD3<Float>(-out.z, 0, out.x)
            posts.cylinder(p, radius: 0.08, topRadius: 0.05, height: 6.2, segments: 8)
            // An arm over the road with the head at its end; the head's underside is the light.
            let a = p + [0, 6.1, 0], b = a + out * 1.6
            posts.box(simd_min(a - side * 0.04, b + side * 0.04) - [0, 0.04, 0], simd_max(a - side * 0.04, b + side * 0.04) + [0, 0.04, 0])
            let c = b - out * 0.35
            let lo = simd_min(c - side * 0.14 - out * 0.3, c + side * 0.14 + out * 0.3), hi = simd_max(c - side * 0.14 - out * 0.3, c + side * 0.14 + out * 0.3)
            posts.box(lo - [0, 0.14, 0], hi - [0, 0.04, 0], faces: [.sides, .top])
            if night {
                heads[lamp.block].floor(x0: lo.x, x1: hi.x, z0: lo.z, z1: hi.z, y: lo.y - 0.14, up: false)
            } else {
                posts.floor(x0: lo.x, x1: hi.x, z0: lo.z, z1: hi.z, y: lo.y - 0.14, up: false)
            }
        }
        var trunks = builder(bark), crowns = builder(leaves)
        for tree in plan.trees {
            let p = SIMD3<Float>(tree.x, 0.15, tree.y), size = tree.z
            trunks.cylinder(p, radius: 0.16 * size, topRadius: 0.1 * size, height: 2.6 * size, segments: 6, cap: false)
            crowns.ball(p + [0, 3.9 * size, 0], radius: SIMD3(1.7, 1.9, 1.7) * size)
        }
        add([(asphalt, roads), (earth, around), (paint, lines), (paving, sidewalks), (grass, lawns), (iron, posts), (bark, trunks),
             (leaves, crowns)])
        for head in heads { add([(lampLight, head)]) }

        // The buildings: generated in parallel a batch at a time (each lot has its own seed, so the order they are
        // made in doesn't matter), then added in the lots' order.
        let specs = plan.lots.map { BuildingSpec(lot: $0, city: city, night: night) }
        let batch = 96
        var tallest: Float = 0, windows = 0, rooms = 0
        for first in stride(from: 0, to: specs.count, by: batch) {
            let count = min(batch, specs.count - first)
            var built = [Building?](repeating: nil, count: count)
            built.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: count) { i in out[i] = BuildingGenerator.generate(specs[first + i]) }
            }
            for (i, building) in built.enumerated() {
                guard let building else { continue }
                tallest = max(tallest, building.height)
                add(building.parts.map { ($0.material, $0.mesh) }, at: plan.lots[first + i].transform)
                windows += building.windows
                rooms += building.rooms
            }
        }

        if night {
            skyColor = [0.006, 0.009, 0.02]
            forcesLightTable = true
            // The moon.
            addLight(.sun(angularRadius: 0.0045), color: [0.035, 0.045, 0.07]) { _ in
                LightPose(position: .zero, direction: normalize([0.45, 0.7, 0.35]))
            }
        } else {
            // The sun: from the south-east in the morning (+x, +z) over the south to the west and back, 90 s each
            // way; t = 0 is mid-morning. It stays 12 degrees or more above the horizon (the exposure is fixed) and
            // never looks straight down a street. Its colour comes from the atmosphere.
            let half: Float = 90
            addLight(.sun(angularRadius: 0.27 * .pi / 180), color: [1, 1, 1]) { t in
                let phase = 0.5 - 0.5 * cos(.pi * (t / half + 0.3))   // 0 = morning, 1 = evening
                let elevation = (12 + 46 * sin(.pi * phase)) * Float.pi / 180, azimuth = (25 + 130 * phase) * Float.pi / 180
                return LightPose(position: .zero, direction: [cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth)])
            }
        }
        defaultCamera = plan.camera(.overview)

        print(String(format: "City: %d x %d blocks, %d buildings up to %.0f m, %d windows (%d with rooms), %d triangles in %d instances, "
                     + "%d materials, built in %.2f s", city.blocks, city.blocks, specs.count, tallest, windows, rooms, triangles,
                     instances.count, materials.count, CFAbsoluteTimeGetCurrent() - start))
    }
}
