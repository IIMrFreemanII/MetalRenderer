import AppKit
import EngineCore
import Garments
import Metal
import MetalRenderer
import SwiftUI
import simd

/// The Garment Designer's 3D view: a renderer of its own (the engine's, path traced) on the garment workshop scene,
/// drawing into the window's layer (or offscreen textures, a script's). Made when the window opens, stopped when it
/// closes; it never saves settings or touches the main view's scene.
final class GarmentStageRenderer {
    let surface: RenderSurface
    let renderer: Renderer

    init?(device: MTLDevice, surface: RenderSurface? = nil) {
        self.surface = surface ?? LayerSurface(device: device)
        guard let r = try? Renderer(device: device, surface: self.surface, benchmarked: false) else { return nil }
        renderer = r
        renderer.perform { r in
            r.settings = r.defaultSettings
            r.settings.scene.kind = .garmentStage
            r.settings.renderScale = 0.5
        }
        renderer.startRenderThread()
    }

    /// The garment `key` (GarmentCatalog's) on `avatar`: the stage's scene made again with it.
    func show(garment key: String, avatar: String, simulate: Bool) {
        renderer.perform { r in
            r.settings.scene.kind = .garmentStage
            r.settings.scene.garmentWorkshop.garment = key
            r.settings.scene.garmentWorkshop.avatar = avatar
            r.settings.scene.garmentWorkshop.simulate = simulate
        }
    }

    func setClip(_ name: String) { renderer.perform { $0.settings.scene.garmentWorkshop.clip = name } }

    func setCamera(_ o: GarmentModel.Orbit) {
        let eye = o.eye, f = o.forward, fov = o.fovY
        renderer.perform { $0.setStageCamera(eye: eye, forward: f, fovY: fov) }
    }

    var layerSurface: LayerSurface? { surface as? LayerSurface }

    func stop() {
        layerSurface?.isVisible = false
        renderer.stopRenderThread()
    }
}

/// The stage's frames, and the mouse on them: drag the cloth to pull it, drag elsewhere to turn round the avatar,
/// right-drag (or Option-drag) to pan, scroll to come closer; with the trace tool, clicks on the body.
struct GarmentViewport: NSViewRepresentable {
    let model: GarmentModel

    final class View: NSView {
        let model: GarmentModel
        private var dragging: (start: CGPoint, orbit: GarmentModel.Orbit, pan: Bool)?
        private var held: (particle: Int, depth: Float)?

        init(model: GarmentModel) {
            self.model = model
            super.init(frame: .zero)
            wantsLayer = true
            attachLayer()
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        func attachLayer() {
            if let surface = model.stage?.layerSurface, layer !== surface.layer {
                layer = surface.layer
                surface.layer.contentsGravity = .resizeAspectFill
                needsLayout = true
            }
        }

        override var acceptsFirstResponder: Bool { true }
        override func layout() {
            super.layout()
            attachLayer()
            let scale = window?.backingScaleFactor ?? 2
            model.stage?.layerSurface?.setSize(bounds.size, backingScale: scale, refreshRate: window?.screen?.maximumFramesPerSecond ?? 60)
            model.stage?.layerSurface?.isVisible = true
        }

        /// The ray through a point of the view (its renderer's camera).
        private func ray(_ p: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
            let o = model.orbit
            let x = Float(p.x / max(1, bounds.width)), y = Float(1 - p.y / max(1, bounds.height))
            let aspect = Float(bounds.width / max(1, bounds.height))
            let f = o.forward, r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0))), u = simd_cross(r, f)
            let t = tan(o.fovY / 2)
            return (o.eye, simd_normalize(f + r * ((x * 2 - 1) * t * aspect) + u * ((1 - y * 2) * t)))
        }

        override func mouseDown(with e: NSEvent) {
            window?.makeFirstResponder(self)
            let p = convert(e.locationInWindow, from: nil)
            let pan = e.modifierFlags.contains(.option)
            dragging = (p, model.orbit, pan)
            guard !pan, let stage = model.stage else { return }
            let r = ray(p)
            if model.tool == .trace {
                stage.renderer.perform { [weak self] rd in
                    guard let hit = rd.garmentBodyHit(origin: r.origin, direction: r.direction) else { return }
                    DispatchQueue.main.async { self?.model.trace.append(hit) }
                }
                dragging = nil
                return
            }
            // A pick on the render thread; until it answers the drag turns the view (and stops once it holds).
            stage.renderer.perform { [weak self] rd in
                guard let i = rd.garmentPick(origin: r.origin, direction: r.direction),
                      let at = rd.garmentDrape()?.positions[i] else { return }
                let depth = simd_dot(at - r.origin, r.direction)
                rd.garmentGrab(i, target: at)
                DispatchQueue.main.async { self?.held = (i, depth); self?.dragging = nil }
            }
        }

        override func mouseDragged(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            if let held, let stage = model.stage {
                let r = ray(p)
                let target = r.origin + r.direction * held.depth
                stage.renderer.perform { $0.garmentGrab(held.particle, target: target) }
                return
            }
            guard let d = dragging else { return }
            var o = d.orbit
            let dx = Float(p.x - d.start.x), dy = Float(p.y - d.start.y)
            if d.pan {
                let f = o.forward, r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0))), u = simd_cross(r, f)
                let k = o.distance * 0.0018
                o.target -= r * dx * k + u * dy * k
            } else {
                o.yaw = d.orbit.yaw + dx * 0.008
                o.pitch = max(-1.4, min(1.4, d.orbit.pitch - dy * 0.006))
            }
            model.setOrbit(o)
        }

        override func mouseUp(with e: NSEvent) {
            if held != nil {
                model.stage?.renderer.perform { $0.garmentGrab(nil, target: .zero) }
                held = nil
            }
            dragging = nil
        }

        override func rightMouseDown(with e: NSEvent) {
            dragging = (convert(e.locationInWindow, from: nil), model.orbit, true)
        }
        override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
        override func rightMouseUp(with e: NSEvent) { dragging = nil }

        override func scrollWheel(with e: NSEvent) {
            var o = model.orbit
            o.distance = max(0.4, min(12, o.distance * exp(-Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.08))))
            model.setOrbit(o)
        }

        override func magnify(with e: NSEvent) {
            var o = model.orbit
            o.distance = max(0.4, min(12, o.distance / Float(1 + e.magnification)))
            model.setOrbit(o)
        }

        override func keyDown(with e: NSEvent) {
            if !GarmentKeys.handle(e, model: model) { super.keyDown(with: e) }
        }
    }

    func makeNSView(context: Context) -> View { View(model: model) }
    func updateNSView(_ view: View, context: Context) { view.attachLayer(); view.needsLayout = true }
    static func dismantleNSView(_ view: View, coordinator: ()) { view.model.stage?.layerSurface?.isVisible = false }
}
