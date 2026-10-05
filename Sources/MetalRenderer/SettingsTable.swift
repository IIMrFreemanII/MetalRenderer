import CoreGraphics
import Foundation
import simd

/// A value that can be written into a `METALRENDERER_*` variable and read back from one.
protocol EnvValue: Equatable {
    var envText: String { get }
    init?(envText: String)
}

extension Float: EnvValue {
    /// The shortest text that reads back as the same Float.
    var envText: String {
        let text = "\(self)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    init?(envText: String) { self.init(envText) }
}
extension CGFloat: EnvValue {
    var envText: String { Float(self).envText }
    init?(envText: String) {
        guard let v = Float(envText) else { return nil }
        self.init(v)
    }
}
extension Int: EnvValue {
    var envText: String { "\(self)" }
    init?(envText: String) {   // "2.7" reads as 2, as it always has
        guard let v = Float(envText), v.isFinite, abs(v) < 1e9 else { return nil }
        self.init(v)
    }
}
extension Bool: EnvValue {
    var envText: String { self ? "1" : "0" }
    init?(envText: String) {
        guard let v = Float(envText) else { return nil }
        self.init(v != 0)
    }
}
extension SIMD3: EnvValue where Scalar == Float {
    var envText: String { "\(x.envText):\(y.envText):\(z.envText)" }
    init?(envText: String) {
        let v = envText.split(separator: ":").compactMap { Float($0) }
        guard v.count == 3 else { return nil }
        self.init(v[0], v[1], v[2])
    }
}

/// An enum written by name: its case name unless `envName` says otherwise. Read back without regard to case.
protocol EnvNamed: EnvValue, CaseIterable {
    var envName: String { get }
}
extension EnvNamed {
    var envName: String { "\(self)" }
    var envText: String { envName }
    init?(envText: String) {
        guard let match = Self.allCases.first(where: { $0.envName == envText.lowercased() }) else { return nil }
        self = match
    }
}
extension GIMode: EnvNamed {
    var envName: String { ["pt", "cascades", "restir"][rawValue] }
}
extension ToneMap: EnvNamed {}
extension DirectLightMode: EnvNamed {}
extension RayTracerKind: EnvNamed {}
extension RenderAPI: EnvNamed {}
extension PrimaryVisibility: EnvNamed {}
extension ShadowMethod: EnvNamed {
    var envName: String { ["rays", "vsm"][rawValue] }
}
extension SceneKind: EnvNamed {
    var envName: String { "\(self)".lowercased() }   // cityNight is read back without regard to case
}
extension CityStyle: EnvNamed {}

/// The `METALRENDERER_*` variables that carry settings, in the order Copy as Env writes them.
enum EnvVariable: String, CaseIterable {
    // One value each.
    case direct = "METALRENDERER_DIRECT", rt = "METALRENDERER_RT", api = "METALRENDERER_API", specular = "METALRENDERER_SPECULAR"
    case primary = "METALRENDERER_PRIMARY", shadowMethod = "METALRENDERER_SHADOW_METHOD"
    case textureBudget = "METALRENDERER_TEXTURE_BUDGET"
    case vg = "METALRENDERER_VG", vgTau = "METALRENDERER_VG_TAU", vgPool = "METALRENDERER_VG_POOL"
    case fog = "METALRENDERER_FOG", sky = "METALRENDERER_SKY"
    // Lists of key=value.
    case scene = "METALRENDERER_SCENE", gi = "METALRENDERER_GI", denoise = "METALRENDERER_DENOISE"
    case restir = "METALRENDERER_RESTIR", restirGI = "METALRENDERER_RESTIR_GI", megaLights = "METALRENDERER_MEGALIGHTS"
    case fogSet = "METALRENDERER_FOG_SET", skySet = "METALRENDERER_SKY_SET", view = "METALRENDERER_VIEW"
    case foliage = "METALRENDERER_FOLIAGE", vsm = "METALRENDERER_VSM"

    var isList: Bool { self.index >= EnvVariable.scene.index }
    private var index: Int { EnvVariable.allCases.firstIndex(of: self)! }
}

/// One setting, described once: where it lives in `RenderSettings`, its name in the `METALRENDERER_*` variables, and
/// the panel row that edits it. Copy as Env, the env parser and the settings panel are all built from these
/// (`SettingsTable.sections`); a new setting is one line there.
struct SettingSpec {
    /// The panel's control for it.
    enum Control {
        case slider(Slider)
        case checkbox(get: (RenderSettings) -> Bool, set: (inout RenderSettings, Bool) -> Void)
        case popup(titles: [String], selected: (RenderSettings) -> Int, select: (inout RenderSettings, Int) -> Void)
        case custom(Custom)
    }
    struct Slider {
        let range: ClosedRange<Double>                      // slider positions (log2 of the value on a log slider)
        let ticks: Int                                      // tick marks the slider snaps to; 0 = none
        let live: Bool                                      // false: applies when the slider is released
        let position: (RenderSettings) -> Double
        let move: (inout RenderSettings, Double) -> Void    // a position, rounded and clamped, into the setting
        let text: (RenderSettings) -> String                // the value shown next to the slider
    }
    /// Rows that are more than one setting behind one control; the panel builds them by hand (SettingsPanel.customRow).
    enum Custom {
        case scene, clearModels, lightRays, upscale, skyMode, skyImage, fogAlbedo, denoiserCaption
    }
    /// The setting as text in an environment variable.
    struct Env {
        var variable = EnvVariable.gi
        var key: String?                // in a key=value list; nil: the variable's whole value
        var interactiveOnly = false     // read only outside benchmarks, whose settings choose it themselves
        var exported = true             // false: an alias that is only read
        let text: (RenderSettings) -> String
        let differs: (RenderSettings, RenderSettings) -> Bool
        let parse: (inout RenderSettings, String) -> Bool
    }

    var title = ""                                  // the row's label, or its checkbox's title
    var control: Control?                           // nil: no row (a setting with only an env name)
    var advanced = false                            // shown only with Show advanced
    var visible: ((RenderSettings) -> Bool)?        // nil: always
    var enabled: ((RenderSettings) -> Bool)?        // nil: always
    var available: ((Int) -> Bool)?                 // a popup's items this GPU can run (Capabilities); nil: all
    var env: Env?                                   // its `variable` is meaningful once `env(_:_:)` named it
    private var named = false

    /// The spec's env name, if it has one.
    var envName: Env? { named ? env : nil }

    // MARK: Modifiers

    func env(_ variable: EnvVariable, _ key: String? = nil, interactiveOnly: Bool = false, exported: Bool = true) -> SettingSpec {
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
    func advanced(_ on: Bool = true) -> SettingSpec { var s = self; s.advanced = on; return s }
    func when(_ condition: @escaping (RenderSettings) -> Bool) -> SettingSpec { var s = self; s.visible = condition; return s }
    func enabled(_ condition: @escaping (RenderSettings) -> Bool) -> SettingSpec { var s = self; s.enabled = condition; return s }
    /// A popup's items by index: the panel greys out the ones `item` rejects.
    func available(_ item: @escaping (Int) -> Bool) -> SettingSpec { var s = self; s.available = item; return s }

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
    static func value<T: EnvValue>(_ path: WritableKeyPath<RenderSettings, T>) -> SettingSpec {
        SettingSpec(env: codec(path))
    }

    /// A slider for a Float (or CGFloat) setting, rounded to `step` (or to `digits` significant digits). `log` spaces
    /// it logarithmically; `ticks` makes it snap to the steps.
    static func slider<F: BinaryFloatingPoint & EnvValue>(_ title: String, _ path: WritableKeyPath<RenderSettings, F>,
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
    static func slider(_ title: String, _ path: WritableKeyPath<RenderSettings, Int>, _ range: ClosedRange<Int>,
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

    static func check(_ title: String, _ path: WritableKeyPath<RenderSettings, Bool>) -> SettingSpec {
        SettingSpec(title: title, control: .checkbox(get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 }),
                    env: codec(path))
    }

    /// A popup choosing among `options` (title, value). A value that is none of them selects nothing.
    static func popup<T: EnvValue>(_ title: String, _ path: WritableKeyPath<RenderSettings, T>,
                                   _ options: [(String, T)]) -> SettingSpec {
        let control = Control.popup(titles: options.map(\.0),
                                    selected: { s in options.firstIndex { $0.1 == s[keyPath: path] } ?? -1 },
                                    select: { $0[keyPath: path] = options[$1].1 })
        return SettingSpec(title: title, control: control, env: codec(path))
    }

    /// A popup over a few counts. A count in between shows as the next one up.
    static func popup(_ title: String, _ path: WritableKeyPath<RenderSettings, Int>, counts: [Int],
                      _ name: @escaping (Int) -> String) -> SettingSpec {
        let control = Control.popup(titles: counts.map(name),
                                    selected: { s in counts.firstIndex { $0 >= s[keyPath: path] } ?? counts.count - 1 },
                                    select: { $0[keyPath: path] = counts[$1] })
        return SettingSpec(title: title, control: control, env: codec(path))
    }

    static func custom(_ row: Custom, _ title: String = "") -> SettingSpec {
        SettingSpec(title: title, control: .custom(row))
    }
}

extension RenderSettings {
    /// Upscaling, through MetalFX's denoising scaler: it denoises the raw light, and SVGF and the shadow denoiser are off.
    var neuralDenoiser: Bool { upscaleFactor > 1 }

    /// The denoiser's wavelet passes for the selected GI method: the panel's one slider edits whichever count applies.
    var filterPasses: Int {
        get { denoiser.passes(for: giMode) }
        set { if giMode == .pathTraced { denoiser.atrousPasses = newValue } else { denoiser.techniquePasses = newValue } }
    }
}

extension SkySettings {
    /// Whether clouds are drawn: over an image they have their own switch (in front of the image).
    var cloudsShown: Bool {
        get { mode == .image ? cloudsOverImage : clouds }
        set { if mode == .image { cloudsOverImage = newValue } else { clouds = newValue } }
    }
}

/// Every setting, in the panel's order. See `SettingSpec`.
enum SettingsTable {
    struct Section {
        let title: String
        var advanced = false
        let rows: [SettingSpec]
    }

    /// Every spec that has an env name, in table order.
    static let named: [SettingSpec.Env] = sections.flatMap(\.rows).compactMap(\.envName)

    private typealias S = SettingSpec
    private typealias When = (RenderSettings) -> Bool

    private static func fmt<T: CVarArg>(_ format: String) -> (T) -> String { { String(format: format, $0) } }
    private static func titled<T: CaseIterable>(_ title: (T) -> String) -> [(String, T)] { T.allCases.map { (title($0), $0) } }

    static let sections: [Section] = [scene, camera, directLight, rendering, globalIllumination, fog, sky, foliage, denoiser, memory]

    private static let foliage: Section = {
        let plants: When = { $0.scene.kind.hasPlants }
        let assemblies: When = { $0.rayTracer == .custom }   // Metal's tracer has the plants baked: they stand still
        return Section(title: "Foliage", rows: [
            S.slider("Wind", \.foliage.wind, FoliageSettings.windRange, step: 0.05, fmt("%.2f")).env(.foliage, "wind").when(plants).enabled(assemblies),
            S.slider("Wind direction", \.foliage.windDirection, FoliageSettings.directionRange, step: 5, fmt("%.0f°"))
                .env(.foliage, "dir").when(plants).enabled(assemblies),
            S.slider("Gusts", \.foliage.gusts, FoliageSettings.gustRange, step: 0.05, fmt("%.2f")).env(.foliage, "gusts").when(plants).enabled(assemblies),
            S.slider("Season", \.foliage.season, FoliageSettings.seasonRange, step: 0.02, fmt("%.2f")).env(.foliage, "season").when(plants),
            S.slider("Leaf translucency", \.foliage.translucency, FoliageSettings.translucencyRange, step: 0.05, fmt("%.2f"))
                .env(.foliage, "translucency").when(plants),
            S.slider("Distance LOD (voxels)", \.foliage.lod, FoliageSettings.lodRange, step: 0.25, fmt("%.2g px"))
                .env(.foliage, "lod").when(plants),   // both tracers (Metal's: VoxelLOD)
        ])
    }()

    private static let scene: Section = {
        let customTracer: When = { $0.rayTracer == .custom }   // Metal would need its acceleration structures rebuilt per cut
        let virtual: When = { $0.rayTracer == .custom && $0.virtualGeometry.enabled }
        let city: When = { $0.scene.kind.isCity }
        let percent: (Float) -> String = { String(format: "%.0f%%", $0 * 100) }
        return Section(title: "Scene", rows: [
            S.custom(.scene, "Scene"),
            // Scene sizes rebuild the scene, so they apply when the slider is released.
            S.slider("Objects", \.scene.objects, SceneSettings.objectRange, step: 50, live: false)
                .env(.scene, "objects").when { $0.scene.kind == .stress },
            S.slider("Lights", \.scene.lights, SceneSettings.lightRange, log: true, live: false)
                .env(.scene, "lights").when { $0.scene.kind.hasLightCount },
            S.slider("Characters", \.scene.characters, SceneSettings.characterRange, log: true, live: false)
                .env(.scene, "characters").when { $0.scene.kind == .crowd },
            S.slider("Poses", \.scene.poses, SceneSettings.poseRange, log: true, live: false)
                .env(.scene, "poses").when { $0.scene.kind == .crowd },
            S.slider("Detail level", \.scene.detail, SceneSettings.detailRange, live: false)
                .env(.scene, "detail").when { $0.scene.kind == .crowd },
            S.slider("City seed", \.scene.seed, SceneSettings.seedRange, live: false).when(city),   // `seed`, as the plants'
            S.slider("City blocks", \.scene.city.blocks, CitySettings.blockRange, live: false) { "\($0) x \($0)" }
                .env(.scene, "blocks").when(city),
            S.popup("Building style", \.scene.city.style, titled(\.title)).env(.scene, "style").when(city),
            S.slider("Lit windows", \.scene.city.lit, CitySettings.litRange, step: 0.05, live: false, percent)
                .env(.scene, "lit").when { $0.scene.kind.hasLitWindows },
            S.slider("Rooms behind windows", \.scene.city.rooms, CitySettings.roomRange, step: 0.05, live: false, percent)
                .env(.scene, "rooms").when(city),
            S.check("Generated textures", \.scene.city.textures).env(.scene, "textures").when(city),
            S.slider("Trees", \.scene.trees, SceneSettings.treeRange, step: 250, live: false)
                .env(.scene, "trees").when { $0.scene.kind.hasForest },
            S.slider("Undergrowth", \.scene.undergrowth, SceneSettings.undergrowthRange, step: 25, live: false) { "\($0)%" }
                .env(.scene, "undergrowth").when { $0.scene.kind.hasForest },
            S.slider("Plant seed", \.scene.seed, SceneSettings.seedRange, live: false)
                .env(.scene, "seed").when { $0.scene.kind.hasPlants },
            S.check("Leaves as cards", \.scene.leafCards).env(.scene, "cards").when { $0.scene.kind.hasPlants }.enabled(customTracer),
            S.check("Plants as plain meshes", \.scene.bakedPlants).env(.scene, "baked").when { $0.scene.kind.hasPlants }
                .enabled(customTracer).advanced(),
            S.check("Far plants as voxels", \.scene.voxelBoxes).env(.scene, "voxels").when { $0.scene.kind.hasPlants }
                .enabled { $0.rayTracer == .metal }.advanced(),
            S.popup("Ray tracing", \.rayTracer, titled(\.title)).env(.rt)
                .available { RayTracerKind.allCases[$0] != .metal || Capabilities.current.metalRayTracing },
            S.popup("Graphics API", \.api, titled(\.title)).env(.api)
                .available { RenderAPI.allCases[$0] != .metal4 || Capabilities.current.metal4 },
            S.popup("Primary visibility", \.primary, titled(\.title)).env(.primary),
            S.check("Virtual geometry (LOD)", \.virtualGeometry.enabled).env(.vg).enabled(customTracer),
            S.slider("Geometry error", \.virtualGeometry.pixelError, VirtualGeometrySettings.pixelErrorRange, step: 0.25, log: true,
                     fmt("%.2g px")).env(.vgTau).enabled(virtual),
            // It also holds the plants' voxel levels (both tracers).
            S.check("Freeze LOD (L)", \.virtualGeometry.freeze).enabled { virtual($0) || $0.scene.kind.hasPlants },
            S.check("Specular (glTF PBR)", \.specular).env(.specular),
            S.check("Emissive surfaces are lights", \.scene.emissiveLights).env(.scene, "emissivelights"),
            S.custom(.clearModels).when { !$0.scene.extraModels.isEmpty },
        ])
    }()

    private static let camera = Section(title: "Camera and time", rows: [
        S.slider("Exposure", \.exposure, RenderSettings.exposureRange, step: 0.1, fmt("%+.1f EV")).env(.view, "exposure"),
        S.popup("Tone map", \.toneMap, titled(\.title)).env(.view, "tonemap"),
        S.slider("Field of view", \.fovDegrees, RenderSettings.fovRange, step: 1, fmt("%.0f°")).env(.view, "fov"),
        S.slider("Move speed", \.moveSpeed, RenderSettings.moveSpeedRange, step: 0.5, log: true, fmt("%g m/s")).env(.view, "speed"),
        S.check("Pause animation", \.paused).env(.view, "paused", interactiveOnly: true),
        S.slider("Time scale", \.timeScale, RenderSettings.timeScaleRange, step: 0.05, fmt("%.2f×")).env(.view, "timescale"),
        S.slider("Time of day", \.timeOfDay, 0...1, step: 0.01) { String(format: "%.0f%%", $0 * 100) }
            .env(.view, "tod").when { $0.scene.kind.dayCycle != nil },
    ])

    private static let directLight: Section = {
        let restir: When = { $0.directLight == .restir || $0.directLight == .auto }
        let spatial: When = { restir($0) && $0.restir.spatialPasses > 0 }
        let grid: When = { restir($0) && $0.restir.grid.enabled }
        let megaLights: When = { $0.directLight == .megalights }
        let vsm: When = { $0.shadowMethod == .virtualMaps }
        let passes = [("Off", 0), ("1 pass", 1), ("2 passes", 2)]
        return Section(title: "Direct light", rows: [
            S.popup("Method", \.directLight, titled { $0 == .auto ? "Auto (ReSTIR above 256 lights)" : $0.title }).env(.direct),
            S.popup("Shadows", \.shadowMethod, titled(\.title)).env(.shadowMethod),
            S.popup("Page pool", \.vsm.pool, counts: VSMSettings.poolOptions) { "\($0) pages (\($0 / 16) MB)" }
                .env(.vsm, "pool").advanced().when(vsm),
            S.slider("Pages a frame", \.vsm.budget, VSMSettings.budgetRange).env(.vsm, "budget").advanced().when(vsm),
            S.slider("Sun levels", \.vsm.levels, VSMSettings.levelRange) { "\($0) (\(16 << ($0 - 1)) m)" }
                .env(.vsm, "levels").advanced().when(vsm),
            S.slider("Mapped lights", \.vsm.maxLights, VSMSettings.maxLightRange).env(.vsm, "lights").advanced().when(vsm),
            S.slider("March steps", \.vsm.steps, VSMSettings.stepRange).env(.vsm, "steps").advanced().when(vsm),
            S.slider("Depth bias", \.vsm.bias, VSMSettings.biasRange, step: 0.25, fmt("%.2f texels")).env(.vsm, "bias").advanced().when(vsm),
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
            S.slider("Samples", \.megaLights.samples, MegaLightsSettings.sampleRange) { "\($0) per pixel" }
                .env(.megaLights, "samples").when(megaLights),
            S.slider("Tree samples", \.megaLights.treeSamples, MegaLightsSettings.treeSampleRange) { "\($0) (far field)" }
                .env(.megaLights, "tree").advanced().when(megaLights),
            S.check("Split lights (list near, tree far)", \.megaLights.partition).env(.megaLights, "partition").advanced().when(megaLights),
            S.check("Guiding (last frame's visible lights)", \.megaLights.guiding).env(.megaLights, "guide").when(megaLights),
            S.slider("Guide weight", \.megaLights.guideWeight, MegaLightsSettings.guideWeightRange, step: 0.05, fmt("%.2f"))
                .env(.megaLights, "gweight").advanced().when { megaLights($0) && $0.megaLights.guiding },
            S.slider("Light cutoff", \.megaLights.cutoff, MegaLightsSettings.cutoffRange, digits: 2, log: true, fmt("%.2g"))
                .env(.megaLights, "cutoff").advanced().when(megaLights),
            S.popup("Tile list", \.megaLights.capacity, counts: MegaLightsSettings.capacityOptions) { "\($0) lights" }
                .env(.megaLights, "capacity").advanced().when(megaLights),
            S.slider("Filter passes", \.megaLights.denoisePasses, DenoiserSettings.passRange).env(.megaLights, "passes").advanced().when(megaLights),
            S.slider("Edge tolerance (σ)", \.megaLights.denoiseSigma, DenoiserSettings.luminanceSigmaRange, step: 0.05, fmt("%.2f"))
                .env(.megaLights, "sigma").advanced().when(megaLights),
            S.slider("History length", \.megaLights.denoiseHistory, DenoiserSettings.maxHistoryRange, step: 1, fmt("%.0f fr"))
                .env(.megaLights, "history").advanced().when(megaLights),
            S.slider("Variance boost", \.megaLights.varianceBoost, DenoiserSettings.varianceBoostRange, step: 0.25, fmt("%.2f×"))
                .env(.megaLights, "boost").advanced().when(megaLights),
        ])
    }()

    private static let rendering: Section = {
        Section(title: "Rendering", rows: [
            S.slider("Render scale", \.renderScale, RenderSettings.renderScaleRange, step: Double(RenderSettings.renderScaleStep),
                     ticks: true, fmt("%.3g×")).env(.gi, "scale"),
            S.custom(.upscale, "Upscale (MetalFX denoiser)"),
            S.value(\.upscaleFactor).env(.gi, "factor"),
            S.check("Blue-noise sampling", \.blueNoise).env(.gi, "blue"),
            S.popup("View", \.viewMode, RenderSettings.viewModes.enumerated().map { ($1, $0) }).env(.view, "view", interactiveOnly: true),
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
