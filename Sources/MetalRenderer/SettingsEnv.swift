import Foundation

/// The settings as `METALRENDERER_*` environment variables, both ways, driven by `SettingsTable`: `export` writes the
/// variables that reproduce the settings ("Copy as Env" in the settings panel), `apply` reads them back.
///
/// Three things are not rows of the table and are handled here: the scene's kind, check scene and added models in
/// `METALRENDERER_SCENE`, and `METALRENDERER_SKY`, which is the sky mode's name or an image's path.
enum SettingsEnv {
    // MARK: - Export

    /// The variables that reproduce `s` in a fresh launch (or in every setting of a benchmark run), listing only what
    /// differs from the defaults. Fog and sky are compared with the scene's presets. Not covered: the camera pose,
    /// Freeze LOD, and where added models were placed (`model=` puts them in front of the default camera).
    static func export(_ s: RenderSettings, defaults: RenderSettings) -> String {
        // What a fresh launch would have: the code's defaults (not this process's env-derived ones) and the scene's presets.
        var d = defaults
        d.directLight = .auto
        d.rayTracer = .custom
        d.api = .metal3
        d.specular = true
        d.textureBudgetMB = 1024
        d.virtualGeometry.enabled = true
        d.virtualGeometry.pixelError = 1
        d.virtualGeometry.poolMB = 768
        d.scene = SceneSettings()
        d.scene.kind = s.scene.kind
        d.scene.showcase = s.scene.showcase   // the model's look: its fog and lens
        d.scene.emissiveLights = true
        d.applySceneDefaults(from: defaults)   // the scene's GI method, light count, fog, sky and lens

        var vars: [String] = []
        for variable in EnvVariable.allCases {
            let changed = SettingsTable.named.filter { $0.variable == variable && $0.exported && $0.differs(s, d) }
            switch variable {
            case .scene:
                let items = [s.scene.kind.envName] + changed.map { "\($0.key!)=\($0.text(s))" } + s.scene.extraModels.map { "model=\($0.path)" }
                vars.append("\(variable.rawValue)=\"\(items.joined(separator: ","))\"")
            case .sky:
                if s.sky.mode != d.sky.mode || SkySettings.override != nil {
                    vars.append("\(variable.rawValue)=\(s.sky.mode == .image ? quoted(s.sky.imagePath ?? "") : "\(s.sky.mode)")")
                }
            case .fog:   // a preset override in this process is repeated even where it changes nothing
                if !changed.isEmpty || FogSettings.override != nil { vars.append("\(variable.rawValue)=\(s.fog.enabled.envText)") }
            case _ where variable.isList:
                if !changed.isEmpty {
                    vars.append("\(variable.rawValue)=\"\(changed.map { "\($0.key!)=\($0.text(s))" }.joined(separator: ","))\"")
                }
            default:
                if let value = changed.first { vars.append("\(variable.rawValue)=\(value.text(s))") }
            }
        }
        return vars.joined(separator: " ")
    }

    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: - Reading

    /// Applies `variable`, if `env` has it, to `s`. Lists are `key=value,key=value`; a key the table doesn't know, or a
    /// value that doesn't read as the setting's type, is reported and skipped. `interactive`: outside benchmarks,
    /// which choose some settings (the view, paused) themselves.
    static func apply(_ variable: EnvVariable, to s: inout RenderSettings, interactive: Bool = false,
                      from env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let text = env[variable.rawValue] else { return }
        let specs = SettingsTable.named.filter { $0.variable == variable }
        if variable == .sky {
            if let mode = SkyMode.allCases.first(where: { $0 != .image && "\($0)" == text }) { s.sky.mode = mode }
            else { s.sky.mode = .image; s.sky.imagePath = text }
            return
        }
        guard variable.isList else {
            if let spec = specs.first, !spec.parse(&s, text) { print("\(variable.rawValue): can't read \"\(text)\"") }
            return
        }
        for item in text.split(separator: ",") {
            let kv = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, let spec = specs.first(where: { $0.key == kv[0] }) {
                if spec.interactiveOnly && !interactive { continue }
                if !spec.parse(&s, kv[1]) { print("\(variable.rawValue): can't read \(kv[0])=\(kv[1])") }
            } else if !(variable == .scene && applySceneItem(kv, to: &s.scene)) {
                print("\(variable.rawValue): unknown key \(kv.first ?? "")")
            }
        }
    }

    /// `METALRENDERER_SCENE`'s items that aren't settings of the table: the scene's kind as a bare word (cornell,
    /// stress, gallery, spots, sun, area, tubes, emissive, mixed, fog, valley, market, forest, crowd, city, citynight, world,
/// showcase),
    /// `check=<light>` for the light-check scene (Scene.buildLightCheck; "empty" = just the floor) and `model=<path>`,
    /// which adds a glTF model as File > Open does, in front of the default camera.
    private static func applySceneItem(_ kv: [String], to s: inout SceneSettings) -> Bool {
        if kv.count == 1, let kind = SceneKind(envText: kv[0]) {
            s.kind = kind
            if kind == .market && s.lights == SceneSettings().lights { s.lights = SceneSettings.marketLights }
            return true
        }
        guard kv.count == 2 else { return false }
        switch kv[0] {
        case "check": s.lightCheck = kv[1]
        case "model": s.extraModels.append(ExtraModel(path: kv[1], position: [Float(s.extraModels.count) * 1.8 - 0.9, 0, 2], yaw: 0))
        default: return false
        }
        return true
    }

    /// The app outside benchmarks: every variable, over the saved or default settings. The starting scene comes
    /// first, with the defaults that suit it (the GI method, fog and sky presets), so the other variables refine it.
    static func applyAll(to s: inout RenderSettings, defaults: RenderSettings,
                         from env: [String: String] = ProcessInfo.processInfo.environment) {
        if env[EnvVariable.scene.rawValue] != nil {
            apply(.scene, to: &s, interactive: true, from: env)
            s.applySceneDefaults(from: defaults)
        }
        for variable in EnvVariable.allCases where variable != .scene {
            apply(variable, to: &s, interactive: true, from: env)
        }
    }
}
