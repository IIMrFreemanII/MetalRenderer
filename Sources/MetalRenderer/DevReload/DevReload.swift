import Buildings
import Darwin
import EngineCore
import Foundation
import Plants
import QuartzCore

/// The dev build's hot reload (`Tools/build.sh`): a save in `Sources` or `Assets` shows in the running app.
/// * A shader (`Sources/MetalRenderer/**.metal`): compiled again, as R does.
/// * The game's code (`Sources/Game`): built again alone and loaded into the app (`Tools/hotreload.sh`, GameReload),
///   then the scene is made again with it, the camera where it was. Its behaviour (the gameplay) starts over.
/// * The scene's file (`Assets/Scenes/<kind>.scene`), the plants' and the buildings' (`Assets/Plants`,
///   `Assets/Buildings`): read again, and the scene made again. The app's own saves don't count (FileStamps, the
///   catalogs' fingerprints).
/// * Any other module's code: a relaunch, which it says.
/// Release builds, benchmarks and tests never start it (`Renderer.startDevReload`).
package final class DevReload {
    /// Posted on the main thread once the game's new code is in: the settings panel takes its rows again.
    package static let gameReloaded = Notification.Name("MetalRendererGameReloaded")
    /// Posted on the main thread when the saved plants' files changed: the plant editor reads them (PlantCatalog.launch).
    package static let plantsReloaded = Notification.Name("MetalRendererPlantsReloaded")

    private weak var renderer: Renderer?
    private var watcher: SourceWatcher?
    private let game: GameReload

    init(renderer: Renderer) {
        self.renderer = renderer
        game = GameReload(renderer: renderer)
        let watcher = SourceWatcher(root: SourceTree.packageRoot) { [weak self] in self?.apply($0) }
        self.watcher = watcher
        if watcher.start() {
            print("Hot reload: on (shaders, Sources/Game, the scene's file, Assets/Plants, Assets/Buildings and Assets/Procedural reload when saved; METALRENDERER_HOTRELOAD=0 turns it off)")
        } else {
            print("Hot reload: FSEvents wouldn't watch \(SourceTree.packageRoot.path)")
        }
    }

    /// What a batch of saves changed (the watcher's queue).
    private func apply(_ changes: Set<DevChange>) {
        guard let renderer else { return }
        var modules: [String] = []
        for change in changes {
            switch change {
            case .shaders:
                print("Hot reload: the shaders")
                renderer.perform { $0.reloadShaders() }
            case .game:
                game.request()
            case .code(let module):
                modules.append(module)
            case .sceneFile(let path):
                let url = URL(fileURLWithPath: path)
                guard FileStamps.changed(url) else { continue }   // the app's own save
                renderer.perform { r in
                    guard SceneFile.url(for: r.scene.settings.kind).standardizedFileURL.path == url.standardizedFileURL.path else { return }
                    r.remakeScene(because: "its file changed")
                }
            case .plants:
                let saved = PlantStore.load()
                guard saved != PlantCatalog.launch else { continue }
                let regrows = saved.fingerprint != PlantCatalog.launch.fingerprint
                PlantCatalog.setLaunch(saved)
                DispatchQueue.main.async { NotificationCenter.default.post(name: DevReload.plantsReloaded, object: nil) }
                guard regrows else { continue }     // the editor's save, or only a file's comments and places
                renderer.perform { r in
                    if r.scene.settings.kind.hasPlants && r.scene.settings.plantCatalog.isEmpty { r.remakeScene(because: "the saved plants changed") }
                }
            case .buildings:
                let saved = BuildingStore.load()
                guard saved.fingerprint != BuildingCatalog.launch.fingerprint else { continue }
                BuildingCatalog.setLaunch(saved)
                renderer.perform { r in
                    if r.scene.settings.buildingCatalog.isEmpty { r.remakeScene(because: "the saved buildings changed") }
                }
            case .procedural:
                // A scene that places procedural assets is made again (each cooks again only if it changed).
                renderer.perform { r in
                    if r.scene.placed?.file.objects.contains(where: { $0.asset.hasPrefix("proc:") }) == true {
                        r.remakeScene(because: "a procedural asset changed")
                    }
                }
            }
        }
        if !modules.isEmpty {
            print("Hot reload: \(modules.sorted().joined(separator: ", ")) changed; only Sources/Game and the shaders reload: "
                  + "rebuild (Tools/build.sh) and relaunch for that")
        }
    }
}

/// The game's code built again (`Tools/hotreload.sh`: the Game module alone, linked into a bundle against this
/// binary) and loaded: its entry (`metalrenderer_game_reload`, GameScenes) registers the new scenes, rows and modes over
/// the old ones, and the scene is made again. One build at a time; saves during one make one more after it. The old
/// copies stay loaded (closures and objects made by them may still be around; Swift images don't unload).
final class GameReload {
    private weak var renderer: Renderer?
    private let queue = DispatchQueue(label: "MetalRenderer.gamereload", qos: .userInitiated)
    private let lock = NSLock()
    private var queued = false
    private var count = 0
    private let binary: String
    private let launched: String

    init(renderer: Renderer) {
        self.renderer = renderer
        binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let stamp = (try? FileManager.default.attributesOfItem(atPath: binary)[.modificationDate] as? Date) ?? nil
        launched = stamp.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
    }

    /// Builds and loads the game's code (any thread).
    func request() {
        lock.lock()
        defer { lock.unlock() }
        if queued { return }   // a build is waiting already: it takes this save too
        queued = true
        queue.async { [self] in
            lock.lock()
            queued = false
            lock.unlock()
            build()
        }
    }

    private func build() {
        guard let renderer else { return }
        count += 1
        let job = renderer.benchmark != nil ? nil : renderer.loadActivity.begin("the game's code", verbs: ("Building", "Built"))
        let start = CACurrentMediaTime()
        let process = Process(), pipe = Pipe()
        process.executableURL = SourceTree.packageRoot.appendingPathComponent("Tools/hotreload.sh")
        process.arguments = [String(count), binary, launched]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            print("Hot reload: Tools/hotreload.sh didn't start: \(error)")
            job?.fail()
            return
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let lines = output.split(separator: "\n").map(String.init)
        let built = (CACurrentMediaTime() - start) * 1000
        switch process.terminationStatus {
        case 0:
            guard let path = lines.last, path.hasSuffix(".bundle") else {
                print("Hot reload: no bundle from Tools/hotreload.sh:\n\(output)")
                job?.fail()
                return
            }
            renderer.perform { $0.loadGame(path, builtMs: built, job: job) }
        case 2:
            print("Hot reload: the game's code not loaded: \(lines.last ?? "")")
            job?.fail()
        default:
            // The compiler's errors (and the lines under them), not the build's progress.
            let errors = lines.filter { $0.contains("error:") }
            print("Hot reload: the game's code didn't build (the app keeps the code it has):\n"
                  + (errors.isEmpty ? output : errors.prefix(20).joined(separator: "\n")))
            job?.fail()
        }
    }
}

extension Renderer {
    /// The dev build's hot reload (DevReload), unless `METALRENDERER_HOTRELOAD=0`; a benchmark's only with `=1` (the
    /// `reload` mode's checks). Main thread, before the frames start. Release builds don't have it.
    package func startDevReload() {
        #if DEBUG
        let asked = ProcessInfo.processInfo.environment["METALRENDERER_HOTRELOAD"]
        guard asked != "0", benchmark == nil || asked == "1", devReload == nil else { return }
        devReload = DevReload(renderer: self)
        #endif
    }

    /// Loads the game's code built again (GameReload), then makes the scene again with it (render thread).
    fileprivate func loadGame(_ path: String, builtMs: Double, job: LoadJob?) {
        // Not while a scene loads: its builder reads the registry the new code writes.
        if loading != nil {
            perform { $0.loadGame(path, builtMs: builtMs, job: job) }
            return
        }
        guard let image = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            print("Hot reload: the game's code didn't load: \(dlerror().map { String(cString: $0) } ?? "")")
            job?.fail()
            return
        }
        guard let entry = dlsym(image, "metalrenderer_game_reload") else {
            print("Hot reload: \(path) has no metalrenderer_game_reload")
            job?.fail()
            return
        }
        unsafeBitCast(entry, to: (@convention(c) () -> Void).self)()
        job?.finish()
        print(String(format: "Hot reload: the game's code built and loaded in %.1f s", builtMs / 1000))
        remakeScene(because: "the game's code changed")
        DispatchQueue.main.async { NotificationCenter.default.post(name: DevReload.gameReloaded, object: nil) }
    }
}
