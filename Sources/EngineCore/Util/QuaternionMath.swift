import simd

// Quaternions as SIMD4 (xyz the axis part, w the scalar), as the physics and its shaders keep them. Inlinable free
// functions: the scene's per-body loops call them from other modules (PhysicsMath forwards to them).

/// `v` without its w.
@inlinable @inline(__always) package func dropW(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

/// `a` then `b`, as one rotation (Hamilton product).
@inlinable @inline(__always) package func quatMultiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
    let av = dropW(a), bv = dropW(b)
    return SIMD4(a.w * bv + b.w * av + cross(av, bv), a.w * b.w - dot(av, bv))
}

/// `v` turned by `q`.
@inlinable @inline(__always) package func quatRotate(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
    let u = dropW(q)
    let t = 2 * cross(u, v)
    return v + q.w * t + cross(u, t)
}

/// The inverse rotation of a unit quaternion.
@inlinable @inline(__always) package func quatConjugate(_ q: SIMD4<Float>) -> SIMD4<Float> { SIMD4(-q.x, -q.y, -q.z, q.w) }

/// `q` as simd's quaternion.
@inlinable @inline(__always) package func quatToSIMD(_ q: SIMD4<Float>) -> simd_quatf { simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w) }
