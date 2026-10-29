import EngineCore
import simd

extension Growth {
    /// The light a growing plant lets through to its own buds: a voxel grid of the shadow it casts (shadow
    /// propagation, after Palubicki et al.'s self-organising trees). Each bud shades a pyramid of cells below it,
    /// halving with every cell down; a bud's light is what the cell above it is left with, and its light direction
    /// leads away from the shadow and up. (Unreal's grower casts 64 rays per bud on the GPU; this is O(buds).)
    package struct LightField {
        let cell: Float
        let half: Int                               // cells from the axis to either side
        let tall: Int                               // cells up from the ground
        var shadow: [Float]
        static let depth = 5                        // how many cells down a bud's shadow reaches
        static let wood: Float = 0.15               // a bare point's shadow
        static let leaves: Float = 0.45             // and its leaves', times Light.leafDensity, on young wood

        package init(height: Float, cell: Float) {
            self.cell = cell
            half = max(4, Int((height * 0.9 / cell).rounded(.up)))
            tall = max(6, Int((height * 1.6 / cell).rounded(.up)) + LightField.depth + 2)
            shadow = [Float](repeating: 0, count: (2 * half + 1) * (2 * half + 1) * tall)
        }

        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int? {
            guard abs(x) <= half, abs(z) <= half, y >= 0, y < tall else { return nil }
            return ((y * (2 * half + 1)) + (z + half)) * (2 * half + 1) + (x + half)
        }

        func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int> {
            SIMD3(Int((p.x / cell).rounded()), Int((p.y / cell).rounded(.down)), Int((p.z / cell).rounded()))
        }

        func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
            guard let i = index(x, y, z) else { return y < 0 ? 1e3 : 0 }   // (below the ground: dark)
            return shadow[i]
        }

        /// A bud's light, 1 in the open, and the way toward more of it.
        func light(at p: SIMD3<Float>, up: SIMD3<Float>, scale: Float) -> (light: Float, direction: SIMD3<Float>) {
            let c = cellOf(p)
            let s = value(c.x, c.y + 1, c.z)
            let light = min(max(1 - s / scale, 0), 1)
            let gradient = SIMD3<Float>(value(c.x + 1, c.y, c.z) - value(c.x - 1, c.y, c.z),
                                        value(c.x, c.y + 1, c.z) - value(c.x, c.y - 1, c.z),
                                        value(c.x, c.y, c.z + 1) - value(c.x, c.y, c.z - 1))
            // Out from under the shade, sideways, and always up: light comes from the sky. (Shadow fades downward, so its
            // vertical gradient would lead a shaded bud to the ground.)
            let side = gradient - up * dot(gradient, up)
            let toward = -side / max(scale, 1e-3) + up * (0.35 + 0.65 * light)
            return (light, length_squared(toward) < 1e-8 ? up : normalize(toward))
        }

        /// Casts the shadow of every living point, then reads each one's light.
        mutating func measure(_ points: inout [Point], _ params: Light, up: SIMD3<Float>) {
            let half = self.half, tall = self.tall, cell = self.cell, side = 2 * half + 1
            shadow.withUnsafeMutableBufferPointer { s in
                for i in s.indices { s[i] = 0 }
                for point in points where !point.removed {
                    let p = point.position
                    let c = SIMD3(Int((p.x / cell).rounded()), Int((p.y / cell).rounded(.down)), Int((p.z / cell).rounded()))
                    // Bare wood shades little (a trunk barely darkens its own buds); young wood carries leaves and shades
                    // much more.
                    let w: Float = LightField.wood + LightField.leaves * params.leafDensity * (1 - point.ethylene)
                    var a = w
                    for q in 0...LightField.depth {
                        let y = c.y - q
                        if y < 0 { break }
                        let z0 = max(c.z - q, -half), z1 = min(c.z + q, half), x0 = max(c.x - q, -half), x1 = min(c.x + q, half)
                        if y < tall && z0 <= z1 && x0 <= x1 {
                            for z in z0...z1 {
                                let row = (y * side + (z + half)) * side
                                for x in x0...x1 { s[row + x + half] += a }
                            }
                        }
                        a *= 0.5
                    }
                }
            }
            let up = normalize(up)
            for i in points.indices where !points[i].removed {
                let l = light(at: points[i].position, up: up, scale: params.shadow)
                points[i].light = l.light
                points[i].lightDirection = l.direction
            }
        }
    }
}
