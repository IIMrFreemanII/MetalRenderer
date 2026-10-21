import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// The ground's 16 layers at a place: each layer's own rule (TerrainRule: height, slope, noise) where nothing is
/// painted, the painted weights where something is (TerrainTile.paint), mixed by how much of the paint shows
/// (TerrainTile.mask). Layer 0 is under all the others: it has what they leave.
package enum TerrainPaint {
    /// The layers' weights by their rules, summing to 1.
    package static func ruleWeights(_ layers: [TerrainLayer], height: Float, slope: Float, x: Double, z: Double) -> SIMD16<Float> {
        var w = SIMD16<Float>(repeating: 0), rest: Float = 1
        // From the top layer down: each takes its share of what the ones above left.
        for l in stride(from: min(layers.count, TerrainTile.layers) - 1, through: 1, by: -1) {
            let rule = layers[l].rule
            guard rule.enabled else { continue }
            let scale = max(rule.noiseScale, 0.01) / 100
            let noise = rule.noiseAmount > 0 ? Terrain.noise(x * Double(scale), z * Double(scale), seed: UInt32(0x51A7 + l)) * 1.4 : 0
            let own = rule.weight(height: height, slope: slope, noise: noise) * rest
            w[l] = own
            rest -= own
        }
        w[0] = max(rest, 0)
        return w
    }

    /// What shows at sample (i, j): the rules' weights, and the paint over them as much as its mask says.
    package static func weights(_ s: TerrainSnapshot, layers: [TerrainLayer], _ i: Int, _ j: Int, height: Float, slope: Float) -> SIMD16<Float> {
        let p = s.grid.place(i, j)
        let rule = ruleWeights(layers, height: height, slope: slope, x: p.x, z: p.y)
        guard let (painted, mask) = s.paint(i, j) else { return rule }
        let paint = SIMD16<Float>(painted) / 255
        return rule + (paint - rule) * mask
    }

    /// A dab of the paint brush (the brush's layer more, the others less), or of the eraser (the paint shows less:
    /// the rules come back). Where nothing was painted, the paint starts as what shows.
    package static func dab(_ s: inout TerrainSnapshot, brush b: TerrainBrush, dab: TerrainDab, layers: [TerrainLayer]?,
                    record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let layers = layers ?? TerrainDocument.defaultLayers
        guard let (lo, hi) = TerrainSculpt.range(s.grid, center: dab.center, radius: b.radius) else { return [] }
        let grid = s.grid, n = grid.tileCells, radius = Double(b.radius), layer = min(max(b.layer, 0), TerrainTile.layers - 1)
        // Heights around it (the rules' slope), one sample beyond on each side.
        let w = hi.x - lo.x + 3
        let h = s.heights(from: lo &- 1, count: SIMD2(w, hi.y - lo.y + 3), step: 1)
        @inline(__always) func at(_ i: Int, _ j: Int) -> Float { h[(j - lo.y + 1) * w + (i - lo.x + 1)] }
        let reading = s
        var touched = Set<SIMD2<Int>>()
        for t in grid.tiles(from: lo, to: hi) {
            let first = grid.firstSample(t)
            let a = simd_max(lo, first), c = simd_min(hi, first &+ (n - 1))
            guard a.x <= c.x, a.y <= c.y else { continue }
            if record.before[t] == nil { record.before[t] = .some(s.tiles[t]) }
            var tile = s.tiles[t] ?? TerrainTile(cells: n)
            s.tiles[t] = nil
            if tile.paint == nil || tile.mask == nil {
                tile.paint = [UInt8](repeating: 0, count: n * n * TerrainTile.layers)
                tile.mask = [UInt8](repeating: 0, count: n * n)
            }
            for j in a.y...c.y {
                for i in a.x...c.x {
                    let wgt = b.falloff(Float(simd_distance(grid.place(i, j), dab.center) / radius)) * min(b.strength * dab.amount, 1)
                    guard wgt > 0 else { continue }
                    let k = (j - first.y) * n + (i - first.x), mask = Float(tile.mask![k]) / 255
                    if b.tool == .erase {
                        tile.mask![k] = UInt8((mask * (1 - wgt) * 255).rounded())
                        continue
                    }
                    var visible: SIMD16<Float>
                    if mask >= 1 {
                        visible = SIMD16(tile.paint![(k * TerrainTile.layers)..<((k + 1) * TerrainTile.layers)].map { Float($0) / 255 })
                    } else {
                        let dx = at(i + 1, j) - at(i - 1, j), dz = at(i, j + 1) - at(i, j - 1)
                        let slope = atan((dx * dx + dz * dz).squareRoot() / (2 * grid.cell)) * 180 / .pi
                        visible = weights(reading, layers: layers, i, j, height: at(i, j), slope: slope)
                    }
                    for l in 0..<TerrainTile.layers { visible[l] = l == layer ? visible[l] + (1 - visible[l]) * wgt : visible[l] * (1 - wgt) }
                    let sum = max(visible.sum(), 1e-6)
                    for l in 0..<TerrainTile.layers { tile.paint![k * TerrainTile.layers + l] = UInt8((visible[l] / sum * 255).rounded()) }
                    tile.mask![k] = 255
                }
            }
            tile.changed(a &- first, c &- first, cells: n)
            s.tiles[t] = tile
            touched.insert(t)
        }
        return touched
    }
}

extension SIMD16 where Scalar == Float {
    package init(_ bytes: SIMD16<UInt8>) {
        self.init()
        for l in 0..<16 { self[l] = Float(bytes[l]) }
    }
    package init(_ values: [Float]) {
        self.init()
        for l in 0..<Swift.min(values.count, 16) { self[l] = values[l] }
    }
}
