import Buildings
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// Erosion: water that rains, runs downhill carrying earth and leaves it where it slows (hydraulic: the virtual pipes
/// model, Mei, Decaudin and Hu 2007), and slopes steeper than they can stand crumbling down (thermal). On a grid of
/// heights (a region of a terrain, rows along z), every pass on every core. Material is conserved: what is taken from
/// one cell is left on another (thermal exactly; hydraulic up to the sediment still carried when it stops).
package enum TerrainErosion {
    package enum Kind: String, CaseIterable, Identifiable {
        case hydraulic, thermal, both
        package var id: String { rawValue }
        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// `iterations` of hydraulic erosion over `b` (`w` x `h` cells of `cell` metres). `rain`: where it rains (0...1 a
    /// cell; nil: everywhere). `progress` is told the share done between passes and stops the run if it says false.
    package static func hydraulic(_ b: inout [Float], w: Int, h: Int, cell: Float, settings e: ErosionSettings, iterations: Int,
                          rain: [Float]? = nil, progress: ((Float) -> Bool)? = nil) {
        let count = w * h
        guard w > 2, h > 2, iterations > 0 else { return }
        var d = [Float](repeating: 0, count: count), s = d, s2 = d
        var fL = d, fR = d, fT = d, fB = d, vx = d, vz = d
        let dt: Float = 0.05, g: Float = 9.81, l = cell, area = l * l
        // (Capacity per unit of speed, slope and depth; earth taken and left by the pass's time step, so that the grid's
        // cells move together rather than each on its own, which grows needles.)
        let kc = e.capacity, ks = e.dissolve * dt, kd = e.deposit * dt, ke = e.evaporation
        let rainPerStep = e.rain
        for it in 0..<iterations {
            // 1. Rain.
            if let rain {
                for k in 0..<count { d[k] += rainPerStep * rain[k] }
            } else {
                for k in 0..<count { d[k] += rainPerStep }
            }
            // 2. Outflow through the four pipes, scaled so a cell never sends more than it holds.
            b.withUnsafeBufferPointer { b in
                d.withUnsafeBufferPointer { d in
                    fL.withUnsafeMutableBufferPointer { fL in
                        fR.withUnsafeMutableBufferPointer { fR in
                            fT.withUnsafeMutableBufferPointer { fT in
                                fB.withUnsafeMutableBufferPointer { fB in
                                    DispatchQueue.concurrentPerform(iterations: h) { j in
                                        for i in 0..<w {
                                            let k = j * w + i, H = b[k] + d[k]
                                            let l0 = i > 0 ? max(0, fL[k] + dt * area * g * (H - b[k - 1] - d[k - 1]) / l) : 0
                                            let r0 = i < w - 1 ? max(0, fR[k] + dt * area * g * (H - b[k + 1] - d[k + 1]) / l) : 0
                                            let t0 = j > 0 ? max(0, fT[k] + dt * area * g * (H - b[k - w] - d[k - w]) / l) : 0
                                            let b0 = j < h - 1 ? max(0, fB[k] + dt * area * g * (H - b[k + w] - d[k + w]) / l) : 0
                                            let out = (l0 + r0 + t0 + b0) * dt
                                            let scale = out > 0 ? min(1, d[k] * area / out) : 1
                                            fL[k] = l0 * scale; fR[k] = r0 * scale; fT[k] = t0 * scale; fB[k] = b0 * scale
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 3. The water's new depth and speed; 4. earth taken or left by how much the water can carry.
            b.withUnsafeMutableBufferPointer { b in
                d.withUnsafeMutableBufferPointer { d in
                    s.withUnsafeMutableBufferPointer { s in
                        vx.withUnsafeMutableBufferPointer { vx in
                            vz.withUnsafeMutableBufferPointer { vz in
                                DispatchQueue.concurrentPerform(iterations: h) { j in
                                    for i in 0..<w {
                                        let k = j * w + i
                                        let inL = i > 0 ? fR[k - 1] : 0, inR = i < w - 1 ? fL[k + 1] : 0
                                        let inT = j > 0 ? fB[k - w] : 0, inB = j < h - 1 ? fT[k + w] : 0
                                        let before = d[k]
                                        let net = dt * (inL + inR + inT + inB - fL[k] - fR[k] - fT[k] - fB[k])
                                        d[k] = max(before + net / area, 0)
                                        let mean = max((before + d[k]) / 2, 1e-4)
                                        let wx = (inL - fL[k] + fR[k] - inR) / 2, wz = (inT - fT[k] + fB[k] - inB) / 2
                                        vx[k] = wx / (l * mean)
                                        vz[k] = wz / (l * mean)
                                        let gx = (b[j * w + min(i + 1, w - 1)] - b[j * w + max(i - 1, 0)]) / (2 * l)
                                        let gz = (b[min(j + 1, h - 1) * w + i] - b[max(j - 1, 0) * w + i]) / (2 * l)
                                        let tilt = max((gx * gx + gz * gz).squareRoot() / (1 + gx * gx + gz * gz).squareRoot(), 0.02)
                                        let speed = (vx[k] * vx[k] + vz[k] * vz[k]).squareRoot()
                                        let capacity = kc * tilt * min(speed, 10) * min(d[k], 1)
                                        if capacity > s[k] {
                                            let take = min(ks * (capacity - s[k]), 0.01 * l)
                                            b[k] -= take
                                            s[k] += take
                                        } else {
                                            let leave = min(kd * (s[k] - capacity), 0.01 * l)
                                            b[k] += leave
                                            s[k] -= leave
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 5. The sediment carried along with the water (back-traced, bilinear); 6. evaporation.
            s.withUnsafeBufferPointer { s in
                s2.withUnsafeMutableBufferPointer { s2 in
                    DispatchQueue.concurrentPerform(iterations: h) { j in
                        for i in 0..<w {
                            let k = j * w + i
                            // (At most a cell a pass: the trace stays stable however fast the water runs.)
                            let mx = min(max(vx[k] * dt / l, -1), 1), mz = min(max(vz[k] * dt / l, -1), 1)
                            let x = min(max(Float(i) - mx, 0), Float(w - 1)), z = min(max(Float(j) - mz, 0), Float(h - 1))
                            let x0 = Int(x), z0 = Int(z), x1 = min(x0 + 1, w - 1), z1 = min(z0 + 1, h - 1), fx = x - Float(x0), fz = z - Float(z0)
                            let top = s[z0 * w + x0] + (s[z0 * w + x1] - s[z0 * w + x0]) * fx
                            let bottom = s[z1 * w + x0] + (s[z1 * w + x1] - s[z1 * w + x0]) * fx
                            s2[k] = top + (bottom - top) * fz
                        }
                    }
                }
            }
            // (The back-trace neither makes nor loses sediment: what it carries is rescaled to what there was.)
            let had = s.reduce(0, +), has = s2.reduce(0, +)
            if has > 1e-9 { let f = had / has; for k in 0..<count { s2[k] *= f } }
            swap(&s, &s2)
            for k in 0..<count { d[k] *= 1 - ke }
            if it % 8 == 7, let progress, !progress(Float(it + 1) / Float(iterations)) { break }
        }
        // What is still carried settles where it is.
        for k in 0..<count { b[k] += s[k] }
    }

    /// `iterations` of thermal erosion: wherever the ground is steeper than `talus` degrees toward a neighbour (of the
    /// eight), `rate` of the excess slides down to it. `mask` scales it a cell (nil: everywhere).
    package static func thermal(_ b: inout [Float], w: Int, h: Int, cell: Float, settings e: ErosionSettings, iterations: Int,
                        mask: [Float]? = nil, progress: ((Float) -> Bool)? = nil) {
        guard w > 2, h > 2, iterations > 0 else { return }
        let talus = tan(min(max(e.talus, 1), 89) * .pi / 180) * cell
        let offsets = [(-1, 0, Float(1)), (1, 0, 1), (0, -1, 1), (0, 1, 1), (-1, -1, Float(2).squareRoot()), (1, -1, Float(2).squareRoot()),
                       (-1, 1, Float(2).squareRoot()), (1, 1, Float(2).squareRoot())]
        var change = [Float](repeating: 0, count: w * h)
        for it in 0..<iterations {
            for k in change.indices { change[k] = 0 }
            // Each cell works out what it sends (to its lower neighbours, by how much lower each is beyond the talus);
            // what arrives is gathered by each receiver from its own neighbours, so the passes never write together.
            var sends = [Float](repeating: 0, count: w * h * 8)
            b.withUnsafeBufferPointer { b in
                sends.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: h) { j in
                        for i in 0..<w {
                            let k = j * w + i
                            var total: Float = 0, most: Float = 0
                            var excess = SIMD8<Float>()
                            for (n, o) in offsets.enumerated() {
                                let x = i + o.0, z = j + o.1
                                guard x >= 0, x < w, z >= 0, z < h else { continue }
                                let drop = b[k] - b[z * w + x] - talus * o.2
                                if drop > 0 { excess[n] = drop; total += drop; most = max(most, drop) }
                            }
                            guard total > 0 else { continue }
                            let amount = e.thermalRate * most / 2 * (mask?[k] ?? 1)
                            for n in 0..<8 where excess[n] > 0 { out[k * 8 + n] = amount * excess[n] / total }
                        }
                    }
                }
            }
            change.withUnsafeMutableBufferPointer { change in
                DispatchQueue.concurrentPerform(iterations: h) { j in
                    for i in 0..<w {
                        let k = j * w + i
                        var delta: Float = 0
                        for n in 0..<8 { delta -= sends[k * 8 + n] }
                        for (n, o) in offsets.enumerated() {
                            // The neighbour on the other side sends to this one along its own `n`.
                            let x = i - o.0, z = j - o.1
                            guard x >= 0, x < w, z >= 0, z < h else { continue }
                            delta += sends[(z * w + x) * 8 + n]
                        }
                        change[k] = delta
                    }
                }
            }
            for k in b.indices { b[k] += change[k] }
            if it % 8 == 7, let progress, !progress(Float(it + 1) / Float(iterations)) { break }
        }
    }

    /// Erosion over a region (sample indices `lo`...`hi`), its edge faded into the ground over `border` metres; kept for
    /// undo in `record`, protected ground left as it was. The heights are read once (`heights`, from a snapshot) so the
    /// long part runs off the render thread; this writes the result.
    package static func erode(heights: [Float], size: SIMD2<Int>, cell: Float, kind: Kind, settings e: ErosionSettings,
                      progress: ((Float) -> Bool)? = nil) -> [Float] {
        var b = heights
        let hydraulic = kind != .thermal ? e.hydraulicIterations : 0, thermal = kind != .hydraulic ? e.thermalIterations : 0
        let total = Float(max(hydraulic + thermal, 1))
        if hydraulic > 0 {
            TerrainErosion.hydraulic(&b, w: size.x, h: size.y, cell: cell, settings: e, iterations: hydraulic) { p in
                progress?(p * Float(hydraulic) / total) ?? true
            }
        }
        if thermal > 0 {
            TerrainErosion.thermal(&b, w: size.x, h: size.y, cell: cell, settings: e, iterations: thermal) { p in
                progress?((Float(hydraulic) + p * Float(thermal)) / total) ?? true
            }
        }
        return b
    }

    /// New heights (`made`, of the region `lo`...`hi`) into the snapshot, faded over `border` metres inside the region's
    /// edge (none for a whole finite terrain), protected ground kept.
    package static func write(_ s: inout TerrainSnapshot, made: [Float], lo: SIMD2<Int>, hi: SIMD2<Int>, border: Float,
                      record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let grid = s.grid, size = hi &- lo &+ 1
        let whole = grid.lo == lo && grid.hi == hi
        let band = whole ? 0 : Double(max(border, 0)) / Double(grid.cell)
        let reading = s
        return TerrainSculpt.forEach(&s, lo: lo, hi: hi, record: &record) { i, j, base, delta in
            let k = (j - lo.y) * size.x + (i - lo.x)
            var w: Float = 1
            if band > 0 {
                let edge = Double(min(i - lo.x, hi.x - i, j - lo.y, hi.y - j))
                let t = Float(min(max(edge / band, 0), 1))
                w = t * t * (3 - 2 * t)
            }
            w *= 1 - reading.protection(i, j)
            guard w > 0 else { return }
            delta += (made[k] - (base + delta)) * w
        }
    }

    /// One dab of an erosion or generator brush: around the dab (a window of the brush's size and a margin), a few
    /// passes of water (`erode`) or of crumbling (`crumble`), or the generator blended in (`stamp`), weighted by the
    /// brush's falloff.
    package static func brush(_ s: inout TerrainSnapshot, brush b: TerrainBrush, dab: TerrainDab, document: TerrainDocument?,
                      record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let margin = b.tool == .stamp ? 0 : 6
        guard let (lo0, hi0) = TerrainSculpt.range(s.grid, center: dab.center, radius: b.radius) else { return [] }
        var lo = lo0 &- margin, hi = hi0 &+ margin
        if let glo = s.grid.lo, let ghi = s.grid.hi { lo = simd_max(lo, glo); hi = simd_min(hi, ghi) }
        let size = hi &- lo &+ 1
        guard size.x > 2, size.y > 2 else { return [] }
        let before = s.heights(from: lo, count: size, step: 1)
        var after = before
        let grid = s.grid, settings = document?.erosion ?? ErosionSettings()
        var weight = [Float](repeating: 0, count: before.count)
        for j in 0..<size.y {
            for i in 0..<size.x {
                let p = grid.place(lo.x + i, lo.y + j)
                weight[j * size.x + i] = b.falloff(Float(simd_distance(p, dab.center) / Double(b.radius))) * min(b.strength * dab.amount, 1)
            }
        }
        switch b.tool {
        case .erode:
            var e = settings
            e.rain *= 3
            hydraulic(&after, w: size.x, h: size.y, cell: grid.cell, settings: e, iterations: 12, rain: weight)
        case .crumble:
            thermal(&after, w: size.x, h: size.y, cell: grid.cell, settings: settings, iterations: 6, mask: weight)
        case .stamp:
            let stack = document?.generator ?? GeneratorStack()
            for k in after.indices {
                let i = k % size.x, j = k / size.x, p = grid.place(lo.x + i, lo.y + j)
                let target = TerrainGenerator.height(stack, x: p.x, z: p.y, ground: before[k])
                after[k] = before[k] + (target - before[k]) * min(weight[k] * 0.15, 1)
            }
        default:
            return []
        }
        let reading = s
        return TerrainSculpt.forEach(&s, lo: lo, hi: hi, record: &record) { i, j, base, delta in
            let k = (j - lo.y) * size.x + (i - lo.x)
            // (Erosion moves earth beyond the brush too, a little: what it carried there. The stamp is weighed above.)
            let change = (after[k] - before[k]) * (1 - reading.protection(i, j))
            delta += change
        }
    }
}
