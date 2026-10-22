import EngineCore
import Foundation
import simd

/// The realistic look's rocks (SceneSettings.realism): boulders, stones and pebbles on a scene's terrain, in its rock
/// scan (TextureSet "rock"), each half sunk into the ground and set to its slope.
extension Scene {
    /// A rock's mesh: an icosphere pushed out by ridged noise, then chipped by `cuts` planes (the flat faces broken rock
    /// has), flattened, its foot level; UVs in metres across it (the scan's repeat). Its own by `seed`.
    package static func boulder(seed: UInt64, cuts: Int = 5) -> (MeshGeometry, [SIMD2<Float>]) {
        var rng = SplitMix64(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0xB0D)
        let base = icosphere(subdivisions: 4)
        let s = UInt32(truncatingIfNeeded: seed &* 7919 &+ 17)
        let squash = SIMD3<Float>(rng.range(0.85, 1.15), rng.range(0.5, 0.75), rng.range(0.7, 1))
        var planes: [(SIMD3<Float>, Float)] = []
        for _ in 0..<cuts {
            let a = rng.range(0, 2 * .pi), e = rng.range(-0.2, 1.2)
            planes.append((simd_normalize(SIMD3(cos(a) * cos(e), sin(e), sin(a) * cos(e))), rng.range(0.6, 0.85)))
        }
        var positions = base.positions.map { p -> SIMD3<Float> in
            let n = simd_normalize(p)
            func ridged(_ q: SIMD2<Float>, _ k: UInt32) -> Float { 1 - abs(Terrain.noise(q, seed: s &+ k)) }
            let bump = 0.88 + 0.22 * Terrain.noise(SIMD2(n.x * 1.3 + n.y, n.z * 1.3 - n.y), seed: s)
                + 0.08 * ridged(SIMD2(n.x * 4 + n.z, n.y * 4 - n.x), 1) + 0.03 * Terrain.noise(SIMD2(n.x * 11 + n.y, n.z * 11), seed: s &+ 2)
            var q = n * bump
            for (pn, d) in planes {
                let over = simd_dot(q, pn) - d
                if over > 0 { q -= pn * over * 0.92 }
            }
            return q * squash
        }
        for k in positions.indices where positions[k].y < -0.15 { positions[k].y = -0.15 - (positions[k].y + 0.15) * 0.15 }
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: base.indices.count, by: 3) {
            let a = Int(base.indices[t]), b = Int(base.indices[t + 1]), c = Int(base.indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        let uvs = positions.map { SIMD2($0.x + $0.y * 0.35, $0.z - $0.y * 0.35) * 0.9 }
        return ((positions, normals.map { simd_length($0) > 0 ? simd_normalize($0) : [0, 1, 0] }, base.indices), uvs)
    }

    /// `count` rocks over the scene's terrain within `lo`...`hi` (x, z): each place kept by `where` (0...1, and the
    /// size range it gives), sized by a power law (many small, a few large), sunk a third, set to the slope. Eight
    /// shapes shared. With the realistic look only. How many.
    @discardableResult
    package func addRocks(count: Int, lo: SIMD2<Float>, hi: SIMD2<Float>, seed: UInt64,
                  where keep: (Float, Float) -> (chance: Float, size: ClosedRange<Float>)) -> Int {
        guard settings.realism != .off, let t = terrain else { return 0 }
        beginObject("Rocks")
        defer { endObject() }
        let material = addScanMaterial("rock", tint: [0.9, 0.9, 0.88], normalScale: 1.3)
            ?? addMaterial(albedo: [0.3, 0.29, 0.27])
        let meshes = (0..<8).map { k -> Int in
            let (geometry, uvs) = Scene.boulder(seed: seed &+ UInt64(k) &* 31)
            return addMesh(geometry, uvs: uvs, name: "rock-\(seed)-\(k)", label: "rock")
        }
        var rng = SplitMix64(seed: seed)
        var placed = 0
        for _ in 0..<count {
            let x = rng.range(lo.x, hi.x), z = rng.range(lo.y, hi.y), chance = rng.next(), k = rng.int(meshes.count)
            let yaw = rng.range(0, 2 * .pi), u = rng.next(), tilt = rng.range(-0.25, 0.25)
            let (likely, size) = keep(x, z)
            guard chance < likely else { continue }
            let r = size.lowerBound + (size.upperBound - size.lowerBound) * u * u
            let h = t.height(x, z), dx = t.height(x + 0.5, z) - t.height(x - 0.5, z), dz = t.height(x, z + 0.5) - t.height(x, z - 0.5)
            let up = simd_normalize(SIMD3(-dx, 1, -dz) + SIMD3(tilt, 0, -tilt) * 0.5)
            addInstance(meshes[k], material, translate([x, h - r * 0.28, z]) * Scene.alignY(up) * rotate(yaw, [0, 1, 0]) * scale(r))
            placed += 1
        }
        return placed
    }
}
