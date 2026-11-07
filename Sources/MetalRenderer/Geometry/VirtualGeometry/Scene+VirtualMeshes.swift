import EngineCore
import Foundation
import simd

extension Scene {
    /// A generated shape as virtual geometry, an instance per transform (their indices): its cluster DAG is built
    /// once and cached under `cacheKey` (`VirtualGeometryBuilder.mesh(cacheKey:build:)`), so only a cache miss calls
    /// `build`. With virtual geometry off the shape is an ordinary full-detail mesh instead (the reference the lab
    /// compares the cuts with). `watertight`: closed and wound outward (the Cracks view). `animations`, if given (one
    /// per transform, nil for a still one), replace the transforms over time, as `addInstance`'s do.
    @discardableResult
    package func addVirtualMesh(name: String, cacheKey: String, material: Int, transforms: [float4x4], watertight: Bool,
                                animations: [((Float) -> float4x4)?]? = nil, build: () -> VGMeshArrays) -> [Int] {
        precondition(animations == nil || animations!.count == transforms.count, "one animation per transform")
        guard !transforms.isEmpty else { return [] }
        beginObject(name)
        defer { endObject() }
        guard usesVirtualGeometry else {
            let a = build()
            let mesh = addMesh((a.positions, a.normals, a.indices), uvs: a.uvs, name: name, label: name)
            return transforms.indices.map { addInstance(mesh, material, transforms[$0], animation: animations?[$0]) }
        }
        loadStep?.set(detail: "\(name): virtual geometry")
        let vm = VirtualGeometryBuilder.mesh(cacheKey: cacheKey, build: build)
        virtualMeshes.append(vm)
        virtualMeshNames.append(name)
        let k = virtualMeshes.count - 1
        if watertight { watertightVirtualMeshes.insert(k) }
        return transforms.indices.map { j in
            let index = addInstance(-1, material, transforms[j], animation: animations?[j])
            instances[index].virtualMesh = k
            return index
        }
    }
}
