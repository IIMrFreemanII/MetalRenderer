import Characters
import Effects
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import simd

extension Scene {
    // MARK: - GPU data

    /// Virtual instances: meshIndex points past the ordinary meshes and pad1 = 1 + the instance's rank among the virtual
    /// ones (its BLAS / cluster records).
    /// Assembly instances: meshIndex points past those too (the table then lists the assemblies), and SDF shapes'
    /// instances past those (the shapes), with `Scene.instanceSDF` in pad0.
    /// Into the renderer's records, kept from frame to frame. `all`: every instance (a scene's first frame); otherwise
    /// only the ones that move, the rest being unchanged.
    /// `range`: of all the instances, these (a part of them, for a caller that writes the parts side by side).
    package func writeInstanceData(into out: UnsafeMutablePointer<GPUInstanceData>, all: Bool, range: Range<Int>? = nil) {
        // Through the arrays' buffers, with the counts taken once: reading `self`'s arrays per instance cost an
        // exclusivity check each.
        let meshCount = meshes.count, virtualCount = virtualMeshes.count, assemblyCount = assemblies.count
        instances.withUnsafeBufferPointer { inst in
            virtualRank.withUnsafeBufferPointer { rank in
                func write(_ i: Int) {
                    let mesh = inst[i].mesh, assembly = inst[i].assembly, sdf = inst[i].sdf
                    out[i] = GPUInstanceData(transform: inst[i].transform,
                                             prevTransform: inst[i].prevTransform,
                                             normalMatrix: inst[i].normalMatrix,
                                             meshIndex: mesh >= 0 ? UInt32(mesh)
                                                 : assembly >= 0 ? UInt32(meshCount + virtualCount + assembly)
                                                 : sdf >= 0 ? UInt32(meshCount + virtualCount + assemblyCount + sdf)
                                                 : UInt32(meshCount + inst[i].virtualMesh),
                                             materialIndex: UInt32(inst[i].material),
                                             pad0: inst[i].mask | (sdf >= 0 ? Scene.instanceSDF : 0),
                                             pad1: rank[i])
                }
                if let range {
                    for i in range { write(i) }
                } else if !all, let animated {   // (a crowd's tens of thousands of walkers: in parts)
                    let moving = animated.instances
                    SceneBuffers.inParts(moving.count) { for k in $0 { write(moving[k]) } }
                } else {
                    SceneBuffers.inParts(inst.count) { for i in $0 { write(i) } }
                }
            }
        }
    }

    /// More lights than this (analytic + emissive meshes): nothing may loop over the lights or keep something per light
    /// (LIGHT_TABLE in Shaders/Types.metal): no light maps, GI and the path tracer sample the light table.
    /// `METALRENDERER_LIGHT_TABLE=1` / `=0` forces it on / off. Set once, by init.
    package static let lightTableThreshold = 256

    /// One bit per light type present (GPULight.sphere ...): the shaders are specialised for it. Bit 31: usesLightTable.
    /// The bits under it: the features the scene's shaders are compiled with.
    package var lightTypeMask: UInt32 {
        // Bits 30 and 29: FOLIAGE, the scene has assemblies or leaning ground cover, and ALPHA_TEST, it has leaf cards.
        // Bit 28: DEFORMING_MESHES, it has meshes that deform (a crowd's pose slots, cloths). Bit 27: GLASS. Bit 26:
        // MULTI_MATERIAL, some mesh has several materials. Bit 25: STREAMED, some meshes are borrowed, and so in
        // buffers of their own. Bit 24: GROUPED, some instances are in groups. Bit 23: VOXEL_BOXES, far plants are
        // voxel boxes. Bit 22: SDF_SHAPES, some instances are SDF shapes. Bit 21: VG_CLUSTERS, virtual geometry is
        // traced as its cut of clusters (VirtualGeometry.clusterMode). Bit 20: HAIR_CURVES, some meshes are curves.
        // Bit 19: RIGID_ASSEMBLIES, some assemblies are buildings of modules. Bit 18: LIQUID, some instances are a
        // liquid's surface. Bit 17: SKIN, some materials are skin. Bit 16: PARTICLES, it has particle effects.
        // Bit 15: MATERIAL_EXTRAS, it has procedural materials. Bit 14: OPACITY, some of them cut holes. Bit 13:
        // PROCEDURAL_CODE, some of them are code the shading runs. Bit 12: TERRAIN, its ground is a terrain whose
        // vertices carry layer weights. Bit 11: WATER, it has water (Scene+Water.swift, Shaders/Water.metal).
        // Bit 10: LEAF_TRANSMIT, some leaves are two-sided (a leaf sheet's). (Shaders/Types.metal.)
        let features: UInt32 = (hasFoliage ? 0x4000_0000 : 0) | (cutouts.isEmpty ? 0 : 0x2000_0000)
            | (hasDeformingMeshes ? 0x1000_0000 : 0) | (hasGlass ? 0x0800_0000 : 0) | (hasMaterialOffsets ? 0x0400_0000 : 0)
            | (hasBorrowedMeshes ? 0x0200_0000 : 0) | (hasGroups ? 0x0100_0000 : 0) | (hasVoxelBoxes ? 0x0080_0000 : 0)
            | (hasSDFShapes ? 0x0040_0000 : 0) | (tracesClusters ? 0x0020_0000 : 0) | (hasCurves ? 0x0010_0000 : 0)
            | (hasRigidAssemblies ? 0x0008_0000 : 0) | (hasLiquid ? 0x0004_0000 : 0) | (hasSkin ? 0x0002_0000 : 0)
            | (hasParticles ? 0x0001_0000 : 0) | (materialExtras.isEmpty ? 0 : 0x8000)
            | (hasOpacity ? 0x2000_4000 : 0)   // OPACITY, with ALPHA_TEST's query loop
            | (proceduralCode.isEmpty ? 0 : 0x2000)   // PROCEDURAL_CODE
            | (terrain == nil ? 0 : 0x1000)           // TERRAIN
            | (hasWater ? 0x0800 : 0)                 // WATER
            | (hasLeafSheets ? 0x0400 : 0)            // LEAF_TRANSMIT
        return lights.reduce((usesLightTable ? 0x8000_0001 : UInt32(1)) | features) { mask, l in   // spheres always: an empty scene needs some type
            let type: Float
            switch l.kind {
            case .sphere: type = GPULight.sphere
            case .spot: type = GPULight.spot
            case .sun: type = GPULight.sun
            case .rect: type = GPULight.rect
            case .tube: type = GPULight.tube
            case .mesh: type = GPULight.mesh
            }
            return mask | 1 << UInt32(type)
        }
    }

    /// `all`: every light (a scene's first frame); otherwise only the ones whose record changes over time.
    package func writeLights(into out: UnsafeMutableBufferPointer<GPULight>, all: Bool) {
        if all {
            for l in lights.indices { out[l] = gpuLight(l) }
        } else {
            for l in changingLights { out[l] = gpuLight(l) }
        }
    }

    private func gpuLight(_ index: Int) -> GPULight {
        let l = lights[index]
        let p = l.current
        func color(_ type: Float) -> SIMD4<Float> { SIMD4(l.color * p.scale, Float(l.group) + 4 * type) }
        switch l.kind {
        case .sphere(let r):
            return GPULight(positionRadius: SIMD4(p.position, r), color: color(GPULight.sphere),
                            axis: .zero, params: .zero)
        case .spot(let r, let inner, let outer):
            return GPULight(positionRadius: SIMD4(p.position, r), color: color(GPULight.spot),
                            axis: SIMD4(normalize(p.direction), 0),
                            params: SIMD4(cos(outer), cos(max(inner, 0)) + (inner >= outer ? 1e-4 : 0), 0, 0))
        case .sun(let angle):
            return GPULight(positionRadius: SIMD4(0, 0, 0, angle), color: color(GPULight.sun),
                            axis: SIMD4(normalize(p.direction), 0), params: sceneSphere)
        case .rect(let w, let h):
            let (t, n, _) = Scene.rectFrame(p)
            return GPULight(positionRadius: SIMD4(p.position, 0), color: color(GPULight.rect),
                            axis: SIMD4(n, l.reach), params: SIMD4(t * (w / 2), h / 2))
        case .tube(let length, let r):
            return GPULight(positionRadius: SIMD4(p.position, r), color: color(GPULight.tube),
                            axis: SIMD4(normalize(p.direction) * (length / 2), 0), params: .zero)
        case .mesh(let i):
            let m = meshLights[i]
            let t = instances[m.instance].transform
            let linear = float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                  SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                  SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            let maxScale = max(length(linear.columns.0), length(linear.columns.1), length(linear.columns.2))
            let areaScale = pow(abs(linear.determinant), 2.0 / 3.0)
            let c = t * SIMD4(m.center, 1)
            let n = m.flatness > 0 ? normalize(linear.inverse.transpose * m.normal) : SIMD3<Float>(0, 1, 0)
            return GPULight(positionRadius: SIMD4(c.x, c.y, c.z, m.radius * maxScale),
                            color: SIMD4(m.power * areaScale, 4 * GPULight.mesh),
                            axis: SIMD4(n, Float(m.materialOffset)),
                            params: SIMD4(Float(bitPattern: UInt32(m.firstTriangle)), Float(bitPattern: UInt32(m.triangleCount)),
                                          m.flatness, Float(bitPattern: UInt32(m.instance))))
        }
    }
}
