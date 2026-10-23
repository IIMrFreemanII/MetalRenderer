import AppKit
import Darwin
import EngineCore
import Foundation

/// The running app's socket: `Tools/script.py` and the MCP server (`Tools/mcp/metalrenderer.py`) send it requests,
/// one JSON line each, and read JSON lines back until `{"exit": n}`:
///
///   {"path": "<script.swift>", "args": [...]}   runs a script (ScriptRunner): {"out": "<text>"}..., then its status
///   {"state": true}                             the app's state (Renderer.scriptState): {"state": {...}}
///   {"capture": "<file.png>", "scale": 0.5}     the next frame as a PNG: {"capture": "<file.png>"}
///   {"place": {...}}, {"move": {...}},           typed edits of the scene's file and the camera, no compile
///   {"remove": {...}}, {"camera": {...}}        (SceneCommand): {"result": {...}}
///   {"modeller": {...}}, …                      a request another module registered (ScriptRequests)
///   {"quit": true}                              a headless run quits (the window's app doesn't)
///
/// The socket is `/tmp/metalrenderer-<uid>/<pid>.sock` (a path in the checkout would pass the 104 bytes a socket's
/// path may have); its path is written to `<scratch>/script.socket` (`.build-dev`, `.build`), where the tools of the
/// same checkout and build look for it.
package final class ScriptServer {
    package let socketPath: String
    private let pointer: URL
    private let fd: Int32
    private unowned let renderer: Renderer

    package init?(renderer: Renderer, scratch: URL) {
        self.renderer = renderer
        let dir = "/tmp/metalrenderer-\(getuid())"
        mkdir(dir, 0o700)
        ScriptServer.removeStale(in: dir)
        socketPath = "\(dir)/\(getpid()).sock"
        pointer = scratch.appendingPathComponent("script.socket")
        unlink(socketPath)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            print("Scripts: can't listen on \(socketPath): \(String(cString: strerror(errno)))")
            close(fd)
            return nil
        }
        chmod(socketPath, 0o600)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try? (socketPath + "\n").write(to: pointer, atomically: true, encoding: .utf8)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "MetalRenderer.script.server"
        thread.start()
    }

    /// The socket and its pointer file go (at quit).
    package func stop() {
        close(fd)
        unlink(socketPath)
        if let named = try? String(contentsOf: pointer, encoding: .utf8), named.trimmingCharacters(in: .whitespacesAndNewlines) == socketPath {
            try? FileManager.default.removeItem(at: pointer)
        }
    }

    /// The sockets of apps that are gone (a crash leaves its socket behind).
    private static func removeStale(in dir: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".sock") {
            if let pid = Int32(name.dropLast(5)), kill(pid, 0) != 0 && errno == ESRCH { unlink("\(dir)/\(name)") }
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // closed (stop)
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "MetalRenderer.script.client"
            thread.start()
        }
    }

    /// One client: its request, the answer, the socket closed.
    private func serve(_ client: Int32) {
        let connection = Connection(client)
        defer { connection.close() }
        guard let line = connection.readLine(),
              let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            connection.send(["out": "script server: send one JSON object on a line\n"])
            connection.send(["exit": 2])
            return
        }
        let done = DispatchSemaphore(value: 0)
        if let path = request["path"] as? String {
            let arguments = request["args"] as? [String] ?? []
            guard let scripts = renderer.scripts else {
                connection.send(["out": "scripts are off in this app\n"])
                connection.send(["exit": 2])
                return
            }
            var status: Int32 = 0
            scripts.run(path: path, arguments: arguments, output: ScriptOutput { connection.send(["out": $0]) }) {
                status = $0
                done.signal()
            }
            done.wait()
            connection.send(["exit": Int(status)])
        } else if let decoded = SceneCommand.decode(request) {
            // A typed edit (place, move, remove, camera): no compile; answered once its scene is in.
            let command: SceneCommand
            switch decoded {
            case .success(let c): command = c
            case .failure(let failure):
                connection.send(["out": "\(failure)\n"])
                connection.send(["exit": 2])
                return
            }
            var result: Result<[String: Any], SceneCommand.Failure> = .failure(.init("not done"))
            renderer.perform { r in
                result = command.apply(to: r)
                done.signal()
            }
            done.wait()
            switch result {
            case .success(let answer):
                waitForScene()
                connection.send(["result": answer])
                connection.send(["exit": 0])
            case .failure(let failure):
                connection.send(["out": "\(failure)\n"])
                connection.send(["exit": 1])
            }
        } else if request["state"] != nil {
            var state: [String: Any] = [:]
            renderer.perform { r in
                state = r.scriptState()
                done.signal()
            }
            done.wait()
            connection.send(["state": state])
            connection.send(["exit": 0])
        } else if let path = request["capture"] as? String {
            let scale = request["scale"] as? Double ?? 1
            var written = false
            renderer.perform { r in
                r.captureFrame(to: URL(fileURLWithPath: path), scale: scale) { ok in
                    written = ok
                    done.signal()
                }
            }
            if done.wait(timeout: .now() + 20) == .timedOut {
                connection.send(["out": "no frame within 20 s (is the window hidden or minimised?)\n"])
                connection.send(["exit": 1])
            } else {
                if written { connection.send(["capture": path]) } else { connection.send(["out": "could not write \(path)\n"]) }
                connection.send(["exit": written ? 0 : 1])
            }
        } else if let (key, body, handle) = ScriptRequests.handler(for: request) {
            // Another module's request (ScriptRequests): its handler answers on this thread.
            switch handle(body) {
            case .success(let answer):
                connection.send(["result": answer])
                connection.send(["exit": 0])
            case .failure(let failure):
                connection.send(["out": "\(key): \(failure)\n"])
                connection.send(["exit": failure.badRequest ? 2 : 1])
            }
        } else if request["quit"] != nil {
            guard Headless.isEnabled else {
                connection.send(["out": "the window's app quits only by hand\n"])
                connection.send(["exit": 1])
                return
            }
            connection.send(["exit": 0])
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } else {
            connection.send(["out": "unknown request: \(line) (the keys: path, state, capture, quit, \(SceneCommand.keys.joined(separator: ", ")), \(ScriptRequests.keys.joined(separator: ", ")))\n"])
            connection.send(["exit": 2])
        }
    }

    /// Returns once the scene the settings ask for is in (at most a minute), as a script's run does.
    private func waitForScene() {
        let start = Date()
        while Date().timeIntervalSince(start) < 60 {
            let settled = DispatchSemaphore(value: 0)
            var ready = false
            renderer.perform { r in
                ready = r.sceneSettled
                settled.signal()
            }
            settled.wait()
            if ready { return }
            Thread.sleep(forTimeInterval: 1.0 / 240)
        }
    }

    /// A client's socket: lines in, JSON lines out (sends from any thread, one at a time).
    private final class Connection {
        private let fd: Int32
        private let lock = NSLock()
        private var open = true

        init(_ fd: Int32) { self.fd = fd }

        /// The first line the client sends (at most 1 MB).
        func readLine() -> String? {
            var data = Data(), byte: UInt8 = 0
            while data.count < 1 << 20 {
                let n = read(fd, &byte, 1)
                if n <= 0 { break }
                if byte == UInt8(ascii: "\n") { return String(decoding: data, as: UTF8.self) }
                data.append(byte)
            }
            return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
        }

        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(UInt8(ascii: "\n"))
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { open = false; return }   // the client went away: the script runs on
                    offset += n
                }
            }
        }

        func close() {
            lock.lock()
            open = false
            lock.unlock()
            Darwin.close(fd)
        }
    }
}
