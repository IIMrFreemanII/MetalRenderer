import Buildings
import Characters
import CoreGraphics
import Effects
import EngineCore
import Foundation
import Garments
import Landscape
import Materials
import Physics
import Plants
import simd

/// A value that can be written into a `METALRENDERER_*` variable and read back from one.
package protocol EnvValue: Equatable {
    var envText: String { get }
    init?(envText: String)
}

extension Float: EnvValue {
    /// The shortest text that reads back as the same Float.
    package var envText: String {
        let text = "\(self)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    package init?(envText: String) { self.init(envText) }
}
extension CGFloat: EnvValue {
    package var envText: String { Float(self).envText }
    package init?(envText: String) {
        guard let v = Float(envText) else { return nil }
        self.init(v)
    }
}
extension Int: EnvValue {
    package var envText: String { "\(self)" }
    package init?(envText: String) {   // "2.7" reads as 2, as it always has
        guard let v = Float(envText), v.isFinite, abs(v) < 1e9 else { return nil }
        self.init(v)
    }
}
extension Bool: EnvValue {
    package var envText: String { self ? "1" : "0" }
    package init?(envText: String) {
        guard let v = Float(envText) else { return nil }
        self.init(v != 0)
    }
}
extension String: EnvValue {   // a word or a name: no commas (they part a list's items)
    package var envText: String { self }
    package init?(envText: String) { self = envText }
}
extension SIMD3: EnvValue where Scalar == Float {
    package var envText: String { "\(x.envText):\(y.envText):\(z.envText)" }
    package init?(envText: String) {
        let v = envText.split(separator: ":").compactMap { Float($0) }
        guard v.count == 3 else { return nil }
        self.init(v[0], v[1], v[2])
    }
}

/// An enum written by name: its case name unless `envName` says otherwise. Read back without regard to case.
package protocol EnvNamed: EnvValue, CaseIterable {
    var envName: String { get }
}
extension EnvNamed {
    package var envName: String { "\(self)" }
    package var envText: String { envName }
    package init?(envText: String) {
        // (Both sides in lower case: a case named in camel case, `headOn`, `santaFe`, is `headon`, `santafe`.)
        guard let match = Self.allCases.first(where: { $0.envName.lowercased() == envText.lowercased() }) else { return nil }
        self = match
    }
}
extension GIMode: EnvNamed {
    package var envName: String { ["pt", "cascades", "restir"][rawValue] }
}
extension ToneMap: EnvNamed {}
extension Realism: EnvNamed {}
extension DirectLightMode: EnvNamed {}
extension FrameInterpolation: EnvNamed {}
extension SceneKind: EnvNamed {
    /// The scenes this build has (SceneRegistry).
    package static var allCases: [SceneKind] { SceneRegistry.kinds }
    // cityNight is read back without regard to case; the character workshop is `people` (`characters=` is the crowd's count).
    package var envName: String { definition.envName }
}
extension CityStyle: EnvNamed {}
extension PhysicsSettings.Backend: EnvNamed {}
extension PhysicsSettings.Skin: EnvNamed {}
extension PhysicsSettings.Body: EnvNamed {}
extension PhysicsSettings.Liquids: EnvNamed {}
extension PhysicsSettings.Solver: EnvNamed {}
extension PhysicsSettings.Solvers: EnvNamed {}
extension CarStyle: EnvNamed {}
extension CarSettings.Demo: EnvNamed {}
extension Foliage.Age: EnvNamed {}
extension PlantSceneSettings.Layout: EnvNamed {}
extension PlantSceneSettings.View: EnvNamed {}
extension BuildingSceneSettings.Sides: EnvNamed { package var envName: String { "\(self)".lowercased() } }
extension BuildingSceneSettings.Layout: EnvNamed {}
extension BuildingSceneSettings.View: EnvNamed {}
extension CharacterSceneSettings.Layout: EnvNamed {}
extension CrowdBodies: EnvNamed {}
extension CharacterSceneSettings.Pose: EnvNamed { package var envName: String { "\(self)".lowercased() } }
extension CharacterSceneSettings.View: EnvNamed {}
extension MaterialWorkshopSettings.Layout: EnvNamed {}
extension MaterialWorkshopSettings.Backdrop: EnvNamed {}
extension PainterWorkshopSettings.Subject: EnvNamed {}
extension TerrainWorkshopSettings.Base: EnvNamed {}
extension TerrainWorkshopSettings.Size: EnvNamed { package var envName: String { "\(metres)" } }
extension FaceExpression: EnvNamed {}
extension CharacterSceneSettings.HairMode: EnvNamed {}
extension ReferenceMode: EnvNamed {
    package var envName: String { ["off", "accumulated", "pt"][rawValue] }
}

/// The `METALRENDERER_*` variables that carry settings, in the order Copy as Env writes them.
package enum EnvVariable: String, CaseIterable {
    // One value each.
    case direct = "METALRENDERER_DIRECT", specular = "METALRENDERER_SPECULAR"
    case textureBudget = "METALRENDERER_TEXTURE_BUDGET"
    case vg = "METALRENDERER_VG", vgTau = "METALRENDERER_VG_TAU", vgPool = "METALRENDERER_VG_POOL"
    case fog = "METALRENDERER_FOG", sky = "METALRENDERER_SKY"
    // Lists of key=value.
    case scene = "METALRENDERER_SCENE", gi = "METALRENDERER_GI", denoise = "METALRENDERER_DENOISE"
    case restir = "METALRENDERER_RESTIR", restirGI = "METALRENDERER_RESTIR_GI"
    case fogSet = "METALRENDERER_FOG_SET", skySet = "METALRENDERER_SKY_SET", view = "METALRENDERER_VIEW"
    case foliage = "METALRENDERER_FOLIAGE", post = "METALRENDERER_POST"

    var isList: Bool { self.index >= EnvVariable.scene.index }
    private var index: Int { EnvVariable.allCases.firstIndex(of: self)! }
}

/// One setting, described once: where it lives in `RenderSettings`, its name in the `METALRENDERER_*` variables, and
/// the panel row that edits it. Copy as Env, the env parser and the settings panel are all built from these
/// (`SettingsTable.sections`); a new setting is one line there.
package struct SettingSpec {
    /// The panel's control for it.
    package enum Control {
        case slider(Slider)
        case checkbox(get: (RenderSettings) -> Bool, set: (inout RenderSettings, Bool) -> Void)
        case popup(titles: [String], selected: (RenderSettings) -> Int, select: (inout RenderSettings, Int) -> Void)
        case custom(Custom)
    }
    package struct Slider {
        package let range: ClosedRange<Double>                      // slider positions (log2 of the value on a log slider)
        package let ticks: Int                                      // tick marks the slider snaps to; 0 = none
        package let live: Bool                                      // false: applies when the slider is released
        package let position: (RenderSettings) -> Double
        package let move: (inout RenderSettings, Double) -> Void    // a position, rounded and clamped, into the setting
        package let text: (RenderSettings) -> String                // the value shown next to the slider
    }
    /// Rows that are more than one setting behind one control; the panel builds them by hand (SettingsPanel.customRow).
    package enum Custom {
        case scene, showcaseModel, clearModels, lightRays, upscale, skyMode, skyImage, fogAlbedo, denoiserCaption, dayPresets
    }
    /// The setting as text in an environment variable.
    package struct Env {
        package var variable = EnvVariable.gi
        package var key: String?                // in a key=value list; nil: the variable's whole value
        package var interactiveOnly = false     // read only outside benchmarks, whose settings choose it themselves
        package var exported = true             // false: an alias that is only read
        package let text: (RenderSettings) -> String
        package let differs: (RenderSettings, RenderSettings) -> Bool
        package let parse: (inout RenderSettings, String) -> Bool
    }

    package var title = ""                                  // the row's label, or its checkbox's title
    package var control: Control?                           // nil: no row (a setting with only an env name)
    package var advanced = false                            // shown only with Show advanced
    package var visible: ((RenderSettings) -> Bool)?        // nil: always
    package var enabled: ((RenderSettings) -> Bool)?        // nil: always
    package var available: ((Int) -> Bool)?                 // a popup's items this GPU can run (Capabilities); nil: all
    package var env: Env?                                   // its `variable` is meaningful once `env(_:_:)` named it
    private var named = false

    /// The spec's env name, if it has one.
    package var envName: Env? { named ? env : nil }

    // MARK: Modifiers

    package func env(_ variable: EnvVariable, _ key: String? = nil, interactiveOnly: Bool = false, exported: Bool = true) -> SettingSpec {
        var s = self
        precondition(s.env != nil, "\(title): this row has no single value to name")
        precondition(variable.isList == (key != nil), "\(variable.rawValue): a list needs a key, a single value none")
        s.env?.variable = variable
        s.env?.key = key
        s.env?.interactiveOnly = interactiveOnly
        s.env?.exported = exported
        s.named = true
        return s
    }
    package func advanced(_ on: Bool = true) -> SettingSpec { var s = self; s.advanced = on; return s }
    package func when(_ condition: @escaping (RenderSettings) -> Bool) -> SettingSpec { var s = self; s.visible = condition; return s }
    package func enabled(_ condition: @escaping (RenderSettings) -> Bool) -> SettingSpec { var s = self; s.enabled = condition; return s }
    /// A slider's value shown as `text` says, from all the settings.
    package func text(_ text: @escaping (RenderSettings) -> String) -> SettingSpec {
        guard case .slider(let m)? = control else { preconditionFailure("\(title): not a slider") }
        var s = self
        s.control = .slider(Slider(range: m.range, ticks: m.ticks, live: m.live, position: m.position, move: m.move, text: text))
        return s
    }
    /// A popup's items by index: the panel greys out the ones `item` rejects.
    package func available(_ item: @escaping (Int) -> Bool) -> SettingSpec { var s = self; s.available = item; return s }

    // MARK: Constructors

    private static func codec<T: EnvValue>(_ path: WritableKeyPath<RenderSettings, T>) -> Env {
        Env(text: { $0[keyPath: path].envText },
            differs: { $0[keyPath: path] != $1[keyPath: path] },
            parse: { s, text in
                guard let v = T(envText: text) else { return false }
                s[keyPath: path] = v
                return true
            })
    }

    /// A setting without a row of its own: only its env name.
    package static func value<T: EnvValue>(_ path: WritableKeyPath<RenderSettings, T>) -> SettingSpec {
        SettingSpec(env: codec(path))
    }

    /// A slider for a Float (or CGFloat) setting, rounded to `step` (or to `digits` significant digits). `log` spaces
    /// it logarithmically; `ticks` makes it snap to the steps.
    package static func slider<F: BinaryFloatingPoint & EnvValue>(_ title: String, _ path: WritableKeyPath<RenderSettings, F>,
                                                          _ range: ClosedRange<F>, step: Double = 0, digits: Int = 0,
                                                          log: Bool = false, ticks: Bool = false, live: Bool = true,
                                                          _ format: @escaping (F) -> String) -> SettingSpec {
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        let position = { (v: Double) in log ? log2(v) : v }
        let slider = Slider(
            range: position(lo)...position(hi),
            ticks: ticks ? Int(((hi - lo) / step).rounded()) + 1 : 0,
            live: live,
            position: { position(Swift.min(Swift.max(Double($0[keyPath: path]), lo), hi)) },
            move: { s, x in
                var v = log ? pow(2, x) : x
                if digits > 0 {
                    let scale = pow(10, floor(log10(v)) - Double(digits - 1))
                    v = (v / scale).rounded() * scale
                } else {
                    v = (v / step).rounded() * step
                }
                s[keyPath: path] = F(Swift.min(Swift.max(v, lo), hi))
            },
            text: { format($0[keyPath: path]) })
        return SettingSpec(title: title, control: .slider(slider), env: codec(path))
    }

    /// A slider for an Int setting, with tick marks for short ranges. `log`: powers of two.
    package static func slider(_ title: String, _ path: WritableKeyPath<RenderSettings, Int>, _ range: ClosedRange<Int>,
                       step: Int = 1, log: Bool = false, live: Bool = true,
                       _ format: @escaping (Int) -> String = { "\($0)" }) -> SettingSpec {
        let top = log ? log2(Double(range.upperBound)) : Double(range.upperBound)
        let slider = Slider(
            range: (log ? 0 : Double(range.lowerBound))...top,
            ticks: log ? Int(top) + 1 : step == 1 && range.count <= 16 ? range.count : 0,
            live: live,
            position: { log ? log2(Double(Swift.max($0[keyPath: path], 1))) : Double($0[keyPath: path]) },
            move: { s, x in
                let v = log ? 1 << Int(x.rounded()) : Int((x / Double(step)).rounded()) * step
                s[keyPath: path] = range.clamp(v)
            },
            text: { format($0[keyPath: path]) })
        return SettingSpec(title: title, control: .slider(slider), env: codec(path))
    }

    package static func check(_ title: String, _ path: WritableKeyPath<RenderSettings, Bool>) -> SettingSpec {
        SettingSpec(title: title, control: .checkbox(get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 }),
                    env: codec(path))
    }

    /// A popup choosing among `options` (title, value). A value that is none of them selects nothing.
    package static func popup<T: EnvValue>(_ title: String, _ path: WritableKeyPath<RenderSettings, T>,
                                   _ options: [(String, T)]) -> SettingSpec {
        let control = Control.popup(titles: options.map(\.0),
                                    selected: { s in options.firstIndex { $0.1 == s[keyPath: path] } ?? -1 },
                                    select: { $0[keyPath: path] = options[$1].1 })
        return SettingSpec(title: title, control: control, env: codec(path))
    }

    /// A popup over a few counts. A count in between shows as the next one up.
    package static func popup(_ title: String, _ path: WritableKeyPath<RenderSettings, Int>, counts: [Int],
                      _ name: @escaping (Int) -> String) -> SettingSpec {
        let control = Control.popup(titles: counts.map(name),
                                    selected: { s in counts.firstIndex { $0 >= s[keyPath: path] } ?? counts.count - 1 },
                                    select: { $0[keyPath: path] = counts[$1] })
        return SettingSpec(title: title, control: control, env: codec(path))
    }

    package static func custom(_ row: Custom, _ title: String = "") -> SettingSpec {
        SettingSpec(title: title, control: .custom(row))
    }
}

extension RenderSettings {
    /// Upscaling, through MetalFX's denoising scaler: it denoises the raw light, and SVGF and the shadow denoiser are off.
    package var neuralDenoiser: Bool { upscaleFactor > 1 }

    /// The denoiser's wavelet passes for the selected GI method: the panel's one slider edits whichever count applies.
    package var filterPasses: Int {
        get { denoiser.passes(for: giMode) }
        set { if giMode == .pathTraced { denoiser.atrousPasses = newValue } else { denoiser.techniquePasses = newValue } }
    }
}

extension SkySettings {
    /// Whether clouds are drawn: over an image they have their own switch (in front of the image).
    package var cloudsShown: Bool {
        get { mode == .image ? cloudsOverImage : clouds }
        set { if mode == .image { cloudsOverImage = newValue } else { clouds = newValue } }
    }
}

/// Every setting, in the panel's order. See `SettingSpec`.
package enum SettingsTable {
    package struct Section {
        package let title: String
        package var advanced = false
        package let rows: [SettingSpec]
    }

    /// Every spec that has an env name, in table order.
    package static let named: [SettingSpec.Env] = sections.flatMap(\.rows).compactMap(\.envName)

    private typealias S = SettingSpec
    private typealias When = (RenderSettings) -> Bool

    private static func fmt<T: CVarArg>(_ format: String) -> (T) -> String { { String(format: format, $0) } }
    package static func titled<T: CaseIterable>(_ title: (T) -> String) -> [(String, T)] { T.allCases.map { (title($0), $0) } }

    /// Made again when the game's rows change (`sceneRows`: a hot reload of the game's code registers them again).
    package static var sections: [Section] {
        _ = SceneRegistry.kinds   // (the game's rows are registered with its scenes)
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        if let made = madeSections, made.rows == sceneRowsVersion { return made.sections }
        let made = [sceneSection(), camera, post, directLight, rendering, globalIllumination, fog, sky, foliage, denoiser, memory]
        madeSections = (sceneRowsVersion, made)
        return made
    }
    private static let sectionsLock = NSLock()
    private static var madeSections: (rows: Int, sections: [Section])?

    private static let foliage: Section = {
        let plants: When = { $0.scene.kind.hasPlants }
        // Baked plants stand still, and so do the open world's.
        let assemblies: When = { !$0.scene.bakedPlants && !$0.scene.kind.isWorld }
        return Section(title: "Foliage", rows: [
            S.slider("Wind", \.foliage.wind, FoliageSettings.windRange, step: 0.05, fmt("%.2f")).env(.foliage, "wind").when(plants).enabled(assemblies),
            S.slider("Wind direction", \.foliage.windDirection, FoliageSettings.directionRange, step: 5, fmt("%.0f°"))
                .env(.foliage, "dir").when(plants).enabled(assemblies),
            S.slider("Gusts", \.foliage.gusts, FoliageSettings.gustRange, step: 0.05, fmt("%.2f")).env(.foliage, "gusts").when(plants).enabled(assemblies),
            S.slider("Sway reach", \.foliage.swayReach, FoliageSettings.swayRange, step: 5, fmt("%.0f m"))
                .env(.foliage, "sway").when(plants).enabled(assemblies),
            S.slider("Season", \.foliage.season, FoliageSettings.seasonRange, step: 0.02, fmt("%.2f")).env(.foliage, "season").when(plants),
            S.slider("Leaf translucency", \.foliage.translucency, FoliageSettings.translucencyRange, step: 0.05, fmt("%.2f"))
                .env(.foliage, "translucency").when(plants),
            S.slider("Distance LOD (voxels)", \.foliage.lod, FoliageSettings.lodRange, step: 0.25, fmt("%.2g px"))
                .env(.foliage, "lod").when(plants),
        ])
    }()

    /// The game's scenes' own rows (their counts, their physics, the destruction's and the demolition's), in the panel
    /// after the workshops' (SceneProvider registers them).
    package static var sceneRows: [SettingSpec] = [] {
        didSet {
            sectionsLock.lock()
            sceneRowsVersion += 1
            sectionsLock.unlock()
        }
    }
    private static var sceneRowsVersion = 0

    private static func sceneSection() -> Section {
        let assemblies: When = { !$0.scene.bakedPlants }
        let virtual: When = { $0.virtualGeometry.enabled }
        let city: When = { $0.scene.kind.isCity }
        let workshop: When = { $0.scene.kind == .plants }
        let buildings: When = { $0.scene.kind == .buildings }
        let characters: When = { $0.scene.kind == .characters }
        let percent: (Float) -> String = { String(format: "%.0f%%", $0 * 100) }
        return Section(title: "Scene", rows: [
            S.custom(.scene, "Scene"),
            S.value(\.scene.showcase).env(.scene, "showcase"),
            // Scene sizes rebuild the scene, so they apply when the slider is released.
            S.slider("Lights", \.scene.lights, SceneSettings.lightRange, log: true, live: false)
                .env(.scene, "lights").when { $0.scene.kind.hasLightCount },
            S.slider("City seed", \.scene.seed, SceneSettings.seedRange, live: false).when(city),   // `seed`, as the plants'
            S.slider("City blocks", \.scene.city.blocks, CitySettings.blockRange, live: false) { "\($0) x \($0)" }
                .env(.scene, "blocks").when(city),
            S.popup("Building style", \.scene.city.style, titled(\.title)).env(.scene, "style").when(city),
            S.slider("Lit windows", \.scene.city.lit, CitySettings.litRange, step: 0.05, live: false, percent)
                .env(.scene, "lit").when { $0.scene.kind.hasLitWindows },
            S.slider("Rooms behind windows", \.scene.city.rooms, CitySettings.roomRange, step: 0.05, live: false, percent)
                .env(.scene, "rooms").when(city),
            S.check("Generated textures", \.scene.city.textures).env(.scene, "textures").when(city),
            S.check("Windows as modules", \.scene.city.modules).env(.scene, "modules").when(city),
            S.check("Interiors near the camera", \.scene.city.interiors).env(.scene, "interiors").when(city),
            S.check("Canal", \.scene.city.canal).env(.scene, "canal").when(city),
            S.slider("Interior reach", \.scene.city.interiorReach, 10...80, step: 5, live: false) { String(format: "%.0f m", $0) }
                .env(.scene, "reach").when(city),
            S.value(\.scene.buildings.style).env(.scene, "bstyle"),
            S.slider("Lot width", \.scene.buildings.lot.x, BuildingSceneSettings.widthRange, step: 0.5, live: false) { String(format: "%.1f m", $0) }
                .env(.scene, "width").when(buildings),
            S.slider("Lot depth", \.scene.buildings.lot.y, BuildingSceneSettings.depthRange, step: 0.5, live: false) { String(format: "%.1f m", $0) }
                .env(.scene, "depth").when(buildings),
            S.popup("Its sides", \.scene.buildings.sides, titled(\.title)).env(.scene, "sides").when(buildings),
            S.slider("Floors", \.scene.buildings.floors, BuildingSceneSettings.floorRange, live: false).env(.scene, "floors").when(buildings),
            S.slider("Building seed", \.scene.buildings.seed, SceneSettings.seedRange, live: false).env(.scene, "bseed").when(buildings),
            S.popup("Layout", \.scene.buildings.layout, titled(\.title)).env(.scene, "blayout").when(buildings),
            S.popup("View", \.scene.buildings.view, titled(\.title)).env(.scene, "bview").when(buildings),
            S.slider("Cut above floor", \.scene.buildings.cut, 0...40, live: false).env(.scene, "cut").when(buildings),
            S.check("Night", \.scene.buildings.night).env(.scene, "night").when(buildings),
            S.value(\.scene.materialWorkshop.graph).env(.scene, "mgraph"),
            S.popup("Shapes", \.scene.materialWorkshop.layout, titled(\.title)).env(.scene, "mlayout").when { $0.scene.kind == .materials },
            S.popup("Backdrop", \.scene.materialWorkshop.backdrop, titled(\.title)).env(.scene, "mbackdrop").when { $0.scene.kind == .materials },
            S.popup("Object", \.scene.painterWorkshop.subject, titled(\.title)).env(.scene, "psubject").when { $0.scene.kind == .painter },
            S.value(\.scene.painterWorkshop.model).env(.scene, "pmodel"),
            S.value(\.scene.painterWorkshop.document).env(.scene, "pdocument"),
            S.popup("Backdrop", \.scene.painterWorkshop.backdrop, titled(\.title)).env(.scene, "pbackdrop").when { $0.scene.kind == .painter },
            S.popup("Terrain size", \.scene.terrainWorkshop.size, titled(\.title)).env(.scene, "tsize").when { $0.scene.kind == .terrain },
            S.popup("Starts from", \.scene.terrainWorkshop.base, titled(\.title)).env(.scene, "tbase").when { $0.scene.kind == .terrain },
            S.slider("Terrain seed", \.scene.terrainWorkshop.seed, SceneSettings.seedRange, live: false).env(.scene, "tseed")
                .when { $0.scene.kind == .terrain && $0.scene.terrainWorkshop.base == .hills },
            S.slider("Bodies dropped", \.scene.terrainWorkshop.bodies, 0...400, live: false).env(.scene, "tbodies")
                .when { $0.scene.kind == .terrain },
            S.check("Sea", \.scene.terrainWorkshop.sea).env(.scene, "tsea")
                .when { $0.scene.kind == .terrain && $0.scene.terrainWorkshop.base == .hills },
            S.value(\.scene.terrainWorkshop.document).env(.scene, "tdocument"),
            S.value(\.scene.garmentWorkshop.garment).env(.scene, "garment"),
            S.value(\.scene.garmentWorkshop.avatar).env(.scene, "avatar"),
            S.check("Simulate", \.scene.garmentWorkshop.simulate).env(.scene, "drape").when { $0.scene.kind == .garmentStage },
            S.slider("Cloth substeps", \.scene.garmentWorkshop.substeps, 4...60, live: false).env(.scene, "gsub")
                .when { $0.scene.kind == .garmentStage },
            S.value(\.scene.garmentWorkshop.clip).env(.scene, "gclip"),
            S.value(\.scene.garmentWorkshop.stopAt).env(.scene, "gstop"),
            S.value(\.scene.characterWorkshop.character).env(.scene, "person"),
            S.popup("Layout", \.scene.characterWorkshop.layout, titled(\.title)).env(.scene, "clayout").when(characters),
            S.popup("Pose", \.scene.characterWorkshop.pose, titled(\.title)).env(.scene, "pose").when(characters),
            S.value(\.scene.characterWorkshop.clip).env(.scene, "clip"),
            S.popup("View", \.scene.characterWorkshop.view, titled(\.title)).env(.scene, "cview").when(characters),
            S.popup("Face", \.scene.characterWorkshop.expression, titled(\.title)).env(.scene, "expr").when(characters),
            S.check("Eyes on the camera", \.scene.characterWorkshop.lookAt).env(.scene, "gaze").when(characters),
            S.popup("Hair", \.scene.characterWorkshop.hair, titled(\.title)).env(.scene, "hairs").when(characters),
        ] + sceneRows + [
            S.slider("Substeps", \.scene.physics.substeps, PhysicsSettings.substepRange, live: false)
                .env(.scene, "substeps").when { $0.scene.kind.simulates },
            S.popup("Physics on", \.scene.physics.backend, titled(\.title)).env(.scene, "physics")
                .when { $0.scene.kind.simulates && !$0.scene.kind.definition.cpuPhysics },
            S.check("CPU physics behind the frame", \.scene.physics.asynchronous).env(.scene, "physicsasync")
                .when { $0.scene.kind.simulates && $0.scene.physics.backend != .gpu },
            S.check("CPU physics on every core", \.scene.physics.everyCore).env(.scene, "physicscores")
                .when { $0.scene.kind.simulates && $0.scene.physics.backend != .gpu },
            S.slider("Particle budget", \.scene.particles.budget, ParticleSettings.budgetRange, step: 0.25, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "budget").when { $0.scene.kind.definition.hasParticles },
            S.check("Particle shadows", \.scene.particles.shadows).env(.scene, "particleshadows")
                .when { $0.scene.kind.definition.particleShadows },
            S.check("Particles in reflections", \.scene.particles.reflections).env(.scene, "particlereflections")
                .when { $0.scene.kind.definition.particleShadows },
            S.popup("Particle layer", \.particleScale, [("Full size", Float(1)), ("Half size", Float(0.5))]).env(.view, "particlescale")
                .when { $0.scene.kind.definition.hasParticles },
            S.slider("Trees", \.scene.trees, SceneSettings.treeRange, step: 250, live: false)
                .env(.scene, "trees").when { $0.scene.kind.hasForest },
            S.slider("Undergrowth", \.scene.undergrowth, SceneSettings.undergrowthRange, step: 25, live: false) { "\($0)%" }
                .env(.scene, "undergrowth").when { $0.scene.kind.hasForest },
            S.slider("Plant seed", \.scene.seed, SceneSettings.seedRange, live: false)
                .env(.scene, "seed").when { $0.scene.kind.hasPlants || $0.scene.kind.definition.seeded },
            S.value(\.scene.plants.species).env(.scene, "species"),
            S.popup("Age", \.scene.plants.age, titled { "\($0)".capitalized }).env(.scene, "age").when(workshop),
            S.slider("Variant", \.scene.plants.variant, PlantSceneSettings.variantRange, live: false).env(.scene, "variant").when(workshop),
            S.slider("Workshop seed", \.scene.plants.seed, SceneSettings.seedRange, live: false).env(.scene, "plantseed").when(workshop),
            S.popup("Layout", \.scene.plants.layout, titled(\.title)).env(.scene, "layout").when(workshop),
            S.popup("View", \.scene.plants.view, titled(\.title)).env(.scene, "view").when(workshop),
            S.popup("Realistic look", \.scene.realism, titled(\.title)).env(.scene, "realism"),
            S.check("Leaves as cards", \.scene.leafCards).env(.scene, "cards").when { $0.scene.kind.hasPlants }.enabled(assemblies),
            S.check("Plants as plain meshes", \.scene.bakedPlants).env(.scene, "baked").when { $0.scene.kind.hasPlants }.advanced(),
            S.check("Far plants as voxels", \.scene.voxelBoxes).env(.scene, "voxels").when { $0.scene.kind.hasPlants }.advanced(),
            S.check("Virtual geometry (LOD)", \.virtualGeometry.enabled).env(.vg),
            S.slider("Geometry error", \.virtualGeometry.pixelError, VirtualGeometrySettings.pixelErrorRange, step: 0.25, log: true,
                     fmt("%.2g px")).env(.vgTau).enabled(virtual),
            // It also holds the plants' voxel levels.
            S.check("Freeze LOD (L)", \.virtualGeometry.freeze).enabled { virtual($0) || $0.scene.kind.hasPlants },
            S.check("Specular (glTF PBR)", \.specular).env(.specular),
            S.check("Emissive surfaces are lights", \.scene.emissiveLights).env(.scene, "emissivelights"),
            S.custom(.clearModels).when { !$0.scene.extraModels.isEmpty },
        ])
    }

    private static let post: Section = {
        let bloom: When = { $0.post.bloom > 0 }, focus: When = { $0.post.aperture > 0 }
        return Section(title: "Lens and finish", rows: [
            S.slider("Bloom", \.post.bloom, PostSettings.bloomRange, step: 0.01, fmt("%.2f")).env(.post, "bloom"),
            S.slider("Bloom threshold", \.post.bloomThreshold, PostSettings.thresholdRange, step: 0.1, fmt("%.1f"))
                .env(.post, "threshold").enabled(bloom).advanced(),
            S.slider("Depth of field", \.post.aperture, PostSettings.apertureRange, step: 0.5, fmt("%.1f px")).env(.post, "aperture"),
            S.slider("Focus distance", \.post.focus, PostSettings.focusRange, step: 0.1) { $0 == 0 ? "Auto" : String(format: "%.1f m", $0) }
                .env(.post, "focus").enabled(focus),
            S.check("Auto exposure", \.post.autoExposure).env(.post, "autoexposure"),
            S.slider("Warmth", \.post.warmth, PostSettings.warmthRange, step: 0.02, fmt("%.2f")).env(.post, "warmth"),
            S.slider("Saturation", \.post.saturation, PostSettings.saturationRange, step: 0.02, fmt("%.2f")).env(.post, "saturation"),
            S.slider("Contrast", \.post.contrast, PostSettings.contrastRange, step: 0.02, fmt("%.2f")).env(.post, "contrast"),
            S.slider("Vignette", \.post.vignette, PostSettings.vignetteRange, step: 0.05, fmt("%.2f")).env(.post, "vignette"),
            S.slider("Film grain", \.post.grain, PostSettings.grainRange, step: 0.005, fmt("%.3f")).env(.post, "grain"),
            S.slider("Chromatic aberration", \.post.aberration, PostSettings.aberrationRange, step: 0.0005) { String(format: "%.2f%%", $0 * 100) }
                .env(.post, "ca"),
        ])
    }()

    private static let camera = Section(title: "Camera and time", rows: [
        S.slider("Exposure", \.exposure, RenderSettings.exposureRange, step: 0.1, fmt("%+.1f EV")).env(.view, "exposure"),
        S.popup("Tone map", \.toneMap, titled(\.title)).env(.view, "tonemap"),
        S.slider("Field of view", \.fovDegrees, RenderSettings.fovRange, step: 1, fmt("%.0f°")).env(.view, "fov"),
        S.slider("Move speed", \.moveSpeed, RenderSettings.moveSpeedRange, step: 0.5, log: true, fmt("%g m/s")).env(.view, "speed"),
        S.check("Pause animation", \.paused).env(.view, "paused", interactiveOnly: true),
        S.slider("Time scale", \.timeScale, RenderSettings.timeScaleRange, step: 0.05, fmt("%.2f×")).env(.view, "timescale"),
        // The day: its times (DayClock), held there; or an offset into the running day.
        S.custom(.dayPresets, "Time").when { DayClock.of($0.scene.kind) != nil },
        S.slider("Time of day", \.timeOfDay, 0...1, step: 0.01) { String(format: "%.0f%%", $0 * 100) }
            .text { s in s.heldHour.map(DayClock.label) ?? String(format: "+%.0f%%", s.timeOfDay * 100) }
            .env(.view, "tod").when { $0.scene.kind.dayCycle != nil },
        S.check("Hold time of day", \.dayHeld).env(.view, "dayhold").when { $0.scene.kind.dayCycle != nil },
    ])

    private static let directLight: Section = {
        let restir: When = { $0.directLight == .restir || $0.directLight == .auto }
        let spatial: When = { restir($0) && $0.restir.spatialPasses > 0 }
        let grid: When = { restir($0) && $0.restir.grid.enabled }
        let passes = [("Off", 0), ("1 pass", 1), ("2 passes", 2)]
        return Section(title: "Direct light", rows: [
            S.popup("Method", \.directLight, titled { $0 == .auto ? "Auto (ReSTIR above 256 lights)" : $0.title }).env(.direct),
            S.custom(.lightRays, "Shadow rays").when { $0.directLight == .grouped },
            S.value(\.manyLightRays).env(.gi, "lightrays"),
            S.slider("Pick reuse", \.manyLightReuse, RenderSettings.manyLightReuseRange) { $0 == 0 ? "off" : "\($0) fr" }
                .env(.gi, "lightreuse").advanced().when { $0.directLight == .grouped && $0.manyLightRays < 2 },
            S.popup("Candidates", \.restir.candidates, counts: [4, 8, 16, 32]) { "\($0) per pixel" }.env(.restir, "candidates").when(restir),
            S.popup("Spatial reuse", \.restir.spatialPasses, counts: passes.map(\.1)) { passes[$0].0 }.env(.restir, "spatial").when(restir),
            S.check("Temporal reuse", \.restir.temporal).env(.restir, "temporal").when(restir),
            S.check("Visibility reuse", \.restir.visibilityReuse).env(.restir, "vis").when(restir),
            S.slider("Chains", \.restir.chains, RestirSettings.chainRange).env(.restir, "chains").advanced().when(restir),
            S.slider("Max M", \.restir.maxM, RestirSettings.maxMRange, step: 1, log: true, fmt("%.0f")).env(.restir, "maxm").advanced().when(restir),
            S.slider("Neighbours", \.restir.spatialSamples, RestirSettings.spatialSampleRange).env(.restir, "k").advanced().when(spatial),
            S.slider("Radius", \.restir.radius, RestirSettings.radiusRange, step: 1, fmt("%.0f px")).env(.restir, "radius").advanced().when(spatial),
            S.check("Light grid (ReGIR candidates)", \.restir.grid.enabled).env(.restir, "grid").when(restir),
            S.slider("Grid share", \.restir.grid.share, RegirSettings.shareRange) { "\($0) cand." }.env(.restir, "gshare").advanced().when(grid),
            S.slider("Grid cells", \.restir.grid.cells, RegirSettings.cellRange) { "\($0)³" }.env(.restir, "gcells").advanced().when(grid),
            S.slider("Grid levels", \.restir.grid.levels, RegirSettings.levelRange).env(.restir, "glevels").advanced().when(grid),
            S.slider("Cell size", \.restir.grid.cellSize, RegirSettings.cellSizeRange, step: 0.25, log: true, fmt("%.2f m"))
                .env(.restir, "gsize").advanced().when(grid),
            S.slider("Level scale", \.restir.grid.levelScale, RegirSettings.scaleRange, step: 0.5, fmt("%.1f×")).env(.restir, "gscale").advanced().when(grid),
            S.slider("Grid slots", \.restir.grid.slots, RegirSettings.slotRange).env(.restir, "gslots").advanced().when(grid),
            S.slider("Grid candidates", \.restir.grid.candidates, RegirSettings.candidateRange).env(.restir, "gk").advanced().when(grid),
            S.check("Split visibility (shadow denoiser)", \.restir.splitVisibility).env(.restir, "split").advanced().when(restir),
            S.slider("Filter passes", \.restir.denoisePasses, DenoiserSettings.passRange).env(.restir, "passes").advanced().when(restir),
            S.slider("Edge tolerance (σ)", \.restir.denoiseSigma, DenoiserSettings.luminanceSigmaRange, step: 0.05, fmt("%.2f"))
                .env(.restir, "sigma").advanced().when(restir),
            S.slider("History length", \.restir.denoiseHistory, DenoiserSettings.maxHistoryRange, step: 1, fmt("%.0f fr"))
                .env(.restir, "history").advanced().when(restir),
            S.slider("Variance boost", \.restir.varianceBoost, DenoiserSettings.varianceBoostRange, step: 0.25, fmt("%.2f×"))
                .env(.restir, "boost").advanced().when(restir),
        ])
    }()

    private static let rendering: Section = {
        let reference: When = { $0.reference.mode != .off }, pathTraced: When = { $0.reference.mode == .pathTraced }
        return Section(title: "Rendering", rows: [
            S.slider("Render scale", \.renderScale, RenderSettings.renderScaleRange, step: Double(RenderSettings.renderScaleStep),
                     ticks: true, fmt("%.3g×")).env(.gi, "scale"),
            S.custom(.upscale, "Upscale (MetalFX denoiser)"),
            S.value(\.upscaleFactor).env(.gi, "factor"),
            S.popup("Frame interpolation", \.frameInterpolation, titled(\.title)).env(.gi, "interp")
                .when { $0.upscaleFactor > 1 }
                .available { FrameInterpolation.allCases[$0] == .off || Capabilities.current.frameInterpolator },
            S.check("Temporal AA", \.taa).env(.gi, "taa").when { $0.upscaleFactor <= 1 },
            S.check("Blue-noise sampling", \.blueNoise).env(.gi, "blue"),
            S.check("Solid shading (`)", \.solid).env(.view, "solid"),
            S.check("Classic grey", \.solidLook.classic).env(.view, "solidclassic").when { $0.solid },
            S.check("Material colours", \.solidLook.materials).env(.view, "solidmaterials").when { $0.solid && !$0.solidLook.classic },
            S.slider("Object tint", \.solidLook.tint, SolidLook.tintRange, step: 0.01, fmt("%.2f")).env(.view, "solidtint")
                .when { $0.solid && !$0.solidLook.classic },
            S.check("Broken faces", \.solidLook.cutFaces).env(.view, "solidcut").when { $0.solid && !$0.solidLook.classic },
            S.check("Outlines", \.solidLook.edges).env(.view, "solidedges").when { $0.solid && !$0.solidLook.classic },
            S.slider("Outline width", \.solidLook.edgeWidth, SolidLook.edgeRange).env(.view, "solidedgewidth")
                .when { $0.solid && !$0.solidLook.classic && $0.solidLook.edges },
            S.check("Sun shadows", \.solidLook.shadows).env(.view, "solidshadows").when { $0.solid && !$0.solidLook.classic },
            S.check("Ambient occlusion", \.solidLook.ao).env(.view, "solidao").when { $0.solid && !$0.solidLook.classic },
            S.slider("AO rays", \.solidLook.aoRays, SolidLook.aoRayRange).env(.view, "solidaorays").when { $0.solid && !$0.solidLook.classic && $0.solidLook.ao },
            S.slider("AO reach", \.solidLook.aoRadius, SolidLook.aoRadiusRange, step: 0.1, fmt("%.1f m")).env(.view, "solidaoradius")
                .when { $0.solid && !$0.solidLook.classic && $0.solidLook.ao },
            S.popup("View", \.viewMode, RenderSettings.viewModes.enumerated().map { ($1, $0) }).env(.view, "view", interactiveOnly: true),
            S.popup("Reference", \.reference.mode, titled(\.title)).env(.view, "reference"),
            S.slider("Ref. bounces", \.reference.bounces, ReferenceSettings.bounceRange).env(.view, "refbounces").when(reference),
            S.slider("Ref. samples/frame", \.reference.samplesPerFrame, ReferenceSettings.samplesPerFrameRange)
                .env(.view, "refspp").when(pathTraced),
            S.popup("Ref. max samples", \.reference.maxSamples, ReferenceSettings.maxSampleOptions.map { ($0 == 0 ? "No limit" : "\($0)", $0) })
                .env(.view, "refmax").when(reference),
        ])
    }()

    private static let globalIllumination: Section = {
        let on: When = { $0.giEnabled }
        let paths: When = { $0.giMode == .pathTraced }, cascades: When = { $0.giMode == .radianceCascades }
        let restir: When = { $0.giMode == .restirGI }
        let spatial: When = { restir($0) && $0.restirGI.spatialPasses > 0 }
        let feedback: When = { restir($0) && $0.restirGI.feedback }
        let denoised: When = { restir($0) && $0.restirGI.denoise }
        let passes = [("Off", 0), ("1 pass", 1), ("2 passes", 2)]
        return Section(title: "Global illumination", rows: [
            S.check("Enabled", \.giEnabled).env(.gi, "on"),
            S.popup("Method", \.giMode, titled(\.title)).env(.gi, "mode").enabled(on),
            S.slider("Bounces", \.bounces, RenderSettings.bounceRange).env(.gi, "bounces").when(paths).enabled(on),
            S.check("Light bounces from light maps", \.lightMaps).env(.gi, "lightmaps").when(paths).enabled(on),
            S.popup("Probe spacing", \.cascades.probeSpacing, counts: CascadeSettings.spacingOptions) { "\($0) px" }
                .env(.gi, "spacing").when(cascades).enabled(on),
            S.slider("Cascades", \.cascades.cascades, CascadeSettings.cascadeRange).env(.gi, "cascades").when(cascades).enabled(on),
            S.slider("First interval", \.cascades.firstInterval, CascadeSettings.firstIntervalRange, step: 0.05, fmt("%.2f m"))
                .env(.gi, "b1").when(cascades).enabled(on),
            S.check("Multi-bounce", \.cascades.feedback).env(.gi, "feedback").when(cascades).enabled(on),
            S.check("Denoise cascade GI", \.cascades.denoiseIndirect).env(.gi, "cdenoise").when(cascades).enabled(on),
            S.popup("Rays", \.restirGI.quarterBudget, [("1 per pixel", false), ("1 per 2×2 pixels", true)])
                .env(.restirGI, "quarter").when(restir).enabled(on),
            S.slider("Bounces", \.restirGI.bounces, RenderSettings.bounceRange).env(.restirGI, "bounces").when(restir).enabled(on),
            S.check("Multi-bounce", \.restirGI.feedback).env(.restirGI, "feedback").when(restir).enabled(on),
            S.check("Temporal reuse", \.restirGI.temporal).env(.restirGI, "temporal").when(restir).enabled(on),
            S.popup("Spatial reuse", \.restirGI.spatialPasses, counts: passes.map(\.1)) { passes[$0].0 }
                .env(.restirGI, "spatial").when(restir).enabled(on),
            S.check("Unbiased spatial reuse", \.restirGI.unbiased).env(.restirGI, "unbiased").when(restir)
                .enabled { $0.giEnabled && $0.restirGI.spatialPasses > 0 },
            S.check("Light bounces from light maps", \.restirGI.lightMaps).env(.restirGI, "lightmaps").advanced().when(restir),
            S.check("Multi-bounce from denoised light", \.restirGI.denoisedFeedback).env(.restirGI, "dfeedback").advanced().when(feedback),
            S.check("Multi-bounce off screen (mean)", \.restirGI.feedbackFallback).env(.restirGI, "fallback").advanced().when(feedback),
            S.slider("Max M", \.restirGI.maxM, RestirGISettings.maxMRange, step: 1, log: true, fmt("%.0f")).env(.restirGI, "maxm").advanced().when(restir),
            S.slider("Max age", \.restirGI.maxAge, RestirGISettings.maxAgeRange) { "\($0) fr" }.env(.restirGI, "age").advanced().when(restir),
            S.slider("Neighbours", \.restirGI.spatialSamples, RestirGISettings.spatialSampleRange).env(.restirGI, "k").advanced().when(spatial),
            S.slider("Radius", \.restirGI.radius, RestirGISettings.radiusRange, step: 1, fmt("%.0f px")).env(.restirGI, "radius").advanced().when(spatial),
            S.slider("Min distance", \.restirGI.minDistance, RestirGISettings.minDistanceRange, step: 0.001, log: true, fmt("%.3f m"))
                .env(.restirGI, "dmin").advanced().when(restir),
            S.check("Denoise ReSTIR GI", \.restirGI.denoise).env(.restirGI, "denoise").advanced().when(restir),
            S.slider("Filter passes", \.restirGI.denoisePasses, DenoiserSettings.passRange).env(.restirGI, "passes").advanced().when(denoised),
            S.slider("Edge tolerance (σ)", \.restirGI.denoiseSigma, DenoiserSettings.luminanceSigmaRange, step: 0.05, fmt("%.2f"))
                .env(.restirGI, "sigma").advanced().when(denoised),
            S.slider("History length", \.restirGI.denoiseHistory, DenoiserSettings.maxHistoryRange, step: 1, fmt("%.0f fr"))
                .env(.restirGI, "history").advanced().when(denoised),
            S.slider("Variance boost", \.restirGI.varianceBoost, DenoiserSettings.varianceBoostRange, step: 0.25, fmt("%.2f×"))
                .env(.restirGI, "boost").advanced().when(denoised),
            S.slider("Anti-lag", \.restirGI.antiLag, DenoiserSettings.antiLagRange, step: 0.1) { $0 == 0 ? "off" : String(format: "%.1f", $0) }
                .env(.restirGI, "antilag").advanced().when(denoised),
        ])
    }()

    private static let fog: Section = {
        let on: When = { $0.fog.enabled }
        return Section(title: "Fog", rows: [
            S.check("Enabled", \.fog.enabled).env(.fog),
            S.value(\.fog.enabled).env(.fogSet, "on", exported: false),
            S.slider("Density", \.fog.density, FogSettings.densityRange, digits: 2, log: true, fmt("%.3g /m")).env(.fogSet, "density").when(on),
            S.slider("Height falloff", \.fog.heightFalloff, FogSettings.falloffRange, step: 0.01, fmt("%.2f /m")).env(.fogSet, "falloff").when(on),
            S.slider("Forward scattering", \.fog.anisotropy, FogSettings.anisotropyRange, step: 0.05, fmt("%.2f")).env(.fogSet, "g").when(on),
            S.slider("Ambient light", \.fog.ambient, FogSettings.ambientRange, step: 0.05, fmt("%.2f")).env(.fogSet, "ambient").when(on),
            S.slider("Noise", \.fog.noise, FogSettings.noiseRange, step: 0.05, fmt("%.2f")).env(.fogSet, "noise").when(on),
            S.slider("Distance", \.fog.maxDistance, FogSettings.distanceRange, step: 5, fmt("%.0f m")).env(.fogSet, "far").when(on),
            S.slider("Haze beyond", \.fog.haze, FogSettings.hazeRange, step: 0.05, fmt("%.2f")).env(.fogSet, "haze").when(on),
            S.check("Local fog volumes", \.fog.volumes).env(.fogSet, "volumes").when(on),
            S.check("Fog in reflections", \.fog.reflections).env(.fogSet, "reflections").when(on),
            S.check("Lights scatter in it", \.fog.lights).env(.fogSet, "lights").when(on),
            S.slider("Base height", \.fog.baseHeight, FogSettings.baseHeightRange, step: 0.25, fmt("%.2f m")).env(.fogSet, "base").advanced().when(on),
            S.slider("Noise tile", \.fog.noiseScale, FogSettings.noiseScaleRange, step: 0.5, fmt("%.1f m")).env(.fogSet, "tile").advanced().when(on),
            // The wind's horizontal speed and heading; its env name carries the whole vector.
            S.slider("Wind", \.fog.windSpeed, FogSettings.windSpeedRange, step: 0.05, fmt("%.2f m/s")).advanced().when(on),
            S.slider("Wind direction", \.fog.windDirection, -180...180, step: 5, fmt("%.0f°")).advanced().when(on),
            S.value(\.fog.wind).env(.fogSet, "wind"),
            S.custom(.fogAlbedo, "Albedo").advanced().when(on),
            S.value(\.fog.albedo).env(.fogSet, "albedo"),
        ])
    }()

    private static let sky: Section = {
        let image: When = { $0.sky.mode == .image }
        let hasClouds: When = { $0.sky.mode != .constant }
        let cloudy: When = { $0.sky.cloudsShown }
        return Section(title: "Sky", rows: [
            S.custom(.skyMode, "Sky"),     // METALRENDERER_SKY: the mode's name or an image's path (SettingsEnv)
            S.custom(.skyImage).when(image),
            S.slider("Image exposure", \.sky.imageExposure, RenderSettings.exposureRange, step: 0.1, fmt("%+.1f EV"))
                .env(.skySet, "exposure").advanced().when(image),
            S.check("Clouds", \.sky.cloudsShown).when(hasClouds),
            S.value(\.sky.clouds).env(.skySet, "clouds"),
            S.value(\.sky.cloudsOverImage).env(.skySet, "over"),
            S.slider("Coverage", \.sky.coverage, SkySettings.coverageRange, step: 0.01, fmt("%.2f")).env(.skySet, "coverage").when(hasClouds).enabled(cloudy),
            S.slider("Cloud density", \.sky.density, SkySettings.densityRange, step: 0.001, fmt("%.3f /m")).env(.skySet, "density").when(hasClouds).enabled(cloudy),
            S.slider("Cloud height", \.sky.cloudBase, SkySettings.cloudBaseRange, step: 50, fmt("%.0f m")).env(.skySet, "base").when(hasClouds).enabled(cloudy),
            S.slider("Wind", \.sky.windSpeed, SkySettings.windRange, step: 1, fmt("%.0f m/s")).env(.skySet, "wind").when(hasClouds).enabled(cloudy),
            S.check("Cloud shadows", \.sky.shadows).env(.skySet, "shadows").when(hasClouds).enabled(cloudy),
            S.slider("Cloud thickness", \.sky.cloudThickness, SkySettings.cloudThicknessRange, step: 50, fmt("%.0f m"))
                .env(.skySet, "thickness").advanced().when(hasClouds),
            S.slider("Cloud size", \.sky.cloudScale, SkySettings.cloudScaleRange, step: 100, log: true, fmt("%.0f m"))
                .env(.skySet, "scale").advanced().when(hasClouds),
            S.slider("Erosion", \.sky.erosion, 0...1, step: 0.01, fmt("%.2f")).env(.skySet, "erosion").advanced().when(hasClouds),
            S.slider("Wind direction", \.sky.windDirection, 0...360, step: 5, fmt("%.0f°")).env(.skySet, "winddir").advanced().when(hasClouds),
            S.slider("Shadow strength", \.sky.shadowStrength, 0...1, step: 0.05, fmt("%.2f"))
                .env(.skySet, "strength").advanced().when { hasClouds($0) && $0.sky.shadows },
        ])
    }()

    private static let denoiser: Section = {
        // While upscaling, the MetalFX denoiser denoises in place of everything here.
        let ours: When = { !$0.neuralDenoiser }
        let on: When = { $0.denoiser.enabled && ours($0) }
        let shadows: When = { on($0) && $0.denoiser.shadowDenoiser }
        return Section(title: "Denoiser", rows: [
            S.custom(.denoiserCaption),
            S.check("Enabled", \.denoiser.enabled).env(.denoise, "on").enabled(ours),
            S.check("Shadow denoiser (direct light)", \.denoiser.shadowDenoiser).env(.denoise, "shadows").enabled(on),
            S.slider("Shadow passes", \.denoiser.shadowPasses, DenoiserSettings.passRange).env(.denoise, "spasses").enabled(shadows),
            S.slider("Shadow history", \.denoiser.shadowHistory, DenoiserSettings.maxHistoryRange, step: 1, fmt("%.0f fr"))
                .env(.denoise, "shistory").advanced().when(shadows),
            S.slider("Shadow clamp", \.denoiser.shadowClamp, DenoiserSettings.shadowClampRange, step: 0.05, fmt("%.2f σ"))
                .env(.denoise, "sclamp").advanced().when(shadows),
            S.slider("Shadow edges (σ)", \.denoiser.shadowSigma, DenoiserSettings.shadowSigmaRange, step: 0.25, fmt("%.2f"))
                .env(.denoise, "ssigma").advanced().when(shadows),
            S.check("Separate direct / indirect", \.denoiser.separateSignals).env(.denoise, "separate").enabled(on),
            // One slider for the selected GI method's count; each count has its own env name.
            S.slider("Filter passes", \.filterPasses, DenoiserSettings.passRange).enabled(on),
            S.value(\.denoiser.atrousPasses).env(.denoise, "passes"),
            S.value(\.denoiser.techniquePasses).env(.denoise, "tpasses"),
            S.slider("Edge tolerance (σ)", \.denoiser.luminanceSigma, DenoiserSettings.luminanceSigmaRange, step: 0.05, fmt("%.2f"))
                .env(.denoise, "sigma").enabled(on),
            S.slider("History length", \.denoiser.maxHistory, DenoiserSettings.maxHistoryRange, step: 1, fmt("%.0f fr"))
                .env(.denoise, "history").enabled(on),
            S.slider("Anti-lag", \.denoiser.antiLag, DenoiserSettings.antiLagRange, step: 0.1) { $0 == 0 ? "off" : String(format: "%.1f", $0) }
                .env(.denoise, "antilag").enabled(on),
        ])
    }()

    private static let memory = Section(title: "Memory", advanced: true, rows: [
        S.popup("Geometry pool", \.virtualGeometry.poolMB, VirtualGeometrySettings.poolOptions.map { ("\($0) MB", $0) }).env(.vgPool).advanced(),
        S.popup("Texture budget", \.textureBudgetMB, RenderSettings.textureBudgetOptions.map { ("\($0) MB", $0) }).env(.textureBudget).advanced(),
    ])
}
