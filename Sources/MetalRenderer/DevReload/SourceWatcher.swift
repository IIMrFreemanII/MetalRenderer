import CoreServices
import Foundation

/// What a saved file asks the dev build's hot reload for (DevReload).
package enum DevChange: Hashable {
    case shaders                    // a .metal file of the engine's: the shaders are compiled again
    case game                       // Sources/Game: its code is built again and loaded into the app
    case code(String)               // any other module's Swift (its folder): that needs a relaunch
    case sceneFile(String)          // Assets/Scenes/<kind>.scene (its path)
    case plants                     // Assets/Plants
    case buildings                  // Assets/Buildings
    case procedural                 // Assets/Procedural
    case garment(String)            // Assets/Garments/<id>.garment.json (its path)

    /// What saving `path` (under `root`, the package's folder) changes; nil: nothing that reloads.
    package static func of(_ path: String, root: String) -> DevChange? {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return nil }
        let relative = String(path.dropFirst(base.count))
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 3, let name = parts.last, !name.hasPrefix("."), !name.hasPrefix("~"), !name.hasSuffix("~") else { return nil }
        let ext = (name as NSString).pathExtension
        switch (parts[0], parts[1]) {
        case ("Sources", "MetalRenderer") where ext == "metal": return .shaders
        case ("Sources", "Game") where ext == "swift": return .game
        case ("Sources", let module) where ext == "swift": return .code(module)
        case ("Assets", "Scenes") where ext == "scene" && parts.count == 3: return .sceneFile(path)
        case ("Assets", "Plants") where ext == "json": return .plants
        case ("Assets", "Buildings") where ext == "json": return .buildings
        case ("Assets", "Procedural") where ext == "json": return .procedural
        case ("Assets", "Garments") where name.hasSuffix(".garment.json"): return .garment(path)
        default: return nil
        }
    }
}

/// Watches the package's `Sources` and `Assets` for saves (FSEvents, file by file) and hands what they change to
/// `changed` once the saves settle: `settle` seconds without another (an editor's save is a few events, a script's
/// a burst). Its queue; the dev build only (DevReload).
package final class SourceWatcher {
    private let root: String
    private let settle: Double
    private let changed: (Set<DevChange>) -> Void
    private let queue = DispatchQueue(label: "MetalRenderer.watch", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pending = Set<DevChange>()
    private var flush: DispatchWorkItem?

    package init(root: URL, settle: Double = 0.3, changed: @escaping (Set<DevChange>) -> Void) {
        self.root = root.standardizedFileURL.path
        self.settle = settle
        self.changed = changed
    }

    deinit { stop() }

    /// Starts watching; false if FSEvents wouldn't.
    @discardableResult
    package func start() -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.saw(list.prefix(count))
        }
        let folders = ["Sources", "Assets"].map { root + "/" + $0 } as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let made = FSEventStreamCreate(nil, callback, &context, folders, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        else { return false }
        stream = made
        FSEventStreamSetDispatchQueue(made, queue)
        return FSEventStreamStart(made)
    }

    package func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Paths FSEvents reported (its queue): what they change waits for the saves to settle.
    package func saw<S: Sequence>(_ paths: S) where S.Element == String {
        let changes = paths.compactMap { DevChange.of($0, root: root) }
        guard !changes.isEmpty else { return }
        pending.formUnion(changes)
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            let batch = self.pending
            self.pending = []
            self.changed(batch)
        }
        flush = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// For the tests: `saw` from any thread, as FSEvents would.
    package func report(_ paths: [String]) { queue.async { self.saw(paths) } }
}
