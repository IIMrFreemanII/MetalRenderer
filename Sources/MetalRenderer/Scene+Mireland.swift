import Foundation
import simd

/// Mireland: a misty swamp at a low morning sun, made of the Mireland materials (MaterialLibrary+Mireland.swift), every
/// one of them procedural (baked by the renderer, edited live in the Material Designer):
/// - mud ground (Swamp Mud) sinking under black water with duckweed (Swamp Ground);
/// - on it, ragged patches: a path of loose dirt, dead grass on the rises, cracked crusts and puddles on the flats,
///   fallen leaves under the trees (Swamp Loose Dirt, Dead Grass, Mud Cracks, Mud Puddle, Leaves);
/// - bare trees: slim birches (Swamp Birch Bark) and thick, leaning, rooted old trunks (Swamp Gnarly Bark);
/// - clumps of grass and leafy stems along the water's edge, cut-out cards (Swamp Grass Blades, Swamp Plant);
/// - ground mist over the water. `SceneSettings.seed` places it all.
extension Scene {
    func buildMireland() {
        var rng = SplitMix64(seed: UInt64(settings.seed) &* 0x9E37_79B9_7F4A_7C15 ^ 0x3A1E)
        let catalog = MaterialCatalog.resolve(settings.materials)
        func material(_ name: String) -> Int { addProceduralMaterial(graph: name, catalog: catalog) }
        func add(_ m: (MeshGeometry, [SIMD2<Float>])) -> Int { addMesh(m.0, uvs: m.1) }
        // (The order is the displacement's: the ground first, then what stands on it.)
        let mud = material("Swamp Mud"), water = material("Swamp Ground"), dirt = material("Swamp Loose Dirt")
        let deadGrass = material("Swamp Dead Grass"), gnarly = material("Swamp Gnarly Bark"), birch = material("Swamp Birch Bark")
        let cracks = material("Swamp Mud Cracks"), puddle = material("Swamp Mud Puddle"), leaves = material("Swamp Leaves")
        let grass = material("Swamp Grass Blades"), plant = material("Swamp Plant")
        // Relief where it shows (the near old trunks); the ground, the patches lying on it and the far trees keep their
        // parallax.
        let farGnarly = material("Swamp Gnarly Bark"), farBirch = material("Swamp Birch Bark")
        undisplacedMaterials = [mud, dirt, deadGrass, birch, farGnarly, farBirch]

        // The ground: low, rolling, level where the camera stands; the water at the height half of it is under.
        let spot = SIMD2<Float>(0, 16)
        let terrain = Terrain(size: 72, cells: 144, seed: UInt64(settings.seed) &+ 0x5A3, relief: 0.8, flat: (spot, 2.5, 7))
        let level = terrain.heights.sorted()[terrain.heights.count * 50 / 100]
        let waterY = min(level, -0.15)
        var ground = terrain.mesh()
        ground.uvs = ground.uvs.map { $0 * terrain.size }   // a tile a metre
        addInstance(addMesh(ground), mud, matrix_identity_float4x4)
        addInstance(add(Scene.flatGrid(size: terrain.size, cells: 8, uvPerMetre: 1)), water, translate([0, waterY, 0]))
        func dry(_ x: Float, _ z: Float, above: Float = 0.12) -> Bool { terrain.height(x, z) > waterY + above }
        func random(in r: ClosedRange<Float>) -> SIMD2<Float> {
            let a = rng.range(0, 2 * .pi), d = sqrt(rng.range(r.lowerBound * r.lowerBound, r.upperBound * r.upperBound))
            return SIMD2(cos(a), sin(a)) * d
        }
        func near(_ p: SIMD2<Float>, _ list: [SIMD2<Float>], _ gap: Float) -> Bool { list.contains { simd_distance($0, p) < gap } }

        // A path of loose dirt from the camera down to the water.
        var at = spot + SIMD2(0.4, 1.5)
        for _ in 0..<12 {
            addInstance(add(patch(terrain, at, radius: rng.range(1.0, 1.5), lift: 0.03, uvPerMetre: 1, ragged: 0.25, rng: &rng)), dirt, matrix_identity_float4x4)
            at += SIMD2(rng.range(-0.5, 0.5), -1.6)
            if !dry(at.x, at.y, above: 0.02) { break }
        }
        // Dead grass on the rises, cracked crusts and puddles on the flats.
        // (A clump of a few overlapping ragged discs, each a little higher than the last: no seam shows where they cross.)
        for _ in 0..<30 {
            let p = random(in: 3...30)
            guard dry(p.x, p.y, above: 0.2) else { continue }
            for k in 0..<4 {
                let q = p + SIMD2(rng.range(-1.6, 1.6), rng.range(-1.6, 1.6))
                addInstance(add(patch(terrain, q, radius: rng.range(0.9, 1.8), lift: 0.03 + 0.004 * Float(k), uvPerMetre: 1, ragged: 0.35, rng: &rng)),
                            deadGrass, matrix_identity_float4x4)
            }
        }
        var decals = 0
        for _ in 0..<80 where decals < 16 {
            let p = random(in: 3...26), above = terrain.height(p.x, p.y) - waterY
            guard above > 0.04, above < 0.5, terrain.normal(p.x, p.y).y > 0.97 else { continue }
            let crust = rng.next() < 0.5
            addInstance(add(decal(terrain, p, size: crust ? rng.range(1.6, 2.6) : rng.range(1.2, 2.2), yaw: rng.range(0, 2 * .pi),
                                      lift: crust ? 0.035 : 0.025)), crust ? cracks : puddle, matrix_identity_float4x4)
            decals += 1
        }

        // Trees: old gnarly trunks, some standing in the water, and slim birches; fallen leaves round them.
        var trunks: [SIMD2<Float>] = []
        for k in 0..<30 {
            var p = random(in: 5...32)
            var tries = 0
            while (near(p, trunks, 3.5) || simd_distance(p, spot) < 5) && tries < 20 { p = random(in: 5...32); tries += 1 }
            trunks.append(p)
            let old = k % 3 == 0
            let y = terrain.height(p.x, p.y)
            let tree = old ? Scene.gnarlyTree(&rng) : Scene.birchTree(&rng)
            addInstance(addMesh(tree.geometry, uvs: tree.uvs), old ? gnarly : birch,
                        translate([p.x, y - 0.25, p.y]) * rotate(rng.range(0, 2 * .pi), [0, 1, 0]))
            if dry(p.x, p.y, above: 0.03) {
                addInstance(add(decal(terrain, p + SIMD2(rng.range(-0.6, 0.6), rng.range(-0.6, 0.6)), size: old ? 3.6 : 2.6,
                                          yaw: rng.range(0, 2 * .pi), lift: 0.04, tiles: 4)), leaves, matrix_identity_float4x4)
            }
        }

        // Far off in the mist, more trees: the swamp goes on past the ground's edge.
        for k in 0..<40 {
            let a = Float(k) / 40 * 2 * .pi + rng.range(-0.06, 0.06), d = rng.range(33, 46)
            let p = SIMD2(cos(a), sin(a)) * d
            let old = rng.next() < 0.35
            let tree = old ? Scene.gnarlyTree(&rng) : Scene.birchTree(&rng)
            addInstance(addMesh(tree.geometry, uvs: tree.uvs), old ? farGnarly : farBirch,
                        translate([p.x, waterY - 0.3, p.y]) * rotate(rng.range(0, 2 * .pi), [0, 1, 0]) * scale(rng.range(1.1, 1.6)))
        }
        let far = Scene.flatGrid(size: 140, cells: 4, uvPerMetre: 1)
        addInstance(add(far), water, translate([0, waterY - 0.02, 0]))

        // Grass clumps and leafy stems along the water's edge (crossed cards, cut out).
        let card = addMesh(Scene.crossedCards(), uvs: Scene.crossedCardUVs())
        var tufts = 0
        for _ in 0..<4000 where tufts < 420 {
            let p = random(in: 2...30), h = terrain.height(p.x, p.y) - waterY
            guard h > -0.15, h < 0.45, !near(p, trunks, 0.6) else { continue }
            let isPlant = rng.next() < 0.18
            let s = isPlant ? rng.range(0.7, 1.15) : rng.range(0.45, 0.9)
            addInstance(card, isPlant ? plant : grass,
                        translate([p.x, terrain.height(p.x, p.y) - 0.03, p.y]) * rotate(rng.range(0, 2 * .pi), [0, 1, 0]) * scale(s))
            tufts += 1
        }

        // A low morning sun through the mist, behind the trees; mist over the water.
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: SIMD3<Float>(1, 0.9, 0.75) * 2.2, motion: .constant) { _ in
            let e = Scene.degrees(13), a = Scene.degrees(-100)
            return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), cos(e) * sin(a)])
        }
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [36, 0.9, 36]), center: [0, waterY + 0.3, 0], density: 0.35,
                                    edge: 0.6, noise: 0.9, heightFalloff: 1.8))
        let eye = SIMD3<Float>(spot.x, terrain.height(spot.x, spot.y) + 1.65, spot.y)
        defaultCamera = Scene.camera(eye, yaw: 0.05, pitch: -0.05)
        focus = AABB(lo: [-36, waterY - 1, -36], hi: [36, waterY + 12, 36])
        print(String(format: "Mireland: water at %.2f m, %d tufts, %d trees, %d decals", waterY, tufts, trunks.count, decals))
    }

    // MARK: - Meshes

    /// A flat square in XZ, `cells` a side, its UVs `uvPerMetre` a metre.
    static func flatGrid(size: Float, cells: Int, uvPerMetre: Float) -> (MeshGeometry, [SIMD2<Float>]) {
        var p: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        let n = cells + 1, half = size / 2
        for j in 0...cells {
            for i in 0...cells {
                let x = Float(i) / Float(cells) * size - half, z = Float(j) / Float(cells) * size - half
                p.append([x, 0, z])
                uv.append(SIMD2(x, z) * uvPerMetre)
            }
        }
        for j in 0..<cells {
            for i in 0..<cells {
                let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
                idx += [a, d, b, a, c, d]
            }
        }
        return ((p, [SIMD3<Float>](repeating: [0, 1, 0], count: p.count), idx), uv)
    }

    /// A ragged disc lying on the terrain (a polar grid, its rim's radius varied by `ragged`), `lift` above it, its UVs
    /// in metres.
    private func patch(_ t: Terrain, _ c: SIMD2<Float>, radius: Float, lift: Float, uvPerMetre: Float, ragged: Float,
                       rng: inout SplitMix64) -> (MeshGeometry, [SIMD2<Float>]) {
        let rings = 6, sectors = 28
        let phase = (rng.range(0, 6.28), rng.range(0, 6.28))
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        func vertex(_ q: SIMD2<Float>) {
            p.append([q.x, t.height(q.x, q.y) + lift, q.y])
            n.append(t.normal(q.x, q.y))
            uv.append(q * uvPerMetre)
        }
        vertex(c)
        for r in 1...rings {
            for s in 0..<sectors {
                let a = Float(s) / Float(sectors) * 2 * .pi
                let rim = radius * (1 - ragged * (1 + sin(2 * a + phase.0) * 0.5 + sin(5 * a + phase.1) * 0.3 + sin(9 * a + phase.0 * 2) * 0.2) / 2)
                vertex(c + SIMD2(cos(a), sin(a)) * rim * Float(r) / Float(rings))
            }
        }
        for s in 0..<sectors { idx += [0, UInt32(1 + (s + 1) % sectors), UInt32(1 + s)] }
        for r in 1..<rings {
            let inner = 1 + (r - 1) * sectors, outer = 1 + r * sectors
            for s in 0..<sectors {
                let a = UInt32(inner + s), b = UInt32(inner + (s + 1) % sectors), c = UInt32(outer + s), d = UInt32(outer + (s + 1) % sectors)
                idx += [a, b, d, a, d, c]
            }
        }
        return ((p, n, idx), uv)
    }

    /// A square decal lying on the terrain, `size` across, turned by `yaw`, `lift` above it: its UVs 0...`tiles` across.
    private func decal(_ t: Terrain, _ c: SIMD2<Float>, size: Float, yaw: Float, lift: Float, tiles: Float = 1) -> (MeshGeometry, [SIMD2<Float>]) {
        let cells = 10
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        let u = SIMD2<Float>(cos(yaw), sin(yaw)), v = SIMD2<Float>(-sin(yaw), cos(yaw))
        for j in 0...cells {
            for i in 0...cells {
                let f = SIMD2(Float(i), Float(j)) / Float(cells)
                let q = c + u * (f.x - 0.5) * size + v * (f.y - 0.5) * size
                p.append([q.x, t.height(q.x, q.y) + lift, q.y])
                n.append(t.normal(q.x, q.y))
                uv.append(f * tiles)
            }
        }
        let k = cells + 1
        for j in 0..<cells {
            for i in 0..<cells {
                let a = UInt32(j * k + i), b = a + 1, c = a + UInt32(k), d = c + 1
                idx += [a, c, d, a, d, b]
            }
        }
        return ((p, n, idx), uv)
    }

    /// Two cards crossed at right angles, a metre square, standing on their bottom edge (UV V down, as an image).
    static func crossedCards() -> MeshGeometry {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        for (k, d) in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)].enumerated() {
            let normal = SIMD3<Float>(-d.z, 0, d.x), base = UInt32(4 * k)
            p += [-d * 0.5 + [0, 1, 0], -d * 0.5, d * 0.5, d * 0.5 + [0, 1, 0]]
            n += [normal, normal, normal, normal]
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (p, n, idx)
    }
    static func crossedCardUVs() -> [SIMD2<Float>] {
        let card: [SIMD2<Float>] = [[0, 0], [0, 1], [1, 1], [1, 0]]
        return card + card
    }

    // MARK: - Trees

    /// A tube along `nodes` (xyz, radius in w): `sides` round, closed at its end; UVs in metres (round it at its base's
    /// girth, along it by its length).
    static func tube(_ nodes: [SIMD4<Float>], sides: Int, into g: inout (p: [SIMD3<Float>], n: [SIMD3<Float>], uv: [SIMD2<Float>], idx: [UInt32])) {
        guard nodes.count >= 2 else { return }
        let girth = 2 * Float.pi * nodes[0].w
        var normal = simd_normalize(simd_cross(SIMD3(nodes[1].x - nodes[0].x, nodes[1].y - nodes[0].y, nodes[1].z - nodes[0].z), [0.3, 0, 1]))
        var along: Float = 0
        let first = UInt32(g.p.count)
        for (i, node) in nodes.enumerated() {
            let c = SIMD3(node.x, node.y, node.z)
            let next = i + 1 < nodes.count ? nodes[i + 1] : node, prev = i > 0 ? nodes[i - 1] : node
            let tangent = simd_normalize(SIMD3(next.x - prev.x, next.y - prev.y, next.z - prev.z))
            normal = simd_normalize(normal - tangent * simd_dot(normal, tangent))   // carried along (parallel transport)
            let binormal = simd_cross(tangent, normal)
            if i > 0 { along += simd_distance(c, SIMD3(prev.x, prev.y, prev.z)) }
            let r = i == nodes.count - 1 ? max(node.w * 0.15, 0.002) : node.w
            for s in 0...sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let out = normal * cos(a) + binormal * sin(a)
                g.p.append(c + out * r)
                g.n.append(out)
                g.uv.append([Float(s) / Float(sides) * girth, along])
            }
        }
        let row = UInt32(sides + 1)
        for i in 0..<UInt32(nodes.count - 1) {
            for s in 0..<UInt32(sides) {
                let a = first + i * row + s, b = a + 1, c = a + row, d = c + 1
                g.idx += [a, b, d, a, d, c]
            }
        }
    }

    /// A limb from `start` along `dir` (bending toward `bend`), `length` long, `radius` at its base, in `count` nodes,
    /// crooked by `wobble`.
    static func limb(_ start: SIMD3<Float>, _ dir: SIMD3<Float>, bend: SIMD3<Float>, length: Float, radius: Float, tip: Float, count: Int,
                     wobble: Float, rng: inout SplitMix64) -> [SIMD4<Float>] {
        var nodes: [SIMD4<Float>] = [], p = start, d = simd_normalize(dir)
        let step = length / Float(count - 1)
        for i in 0..<count {
            let f = Float(i) / Float(count - 1)
            nodes.append(SIMD4(p, radius * (1 - f) + radius * tip * f))
            d = simd_normalize(d + bend * (step / length) * 2 + SIMD3(rng.range(-1, 1), rng.range(-0.4, 0.4), rng.range(-1, 1)) * wobble)
            p += d * step
        }
        return nodes
    }

    typealias TreeMesh = (geometry: MeshGeometry, uvs: [SIMD2<Float>])

    /// An old swamp tree: thick, leaning, crooked, a few heavy limbs, roots splayed into the mud.
    static func gnarlyTree(_ rng: inout SplitMix64) -> TreeMesh {
        var g: (p: [SIMD3<Float>], n: [SIMD3<Float>], uv: [SIMD2<Float>], idx: [UInt32]) = ([], [], [], [])
        let r = rng.range(0.3, 0.5), h = rng.range(4.5, 7)
        let lean = SIMD3<Float>(rng.range(-0.35, 0.35), 1, rng.range(-0.35, 0.35))
        let trunk = limb([0, 0, 0], lean, bend: [0, 0.3, 0], length: h, radius: r, tip: 0.3, count: 14, wobble: 0.12, rng: &rng)
        tube(trunk, sides: 20, into: &g)
        for _ in 0..<Int(rng.range(3, 6)) {
            let at = trunk[Int(rng.range(6, 12))]
            let a = rng.range(0, 2 * .pi)
            let out = SIMD3<Float>(cos(a), rng.range(0.4, 1.0), sin(a))
            tube(limb(SIMD3(at.x, at.y, at.z), out, bend: [0, 0.4, 0], length: rng.range(1.5, 3.2), radius: at.w * 0.5, tip: 0.15, count: 8,
                      wobble: 0.2, rng: &rng), sides: 10, into: &g)
        }
        for k in 0..<Int(rng.range(4, 7)) {
            let a = Float(k) / 6 * 2 * .pi + rng.range(-0.3, 0.3)
            let out = SIMD3<Float>(cos(a), -0.35, sin(a))
            tube(limb([0, 0.55, 0], out, bend: [0, -0.5, 0], length: rng.range(1.2, 2), radius: r * 0.45, tip: 0.3, count: 6, wobble: 0.1, rng: &rng),
                 sides: 10, into: &g)
        }
        return ((g.p, g.n, g.idx), g.uv)
    }

    /// A slim birch, slightly bent, its few branches reaching up.
    static func birchTree(_ rng: inout SplitMix64) -> TreeMesh {
        var g: (p: [SIMD3<Float>], n: [SIMD3<Float>], uv: [SIMD2<Float>], idx: [UInt32]) = ([], [], [], [])
        let r = rng.range(0.1, 0.17), h = rng.range(7, 11)
        let trunk = limb([0, 0, 0], [rng.range(-0.1, 0.1), 1, rng.range(-0.1, 0.1)], bend: [rng.range(-0.1, 0.1), 0, rng.range(-0.1, 0.1)],
                         length: h, radius: r, tip: 0.12, count: 16, wobble: 0.04, rng: &rng)
        tube(trunk, sides: 14, into: &g)
        for _ in 0..<Int(rng.range(4, 8)) {
            let at = trunk[Int(rng.range(7, 14))]
            let a = rng.range(0, 2 * .pi)
            tube(limb(SIMD3(at.x, at.y, at.z), [cos(a), rng.range(0.8, 1.6), sin(a)], bend: [0, 0.3, 0], length: rng.range(1, 2.4),
                      radius: at.w * 0.45, tip: 0.1, count: 6, wobble: 0.15, rng: &rng), sides: 8, into: &g)
        }
        return ((g.p, g.n, g.idx), g.uv)
    }
}
