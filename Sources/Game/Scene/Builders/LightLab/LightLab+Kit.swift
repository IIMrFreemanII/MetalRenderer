import EngineCore
import MetalRenderer
import simd

/// Where a booth (or a yard zone) is, and its own coordinates: x across (right, -2...2 in a hall booth), y up from the
/// floor, z from the door wall (0) to the back wall (4). Content steps build only in these.
struct BoothFrame {
    let number: Int
    /// The floor's centre, in the world.
    let origin: SIMD3<Float>
    /// Unit vectors, horizontal: across to the right as one stands in the door looking in, and from the door toward the
    /// back wall.
    let right: SIMD3<Float>
    let inward: SIMD3<Float>
    /// Across, high, deep (4, 3, 4 for a hall booth; 6 across and deep for a yard zone).
    let size: SIMD3<Float>

    /// A local point in the world.
    func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        origin + right * x + SIMD3(0, y, 0) + inward * (z - size.z / 2)
    }

    /// A local direction (or offset) in the world.
    func dir(_ local: SIMD3<Float>) -> SIMD3<Float> {
        right * local.x + SIMD3(0, local.y, 0) + inward * local.z
    }

    /// The turn about y (`Kit.box(yaw:)`, `rotate(_, [0, 1, 0])`) that puts a thing modelled as the default camera sees it
    /// (+x to its right, looking along -z) so that it looks `local` radians further left of straight into the booth.
    /// At 0 its right is the booth's `right` and it looks along `inward`.
    func yaw(_ local: Float = 0) -> Float { atan2(-inward.x, -inward.z) + local }

    /// The world's box of a local box (both are axis-aligned: the frames are turned by quarter turns).
    func worldBox(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let a = p(lo.x, lo.y, lo.z), b = p(hi.x, hi.y, hi.z)
        return (simd_min(a, b), simd_max(a, b))
    }

    /// A hall booth's whole box, walls included (0.3 m): the space it takes from the hall.
    var outer: (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        worldBox([-size.x / 2 - 0.3, -0.3, -0.3], [size.x / 2 + 0.3, size.y + 0.3, size.z + 0.3])
    }
}

/// The materials every booth shares (added once, so the kit costs a few).
struct LabMaterials {
    let wall: Int
    /// The checker's two squares, added one after the other (the checker mesh's per-triangle materials are offsets).
    let checker: Int
    let cards: [Int]
    let chart: [Int]
    let white: Int

    static let cardAlbedos: [Float] = [0.03, 0.18, 0.5, 0.9]
    static let chartColours: [SIMD3<Float>] = [
        [0.8, 0.1, 0.1], [0.1, 0.7, 0.1], [0.1, 0.1, 0.8], [0.1, 0.7, 0.8], [0.8, 0.1, 0.7], [0.85, 0.8, 0.1],
    ]

    init(_ scene: Scene) {
        wall = scene.addMaterial(albedo: SIMD3(repeating: 0.5))
        checker = scene.addMaterial(albedo: SIMD3(repeating: 0.18))
        _ = scene.addMaterial(albedo: SIMD3(repeating: 0.5))
        cards = Self.cardAlbedos.map { scene.addMaterial(albedo: SIMD3(repeating: $0)) }
        chart = Self.chartColours.map { scene.addMaterial(albedo: $0) }
        white = scene.addMaterial(albedo: SIMD3(repeating: 0.9))
    }
}

/// The lab's kit: the hall's dimensions and the pieces a booth is made of.
enum LabKit {
    /// The corridor, along +x: 3 m wide (z -1.5...1.5), 3 m high. Its inside runs from x = 0 to `corridorEnd`.
    static let corridorEnd: Float = 55.6
    static let wall: Float = 0.3
    /// A hall booth's column: its centre x, 4.6 m apart (4 m inside and two walls).
    static func columnX(_ column: Int) -> Float { 2.5 + 4.6 * Float(column) }
    static let columns = 12
    /// The yard behind the end wall: x from `yardLo` for 18 m, z -9...9.
    static let yardLo: Float = corridorEnd + wall
    static let yardSize: Float = 18

    /// The sun's direction (toward it): 35 degrees up, from the south-west (-x, +z).
    static var toSun: SIMD3<Float> {
        let e = Scene.degrees(35), az: Float = -.pi / 4
        return [cos(e) * sin(az), sin(e), cos(e) * cos(az)]
    }

    /// A flat grid of squares over x -w/2...w/2, z -d/2...d/2 at y = 0 with alternating materials (offset 0 and 1).
    static func checkerMesh(width w: Float, depth d: Float, square: Float = 0.5) -> (mesh: MeshGeometry, offsets: [UInt8]) {
        let nx = Int((w / square).rounded()), nz = Int((d / square).rounded())
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], offsets: [UInt8] = []
        positions.reserveCapacity(nx * nz * 4)
        for j in 0..<nz {
            for i in 0..<nx {
                let x0 = -w / 2 + Float(i) * square, z0 = -d / 2 + Float(j) * square, base = UInt32(positions.count)
                positions += [[x0, 0, z0], [x0 + square, 0, z0], [x0 + square, 0, z0 + square], [x0, 0, z0 + square]]
                normals += [SIMD3<Float>](repeating: [0, 1, 0], count: 4)
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
                offsets += [UInt8](repeating: UInt8((i + j) & 1), count: 2)
            }
        }
        return ((positions, normals, indices), offsets)
    }

    /// Boxes (world centre, size) merged into one mesh in world coordinates.
    static func merged(_ boxes: [(center: SIMD3<Float>, size: SIMD3<Float>)]) -> MeshGeometry {
        let cube = Scene.cubeMesh()
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for box in boxes {
            let base = UInt32(positions.count)
            positions += cube.positions.map { $0 * box.size + box.center }
            normals += cube.normals
            indices += cube.indices.map { $0 + base }
        }
        return (positions, normals, indices)
    }

    private static let segments: [UInt8] = {
        // a top, b top right, c bottom right, d bottom, e bottom left, f top left, g middle (bits 0...6)
        let digits = ["abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc", "abcdefg", "abcdfg"]
        return digits.map { $0.reduce(0) { $0 | UInt8(1 << ($1.asciiValue! - 97)) } }
    }()

    /// A two-digit number in 7-segment boxes, 0.25 m high, as read from inside the booth looking at the door wall (so
    /// it runs along -x of the frame), centred at local x = 0, y = `y`, on the door wall's inside face.
    static func signMesh(_ number: Int, _ b: BoothFrame, y: Float = 2.6) -> MeshGeometry {
        let h: Float = 0.25, w: Float = 0.14, t: Float = 0.03, gap: Float = 0.06, depth: Float = 0.02
        var boxes: [(center: SIMD3<Float>, size: SIMD3<Float>)] = []
        for (k, digit) in [number / 10 % 10, number % 10].enumerated() {
            let cx = -((Float(k) - 0.5) * (w + gap))   // the first digit is on the reader's left: +x of the frame
            let long = (h - 3 * t) / 2
            let bits = segments[digit]
            // (centre across, centre up, size across, size up) per segment a...g
            let parts: [(Float, Float, Float, Float)] = [
                (0, h - t / 2, w, t), (w / 2 - t / 2, h - t - long / 2, t, long), (w / 2 - t / 2, t + long / 2, t, long),
                (0, t / 2, w, t), (-w / 2 + t / 2, t + long / 2, t, long), (-w / 2 + t / 2, h - t - long / 2, t, long),
                (0, h / 2, w, t),
            ]
            for (s, part) in parts.enumerated() where bits & UInt8(1 << s) != 0 {
                // the reader's right is -x of the frame
                let lo = b.p(cx - part.0 - part.2 / 2, y - h / 2 + part.1 - part.3 / 2, 0)
                let hi = b.p(cx - part.0 + part.2 / 2, y - h / 2 + part.1 + part.3 / 2, depth)
                boxes.append(((lo + hi) / 2, simd_abs(hi - lo)))
            }
        }
        return merged(boxes)
    }
}

extension Scene {
    /// One axis-aligned slab given by local corners.
    @discardableResult
    func labSlab(_ kit: Kit, _ b: BoothFrame, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ material: Int) -> Int {
        let box = b.worldBox(lo, hi)
        return kit.slab(box.lo, box.hi, material)
    }

    /// A booth's shell: 0.3 m walls, floor and ceiling as slabs overlapping at the corners, a door in the corridor-side
    /// wall (1 m x 2.2 m) and a baffle outside it.
    func labShell(_ kit: Kit, _ b: BoothFrame, _ m: LabMaterials) {
        let hx = b.size.x / 2, h = b.size.y, d = b.size.z, t = LabKit.wall
        object("Shell") {
            labSlab(kit, b, [-hx - t, -t, -t], [hx + t, -0.002, d + t], m.wall)          // floor (its top just under the checker)
            labSlab(kit, b, [-hx - t, h, -t], [hx + t, h + t, d + t], m.wall)             // ceiling
            labSlab(kit, b, [-hx - t, -t, d], [hx + t, h + t, d + t], m.wall)             // back
            labSlab(kit, b, [-hx - t, -t, -t], [-hx, h + t, d + t], m.wall)               // left
            labSlab(kit, b, [hx, -t, -t], [hx + t, h + t, d + t], m.wall)                 // right
            labSlab(kit, b, [-hx - t, -t, -t], [-0.5, h + t, 0], m.wall)                  // door wall, left of the door
            labSlab(kit, b, [0.5, -t, -t], [hx + t, h + t, 0], m.wall)                    // right of the door
            labSlab(kit, b, [-0.5, 2.2, -t], [0.5, h + t, 0], m.wall)                     // over it
            labSlab(kit, b, [-1, 0, -0.75], [1, 2.4, -0.6], m.wall)                       // baffle
        }
    }

    /// Grey cards (0.3 m squares, 1 cm thick) on the left wall near the door end, a colour chart under them, a number sign
    /// above the door.
    func labDecor(_ kit: Kit, _ b: BoothFrame, _ m: LabMaterials, signMesh: Int) {
        let hx = b.size.x / 2
        object("Cards") {
            for (i, material) in m.cards.enumerated() {
                let z = 0.5 + 0.4 * Float(i)
                labSlab(kit, b, [-hx, 1.05, z - 0.15], [-hx + 0.01, 1.35, z + 0.15], material)
            }
        }
        object("Chart") {
            for (i, material) in m.chart.enumerated() {
                let z = 0.4 + 0.25 * Float(i)
                labSlab(kit, b, [-hx, 0.65, z - 0.1], [-hx + 0.01, 0.85, z + 0.1], material)
            }
        }
        object("Sign") { addInstance(signMesh, m.white, matrix_identity_float4x4) }
    }
}
