import Characters
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import simd

extension Scene {
    // MARK: - Emissive-mesh lights

    /// A light that comes with a borrowed mesh, made already: sampled as the scene's own emissive instances are.
    package func addMeshLight(_ light: BorrowedLight) { borrowedLights.append(light) }

    /// Every geometry instance with an emissive material becomes a mesh light (after the analytic lights, which
    /// assignLightGroups has sorted): its triangles, each weighted by area x emitted luminance (an emissive texture's
    /// luminance from a small decoded copy), and the bounding sphere / mean normal proxy the shaders weigh it by.
    package func buildMeshLights() {
        // (A borrowed mesh's lights may be off as the scene is made: the open world's by day.)
        guard !borrowedLights.isEmpty || materials.contains(where: { $0.emission.x > 0 || $0.emission.y > 0 || $0.emission.z > 0 }) else { return }
        emissiveTriangles.reserveCapacity(borrowedLights.reduce(0) { $0 + $1.range.count })
        var textureCache: [Int: ((SIMD2<Float>) -> SIMD3<Float>)?] = [:]
        func emissiveTexture(_ index: UInt32) -> ((SIMD2<Float>) -> SIMD3<Float>)? {
            guard index != .max else { return nil }
            if let cached = textureCache[Int(index)] { return cached }
            let sampler = Scene.thumbnailSampler(textures[Int(index)].data)
            textureCache[Int(index)] = sampler
            return sampler
        }
        var flagged = Set<Int>()
        let lent = Set(borrowed.map(\.mesh))   // their lights come with them (`addMeshLight`)
        var sdfLights: [Int: (positions: [SIMD3<Float>], indices: [UInt32], materials: [Int])] = [:]
        for (i, inst) in instances.enumerated() where inst.isGeometry && !inst.deforms {
            if inst.sdf >= 0 {
                // An SDF shape: a light per material of its that emits, its triangles those of the shape's surface
                // (made once per shape, just outside it: SDFShape.triangles) where that material is.
                let shape = sdfShapes[inst.sdf]
                for offset in 0..<shape.materialCount {
                    let e = materials[inst.material + offset].emission
                    let le = SIMD3(e.x, e.y, e.z)
                    guard le.max() > 0 else { continue }
                    if sdfLights[inst.sdf] == nil { sdfLights[inst.sdf] = shape.triangles(volumes: sdfVolumes) }
                    let mesh = sdfLights[inst.sdf]!
                    var draft = MeshLightDraft()
                    for t in mesh.materials.indices where mesh.materials[t] == offset {
                        draft.add(mesh.positions[Int(mesh.indices[3 * t])], mesh.positions[Int(mesh.indices[3 * t + 1])],
                                  mesh.positions[Int(mesh.indices[3 * t + 2])], emission: le)
                    }
                    guard var light = draft.finish(instance: i, firstTriangle: emissiveTriangles.count) else { continue }
                    light.materialOffset = offset
                    emissiveTriangles += draft.triangles
                    meshLights.append(light)
                    lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
                    flagged.insert(inst.material + offset)
                }
                continue
            }
            let material = materials[inst.material]
            let factor = SIMD3(material.emission.x, material.emission.y, material.emission.z)
            guard factor.max() > 0 else { continue }
            let positions: [SIMD3<Float>], uvsOf: [SIMD2<Float>], tris: ArraySlice<UInt32>
            if let src = emitterSources[i] {
                (positions, uvsOf, tris) = (src.positions, src.uvs, src.indices[...])
            } else if inst.mesh >= 0, !lent.contains(inst.mesh), Int(meshes[inst.mesh].firstIndex) < indices.count {
                let m = meshes[inst.mesh]
                (positions, uvsOf, tris) = (self.positions, uvs, indices[Int(m.firstIndex) ..< Int(m.firstIndex + m.indexCount)])
            } else {
                continue
            }
            let texture = emissiveTexture(material.textures.w)
            var draft = MeshLightDraft()
            let t = Array(tris)
            for f in stride(from: 0, to: t.count - 2, by: 3) {
                let (a, b, c) = (Int(t[f]), Int(t[f + 1]), Int(t[f + 2]))
                let uv0 = a < uvsOf.count ? uvsOf[a] : .zero, uv1 = b < uvsOf.count ? uvsOf[b] : .zero
                let uv2 = c < uvsOf.count ? uvsOf[c] : .zero
                var le = factor
                if let texture {
                    le *= (texture((uv0 + uv1 + uv2) / 3) * 2 + texture(uv0) + texture(uv1) + texture(uv2)) / 5
                }
                draft.add(positions[a], positions[b], positions[c], uv0: uv0, uv1: uv1, uv2: uv2, emission: le)
            }
            guard let light = draft.finish(instance: i, firstTriangle: emissiveTriangles.count) else { continue }
            emissiveTriangles += draft.triangles
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
            flagged.insert(inst.material)
        }
        // The lights that came with borrowed meshes: their triangles as they are.
        for borrowed in borrowedLights {
            var light = borrowed.light
            light.firstTriangle = emissiveTriangles.count
            borrowed.triangles.withUnsafeBufferPointer { emissiveTriangles.append(contentsOf: UnsafeBufferPointer(rebasing: $0[borrowed.range])) }
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
            flagged.insert(instances[light.instance].material + light.materialOffset)
        }
        borrowedLights = []
        for m in flagged { materials[m].params.z = 1 }
        if !meshLights.isEmpty {
            print(String(format: "Emissive lights: %d meshes, %d triangles", meshLights.count, emissiveTriangles.count))
        }
    }

    /// A 64-pixel copy of an encoded image, sampled (repeat, nearest) as linear RGB; nil if it doesn't decode.
    private static func thumbnailSampler(_ data: Data) -> ((SIMD2<Float>) -> SIMD3<Float>)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
        else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let linear = (0..<256).map { i -> Float in
            let c = Float(i) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let texels = w * h
        let rgb: [SIMD3<Float>] = (0..<texels).map { (i: Int) -> SIMD3<Float> in
            let r: Float = linear[Int(pixels[4 * i])], g: Float = linear[Int(pixels[4 * i + 1])], b: Float = linear[Int(pixels[4 * i + 2])]
            return SIMD3<Float>(r, g, b)
        }
        return { uv in
            let x = Int((uv.x - uv.x.rounded(.down)) * Float(w)) % w, y = Int((uv.y - uv.y.rounded(.down)) * Float(h)) % h
            return rgb[max(y, 0) * w + max(x, 0)]
        }
    }
}
