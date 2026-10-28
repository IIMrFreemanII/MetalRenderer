import Foundation
import simd

/// The garment solver on the CPU: the reference the GPU's steps (Shaders/Garment.metal, GarmentSolverGPU) follow line
/// for line, for the tests and for a garment without a GPU. Small-step XPBD (Macklin et al. 2019): many substeps of
/// one iteration each, every constraint's lambda starting at 0. A substep: predict under gravity; each colour's
/// constraints in turn (no two of a colour share a particle: each colour's run in parallel on the GPU); the body,
/// the spheres and the floor pushed out of; velocities from the move, damped.
package struct GarmentSim {
    /// Each particle: where it is (w = inverse mass), where the substep has put it, its velocity.
    package var x: [SIMD4<Float>]
    package var p: [SIMD4<Float>]
    package var v: [SIMD4<Float>]
    package var constraints: [GPUGarmentConstraint]
    package var colourStarts: [Int]
    package var spheres: [GPUGarmentSphere] = []
    package var params = GPUGarmentParams()
    /// The body as a distance (negative inside), with its gradient: the editor's avatar.
    package var body: ((SIMD3<Float>) -> (Float, SIMD3<Float>))?

    package init(positions: [SIMD3<Float>], invMass: [Float], constraints: [GPUGarmentConstraint], colourStarts: [Int]) {
        x = zip(positions, invMass).map { SIMD4($0.0, $0.1) }
        p = x
        v = [SIMD4<Float>](repeating: .zero, count: positions.count)
        self.constraints = constraints
        self.colourStarts = colourStarts
        params.counts = SIMD4(UInt32(positions.count), UInt32(constraints.count), 0, 0)
        params.collide = SIMD4(0.003, 0.5, 0.004, 0.5)
        params.seams.x = 1e-9
    }

    package var positions: [SIMD3<Float>] { x.map { SIMD3($0.x, $0.y, $0.z) } }

    /// `substeps` substeps of `dt` (a frame's time) in all.
    package mutating func step(dt: Float, substeps: Int) {
        let h = dt / Float(substeps)
        params.gravity.w = h
        for _ in 0..<substeps {
            for i in x.indices { p[i] = GarmentStep.predict(x[i], v[i], params) }
            for k in 0..<(colourStarts.count - 1) {
                for c in colourStarts[k]..<colourStarts[k + 1] { GarmentStep.solve(constraints[c], &p, params) }
            }
            for i in x.indices {
                var q = p[i]
                GarmentStep.collide(&q, previous: x[i], spheres: spheres, params: params, body: body)
                p[i] = q
                (x[i], v[i]) = GarmentStep.finish(x[i], q, params)
            }
        }
    }
}

/// One substep's pieces, shared by the CPU solver and written again in MSL (Garment.metal's garment* functions).
package enum GarmentStep {
    package static func predict(_ x: SIMD4<Float>, _ v: SIMD4<Float>, _ params: GPUGarmentParams) -> SIMD4<Float> {
        guard x.w > 0 else { return x }
        let h = params.gravity.w
        var vel = SIMD3(v.x, v.y, v.z) + SIMD3(params.gravity.x, params.gravity.y, params.gravity.z) * h
        // Damping, per second.
        vel *= max(0, 1 - params.collide.w * h)
        return SIMD4(SIMD3(x.x, x.y, x.z) + vel * h, x.w)
    }

    /// Velocity from the substep's move; the new position.
    package static func finish(_ x: SIMD4<Float>, _ p: SIMD4<Float>, _ params: GPUGarmentParams) -> (SIMD4<Float>, SIMD4<Float>) {
        let h = params.gravity.w
        var vel = SIMD3(p.x - x.x, p.y - x.y, p.z - x.z) / h
        // No faster than 6 m/s (as garmentCollideKernel).
        let speed = simd_length(vel)
        if speed > 6 { vel *= 6 / speed }
        let q = SIMD3(x.x, x.y, x.z) + vel * h
        return (SIMD4(q, x.w), SIMD4(vel, 0))
    }

    @inline(__always) static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    package static func solve(_ c: GPUGarmentConstraint, _ p: inout [SIMD4<Float>], _ params: GPUGarmentParams) {
        let h2 = params.gravity.w * params.gravity.w
        switch c.kind {
        case .tri:
            let i0 = Int(c.v.x), i1 = Int(c.v.y), i2 = Int(c.v.z)
            var x0 = xyz(p[i0]), x1 = xyz(p[i1]), x2 = xyz(p[i2])
            let w0 = p[i0].w, w1 = p[i1].w, w2 = p[i2].w
            let m = c.a, area = c.b.w
            // Each column of F = [x1-x0, x2-x0] · Dm⁻¹ as a sum over the particles: its coefficients.
            let cu = SIMD3(-(m.x + m.z), m.x, m.z), cv = SIMD3(-(m.y + m.w), m.y, m.w)
            for k in 0..<3 {
                let fu = (x1 - x0) * m.x + (x2 - x0) * m.z, fv = (x1 - x0) * m.y + (x2 - x0) * m.w
                var C: Float, g0: SIMD3<Float>, g1: SIMD3<Float>, g2: SIMD3<Float>, alpha: Float
                if k < 2 {
                    let f = k == 0 ? fu : fv, cc = k == 0 ? cu : cv
                    let l = simd_length(f)
                    guard l > 1e-9 else { continue }
                    let n = f / l
                    C = l - 1
                    g0 = n * cc.x; g1 = n * cc.y; g2 = n * cc.z
                    alpha = k == 0 ? c.b.x : c.b.y
                } else {
                    C = simd_dot(fu, fv)
                    g0 = fv * cu.x + fu * cv.x; g1 = fv * cu.y + fu * cv.y; g2 = fv * cu.z + fu * cv.z
                    alpha = c.b.z
                }
                let denom = w0 * simd_length_squared(g0) + w1 * simd_length_squared(g1) + w2 * simd_length_squared(g2) + alpha / (area * h2)
                guard denom > 1e-12 else { continue }
                let dl = -C / denom
                x0 += g0 * (w0 * dl); x1 += g1 * (w1 * dl); x2 += g2 * (w2 * dl)
            }
            p[i0] = SIMD4(x0, w0); p[i1] = SIMD4(x1, w1); p[i2] = SIMD4(x2, w2)
        case .bend:
            let i1 = Int(c.v.x), i2 = Int(c.v.y), i3 = Int(c.v.z), i4 = Int(c.v.w)
            let x1 = xyz(p[i1]), x2 = xyz(p[i2]), x3 = xyz(p[i3]), x4 = xyz(p[i4])
            let w1 = p[i1].w, w2 = p[i2].w, w3 = p[i3].w, w4 = p[i4].w
            guard let (theta, g) = dihedral(x1, x2, x3, x4) else { return }
            var C = theta - c.a.y
            // (The shorter way round: an angle near ±π doesn't flip.)
            if C > .pi { C -= 2 * .pi } else if C < -.pi { C += 2 * .pi }
            let denom = w1 * simd_length_squared(g.0) + w2 * simd_length_squared(g.1) + w3 * simd_length_squared(g.2)
                + w4 * simd_length_squared(g.3) + c.a.x * (c.b.x > 0 ? params.seams.z : 1) / h2
            guard denom > 1e-12 else { return }
            let dl = -C / denom
            p[i1] = SIMD4(x1 + g.0 * (w1 * dl), w1); p[i2] = SIMD4(x2 + g.1 * (w2 * dl), w2)
            p[i3] = SIMD4(x3 + g.2 * (w3 * dl), w3); p[i4] = SIMD4(x4 + g.3 * (w4 * dl), w4)
        case .seam, .link:
            let seam = c.kind == .seam
            let ia = Int(c.v.x), ib0 = Int(c.v.y), ib1 = seam ? Int(c.v.z) : Int(c.v.y)
            let w = seam ? c.a.x : 0, rest = seam ? c.a.y : c.a.x
            let alpha = seam ? params.seams.x : c.a.y
            let xa = xyz(p[ia]), xb0 = xyz(p[ib0]), xb1 = xyz(p[ib1])
            let wa = p[ia].w, wb0 = p[ib0].w, wb1 = p[ib1].w
            let q = xb0 * (1 - w) + xb1 * w
            let d = xa - q, l = simd_length(d)
            guard l > 1e-9 else { return }
            let n = d / l, C = l - rest
            let k0 = 1 - w, k1 = w
            let denom = wa + wb0 * k0 * k0 + (ib1 != ib0 ? wb1 * k1 * k1 : 0) + alpha / h2
            guard denom > 1e-12 else { return }
            let dl = -C / denom
            p[ia] = SIMD4(xa + n * (wa * dl), wa)
            if ib1 == ib0 {
                p[ib0] = SIMD4(xb0 - n * (wb0 * dl), wb0)
            } else {
                p[ib0] = SIMD4(xb0 - n * (wb0 * k0 * dl), wb0)
                p[ib1] = SIMD4(xb1 - n * (wb1 * k1 * dl), wb1)
            }
        }
    }

    /// The signed angle between two triangles across their edge x3–x4 (x1, x2 their far corners; 0: flat) and its
    /// gradient at the four (Bridson et al. 2003).
    package static func dihedral(_ x1: SIMD3<Float>, _ x2: SIMD3<Float>, _ x3: SIMD3<Float>, _ x4: SIMD3<Float>)
        -> (Float, (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>))? {
        let e = x4 - x3, le = simd_length(e)
        let n1 = simd_cross(x1 - x3, x1 - x4), n2 = simd_cross(x2 - x4, x2 - x3)
        let l1 = simd_length_squared(n1), l2 = simd_length_squared(n2)
        guard le > 1e-9, l1 > 1e-18, l2 > 1e-18 else { return nil }
        let a = n1 / l1.squareRoot(), b = n2 / l2.squareRoot()
        let theta = atan2(simd_dot(simd_cross(a, b), e / le), simd_dot(a, b))
        let q1 = n1 / l1, q2 = n2 / l2
        let u1 = q1 * le, u2 = q2 * le
        let u3 = q1 * (simd_dot(x1 - x4, e) / le) + q2 * (simd_dot(x2 - x4, e) / le)
        let u4 = -q1 * (simd_dot(x1 - x3, e) / le) - q2 * (simd_dot(x2 - x3, e) / le)
        return (theta, (-u1, -u2, -u3, -u4))
    }

    /// The particle pushed out of the floor, the spheres and capsules, and the body (a distance and its gradient),
    /// keeping the cloth's thickness off each; friction takes the move along the surface down.
    package static func collide(_ q: inout SIMD4<Float>, previous x: SIMD4<Float>, spheres: [GPUGarmentSphere], params: GPUGarmentParams,
                                body: ((SIMD3<Float>) -> (Float, SIMD3<Float>))?) {
        guard q.w > 0 else { return }
        let thickness = params.collide.x, friction = params.collide.y
        var pos = xyz(q)
        let prev = xyz(x)
        func push(_ n: SIMD3<Float>, _ depth: Float, _ mu: Float) {
            pos += n * depth
            // Friction: the move since the substep began, along the surface, shortened.
            let move = pos - prev, tangent = move - n * simd_dot(move, n)
            let t = simd_length(tangent)
            if t > 1e-9 { pos -= tangent * min(1, mu * depth / t) }
        }
        if pos.y < params.floor.y + thickness { push(SIMD3(0, 1, 0), params.floor.y + thickness - pos.y, friction) }
        for s in spheres {
            let a = SIMD3(s.a.x, s.a.y, s.a.z), b = SIMD3(s.b.x, s.b.y, s.b.z), ab = b - a
            let l2 = simd_length_squared(ab)
            let t = l2 > 0 ? max(0, min(1, simd_dot(pos - a, ab) / l2)) : 0
            let d = pos - (a + ab * t), l = simd_length(d), r = s.a.w + thickness
            if l < r && l > 1e-9 { push(d / l, r - l, s.b.w) }
        }
        if let body {
            let margin = params.collide.z
            let (dist, grad) = body(pos)
            if dist < margin + thickness, simd_length_squared(grad) > 1e-12 {
                push(simd_normalize(grad), margin + thickness - dist, friction)
            }
        }
        q = SIMD4(pos, q.w)
    }
}
