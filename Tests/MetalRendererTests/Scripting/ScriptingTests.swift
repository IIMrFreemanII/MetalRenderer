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

    func testTheStageNamesItsMaterials() {
        GameScenes.register()
        XCTAssertEqual(SceneRegistry.kind(named: "stage"), .stage)
        let names = Set(Scene.stageColours.map(\.0))
        XCTAssertTrue(names.isSuperset(of: ["red", "white", "wood"]))
    }
}
