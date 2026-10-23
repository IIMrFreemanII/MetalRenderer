import EngineCore
import Foundation
import Modeling
import simd

/// The Modeller's side of the renderer: the selection as a model to edit, saved assets back into the scene.
extension Renderer {
    /// What the selection is, as the Modeller opens it.
    package struct ModelingSelection {
        package var document: ModelingDocument?
        package var message: String
        /// The placed object (index in the scene file) it came from, if it is one.
        package var placedObject: Int?
        /// The instances it came from.
        package var instances: [Int]
    }

    /// The selected object as a model: a placed model asset as it was saved, a placed glTF model's parts, or what a
    /// builder made, out of the scene's arrays. Render thread.
    package func modelingSelection() -> ModelingSelection {
        guard let target = selection?.target, !target.instances.isEmpty else {
            return ModelingSelection(document: nil, message: "Select an object in the main view first", placedObject: nil, instances: [])
        }
        let placed = placedSelection
        if let k = placed, let file = scene.placed?.file, k < file.objects.count {
            let o = file.objects[k]
            if o.asset.hasPrefix("mesh:"), let url = ModelStore.url(String(o.asset.dropFirst(5))), let doc = ModelAsset.readDocument(url) {
                return ModelingSelection(document: doc, message: "Opened \(o.name) (model asset)", placedObject: k, instances: target.instances)
            }
            if o.asset.hasPrefix("model:") {
                let url = Scene.assetsDirectory.appendingPathComponent(String(o.asset.dropFirst(6)))
                if let objects = try? GLTFModels.read(url) {
                    var doc = ModelingDocument(name: o.name, objects: objects)
                    doc.selection = Set(objects.map(\.id))
                    return ModelingSelection(document: doc, message: "Opened \(o.name) (glTF)", placedObject: k, instances: target.instances)
                }
            }
        }
        let name = target.scope.split(separator: "/").last.map(String.init) ?? "Object"
        guard let doc = scene.modelingDocument(of: target.instances, name: name.isEmpty ? "Object" : name) else {
            return ModelingSelection(document: nil, message: "That object's meshes can't be edited here (virtual geometry, or the scene let go of them)",
                                     placedObject: nil, instances: target.instances)
        }
        return ModelingSelection(document: doc, message: "Opened \(name) from the scene", placedObject: placed, instances: target.instances)
    }

    /// A model asset was saved: the scene shows it. Placed objects of it are made again; the placed object it was
    /// opened from places it from now on; a builder's object gets it placed where it stands (the model's objects
    /// were opened at their places in the world, so at the origin), the builder's own staying as it was. Render thread.
    package func modelAssetSaved(_ slug: String, placedObject: Int?, instances: [Int]) {
        let asset = "mesh:\(slug)"
        let file = scene.placed?.file
        if let k = placedObject, let file, k < file.objects.count, file.objects[k].asset != asset {
            editPlaced { f in
                f.objects[k].asset = asset
                f.objects[k].material = ""
            }
            return
        }
        if file?.objects.contains(where: { $0.asset == asset }) == true {
            remakeScene(because: "model asset \(slug) saved")
            return
        }
        if placedObject == nil, !instances.isEmpty {
            editPlaced { f in f.objects.append(SceneFile.Object(asset: asset, name: slug)) }
        }
    }
}
