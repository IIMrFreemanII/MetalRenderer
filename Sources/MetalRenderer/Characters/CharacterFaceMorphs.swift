import Foundation
import simd

/// The face's morph targets: the face sliders' (the nose's length, the eyes' spacing, the jaw's width ...) and the
/// macros' (a woman's face, an old one, a heavy one, a thin one), each a movement of the skin near FaceSculpt's
/// landmarks. The eyeballs, teeth and tongue move whole, as the skin at their middles does.
extension CharacterMorphs {
    /// The face sliders, by target name: title and the group of the editor's Face tab.
    static let faceSliders: [(name: String, title: String, group: String)] = [
        ("eyeSpacing", "Spacing", "Eyes"), ("eyeHeight", "Height", "Eyes"), ("eyeSize", "Opening", "Eyes"),
        ("eyeTilt", "Tilt", "Eyes"), ("eyeDepth", "Deep-set", "Eyes"),
        ("browHeight", "Brow height", "Brows"), ("browRidge", "Brow ridge", "Brows"),
        ("noseLength", "Length", "Nose"), ("noseWidth", "Width", "Nose"), ("noseBridge", "Bridge", "Nose"), ("noseTip", "Tip up", "Nose"),
        ("mouthWidth", "Width", "Mouth"), ("lips", "Fullness", "Mouth"), ("mouthHeight", "Height", "Mouth"),
        ("cheekbones", "Cheekbones", "Jaw and cheeks"), ("cheeks", "Cheeks", "Jaw and cheeks"), ("jawWidth", "Jaw width", "Jaw and cheeks"),
        ("chin", "Chin forward", "Jaw and cheeks"), ("chinHeight", "Chin length", "Jaw and cheeks"),
        ("earSize", "Size", "Ears"), ("earsOut", "Sticking out", "Ears"),
    ]
    /// The macros' face targets (MacroRig): a woman's, an old, a heavy and a thin face.
    static let faceMacros = ["faceFemale", "faceOld", "faceFat", "faceThin"]

    static func faceTargets(_ base: CharacterBase, sculpt: FaceSculpt) -> [Target] {
        let c = base.character
        let regions = base.regions.map { CharacterBase.Region(rawValue: $0) ?? .trunk }
        // Each separate part's middle (the sculpt's space): it moves as the skin there.
        var middles: [CharacterBase.Region: SIMD3<Float>] = [:]
        for part in [CharacterBase.Region.leftEye, .rightEye, .upperTeeth, .lowerTeeth, .tongue] {
            let mine = regions.indices.filter { regions[$0] == part }
            guard !mine.isEmpty else { continue }
            middles[part] = sculpt.local(mine.reduce(SIMD3<Float>()) { $0 + c.positions[$1] } / Float(mine.count))
        }
        let names = faceSliders.map(\.name) + faceMacros
        var out = [Target](repeating: Target(name: "", vertices: [], deltas: []), count: names.count)
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: names.count) { k in
                var t = Target(name: names[k], vertices: [], deltas: [])
                for v in c.positions.indices {
                    let q = sculpt.local(c.positions[v])
                    guard q.y > 1.53 else { continue }
                    let d: SIMD3<Float>
                    if let middle = middles[regions[v]] { d = faceShape(names[k], middle, .zero) }
                    else { d = faceShape(names[k], q, c.normals[v]) }
                    if simd_length_squared(d) > 1e-12 {
                        t.vertices.append(UInt32(v))
                        t.deltas.append(d * sculpt.scale)
                    }
                }
                o[k] = t
            }
        }
        return out
    }

    /// 1 within `inner` of `c`, easing to 0 by `outer`: a part moved whole with what is round it.
    @inline(__always) static func plateau(_ q: SIMD3<Float>, _ c: SIMD3<Float>, _ inner: Float, _ outer: Float) -> Float {
        1 - FaceSculpt.smoothstep(inner, outer, simd_distance(q, c))
    }

    /// Target `name`'s movement of the skin at `q` (the sculpt's space, `n` its normal) at weight 1.
    static func faceShape(_ name: String, _ q: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> {
        let side: Float = q.x >= 0 ? 1 : -1
        let m = SIMD3(abs(q.x), q.y, q.z)
        let g = FaceRig.gauss
        let eye = SIMD3<Float>(FaceSculpt.eyeCentres[0].x, FaceSculpt.eyeCentres[0].y, FaceSculpt.eyeCentres[0].z)
        let ear = SIMD3<Float>(FaceSculpt.ears[0].x, FaceSculpt.ears[0].y, FaceSculpt.ears[0].z)
        let corner = SIMD3<Float>(FaceSculpt.mouthHalfWidth, 1.6135, 0.0905)
        let front = FaceSculpt.smoothstep(0.075, 0.09, q.z)
        // The lid's skin round an eye, and where on it (toward the side, up).
        let lids = g(m, eye + [0, 0, 0.012], [0.016, 0.012, 0.012]) * FaceSculpt.smoothstep(0.065, 0.078, q.z)
        let r = m - eye
        switch name {
        case "noseLength": return g(m, [0, 1.648, 0.112], [0.014, 0.016, 0.02]) * front * SIMD3(0, -0.005, 0.0025)
        case "noseWidth": return g(m, [0.0146, 1.6415, 0.098], [0.01, 0.01, 0.012]) * SIMD3(side * 0.0035, 0, 0)
        case "noseBridge": return g(m, [0, 1.672, 0.1], [0.01, 0.022, 0.025]) * FaceSculpt.smoothstep(0.082, 0.095, q.z) * SIMD3(0, 0, 0.004)
        case "noseTip": return g(m, [0, 1.65, 0.118], [0.011, 0.01, 0.014]) * SIMD3(0, 0.0035, -0.001)
        case "eyeSpacing": return plateau(m, eye, 0.019, 0.04) * SIMD3(side * 0.003, 0, 0)
        case "eyeHeight": return plateau(m, eye, 0.019, 0.04) * SIMD3(0, 0.003, 0)
        case "eyeDepth": return plateau(m, eye, 0.019, 0.038) * SIMD3(0, 0, -0.003)
        case "eyeSize": return lids * SIMD3(side * r.x * 0.12, (r.y - 0.0004) * 0.28, 0)
        case "eyeTilt": return lids * SIMD3(0, 0.0025 * min(max(r.x / 0.014, -1), 1), 0)
        case "browHeight": return g(m, [0.034, 1.703, 0.086], [0.024, 0.009, 0.025]) * SIMD3(0, 0.004, 0)
        case "browRidge": return g(m, [0.02, 1.703, 0.09], [0.035, 0.008, 0.02]) * SIMD3(0, 0.0005, 0.0035)
        case "cheekbones": return g(m, [0.053, 1.668, 0.058], [0.016, 0.012, 0.018]) * n * 0.004
        case "cheeks": return g(m, [0.043, 1.633, 0.06], [0.02, 0.022, 0.022]) * n * 0.005
        case "jawWidth": return g(m, [0.049, 1.607, 0.005], [0.022, 0.025, 0.03]) * SIMD3(side * 0.006, 0, 0)
        case "chin": return g(m, [0, 1.582, 0.093], [0.016, 0.014, 0.016]) * SIMD3(0, -0.001, 0.005)
        case "chinHeight": return g(m, [0, 1.575, 0.085], [0.03, 0.016, 0.03]) * SIMD3(0, -0.005, 0.0005)
        case "mouthWidth": return g(m, corner, [0.01, 0.008, 0.012]) * SIMD3(side * 0.0035, 0, -0.0008)
        case "lips":
            var a = q
            a.z += 15 * a.x * a.x
            return g(m, [0.006, 1.6145, 0.1], [0.022, 0.009, 0.012]) * FaceSculpt.smoothstep(0.088, 0.094, a.z) * n * 0.0022
        case "mouthHeight": return g(m, [0, 1.6145, 0.095], [0.03, 0.012, 0.03]) * SIMD3(0, 0.003, 0)
        case "earSize":
            let e = m - ear
            return g(m, ear, [0.018, 0.03, 0.018]) * SIMD3(side * e.x, e.y, e.z) * 0.18
        case "earsOut":
            return g(m, ear, [0.016, 0.03, 0.016]) * FaceSculpt.smoothstep(ear.z - 0.004, ear.z - 0.02, q.z) * SIMD3(side * 0.006, 0, 0)
        case "faceFemale":
            return combine(q, n, ["browRidge": -1, "jawWidth": -0.9, "chin": -0.5, "chinHeight": -0.4, "noseLength": -0.6, "noseWidth": -0.7,
                                  "noseBridge": -0.3, "lips": 0.9, "mouthWidth": -0.3, "browHeight": 0.7, "eyeSize": 0.5, "cheekbones": 0.4,
                                  "cheeks": 0.5, "earSize": -0.4])
                + g(m, [0, 1.735, 0.08], [0.04, 0.025, 0.03]) * SIMD3(0, 0, 0.003)
        case "faceOld":
            return combine(q, n, ["noseLength": 0.6, "earSize": 0.7, "lips": -0.8, "eyeDepth": 0.6, "browHeight": -0.5])
                + g(m, [0.043, 1.633, 0.06], [0.02, 0.022, 0.022]) * SIMD3(0, -0.006, -0.0015)
                + g(m, [0.04, 1.595, 0.06], [0.018, 0.012, 0.02]) * SIMD3(side * 0.003, -0.004, 0.0015)
                + g(m, [0.064, 1.705, 0.05], [0.012, 0.016, 0.016]) * n * -0.002
        case "faceFat":
            return combine(q, n, ["cheeks": 1.4, "jawWidth": 0.4])
                + g(m, [0, 1.567, 0.05], [0.035, 0.012, 0.035]) * SIMD3(0, -0.006, 0.004)
        case "faceThin":
            return combine(q, n, ["cheeks": -1, "cheekbones": 0.3, "jawWidth": -0.2])
                + g(m, [0.064, 1.705, 0.05], [0.012, 0.016, 0.016]) * n * -0.0015
        default:
            return .zero
        }
    }

    static func combine(_ q: SIMD3<Float>, _ n: SIMD3<Float>, _ parts: [String: Float]) -> SIMD3<Float> {
        parts.reduce(SIMD3<Float>()) { $0 + faceShape($1.key, q, n) * $1.value }
    }
}
