import CoreGraphics
import Foundation
import Metal
import simd

/// Training data for our own denoising upscaler (Tools/neural). Two runs over the same clips:
///
/// - `METALRENDERER_BENCH=dataset` renders each clip as the app does (its GI method, MetalFX 3x from 0.5x) with the
///   camera on a seeded track, and saves every measured frame's inputs to the denoising scaler as float16 arrays
///   (.npy), MetalFX's output (the baseline to beat) and a JSON row: time, camera, jitter, exposure.
/// - `METALRENDERER_BENCH=datasetref` reads those rows and renders, for every frame without one yet, a supersampled
///   path-traced reference at the output resolution, in linear light, at that frame's time and camera. It can be
///   stopped and run again: it carries on with the frames left.
///
/// `METALRENDERER_DATASET="scenes=cornell|gallery,clips=2,frames=32,spp=1024,seed=1,factor=3,bounces=4"` chooses the
/// clips (`DatasetSpec` has the defaults); both runs need the same value. They go to `METALRENDERER_DATASET_DIR`
/// (default `dataset`): `<clip>/clip.json`, `<clip>/fNNNN.json`, `<clip>/fNNNN-<buffer>.npy`.
extension Benchmark {
    struct DatasetSpec {
        // Not the stress hall: its references take far longer than any other scene's.
        var scenes: [SceneKind] = [.cornell, .gallery, .spots, .sun, .area, .tubes, .emissive, .mixed, .fog, .valley, .market,
                                   .forest, .randomRoom]
        var clips = 4           // per scene, each with its own seed, start time and camera track
        var rooms = 24          // ...but this many random rooms (Scene+Training.swift): each clip is another room
        var frames = 32         // saved per clip, after the warm-up
        var spp = 1024          // frames averaged per reference
        var seed = 1
        var bounces = 4         // the references' path length
        var factor: CGFloat = 3
        var scale: CGFloat = 0.5
        var directory = URL(fileURLWithPath: "dataset")

        init(env: [String: String] = ProcessInfo.processInfo.environment) {
            if let dir = env["METALRENDERER_DATASET_DIR"] { directory = URL(fileURLWithPath: dir) }
            for item in (env["METALRENDERER_DATASET"] ?? "").split(separator: ",") {
                let kv = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { print("METALRENDERER_DATASET: can't read \(item)"); continue }
                switch kv[0] {
                case "scenes": scenes = kv[1].split(separator: "|").compactMap { SceneKind(envText: String($0)) }
                case "clips": clips = Int(kv[1]) ?? clips
                case "rooms": rooms = Int(kv[1]) ?? rooms
                case "frames": frames = Int(kv[1]) ?? frames
                case "spp": spp = Int(kv[1]) ?? spp
                case "seed": seed = Int(kv[1]) ?? seed
                case "bounces": bounces = Int(kv[1]) ?? bounces
                case "factor": factor = Double(kv[1]).map { CGFloat($0) } ?? factor
                case "scale": scale = Double(kv[1]).map { CGFloat($0) } ?? scale
                default: print("METALRENDERER_DATASET: unknown key \(kv[0])")
                }
            }
        }

        /// The clips, scene by scene: a seed for the scene, a start time and a camera track each.
        var clipList: [DatasetClip] {
            scenes.flatMap { kind in
                (0..<(kind == .randomRoom ? rooms : clips)).map { c in
                    var rng = BlueNoise.SplitMix64(seed: UInt64(seed) &* 0x1_0000 &+ UInt64(kind.rawValue) &* 0x100 &+ UInt64(c))
                    var scene = SceneSettings(kind: kind)
                    if kind == .market { scene.lights = SceneSettings.marketLights }
                    scene.seed = seed * 100 + c
                    let start = Float.random(in: 0..<(kind.dayCycle ?? 20), using: &rng)
                    let drift = CameraDrift(style: (c + kind.rawValue) % CameraDrift.styles, reach: kind == .cornell ? 0.3 : 1, using: &rng)
                    return DatasetClip(name: "\(kind)-\(seed)-\(c)", index: c, scene: scene, startTime: start, drift: drift)
                }
            }
        }
    }

    struct DatasetClip {
        var name: String
        var index: Int          // its number within its scene
        var scene: SceneSettings
        var startTime: Float
        var drift: CameraDrift

        /// Settings both of its runs share: a room's glTF models at full detail and with every texture level, so
        /// the references don't get finer meshes or mips than the noisy frames had (as the gallery's references).
        func shared(_ s: inout RenderSettings) {
            guard scene.kind == .randomRoom else { return }
            s.virtualGeometry.enabled = false
            s.textureBudgetMB = 4096
        }
    }

    /// What a setting of the dataset runs saves: a clip's inputs every measured frame, or one frame's reference.
    enum DatasetCapture {
        case inputs(clip: URL)
        case reference(clip: URL, frame: Int)
    }

    /// The JSON row saved with each frame's arrays: what the network and the reference need besides the images.
    struct DatasetFrame: Codable {
        var frame: Int
        var time: Float                     // the animation clock
        var camera: [Float]                 // position x, y, z, yaw, pitch, fovY
        var jitter: [Float]                 // this frame's and the last frame's sub-pixel offset, in render pixels
        var prevJitter: [Float]
        var exposure: Float                 // the multiplier the tone curve applies first
        var size: [Int]                     // render width, height
        var outSize: [Int]                  // output width, height

        var cameraPose: Camera {
            var c = Camera()
            c.position = SIMD3(camera[0], camera[1], camera[2])
            (c.yaw, c.pitch, c.fovY) = (camera[3], camera[4], camera[5])
            return c
        }
    }

    /// `METALRENDERER_BENCH=dataset`: every clip, as the app renders it (its GI method, upscaled by MetalFX), but those
    /// already saved (their last frame has its row): a larger dataset adds clips to a smaller one.
    static func dataset() -> [Config] {
        let spec = DatasetSpec()
        let clips = spec.clipList.filter { clip in
            !FileManager.default.fileExists(atPath: spec.directory.appendingPathComponent(clip.name)
                .appendingPathComponent(datasetFileName(frame: spec.frames - 1, buffer: nil)).path)
        }
        print("dataset: \(clips.count) of \(spec.clipList.count) clips to render")
        return clips.map { clip in
            var c = Config(clip.name, scale: spec.scale, upscale: spec.factor, gi: RenderSettings().giMode, scene: clip.scene,
                           clip.shared).drifting(clip.drift).frames(spec.frames)
            c.startTime = clip.startTime
            c.dataset = .inputs(clip: spec.directory.appendingPathComponent(clip.name))
            return c
        }
    }

    /// `METALRENDERER_BENCH=datasetref`: a reference for every saved frame that has none yet. Every scene's first clip
    /// first, then every scene's second, ...: a run stopped early leaves complete clips of every scene to train on.
    static func datasetReferences() -> [Config] {
        let spec = DatasetSpec()
        let decoder = JSONDecoder()
        var list: [Config] = [], missing = 0
        for clip in spec.clipList.enumerated().sorted(by: { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }).map(\.element) {
            let dir = spec.directory.appendingPathComponent(clip.name)
            for f in 0..<spec.frames {
                let row = dir.appendingPathComponent(datasetFileName(frame: f, buffer: nil))
                guard let data = try? Data(contentsOf: row), let frame = try? decoder.decode(DatasetFrame.self, from: data) else {
                    missing += 1
                    continue
                }
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent(datasetFileName(frame: f, buffer: "reference")).path) {
                    continue
                }
                var c = Config("\(clip.name) f\(f)", scale: spec.scale * spec.factor, gi: .pathTraced, scene: clip.scene) {
                    $0.bounces = spec.bounces
                    clip.shared(&$0)
                }.from(frame.cameraPose).reference(frames: spec.spp, at: frame.time, supersample: true)
                c.dataset = .reference(clip: dir, frame: f)
                list.append(c)
            }
        }
        if missing > 0 { print("datasetref: \(missing) frames have no row in \(spec.directory.path): run METALRENDERER_BENCH=dataset first") }
        print("datasetref: \(list.count) references to render")
        return list
    }

    /// Writes a dataset file, saying so when it can't (a full disk would otherwise leave holes in the dataset).
    static func datasetWrite(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)   // a stopped run leaves no half-written file
        } catch {
            print("dataset: can't write \(url.path): \(error.localizedDescription)")
        }
    }

    static func datasetFileName(frame: Int, buffer: String?) -> String {
        String(format: "f%04d", frame) + (buffer.map { "-" + $0 + ".npy" } ?? ".json")
    }

    // MARK: - Float arrays

    /// Channels and bytes per channel of the formats the benchmark captures.
    static func layout(_ format: MTLPixelFormat) -> (channels: Int, bytes: Int) {
        switch format {
        case .rgba32Float: return (4, 4)
        case .r32Float: return (1, 4)
        case .rgba16Float: return (4, 2)
        case .rg16Float: return (2, 2)
        case .r16Float: return (1, 2)
        default: return (4, 1)   // bgra8Unorm_srgb, the drawable
        }
    }

    static func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
        let l = layout(format)
        return l.channels * l.bytes
    }

    /// A buffer for a copy of `texture` (FrameEncoder.capture) and a closure that writes its first `keep` channels to
    /// `url` as a float16 .npy array of shape (height, width, keep).
    static func floatCapture(of texture: MTLTexture, keep: Int, to url: URL, device: MTLDevice) -> (buffer: MTLBuffer, write: () -> Void)? {
        let w = texture.width, h = texture.height, (channels, bytes) = layout(texture.pixelFormat)
        guard let buffer = device.makeBuffer(length: w * h * channels * bytes, options: .storageModeShared) else { return nil }
        return (buffer, {
            var values = [Float16](repeating: 0, count: w * h * keep)
            let source = buffer.contents()
            if bytes == 2 {
                let p = source.bindMemory(to: Float16.self, capacity: w * h * channels)
                for i in 0..<w * h { for c in 0..<keep { values[i * keep + c] = p[i * channels + c] } }
            } else {
                let p = source.bindMemory(to: Float.self, capacity: w * h * channels)
                for i in 0..<w * h { for c in 0..<keep { values[i * keep + c] = Float16(p[i * channels + c]) } }
            }
            // .npy version 1.0: magic, header length, a Python dict padded with spaces to 64 bytes, the data.
            var header = "{'descr': '<f2', 'fortran_order': False, 'shape': (\(h), \(w), \(keep)), }"
            header += String(repeating: " ", count: 63 - (10 + header.count) % 64) + "\n"
            var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0, UInt8(header.count & 0xff), UInt8(header.count >> 8)])
            data.append(Data(header.utf8))
            values.withUnsafeBytes { data.append(contentsOf: $0) }
            datasetWrite(data, to: url)
        })
    }
}

/// A smooth, seeded camera move for a dataset clip (unlike CameraTrack's keys, relative to wherever the scene puts its camera), as offsets from the clip's start pose in the camera's own frame:
/// a drift at constant speed and turn rate, plus wobble (sums of sines). `style` picks what dominates, so the clips
/// cover a still camera, pans, dollies and a shaky hand with fast turns (disocclusions).
struct CameraDrift {
    static let styles = 4
    var velocity = SIMD3<Float>()       // m/s: right, up, forward
    var yawRate: Float = 0              // rad/s
    var wobble: [(amplitude: SIMD3<Float>, hertz: Float, phase: Float)] = []
    var yawWobble = SIMD3<Float>()      // amplitude (rad), hertz, phase
    var pitchWobble = SIMD3<Float>()

    init(style: Int, reach: Float, using rng: inout BlueNoise.SplitMix64) {
        func r(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &rng) }
        func sign() -> Float { Bool.random(using: &rng) ? 1 : -1 }
        func shake(_ amplitude: Float, _ hertz: ClosedRange<Float>) -> (SIMD3<Float>, Float, Float) {
            (SIMD3(r(-1...1), r(-1...1), r(-1...1)) * amplitude, r(hertz), r(0...6.28))
        }
        switch style {
        case 0:   // the camera holds still (as a hand would): only the scene moves
            wobble = [shake(0.01 * reach, 0.2...0.8)]
        case 1:   // a pan, looking up and down a little
            yawRate = sign() * r(0.2...1.0)
            pitchWobble = SIMD3(r(0.02...0.1), r(0.1...0.5), r(0...6.28))
        case 2:   // a dolly or a strafe, turning slowly
            velocity = normalize(SIMD3(r(-1...1), r(-0.2...0.2), r(-1...1))) * r(0.3...1.5) * reach
            yawRate = r(-0.2...0.2)
        default:  // a shaky hand with quick turns
            wobble = [shake(0.15 * reach, 0.3...1.0), shake(0.03 * reach, 1.5...4)]
            yawWobble = SIMD3(r(0.15...0.4), r(0.4...1.5), r(0...6.28))
            pitchWobble = SIMD3(r(0.05...0.15), r(0.3...1.0), r(0...6.28))
        }
    }

    /// The pose `t` seconds into the clip.
    func pose(at t: Float, from base: Camera) -> Camera {
        func wave(_ w: SIMD3<Float>) -> Float { w.x * sin(2 * .pi * w.y * t + w.z) }
        var offset = velocity * t
        for w in wobble { offset += w.amplitude * sin(2 * .pi * w.hertz * t + w.phase) }
        var c = base
        c.position += base.right * offset.x + base.up * offset.y + base.forward * offset.z
        c.yaw += yawRate * t + wave(yawWobble)
        c.pitch = min(max(base.pitch + wave(pitchWobble), -1.3), 1.3)
        return c
    }
}
