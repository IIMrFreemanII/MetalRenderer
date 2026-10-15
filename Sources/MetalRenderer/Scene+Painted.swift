import Foundation
import simd

/// An object the Material Painter paints: its instance, given materials of its own (copies of the ones it had, one
/// per material its mesh's triangles name, so a several-material mesh keeps its offsets) that read one texture set
/// through the texture slots the renderer fills (PainterSession: the document's layers composited), at the UVs of
/// its layout (UVAtlas: its own UVs, or the painter's unwrap), three per triangle in `Scene.paintUVs`.
struct PaintedObject {
    var instance: Int
    var mesh: Int
    var document: String
    var materials: [Int]              // the run of painted materials, its instance's first
    var originals: [GPUMaterial]      // what they were (the layer "as it was" is made from them)
    var slots: [UInt32]               // per ProcSlot, Scene.textures indices
    var cornerBase: Int               // its first corner in the GPU's UVs (Scene.uvs, then Scene.paintUVs)
    var firstTriangle: Int            // its mesh's first in the index buffer
    var atlas: UVAtlas
    var fingerprint: String
    var resolution: Int
    var opacity: Bool                 // its document cuts holes (the scene alpha-tests it)
    var emissive: Bool

    /// What a painted material's extras say in `textures.z`: its corners' first, less three per triangle before its
    /// mesh's, in the low 30 bits, the top two 10 (1 is a procedural material's planar UVs; ~0, a material without
    /// extras, and 0 neither).
    static func encode(cornerOffset: Int) -> UInt32 { 0x8000_0000 | (UInt32(bitPattern: Int32(cornerOffset)) & 0x3FFF_FFFF) }
    /// ...and back, from an extra's (nil: not a painted material's).
    static func corners(_ e: GPUMaterialExtra) -> Int32? {
        guard e.textures.z & 0xC000_0000 == 0x8000_0000 else { return nil }
        return Int32(bitPattern: e.textures.z << 2) >> 2
    }
    var cornerOffset: Int { cornerBase - 3 * firstTriangle }
}

extension Scene {
    /// Instance `i` can be painted: an ordinary mesh's (not virtual geometry, a plant's assembly, an SDF shape, a
    /// borrowed tile mesh, a leaf card or swaying cover, nor a displaced copy), in a scene that isn't the open world.
    func paintable(_ i: Int) -> Bool {
        guard instances.indices.contains(i), worldPlace == nil else { return false }
        let inst = instances[i]
        guard inst.mesh >= 0, inst.virtualMesh < 0, inst.assembly < 0, inst.sdf < 0, inst.isGeometry else { return false }
        let m = meshes[inst.mesh]
        guard m.block == 0, m.cutout == 0, m.sways == 0, m.indexCount >= 3 else { return false }
        return !displaced.contains { $0.mesh == inst.mesh } && Int(m.firstIndex + m.indexCount) <= indices.count
    }

    /// Instance `i` as the scene makes it, said in full: its mesh's triangles and its material's values (what a saved
    /// assignment must still match).
    func paintFingerprint(_ i: Int) -> String {
        let inst = instances[i]
        return PaintMesh(scene: self, mesh: inst.mesh).fingerprint + "-" + MaterialAssignments.fingerprint(materials[inst.material])
    }

    /// The scene's paint (SceneSettings.paintAssignments), and the painter workshop's object with its document: each
    /// instance that still is what it was painted as gets its painted materials. Warnings for the stale ones.
    func applyPaintAssignments() {
        guard worldPlace == nil else { return }
        var entries = PaintAssignments.resolve(settings.paintAssignments).entries(settings)
        if let s = paintSubject, paintable(s) {
            entries.removeAll { $0.instance == s }
            entries.append(PaintAssignments.Entry(instance: s, fingerprint: paintFingerprint(s), document: settings.painterWorkshop.document))
        }
        for e in entries {
            guard paintable(e.instance) else {
                print("Painter: \(e.document) can't paint instance \(e.instance) (it isn't there, or isn't a mesh of its own)")
                continue
            }
            guard paintFingerprint(e.instance) == e.fingerprint else {
                print("Painter: the paint of instance \(e.instance) (\(e.document)) is stale (the scene's object changed)")
                continue
            }
            paint(e.instance, document: e.document)
        }
    }

    /// Instance `i` painted with `name`'s document: its materials, its texture set's slots (white pixels until the
    /// renderer composites it), its layout.
    @discardableResult
    func paint(_ i: Int, document name: String) -> PaintedObject? {
        guard paintable(i), !painted.contains(where: { $0.instance == i }) else { return nil }
        let doc = PaintDocuments.shared.document(name)
        let inst = instances[i]
        let mesh = PaintMesh(scene: self, mesh: inst.mesh)
        let fingerprint = paintFingerprint(i)
        let atlas = Scene.paintAtlas(mesh, resolution: doc.resolution)
        let m = meshes[inst.mesh]
        let first = Int(m.firstIndex) / 3, count = Int(m.indexCount) / 3
        // The materials its triangles name.
        var run = 1
        if !triangleMaterials.isEmpty {
            for t in first..<min(first + count, triangleMaterials.count) { run = max(run, Int(triangleMaterials[t]) + 1) }
        }
        run = min(run, materials.count - inst.material)
        var slots: [UInt32] = []
        for slot in ProcSlot.allCases {
            slots.append(addTexture(TextureSource(data: Data([255, 255, 255, 255]), srgb: slot.srgb, name: "painted/\(name)/\(slot)",
                                                  modelPath: GeneratedCache.folder.appendingPathComponent("painted").path,
                                                  cacheKey: "painted-\(slot)", raw: (1, 1))))
        }
        let object = PaintedObject(instance: i, mesh: inst.mesh, document: name, materials: [], originals: [], slots: slots,
                                   cornerBase: uvs.count + paintUVs.count, firstTriangle: first, atlas: atlas, fingerprint: fingerprint,
                                   resolution: doc.resolution, opacity: doc.opacity, emissive: doc.emissive)
        var made = object
        for k in 0..<run {
            let was = materials[inst.material + k]
            made.originals.append(was)
            // Grey until its texture set comes (the renderer's), keeping what isn't its surface's (skin, a leaf's light).
            var p = GPUMaterial(albedo: SIMD4(0.5, 0.5, 0.5, 0), emission: SIMD4(0, 0, 0, 0.6), params: SIMD4(1, doc.normalStrength, 0, was.params.w))
            p.params.z = 0
            made.materials.append(addMaterial(p))
            var e = GPUMaterialExtra()
            e.textures = SIMD4(.max, doc.opacity ? slots[ProcSlot.opacity.rawValue] : .max, PaintedObject.encode(cornerOffset: object.cornerOffset), .max)
            e.surface = SIMD4(0, 1, doc.alphaCutoff, doc.aoStrength)
            materialExtras[made.materials[k]] = e
        }
        setPaintedMaterial(i, made.materials[0], cutsHoles: doc.opacity)
        paintUVs += atlas.corners
        painted.append(made)
        return made
    }

    /// A mesh's layout at `resolution`, from the cache (GeneratedCache) or made and put there.
    static func paintAtlas(_ mesh: PaintMesh, resolution: Int) -> UVAtlas {
        let name = "painter-\(mesh.fingerprint)-\(resolution).sect", key = "painter atlas v\(UVUnwrap.version)"
        let cornerID = SectionFile.id("corn"), chartID = SectionFile.id("chrt"), infoID = SectionFile.id("info")
        if let file = GeneratedCache.load(name, key: key), let corners: [SIMD2<Float>] = file.array(cornerID),
           let charts: [Int32] = file.array(chartID), let info: [Float] = file.array(infoID), info.count == 3,
           corners.count == mesh.indices.count, charts.count == mesh.triangleCount {
            return UVAtlas(corners: corners, chartOfTriangle: charts, chartCount: Int(info[0]), resolution: resolution,
                           texelsPerMetre: info[1], own: info[2] != 0)
        }
        let atlas = UVUnwrap.atlas(mesh, resolution: resolution)
        var writer = SectionFile.Writer()
        writer.add(cornerID, atlas.corners)
        writer.add(chartID, atlas.chartOfTriangle)
        writer.add(infoID, [Float(atlas.chartCount), atlas.texelsPerMetre, atlas.own ? 1 : 0])
        GeneratedCache.store(name, key: key, writer)
        return atlas
    }
}
