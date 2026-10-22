import EngineCore
import Foundation
import Plants
import simd

/// A terrain's generator (GeneratorStack): its steps evaluated at a place of the world, a source's noise combined with
/// what the steps before made by its blend, an operation changing it; and the stack run over a region, its edge
/// faded into the ground around it.
enum TerrainGenerator {
    /// Gradient noise remapped to about -1...1.
    @inline(__always) private static func n(_ x: Double, _ z: Double, _ seed: UInt32) -> Float { Terrain.noise(x, z, seed: seed) * 1.4 }

    /// The stack's height at (x, z) given the ground's `ground` there (only `replaces == false` stacks add to it, and
    /// operations read it as the first steps' input).
    static func height(_ stack: GeneratorStack, x: Double, z: Double, ground: Float) -> Float {
        var h: Float = stack.replaces ? 0 : ground
        var px = x, pz = z
        for node in stack.nodes where node.enabled {
            let seed = UInt32(truncatingIfNeeded: node.seed &* 0x9E37 &+ 0x1F)
            let scale = Double(max(node.scale, 0.5))
            func fbm(_ kind: GeneratorNode.Kind) -> Float {
                var sum: Float = 0, amp: Float = 1, f = 1.0, norm: Float = 0, weight: Float = 1
                for o in 0..<max(min(node.octaves, 12), 1) {
                    let s = seed &+ UInt32(o) &* 131
                    var v = n(px / scale * f, pz / scale * f, s)
                    switch kind {
                    case .ridged:
                        v = 1 - abs(v)
                        v *= v
                        v *= weight
                        weight = min(max(v * 1.6, 0), 1)
                    case .billow: v = abs(v) * 2 - 1
                    default: break
                    }
                    sum += v * amp
                    norm += amp
                    amp *= node.gain
                    f *= Double(node.lacunarity)
                }
                return sum / max(norm, 1e-6)
            }
            var made: Float? = nil
            switch node.kind {
            case .fbm: made = fbm(.fbm) * node.amplitude
            case .ridged: made = (fbm(.ridged) * 2 - 0.6) * node.amplitude
            case .billow: made = fbm(.billow) * node.amplitude
            case .cellular:
                // Distance to the nearest of one jittered point per cell (F1), as hills or pits.
                let cx = (px / scale).rounded(.down), cz = (pz / scale).rounded(.down)
                var best = Double.infinity
                for dz in -1...1 {
                    for dx in -1...1 {
                        let ix = Int(cx) + dx, iz = Int(cz) + dz
                        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(ix &* 73_856_093 ^ iz &* 19_349_663)) ^ UInt64(seed))
                        let jx = Double(rng.next()), jz = Double(rng.next())
                        let d = hypot(px / scale - (Double(ix) + jx), pz / scale - (Double(iz) + jz))
                        best = min(best, d)
                    }
                }
                made = (1 - Float(min(best, 1)) * 1.6) * node.amplitude
            case .constant: made = node.amplitude
            case .warp:
                // Later steps read the place moved by a noise.
                px += Double(n(x / scale, z / scale, seed) * node.amplitude * node.amount)
                pz += Double(n(x / scale + 31.7, z / scale - 17.3, seed &+ 7) * node.amplitude * node.amount)
            case .terrace:
                let step = max(node.amplitude, 0.1), t = h / step, f = t - t.rounded(.down)
                let k = 1 / (1 - min(max(node.sharpness, 0), 0.95))
                h = (t.rounded(.down) + min(max((f - 0.5) * k + 0.5, 0), 1)) * step
            case .plateau:
                if h > node.level { h = node.level + (h - node.level) * (1 - node.amount) }
            case .curve:
                h = node.level + (h - node.level) * node.amount
            case .smooth:
                break   // over a region only (`run`): it reads the neighbours
            }
            if let v = made {
                switch node.blend {
                case .add: h += v
                case .subtract: h -= v
                case .multiply: h *= v / max(abs(node.amplitude), 1e-3)
                case .max: h = max(h, v)
                case .min: h = min(h, v)
                case .replace: h = v
                case .lerp: h += (v - h) * node.amount
                }
            }
        }
        return h
    }

    /// The stack run over a region (sample indices `lo`...`hi`), faded into the ground over `border` metres inside its
    /// edge (a whole finite terrain: no fade). Kept for undo in `record`; protected ground stays.
    static func run(_ s: inout TerrainSnapshot, stack: GeneratorStack, lo: SIMD2<Int>, hi: SIMD2<Int>, border: Float,
                    record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let grid = s.grid, size = hi &- lo &+ 1
        guard size.x > 0, size.y > 0 else { return [] }
        let ground = s.heights(from: lo, count: size, step: 1)
        var made = [Float](repeating: 0, count: ground.count)
        made.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: size.y) { j in
                for i in 0..<size.x {
                    let p = grid.place(lo.x + i, lo.y + j)
                    out[j * size.x + i] = height(stack, x: p.x, z: p.y, ground: ground[j * size.x + i])
                }
            }
        }
        // Smoothing steps: passes of a 3 x 3 mean over what was made.
        let passes = stack.nodes.filter { $0.enabled && $0.kind == .smooth }.reduce(0) { $0 + max(Int($1.amount * 10), 1) }
        if passes > 0 { made = smooth(made, size.x, size.y, passes: passes) }
        let whole = grid.lo == lo && grid.hi == hi
        let band = whole ? 0 : Double(max(border, 0)) / Double(grid.cell)
        let reading = s
        return TerrainSculpt.forEach(&s, lo: lo, hi: hi, record: &record) { i, j, base, delta in
            let k = (j - lo.y) * size.x + (i - lo.x)
            var w: Float = 1
            if band > 0 {
                let e = Double(min(i - lo.x, hi.x - i, j - lo.y, hi.y - j))
                let t = Float(min(max(e / band, 0), 1))
                w = t * t * (3 - 2 * t)
            }
            w *= 1 - reading.protection(i, j)
            guard w > 0 else { return }
            let now = base + delta
            delta += (made[k] - now) * w
        }
    }

    /// `passes` of a 3 x 3 mean (edges clamped).
    static func smooth(_ h: [Float], _ w: Int, _ hgt: Int, passes: Int) -> [Float] {
        var a = h, b = h
        for _ in 0..<passes {
            a.withUnsafeBufferPointer { src in
                b.withUnsafeMutableBufferPointer { dst in
                    DispatchQueue.concurrentPerform(iterations: hgt) { j in
                        for i in 0..<w {
                            var sum: Float = 0
                            for dj in -1...1 {
                                let y = min(max(j + dj, 0), hgt - 1)
                                for di in -1...1 { sum += src[y * w + min(max(i + di, 0), w - 1)] }
                            }
                            dst[j * w + i] = sum / 9
                        }
                    }
                }
            }
            swap(&a, &b)
        }
        return a
    }
}
