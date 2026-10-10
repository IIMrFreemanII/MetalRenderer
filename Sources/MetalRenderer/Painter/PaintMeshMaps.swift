import Foundation
import Metal

/// The Material Designer's Mesh Map node's pictures: a painted object's bakes (PaintBake) under a context name while a
/// graph mask of it is baked, or a neutral picture (flat curvature and height, open occlusion, an upward normal...)
/// anywhere else. Any thread.
enum PaintMeshMaps {
    private static let lock = NSLock()
    private static var maps: [String: [String: MTLTexture]] = [:]
    private static var neutral: [String: MTLTexture] = [:]

    /// The map `map` of the object `context` names, or its neutral picture.
    static func texture(context: String, map: String, device: MTLDevice) -> MTLTexture? {
        lock.lock()
        if let t = maps[context]?[map] { lock.unlock(); return t }
        if let t = neutral[map] { lock.unlock(); return t }
        lock.unlock()
        let value: [UInt8]
        switch map {
        case "occlusion": value = [255, 255, 255, 255]
        case "thickness": value = [64, 64, 64, 255]
        case "normal": value = [128, 128, 255, 255]
        default: value = [128, 128, 128, 255]
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        value.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        lock.lock()
        neutral[map] = t
        lock.unlock()
        return t
    }

    /// `name`'s graph baked over `bake`'s object (its Mesh Map nodes reading its maps): its base colour (else its
    /// height, its opacity), at the graph's own size: a graph mask (PaintGenerator.Kind.graph).
    static func bake(graph name: String, catalog: MaterialCatalog, maps bake: PaintBake, size: Int, device: MTLDevice) -> MTLTexture? {
        guard var g = catalog.graph(name) else { return nil }
        let context = "painter-\(UInt(bitPattern: ObjectIdentifier(bake).hashValue))"
        lock.lock()
        maps[context] = ["curvature": bake.curvature, "occlusion": bake.occlusion, "thickness": bake.thickness,
                         "position": bake.position, "normal": bake.normal, "height": bake.position]
        lock.unlock()
        for i in g.nodes.indices where g.nodes[i].kind == .meshMap { g.nodes[i].params["context"] = .text(context) }
        let b = MaterialBake.shared(device)
        let key = MaterialBake.key(g, catalog: catalog)
        let o = b.bakeNow(g, key: key, catalog: catalog)
        return o?.baseColor ?? o?.height ?? o?.opacity
    }
}
