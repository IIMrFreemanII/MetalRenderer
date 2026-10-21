import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// A scene's water (Shaders/Water.metal): the looks of its bodies, its surfaces' triangles, and where the water is
/// (the field the renderer's water map is drawn from, in the world's x, z; `offset` the world's place of the scene's
/// origin). The surfaces are not among the scene's instances: the water's rays meet them in a structure of their own
/// (WaterSystem), and no other ray need walk past them (a sea's sheet under a whole terrain would cost every ray).
package final class SceneWater {
    var looks: [WaterLook] = []
    package var field: WaterField?
    var offset = SIMD2<Double>.zero
    /// Something that tells the water map apart from the last scene's (a terrain's document's version, its edits):
    /// the same key keeps the map that is drawn.
    package var key = ""
    /// The still surfaces' triangles (the scene's coordinates) and their looks: the water's own structure
    /// (WaterSystem), which the water's rays meet instead of the scene's.
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var triangleLooks: [UInt8] = []
    /// A terrain's: per water body of its document, the look it got (nil: it made nothing), to follow its edits.
    var bodyLooks: [Int?] = []
}

extension Scene {
    /// A look for water surfaces: its index in the scene's looks.
    package func addWaterLook(_ look: WaterLook) -> Int {
        let w = water ?? SceneWater()
        water = w
        w.looks.append(look)
        hasWater = true
        return w.looks.count - 1
    }

    /// A water surface: `geometry`'s triangles (the scene's coordinates) of a look (addWaterLook), into the water's
    /// own structure.
    package func addWaterSurface(_ geometry: MeshGeometry, look: Int) {
        let w = water ?? SceneWater()
        water = w
        let base = UInt32(w.positions.count)
        w.positions += geometry.positions
        w.indices += geometry.indices.map { $0 + base }
        w.triangleLooks += [UInt8](repeating: UInt8(min(look, 254)), count: geometry.indices.count / 3)
    }
}

extension Scene {
    /// A pool's still water at `level` over `outline` (a convex polygon of x, z, either way round), its floor at
    /// `floor` (its rim is the scene's to build): its surface, and where it is for the water map (`key` tells the map
    /// apart from other scenes').
    package func addPoolWater(_ outline: [SIMD2<Float>], level: Float, floor: Float, look: WaterLook = .preset(.pool), key: String) {
        guard !WaterSystem.off, outline.count >= 3 else { return }
        let index = addWaterLook(look)
        let centre = outline.reduce(.zero, +) / Float(outline.count)
        var positions = [SIMD3(centre.x, level, centre.y)], indices: [UInt32] = []
        // (A fan facing up whichever way the outline goes round.)
        let turn = outline.indices.reduce(Float(0)) { s, i in
            let a = outline[i], b = outline[(i + 1) % outline.count]
            return s + (a.x * b.y - b.x * a.y)
        }
        for (i, p) in outline.enumerated() {
            positions.append(SIMD3(p.x, level, p.y))
            let a = UInt32(i + 1), b = UInt32((i + 1) % outline.count + 1)
            indices += turn > 0 ? [0, b, a] : [0, a, b]
        }
        addWaterSurface((positions, [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count), indices), look: index)
        let lo = outline.reduce(SIMD2(repeating: Float.infinity), simd_min), hi = outline.reduce(SIMD2(repeating: -Float.infinity), simd_max)
        let sign: Float = turn > 0 ? 1 : -1
        water?.field = LevelWaterField(level: level, look: index, lo: SIMD2<Double>(lo), hi: SIMD2<Double>(hi)) { x, z in
            let q = SIMD2(Float(x), Float(z))
            let inside = outline.indices.allSatisfy { i in
                let a = outline[i], b = outline[(i + 1) % outline.count]
                return sign * ((b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)) >= 0
            }
            return inside ? floor : level + 1
        }
        water?.key = key
    }

    /// The open world's water around this scene (World+Water.swift): the sea's sheet over the scene's tiles where any
    /// of their ground is under it, the rivers' ribbons and the lakes' sheets that are in them (the scene's
    /// coordinates: `anchor` is the world's place of its origin); and where it all is, for the water map.
    package func addWorldWater(_ world: World, tiles: [SIMD2<Int>], anchor: SIMD2<Double>) {
        guard !WaterSystem.off, !tiles.isEmpty else { return }
        section("Water")
        let side = Double(World.tileSize), w = world.water
        let lo = SIMD2(Double(tiles.map(\.x).min()!), Double(tiles.map(\.y).min()!)) * side
        let hi = (SIMD2(Double(tiles.map(\.x).max()!), Double(tiles.map(\.y).max()!)) + 1) * side
        let sea = addWaterLook(.preset(.ocean)), lake = addWaterLook(.preset(.lake)), river = addWaterLook(.preset(.river))
        func local(_ p: SIMD2<Double>, _ y: Float) -> SIMD3<Float> { SIMD3(Float(p.x - anchor.x), y, Float(p.y - anchor.y)) }

        // The sea, where some of the square's ground is under it (a sample every 64 m).
        var under = false
        var z = lo.y
        while z <= hi.y && !under {
            var x = lo.x
            while x <= hi.x && !under { under = w.natural(x, z) < w.seaLevel; x += 64 }
            z += 64
        }
        if under {
            addWaterSurface(TerrainWater.plane(from: lo, to: hi, level: w.seaLevel, offset: anchor).0, look: sea)
        }

        let (edges, chains, lakes) = w.contents(lo: lo, hi: hi)
        // Each river's chain of steps, a ribbon a little narrower than its channel, at its surface's height.
        var ribbons = 0
        for chain in chains {
            var points: [SIMD2<Double>] = [], halves: [Float] = [], levels: [Float] = []
            for k in chain {
                let e = edges[k]
                points.append(e.a); halves.append(e.half); levels.append(e.level.0)
            }
            if let last = chain.last {
                points.append(edges[last].b); halves.append(edges[last].half); levels.append(edges[last].level.1)
            }
            guard points.count > 1 else { continue }
            var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
            for k in points.indices {
                let a = points[max(k - 1, 0)], b = points[min(k + 1, points.count - 1)]
                let d = simd_normalize(b - a), across = SIMD2(-d.y, d.x) * Double(halves[k] * 0.95)
                positions.append(local(points[k] - across, levels[k]))
                positions.append(local(points[k] + across, levels[k]))
                if k > 0 {
                    let base = UInt32(positions.count - 4)
                    indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
                }
            }
            addWaterSurface((positions, [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count), indices), look: river)
            ribbons += 1
        }
        // Each pond, a disc of water over its bowl (out to its rim).
        for o in lakes {
            let segments = 48, r = Double(o.radius) * 1.15
            var positions = [local(o.center, o.level)], indices: [UInt32] = []
            for k in 0..<segments {
                let a = Double(k) / Double(segments) * 2 * .pi, p = o.center + SIMD2(cos(a), sin(a)) * r
                positions.append(local(p, o.level))
                indices += [0, UInt32(1 + (k + 1) % segments), UInt32(1 + k)]
            }
            addWaterSurface((positions, [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count), indices), look: lake)
        }
        guard let water else { return }
        water.field = WorldWaterField(world: world, looks: (sea, lake, river))
        water.offset = anchor
        // (One map for every scene of the world: it follows the camera, and is drawn again only where it has gone.)
        water.key = "world \(world.seed)"
        print(String(format: "World water: sea at %.1f m%@, %d rivers, %d ponds", w.seaLevel, under ? " (in sight)" : "", ribbons, lakes.count))
    }
}
