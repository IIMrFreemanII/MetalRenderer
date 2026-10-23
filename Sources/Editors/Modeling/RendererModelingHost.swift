import Foundation
import Metal
import MetalRenderer
import Modeling

/// The Modeller's host: the renderer's selection as a model, saved assets back into its scene, placing one. The
/// window's Modeller has the app's renderer; a scripted one (ScriptModeller) the headless app's.
final class RendererModelingHost: ModelingHost {
    private let renderer: Renderer

    init(renderer: Renderer) { self.renderer = renderer }

    var metalDevice: MTLDevice? { renderer.metalDevice }

    func modelOfSelection(_ done: @escaping (ModelingDocument?, String, ModelSource?) -> Void) {
        renderer.perform { r in
            let s = r.modelingSelection()
            DispatchQueue.main.async {
                done(s.document, s.message, s.document == nil ? nil : ModelSource(placedObject: s.placedObject, instances: s.instances))
            }
        }
    }

    func modelAssetSaved(_ slug: String, source: ModelSource?) {
        renderer.perform { r in r.modelAssetSaved(slug, placedObject: source?.placedObject, instances: source?.instances ?? []) }
    }

    func placeModelAsset(_ slug: String) {
        renderer.perform { r in r.addPlaced(asset: "mesh:\(slug)") }
    }
}
