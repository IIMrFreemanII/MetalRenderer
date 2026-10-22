import EngineCore
import Foundation

/// A running script's way to the app (README, "Scripts"). Not a facade: a script calls the engine itself
/// (`Renderer`, `Scene`, `SceneFile`, the settings); this is only what the threads need: run a closure on the render
/// thread and wait for it, wait for a scene or for frames, a closure every frame, and where `print` goes.
package final class ScriptRun {
    package let renderer: Renderer
    /// The script's file, and the arguments it was run with (`Tools/script.py <file> <arguments>`).
    package let path: String
    package let arguments: [String]
    private let output: ScriptOutput
    private let lock = NSLock()
    private var didFail = false

    init(renderer: Renderer, path: String, arguments: [String], output: ScriptOutput) {
        self.renderer = renderer
        self.path = path
        self.arguments = arguments
        self.output = output
    }

    /// Whether the script threw or said it failed (`fail`): the run ends with exit status 1.
    package var failed: Bool { lock.lock(); defer { lock.unlock() }; return didFail }

    /// Text for whoever ran the script, and the app's output (the script's `print`).
    package func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
        output.write(text)
    }

    /// The run fails (exit status 1), with `error` said.
    package func fail(_ error: Any) {
        lock.lock()
        didFail = true
        lock.unlock()
        write("error: \(error)\n")
    }

    // MARK: - The render thread

    /// Runs `body` on the render thread, before its next frame, and returns what it returns (any thread; on the render
    /// thread, at once).
    package func render<T>(_ body: (Renderer) -> T) -> T {
        withoutActuallyEscaping(body) { onRenderThread($0) }
    }

    package func render<T>(_ body: (Renderer) throws -> T) throws -> T {
        try withoutActuallyEscaping(body) { body in try onRenderThread { r in Result { try body(r) } }.get() }
    }

    private func onRenderThread<T>(_ body: @escaping (Renderer) -> T) -> T {
        if renderer.renderThread.isCurrent { return body(renderer) }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        renderer.perform { r in
            result = body(r)
            done.signal()
        }
        done.wait()
        return result!
    }

    /// Whether waiting here would never end: on the render thread (inside `render`, a short script, `onFrame`).
    private func cannotWait(_ what: String) -> Bool {
        guard renderer.renderThread.isCurrent else { return false }
        write("\(what) on the render thread (in render {}, a short script or onFrame) would never return: skipped\n")
        return true
    }

    // MARK: - Waiting

    /// Returns once the scene the settings ask for is installed: nothing loading, no remake or scene-file edit waiting.
    /// The app's loads go on in the background meanwhile (a benchmark's are made at once).
    package func waitForScene(timeout: TimeInterval = 600) {
        guard !cannotWait("waitForScene()") else { return }
        let start = Date()
        while !render({ $0.sceneSettled }) {
            if Date().timeIntervalSince(start) > timeout {
                write("waitForScene(): the scene isn't in after \(Int(timeout)) s (is the window hidden?)\n")
                return
            }
            Thread.sleep(forTimeInterval: 1.0 / 240)
        }
    }

    /// Returns once `frames` more frames have been drawn (at most `timeout` seconds: a hidden window draws none).
    package func wait(frames: Int, timeout: TimeInterval = 60) {
        guard !cannotWait("wait(frames:)") else { return }
        let first = render { $0.frameIndex }, start = Date()
        while render({ $0.frameIndex }) &- first < UInt32(max(frames, 0)) {
            if Date().timeIntervalSince(start) > timeout { return }
            Thread.sleep(forTimeInterval: 1.0 / 240)
        }
    }

    /// Returns after `seconds` (the frames go on meanwhile).
    package func wait(seconds: Double) {
        guard !cannotWait("wait(seconds:)") else { return }
        Thread.sleep(forTimeInterval: max(seconds, 0))
    }

    // MARK: - Every frame

    /// `hook` every frame, on the render thread, with the frame's time step (before the camera and the scene move),
    /// until this script runs again or calls `stop()`.
    package func onFrame(_ hook: @escaping (Renderer, Float) -> Void) {
        let owner = path
        renderer.perform { $0.scriptHooks.append(ScriptHook(owner: owner, run: hook)) }
    }

    /// The script's `onFrame` closures stop.
    package func stop() {
        let owner = path
        renderer.perform { $0.scriptHooks.removeAll { $0.owner == owner } }
    }

    // MARK: - Pictures

    /// The next frame as a PNG at `path` (default: in the scripts' folder), `scale` times its size; returns where it
    /// went, or nil if no frame came within `timeout` seconds.
    @discardableResult
    package func capture(_ path: String? = nil, scale: Double = 1, timeout: TimeInterval = 20) -> URL? {
        guard !cannotWait("capture()") else { return nil }
        let folder = renderer.scripts?.workDirectory ?? FileManager.default.temporaryDirectory
        let url = path.map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("captures").appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        let done = DispatchSemaphore(value: 0)
        var written: URL?
        renderer.perform { $0.captureFrame(to: url, scale: scale) { ok in written = ok ? url : nil; done.signal() } }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return written
    }
}

/// Where a script's output goes (the socket's client, the benchmark's log), until the run is over: what its
/// `onFrame` closures print later goes to the app's output only.
package final class ScriptOutput {
    private let lock = NSLock()
    private var send: ((String) -> Void)?

    package init(_ send: @escaping (String) -> Void) { self.send = send }

    package func write(_ text: String) {
        lock.lock()
        let send = send
        lock.unlock()
        send?(text)
    }

    package func detach() {
        lock.lock()
        send = nil
        lock.unlock()
    }
}

/// A script's closure every frame (ScriptRun.onFrame), by the script's file.
package struct ScriptHook {
    package let owner: String
    package let run: (Renderer, Float) -> Void
}

/// The next frame's picture as a PNG at `url`, `scale` times its size (Renderer.captureFrame); `done` says whether it
/// was written.
package struct FrameCapture {
    package let url: URL
    package let scale: Double
    package let done: (Bool) -> Void
}
