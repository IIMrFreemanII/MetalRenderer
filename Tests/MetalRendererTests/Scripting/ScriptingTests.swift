import XCTest
import simd
@testable import EngineCore
@testable import Game
@testable import MetalRenderer

/// Swift scripts (Scripting/): the file a script is made into (both forms, imports, its lines kept), what the
/// compiler is told (the package's name) and shows (errors, not warnings), and scene-file edits that only move.
final class ScriptingTests: XCTestCase {
    private func lines(_ s: String) -> [String] { s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

    func testShortFormRunsInARenderClosure() {
        let text = "let n = 3\nimport Plants\nprint(n)"
        XCTAssertFalse(ScriptSource.isFullForm(text))
        let out = ScriptSource.generate(text, path: "/tmp/a \"b\".swift")
        let all = lines(out)
        XCTAssertTrue(all.contains("import Plants"))
        XCTAssertEqual(all.filter { $0 == "import Plants" }.count, 1)
        XCTAssertTrue(all.contains("import MetalRenderer"))
        XCTAssertTrue(out.contains("func run(_ run: ScriptRun) throws { try run.render { (renderer: Renderer) throws -> Void in"))
        // The script's lines follow the marker in order, its import line left empty: line k of the file is line k.
        let marker = all.firstIndex { $0.hasPrefix("#sourceLocation(file: \"/tmp/a \\\"b\\\".swift\", line: 1)") }!
        XCTAssertEqual(Array(all[(marker + 1)...(marker + 3)]), ["let n = 3", "", "print(n)"])
        XCTAssertTrue(out.contains("@_cdecl(\"\(ScriptSource.entry)\")"))
    }

    func testFullFormKeepsItsRun() {
        let text = "import Buildings\n\nfunc run(_ run: ScriptRun) {\n    print(1)\n}\n"
        XCTAssertTrue(ScriptSource.isFullForm(text))
        let out = ScriptSource.generate(text, path: "/s.swift")
        XCTAssertFalse(out.contains("run.render { (renderer: Renderer)"))
        XCTAssertTrue(out.contains("func run(_ run: ScriptRun) {\n    print(1)"))
        XCTAssertTrue(lines(out).contains("import Buildings"))
        XCTAssertFalse(ScriptSource.isFullForm("let f = { run(1) }\nfunc running() {}"))
        XCTAssertTrue(ScriptSource.isFullForm("  func run (_ r: ScriptRun) throws {}"))
    }

    func testImportLines() {
        XCTAssertEqual(ScriptSource.importedModule("import Plants"), "Plants")
        XCTAssertEqual(ScriptSource.importedModule("  @testable import Physics"), "Physics")
        XCTAssertEqual(ScriptSource.importedModule("import struct Landscape.TerrainDocument"), "Landscape")
        XCTAssertNil(ScriptSource.importedModule("let important = 1"))
        XCTAssertNil(ScriptSource.importedModule("// import Plants"))
    }

    func testThePackagesName() {
        let pif = "{ \"buildSettings\" : { \"SWIFT_PACKAGE_NAME\" : \"metalgi\", \"OTHER\" : 1 } }"
        XCTAssertEqual(ScriptCompiler.packageName(pif: pif), "metalgi")
        XCTAssertNil(ScriptCompiler.packageName(pif: "{}"))
        XCTAssertEqual(ScriptCompiler.packageName(folder: "reverent-poitras-c1fdd2"), "reverent_poitras_c1fdd2")
        XCTAssertEqual(ScriptCompiler.packageName(folder: "MetalGI"), "metalgi")
    }

    func testErrorsWithoutWarnings() {
        let output = """
        /s.swift:2:5: warning: initialization of variable 'x' was never used
        2 | let x = 1
          |     `- warning: never used
        /s.swift:3:1: error: cannot find 'foo' in scope
        3 | foo()
          | `- error: cannot find 'foo' in scope
        """
        let errors = ScriptCompiler.errors(in: output)
        XCTAssertTrue(errors.contains("/s.swift:3:1: error: cannot find 'foo' in scope"))
        XCTAssertTrue(errors.contains("3 | foo()"))
        XCTAssertFalse(errors.contains("warning"))
    }

    func testMovesAreToldFromChanges() {
        let a = SceneFile(objects: [SceneFile.Object(asset: "prefab:box", name: "A"), SceneFile.Object(asset: "prefab:ball", name: "B")])
        var moved = a
        moved.objects[1].position = [1, 2, 3]
        moved.objects[0].scale = [2, 2, 2]
        XCTAssertTrue(moved.onlyMoves(from: a))
        XCTAssertFalse(moved.matches(a))
        XCTAssertTrue(a.matches(a))
        var recoloured = a
        recoloured.objects[0].material = "red"
        XCTAssertFalse(recoloured.onlyMoves(from: a))
        var more = a
        more.objects.append(SceneFile.Object(asset: "prefab:quad", name: "C"))
        XCTAssertFalse(more.onlyMoves(from: a))
        var lit = moved
        lit.lights.append(SceneFile.Light(kind: .sphere, name: "L"))
        XCTAssertFalse(lit.onlyMoves(from: a))
    }

    // MARK: - Typed commands (SceneCommand)

    func testCommandsReadFromJSON() throws {
        let place = try XCTUnwrap(SceneCommand.decode(["place": ["asset": "prefab:box", "name": "Crate", "position": [1, 0.5, -2],
                                                                  "rotation": [0, 90, 0], "scale": 2, "material": "wood", "parent": "Table"]]))
        guard case .success(.place(let o, let parent)) = place else { return XCTFail("\(place)") }
        XCTAssertEqual(o.asset, "prefab:box")
        XCTAssertEqual(o.position, [1, 0.5, -2])
        XCTAssertEqual(o.scale, [2, 2, 2])
        XCTAssertEqual(o.material, "wood")
        XCTAssertEqual(parent, "Table")
        // 90 degrees about y: x goes to -z.
        let turned = o.rotation.act([1, 0, 0])
        XCTAssertEqual(turned.z, -1, accuracy: 1e-5)

        guard case .success(.move(let name, let position, nil, nil))? = SceneCommand.decode(["move": ["name": "Crate", "position": [0, 1, 0]]]) else {
            return XCTFail("move")
        }
        XCTAssertEqual(name, "Crate")
        XCTAssertEqual(position, [0, 1, 0])
        guard case .success(.remove(let names, let prefix))? = SceneCommand.decode(["remove": ["name": "A", "prefix": "Grid "]]) else {
            return XCTFail("remove")
        }
        XCTAssertEqual(names, ["A"])
        XCTAssertEqual(prefix, "Grid ")
        guard case .success(.camera(nil, let lookAt, nil, nil, let fov))? = SceneCommand.decode(["camera": ["lookAt": [0, 0, 0], "fov": 50]]) else {
            return XCTFail("camera")
        }
        XCTAssertEqual(lookAt, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(fov, 50)
        XCTAssertNil(SceneCommand.decode(["state": true]))
        for bad: [String: Any] in [["place": ["name": "no asset"]], ["move": ["position": [1, 2, 3]]], ["remove": [:]],
                                   ["place": ["asset": "prefab:box", "position": [1, 2]]], ["camera": ["yaw": 1, "lookAt": "here"]]] {
            guard case .failure? = SceneCommand.decode(bad) else { return XCTFail("\(bad) should fail") }
        }
    }

    func testCameraAnglesLookAtTheTarget() throws {
        let eye = SIMD3<Float>(3, 4, 5), target = SIMD3<Float>(-1, 0.5, 2)
        let (yaw, pitch) = try XCTUnwrap(SceneCommand.angles(from: eye, to: target))
        let camera = Camera(position: eye, yaw: yaw, pitch: pitch)
        let wanted = simd_normalize(target - eye)
        XCTAssertEqual(simd_distance(camera.forward, wanted), 0, accuracy: 1e-5)
        XCTAssertNil(SceneCommand.angles(from: eye, to: eye))
    }

    func testPlacingReplacesByNameAndRemovingTakesChildren() {
        var file = SceneFile()
        XCTAssertEqual(file.upsert(SceneFile.Object(asset: "prefab:box", name: "Table")).replaced, false)
        file.objects.append(SceneFile.Object(asset: "prefab:ball", name: "Lamp", parent: 0))
        file.objects.append(SceneFile.Object(asset: "prefab:box", name: "Chair"))
        file.objects.append(SceneFile.Object(asset: "prefab:quad", name: "Cushion", parent: 2))
        let (k, replaced) = file.upsert(SceneFile.Object(asset: "prefab:box", name: "Table", position: [1, 0, 0]))
        XCTAssertEqual(k, 0)
        XCTAssertTrue(replaced)
        XCTAssertEqual(file.objects.count, 4)
        XCTAssertEqual(file.removeObjects([0]), 2)   // the table and its lamp
        XCTAssertEqual(file.objects.map(\.name), ["Chair", "Cushion"])
        XCTAssertEqual(file.objects[1].parent, 0)    // renumbered
        XCTAssertEqual(file.removeObjects([]), 0)
    }

    func testTheStageNamesItsMaterials() {
        GameScenes.register()
        XCTAssertEqual(SceneRegistry.kind(named: "stage"), .stage)
        let names = Set(Scene.stageColours.map(\.0))
        XCTAssertTrue(names.isSuperset(of: ["red", "white", "wood"]))
    }
}
