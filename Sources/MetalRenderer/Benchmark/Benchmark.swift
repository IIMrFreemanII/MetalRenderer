import EngineCore
import Foundation
import Metal
import Physics
import Plants
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless-ish benchmark mode, enabled with `METALRENDERER_BENCH=1 swift run -c release`.
///
/// Runs a fixed list of render settings with a deterministic animation clock, times every GPU
/// pass (each pass goes into its own command buffer so `gpuStartTime`/`gpuEndTime` isolate it),
/// prints a table and quits. Set `METALRENDERER_BENCH_DIR=<folder>` to also save a PNG per setting.
package final class Benchmark {
    /// One setting of a benchmark run: what it renders with and how the run goes. The lists are in
    /// Benchmark+Modes.swift, built with the modifiers below (`still`, `reference`, `cameraMove`, ...).
    package struct Config {
        package var name: String
        /// What it renders with, before the METALRENDERER_* lists override it (`resolvedSettings`).
        package var settings: RenderSettings
        /// The direct-light method, for settings that compare them (references use it too); nil = METALRENDERER_DIRECT / Auto.
        var directLight: DirectLightMode? = nil
        package var startTime: Float = 0            // the animation clock at the first frame
        var dt: Float = 1.0 / 60.0          // the clock's step a frame (seconds)
        package var frames: Int? = nil              // measured frames, if not the default
        var accumulate = false              // reference image: average raw frames instead of denoising
        package var accumulateTechnique = false     // with accumulate: average the GI method's frames instead of path tracing (restirgicheck)
        var supersample = false             // with accumulate: jitter every frame and average the final colour (anti-aliased reference)
        package var capturePrevious = false         // also save the second-to-last frame (for frame-to-frame flicker)
        var record = false                  // also save every other measured frame (30 fps), as JPEGs in a folder of its own
        var cameraPath = false              // fly the camera along cameraPose(progress:), ending at the default pose
        package var camera: Camera? = nil           // a fixed camera instead of the scene's default
        var flight: SIMD3<Float>? = nil     // the camera flies from there: metres a second (the open world's tiles)
        package var track: CameraTrack? = nil       // the camera follows it, from its start at the first measured frame
        var body = false                    // the camera is a walker's body: doors open for it, it shoves loose furniture
        var ride: Int? = nil                // the camera rides lift `ride` (its track keyed at the lift's lowest floor)
        package var events: [(time: Float, event: Event)] = []   // what happens at times of its track (`at`)
        /// Something done in a building at a moment of a setting's track, as the walker would (InteriorControls).
        package enum Event {
            case callLift(Int, floor: Int)          // lift n to that floor
            case lights(on: Bool, within: Float)    // the switches that near the camera, on or off
            case flashlight(Bool)
            /// The Material Painter in paint mode on the scene's first painted object (the camera kept), its steps
            /// one a frame (Renderer.runPainterScript).
            case paint([PainterStep])
            /// The Terrain Editor's steps (sculpt mode, brushes, strokes, undo), one a frame (Renderer.runTerrainScript).
            case terrain([TerrainStep])
        }
        // Set by `fog` / `sky`: the config's own, not the preset of whatever scene the run ends up with.
        private var ownFog = false, ownSky = false

        /// Benchmark settings differ from the app's defaults (radiance cascades, 3x from 0.5x): they path trace at 0.75x
        /// without upscaling or temporal AA unless they say otherwise. `scale`: the traced resolution as a fraction of the window;
        /// `upscale`: the upscaling factor, 0 = off; `gi`: the GI method, nil = GI off. The scene brings its fog and sky
        /// presets (`fog` and `sky` edit them); `change` edits anything else.
        package init(_ name: String, scale: CGFloat = 0.75, upscale: CGFloat = 0, gi: GIMode? = .pathTraced,
             scene: SceneSettings = SceneSettings(), _ change: (inout RenderSettings) -> Void = { _ in }) {
            var s = RenderSettings()
            s.renderScale = scale
            s.upscaleFactor = upscale
            s.taa = false   // (the native settings' references and scores are from before it)
            s.giEnabled = gi != nil
            s.giMode = gi ?? .pathTraced
            s.scene = scene
            s.fog = FogSettings.preset(for: scene)
            s.sky = SkySettings.preset(for: scene)
            s.foliage = FoliageSettings.preset(for: scene.kind)
            s.post = PostSettings.preset(for: scene)
            change(&s)
            self.name = name
            settings = s
        }

        // Modifiers: each returns a changed copy.
        package func named(_ name: String) -> Config { var c = self; c.name = name; return c }
        package func with(_ change: (inout RenderSettings) -> Void) -> Config { var c = self; change(&c.settings); return c }
        package func view(_ mode: Int) -> Config { with { $0.viewMode = mode } }
        /// Edits the fog (the scene's preset until then). It then stays as set, whatever scene METALRENDERER_SCENE picks.
        package func fog(_ change: (inout FogSettings) -> Void) -> Config { var c = self; change(&c.settings.fog); c.ownFog = true; return c }
        /// The same for the sky.
        package func sky(_ change: (inout SkySettings) -> Void) -> Config { var c = self; change(&c.settings.sky); c.ownSky = true; return c }
        package func frames(_ count: Int?) -> Config { var c = self; c.frames = count; return c }
        /// The clock steps `seconds` a frame (the animation, tracks, flights) instead of 1/60.
        package func step(_ seconds: Float) -> Config { var c = self; c.dt = seconds; return c }
        package func direct(_ mode: DirectLightMode) -> Config { var c = self; c.directLight = mode; return c }
        package func from(_ camera: Camera) -> Config { var c = self; c.camera = camera; return c }
        package func cameraMove() -> Config { var c = self; c.cameraPath = true; return c }
        /// Saves every other measured frame (30 fps of the 60 Hz clock) for a video: `<NN-name>/f0001.jpg` and on.
        package func recording() -> Config { var c = self; c.record = true; return c }
        package func flying(_ velocity: SIMD3<Float>) -> Config { var c = self; c.flight = velocity; return c }
        /// The camera follows `track`, the warm-up holding its first pose; the setting runs as long as the track.
        package func track(_ track: CameraTrack) -> Config {
            var c = self
            c.track = track
            c.frames = Int((track.duration * 60).rounded()) + 1
            return c
        }
        /// The camera walks: doors open as it comes up to them, it shoves the loose furniture it walks into.
        package func walking() -> Config { var c = self; c.body = true; return c }
        /// The camera rides lift `n`: its track's heights are from the lift's lowest floor, carried up with the cab.
        package func riding(_ n: Int) -> Config { var c = self; c.ride = n; return c }
        /// `event` at `time` seconds of the track.
        package func at(_ time: Float, _ event: Event) -> Config { var c = self; c.events.append((time, event)); return c }
        /// Paused at `time` seconds of animation, so every setting renders the same frame. `previous`: the frame
        /// before the last is saved too.
        package func still(at time: Float = 5, previous: Bool = false) -> Config {
            var c = self
            c.settings.paused = true
            c.startTime = time
            c.capturePrevious = previous
            return c
        }
        /// A converged reference: paused at `time`, `frames` raw frames averaged instead of denoised.
        package func reference(frames: Int, at time: Float = 5, supersample: Bool = false) -> Config {
            var c = still(at: time)
            c.accumulate = true
            c.frames = frames
            c.supersample = supersample
            return c
        }
        /// Animated again (after `still`), from the same start time and for the default number of frames.
        package func moving() -> Config {
            var c = self
            c.settings.paused = false
            c.frames = nil
            c.capturePrevious = false
            return c
        }

        /// The settings the run uses: this config's, then the METALRENDERER_* lists, which override every setting of a
        /// run (SettingsEnv; the keys are SettingsTable's). References keep their own GI settings.
        func resolvedSettings(env: [String: String] = ProcessInfo.processInfo.environment) -> RenderSettings {
            var s = settings
            SettingsEnv.apply(.scene, to: &s, from: env)
            // A run moved to a physics scene takes its look (the METALRENDERER_GI list below can change it again).
            if s.scene.kind.usesPhysicsLook && !settings.scene.kind.simulates { s.usePhysicsLook() }
            // The fog and sky of the scene the run ends up with, unless this config set its own.
            if !ownFog { s.fog = FogSettings.preset(for: s.scene) }
            if !ownSky { s.sky = SkySettings.preset(for: s.scene) }
            if s.scene.kind != settings.scene.kind { s.foliage = FoliageSettings.preset(for: s.scene.kind) }
            if s.scene.kind != settings.scene.kind || s.scene.showcase != settings.scene.showcase || s.scene.realism != settings.scene.realism {
                s.post = PostSettings.preset(for: s.scene)
            }
            for variable in [EnvVariable.fogSet, .skySet, .foliage, .denoise, .post] { SettingsEnv.apply(variable, to: &s, from: env) }
            if !accumulate { SettingsEnv.apply(.gi, to: &s, from: env) }
            for variable in [EnvVariable.restir, .restirGI, .view] { SettingsEnv.apply(variable, to: &s, from: env) }
            if let directLight { s.directLight = directLight }
            return s
        }

        /// (As the memberwise initializer, for the modules above this one.)
        package init(name: String, settings: RenderSettings, directLight: DirectLightMode? = nil, startTime: Float = 0, dt: Float = 1.0 / 60.0, frames: Int? = nil, accumulate: Bool = false, accumulateTechnique: Bool = false, supersample: Bool = false, capturePrevious: Bool = false, record: Bool = false, cameraPath: Bool = false, camera: Camera? = nil, flight: SIMD3<Float>? = nil, track: CameraTrack? = nil, body: Bool = false, ride: Int? = nil, events: [(time: Float, event: Event)] = []) {
            self.name = name
            self.settings = settings
            self.directLight = directLight
            self.startTime = startTime
            self.dt = dt
            self.frames = frames
            self.accumulate = accumulate
            self.accumulateTechnique = accumulateTechnique
            self.supersample = supersample
            self.capturePrevious = capturePrevious
            self.record = record
            self.cameraPath = cameraPath
            self.camera = camera
            self.flight = flight
            self.track = track
            self.body = body
            self.ride = ride
            self.events = events
        }
    }

    /// Close to the gallery's owl and its neighbours, looking down at the floor's reflections.
    package static let galleryCloseup: Camera = {
        var c = Camera()
        c.position = [1.6, 1.35, -1.6]
        c.yaw = 0.62
        c.pitch = -0.22
        return c
    }()

    /// Scripted camera move for the "camera" settings: a yaw sweep plus dolly that ends at the default camera,
    /// still moving, so the last frame can be scored against the same t = 5 s references as the static frames.
    /// `sceneCamera`: the scene's own default camera, for a scene whose camera depends on how it was built (the crowd,
    /// the city).
    package static func cameraPose(progress p: Float, scene: SceneKind = .cornell, sceneCamera: Camera? = nil) -> Camera {
        if let move = scene.definition.cameraMove, let c = move(p, sceneCamera) { return c }   // the gallery's, the showcase's...
        var c = Camera(), start = Camera()
        if let demo = Scene.demoCamera(scene) ?? (scene.cameraFromScene ? sceneCamera : nil) {
            // A step to the side and back, turning toward the default view.
            c = demo
            start.position = demo.position + SIMD3<Float>(1.5, 0.3, 1.5)
            start.yaw = demo.yaw + 0.35
            start.pitch = demo.pitch - 0.05
        } else {
            start.position = SIMD3<Float>(2.6, 1.7, 2.2)
            start.yaw = -0.9
            start.pitch = -0.25
        }
        return glide(from: start, to: c, p)
    }

    /// The camera at progress p of the way from `start` to `end` (METALRENDERER_PAN=rotate: turning only).
    package static func glide(from start: Camera, to end: Camera, _ p: Float) -> Camera {
        var start = start, c = end
        if ProcessInfo.processInfo.environment["METALRENDERER_PAN"] == "rotate" { start.position = c.position; start.pitch = c.pitch }   // yaw only
        c.position = start.position + (c.position - start.position) * p
        c.yaw = start.yaw + (c.yaw - start.yaw) * p
        c.pitch = start.pitch + (c.pitch - start.pitch) * p
        return c
    }

    /// The modes by name (`METALRENDERER_BENCH=<name>`): the game's, registered with its scenes (SceneProvider).
    package static var modes: [String: () -> [Config]] = [:]
    /// What any other value of METALRENDERER_BENCH runs (the documented one is `1`).
    package static var standardMode: () -> [Config] = { [] }

    package static func configs(for mode: String) -> [Config] {
        _ = SceneRegistry.kinds   // (the modes are registered with the scenes)
        if let build = modes[mode] { return build() }
        if mode != "1" && !mode.isEmpty {
            print("METALRENDERER_BENCH=\(mode) isn't a mode (\(modes.keys.sorted().joined(separator: ", "))): running the default list")
        }
        return standardMode()
    }

    /// Where the current setting's track is: seconds since its first measured frame (0 while it warms up).
    package var trackTime: Float { Float(max(frameInConfig - warmupFrames, 0)) * fixedDt }

    /// Progress through the current setting, 0 at its first frame and 1 at its last.
    package var progressInConfig: Float {
        let total = warmupFrames + (current.frames ?? measuredFrames)
        return Float(frameInConfig) / Float(max(total - 1, 1))
    }

    package struct FrameRecord {
        var config: Int
        var passMs: [String: Double]
        var spanMs: Double          // first pass start -> last pass end
        var cpuMs: Double           // the CPU's work in draw (simulation, uploads, encoding), without the waits
    }

    package static let isEnabled = ProcessInfo.processInfo.environment["METALRENDERER_BENCH"] != nil
    /// Each pass in its own command buffer, for per-pass timings (default). `METALRENDERER_BENCH_SPLIT=0` encodes frames
    /// exactly like normal mode (one command buffer) and reports only the whole-frame GPU time.
    package static let splitPasses = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_SPLIT"] != "0"
    package static let passOrder = ["skin", "blas", "tlas", "lightmap", "trace", "glass", "temporal", "atrous", "composite", "upscale"]

    /// The settings of `list` this GPU can run; the others are named with what they need (Capabilities).
    package static func supported(_ list: [Config], on caps: Capabilities) -> (run: [Config], skipped: [String]) {
        var run: [Config] = [], skipped: [String] = []
        for c in list {
            if let missing = c.resolvedSettings().missing(in: caps) { skipped.append("\(c.name) (needs \(missing))") }
            else { run.append(c) }
        }
        return (run, skipped)
    }

    /// This run's settings: the mode's list (Benchmark+Modes.swift), without the settings this GPU can't run.
    /// `METALRENDERER_BENCH_ONLY="32 lights, 400|camera"` keeps only the settings whose names contain one of these substrings.
    package let configs: [Config] = {
        let (all, skipped) = Benchmark.supported(Benchmark.configs(for: ProcessInfo.processInfo.environment["METALRENDERER_BENCH"] ?? ""),
                                                 on: Capabilities.current)
        skipped.forEach { print("skipped: \($0)") }
        if all.isEmpty {
            print("Nothing to run: this GPU supports none of the mode's settings.")
            exit(0)
        }
        guard let only = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_ONLY"] else { return all }
        let keys = only.split(separator: "|").map(String.init)
        let kept = all.filter { c in keys.contains { c.name.contains($0) } }
        if kept.isEmpty {   // nothing to render: say what the names are instead of running an empty list
            let mode = ProcessInfo.processInfo.environment["METALRENDERER_BENCH"] ?? ""
            let names = all.map { "  " + $0.name + "\n" }.joined()
            let message = "METALRENDERER_BENCH_ONLY=\"\(only)\" matches no setting of METALRENDERER_BENCH=\(mode). "
                + "It keeps the settings whose names contain one of its substrings (separated by |). The names:\n" + names
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
        return kept
    }()

    package let warmupFrames = 60
    package let measuredFrames = 240
    /// The current setting's clock step.
    package var fixedDt: Float { current.dt }
    package let captureDir = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

    private(set) var configIndex = 0
    private(set) var frameInConfig = 0
    private var resolutions: [String] = []
    private let lock = NSLock()
    private var records: [FrameRecord] = []

    package init() {
        resolutions = Array(repeating: "", count: configs.count)
    }

    package var current: Config { configs[configIndex] }
    package var isFinished: Bool { configIndex >= configs.count }
    package var isMeasuring: Bool { frameInConfig >= warmupFrames }
    private var framesInConfig: Int { cut ?? (warmupFrames + (current.frames ?? measuredFrames)) }
    private var framesLeftInConfig: Int { framesInConfig - frameInConfig }
    /// `METALRENDERER_SHOT_SWAP=<k>`: a setting ends, and its picture is taken, `k` frames after the open world's
    /// scene is first made around another tile (0: the first frame of the new scene), to see what a crossing shows.
    package static let swapShot = ProcessInfo.processInfo.environment["METALRENDERER_SHOT_SWAP"].flatMap { Int($0) }
    private var cut: Int?
    package func noteSwap() {
        if let k = Benchmark.swapShot, cut == nil { cut = min(frameInConfig + max(k, 0) + 1, framesInConfig) }
    }
    package var shouldCapture: Bool { framesLeftInConfig == 1 || (current.capturePrevious && framesLeftInConfig == 2) }
    /// A recording setting's frame to save: every other measured one.
    package var shouldRecord: Bool { current.record && isMeasuring && (frameInConfig - warmupFrames) % 2 == 0 }

    package func noteDraw(resolution: String) {
        resolutions[configIndex] = resolution
    }

    /// Most frames the last warm-up frame is held while streaming settles (`hold(settled:)`).
    package static let maxHold = 600
    private var held = 0
    /// Whether to draw the last warm-up frame again instead of advancing: virtual geometry's streaming hasn't
    /// loaded what the view asks for yet (`settled` false), so measuring would start on a coarser cut that a
    /// later run, or a faster disk, wouldn't show. At most `maxHold` frames; the time stands still meanwhile.
    package func hold(settled: Bool) -> Bool {
        guard frameInConfig == warmupFrames - 1, cut == nil else { return false }
        if !settled && held < Benchmark.maxHold {
            held += 1
            return true
        }
        if held > 0 {
            print(settled ? "  streaming settled after \(held) more warm-up frames"
                          : "  streaming not settled after \(held) more warm-up frames: measuring anyway")
        }
        held = 0
        return false
    }

    /// Returns true when the config changed (the caller should reset its animation clock).
    package func advance() -> Bool {
        frameInConfig += 1
        guard frameInConfig >= framesInConfig else { return false }
        cut = nil
        frameInConfig = 0
        configIndex += 1
        return true
    }

    package func record(_ r: FrameRecord) {
        lock.lock(); records.append(r); lock.unlock()
    }

    package func report(gpuName: String) -> String {
        lock.lock(); let all = records; lock.unlock()
        var out = "\nMetalRenderer benchmark — \(gpuName) — \(warmupFrames) warm-up + \(measuredFrames) measured frames per setting\n"
        out += "GPU times are medians in ms (p95 for the total). Frames are serialized so passes never overlap.\n\"span\" = first pass start to last pass end, including gaps between command buffers. \"cpu\" = the CPU's work per frame.\n\n"
        // One column per pass that ran: passOrder first, then any others (e.g. GI technique passes) by name.
        let seen = Set(all.flatMap { $0.passMs.keys })
        let passes = Benchmark.passOrder.filter(seen.contains) + seen.subtracting(Benchmark.passOrder).sorted()
        let header = ["setting", "res"] + passes.map { $0 == "upscale" ? "MetalFX" : $0 } + ["GPU total", "p95", "max fps", "span", "cpu"]
        var rows: [[String]] = [header]
        for (i, c) in configs.enumerated() {
            let frames = all.filter { $0.config == i }
            guard !frames.isEmpty else { continue }
            var row = [c.name, resolutions[i]]
            for pass in passes {
                let v = frames.compactMap { $0.passMs[pass] }
                row.append(v.isEmpty ? "—" : String(format: "%.2f", percentile(v, 0.5)))
            }
            let totals = frames.map { $0.passMs.values.reduce(0, +) }
            let med = percentile(totals, 0.5)
            row.append(String(format: "%.2f", med))
            row.append(String(format: "%.2f", percentile(totals, 0.95)))
            row.append(String(format: "%.0f", 1000 / med))
            row.append(String(format: "%.2f", percentile(frames.map { $0.spanMs }, 0.5)))
            row.append(String(format: "%.2f", percentile(frames.map { $0.cpuMs }, 0.5)))
            rows.append(row)
        }
        let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        for (r, row) in rows.enumerated() {
            out += row.enumerated().map { col, s in
                col == 0 ? s.padding(toLength: widths[col], withPad: " ", startingAt: 0)
                         : String(repeating: " ", count: widths[col] - s.count) + s
            }.joined(separator: "  ") + "\n"
            if r == 0 { out += widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ") + "\n" }
        }
        return out
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }

    // MARK: - Frame capture

    /// A buffer for a copy of `texture` (bgra8Unorm_srgb: the bytes are already sRGB-encoded; the frame encodes the
    /// copy, FrameEncoder.capture) and a closure that writes it as PNG, or (`sequence`: a recording's frame) as a JPEG
    /// numbered in the setting's own folder.
    /// `suffix` goes after the setting's name ("-interp": frame interpolation's in-between picture).
    package func capture(of texture: MTLTexture, device: MTLDevice, sequence: Bool = false, suffix: String = "") -> (buffer: MTLBuffer, write: () -> Void)? {
        guard var dir = captureDir else { return nil }
        let w = texture.width, h = texture.height, rowBytes = w * 4
        guard let buffer = device.makeBuffer(length: rowBytes * h, options: .storageModeShared) else { return nil }
        let name = String(format: "%02d-", configIndex) + current.name
            .replacingOccurrences(of: "[^A-Za-z0-9.]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let fileName: String, type: UTType
        if sequence {
            dir.appendPathComponent(name)
            (fileName, type) = (String(format: "f%04d.jpg", (frameInConfig - warmupFrames) / 2 + 1), .jpeg)
        } else {
            (fileName, type) = (name + (framesLeftInConfig == 2 ? "-prev" : "") + suffix + ".png", .png)
        }
        let url = dir.appendingPathComponent(fileName)
        return (buffer, {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let ctx = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: bitmapInfo),
                  let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
            CGImageDestinationFinalize(dest)
        })
    }
}

/// A camera's way through a scene for a benchmark setting (`Config.track`): keys of where it is and what it looks at,
/// at times in seconds, joined by Catmull-Rom curves and eased in and out at each key's time. Before the first key it
/// holds the first pose, after the last the last.
package struct CameraTrack {
    package struct Key {
        package var time: Float
        package var position: SIMD3<Float>
        package var target: SIMD3<Float>

        /// (As the memberwise initializer, for the modules above this one.)
        package init(time: Float, position: SIMD3<Float>, target: SIMD3<Float>) {
            self.time = time
            self.position = position
            self.target = target
        }
    }
    package var keys: [Key]
    /// Straight from key to key at a steady pace (a walk's dense keys), not curved and eased at each.
    var linear = false

    package init(_ keys: [Key], linear: Bool = false) {
        precondition(!keys.isEmpty && zip(keys, keys.dropFirst()).allSatisfy { $0.time < $1.time }, "a track's keys in time")
        self.keys = keys
        self.linear = linear
    }

    var duration: Float { keys.last!.time }

    /// Where the camera is and what it looks at, at `t` seconds.
    func pose(at t: Float) -> (position: SIMD3<Float>, target: SIMD3<Float>) {
        guard let next = keys.firstIndex(where: { $0.time > t }) else { return (keys.last!.position, keys.last!.target) }
        guard next > 0 else { return (keys[0].position, keys[0].target) }
        let a = keys[next - 1], b = keys[next]
        let u = (t - a.time) / (b.time - a.time), s = u * u * (3 - 2 * u)
        if linear { return (a.position + (b.position - a.position) * u, a.target + (b.target - a.target) * u) }
        let before = keys[max(next - 2, 0)], after = keys[min(next + 1, keys.count - 1)]
        func curve(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) -> SIMD3<Float> {
            let s2 = s * s, s3 = s2 * s
            return 0.5 * ((2 * p1) + (p2 - p0) * s + (2 * p0 - 5 * p1 + 4 * p2 - p3) * s2 + (3 * p1 - p0 - 3 * p2 + p3) * s3)
        }
        return (curve(before.position, a.position, b.position, after.position), curve(before.target, a.target, b.target, after.target))
    }

    /// The camera at `t` (Camera.forward: yaw 0 looks down -z, a positive yaw toward +x).
    package func camera(at t: Float) -> Camera {
        let (position, target) = pose(at: t)
        let d = simd_normalize(target - position)
        var c = Camera()
        c.position = position
        c.yaw = atan2(d.x, -d.z)
        c.pitch = asin(max(-1, min(1, d.y)))
        return c
    }
}
