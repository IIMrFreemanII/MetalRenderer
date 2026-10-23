import AppKit
import Metal
import MetalRenderer
import Modeling
import SwiftUI
import simd

/// The Rendered shading mode: a renderer of its own (the engine's, path traced with its GI) drawing the model on the
/// Modeller stage into the window. Made when the mode is chosen, stopped when it is left or the window closes; it never
/// saves settings or touches the main view's scene.
final class StageRenderer {
    /// The window's layer, or offscreen textures (a scripted Modeller's, ScriptModeller).
    let surface: RenderSurface
    let renderer: Renderer
    private var pending: DispatchWorkItem?

    /// `surface`: nil draws into a layer of its own, for the window.
    init?(device: MTLDevice, surface: RenderSurface? = nil) {
        self.surface = surface ?? LayerSurface(device: device)
        // Never the process's benchmark (a headless app's): the stage starts as the app's renderer does.
        guard let r = try? Renderer(device: device, surface: self.surface, benchmarked: false) else { return nil }
        renderer = r
        renderer.perform { r in
            // The app's defaults, not the main view's last session (its scene, a Solid view, debug views …).
            r.settings = r.defaultSettings
            r.settings.scene.kind = .modelingStage
            r.settings.renderScale = 0.5
        }
        renderer.startRenderThread()
    }

    /// The model the stage shows, a moment after the last change (a drag's edits come in many).
    func show(_ model: @escaping () -> ModelAsset.Rendered, delay: Double = 0.25) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            ModelingStage.set(model())
            self?.renderer.perform { $0.remakeStage() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setCamera(_ c: ViewportCamera) {
        let eye = c.eye, f = c.forward, fov = c.fovY
        renderer.perform { $0.setStageCamera(eye: eye, forward: f, fovY: fov) }
    }

    /// The layer it draws into in the window (nil offscreen).
    var layerSurface: LayerSurface? { surface as? LayerSurface }

    func stop() {
        pending?.cancel()
        layerSurface?.isVisible = false
        renderer.stopRenderThread()
    }
}

/// The stage's frames in the viewport's place.
struct RenderedViewport: NSViewRepresentable {
    let stage: StageRenderer

    final class View: NSView {
        let stage: StageRenderer
        init(stage: StageRenderer) {
            self.stage = stage
            super.init(frame: .zero)
            wantsLayer = true
            if let surface = stage.layerSurface {
                layer = surface.layer
                surface.layer.contentsGravity = .resize
            }
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the input stays the viewport's
        override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? 2
            stage.layerSurface?.setSize(bounds.size, backingScale: scale, refreshRate: window?.screen?.maximumFramesPerSecond ?? 60)
            stage.layerSurface?.isVisible = true
        }
    }

    func makeNSView(context: Context) -> View { View(stage: stage) }
    func updateNSView(_ view: View, context: Context) { view.needsLayout = true }
    static func dismantleNSView(_ view: View, coordinator: ()) { view.stage.layerSurface?.isVisible = false }
}

extension ModelingModel {
    /// Shading changed: the stage made or stopped.
    func updateStage() {
        if shading.mode == .rendered {
            if stage == nil, let device = renderer?.device ?? host?.metalDevice {
                stage = StageRenderer(device: device, surface: stageSurface?(device))
                if stage == nil { report("The Rendered view needs Metal ray tracing") }
            }
            stage?.setCamera(camera)
            stage?.show({ [weak self] in self?.renderedModel() ?? ModelAsset.Rendered(positions: [], normals: [], uvs: [], indices: [], triangleMaterial: [], materials: []) }, delay: 0)
        } else if let s = stage {
            s.stop()
            stage = nil
        }
    }

    /// The document changed: the stage shows it (after a moment).
    func stageDocumentChanged() {
        guard let stage else { return }
        if mode == .sculpt { sculpt?.commit(into: self) }
        stage.show { [weak self] in
            self?.renderedModel() ?? ModelAsset.Rendered(positions: [], normals: [], uvs: [], indices: [], triangleMaterial: [], materials: [])
        }
    }
}
