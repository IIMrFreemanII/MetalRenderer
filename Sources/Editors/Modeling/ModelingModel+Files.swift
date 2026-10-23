import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// New, open, save (the asset library), import and export, editing the scene's selection.
extension ModelingModel {
    /// What a scene renders of the document: every rendered, visible object's evaluated mesh in the model's space, one
    /// triangle mesh, its material slots one after another.
    func renderedModel() -> ModelAsset.Rendered {
        var out = ModelAsset.Rendered(positions: [], normals: [], uvs: [], indices: [], triangleMaterial: [], materials: [])
        let cache = ModifierCache()
        for o in document.objects where o.renders && o.visible {
            let evaluated = cache.evaluate(o, for: .render) { id in self.document.objects.first { $0.id == id } }
            let mesh = TriangleMesh(evaluated.transformed(by: o.transform.matrix))
            let base = UInt32(out.positions.count), slotBase = UInt16(out.materials.count)
            out.positions += mesh.positions
            out.normals += mesh.normals
            out.uvs += mesh.uvs.map { SIMD2($0.x, 1 - $0.y) }   // glTF's v, as the engine's models
            out.indices += mesh.indices.map { $0 + base }
            out.triangleMaterial += mesh.triangleMaterial.map { min($0, UInt16(max(0, o.materials.count - 1))) + slotBase }
            out.materials += o.materials.isEmpty ? [MaterialSlot(name: "Material")] : o.materials
        }
        return out
    }

    /// ⌘S: the document into the asset library (under its asset's name, or a new one from its name), and the main
    /// scene told.
    func save(as name: String? = nil) {
        cancelModal()
        if mode == .sculpt { sculpt?.commit(into: self) }
        var d = document
        if let name { d.name = name; d.asset = nil }
        var slug = d.asset ?? ModelStore.slug(d.name)
        if d.asset == nil {
            // A new asset: a name no other has.
            let taken = Set(ModelStore.list().map(\.slug))
            var k = 1
            let base = slug
            while taken.contains(slug) { k += 1; slug = "\(base)-\(k)" }
        }
        guard let url = ModelStore.url(slug) else { report("No model folder (METALRENDERER_MODELS=none)"); return }
        do {
            d.asset = slug
            setDocument(d, coarse: true)
            try ModelAsset.write(document, rendered: renderedModel(), to: url)
            markSaved()
            report("Saved \(url.lastPathComponent)")
            host?.modelAssetSaved(slug, source: source)
        } catch {
            report("Couldn't save: \(error.localizedDescription)")
        }
    }

    func open(asset slug: String) {
        guard let url = ModelStore.url(slug), let d = ModelAsset.readDocument(url) else { report("Couldn't open \(slug)"); return }
        replaceDocument(d)
        report("Opened \(slug)")
    }

    func newDocument() {
        replaceDocument(.startup())
    }

    /// OBJ or glTF in: their objects added to the document (selected).
    func importFile(_ url: URL) {
        do {
            let objects: [ModelObject]
            switch url.pathExtension.lowercased() {
            case "obj": objects = try OBJFile.read(url)
            case "glb", "gltf": objects = try GLTFModels.read(url)
            default: report("Can't import .\(url.pathExtension)"); return
            }
            edit("Import \(url.lastPathComponent)") { d in
                for o in objects { d.add(o) }
                d.selection = Set(d.objects.suffix(objects.count).map(\.id))
            }
            if let b = documentBounds(selectedOnly: true) { camera.frame(b, aspect: viewSize.x / max(viewSize.y, 1)) }
            report("Imported \(objects.count) object(s) from \(url.lastPathComponent)")
        } catch {
            report("Couldn't import \(url.lastPathComponent): \(error)")
        }
    }

    /// OBJ or glTF out: the rendered objects with their modifiers applied (selected only, if any are).
    func exportFile(_ url: URL, selectedOnly: Bool = false) {
        let cache = ModifierCache()
        let objects = document.objects.filter { $0.renders && $0.visible && (!selectedOnly || document.selection.contains($0.id)) }
        do {
            switch url.pathExtension.lowercased() {
            case "obj":
                try OBJFile.write(objects.map { o in
                    (o.name, cache.evaluate(o, for: .render) { id in self.document.objects.first { $0.id == id } }, o.transform.matrix, o.materials)
                }, to: url)
            case "glb":
                try GLTFModels.write(objects.map { o in
                    let m = cache.evaluate(o, for: .render) { id in self.document.objects.first { $0.id == id } }
                    return (o.name, TriangleMesh(m.transformed(by: o.transform.matrix)), o.materials)
                }, to: url)
            default: report("Can't export .\(url.pathExtension)"); return
            }
            report("Exported \(objects.count) object(s) to \(url.lastPathComponent)")
        } catch {
            report("Couldn't export: \(error)")
        }
    }

    /// The main view's selected object, opened here.
    func editSceneSelection() {
        guard let host else { return }
        host.modelOfSelection { [weak self] doc, why, source in
            guard let self else { return }
            guard let doc else { self.report(why); return }
            self.replaceDocument(doc, source: source)
            self.report(why)
        }
    }

    /// The modifiers of the selected objects put into their meshes (Apply › Visual Geometry to Mesh).
    func applyModifiers() {
        guard mode == .object else { return }
        let cache = ModifierCache()
        edit("Apply Modifiers") { d in
            let snapshot = d
            for k in d.objects.indices where d.selection.contains(d.objects[k].id) && !d.objects[k].modifiers.isEmpty {
                d.objects[k].mesh = cache.evaluate(d.objects[k], for: .viewport) { id in snapshot.objects.first { $0.id == id } }
                d.objects[k].modifiers = []
            }
        }
    }

    /// One modifier applied (the panel's Apply): the stack down to it put into the mesh, those modifiers gone.
    func applyModifier(_ id: UUID) {
        guard let i = activeIndex, let k = document.objects[i].modifiers.firstIndex(where: { $0.id == id }) else { return }
        edit("Apply Modifier") { d in
            var o = d.objects[i]
            o.modifiers = Array(o.modifiers[...k])
            let snapshot = d
            d.objects[i].mesh = ModifierStack.evaluate(o, for: .viewport) { id in snapshot.objects.first { $0.id == id } }
            d.objects[i].modifiers.removeSubrange(0...k)
        }
    }

    /// U › Unwrap / Smart UV Project, on the selected faces.
    func unwrap(smart: Bool) {
        editMesh(smart ? "Smart UV Project" : "Unwrap") { $0.unwrap(smart ? .smart(angle: 66 * .pi / 180) : .seams) }
        report(smart ? "Smart UV Project" : "Unwrapped along the seams")
    }
}
