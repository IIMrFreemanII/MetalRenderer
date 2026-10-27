import XCTest
import simd
@testable import EngineCore
@testable import MetalRenderer
@testable import Modeling
@testable import Procedural

/// Procedural assets: references and their values, cooking into a scene's mesh, the cooked-mesh cache, instances
/// placed by points. PROCEDURAL_DEMO=1 also writes the demo assets (Assets/Procedural) and the Procedural scene's file.
final class ProceduralAssetTests: XCTestCase {
    private let none = ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 })

    func testReferences() {
        let r = ProcAssetReference("fence?height=2.5&color=1,0.5,0&name=a%20b")
        XCTAssertEqual(r.slug, "fence")
        XCTAssertEqual(r.values["height"], "2.5")
        XCTAssertEqual(r.values["name"], "a b")
        XCTAssertEqual(ProcAssetReference(String(r.asset.dropFirst(5))), r)
        XCTAssertEqual(ProcAssetReference(slug: "rock").asset, "proc:rock")
    }

    /// A box whose height and seed are promoted.
    private func boxAsset() -> ProcAsset {
        var g = ProcGraph()
        let box = g.add(.box)
        let noise = g.add(.attribnoise, params: ["amp": .float(0)])
        g.link(box, to: noise)
        g.setDisplay(noise)
        g.interface = [PromotedParam("height", value: .vec3([1, 1, 1]), targets: [.init(node: "box1", param: "size")]),
                       PromotedParam("seed", value: .int(0), targets: [.init(node: "attribnoise1", param: "seed")])]
        return ProcAsset(name: "Box", graph: g, materials: [MaterialSlot(name: "Material", baseColor: [1, 0, 0, 1])])
    }

    /// `proc:<slug>?frame=<n>`: the frame its expressions read; each frame's cook is a mesh of its own, copies share it.
    func testPlacedFrame() throws {
        var g = ProcGraph()
        let box = g.add(.box)
        g.nodes[g.index(of: box)!].expressions["sizex"] = "$F"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proc-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("METALRENDERER_PROCEDURAL", folder.path, 1)
        defer { unsetenv("METALRENDERER_PROCEDURAL"); try? FileManager.default.removeItem(at: folder) }
        try ProcStore.write(ProcAsset(name: "Bar", graph: g), slug: "bar")
        let scene = Scene()
        let instances = scene.instances.count
        for f in ["1", "3", "3"] { scene.addProcAsset("bar?frame=\(f)", transform: matrix_identity_float4x4) }
        XCTAssertEqual(scene.proceduralMeshes.count, 2)
        XCTAssertEqual(scene.instances.count - instances, 3)
        let widths = scene.proceduralMeshes.values.map { scene.meshBounds[$0.mesh] }.map { $0.1.x - $0.0.x }.sorted()
        XCTAssertEqual(widths[0], 1, accuracy: 1e-5)
        XCTAssertEqual(widths[1], 3, accuracy: 1e-5)
    }

    func testCookWithValues() throws {
        let a = boxAsset()
        let values = a.values(["height": "1,3,1", "seed": "4", "unknown": "1"])
        XCTAssertEqual(values["height"], .vec3([1, 3, 1]))
        XCTAssertEqual(values["seed"], .int(4))
        XCTAssertNil(values["unknown"])
        let c = try a.cook(values, environment: none).get()
        XCTAssertEqual(c.rendered.triangleCount, 12)
        XCTAssertEqual(c.rendered.positions.map(\.y).max() ?? 0, 1.5, accuracy: 1e-5)
        XCTAssertEqual(c.rendered.materials.first?.baseColor, [1, 0, 0, 1])
        // Cached: the second time from the file, the same mesh; other values another file.
        let first = try a.cached(values, environment: none).get()
        let again = try a.cached(values, environment: none).get()
        XCTAssertEqual(first.rendered.positions, again.rendered.positions)
        XCTAssertNotEqual(a.cacheName(values, environment: none), a.cacheName([:], environment: none))
        XCTAssertEqual(a.cacheName(values, environment: none), a.cacheName(values, environment: none))
    }

    func testInstancesFromPoints() throws {
        var g = ProcGraph()
        let line = g.add(.line, params: ["points": .int(3), "dir": .vec3([1, 0, 0]), "dist": .float(4)])
        let tag = g.add(.attribcreate, params: ["name": .string("instance"), "type": .string("string"), "string": .string("mesh:rock")])
        let ps = g.add(.attribcreate, params: ["name": .string("pscale"), "value": .vec4([2, 0, 0, 0])])
        g.link(line, to: tag); g.link(tag, to: ps)
        g.setDisplay(ps)
        let c = try ProcAsset(name: "Row", graph: g).cook([:], environment: none).get()
        XCTAssertEqual(c.instances.count, 3)
        XCTAssertEqual(c.instances[2].asset, "mesh:rock")
        XCTAssertEqual(c.instances[2].transform.columns.3.x, 4, accuracy: 1e-5)
        XCTAssertEqual(c.instances[0].transform.columns.0.x, 2, accuracy: 1e-5)
        // Through the cache too.
        let cached = try ProcAsset(name: "Row", graph: g).cached([:], environment: none).get()
        XCTAssertEqual(cached.instances.map(\.asset), c.instances.map(\.asset))
    }

    func testStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proc-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ProcStore.write(boxAsset(), slug: "box", in: folder)
        XCTAssertEqual(ProcStore.list(in: folder), ["box"])
        XCTAssertEqual(ProcStore.read("box", in: folder), boxAsset())
    }

    // MARK: The demo

    /// The demo assets and the Procedural scene's file, written into the package (PROCEDURAL_DEMO=1).
    func testWriteDemo() throws {
        guard ProcessInfo.processInfo.environment["PROCEDURAL_DEMO"] == "1" else { throw XCTSkip("PROCEDURAL_DEMO not set") }
        let folder = SourceTree.packageRoot.appendingPathComponent("Assets/Procedural")
        for (slug, asset) in ProceduralDemo.assets() {
            try ProcStore.write(asset, slug: slug, in: folder)
            // Each cooks.
            let c = try asset.cook([:], environment: .assets).get()
            XCTAssertGreaterThan(c.rendered.triangleCount + c.instances.count, 0, slug)
            let badNormals = c.rendered.normals.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) || simd_length($0) < 0.5 }.count
            XCTAssertEqual(badNormals, 0, "\(slug): normals that aren't unit")
        }
        try ProceduralDemo.sceneFile().write(to: SceneFile.url(for: SceneKind("procedural")))
    }
}

/// The demo's assets, made as a user would in the Procedural workspace.
enum ProceduralDemo {
    static func assets() -> [(String, ProcAsset)] {
        var out: [(String, ProcAsset)] = []

        // A rock: an icosphere pushed about by noise along its normals, squashed; its seed and size promoted.
        var rock = ProcGraph()
        let s = rock.add(.sphere, params: ["type": .string("ico"), "freq": .int(3), "rad": .vec3([1, 0.7, 1])], name: "shape")
        let n = rock.add(.attribnoise, params: ["op": .string("alongnormal"), "amp": .float(0.35), "freq": .float(1.3), "octaves": .int(4)], name: "bumps")
        let sz = rock.add(.transform, params: ["scale": .float(0.6)], name: "size")
        rock.link(s, to: n); rock.link(n, to: sz)
        rock.setDisplay(sz)
        rock.interface = [PromotedParam("seed", value: .int(0), span: 0...100, targets: [.init(node: "bumps", param: "seed")]),
                          PromotedParam("size", value: .float(0.6), span: 0.1...3, targets: [.init(node: "size", param: "scale")])]
        out.append(("rock", ProcAsset(name: "Rock", graph: rock, materials: [MaterialSlot(name: "Material", baseColor: [0.3, 0.28, 0.25, 1], roughness: 0.8)])))

        // A rock field: points scattered on a patch, relaxed, each a rock (instanced) turned and sized at random.
        var field = ProcGraph()
        let grid = field.add(.grid, params: ["size": .vec2([14, 8]), "rows": .int(4), "cols": .int(6)], name: "ground")
        let sc = field.add(.scatter, params: ["npts": .int(40), "seed": .int(2), "relaxiterations": .int(3), "attribs": .string("")], name: "spots")
        let ps = field.add(.attribrandomize, params: ["name": .string("pscale"), "dims": .int(1), "min": .vec4([0.3, 0, 0, 0]), "max": .vec4([1.2, 0, 0, 0]), "seed": .int(5)])
        let ori = field.add(.attribrandomize, params: ["name": .string("orient"), "dims": .int(4), "min": .vec4([-1, -1, -1, -1]), "max": .vec4([1, 1, 1, 1]), "seed": .int(9)])
        let inst = field.add(.attribcreate, params: ["name": .string("instance"), "type": .string("string"), "string": .string("proc:rock")])
        field.link(grid, to: sc); field.link(sc, to: ps); field.link(ps, to: ori); field.link(ori, to: inst)
        field.setDisplay(inst)
        field.interface = [PromotedParam("count", value: .int(40), span: 0...400, targets: [.init(node: "spots", param: "npts")]),
                           PromotedParam("seed", value: .int(2), span: 0...100, targets: [.init(node: "spots", param: "seed")])]
        out.append(("rock-field", ProcAsset(name: "Rock Field", graph: field)))

        // A fence along a curve: posts every 1.5 m (boxes copied to the resampled curve), two rails swept along it.
        var fence = ProcGraph()
        let curve = fence.add(.curve, params: ["points": .points([[-6, 0, 0], [-2, 0, -1.5], [2, 0, -1], [6, 0, 1]]), "type": .string("smooth")], name: "path")
        let rs = fence.add(.resample, params: ["length": .float(1.5)], name: "spacing")
        let post = fence.add(.box, params: ["size": .vec3([0.12, 1.2, 0.12]), "t": .vec3([0, 0.6, 0])], name: "post")
        let posts = fence.add(.copytopoints, name: "posts")
        let up1 = fence.add(.transform, params: ["t": .vec3([0, 0.95, 0])])
        let up2 = fence.add(.transform, params: ["t": .vec3([0, 0.5, 0])])
        let rails = fence.add(.merge)
        let sw = fence.add(.sweep, params: ["surfaceshape": .string("square"), "width": .float(0.07)], name: "rails")
        let all = fence.add(.merge, name: "fence")
        let wood = fence.add(.attribcreate, params: ["name": .string("material"), "class": .string("primitive"), "type": .string("string"), "string": .string("wood")])
        fence.link(curve, to: rs)
        fence.link(post, to: posts, 0); fence.link(rs, to: posts, 1)
        fence.link(curve, to: up1); fence.link(curve, to: up2)
        fence.link(up1, to: rails, 0); fence.link(up2, to: rails, 1)
        fence.link(rails, to: sw)
        fence.link(posts, to: all, 0); fence.link(sw, to: all, 1)
        fence.link(all, to: wood)
        fence.setDisplay(wood)
        fence.interface = [PromotedParam("spacing", value: .float(1.5), span: 0.3...5, targets: [.init(node: "spacing", param: "length")])]
        out.append(("fence", ProcAsset(name: "Fence", graph: fence, materials: [MaterialSlot(name: "wood", baseColor: [0.42, 0.27, 0.15, 1], roughness: 0.7)])))

        // A bush: an L-system's branches as wires, thinner each level.
        var bush = ProcGraph()
        let ls = bush.add(.lsystem, params: ["generations": .int(3), "angle": .float(28), "variance": .float(12), "step": .float(0.11)], name: "growth")
        let pw = bush.add(.polywire, params: ["radius": .float(0.025), "divs": .int(5)], name: "branches")
        let bark = bush.add(.attribcreate, params: ["name": .string("material"), "class": .string("primitive"), "type": .string("string"), "string": .string("bark")])
        bush.link(ls, to: pw); bush.link(pw, to: bark)
        bush.setDisplay(bark)
        bush.interface = [PromotedParam("seed", value: .int(0), span: 0...100, targets: [.init(node: "growth", param: "seed")]),
                          PromotedParam("generations", value: .int(3), span: 1...6, targets: [.init(node: "growth", param: "generations")])]
        out.append(("bush", ProcAsset(name: "Bush", graph: bush, materials: [MaterialSlot(name: "bark", baseColor: [0.32, 0.25, 0.16, 1], roughness: 0.8)])))
        return out
    }

    /// The Procedural scene's objects: the rock field, the fence behind it, three bushes of their own seeds, a big rock.
    static func sceneFile() -> SceneFile {
        SceneFile(objects: [
            SceneFile.Object(asset: "proc:rock-field", name: "Rock Field", position: [0, 0, 1]),
            SceneFile.Object(asset: "proc:fence", name: "Fence", position: [0, 0, -4.5]),
            SceneFile.Object(asset: "proc:bush?seed=1", name: "Bush 1", position: [-4, 0, -3]),
            SceneFile.Object(asset: "proc:bush?seed=7", name: "Bush 2", position: [0.5, 0, -3.2]),
            SceneFile.Object(asset: "proc:bush?seed=12", name: "Bush 3", position: [4.5, 0, -2.5]),
            SceneFile.Object(asset: "proc:rock?seed=31&size=1.6", name: "Big Rock", position: [5.5, 0.3, 3]),
        ])
    }
}
