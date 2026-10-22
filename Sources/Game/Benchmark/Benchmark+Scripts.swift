import EngineCore
import Foundation
import MetalRenderer

/// Swift scripts without the window (README, "Scripts"): one run and its picture, or an app the tools drive.
extension Benchmark {
    /// `METALRENDERER_BENCH=script METALRENDERER_SCRIPT=<file.swift> [METALRENDERER_SCRIPT_ARGS="a b"]`: the stage (or
    /// the scene METALRENDERER_SCENE names) in the app's look, the script run at the first frame; once it is done and
    /// its scene is in, the warm-up and METALRENDERER_SHOT_FRAMES frames (default 30), the last saved as
    /// `script-<name>.png` in METALRENDERER_BENCH_DIR.
    static func script() -> [Config] {
        let frames = env["METALRENDERER_SHOT_FRAMES"].flatMap { Int($0) }.map { max(1, $0) } ?? 30
        guard let path = env["METALRENDERER_SCRIPT"] else {   // (the stage as it is)
            return [stage("script").still().frames(frames)]
        }
        let arguments = env["METALRENDERER_SCRIPT_ARGS"].map { $0.split(separator: " ").map(String.init) } ?? []
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return [stage("script \(name)").still().frames(frames).at(0, .script(path, arguments: arguments))]
    }

    /// `METALRENDERER_BENCH=serve`: the stage (or METALRENDERER_SCENE's) held, with the script socket open, for
    /// `Tools/script.py` and the MCP server (`Tools/mcp/metalrenderer.py`) to drive without a window. It quits when a
    /// tool sends `{"quit": true}` (`Tools/script.py --quit`). With METALRENDERER_SCRIPT, that script runs first.
    static func serve() -> [Config] {
        var c = stage("serve").still().serving()
        if let path = env["METALRENDERER_SCRIPT"] { c = c.at(0, .script(path, arguments: [])) }
        return [c]
    }

    /// The app's look (cascades, MetalFX 3x from 0.5x) on the stage.
    private static func stage(_ name: String) -> Config {
        Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .stage))
    }
}
