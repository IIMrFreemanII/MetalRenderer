import Foundation
import simd

/// How the showcase (Scene+Showcase.swift) stages one model of `Assets/`: the set it stands in, its lights' colours, what
/// drifts through the air, and the fog and lens it is seen through. One row of `looks` a model; a model without a row
/// (one the user put in Assets/) gets the studio.
struct ShowcaseLook {
    /// The set around the model.
    enum Stage {
        case studio      // a dark cyclorama, the key beam and two rims
        case crypt       // a stone hall: low light through tall windows in shafts over ground mist
        case forge       // dark brick round a glowing pit, embers and smoke
        case underwater  // deep water: dense tinted fog, swaying shafts from the surface, bubbles; the model drifts
        case neon        // a glossy black floor between coloured panels and strips, a sweeping scanner beam
        case workshop    // an interior at dusk: a window's sun shaft, a desk lamp, a flickering tube
        case sanctum     // a round dais under one beam, runes circling the model in a coloured cloud
    }
    enum Particles { case none, embers, bubbles, dust, runes }

    var stage = Stage.studio
    var size: Float = 1.8                       // the model's largest side (m)
    var spin: Float = 0.12                      // its turntable (rad/s); 0 = it stays as it stands
    var view: Float = 0.45                      // the camera's angle round the model from its front (+z), radians
    var key = SIMD3<Float>(1, 0.92, 0.8)        // the colours: the beam from above...
    var rim = SIMD3<Float>(0.6, 0.75, 1)        // ...the lights behind it...
    var accent = SIMD3<Float>(1, 0.6, 0.3)      // ...and the set's own glow (the plinth's ring, the pit, the runes, panels)
    var sky = SIMD3<Float>(0.01, 0.012, 0.016)  // the constant sky: what the fog's ambient light is made of
    var particles = Particles.none
    /// The fog, from the showcase's preset (FogSettings.preset(for: .showcase)).
    var fog: (inout FogSettings) -> Void = { _ in }
    var post = ShowcaseLook.lens

    /// The lens every look starts from.
    static let lens = PostSettings(bloom: 0.06, bloomThreshold: 1, aperture: 6, focus: 0, vignette: 0.35, grain: 0.015,
                                   aberration: 0.0015)

    /// The models of Assets/, by a part of their file name.
    static let looks: [(match: String, look: ShowcaseLook)] = [
        ("battle maiden", ShowcaseLook(
            stage: .neon, key: [0.85, 0.92, 1], rim: [0.3, 0.55, 1], accent: [0.2, 0.85, 1], sky: [0.004, 0.006, 0.012],
            particles: .dust,
            fog: { $0.density = 0.035; $0.heightFalloff = 0.05; $0.anisotropy = 0.7; $0.albedo = [0.8, 0.85, 1] },
            post: lens.with { $0.bloom = 0.08; $0.aberration = 0.002 })),
        ("cat robot", ShowcaseLook(
            stage: .neon, size: 1.5, key: [1, 0.85, 0.95], rim: [1, 0.15, 0.6], accent: [0.1, 0.85, 1], sky: [0.006, 0.003, 0.01],
            fog: { $0.density = 0.04; $0.heightFalloff = 0.05; $0.anisotropy = 0.6; $0.albedo = [0.95, 0.85, 1] },
            post: lens.with { $0.bloom = 0.1; $0.aperture = 4; $0.aberration = 0.0025 })),
        ("fantasy character", ShowcaseLook(
            stage: .sanctum, key: [1, 0.85, 0.55], rim: [1, 0.7, 0.35], accent: [1, 0.72, 0.28], sky: [0.012, 0.009, 0.006],
            particles: .runes,
            fog: { $0.density = 0.03; $0.albedo = [1, 0.9, 0.75] },
            post: lens.with { $0.bloom = 0.08 })),
        ("sorceress", ShowcaseLook(
            stage: .sanctum, key: [0.85, 0.8, 1], rim: [0.65, 0.3, 1], accent: [0.2, 1, 0.85], sky: [0.008, 0.005, 0.014],
            particles: .runes,
            fog: { $0.density = 0.035; $0.albedo = [0.8, 0.7, 1] },
            post: lens.with { $0.bloom = 0.1 })),
        ("demon", ShowcaseLook(
            stage: .forge, size: 2.2, view: 0.35, key: [1, 0.55, 0.3], rim: [1, 0.3, 0.1], accent: [1, 0.35, 0.05],
            sky: [0.012, 0.004, 0.002], particles: .embers,
            fog: { $0.density = 0.045; $0.heightFalloff = 0.1; $0.anisotropy = 0.5; $0.albedo = [0.6, 0.5, 0.45]; $0.noise = 0.7 },
            post: lens.with { $0.bloom = 0.12; $0.grain = 0.025 })),
        ("golem", ShowcaseLook(
            stage: .crypt, size: 2.3, view: 0.4, key: [0.7, 0.85, 1], rim: [0.45, 0.65, 1], accent: [0.3, 1, 0.6],
            sky: [0.006, 0.008, 0.012], particles: .dust,
            fog: { $0.density = 0.045; $0.heightFalloff = 0.08; $0.anisotropy = 0.75; $0.albedo = [0.75, 0.85, 0.8] },
            post: lens.with { $0.vignette = 0.45; $0.grain = 0.025 })),
        ("female warrior", ShowcaseLook(
            stage: .forge, key: [1, 0.8, 0.55], rim: [1, 0.55, 0.2], accent: [1, 0.45, 0.1], sky: [0.01, 0.006, 0.003],
            particles: .embers,
            fog: { $0.density = 0.04; $0.anisotropy = 0.55; $0.albedo = [0.75, 0.65, 0.55] },
            post: lens.with { $0.bloom = 0.09 })),
        ("owl", ShowcaseLook(
            stage: .workshop, size: 1.1, spin: 0.1, key: [1, 0.75, 0.45], rim: [0.5, 0.65, 1], accent: [1, 0.6, 0.25],
            sky: [0.03, 0.025, 0.03], particles: .dust,
            fog: { $0.density = 0.03; $0.anisotropy = 0.75; $0.albedo = [0.9, 0.82, 0.72] },
            post: lens.with { $0.aperture = 8 })),
        ("submarine", ShowcaseLook(
            stage: .underwater, size: 4, spin: 0, view: 0.7, key: [0.6, 0.95, 1], rim: [0.3, 0.7, 1], accent: [0.2, 0.8, 0.9],
            sky: [0.01, 0.04, 0.06], particles: .bubbles,
            fog: {
                $0.density = 0.07; $0.heightFalloff = 0.04; $0.baseHeight = 0; $0.anisotropy = 0.75; $0.ambient = 0.6
                $0.albedo = [0.35, 0.75, 0.85]; $0.noise = 0.6; $0.noiseScale = 6; $0.wind = [0.25, 0.02, 0.05]
                $0.maxDistance = 25; $0.haze = 1
            },
            post: lens.with { $0.aperture = 4; $0.aberration = 0.002 })),
        ("laboratory", ShowcaseLook(
            stage: .workshop, size: 2.2, spin: 0, view: 0.35, key: [1, 0.85, 0.6], rim: [0.75, 0.85, 1], accent: [0.3, 1, 0.4],
            sky: [0.02, 0.025, 0.03], particles: .dust,
            fog: { $0.density = 0.03; $0.anisotropy = 0.7; $0.albedo = [0.95, 0.9, 0.82] },
            post: lens.with { $0.aperture = 5 })),
        ("harpy", ShowcaseLook(
            stage: .crypt, size: 2.2, key: [1, 0.75, 0.5], rim: [1, 0.55, 0.3], accent: [1, 0.6, 0.3], sky: [0.014, 0.01, 0.008],
            particles: .dust,
            fog: { $0.density = 0.04; $0.heightFalloff = 0.08; $0.anisotropy = 0.75; $0.albedo = [1, 0.9, 0.8] },
            post: lens.with { $0.bloom = 0.08 })),
    ]

    /// The look of the model `name` names (`SceneSettings.showcase`; "" = the first model), or the studio's.
    static func look(for name: String) -> ShowcaseLook {
        guard let file = Scene.showcaseFile(name) else { return ShowcaseLook() }
        return look(forFile: file)
    }

    static func look(forFile url: URL) -> ShowcaseLook {
        let name = Scene.showcaseKey(url.lastPathComponent)
        return looks.first { name.contains($0.match) }?.look ?? ShowcaseLook()
    }
}

extension PostSettings {
    /// A changed copy.
    func with(_ change: (inout PostSettings) -> Void) -> PostSettings { var p = self; change(&p); return p }
}

extension Scene {
    /// A file or setting name as the showcase compares them: lower case, underscores as spaces.
    static func showcaseKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    /// The model the showcase shows for `name` (`SceneSettings.showcase`): the first of `galleryFiles()` whose name
    /// contains it, without regard to case ("" = the first one). nil if there is none.
    static func showcaseFile(_ name: String) -> URL? {
        let files = galleryFiles(), key = showcaseKey(name).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? files.first : files.first { showcaseKey($0.lastPathComponent).contains(key) }
    }

    /// A model's name for the panel and for `SceneSettings.showcase`: its file name without the extensions and the
    /// " 3d model" the downloads came with ("steampunk owl", "Winged Harpy Warrior").
    static func showcaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        while let dot = name.lastIndex(of: "."), ["glb", "gltf"].contains(name[name.index(after: dot)...].lowercased()) {
            name = String(name[..<dot])
        }
        if name.lowercased().hasSuffix(" 3d model") { name = String(name.dropLast(" 3d model".count)) }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}
