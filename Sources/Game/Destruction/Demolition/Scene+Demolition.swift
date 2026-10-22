import EngineCore
import Foundation
import simd
import MetalRenderer

/// The demolition scene: a generated office (DemolitionBlueprint: the building generator's plan, every wall, slab,
/// column, flight and desk of it a fractured object) on an empty lot under the afternoon sun, to wreck with a machine
/// gun, rockets and TNT, flying round it or walking through it (Renderer+Demolition.swift; the physics' side is
/// Physics+Demolition.swift). Drawn in the solid look, which tells its materials apart.
///
/// Each storey stands on the one under it, block on block, with nothing welding them: what loses what held it up comes
/// down whole and breaks where it lands. The pieces of one block are welded (holes stay holes); the ground holds the
/// ground floor's. Everything starts asleep, and stays so until something reaches it.
extension Scene {
    func buildDemolition(_ settings: DemolitionSettings) {
        let kit = Kit(self)
        let world = physicsWorld()
        world.fractureTuning.x = settings.fade ? 6 : 1e9
        world.idleWelds = true
        let blueprint = DemolitionBlueprint(settings)

        // Materials: each look's outside, then its broken inside (flagged as a cut face for the solid look).
        let ground = addPBRMaterial(baseColor: [0.29, 0.31, 0.28], metallic: 0, roughness: 0.9)
        var outside: [Int] = [], inside: [Int] = []
        for look in DemolitionBlueprint.Look.allCases {
            let (colour, cut, metallic, roughness) = Scene.demolitionColours(look)
            if look == .glass {
                outside.append(addGlassMaterial(tint: colour))
                inside.append(addGlassMaterial(tint: cut))
            } else {
                outside.append(addPBRMaterial(baseColor: colour, metallic: metallic, roughness: roughness))
                inside.append(addPBRMaterial(baseColor: cut, metallic: 0, roughness: 0.95))
            }
            markCutFace(inside[inside.count - 1])
        }
        let tntRed = addPBRMaterial(baseColor: [0.72, 0.08, 0.06], metallic: 0, roughness: 0.6)
        let flame = addMaterial(albedo: [1, 0.55, 0.15], emission: [12, 4.5, 1.0])
        let exhaust = addMaterial(albedo: [1, 0.5, 0.1], emission: [6, 2.2, 0.5])
        let iron = addPBRMaterial(baseColor: [0.12, 0.12, 0.13], metallic: 0.8, roughness: 0.5)

        section("Lot")
        addInstance(kit.quad, ground, scale([160, 1, 160]))
        addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)

        var rig = DemolitionRig()
        rig.counts = [Int](repeating: 0, count: DemolitionBlueprint.Kind.allCases.count)
        rig.floors = blueprint.floors
        var storeyOpen = -1
        for (k, block) in blueprint.blocks.enumerated() {
            if block.storey != storeyOpen {
                storeyOpen = block.storey
                section("Office/Floor \(block.storey + 1)")
            }
            rig.counts[block.kind.rawValue] += 1
            let (recipe, strength) = Scene.demolitionRecipe(block, seed: UInt64(settings.seed) &* 7919 &+ UInt64(k), settings: settings)
            let anchor: FractureAnchor = block.storey == 0 && block.kind != .furniture && block.kind != .glass ? .ground(0) : .none
            let f = addFractured("\(block.kind.title) \(k)", shape: block.shape, recipe: recipe, transform: block.transform,
                                 material: outside[block.look.rawValue], interior: inside[block.look.rawValue], anchor: anchor,
                                 mask: block.kind == .glass ? Scene.maskGlass : Scene.maskGeometry,
                                 toughness: settings.toughness, strength: settings.strength * strength)
            world.startAsleep(f.firstBody)
            rig.objects.append(f)
        }

        weldNeighbours(blueprint, rig.objects, settings: settings)

        section("Tools")
        // The rockets: balls that go off where they meet something (disabled until fired).
        let rocketShape = addSDFShape(SDFShape(.sphere(radius: DemolitionRig.rocketRadius)))
        for _ in 0..<DemolitionRig.rocketPool {
            let b = world.bodies.count
            addBody(sdf: rocketShape, exhaust, translate([0, -50, 0]), density: 600, friction: 0.4, restitution: 0.1)
            world.addRocket(b)
            rig.rockets.append(b)
        }
        // The walker: a capsule no ray sees (the camera is in it), off until walking.
        let w = world.bodies.count
        let capsule = SDFShape(.capsule(halfLength: PhysicsWorld.walkerHalf, radius: PhysicsWorld.walkerRadius))
        let volume = Float.pi * PhysicsWorld.walkerRadius * PhysicsWorld.walkerRadius * (2 * PhysicsWorld.walkerHalf + 4 / 3 * PhysicsWorld.walkerRadius)
        addBody(sdf: addSDFShape(capsule), iron, translate([0, -40, 0]), density: 80 / volume, friction: 0, restitution: 0, mask: 0)
        world.addWalker(w)
        rig.walker = w
        rig.spawn = SIMD3(0, PhysicsWorld.walkerHalf + PhysicsWorld.walkerRadius + 0.02, blueprint.outline.hi.y + 2.5)
        rig.centre = SIMD3((blueprint.outline.lo.x + blueprint.outline.hi.x) / 2, 0, (blueprint.outline.lo.y + blueprint.outline.hi.y) / 2)
        // TNT charges and fireballs: drawn where the tools put them, hidden (tiny, under the lot) while unused.
        let hidden = translate([0, -60, 0]) * scale(PhysicsWorld.hiddenScale)
        for _ in 0..<DemolitionRig.chargePool { rig.charges.append(kit.box(.zero, [0.22, 0.14, 0.12], tntRed)) }
        for k in rig.charges { setTransform(k, hidden) }
        let ball = addSDFShape(SDFShape(.sphere(radius: 1)))
        for _ in 0..<DemolitionRig.fireballPool { rig.fireballs.append(addInstance(sdf: ball, flame, hidden, mask: Scene.maskEffect)) }
        for k in rig.charges + rig.fireballs { editInstance(k) { $0.simulated = true } }

        if settings.dust {
            var interiors: [FractureMaterial: Int] = [:]
            for look in DemolitionBlueprint.Look.allCases where interiors[look.material] == nil { interiors[look.material] = inside[look.rawValue] }
            rig.dustProxies = addDestructionDust(kit, interiors: interiors)
        }
        if settings.demo { demolitionDemo(blueprint, rig) }
        world.keepBuiltCommands()
        demolitionRig = rig

        // The afternoon sun from the front left, a blue sky.
        section("Sun")
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1.0, 0.95, 0.88]) { _ in
            let e = Scene.degrees(38), az: Float = -0.55
            return LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)], scale: SIMD3(repeating: 1.5))
        }
        skyAnimation = { _ in SIMD3<Float>(0.3, 0.45, 0.8) * 0.24 }
        defaultCamera = Scene.camera([0, 11, blueprint.outline.hi.y + 36], pitch: -0.2)
    }

    /// Whether a block is welded to the blocks it touches (all of the structure: slabs, walls, columns, glass, the
    /// stair), and how much of its material's strength its welds hold (the furniture stands loose).
    static func welded(_ kind: DemolitionBlueprint.Kind) -> Bool { kind != .furniture }

    /// Each block of the structure welded to the blocks it touches (a millimetre apart, face to face), at every level
    /// of both: wherever two of their nodes' outer faces meet, a weld of the faces' shared rectangle, so that what is
    /// left of a broken panel stays held to the panel beside it, as a slab's or a wall's own pieces are (Chaos's
    /// connection graph across objects). The slab is one plate on its supports, not panels each on its own.
    func weldNeighbours(_ blueprint: DemolitionBlueprint, _ objects: [Fractured], settings: DemolitionSettings) {
        let world = physicsWorld()
        let blocks = blueprint.blocks
        /// Object `k`'s nodes' outer faces on its side along axis `axis` (+1 / -1): node, and the face's rectangle in
        /// the other two axes (world).
        func faces(_ k: Int, _ axis: Int, _ sign: Float) -> [(node: Int, lo: SIMD2<Float>, hi: SIMD2<Float>)] {
            let centre = blocks[k].transform.columns.3, o = SIMD3(centre.x, centre.y, centre.z)
            let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
            var out: [(node: Int, lo: SIMD2<Float>, hi: SIMD2<Float>)] = []
            for (n, node) in objects[k].tree.nodes.enumerated() {
                for f in node.cell.faces where f.tag == ConvexCell.outer && f.plane[axis] * sign > 0.999 {
                    var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
                    for p in f.polygon {
                        let w = p + o
                        lo = simd_min(lo, SIMD2(w[u], w[v]))
                        hi = simd_max(hi, SIMD2(w[u], w[v]))
                    }
                    out.append((n, lo, hi))
                }
            }
            return out
        }
        var made = 0
        for i in blocks.indices where Scene.welded(blocks[i].kind) {
            for j in (i + 1)..<blocks.count where abs(blocks[j].storey - blocks[i].storey) <= 1 && Scene.welded(blocks[j].kind) {
                let a = blocks[i], b = blocks[j]
                // Face to face along one axis, overlapping along the other two.
                for axis in 0..<3 {
                    let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
                    guard min(a.hi[u], b.hi[u]) - max(a.lo[u], b.lo[u]) > 0.02, min(a.hi[v], b.hi[v]) - max(a.lo[v], b.lo[v]) > 0.02 else { continue }
                    let sign: Float
                    if abs(b.lo[axis] - a.hi[axis]) < 0.003 { sign = 1 } else if abs(a.lo[axis] - b.hi[axis]) < 0.003 { sign = -1 } else { continue }
                    let plane = sign > 0 ? (a.hi[axis] + b.lo[axis]) / 2 : (a.lo[axis] + b.hi[axis]) / 2
                    let fa = faces(i, axis, sign), fb = faces(j, axis, -sign)
                    let sigma = min(Scene.demolitionRecipe(a, seed: 0, settings: settings).1 * a.look.material.strength,
                                    Scene.demolitionRecipe(b, seed: 0, settings: settings).1 * b.look.material.strength) * settings.strength
                    for x in fa {
                        for y in fb {
                            let lo = simd_max(x.lo, y.lo), hi = simd_min(x.hi, y.hi)
                            guard hi.x - lo.x > 0.01, hi.y - lo.y > 0.01 else { continue }
                            var centre = SIMD3<Float>()
                            centre[axis] = plane
                            centre[u] = (lo.x + hi.x) / 2
                            centre[v] = (lo.y + hi.y) / 2
                            world.addWeld(objects[i].firstBody + x.node, objects[j].firstBody + y.node, centre: centre,
                                          area: (hi.x - lo.x) * (hi.y - lo.y), sigma: sigma)
                            made += 1
                        }
                    }
                }
            }
        }
        _ = made
    }

    /// The scripted demo (DemolitionSettings.demo: the benchmark's and the tests'): a rocket into the third floor's
    /// front at 2 s, TNT in the ground floor at 4 s, a hole blown in the fourth floor at 6 s and the walker put beside
    /// it at 6.5 s walking into it, a burst from the machine gun at a second-floor pier from 7 s, TNT at the ground
    /// floor's corners at 10 s.
    func demolitionDemo(_ b: DemolitionBlueprint, _ rig: DemolitionRig) {
        let world = physicsWorld()
        let step = { (t: Float) in Int(t / PhysicsWorld.stepLength) }
        let front = b.outline.hi.y, f = b.floors
        // The rocket.
        let from = SIMD3<Float>(-4, 6, front + 22), target = SIMD3<Float>(0, f[2] + 1.6, front)
        let (dir, speed) = Scene.aim(from: from, at: target, speed: 28, gravity: world.gravity.y)
        world.command(.rocket, body: rig.rockets[0], origin: from, radius: 2.5, direction: dir, magnitude: speed, at: step(2))
        // TNT inside.
        world.command(.blast, origin: [4, 1, 2], radius: 1.8, magnitude: 18, at: step(4), steps: 4)
        // A hole in the fourth floor, and the walker into it.
        let hole = SIMD3<Float>(-6, f[3] - 0.1, -3)
        world.command(.blast, origin: hole, radius: DemolitionPlayer.tntRadius, magnitude: DemolitionPlayer.tntPush, at: step(6), steps: 4)
        world.command(.drive, body: Int(DemolitionState.Walker.enableFlag | DemolitionState.Walker.placeFlag),
                      origin: [hole.x, f[3] + PhysicsWorld.walkerHalf + PhysicsWorld.walkerRadius + 0.05, hole.z + 3.2], at: step(6.5))
        world.command(.drive, direction: [0, 0, -2.5], at: step(7))
        // A burst at a pier of the second floor's front, from the lot.
        if let k = b.blocks.indices.first(where: { b.blocks[$0].kind == .pier && b.blocks[$0].storey == 1 && b.blocks[$0].hi.z > front - 0.01
                                                    && b.blocks[$0].lo.x > -6 }) {
            let p = b.blocks[k]
            for n in 0..<12 {
                let at = SIMD3((p.lo.x + p.hi.x) / 2 + Float(n % 3 - 1) * 0.2, (p.lo.y + p.hi.y) / 2 + Float(n / 3 - 2) * 0.25, p.hi.z)
                world.command(.hit, body: rig.objects[k].firstBody, origin: at, direction: [0, 0, -1], magnitude: 25, at: step(7 + Float(n) / 12))
            }
        }
        // The corners.
        for (x, z) in [(b.outline.lo.x, b.outline.lo.y), (b.outline.hi.x, b.outline.lo.y), (b.outline.lo.x, b.outline.hi.y), (b.outline.hi.x, b.outline.hi.y)] {
            world.command(.blast, origin: [x + (x < 0 ? 1 : -1), 1, z + (z < 0 ? 1 : -1)], radius: 2.2, magnitude: 18, at: step(10), steps: 4)
        }
    }

    /// A look's colour outside and broken (linear), its metalness and roughness: told apart at a glance in the solid
    /// look as well as the full one.
    static func demolitionColours(_ look: DemolitionBlueprint.Look) -> (SIMD3<Float>, SIMD3<Float>, Float, Float) {
        switch look {
        case .facade: return ([0.58, 0.54, 0.47], [0.66, 0.6, 0.5], 0, 0.85)
        case .slab: return ([0.4, 0.43, 0.48], [0.55, 0.56, 0.57], 0, 0.9)
        case .column: return ([0.5, 0.46, 0.55], [0.6, 0.57, 0.6], 0, 0.85)
        case .plaster: return ([0.82, 0.8, 0.74], [0.9, 0.86, 0.76], 0, 0.9)
        case .glass: return ([0.72, 0.9, 0.9], [0.65, 0.85, 0.85], 0, 0)
        case .stair: return ([0.62, 0.5, 0.36], [0.7, 0.6, 0.46], 0, 0.8)
        case .wood: return ([0.52, 0.32, 0.16], [0.78, 0.6, 0.38], 0, 0.6)
        case .metal: return ([0.38, 0.46, 0.56], [0.55, 0.58, 0.6], 0.6, 0.4)
        case .fabric: return ([0.22, 0.38, 0.6], [0.5, 0.55, 0.62], 0, 0.95)
        case .plastic: return ([0.75, 0.66, 0.24], [0.8, 0.74, 0.5], 0, 0.5)
        }
    }

    /// How a block breaks: its kind's pieces (scaled by the Pieces setting) and how much its welds hold of its
    /// material's (`strength`, a share).
    static func demolitionRecipe(_ block: DemolitionBlueprint.Block, seed: UInt64, settings: DemolitionSettings)
        -> (FractureRecipe, Float) {
        var r = FractureRecipe.defaults(block.look.material)
        r.seed = seed
        let strength: Float
        switch block.kind {
        case .pier: r.counts = [4, 2]; strength = 0.15
        case .spandrel, .lintel: r.counts = [3, 2]; strength = 0.15
        case .glass: r.counts = [8]; strength = 1
        case .slab: r.counts = [6, 2]; strength = 0.3
        case .column: r.counts = [6, 2]; strength = 0.15
        case .partition: r.counts = [5, 2]; strength = 0.3
        case .doorHead: r.counts = [2]; strength = 0.3
        case .stair: r.counts = [5, 2]; strength = 0.3
        case .furniture: r.pattern = .voronoi; r.counts = [3]; strength = 1
        }
        if block.kind == .glass {
            // The radial cracks from the pane's middle (its own space).
            r.centre = .zero
        }
        return (r.scaled(settings.pieces), strength)
    }
}
