import Darwin
import EngineCore
import Foundation

/// Runs Swift scripts in the app, one at a time in the order asked: compiles each (ScriptCompiler), loads its bundle,
/// calls its entry on a thread of its own, then waits for the scene it asked for, so a run that is done is on screen.
/// Bundles are never unloaded (a script's closures, its `onFrame` hooks and the prefabs it registers, live on).
package final class ScriptRunner {
    private unowned let renderer: Renderer
    private let compiler: ScriptCompiler
    private let queue = DispatchQueue(label: "MetalRenderer.script", qos: .userInitiated)
    private let lock = NSLock()
    private var queued = 0
    private var count = 0

    package init(renderer: Renderer, compiler: ScriptCompiler = ScriptCompiler()) {
        self.renderer = renderer
        self.compiler = compiler
    }

    /// Where the generated sources, bundles and captures go, and the build's scratch folder (`.build-dev`, `.build`).
    package var workDirectory: URL { compiler.workDirectory }
    package var scratch: URL { compiler.scratch }

    /// A script is running or waiting to (a benchmark holds its frame meanwhile).
    package var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return queued > 0 }

    /// Runs the script at `path`; what it prints goes to `output`, and `done` gets its exit status (0 ok, 1 it failed,
    /// 2 it didn't compile or load). Any thread.
    package func run(path: String, arguments: [String] = [], output: ScriptOutput, done: @escaping (Int32) -> Void = { _ in }) {
        lock.lock()
        queued += 1
        lock.unlock()
        queue.async { [self] in
            let status = execute(path: path, arguments: arguments, output: output)
            output.detach()
            lock.lock()
            queued -= 1
            lock.unlock()
            done(status)
        }
    }

    private func execute(path: String, arguments: [String], output: ScriptOutput) -> Int32 {
        func say(_ text: String) {
            FileHandle.standardOutput.write(Data(text.utf8))
            output.write(text)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            say("script: can't read \(url.path)\n")
            return 2
        }
        lock.lock()
        count += 1
        let n = count
        lock.unlock()
        let start = Date()
        let bundle: URL
        switch compiler.compile(text, path: url.path, number: n) {
        case .success(let made): bundle = made
        case .failure(let failure):
            say("\(failure)\n")
            return 2
        }
        let compiledMs = Int(Date().timeIntervalSince(start) * 1000)
        guard let image = dlopen(bundle.path, RTLD_NOW | RTLD_LOCAL) else {
            say("script: can't load \(bundle.lastPathComponent): \(String(cString: dlerror()))\n")
            return 2
        }
        guard let symbol = dlsym(image, ScriptSource.entry) else {
            say("script: \(bundle.lastPathComponent) has no \(ScriptSource.entry)\n")
            return 2
        }
        let entry = unsafeBitCast(symbol, to: (@convention(c) (UnsafeRawPointer) -> Void).self)
        // The same script run again: its closures of the last run stop first (the render thread runs work in order).
        let owner = url.path
        renderer.perform { $0.session.scriptHooks.removeAll { $0.owner == owner } }
        let run = ScriptRun(renderer: renderer, path: owner, arguments: arguments, output: output)
        let handle = Unmanaged.passRetained(run)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            entry(UnsafeRawPointer(handle.toOpaque()))
            finished.signal()
        }
        thread.name = "MetalRenderer.script.run"
        thread.stackSize = 8 << 20   // as the render thread's: engine code called from a script needs it
        thread.start()
        finished.wait()
        run.waitForScene()
        handle.release()
        let ranMs = Int(Date().timeIntervalSince(start) * 1000) - compiledMs
        say("script: \(url.lastPathComponent) \(run.failed ? "failed" : "done") (compiled in \(compiledMs) ms, ran in \(ranMs) ms)\n")
        return run.failed ? 1 : 0
    }
}
