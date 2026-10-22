import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalKit
import Physics
import Plants
import QuartzCore
import simd

extension Renderer {
    // MARK: - Interiors on demand


    /// The city's building the camera is in or nearest (within reach, not far above it): its interior is made, in the
    /// background (SceneSettings.interior); left behind, it is dropped. It waits a moment and while the camera flies
    /// fast, so that passing by doesn't make one.
    package func chooseInterior() {
        let now = CACurrentMediaTime()
        let p = camera.position, flat = SIMD2(p.x, p.z)
        let speed = lastCameraPosition.map { length($0 - p) } ?? 0
        lastCameraPosition = p
        guard speed < 0.25 else { return }   // (a frame's way at 15 m/s and 60 fps)
        let reach = settings.scene.city.interiorReach
        func gap(_ r: CityPlan.Rect) -> Float { length(simd_max(simd_max(r.lo - flat, flat - r.hi), .zero)) }
        let current = settings.scene.interior
        var wanted = current
        if let inside = scene.lotAreas.first(where: { gap($0.rect) == 0 && p.y < $0.height + 1 }) {
            wanted = inside.key
        } else if let near = scene.lotAreas.filter({ p.y < $0.height + 25 }).min(by: { gap($0.rect) < gap($1.rect) }) {
            let held = scene.lotAreas.first { $0.key == current }
            if held.map({ gap($0.rect) > reach + 15 }) ?? true { wanted = gap(near.rect) < reach ? near.key : nil }
        } else {
            wanted = nil
        }
        guard wanted != current else { interiorWanted = nil; return }
        if interiorWanted?.key != wanted { interiorWanted = (wanted, now); return }
        if let since = interiorWanted?.since, now - since > 0.4 || benchmark != nil {
            settings.scene.interior = wanted
            interiorWanted = nil
        }
    }
}
