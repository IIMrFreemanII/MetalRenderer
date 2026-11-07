import EngineCore
import Foundation
import simd
import MetalRenderer

/// The VG lab's benchmark modes (`VGLab`, Benchmark+Modes.swift): `vglab` renders every bookmark's views and ends with
/// the cold-cache flight; `vglabfly` flies along every booth. Each setting's virtual geometry report (`VGReport.json`)
/// goes to a JSON array next to the PNGs (`vglab.json`, `vglabfly.json` in METALRENDERER_BENCH_DIR), which
/// Tools/eval/vglab.py reads.
extension Benchmark {
    /// What a mode collects: one entry a setting, the file rewritten at every capture (so it is whole when the run ends).
    final class VGLabLog: @unchecked Sendable {
        let file: String
        private let lock = NSLock()
        private var entries: [[String: Any]] = []
        private var extras: [String: [String: Any]] = [:]

        init(file: String) { self.file = file }

        /// Facts a setting found before its capture (the cold step's residency).
        func note(_ name: String, _ key: String, _ value: Any) {
            lock.lock(); extras[name, default: [:]][key] = value; lock.unlock()
        }

        /// The setting's entry: what it is, the report at its capture (JSON null without virtual geometry), the notes.
        func capture(_ renderer: Renderer, name: String, view: Int, virtual: Bool, bookmark: String) {
            var entry: [String: Any] = ["name": name, "view": view, "viewName": RenderSettings.viewModes[view],
                                        "vg": virtual, "bookmark": bookmark,
                                        "report": renderer.vgReport()?.json(rows: 64, history: 512) ?? NSNull()]
            lock.lock()
            for (k, v) in extras[name] ?? [:] { entry[k] = v }
            entries.removeAll { ($0["name"] as? String) == name }
            entries.append(entry)
            let all = entries
            lock.unlock()
            guard let dir = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_DIR"] else { return }
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
        }
    }

    private static let vglabLog = VGLabLog(file: "vglab.json")
    private static let vglabflyLog = VGLabLog(file: "vglabfly.json")

    /// A VG lab setting: the lab at the bookmark, still, native resolution (crisp PNGs), the report taken at capture.
    private static func vglabConfig(_ name: String, bookmark: String, view: Int, virtual: Bool, log: VGLabLog,
                                    waitRule: Bool = false) -> Config {
        Config(name, scale: 1, gi: nil, scene: SceneSettings(kind: .vgLab)) {
            $0.virtualGeometry.enabled = virtual
            $0.virtualGeometry.waitRule = waitRule
        }.view(view).still().frames(8).at(bookmark).atCapture {
            log.capture($0, name: name, view: view, virtual: virtual, bookmark: bookmark)
        }
    }

    /// The VG lab at every bookmark: Final, the six geometry views (8-13) and the three virtual geometry views (16-18)
    /// with virtual geometry (cuts made synchronously, the wait rule off), then Normals and Triangles with the
    /// full-detail meshes; the cold-cache flight last. Names are `vglabNN <booth> <view> <vg|full>`
    /// (`METALRENDERER_BENCH_ONLY=vglab02` takes booth 2). Writes `vglab.json`.
    static func vglab() -> [Config] {
        var out: [Config] = []
        let bookmarks = VGLab.bookmarks().map(\.name)
        let views = [0] + Array(RenderSettings.geometryViews) + Array(RenderSettings.vgViews)
        for (tag, virtual, list) in [("vg", true, views), ("full", false, [3, 8])] {
            for bookmark in bookmarks {
                for view in list {
                    let name = "vglab\(bookmark.lowercased()) \(RenderSettings.viewModes[view].lowercased()) \(tag)"
                    out.append(vglabConfig(name, bookmark: bookmark, view: view, virtual: virtual, log: vglabLog))
                }
            }
        }
        out.append(vglabCold())
        return out
    }

    /// At "08 Cold far": the owl's and the golem's meshes dropped from the page cache at the first measured frame (their
    /// residency before and after is in the JSON), then a 2 s glide to "08 Cold near" with the wait rule on: what
    /// reading them from disk costs a flight.
    private static func vglabCold() -> Config {
        let name = "vglab08 cold fly", view = 0
        let log = vglabLog
        func camera(_ bookmark: String) -> Camera {
            Config("x", scene: SceneSettings(kind: .vgLab)).at(bookmark).camera!
        }
        let far = camera("08 Cold far"), near = camera("08 Cold near")
        let warmup = 60, glideFrames = 120
        let total = Float(warmup + glideFrames - 1)
        func residency(_ r: [(mesh: String, resident: Float)]) -> [[String: Any]] {
            r.map { ["mesh": $0.mesh, "resident": Double($0.resident)] }
        }
        return Config(name, scale: 1, gi: nil, scene: SceneSettings(kind: .vgLab)) {
            $0.virtualGeometry.enabled = true
            $0.virtualGeometry.waitRule = true
        }.view(view).still().frames(glideFrames).cameraMove { p in
            // Held at the far booth through the warm-up, then the glide.
            let q = max(0, (p - Float(warmup) / total) / (1 - Float(warmup) / total))
            return glide(from: far, to: near, q)
        }.onFrame { renderer, frame in
            guard frame == warmup, let report = renderer.vgReport() else { return }
            let before = zip(report.meshNames, report.residency).filter {
                let n = $0.0.lowercased()
                return n.contains("owl") || n.contains("golem")
            }.map { (mesh: $0.0, resident: $0.1) }
            log.note(name, "residencyBefore", residency(before))
            log.note(name, "residencyAfter", residency(renderer.vgEvict(matching: "owl") + renderer.vgEvict(matching: "golem")))
        }.atCapture {
            log.capture($0, name: name, view: view, virtual: true, bookmark: "08 Cold far -> 08 Cold near")
        }
    }

    /// The scene's glide along every booth (`cameraMove`) with virtual geometry on and the wait rule on (the default):
    /// meant to be run with METALRENDERER_VG_SYNC=0, so that cuts and BLAS builds are made in the background while the
    /// camera moves, as in the app. The JSON's `history` (512 frames) shows the cut cost, rebuilds and memory along
    /// the way. Writes `vglabfly.json`.
    static func vglabfly() -> [Config] {
        let name = "vglabfly move"
        let log = vglabflyLog
        return [Config(name, scale: 1, gi: nil, scene: SceneSettings(kind: .vgLab)) {
            $0.virtualGeometry.enabled = true
            $0.virtualGeometry.waitRule = true
        }.cameraMove().frames(600).atCapture {
            log.capture($0, name: name, view: 0, virtual: true, bookmark: "01 Ladder -> 08 Cold")
        }]
    }
}
