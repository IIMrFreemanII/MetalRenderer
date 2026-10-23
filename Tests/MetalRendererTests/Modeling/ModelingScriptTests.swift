import AppKit
import Metal
import XCTest
import simd
@testable import Editors
@testable import Modeling

/// The scripted Modeller (ScriptModeller, the socket's `modeller`): its steps as JSON (good ones, and bad ones with
/// errors that say what to send), done as a user's keys and clicks would be, its operators by name, popups, state and
/// pictures. Without an app: no renderer, a Metal device only.
final class ModelingScriptTests: XCTestCase {
    private var modeller: ScriptModeller!

    override func setUpWithError() throws {
        modeller = ScriptModeller(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func steps(_ json: String) throws -> [ModellerStep] {
        try ModellerStep.decode(list: JSONSerialization.jsonObject(with: Data(json.utf8))).get()
    }

    private func failure(_ json: String) -> String {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return "not JSON" }
        if case .failure(let f) = ModellerStep.decode(list: list) { return f.description }
        return ""
    }

    private var faces: Int { (try? modeller.document.objects[0].mesh.faceCount) ?? -1 }

    func testStepsDecode() throws {
        let s = try steps(#"[{"keys": "tab ctrl+shift+d cmd+z"}, "f3", {"click": [10, 20], "mods": "shift", "count": 2},"#
                          + #" {"drag": [[0, 0], {"world": [1, 0, 0]}]}, {"drag": [[0, 0], [10, 0]], "steps": 5, "pressure": [0, 1]},"#
                          + #" {"run": "Spin"}, {"add": "icoSphere"}, {"selectMode": "face"}, {"shading": "Rendered"}, {"wait": 0.1}]"#)
        XCTAssertEqual(s.count, 10)
        guard case .keys(let k) = s[0] else { return XCTFail("keys") }
        XCTAssertEqual(k.map(\.key), ["tab", "d", "z"])
        XCTAssertTrue(k[1].ctrl && k[1].shift && !k[1].cmd)
        XCTAssertTrue(k[2].cmd)
        guard case .click(.screen(let p), _, let flags, 2) = s[2] else { return XCTFail("click") }
        XCTAssertEqual(p, [10, 20])
        XCTAssertEqual(flags, .shift)
        guard case .drag(let points, _, _, _) = s[3] else { return XCTFail("drag") }
        XCTAssertEqual(points.last, .world([1, 0, 0]))
        guard case .drag(let fine, _, _, let pressure) = s[4] else { return XCTFail("drag steps") }
        XCTAssertEqual(fine.count, 6)
        XCTAssertEqual(pressure.count, 6)
        guard case .shading(.rendered) = s[8] else { return XCTFail("shading by any case") }
    }

    func testBadStepsSayWhatToSend() {
        XCTAssertTrue(failure(#"[{"jump": 1}]"#).contains("the steps: keys"))
        XCTAssertTrue(failure(#"[{"keys": "tab"}, {"mode": "paint"}]"#).hasPrefix("step 2: mode: one of object, edit, sculpt"))
        XCTAssertTrue(failure(#"[{"click": [1]}]"#).contains("[x, y]"))
        XCTAssertTrue(failure(#"[{"keys": "ctrl+"}]"#).contains("has no key"))
        XCTAssertTrue(failure(#"{"keys": "tab"}"#).contains("a list of steps"))
    }

    func testKeysAndClicksEditTheMesh() throws {
        // The cube, edit mode, face select, the face facing +X, extruded 1.
        let notes = try modeller.perform(steps(#"[{"keys": "tab 3"}, {"click": {"world": [1, 0, 0]}}, {"keys": "e"}, {"type": "1"}, {"keys": "return"}]"#))
        XCTAssertEqual(notes.count, 5)
        XCTAssertEqual(faces, 10)
        let mesh = try modeller.document.objects[0].mesh
        XCTAssertEqual(mesh.positions.map(\.x).max(), 2)
        let state = try modeller.state()
        XCTAssertEqual(state["mode"] as? String, "edit")
        XCTAssertEqual(state["selectMode"] as? String, "face")
        XCTAssertEqual(state["undo"] as? String, "Extrude Region and Move")
        // Cmd-Z undoes it.
        try modeller.perform(steps(#"["cmd+z"]"#))
        XCTAssertEqual(faces, 6)
    }

    func testOperatorsByNameAndPopups() throws {
        try modeller.perform(steps(#"[{"keys": "tab 3"}, {"click": {"world": [1, 0, 0]}}, {"run": "Edge > Spin"}, {"type": "90"}, {"keys": "return"}]"#))
        XCTAssertGreaterThan(faces, 10)
        // A name that several operators have: the error lists them; one none has: the error lists what there is.
        XCTAssertThrowsError(try modeller.run("select")) { XCTAssertTrue("\($0)".contains("names")) }
        XCTAssertThrowsError(try modeller.run("Teleport")) { XCTAssertTrue("\($0)".contains("Bridge Edge Loops")) }
        // M opens the merge popup; picking an item runs it.
        try modeller.perform(steps(#"[{"open": {"primitive": "cube"}}, "tab a m"]"#))
        XCTAssertEqual((try modeller.state()["popup"] as? [String: Any])?["title"] as? String, "Merge")
        try modeller.pick("At Center")
        XCTAssertEqual(try modeller.document.objects[0].mesh.vertexCount, 1)
        XCTAssertThrowsError(try modeller.pick("At Center")) { XCTAssertTrue("\($0)".contains("no popup")) }
    }

    func testOperatorSearch() throws {
        try modeller.perform(steps(#"[{"keys": "tab 3"}, {"click": {"world": [1, 0, 0]}}, "f3", {"type": "inset"}]"#))
        let search = try XCTUnwrap(modeller.state()["search"] as? [String: Any])
        XCTAssertEqual(search["results"] as? [String], ["Face ▸ Inset Faces"])
        try modeller.perform(steps(#"["return", {"move": {"world": [1, 0.3, 0.3]}}, {"click": {"world": [1, 0.3, 0.3]}}]"#))
        XCTAssertEqual(faces, 10)
    }

    func testPictures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelingScriptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for view in [ScriptModeller.View.viewport, .window] {
            let url = try modeller.capture(view, scale: 0.5, to: folder.appendingPathComponent("\(view.rawValue).png").path)
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertGreaterThan(image.size.width, 100, view.rawValue)
        }
        // The window's picture leaves the script's viewport as it was.
        XCTAssertEqual((try modeller.state()["viewSize"] as? [Double]), [1000, 640])
        XCTAssertThrowsError(try modeller.capture(.rendered)) { XCTAssertTrue("\($0)".contains("shading")) }
    }
}
