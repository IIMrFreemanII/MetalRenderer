import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants

/// Keeps the app's `RenderSettings` between launches (UserDefaults, as JSON). Benchmarks never load or save them.
///
/// Loading lays the saved JSON over the current defaults, so fields added since the save keep their defaults and
/// removed ones are ignored. A field that no longer decodes (an enum case since removed, a changed type) takes its
/// default, and the others are kept.
/// `METALRENDERER_SETTINGS=default` starts from the defaults without reading the saved copy (later changes still save).
package enum SettingsStore {
    private static let key = "renderSettings"
    private static var pending: DispatchWorkItem?

    package static func load(over defaults: RenderSettings) -> RenderSettings? {
        guard ProcessInfo.processInfo.environment["METALRENDERER_SETTINGS"] != "default",
              let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return decode(saved: data, over: defaults)
    }

    /// Saved settings' JSON laid over `defaults` as a launch reads them (a script given the window's saved copy, from
    /// a build with other fields, reads it the same way).
    package static func decode(saved data: Data, over defaults: RenderSettings) -> RenderSettings? {
        guard var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any] else { return nil }
        // Saved under an older default look: that look's choices go, once, and the app opens where a first launch does.
        let oldLook = (saved["lookVersion"] as? Int ?? 0) < RenderSettings.currentLook
        if oldLook { for key in ["post", "fog", "sky", "toneMap", "exposure", "lookVersion"] { saved[key] = nil } }
        guard var s = decode(merge(base, saved), defaults: base) else { return nil }
        if oldLook {
            s.scene.kind = RenderSettings.firstLaunch(defaults).scene.kind
            s.applySceneDefaults(from: defaults)
        }
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
        s.scene.paintAssignments = ""
        s.scene.terrainKey = ""
        s.scene.sceneOverrides = ""
        s.scene.buildingCatalog = ""
        s.scene.characterCatalog = ""
        s.scene.characterWorkshop.mutants = ""
        s.scene.characterWorkshop.compare = ""
        s.scene.interior = nil
        s.scene.buildings.mutants = ""
        s.scene.buildings.compare = ""
        s.scene.plants.mutants = ""
        s.scene.plants.compare = ""
        s.scene.plants.stage = -1
        s.virtualGeometry.freeze = false
        s.scene.realism = defaults.scene.realism   // (once the panel's switch: a copy saved with it off stays realistic)
        if let path = s.sky.imagePath, !FileManager.default.fileExists(atPath: path) {
            s.sky.imagePath = nil
            if s.sky.mode == .image { s.sky.mode = defaults.sky.mode }
        }
        return s
    }

    /// Saves `s` half a second after the last change (sliders send many).
    package static func save(_ s: RenderSettings) {
        pending?.cancel()
        let work = DispatchWorkItem { write(s) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a pending save now (at quit).
    package static func flush() {
        guard let work = pending, !work.isCancelled else { return }
        work.perform()
        work.cancel()
    }

    /// `METALRENDERER_DUMP_SETTINGS=1`: prints the settings as JSON (to compare two launches, e.g. after Copy as Env).
    package static func dumpIfRequested(_ s: RenderSettings) {
        guard ProcessInfo.processInfo.environment["METALRENDERER_DUMP_SETTINGS"] == "1" else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(s), let text = String(data: data, encoding: .utf8) { print(text) }
        fflush(stdout)   // the app runs until quit; a redirected stdout would hold it back
    }

    private static func write(_ s: RenderSettings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The settings in `json`, each field that doesn't decode set to its value in `defaults` (the defaults' JSON) in
    /// turn: nil only if one at an array's index, or more than a few, don't.
    package static func decode(_ json: [String: Any], defaults: [String: Any]) -> RenderSettings? {
        var json = json
        for _ in 0..<32 {
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
            let context: DecodingError.Context
            do {
                return try JSONDecoder().decode(RenderSettings.self, from: data)
            } catch DecodingError.dataCorrupted(let c), DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c) {
                context = c
            } catch {
                return nil
            }
            let path = context.codingPath
            guard !path.isEmpty, path.allSatisfy({ $0.intValue == nil }),
                  let repaired = replacing(path.map(\.stringValue), in: json, from: defaults) else { return nil }
            json = repaired
        }
        return nil
    }

    /// `json` with the value at `keys` taken from `defaults` (nil if `defaults` has none there).
    private static func replacing(_ keys: [String], in json: [String: Any], from defaults: [String: Any]) -> [String: Any]? {
        guard let key = keys.first, let value = defaults[key] else { return nil }
        var out = json
        if keys.count == 1 {
            out[key] = value
        } else {
            guard let inner = json[key] as? [String: Any], let innerDefaults = value as? [String: Any],
                  let repaired = replacing(Array(keys.dropFirst()), in: inner, from: innerDefaults) else { return nil }
            out[key] = repaired
        }
        return out
    }

    package static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] { JSONMerge.merge(base, over) }
}
