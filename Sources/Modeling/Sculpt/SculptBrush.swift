import Foundation
import simd

/// Sculpt mode's brushes, as Blender's.
package enum SculptBrushKind: String, CaseIterable, Codable, Identifiable {
    case draw, clayStrips, inflate, smooth, grab, crease, flatten, pinch, mask, drawFaceSets
    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .draw: "Draw"
        case .clayStrips: "Clay Strips"
        case .inflate: "Inflate"
        case .smooth: "Smooth"
        case .grab: "Grab"
        case .crease: "Crease"
        case .flatten: "Flatten"
        case .pinch: "Pinch"
        case .mask: "Mask"
        case .drawFaceSets: "Draw Face Sets"
        }
    }

    package var symbol: String {
        switch self {
        case .draw: "paintbrush.pointed"
        case .clayStrips: "rectangle.stack"
        case .inflate: "circle.circle"
        case .smooth: "drop"
        case .grab: "hand.raised"
        case .crease: "line.diagonal"
        case .flatten: "minus.square"
        case .pinch: "arrow.down.right.and.arrow.up.left"
        case .mask: "theatermasks"
        case .drawFaceSets: "square.grid.3x3.fill"
        }
    }

    package var shortcut: String {
        switch self {
        case .draw: "X"
        case .clayStrips: "C"
        case .inflate: "I"
        case .smooth: "S"
        case .grab: "G"
        case .crease: "Shift C"
        case .flatten: "Shift T"
        case .pinch: "P"
        case .mask: "M"
        case .drawFaceSets: ""
        }
    }

    var code: Int32 { Int32(SculptBrushKind.allCases.firstIndex(of: self)!) }
}

/// A brush's settings (the tool settings in the header and the sidebar).
package struct SculptBrush: Equatable, Codable {
    package var kind: SculptBrushKind = .draw
    /// On screen, in points.
    package var radius: Float = 50
    package var strength: Float = 0.5
    package var falloff: ProportionalFalloff = .smooth
    package var pressureRadius = false
    package var pressureStrength = true
    /// Between dabs, a share of the radius.
    package var spacing: Float = 0.1
    package var autosmooth: Float = 0
    /// Mirror across the object's X, Y, Z (Blender's symmetry; X on by default).
    package var symmetry: [Bool] = [true, false, false]
    /// Subtract instead of add (Ctrl inverts while held).
    package var subtract = false
    /// The face set Draw Face Sets paints (a new one per stroke when 0).
    package var faceSet: Int32 = 0

    package init(kind: SculptBrushKind = .draw) {
        self.kind = kind
        if kind == .smooth { strength = 0.5 }
        if kind == .mask { strength = 1 }
        if kind == .grab { strength = 1 }
    }
}

/// One dab as the kernels see it (object space).
package struct SculptDab {
    package var center: SIMD3<Float>
    package var radius: Float
    package var normal: SIMD3<Float>
    package var planeCenter: SIMD3<Float>
    package var strength: Float     // signed: subtract is negative
    package var kind: Int32
}

/// The falloff as a table of 256 (x = distance / radius).
package func sculptFalloffTable(_ f: ProportionalFalloff) -> [Float] {
    (0..<256).map { f.weight(Float($0) / 255) }
}

/// A dab on vertices `start..<end` (the brushes that move each vertex by itself; smooth and grab have their own).
/// Masked vertices move less (by their mask); the mask brush paints the mask.
@inline(never)
func sculptDabKernel(_ p: UnsafeMutablePointer<SIMD4<Float>>, _ n: UnsafePointer<SIMD4<Float>>, _ start: Int, _ end: Int,
                     _ dab: SculptDab, _ falloff: UnsafePointer<Float>) {
    let r2 = dab.radius * dab.radius
    let inv = 1 / max(dab.radius, 1e-12)
    let c = dab.center, nrm = dab.normal, s = dab.strength, r = dab.radius
    let kind = dab.kind
    var v = start
    while v < end {
        let q = p[v]
        var pos = SIMD3(q.x, q.y, q.z)
        let d = pos - c
        let dd = simd_length_squared(d)
        if dd < r2 {
            let x = dd.squareRoot() * inv
            var f = falloff[min(255, Int(x * 255))]
            if kind == 8 {   // mask
                p[v].w = min(1, max(0, q.w + s * f))
                v &+= 1
                continue
            }
            f *= 1 - q.w
            switch kind {
            case 0:   // draw
                pos += nrm * (s * r * 0.05 * f)
            case 1:   // clay strips: up to a plane above the surface, filling below it
                let plane = dab.planeCenter + nrm * (r * 0.1 * (s >= 0 ? 1 : -1))
                let h = simd_dot(pos - plane, nrm)
                if (s >= 0 && h < 0) || (s < 0 && h > 0) { pos -= nrm * (h * f * min(1, abs(s)) * 0.5) }
            case 2:   // inflate: along the vertex's own normal
                let vn = n[v]
                pos += SIMD3(vn.x, vn.y, vn.z) * (s * r * 0.03 * f)
            case 5:   // crease: in, and pinched toward the stroke
                let t = d - nrm * simd_dot(d, nrm)
                pos += -nrm * (s * r * 0.04 * f * f) - t * (0.12 * abs(s) * f)
            case 6:   // flatten: toward the plane under the brush
                let h = simd_dot(pos - dab.planeCenter, nrm)
                pos -= nrm * (h * f * min(1, abs(s)) * 0.5 * (s >= 0 ? 1 : -1))
            case 7:   // pinch: toward the centre, along the surface
                let t = d - nrm * simd_dot(d, nrm)
                pos -= t * (0.25 * s * f)
            default: break
            }
            p[v] = SIMD4(pos, q.w)
        }
        v &+= 1
    }
}

/// Smooth, first half: where each vertex in the dab would go (toward its neighbours' mean), into `target`; the
/// positions aren't changed, so the leaves can do it at the same time.
@inline(never)
func sculptSmoothTargets(_ p: UnsafePointer<SIMD4<Float>>, _ target: UnsafeMutablePointer<SIMD4<Float>>, _ vnStart: UnsafePointer<Int32>,
                         _ vnList: UnsafePointer<Int32>, _ start: Int, _ end: Int, _ dab: SculptDab, _ falloff: UnsafePointer<Float>) {
    let r2 = dab.radius * dab.radius
    let inv = 1 / max(dab.radius, 1e-12)
    let s = min(1, abs(dab.strength))
    var v = start
    while v < end {
        let q = p[v]
        let pos = SIMD3(q.x, q.y, q.z)
        let dd = simd_length_squared(pos - dab.center)
        if dd < r2 {
            var sum = SIMD3<Float>.zero
            var k = Int(vnStart[v])
            let e = Int(vnStart[v + 1])
            let count = e - k
            while k < e {
                let o = p[Int(vnList[k])]
                sum += SIMD3(o.x, o.y, o.z)
                k &+= 1
            }
            if count > 0 {
                let f = falloff[min(255, Int(dd.squareRoot() * inv * 255))] * (1 - q.w) * s
                target[v] = SIMD4(pos + (sum / Float(count) - pos) * f, q.w)
            } else {
                target[v] = q
            }
        } else {
            target[v] = q
        }
        v &+= 1
    }
}

/// Smooth, second half: the targets written back.
@inline(never)
func sculptCopyRange(_ from: UnsafePointer<SIMD4<Float>>, _ to: UnsafeMutablePointer<SIMD4<Float>>, _ start: Int, _ end: Int) {
    var v = start
    while v < end {
        to[v] = from[v]
        v &+= 1
    }
}

/// The area under the brush: its weighted normal and centre (the plane Flatten and Clay Strips work to), as sums.
@inline(never)
func sculptAreaSums(_ p: UnsafePointer<SIMD4<Float>>, _ n: UnsafePointer<SIMD4<Float>>, _ start: Int, _ end: Int, _ c: SIMD3<Float>,
                    _ r: Float) -> (normal: SIMD3<Float>, centre: SIMD3<Float>, weight: Float) {
    let r2 = r * r
    var ns = SIMD3<Float>.zero, cs = SIMD3<Float>.zero, w: Float = 0
    var v = start
    while v < end {
        let q = p[v]
        let pos = SIMD3(q.x, q.y, q.z)
        let dd = simd_length_squared(pos - c)
        if dd < r2 {
            let f = 1 - dd / r2
            let vn = n[v]
            ns += SIMD3(vn.x, vn.y, vn.z) * f
            cs += pos * f
            w += f
        }
        v &+= 1
    }
    return (ns, cs, w)
}
