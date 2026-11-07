import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import ImageIO
import Landscape
import Materials
import Physics
import Plants
import simd

extension Scene {
    // MARK: - Emissive-mesh lights

    /// A light that comes with a borrowed mesh, made already: sampled as the scene's own emissive instances are.
    package func addMeshLight(_ light: BorrowedLight) { borrowedLights.append(light) }

    /// Every geometry instance with an emissive material becomes a mesh light (after the analytic lights,
    /// countAnalyticLights): its triangles, each weighted by area x emitted luminance (an emissive texture's
    /// luminance from a small decoded copy), and the bounding sphere / mean normal proxy the shaders weigh it by.
    package func buildMeshLights() {
        cascadeLitMeshLights = 0
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
        // Each light's material, and the size of its smallest light if every light of it is big enough to be lit by the
        // cascades (params.z = 2 + that size: the shaders' reach of the cascades, cascadeEmitterReach), -1 if one isn't.
        var flagged: [Int: Float] = [:]
        var lightMaterials: [Int] = []
        let leastSize = settings.cascadeEmitterSize
        func flag(_ material: Int, light: MeshLight, triangles: ArraySlice<GPUEmissiveTriangle>) {
            let t = instances[light.instance].transform
            let linear = float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                  SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                  SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            var area: Float = 0
            for tri in triangles { area += 0.5 * length(cross(SIMD3(tri.e1.x, tri.e1.y, tri.e1.z), SIMD3(tri.e2.x, tri.e2.y, tri.e2.z))) }
            area *= pow(abs(linear.determinant), 2.0 / 3.0)
            let size = Scene.cascadeEmitterSize(area: area, flatness: light.flatness)
            let was = flagged[material] ?? .infinity
            flagged[material] = size >= leastSize && was >= 0 ? min(was, size) : -1
            lightMaterials.append(material)
        }
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
                    flag(inst.material + offset, light: light, triangles: draft.triangles[...])
                    emissiveTriangles += draft.triangles
                    meshLights.append(light)
                    lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
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
            flag(inst.material, light: light, triangles: draft.triangles[...])
            emissiveTriangles += draft.triangles
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
        }
        // The lights that came with borrowed meshes: their triangles as they are.
        for borrowed in borrowedLights {
            var light = borrowed.light
            light.firstTriangle = emissiveTriangles.count
            let first = emissiveTriangles.count
            borrowed.triangles.withUnsafeBufferPointer { emissiveTriangles.append(contentsOf: UnsafeBufferPointer(rebasing: $0[borrowed.range])) }
            flag(instances[light.instance].material + light.materialOffset, light: light, triangles: emissiveTriangles[first...])
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
        }
        borrowedLights = []
        for (m, size) in flagged { materials[m].params.z = size >= 0 ? 2 + size : 1 }
        cascadeLitMeshLights = lightMaterials.reduce(0) { $0 + ((flagged[$1] ?? -1) >= 0 ? 1 : 0) }
        if !meshLights.isEmpty {
            print(String(format: "Emissive lights: %d meshes (%d for the cascades), %d triangles", meshLights.count, cascadeLitMeshLights, emissiveTriangles.count))
        }
    }

    /// How big a mesh light is, as a length: the radius of a disc of its area if it is flat, else of a sphere's
    /// quarter-area (about a quarter of a closed or round shape's area faces any one direction).
    package static func cascadeEmitterSize(area: Float, flatness: Float) -> Float {
        (area / (flatness >= 0.5 ? .pi : 4 * .pi)).squareRoot()
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
