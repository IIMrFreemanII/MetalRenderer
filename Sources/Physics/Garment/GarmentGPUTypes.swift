import Metal
import simd

// The garment solver's structs shared with Shaders/Garment.metal (MSL structs of the same name, the same layout:
// validateGPULayouts checks them, and the MSL side asserts their sizes).

/// One of the solver's constraints (MSL GarmentConstraint): a few particles and what holds them, by kind.
///   tri:   v = (a, b, c, -); a = the inverse of the rest shape in the grain's frame (m00, m01, m10, m11);
///          b = compliance along the warp, the weft, in shear; rest area
///   bend:  v = (opposite 1, opposite 2, edge start, edge end); a = (compliance, rest angle, -, -); b.x = 1 across a seam
///          (its compliance times the seams' bending scale: off while they close)
///   seam:  v = (a, b0, b1, -): a to the point `w` of the way from b0 to b1; a = (w, rest length, compliance, -)
///   link:  v = (a, b, -, -): a distance; a = (rest length, compliance, -, -)
package struct GPUGarmentConstraint: Equatable {
    package var v = SIMD4<UInt32>()
    package var info = SIMD4<UInt32>()    // x = kind (GarmentConstraintKind), y = colour, zw = 0
    package var a = SIMD4<Float>()
    package var b = SIMD4<Float>()

    package init(v: SIMD4<UInt32> = .zero, kind: GarmentConstraintKind, a: SIMD4<Float> = .zero, b: SIMD4<Float> = .zero) {
        self.v = v
        self.info = SIMD4(kind.rawValue, 0, 0, 0)
        self.a = a
        self.b = b
    }
    package var kind: GarmentConstraintKind { GarmentConstraintKind(rawValue: info.x) ?? .link }
}

package enum GarmentConstraintKind: UInt32 {
    case tri = 0, bend = 1, seam = 2, link = 3
}

/// What a step needs (MSL GarmentParams).
package struct GPUGarmentParams {
    package var gravity = SIMD4<Float>(0, -9.81, 0, 0)  // w = dt of a substep
    package var counts = SIMD4<UInt32>()                // x = particles, y = constraints, z = this colour's first, w = its count
    package var collide = SIMD4<Float>()                // x = the cloth's thickness, y = friction, z = the body's margin, w = damping (per second)
    package var seams = SIMD4<Float>(0, 0, 1, 0)        // x = the seams' compliance now (their ramp), y = self-collision distance,
                                                        // z = bending across seams' compliance scale (huge while they close)
    package var grab = SIMD4<Float>()                   // the held particle's target; w = 1 while one is held
    package var grabInfo = SIMD4<UInt32>()              // x = the held particle, y = the body's SDF (1: there is one), z = triangles of the skinned body, w = -
    package var sdfLo = SIMD4<Float>()                  // the body's SDF box: lo (w = its cell size)
    package var sdfHi = SIMD4<Float>()                  // hi (w = how far the body moved this frame's substep fraction: 0...1)
    package var floor = SIMD4<Float>(0, -1e9, 0, 0)     // y = the floor's height (a plane under it all)
    package var spheres = SIMD4<UInt32>()               // x = colliding spheres (GarmentSphere), yzw = 0

    package init() {}
}

/// A sphere or a capsule the cloth stays out of (a test's ball, the body's bones as a backstop): MSL GarmentSphere.
package struct GPUGarmentSphere {
    package var a = SIMD4<Float>()   // xyz = one end, w = radius
    package var b = SIMD4<Float>()   // xyz = the other end (a sphere: the same), w = friction

    package init(a: SIMD4<Float>, b: SIMD4<Float>) {
        self.a = a
        self.b = b
    }
}

extension GPUGarmentConstraint {
    /// The layouts the shader asserts (sizes in bytes), for validateGPULayouts.
    package static let expectedStrides: [(String, Int, Int)] = [
        ("GarmentConstraint", MemoryLayout<GPUGarmentConstraint>.stride, 64),
        ("GarmentParams", MemoryLayout<GPUGarmentParams>.stride, 160),
        ("GarmentSphere", MemoryLayout<GPUGarmentSphere>.stride, 32),
    ]
}
