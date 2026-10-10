import Foundation
import simd

/// Puts generated buildings into a scene (the city's, the world's, the building workshop's): their materials (each
/// kind of surface's texture added once, glass and lights shared), their parts merged into one mesh of several
/// materials per building, and, if they have it, their interior: each storey's mesh (a tower's typical floors one
/// mesh placed many times) at its height.
///
/// A building with its interior drops its fill (the blinds, the dark and the room boxes behind its glass, its closed
/// doors: Building.Slot.isFill) and has instead what the interior has (and, for the walker, its colliders).
final class BuildingKit {
    unowned let scene: Scene
    /// The scene's doors, lights and lifts (made with the kit, shared by all its interiors).
    let controls: InteriorControls
    private var modelsAdded = 0

    /// The most interior lights a scene has, and loose pieces that are bodies.
    static let lightBudget = 420
    static let bodyBudget = 160
    private let maps: [SurfaceKind: (base: Scene.TextureSource, normal: Scene.TextureSource, roughness: Scene.TextureSource?)]
    private var mapIndex: [SurfaceKind: SIMD4<UInt32>] = [:]
    private var shared: [SurfaceMaterial: Int] = [:]
    /// Interior storeys' meshes made so far (by the storey's key and the building's style): one mesh for every copy.
    private var storeyMeshes: [String: (mesh: Int, first: Int)] = [:]
    private(set) var triangles = 0
    /// The interiors added: what the walker meets, in the scene's frame.
    private(set) var colliders: [Interior.Collider] = []

    init(_ scene: Scene, textures: Bool) {
        self.scene = scene
        maps = textures ? ProceduralTextures.sources(SurfaceKind.allCases) : [:]
        controls = scene.interiorControls ?? InteriorControls()
        scene.interiorControls = controls
    }

    /// ...with the scene's textures already added (the open world's: `index` by kind).
    init(_ scene: Scene, mapIndex index: [SurfaceKind: SIMD4<UInt32>]) {
        self.scene = scene
        maps = [:]
        mapIndex = index
        controls = scene.interiorControls ?? InteriorControls()
        scene.interiorControls = controls
    }

    /// Nothing of its interiors moves (the open world's scenes are still: their trees are groups): doors stand open,
    /// lifts at the ground floor, the loose furniture where it is, the rooms' lights as they are (no switches).
    var still = false

    /// The walker's flashlight: a spot light at the eye, along the view (the renderer moves it), off until switched.
    func addFlashlight() {
        let c = controls
        scene.addLight(.spot(radius: 0.02, inner: 0.18, outer: 0.45), color: SIMD3(1, 0.93, 0.82) * 3.5, motion: .animated, proxy: false) { [unowned c] _ in
            Scene.LightPose(position: c.flashlight.position, direction: c.flashlight.direction, scale: SIMD3(repeating: c.flashlight.on ? 1 : 0))
        }
    }

    /// The doorway's distance out of the shaft's inside to its wall's middle.
    private func plan(partition: Float) -> Float { 0.06 }

    /// A surface kind's texture, added the first time a material asks for it.
    private func textures(_ kind: SurfaceKind) -> SIMD4<UInt32>? {
        if let index = mapIndex[kind] { return index }
        guard let m = maps[kind] else { return nil }
        let index = SIMD4(scene.addTexture(m.base), m.roughness.map { scene.addTexture($0) } ?? .max, scene.addTexture(m.normal), .max)
        mapIndex[kind] = index
        return index
    }

    func gpuMaterial(_ m: SurfaceMaterial) -> GPUMaterial {
        var gpu = GPUMaterial(albedo: SIMD4(m.color, m.metallic), emission: SIMD4(m.emission, m.roughness),
                              params: SIMD4(m.specular ? 1 : 0, 1, 0, 0))
        if let kind = m.surface, let index = textures(kind) { gpu.textures = index }
        return gpu
    }

    /// Glass and lights are instances of their own (their mask, a mesh light each): those materials are shared.
    func sharedMaterial(_ m: SurfaceMaterial) -> Int {
        if let i = shared[m] { return i }
        let i = m.glass ? scene.addGlassMaterial(tint: m.color) : scene.addMaterial(gpuMaterial(m))
        shared[m] = i
        return i
    }

    /// Adds meshes that belong together (a building's parts) at `transform`: everything opaque and unlit as one mesh
    /// of several materials, so that a ray that meets the building walks one tree, not one per material; glass and
    /// lights each an instance of their own. Returns the instances.
    @discardableResult
    func add(_ parts: [(material: SurfaceMaterial, mesh: MeshBuilder)], at transform: float4x4 = matrix_identity_float4x4,
             name: String? = nil) -> [Int] {
        var merged = MeshBuilder(), offsets: [UInt8] = [], first = -1, made: [Int] = []
        for (k, (m, mesh)) in parts.enumerated() where !mesh.isEmpty {
            triangles += mesh.triangleCount
            if m.glass || m.emission != .zero {
                made.append(scene.addInstance(scene.addMesh(mesh.geometry, uvs: mesh.uvs, name: name.map { "\($0) part \(k)" }), sharedMaterial(m), transform,
                                              mask: m.glass ? Scene.maskGlass : Scene.maskGeometry))
            } else {
                let index = scene.addMaterial(gpuMaterial(m))
                if first < 0 { first = index }
                offsets += [UInt8](repeating: UInt8(index - first), count: mesh.triangleCount)
                merged.append(mesh)
            }
        }
        if first >= 0 {
            made.append(scene.addInstance(scene.addMesh(merged.geometry, uvs: merged.uvs, materials: offsets, name: name), first, transform))
        }
        return made
    }

    /// A building at `transform`: its shell, and its fill or (if it has one) its interior. `name`: what its meshes
    /// are made from, said in full (Scene.meshNames), if they are to be kept from scene to scene.
    func addBuilding(_ b: Building, at transform: float4x4, name: String? = nil) {
        add(b.parts.filter { !$0.slot.isFill }.map { ($0.material, $0.mesh) }, at: transform, name: name.map { "\($0) shell" })
        if let interior = b.interior {
            addInterior(interior, at: transform)
        } else {
            add(b.parts.filter { $0.slot.isFill }.map { ($0.material, $0.mesh) }, at: transform, name: name.map { "\($0) fill" })
        }
    }

    /// An interior at `transform`: each storey's mesh where its storeys are (its glass and its glowing parts
    /// instances of their own), its loose pieces, its lights, and its colliders.
    func addInterior(_ interior: Interior, at transform: float4x4) {
        var meshes: [Int: (mesh: Int, first: Int)] = [:]
        var apart: [Int: [(mesh: Int, material: Int, glass: Bool)]] = [:]
        for (index, storey) in interior.storeys.enumerated() {
            var merged = MeshBuilder(), offsets: [UInt8] = []
            var first = -1
            for part in storey.parts where !part.mesh.isEmpty && (part.material.glass || part.material.emission != .zero) {
                apart[index, default: []].append((scene.addMesh(part.mesh.geometry, uvs: part.mesh.uvs), sharedMaterial(part.material), part.material.glass))
            }
            for part in storey.parts where !part.mesh.isEmpty && !part.material.glass && part.material.emission == .zero {
                let m = scene.addMaterial(gpuMaterial(part.material))
                if first < 0 { first = m }
                // (More than 256 materials in a storey: the rest keep the last's.)
                offsets += [UInt8](repeating: UInt8(min(m - first, 255)), count: part.mesh.triangleCount)
                merged.append(part.mesh)
            }
            guard first >= 0 else { continue }
            meshes[index] = (scene.addMesh(merged.geometry, uvs: merged.uvs, materials: offsets), first)
        }
        for p in interior.placements {
            let at = transform * translate([0, p.y, 0])
            for a in apart[p.mesh] ?? [] { scene.addInstance(a.mesh, a.material, at, mask: a.glass ? Scene.maskGlass : Scene.maskGeometry) }
            guard let made = meshes[p.mesh] else { continue }
            triangles += interior.storeys[p.mesh].parts.reduce(0) { $0 + $1.mesh.triangleCount }
            scene.addInstance(made.mesh, made.first, at)
        }
        let c = controls
        // The loose pieces: bodies the physics moves (a box round each), drawn as their meshes (one multi-material mesh
        // for each kind of piece: the same chair is one mesh); the walls, floors and furniture near them are what they
        // meet.
        var propMeshes: [Int: (mesh: Int, first: Int)] = [:]
        var near: [(lo: SIMD3<Float>, hi: SIMD3<Float>)] = []
        for prop in interior.props {
            let boxes = prop.item.collisionBoxes
            guard !boxes.isEmpty else { continue }
            let lo = boxes.map(\.lo).reduce(SIMD3(repeating: .infinity), simd_min), hi = boxes.map(\.hi).reduce(SIMD3(repeating: -.infinity), simd_max)
            let centre = (lo + hi) / 2, half = (hi - lo) / 2
            var shifted = prop.item
            shifted.shift(-centre)
            var h = Hasher()
            for b in shifted.boxes { h.combine(b.role); for v in [b.lo, b.hi] { h.combine(v.x); h.combine(v.y); h.combine(v.z) } }
            for c in shifted.cylinders { h.combine(c.role); h.combine(c.base.x); h.combine(c.base.y); h.combine(c.base.z); h.combine(c.radius); h.combine(c.height) }
            for m in prop.materials { h.combine(m) }
            let key = h.finalize()
            let made = propMeshes[key] ?? {
                var out = MaterialMeshes()
                shifted.emit(into: &out, frame: matrix_identity_float4x4) { prop.materials[$0.rawValue] }
                var merged = MeshBuilder(), offsets: [UInt8] = [], first = -1
                for part in out.parts where !part.mesh.isEmpty {
                    let m = scene.addMaterial(gpuMaterial(part.material))
                    if first < 0 { first = m }
                    offsets += [UInt8](repeating: UInt8(min(m - first, 255)), count: part.mesh.triangleCount)
                    merged.append(part.mesh)
                }
                let made = (scene.addMesh(merged.geometry, uvs: merged.uvs, materials: offsets), first)
                propMeshes[key] = made
                return made
            }()
            let floor = interior.placements.first { $0.storey == prop.storey }?.y ?? 0
            let at = transform * translate([0, floor, 0]) * prop.frame * translate(centre)
            // (A tower's hundreds: the first are bodies, the rest stand still.)
            guard !still && c.props.count < BuildingKit.bodyBudget else { scene.addInstance(made.mesh, made.first, at); continue }
            let body = scene.physics?.bodies.count ?? 0
            scene.physicsFromInstall = true
            scene.addMeshBody(made.mesh, made.first, at, halfExtents: half, mass: prop.item.mass)
            c.props.append(InteriorControls.Prop(body: body, half: half))
            let p = SIMD3(at.columns.3.x, at.columns.3.y, at.columns.3.z)
            near.append((p - SIMD3(2, 1, 2), p + SIMD3(2, 2.5, 2)))
        }
        if !near.isEmpty {
            // What they can meet: the interior's boxes near them (not all of a tower's), and the ground.
            for col in interior.colliders {
                let a = transform * SIMD4(col.lo, 1), b = transform * SIMD4(col.hi, 1)
                let lo = simd_min(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)), hi = simd_max(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))
                if near.contains(where: { all($0.lo .< hi) && all($0.hi .> lo) }) { scene.addStaticBox(lo, hi) }
            }
        }
        // The glTF props, fitted where their generated pieces would stand (a few dozen at most: each is a model added).
        for model in interior.models.prefix(max(48 - modelsAdded, 0)) {
            guard let fit = PropLibrary.shared.fit(model.entry, into: model.size), let m = PropLibrary.shared.model(model.entry) else { continue }
            let floor = interior.placements.first { $0.storey == model.storey }?.y ?? 0
            scene.addModel(m.model, url: m.url, transform: transform * translate([0, floor, 0]) * model.frame * fit)
            modelsAdded += 1
        }
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { let q = transform * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
        func world2(_ v: SIMD2<Float>) -> SIMD2<Float> { let q = transform * SIMD4(v.x, 0, v.y, 0); return SIMD2(q.x, q.z) }
        // Its lights, each switched by its room's switch (InteriorControls.lights): at most a few hundred (the rest of
        // a tower's floors stay dark).
        var byRoom: [SIMD2<Int>: [Int]] = [:]
        for l in interior.lights.filter({ interior.night || $0.on }).prefix(max(BuildingKit.lightBudget - c.lights.count, 0)) {
            let index = c.lights.count
            c.lights.append(l.on ? 1 : 0)
            byRoom[SIMD2(l.storey, l.room), default: []].append(index)
            let t4 = transform * SIMD4(1, 0, 0, 0)
            let position = world(l.position), tangent = SIMD3(t4.x, t4.y, t4.z)
            if still {
                // (The open world's: on once the sun is down, as its windows are.)
                guard l.on else { continue }
                scene.addLight(.rect(width: l.size.x, height: l.size.y), color: l.color, motion: .scaleOnly) { [weak scene] _ in
                    let night = scene?.heavens.map { $0.sunElevation < -0.035 } ?? true
                    return Scene.LightPose(position: position, direction: [0, -1, 0], tangent: tangent, scale: SIMD3(repeating: night ? 1 : 0))
                }
                continue
            }
            scene.addLight(.rect(width: l.size.x, height: l.size.y), color: l.color, motion: .scaleOnly) { [unowned c] _ in
                Scene.LightPose(position: position, direction: [0, -1, 0], tangent: tangent, scale: SIMD3(repeating: c.lights[index]))
            }
        }
        for w in interior.switches where !still {
            guard let lights = byRoom[SIMD2(w.storey, w.room)] else { continue }
            let n4 = transform * SIMD4(w.normal, 0)
            c.switches.append(InteriorControls.Switch(position: world(w.position), normal: SIMD3(n4.x, n4.y, n4.z), lights: lights,
                                                      on: lights.contains { c.lights[$0] > 0 }))
        }
        // Its doors' leaves: a mesh for each size and kind, an instance each, turned about its hinge as the door opens.
        var leaves: [SIMD4<Float>: [(mesh: Int, material: Int, glass: Bool)]] = [:]
        for d in interior.doors {
            let key = SIMD4(d.width, d.height, d.glazed ? 1 : 0, d.color.x + d.color.y * 7 + d.color.z * 49)
            let parts = leaves[key] ?? {
                var out = MaterialMeshes()
                let wood = SurfaceMaterial(color: d.color, roughness: 0.5, specular: true)
                let t: Float = 0.04
                if d.glazed {
                    out[wood].box([0, 0, -t / 2], [0.08, d.height, t / 2])
                    out[wood].box([d.width - 0.08, 0, -t / 2], [d.width, d.height, t / 2])
                    out[wood].box([0.08, 0, -t / 2], [d.width - 0.08, 0.12, t / 2])
                    out[wood].box([0.08, d.height - 0.08, -t / 2], [d.width - 0.08, d.height, t / 2])
                    out[FurnishPalette.glass].wall(x0: 0.08, x1: d.width - 0.08, y0: 0.12, y1: d.height - 0.08)
                } else {
                    out[wood].box([0, 0, -t / 2], [d.width, d.height, t / 2])
                }
                // The handles, either side, at the far edge.
                out[FurnishPalette.chrome].box([d.width - 0.16, 1.0, t / 2], [d.width - 0.06, 1.03, t / 2 + 0.05])
                out[FurnishPalette.chrome].box([d.width - 0.16, 1.0, -t / 2 - 0.05], [d.width - 0.06, 1.03, -t / 2])
                let made = out.parts.filter { !$0.mesh.isEmpty }.map { part -> (mesh: Int, material: Int, glass: Bool) in
                    (scene.addMesh(part.mesh.geometry, uvs: part.mesh.uvs), part.material.glass ? sharedMaterial(part.material) : scene.addMaterial(gpuMaterial(part.material)),
                     part.material.glass)
                }
                leaves[key] = made
                return made
            }()
            let door = InteriorControls.Door(hinge: world(d.hinge), along: normalize(world2(d.along)), turn: d.turn * (simd_determinant(transform) < 0 ? -1 : 1),
                                             width: d.width, height: d.height, open: still || d.open ? 1 : 0, target: still || d.open ? 1 : 0)
            if still {
                for p in parts { scene.addInstance(p.mesh, p.material, door.frame, mask: p.glass ? Scene.maskGlass : Scene.maskGeometry) }
                continue
            }
            let index = c.doors.count
            c.doors.append(door)
            for p in parts {
                scene.addInstance(p.mesh, p.material, c.doors[index].frame, mask: p.glass ? Scene.maskGlass : Scene.maskGeometry) { [unowned c] _ in
                    c.doors[index].frame
                }
            }
        }
        // Its lifts: the cab (riding its shaft), each landing's door (sliding aside while the cab stands there).
        for shaft in interior.lifts {
            let a = world(SIMD3(shaft.shaft.lo.x, 0, shaft.shaft.lo.y)), b = world(SIMD3(shaft.shaft.hi.x, 0, shaft.shaft.hi.y))
            let inside = CityPlan.Rect(lo: SIMD2(min(a.x, b.x), min(a.z, b.z)), hi: SIMD2(max(a.x, b.x), max(a.z, b.z)))
            var lift = Lift(shaft: inside, floors: shaft.floors.map { $0 + transform.columns.3.y }, doorSide: normalize(world2(shaft.doorSide)))
            let index = still ? -1 : c.lifts.count
            // The call buttons: beside each landing door, outside.
            let mid = inside.center + lift.doorSide * ((lift.doorSide.x != 0 ? inside.size.x : inside.size.y) / 2 + 0.12)
            let across = SIMD2(-lift.doorSide.y, lift.doorSide.x)
            for (k, f) in lift.floors.enumerated() {
                let p = mid + across * (lift.doorWidth / 2 + 0.25)
                lift.buttons.append(Lift.Button(position: SIMD3(p.x, f + 1.1, p.y), floor: k))
            }
            if !still { c.lifts.append(lift) }
            // The cab: a floor, three walls, a ceiling with a light panel; its own frame at the shaft's foot.
            var cab = MaterialMeshes()
            let cr = lift.cab, size = cr.size
            let steel = SurfaceMaterial(color: [0.6, 0.61, 0.63], roughness: 0.3, metallic: 0.9, specular: true)
            cab[FurnishPalette.stone].box([0, -0.15, 0], [size.x, 0, size.y])
            let open = lift.doorSide
            if open.x <= 0.5 { cab[steel].box([size.x - 0.05, 0, 0], [size.x, 2.3, size.y]) }
            if open.x >= -0.5 { cab[steel].box([0, 0, 0], [0.05, 2.3, size.y]) }
            if open.y <= 0.5 { cab[steel].box([0, 0, size.y - 0.05], [size.x, 2.3, size.y]) }
            if open.y >= -0.5 { cab[steel].box([0, 0, 0], [size.x, 2.3, 0.05]) }
            cab[steel].box([0, 2.3, 0], [size.x, 2.36, size.y])
            cab[SurfaceMaterial(color: .zero, emission: [6, 6, 5.6])].floor(x0: size.x * 0.3, x1: size.x * 0.7, z0: size.y * 0.3, z1: size.y * 0.7, y: 2.29, up: false)
            let base = SIMD3(cr.lo.x, 0, cr.lo.y)
            for part in cab.parts where !part.mesh.isEmpty {
                let material = part.material.emission != .zero ? sharedMaterial(part.material) : scene.addMaterial(gpuMaterial(part.material))
                let mesh = scene.addMesh(part.mesh.geometry, uvs: part.mesh.uvs)
                if still { scene.addInstance(mesh, material, translate(base + [0, lift.y, 0])); continue }
                scene.addInstance(mesh, material, translate(base + [0, lift.y, 0])) { [unowned c] _ in
                    translate(base + [0, c.lifts[index].y, 0])
                }
            }
            // The landing doors: two steel panels in each storey's doorway, parting to either side into the shaft's
            // wall (a lift at the core's corner has no more wall than that beside its door).
            let half = lift.doorWidth / 2
            let panel = scene.addMesh({ var m = MeshBuilder(); m.box([-half / 2, 0, -0.02], [half / 2, 2.1, 0.02]); return m.geometry }())
            let steelIndex = scene.addMaterial(gpuMaterial(steel))
            let doorMid = inside.center + lift.doorSide * ((lift.doorSide.x != 0 ? inside.size.x : inside.size.y) / 2 + plan(partition: 0))
            for (k, f) in lift.floors.enumerated() {
                let along = SIMD3(across.x, 0, across.y)
                let rotation = float4x4(columns: (SIMD4(along, 0), SIMD4(0, 1, 0, 0), SIMD4(lift.doorSide.x, 0, lift.doorSide.y, 0), SIMD4(0, 0, 0, 1)))
                let at = SIMD3(doorMid.x, f, doorMid.y)
                for side: Float in [-1, 1] {
                    let shut = at + along * side * half / 2
                    if still { scene.addInstance(panel, steelIndex, translate(shut + along * side * (k == 0 ? half * 0.96 : 0)) * rotation); continue }
                    scene.addInstance(panel, steelIndex, translate(shut) * rotation) { [unowned c] _ in
                        translate(shut + along * side * c.lifts[index].landing(k) * half * 0.96) * rotation
                    }
                }
            }
        }
        for c in interior.colliders {
            let a = transform * SIMD4(c.lo, 1), b = transform * SIMD4(c.hi, 1)
            colliders.append(Interior.Collider(lo: simd_min(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)),
                                               hi: simd_max(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)), kind: c.kind))
        }
    }
}
