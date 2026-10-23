import Foundation
import simd

/// The viewport shaders' structs (Shaders/Viewport.metal), byte for byte; `validateViewportLayouts` checks the strides.
package struct ViewUniforms {
    package var viewProj = matrix_identity_float4x4
    package var view = matrix_identity_float4x4
    package var invViewProj = matrix_identity_float4x4
    package var eye = SIMD4<Float>.zero
    package var viewDir = SIMD4<Float>.zero
    package var viewport = SIMD2<Float>.zero
    package var pixelScale: Float = 1
    package var gridScale: Float = 1
    package var background = SIMD4<Float>.zero
    package var flags = SIMD4<UInt32>.zero
}

package struct ViewVertex {
    package var x: Float, y: Float, z: Float
    package var normal: UInt32
    package var mask: Float
    package var faceSet: UInt32

    @inlinable package init(_ p: SIMD3<Float>, normal n: SIMD3<Float>, mask: Float = 0, faceSet: UInt32 = 0) {
        x = p.x; y = p.y; z = p.z
        normal = ViewVertex.octahedral(n)
        self.mask = mask
        self.faceSet = faceSet
    }

    /// A unit normal as two snorm16 (octahedral mapping).
    @inlinable package static func octahedral(_ n: SIMD3<Float>) -> UInt32 {
        let l1 = abs(n.x) + abs(n.y) + abs(n.z)
        var e = l1 > 0 ? SIMD2(n.x, n.y) / l1 : SIMD2<Float>(0, 0)
        if n.z < 0 {
            let s = SIMD2<Float>(e.x >= 0 ? 1 : -1, e.y >= 0 ? 1 : -1)
            e = (SIMD2<Float>(1, 1) - abs(SIMD2(e.y, e.x))) * s
        }
        let q = SIMD2<Int16>(clamping: SIMD2<Int32>((e * 32767).rounded(.toNearestOrEven)))
        return UInt32(UInt16(bitPattern: q.x)) | UInt32(UInt16(bitPattern: q.y)) << 16
    }
}

package struct ObjectUniforms {
    package var model = matrix_identity_float4x4
    package var normalMatrix = matrix_identity_float4x4
    package var color = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    package var wire = SIMD4<Float>(0, 0, 0, 1)
    package var shading: UInt32 = 0
    package var flags: UInt32 = 0
    package var matcap: UInt32 = 0
    package var objectID: UInt32 = 0

    package enum Flag {
        package static let selected: UInt32 = 1, active: UInt32 = 2, edit: UInt32 = 4, sculpt: UInt32 = 8
        package static let materialColors: UInt32 = 16, backfaceCull: UInt32 = 32, faceOrientation: UInt32 = 64
    }
}

package struct EditEdgeGPU {
    package var a: UInt32, b: UInt32, flags: UInt32, pad: UInt32 = 0
    package enum Flag {
        package static let select: UInt32 = 1, hide: UInt32 = 2, seam: UInt32 = 4, sharp: UInt32 = 8, crease: UInt32 = 16, active: UInt32 = 32
    }
}

/// A 3D line the overlay draws: constraint axes, the brush ring, the knife's cut, the 3D cursor.
package struct OverlayLine {
    package var a: SIMD4<Float>       // xyz; w: width in points
    package var b: SIMD4<Float>       // xyz; w: 1 dashed
    package var color: SIMD4<Float>   // linear, alpha

    package init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, color: SIMD4<Float>, width: Float = 1, dashed: Bool = false) {
        self.a = SIMD4(a, width)
        self.b = SIMD4(b, dashed ? 1 : 0)
        self.color = color
    }
}

/// A packed position (12 bytes, as the shaders' packed_float3).
package struct PackedFloat3 {
    package var x: Float, y: Float, z: Float
    @inlinable package init(_ p: SIMD3<Float>) { x = p.x; y = p.y; z = p.z }
}

package func validateViewportLayouts() {
    precondition(MemoryLayout<ViewUniforms>.stride == 272, "ViewUniforms")
    precondition(MemoryLayout<ViewVertex>.stride == 24, "ViewVertex")
    precondition(MemoryLayout<ObjectUniforms>.stride == 176, "ObjectUniforms")
    precondition(MemoryLayout<EditEdgeGPU>.stride == 16, "EditEdge")
    precondition(MemoryLayout<OverlayLine>.stride == 48, "OverlayLine")
    precondition(MemoryLayout<PackedFloat3>.stride == 12, "packed_float3")
}

/// sRGB to linear, for theme colours given as Blender's.
package func linearColor(_ hex: UInt32, alpha: Float = 1) -> SIMD4<Float> {
    func lin(_ c: UInt32) -> Float {
        let s = Float(c & 255) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return SIMD4(lin(hex >> 16), lin(hex >> 8), lin(hex), alpha)
}
