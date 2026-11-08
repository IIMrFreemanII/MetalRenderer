import EngineCore
import MetalRenderer
import simd

/// A small deterministic generator for the lab's random placements (the same scene at every load).
private struct LabRng {
    var state: UInt32
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(state >> 8) / Float(1 << 24)
    }
}

extension Scene {
    /// How many lights booth 19 holds, and its grid (across, up, deep) of them.
    static func labGridShape(_ variant: LightLabVariant) -> (count: Int, grid: SIMD3<Int>) {
        switch variant {
        case .normal: (16, [4, 2, 2])
        case .table: (400, [10, 4, 10])
        case .dense: (16384, [32, 16, 32])
        case .overLimit: (70000, [50, 28, 50])
        case .threeSuns: (16, [4, 2, 2])
        }
    }

    /// Booth 19, light grid: small sphere lights on a regular 3D grid in the upper volume, 16 / 400 / 16384 / 70000 by
    /// variant (culling, the tree, the fallback). The total intensity is the same at any count. The `threeSuns` variant keeps
    /// the normal 16. Above 400 lights no proxy is drawn (an instance and a material per light would be the load).
    func boothLightGrid(_ b: BoothFrame, _ lab: LightLabSettings) {
        let (count, grid) = Scene.labGridShape(lab.variant)
        let palette: [SIMD3<Float>] = [[1, 0.3, 0.3], [0.3, 1, 0.3], [0.4, 0.4, 1], [0.3, 0.9, 0.9], [1, 0.4, 0.9], [1, 0.9, 0.3]]
            .map { Scene.hue($0) }
        let total: Float = 8, each = total / Float(count), proxy = count <= 400
        // The grid fills x -1.8...1.8, y 1.9...2.8, z 0.6...3.8 (cell centres).
        let lo = SIMD3<Float>(-1.8, 1.9, 0.6), size = SIMD3<Float>(3.6, 0.9, 3.2)
        let step = size / SIMD3<Float>(grid)
        let origin = b.origin, right = b.right, inward = b.inward, half = b.size.z / 2
        lights.reserveCapacity(lights.count + count)
        var i = 0
        for iy in 0..<grid.y {
            let y = lo.y + (Float(iy) + 0.5) * step.y
            for iz in 0..<grid.z {
                let z = lo.z + (Float(iz) + 0.5) * step.z
                for ix in 0..<grid.x {
                    let x = lo.x + (Float(ix) + 0.5) * step.x
                    let position = origin + right * x + SIMD3(0, y, 0) + inward * (z - half)
                    let radius = 0.01 + 0.005 * Float((i * 7) % 5)
                    addLight(.sphere(radius: radius), color: palette[i % palette.count] * each, motion: .constant, proxy: proxy) { _ in
                        LightPose(position: position)
                    }
                    i += 1
                }
            }
        }
    }

    /// Booth 20, cluster: 136 lights (r 5 mm) in one 1 m cube at the booth's centre, more than a MegaLights tile holds (128).
    func boothCluster(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        let count = 136, total: Float = 3
        var rng = LabRng(state: 0x2F6E_2B1)
        for _ in 0..<count {
            let local = SIMD3<Float>(-0.5 + rng.next(), 1 + rng.next(), 1.5 + rng.next())
            let position = b.p(local.x, local.y, local.z)
            let tint = SIMD3<Float>(1, 0.95 + 0.05 * rng.next(), 0.88 + 0.12 * rng.next())
            addLight(.sphere(radius: 0.005), color: tint * (total / Float(count)), motion: .constant) { _ in LightPose(position: position) }
        }
        object("Objects") {
            labSlab(kit, b, [-1.5, 0, 1.7], [-0.9, 0.5, 2.3], grey)
            labSlab(kit, b, [1.0, 0, 1.5], [1.5, 1.2, 2.0], grey)
            labSlab(kit, b, [-0.3, 0, 3.2], [0.3, 0.6, 3.8], grey)
            kit.ball(b.p(1.2, 0.3, 3.0), 0.3, grey)
        }
    }

    /// Booth 21, movers: a fast light (2 rev/s, r 5 cm), a slow orbit, and a light passing back and forth behind a 0.4 m
    /// pillar (disocclusion). Motion off: each stands at its t = 0 pose, `.constant`; on: `.animated`.
    func boothMovers(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        object("Pillar") { labSlab(kit, b, [-0.2, 0, 2.0], [0.2, 2.5, 2.4], grey) }
        let poses: [(radius: Float, intensity: Float, pose: (Float) -> LightPose)] = [
            (0.05, 2, { t in
                let a = 2 * .pi * 2 * t
                return LightPose(position: b.p(-1.1 + 0.5 * cos(a), 1.4, 1.5 + 0.5 * sin(a)))
            }),
            (0.03, 2, { t in
                let a = 2 * .pi * 0.1 * t
                return LightPose(position: b.p(1.0 + 0.8 * cos(a), 1.6, 2.2 + 0.8 * sin(a)))
            }),
            (0.04, 2, { t in
                let a = 2 * .pi * t / 4
                return LightPose(position: b.p(1.6 * sin(a), 1.2, 3.0))
            }),
        ]
        for m in poses {
            if lab.motion {
                addLight(.sphere(radius: m.radius), color: SIMD3(repeating: m.intensity), motion: .animated, pose: m.pose)
            } else {
                let still = m.pose(0)
                addLight(.sphere(radius: m.radius), color: SIMD3(repeating: m.intensity), motion: .constant) { _ in still }
            }
        }
    }

    /// Booth 22, blinkers: on/off square waves at 2, 5 and 15 Hz, and a light cycling red, green, blue at 1 Hz. Motion off:
    /// all on at their t = 0 colours, `.constant`; on: `.scaleOnly` through `LightPose.scale`.
    func boothBlinkers(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        let xs: [Float] = [-1.5, -0.5, 0.5, 1.5]
        for (i, x) in xs.enumerated() {
            let position = b.p(x, 1.5, 2.0)
            let pose: (Float) -> LightPose
            switch i {
            case 3:
                pose = { t in
                    let phase = t - floor(t)
                    let scale: SIMD3<Float> = phase < 1.0 / 3 ? [1, 0, 0] : phase < 2.0 / 3 ? [0, 1, 0] : [0, 0, 1]
                    return LightPose(position: position, scale: scale)
                }
            default:
                let hz: Float = [2, 5, 15][i]
                pose = { t in
                    let phase = t * hz - floor(t * hz)
                    return LightPose(position: position, scale: SIMD3(repeating: phase < 0.5 ? 1 : 0))
                }
            }
            let color = SIMD3<Float>(repeating: i == 3 ? 3.5 : 2.5)
            if lab.motion {
                addLight(.sphere(radius: 0.05), color: color, motion: .scaleOnly, pose: pose)
            } else {
                let still = pose(0)
                addLight(.sphere(radius: 0.05), color: color, motion: .constant) { _ in still }
            }
            object("Ball \(i)") { kit.ball(b.p(x, 0.25, 2.0), 0.25, grey) }
        }
    }

    /// Booth 23 (yard), sun shadows: 2 cm poles 2 m tall, a picket fence, an overhang (2 x 2 m roof at 2.5 m on posts),
    /// a 1 m cube. Lit by the yard's sun.
    func boothSunShadows(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let wood = addMaterial(albedo: SIMD3(repeating: 0.6))
        let grey = addMaterial(albedo: SIMD3(repeating: 0.45))
        object("Poles") {
            for z in [0.8, 1.2, 1.6] as [Float] { labSlab(kit, b, [2.49, 0, z - 0.01], [2.51, 2, z + 0.01], grey) }
        }
        object("Fence") {
            labSlab(kit, b, [-1.0, 0.25, 2.0], [1.5, 0.3, 2.04], wood)
            labSlab(kit, b, [-1.0, 0.7, 2.0], [1.5, 0.75, 2.04], wood)
            var x: Float = -1.0
            while x < 1.5 { labSlab(kit, b, [x, 0, 2.02], [x + 0.06, 1.0, 2.05], wood); x += 0.12 }
        }
        object("Overhang") {
            labSlab(kit, b, [-2.8, 2.5, 3.6], [-0.8, 2.6, 5.6], wood)
            for (x, z) in [(-2.8, 3.6), (-0.88, 3.6), (-2.8, 5.52), (-0.88, 5.52)] as [(Float, Float)] {
                labSlab(kit, b, [x, 0, z], [x + 0.08, 2.5, z + 0.08], grey)
            }
        }
        object("Cube") { labSlab(kit, b, [1.0, 0, 4.0], [2.0, 1, 5.0], grey) }
    }

    /// Booth 24 (yard), window room: a closed 4 x 3 x 4 m room (0.2 m walls) with a tinted window (1.5 x 1 m) on the sun's
    /// side (the -x side of the world, the zone's z = 1 wall) and a 0.8 x 0.8 skylight; a grey floor and a white cube
    /// inside, lit by the sun and GI only. Interior: x -2...2, z 1...5.
    func boothWindowRoom(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let wall = addMaterial(albedo: SIMD3(repeating: 0.5))
        let floor = addMaterial(albedo: SIMD3(repeating: 0.4))
        let white = addMaterial(albedo: SIMD3(repeating: 0.85))
        let glass = addGlassMaterial(tint: [0.6, 0.85, 0.95])
        object("Walls") {
            labSlab(kit, b, [-2.2, 0, 0.8], [0.25, 3, 1.0], wall)      // the front wall, around the window
            labSlab(kit, b, [1.75, 0, 0.8], [2.2, 3, 1.0], wall)
            labSlab(kit, b, [0.25, 0, 0.8], [1.75, 1, 1.0], wall)
            labSlab(kit, b, [0.25, 2, 0.8], [1.75, 3, 1.0], wall)
            labSlab(kit, b, [-2.2, 0, 5.0], [2.2, 3, 5.2], wall)        // back
            labSlab(kit, b, [-2.2, 0, 0.8], [-2.0, 3, 5.2], wall)       // left
            labSlab(kit, b, [2.0, 0, 0.8], [2.2, 3, 5.2], wall)         // right
        }
        object("Roof") {
            labSlab(kit, b, [-2.2, 3, 0.8], [2.2, 3.2, 1.2], wall)      // around the skylight (x 1...1.8, z 1.2...2)
            labSlab(kit, b, [-2.2, 3, 2.0], [2.2, 3.2, 5.2], wall)
            labSlab(kit, b, [-2.2, 3, 1.2], [1.0, 3.2, 2.0], wall)
            labSlab(kit, b, [1.8, 3, 1.2], [2.2, 3.2, 2.0], wall)
        }
        object("Window") {
            let box = b.worldBox([0.25, 1, 0.89], [1.75, 2, 0.91])
            addInstance(kit.cube, glass, translate((box.lo + box.hi) / 2) * scale(box.hi - box.lo), mask: Scene.maskGlass)
        }
        object("Inside") {
            labSlab(kit, b, [-2, 0, 1], [2, 0.02, 5], floor)
            labSlab(kit, b, [-0.1, 0.02, 2.3], [0.5, 0.62, 2.9], white)
        }
    }

    /// Booth 25 (yard), suns: a cube, a pole and a sphere on the checker. The yard's sun is the first; here a second one
    /// (0.4 of it, from the north-east at 20 degrees) in every variant, and in `threeSuns` a third (0.3, from the west at
    /// 60 degrees).
    func boothSuns(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        object("Things") {
            labSlab(kit, b, [-1.7, 0, 2.5], [-0.7, 1, 3.5], grey)
            labSlab(kit, b, [-0.01, 0, 2.99], [0.01, 2, 3.01], grey)
            kit.ball(b.p(1.2, 0.5, 3.0), 0.5, grey)
        }
        func sun(_ name: String, elevation: Float, azimuth: Float, strength: Float) {
            let e = Scene.degrees(elevation)
            let direction = SIMD3<Float>(cos(e) * sin(azimuth), sin(e), cos(e) * cos(azimuth))
            let pose = LightPose(position: .zero, direction: direction, scale: [1.0, 0.95, 0.88] * 1.8 * strength)
            object(name) { addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1], motion: .constant) { _ in pose } }
        }
        sun("Sun 2", elevation: 20, azimuth: 3 * .pi / 4, strength: 0.4)
        if lab.variant == .threeSuns { sun("Sun 3", elevation: 60, azimuth: -.pi / 2, strength: 0.3) }
    }

    /// Booth 26, bounce room (GI): walls painted red (left), green (right) and white (back) on slabs 1 cm in front of them;
    /// a false ceiling at 2.8 m with a 0.2 m slot, and above it one narrow spot (outer 8 degrees) shining through the slot
    /// onto a white floor patch. Everything else is lit by GI only.
    func boothBounceRoom(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let red = addMaterial(albedo: [0.7, 0.1, 0.1])
        let green = addMaterial(albedo: [0.1, 0.7, 0.1])
        let white = addMaterial(albedo: SIMD3(repeating: 0.8))
        let plain = addMaterial(albedo: SIMD3(repeating: 0.5))
        object("Paint") {
            labSlab(kit, b, [-1.99, 0, 0.05], [-1.98, 2.8, 4], red)
            labSlab(kit, b, [1.98, 0, 0.05], [1.99, 2.8, 4], green)
            labSlab(kit, b, [-2, 0, 3.98], [2, 2.8, 3.99], white)
        }
        object("Ceiling and patch") {
            labSlab(kit, b, [-2, 2.8, 0], [2, 2.9, 2.9], plain)       // the false ceiling, around the slot (x -0.1...0.1, z 2.9...3.1)
            labSlab(kit, b, [-2, 2.8, 3.1], [2, 2.9, 4], plain)
            labSlab(kit, b, [-2, 2.8, 2.9], [-0.1, 2.9, 3.1], plain)
            labSlab(kit, b, [0.1, 2.8, 2.9], [2, 2.9, 3.1], plain)
            labSlab(kit, b, [-0.5, 0.0, 2.5], [0.5, 0.01, 3.5], white)
        }
        let position = b.p(0, 2.95, 3), down = SIMD3<Float>(0, -1, 0)
        addLight(.spot(radius: 0.02, inner: Scene.degrees(6), outer: Scene.degrees(8)), color: SIMD3(repeating: 150), motion: .constant) { _ in   // ~9 W through the cone: enough to bounce
            LightPose(position: position, direction: down)
        }
    }
}
