import Foundation

/// Keeps the app's `RenderSettings` between launches (UserDefaults, as JSON). Benchmarks never load or save them.
///
/// Loading lays the saved JSON over the current defaults, so fields added since the save keep their defaults and
/// removed ones are ignored. If the saved copy no longer decodes (a field changed type), the defaults are used.
/// `METALRENDERER_SETTINGS=default` starts from the defaults without reading the saved copy (later changes still save).
enum SettingsStore {
    private static let key = "renderSettings"
    private static var pending: DispatchWorkItem?

    static func load(over defaults: RenderSettings) -> RenderSettings? {
        guard ProcessInfo.processInfo.environment["METALRENDERER_SETTINGS"] != "default",
              let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: merge(base, saved)),
              var s = try? JSONDecoder().decode(RenderSettings.self, from: merged) else { return nil }
        // Session state rather than preferences.
        s.paused = defaults.paused
        s.viewMode = defaults.viewMode
        s.reference.mode = defaults.reference.mode
        s.scene.lightCheck = nil
        s.scene.worldTile = nil
        s.scene.worldAnchor = nil
        s.scene.extraModels = []
        s.scene.plantCatalog = ""
        s.scene.effects = ""   // the VFX editor's catalogs are this session's
        s.scene.materials = ""
        s.scene.materialAssignments = ""
        s.scene.buildingCatalog = ""
        s.scene.characterCatalog = ""
        s.scene.characterWorkshop.mutants = ""
        s.scene.characterWorkshop.compare = ""
        s.scene.interior = nil
        s.scene.buildings.mutants = ""
        s.scene.buildings.compare = ""
        s.scene.plants.mutants = ""
        s.scene.plants.compare = ""
        s.virtualGeometry.freeze = false
        if let path = s.sky.imagePath, !FileManager.default.fileExists(atPath: path) {
            s.sky.imagePath = nil
            if s.sky.mode == .image { s.sky.mode = defaults.sky.mode }
        }
        return s
    }

    /// Saves `s` half a second after the last change (sliders send many).
    static func save(_ s: RenderSettings) {
        pending?.cancel()
        let work = DispatchWorkItem { write(s) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a pending save now (at quit).
    static func flush() {
        guard let work = pending, !work.isCancelled else { return }
        work.perform()
        work.cancel()
    }

    /// `METALRENDERER_DUMP_SETTINGS=1`: prints the settings as JSON (to compare two launches, e.g. after Copy as Env).
    static func dumpIfRequested(_ s: RenderSettings) {
        guard ProcessInfo.processInfo.environment["METALRENDERER_DUMP_SETTINGS"] == "1" else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(s), let text = String(data: data, encoding: .utf8) { print(text) }
        fflush(stdout)   // the app runs until quit; a redirected stdout would hold it back
    }

    private static func write(_ s: RenderSettings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] { out[k] = merge(b, o) } else { out[k] = v }
        }
        return out
    }
}
