import XCTest
import simd
@testable import MetalRenderer

/// The settings table (SettingsTable.swift) drives Copy as Env, the env parser and the panel. These check that the
/// three agree: what is exported reads back as the same settings, and no setting is missing from the table.
final class SettingsTableTests: XCTestCase {
    private let defaults = RenderSettings()

    // MARK: - Helpers

    /// "A=1 B="x=1,y=2" C='a b'" as a shell would split it.
    private func variables(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var token = "", quote: Character?
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == q { quote = nil } else { token.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "\\", text.index(after: i) < text.endIndex {   // \' between two quoted parts
                i = text.index(after: i)
                token.append(text[i])
            } else if c == " " {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(c)
            }
            i = text.index(after: i)
        }
        if !token.isEmpty { tokens.append(token) }
        for t in tokens {
            let kv = t.split(separator: "=", maxSplits: 1).map(String.init)
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    /// The settings a fresh launch would have with the variables that `export` wrote for `s`.
    private func roundTrip(_ s: RenderSettings) -> (settings: RenderSettings, env: String) {
        let env = SettingsEnv.export(s, defaults: defaults)
        var r = defaults
        SettingsEnv.applyAll(to: &r, defaults: defaults, from: variables(env))
        return (r, env)
    }

    private func leaves(_ s: RenderSettings) -> [String: String] {
        var out: [String: String] = [:]
        func flatten(_ any: Any, _ path: String) {
            if let d = any as? [String: Any] { for (k, v) in d { flatten(v, path.isEmpty ? k : path + "." + k) } }
            else if let a = any as? [Any] { for (i, v) in a.enumerated() { flatten(v, path + "[\(i)]") } }
            else { out[path] = "\(any)" }
        }
        flatten(try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s)), "")
        return out
    }

    private func difference(_ a: RenderSettings, _ b: RenderSettings) -> String {
        let la = leaves(a), lb = leaves(b)
        return Set(la.keys).union(lb.keys).sorted().filter { la[$0] != lb[$0] }
            .map { "\($0): \(la[$0] ?? "nil") != \(lb[$0] ?? "nil")" }.joined(separator: "; ")
    }

    /// Every leaf of the settings (as JSON paths) with a changed value: numbers nudged, switches flipped.
    private func singleChanges() -> [(path: String, settings: RenderSettings)] {
        var floats = Set<String>()
        func scan(_ value: Any, _ path: String) {
            if value is Float || value is CGFloat || value is SIMD3<Float> { floats.insert(path); return }
            for child in Mirror(reflecting: value).children { if let l = child.label { scan(child.value, path.isEmpty ? l : path + "." + l) } }
        }
        scan(defaults, "")
        let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
        var out: [(String, RenderSettings)] = []
        func decode(_ root: Any) -> RenderSettings? {
            try? JSONDecoder().decode(RenderSettings.self, from: JSONSerialization.data(withJSONObject: root))
        }
        /// `root` with the leaf at `path` replaced.
        func replacing(_ node: Any, _ path: [String], with value: Any) -> Any {
            guard let key = path.first else { return value }
            if var d = node as? [String: Any] { d[key] = replacing(d[key]!, Array(path.dropFirst()), with: value); return d }
            var a = node as! [Any]
            a[Int(key)!] = replacing(a[Int(key)!], Array(path.dropFirst()), with: value)
            return a
        }
        func visit(_ node: Any, _ path: [String], _ name: String) {
            if let d = node as? [String: Any] {
                for k in d.keys.sorted() { visit(d[k]!, path + [k], name.isEmpty ? k : name + "." + k) }
            } else if let a = node as? [Any] {
                for i in a.indices { visit(a[i], path + ["\(i)"], name) }
            } else if let n = node as? NSNumber {
                let candidates: [Any]
                if CFGetTypeID(n) == CFBooleanGetTypeID() { candidates = [!n.boolValue] }
                else if floats.contains(name) { candidates = [Double(Float(n.doubleValue * 1.5 + 0.25))] }
                else { candidates = [n.intValue + 1, n.intValue - 1] }   // an enum's last case has no next one
                for c in candidates {
                    if let s = decode(replacing(json, path, with: c)) { out.append((path.joined(separator: "."), s)); return }
                }
                XCTFail("\(name): no changed value decodes")
            }
        }
        visit(json, [], "")
        return out
    }

    // MARK: - Tests

    func testEnvNamesAreUnique() {
        var seen = Set<String>()
        for env in SettingsTable.named {
            let name = env.variable.rawValue + "/" + (env.key ?? "")
            XCTAssertTrue(seen.insert(name).inserted, "\(name) names two settings")
            XCTAssertEqual(env.variable.isList, env.key != nil, name)
        }
    }

    func testDefaultsExportOnlyTheScene() {
        XCTAssertEqual(SettingsEnv.export(defaults, defaults: defaults), "METALRENDERER_SCENE=\"cornell\"")
    }

    /// Each setting on its own: a change shows up in the export and reads back as the same settings. A setting added
    /// to RenderSettings without a line in the table fails here.
    func testEverySettingRoundTrips() {
        // Session state, like the camera; and what the renderer sets by the time of day.
        let unexported: Set<String> = ["virtualGeometry.freeze", "scene.worldLit", "scene.plantCatalog", "scene.plants.mutants",
                                         "scene.plants.compare"]
        let changes = singleChanges()
        XCTAssertGreaterThan(changes.count, 120)
        for (path, s) in changes where !unexported.contains(path) {
            let (r, env) = roundTrip(s)
            XCTAssertNotEqual(env, SettingsEnv.export(defaults, defaults: defaults), "\(path): a change isn't exported")
            XCTAssertEqual(r, s, "\(path): \(env) reads back differently: \(difference(s, r))")
        }
    }

    /// Whole settings, as the panel's controls can produce them: every control moved to a random place.
    func testRandomPanelStatesRoundTrip() {
        var seed: UInt64 = 42
        func random() -> Double {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        func pick<T>(_ options: [T]) -> T { options[min(Int(random() * Double(options.count)), options.count - 1)] }
        for round in 0..<200 {
            var s = defaults
            s.scene.kind = pick(SceneKind.allCases)
            s.applySceneDefaults(from: defaults)
            for spec in SettingsTable.sections.flatMap(\.rows) where random() < 0.6 {
                switch spec.control {
                case .slider(let m): m.move(&s, m.range.lowerBound + random() * (m.range.upperBound - m.range.lowerBound))
                case .checkbox(_, let set): set(&s, random() < 0.5)
                case .popup(let titles, _, let select): select(&s, min(Int(random() * Double(titles.count)), titles.count - 1))
                case .custom(.lightRays): s.manyLightRays = pick([1, 2])
                case .custom(.upscale): s.upscaleFactor = pick([0, 1.5, 2, 3])
                case .custom(.skyMode):
                    s.sky.mode = pick(SkyMode.allCases)
                    s.sky.imagePath = s.sky.mode == .image ? "/tmp/it's a sky \(round).hdr" : nil
                case .custom(.fogAlbedo): s.fog.albedo = [Float(Int(random() * 100)) / 100, 0.5, 1]
                case .custom, nil: break
                }
            }
            s.virtualGeometry.freeze = false   // not exported
            // A market with the default light count reads as "the market's own count" (applySceneDefaults).
            if s.scene.kind == .market && s.scene.lights == SceneSettings().lights { s.scene.lights = 64 }
            let (r, env) = roundTrip(s)
            XCTAssertEqual(r, s, "round \(round): \(env) reads back differently: \(difference(s, r))")
        }
    }

    func testThePhysicsSceneHasItsOwnLook() {
        var s = defaults
        s.scene.kind = .physics
        s.applySceneDefaults(from: defaults)
        XCTAssertFalse(s.giEnabled)
        XCTAssertFalse(s.specular)
        XCTAssertEqual(s.renderScale, RenderSettings.physicsScale)
        // Leaving it brings the defaults back...
        s.scene.kind = .cornell
        s.applySceneDefaults(from: defaults)
        XCTAssertEqual(s.giEnabled, defaults.giEnabled)
        XCTAssertEqual(s.specular, defaults.specular)
        XCTAssertEqual(s.renderScale, defaults.renderScale)
        // ...but not over a look chosen elsewhere.
        s.giEnabled = false
        s.renderScale = 1
        s.scene.kind = .sun
        s.applySceneDefaults(from: defaults)
        XCTAssertFalse(s.giEnabled)
        XCTAssertEqual(s.renderScale, 1)
        // Starting in it from the environment.
        var started = defaults
        SettingsEnv.applyAll(to: &started, defaults: defaults, from: ["METALRENDERER_SCENE": "physics"])
        XCTAssertEqual(started.scene.kind, .physics)
        XCTAssertFalse(started.giEnabled)
        XCTAssertEqual(started.renderScale, RenderSettings.physicsScale)
        // The ragdoll scene shares it, and its count is a scene key.
        var ragdolls = defaults
        SettingsEnv.applyAll(to: &ragdolls, defaults: defaults, from: ["METALRENDERER_SCENE": "ragdolls,ragdolls=40"])
        XCTAssertEqual(ragdolls.scene.kind, .ragdolls)
        XCTAssertEqual(ragdolls.scene.physics.ragdolls, 40)
        XCTAssertFalse(ragdolls.specular)
        XCTAssertEqual(ragdolls.renderScale, RenderSettings.physicsScale)
        // The hair scene too.
        var hair = defaults
        SettingsEnv.applyAll(to: &hair, defaults: defaults, from: ["METALRENDERER_SCENE": "hair,hair=6,fur=3"])
        XCTAssertEqual(hair.scene.kind, .hair)
        XCTAssertEqual(hair.scene.physics.hair, 6)
        XCTAssertEqual(hair.scene.physics.furBodies, 3)
        XCTAssertEqual(hair.renderScale, RenderSettings.physicsScale)
        // The soft body scene shares the look; its counts are scene keys.
        var soft = defaults
        SettingsEnv.applyAll(to: &soft, defaults: defaults, from: ["METALRENDERER_SCENE": "softbodies,soft=8,cells=5"])
        XCTAssertEqual(soft.scene.kind, .softBodies)
        XCTAssertEqual(soft.scene.physics.softBodies, 8)
        XCTAssertEqual(soft.scene.physics.softCells, 5)
        XCTAssertFalse(soft.giEnabled)
        XCTAssertEqual(soft.renderScale, RenderSettings.physicsScale)
    }

    func testBadInputIsSkipped() {
        var s = defaults
        SettingsEnv.applyAll(to: &s, defaults: defaults, from: [
            "METALRENDERER_GI": "mode=nonsense,bounces=abc,nokey=1,blue",
            "METALRENDERER_FOG_SET": "albedo=1:2,zzz=3",
            "METALRENDERER_DIRECT": "sometimes",
        ])
        XCTAssertEqual(s, defaults)
    }

    /// Settings saved before the custom tracer went still carry `"rayTracer"`: the removed key is ignored and the
    /// rest loads (SettingsStore lays the saved JSON over the defaults).
    func testRemovedKeysDoNotResetSavedSettings() throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any])
        saved["rayTracer"] = 1
        saved["api"] = RenderAPI.metal4.rawValue
        saved["bounces"] = defaults.bounces + 1
        let store = UserDefaults.standard, key = "renderSettings"
        let before = store.data(forKey: key)
        defer { store.set(before, forKey: key) }
        store.set(try JSONSerialization.data(withJSONObject: saved), forKey: key)
        let s = try XCTUnwrap(SettingsStore.load(over: defaults))
        XCTAssertEqual(s.api, .metal4)
        XCTAssertEqual(s.bounces, defaults.bounces + 1)
    }

    func testLumenIsRead() {
        var s = defaults
        SettingsEnv.applyAll(to: &s, defaults: defaults, from: [
            "METALRENDERER_GI": "mode=lumen",
            "METALRENDERER_LUMEN": "spacing=4,history=8,filter=0",
        ])
        XCTAssertEqual(s.giMode, .lumen)
        XCTAssertEqual(s.lumen.probeSpacing, 4)
        XCTAssertEqual(s.lumen.history, 8)
        XCTAssertFalse(s.lumen.filter)
    }

    func testListsAreRead() {
        var s = defaults
        SettingsEnv.applyAll(to: &s, defaults: defaults, from: [
            "METALRENDERER_SCENE": "market,model=/tmp/a.glb",
            "METALRENDERER_GI": "mode=restir, bounces = 3.7,scale=0.75",
            "METALRENDERER_FOG_SET": "on=0,wind=1:0:2",
            "METALRENDERER_VIEW": "tonemap=AgX,paused=1",
            "METALRENDERER_API": "metal4",
        ])
        XCTAssertEqual(s.scene.kind, .market)
        XCTAssertEqual(s.scene.lights, SceneSettings.marketLights)
        XCTAssertEqual(s.scene.extraModels.map(\.path), ["/tmp/a.glb"])
        XCTAssertEqual(s.giMode, .restirGI)
        XCTAssertEqual(s.bounces, 3)
        XCTAssertEqual(s.renderScale, 0.75)
        XCTAssertFalse(s.fog.enabled)
        XCTAssertEqual(s.fog.wind, SIMD3<Float>(1, 0, 2))
        XCTAssertEqual(s.toneMap, .agx)
        XCTAssertTrue(s.paused)
        XCTAssertEqual(s.api, .metal4)
        // Benchmarks choose the view and the pause themselves.
        var b = defaults
        SettingsEnv.apply(.view, to: &b, from: ["METALRENDERER_VIEW": "paused=1,view=3,fov=70"])
        XCTAssertFalse(b.paused)
        XCTAssertEqual(b.viewMode, 0)
        XCTAssertEqual(b.fovDegrees, 70)
    }

    /// Far plants are traced as their triangles unless asked for their voxels, which are slower wherever
    /// they were measured.
    func testFarPlantsAreTrianglesUnlessAskedFor() {
        XCTAssertFalse(defaults.scene.voxelBoxes)
        var s = defaults
        SettingsEnv.applyAll(to: &s, defaults: defaults, from: ["METALRENDERER_SCENE": "forest,voxels=1"])
        XCTAssertTrue(s.scene.voxelBoxes)
    }

    /// A slider shows the value it just set: its position after a move is inside the slider and stays put when the
    /// slider is moved to it again (to a tolerance: the fog's wind heading is derived from a vector).
    func testSlidersShowWhatTheySet() {
        for spec in SettingsTable.sections.flatMap(\.rows) {
            guard case .slider(let m) = spec.control else { continue }
            let span = m.range.upperBound - m.range.lowerBound
            var s = defaults
            for t in [0.0, 0.31, 0.5, 0.77, 1.0] {
                m.move(&s, m.range.lowerBound + t * span)
                let shown = m.position(s)
                XCTAssertTrue(m.range.contains(shown), "\(spec.title): \(shown) is outside the slider")
                m.move(&s, shown)
                XCTAssertEqual(m.position(s), shown, accuracy: 1e-4 * span, "\(spec.title): the position it shows moves it again")
            }
        }
    }
}
