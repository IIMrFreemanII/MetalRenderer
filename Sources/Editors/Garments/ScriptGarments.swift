import AppKit
import EngineCore
import Foundation
import Garments
import ImageIO
import Metal
import MetalRenderer
import SwiftUI
import simd

/// A Garment Designer for the tools and scripts to drive: its own model and stage, offscreen, in a headless app or
/// beside the window's (whose designer it never touches). The socket's `garments` request:
///
///     {"steps": [{"new": "shirt"}, {"avatar": "X Bot"}, {"wait": 3}, {"select": "Front left"}, {"param": ["length", 0.8]},
///                {"dart": ["Front", 0, 0.5]}, {"tool": "seam"}, {"simulate": false}, {"save": "my-shirt"}, {"export": "/tmp/s.dxf"}],
///      "capture": {"view": "window" | "rendered" | "pattern", "path": "…", "scale": 0.5}}
///
/// answers with what each step said, the state (its panels, seams, the cloth's report) and the picture's path.
final class ScriptGarments {
    typealias Failure = ScriptRequests.Failure
    private let device: MTLDevice
    private var model: GarmentModel?
    private static var shared: ScriptGarments?

    init(device: MTLDevice) { self.device = device }

    static func register(renderer: Renderer) {
        let s = ScriptGarments(device: renderer.metalDevice)
        shared = s
        ScriptRequests.register("garments") { body in s.request(body) }
    }

    private func current() -> GarmentModel {
        if let model { return model }
        let m = GarmentModel()
        m.canvasSize = CGSize(width: 640, height: 640)
        let device = self.device
        m.makeStage = { GarmentStageRenderer(device: device, surface: OffscreenSurface(device: device, pointSize: CGSize(width: 560, height: 640), backingScale: 2)) }
        m.startStage()
        m.frame()
        model = m
        return m
    }

    func request(_ body: Any) -> Result<[String: Any], Failure> {
        guard let body = body as? [String: Any] else { return .failure(Failure("give an object: {\"steps\": [...], \"capture\": \"window\"}", badRequest: true)) }
        do {
            var notes: [String] = []
            for (k, step) in (body["steps"] as? [[String: Any]] ?? []).enumerated() {
                do { notes.append(try perform(step)) } catch let f as Failure { throw Failure("step \(k + 1): \(f)") }
            }
            var answer: [String: Any] = ["steps": notes, "state": try onMain { state(current()) }]
            if let c = body["capture"] {
                let options = c as? [String: Any] ?? [:]
                let view = c as? String ?? options["view"] as? String ?? "window"
                answer["capture"] = try capture(view, path: options["path"] as? String, scale: (options["scale"] as? NSNumber)?.doubleValue ?? 1).path
            }
            return .success(answer)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure("\(error)"))
        }
    }

    private func onMain<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        var result: Result<T, Error>!
        DispatchQueue.main.sync { result = Result { try body() } }
        return try result.get()
    }

    private func perform(_ step: [String: Any]) throws -> String {
        if let seconds = (step["wait"] as? NSNumber)?.doubleValue {
            Thread.sleep(forTimeInterval: seconds)
            return "waited \(seconds) s"
        }
        return try onMain {
            let m = current()
            func panel(_ name: Any?) throws -> Panel {
                if let i = name as? Int, m.garment.panels.indices.contains(i) { return m.garment.panels[i] }
                guard let s = name as? String, let p = m.garment.panels.first(where: { $0.name == s }) else {
                    throw Failure("no panel \(name ?? "nil"): \(m.garment.panels.map(\.name).joined(separator: ", "))")
                }
                return p
            }
            if let kind = step["new"] as? String {
                guard let k = GarmentTemplate.Kind(rawValue: kind) else { throw Failure("templates: \(GarmentTemplate.Kind.allCases.map(\.rawValue))") }
                m.newFromTemplate(k)
                return "new \(k.label): \(m.garment.panels.count) panels, \(m.garment.seams.count) seams"
            }
            if let kind = step["over"] as? String, let k = GarmentTemplate.Kind(rawValue: kind) { m.addLayer(k); return "\(k.label) over it" }
            if let a = step["avatar"] as? String { m.setAvatar(a); return "avatar \(a)" }
            if let t = step["tool"] as? String {
                guard let tool = GarmentModel.Tool(rawValue: t) else { throw Failure("tools: \(GarmentModel.Tool.allCases.map(\.rawValue))") }
                m.tool = tool
                return "tool \(t)"
            }
            if let on = step["simulate"] as? Bool { if on != m.simulating { m.toggleSimulation() }; return "simulate \(on)" }
            if let name = step["select"] { let p = try panel(name); m.selection = [p.id]; m.tab = .panel; return "selected \(p.name)" }
            if let pv = step["param"] as? [Any], let key = pv.first as? String, let v = (pv.last as? NSNumber)?.floatValue {
                m.setTemplateParam(key, v)
                return "\(key) = \(v)"
            }
            if let d = step["dart"] as? [Any], d.count == 3, let e = d[1] as? Int, let f = (d[2] as? NSNumber)?.floatValue {
                let p = try panel(d[0])
                m.addDart(panel: p.id, edge: e, at: f)
                return "dart on \(p.name)"
            }
            if let r = step["rectangle"] as? [NSNumber], r.count == 4 {
                let lo = SIMD2(r[0].floatValue, r[1].floatValue), hi = SIMD2(r[2].floatValue, r[3].floatValue)
                m.addPanel("Rectangle", [PathPoint(lo), PathPoint(SIMD2(hi.x, lo.y)), PathPoint(hi), PathPoint(SIMD2(lo.x, hi.y))])
                return "rectangle"
            }
            if let s = step["sew"] as? [[Any]], s.count == 2 {
                func end(_ a: [Any]) throws -> SeamEnd {
                    let p = try panel(a.first)
                    guard a.count >= 2, let e = a[1] as? Int else { throw Failure("sew: [[panel, edge, t0?, t1?], [panel, edge, …]]") }
                    return SeamEnd(panel: p.id, edge: e, t0: (a.count > 2 ? (a[2] as? NSNumber)?.floatValue : nil) ?? 0,
                                   t1: (a.count > 3 ? (a[3] as? NSNumber)?.floatValue : nil) ?? 1)
                }
                m.seamDraft = ([try end(s[0])], [try end(s[1])])
                m.finishSeam()
                return m.message
            }
            if let f = step["fabric"] as? String, let p = Fabric.Preset(rawValue: f) { m.setFabric(0) { $0 = .preset(p) }; return "fabric \(f)" }
            if let frozen = step["freeze"] { let p = try panel(frozen); let id = p.id; m.edit("Freeze") { g in if let i = g.panelIndex(id: id) { g.panels[i].frozen.toggle() } }; return "freeze \(p.name)" }
            if let yaw = (step["view"] as? NSNumber)?.floatValue { m.view(yaw); return "view \(yaw)" }
            if step["fit"] != nil { m.gradeToAvatar(); return "fitted" }
            if step["reset"] != nil { m.resetDrape(); return "reset" }
            if let clip = step["clip"] as? String { m.setClip(clip); return "clip \(clip)" }
            if let id = step["save"] as? String { m.save(as: id); return m.message }
            if let id = step["open"] as? String { m.open(id); return m.message }
            if let path = step["export"] as? String { m.export(to: URL(fileURLWithPath: path)); return m.message }
            throw Failure("unknown step \(step.keys.sorted())")
        }
    }

    private func state(_ m: GarmentModel) -> [String: Any] {
        var s: [String: Any] = [
            "name": m.garment.name, "avatar": m.avatar, "simulating": m.simulating, "tool": m.tool.rawValue, "message": m.message,
            "panels": m.garment.panels.map { ["name": $0.name, "id": $0.id, "points": $0.points.count, "area": $0.signedArea] },
            "seams": m.garment.seams.count,
            "mismatched": m.mismatchedSeams.map { ["seam": $0.seam, "a": $0.a, "b": $0.b] },
        ]
        if let r = m.report {
            s["cloth"] = ["particles": r.particles, "constraints": r.constraints, "colours": r.colours, "buildMs": r.buildMs, "seconds": r.sewTime]
        }
        return s
    }

    /// The stage's frame (after its scene is in and 32 frames), the pattern canvas, or the whole window with the
    /// stage's frame in its 3D view.
    private func capture(_ view: String, path: String?, scale: Double) throws -> URL {
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("garments-\(view)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        let m = try onMain { current() }
        var stageImage: CGImage?
        let stage = try onMain({ m.stage })
        if view != "pattern" && stage == nil { throw Failure("no stage") }
        if view != "pattern", let stage {
            Thread.sleep(forTimeInterval: 0.4)
            func onStage<T>(_ body: @escaping (Renderer) -> T) -> T {
                var result: T?
                let done = DispatchSemaphore(value: 0)
                stage.renderer.perform { result = body($0); done.signal() }
                done.wait()
                return result!
            }
            let start = Date()
            while !onStage({ $0.sceneSettled }) && Date().timeIntervalSince(start) < 120 { Thread.sleep(forTimeInterval: 0.01) }
            let first = onStage { $0.frameIndex }
            while onStage({ $0.frameIndex }) &- first < 32 && Date().timeIntervalSince(start) < 180 { Thread.sleep(forTimeInterval: 0.01) }
            let file = view == "rendered" ? url : FileManager.default.temporaryDirectory.appendingPathComponent("garment-stage-\(UUID().uuidString).png")
            let done = DispatchSemaphore(value: 0)
            var ok = false
            stage.renderer.perform { $0.captureFrame(to: file, scale: view == "rendered" ? scale : 1) { written in ok = written; done.signal() } }
            guard done.wait(timeout: .now() + 30) == .success, ok else { throw Failure("the stage gave no frame") }
            if view == "rendered" { return url }
            stageImage = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            if stageImage == nil { throw Failure("the stage's frame didn't read from \(file.path) (exists: \(FileManager.default.fileExists(atPath: file.path)))") }
            try? FileManager.default.removeItem(at: file)
        }
        try onMain {
            m.stagePicture = stageImage
            defer { m.stagePicture = nil }
            let size = view == "pattern" ? CGSize(width: 900, height: 700) : CGSize(width: 1500, height: 900)
            let root = view == "pattern" ? AnyView(PatternCanvas(model: m)) : AnyView(GarmentView(model: m))
            let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if view == "pattern" { m.canvasSize = size; m.frame() }
            host.layoutSubtreeIfNeeded()
            // (A layer-backed NSView draws through cacheDisplay; the canvas's draw is called for it.)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure("the window drew nothing") }
            host.cacheDisplay(in: host.bounds, to: rep)
            // The stage's frame where the 3D view is (a layer's picture isn't in the views' drawing).
            // Where GarmentView lays the 3D view out: right of the pattern, under the bars, over the status line.
            let w = (size.width - 342) / 2
            m.viewportRect = CGRect(x: w + 1, y: 68, width: w, height: size.height - 68 - 22)
            guard var image = rep.cgImage else { throw Failure("the window drew nothing") }
            // The stage's frame where the 3D view is, filling it (a layer's picture isn't in the views' drawing).
            if let stageImage, view != "pattern", let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let r = m.viewportRect, k = CGFloat(image.width) / size.width
                let dest = CGRect(x: r.minX * k, y: (size.height - r.maxY) * k, width: r.width * k, height: r.height * k)
                // The frame's middle, cut to the view's shape (as the layer fills it).
                let sw = CGFloat(stageImage.width), sh = CGFloat(stageImage.height)
                var crop = CGRect(x: 0, y: 0, width: sw, height: sh)
                if dest.width / dest.height > sw / sh { crop.size.height = sw * dest.height / dest.width; crop.origin.y = (sh - crop.height) / 2 }
                else { crop.size.width = sh * dest.width / dest.height; crop.origin.x = (sw - crop.width) / 2 }
                if let cut = stageImage.cropping(to: crop.integral) { ctx.draw(cut, in: dest) }
                if let made = ctx.makeImage() { image = made }
            }
            try ModelingPictures.write(image, to: url, scale: scale)
        }
        return url
    }
}
