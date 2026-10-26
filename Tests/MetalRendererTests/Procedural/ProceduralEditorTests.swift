import AppKit
import Metal
import XCTest
import simd
@testable import EngineCore
@testable import Editors
@testable import Modeling
@testable import Procedural

/// The Modeller's Procedural workspace without a window: a network on an object, its cooks into the object's mesh,
/// undo, flags and templates, saving, the scripted steps. MODELING_PNG=<folder> also writes the window.
final class ProceduralEditorTests: XCTestCase {
    private var model: ModelingModel!

    override func setUpWithError() throws {
        model = ModelingModel()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        model.renderer = try ViewportRenderer(device: device)
        model.scene = ViewportScene(device: device)
        model.viewSize = [800, 600]
        model.pixelScale = 1
        model.procedural.synchronous = true
    }

    private var session: ProceduralSession { model.procedural }
    private var mesh: EditMesh { model.activeObject!.mesh }

    func testNetworkCooksIntoTheMeshAndUndoes() {
        model.setWorkspace(.procedural)
        XCTAssertEqual(model.mode, .object)
        XCTAssertFalse(session.hasNetwork)
        session.makeNetwork()
        XCTAssertTrue(session.hasNetwork)
        XCTAssertEqual(session.graph.nodes.map(\.name), ["box1"])
        XCTAssertEqual(mesh.faceCount, 6)
        XCTAssertNotNil(model.activeObject?.network)
        // Tab-adding with box1 selected: wired below it, displayed.
        session.selection = [session.graph.nodes[0].id]
        let sub = session.add(.subdivide)!
        XCTAssertEqual(session.graph.displayNode, sub)
        XCTAssertEqual(session.graph.inputs(of: sub), [session.graph.nodes[0].id])
        XCTAssertEqual(mesh.faceCount, 24)
        session.setParam(sub, "iterations", .int(2))
        XCTAssertEqual(mesh.faceCount, 96)
        // Undo: the parameter, then the node; redo brings them back.
        model.undo.undo()
        XCTAssertEqual(mesh.faceCount, 24)
        model.undo.undo()
        XCTAssertEqual(session.graph.nodes.count, 1)
        XCTAssertEqual(mesh.faceCount, 6)
        model.undo.redo()
        XCTAssertEqual(session.graph.nodes.count, 2)
        XCTAssertEqual(mesh.faceCount, 24)
        // An error leaves the mesh as it was and says so.
        session.setParam(sub, "iterations", .int(1))
        let bad = session.add(.attribrename, after: sub)!
        session.setParam(bad, "from", .string("missing"))
        session.setParam(bad, "to", .string("x"))
        XCTAssertNotNil(session.info[bad]?.error)
        XCTAssertEqual(mesh.faceCount, 24)
    }

    func testDraggedFieldIsOneUndoStep() {
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        let before = model.undo.undoActionName
        for s: Float in [1.1, 1.2, 1.3, 1.4] { session.setParam(box, "scale", .float(s)) }
        XCTAssertEqual(model.activeObject!.mesh.bounds.hi.x, 0.7, accuracy: 1e-5)
        model.undo.undo()
        XCTAssertEqual(session.graph.node(box)?.params["scale"], nil)
        XCTAssertEqual(model.undo.undoActionName, before)
    }

    func testFlagsTemplatesAndBypass() {
        model.setWorkspace(.procedural)
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        session.selection = [box]
        let xform = session.add(.transform)!
        session.setParam(xform, "t", .vec3([3, 0, 0]))
        XCTAssertEqual(mesh.bounds.centroid.x, 3, accuracy: 1e-5)
        session.toggleTemplate(box)
        let objects = model.document.objects.filter(\.visible).count
        let f = model.frame()
        XCTAssertEqual(f.objects.count, objects + 1)
        XCTAssertTrue(f.objects.last!.template)
        session.toggleBypass(xform)
        XCTAssertEqual(mesh.bounds.centroid.x, 0, accuracy: 1e-5)
        session.setDisplay(box)
        XCTAssertEqual(session.graph.displayNode, box)
        // Moving nodes: one undo step at the drag's end, no recook.
        session.beginDrag()
        session.moveSelection(by: [10, 0], ids: [box])
        session.moveSelection(by: [10, 0], ids: [box])
        session.endDrag()
        XCTAssertEqual(session.graph.node(box)?.at.x ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(model.undo.undoActionName, "Move Nodes")
        model.undo.undo()
        XCTAssertEqual(session.graph.node(box)?.at.x ?? 1, 0, accuracy: 1e-6)
    }

    func testCopyPasteDeleteAndLayout() {
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        session.selection = [box]
        let x = session.add(.transform)!
        session.selection = [box, x]
        session.copySelection()
        session.paste()
        XCTAssertEqual(session.graph.nodes.count, 4)
        XCTAssertEqual(Set(session.graph.nodes.map(\.name)).count, 4)
        XCTAssertEqual(session.graph.links.count, 2)
        session.deleteSelection()
        XCTAssertEqual(session.graph.nodes.count, 2)
        session.selection = []
        session.layout()
        XCTAssertGreaterThan(session.graph.node(x)!.at.y, session.graph.node(box)!.at.y)
    }

    func testNetworkSavedInTheAsset() throws {
        session.makeNetwork()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proc-\(UUID().uuidString).mrmesh")
        defer { try? FileManager.default.removeItem(at: url) }
        try ModelAsset.write(model.document, rendered: .init(positions: [], normals: [], uvs: [], indices: [], triangleMaterial: [], materials: []), to: url)
        let back = try XCTUnwrap(ModelAsset.readDocument(url))
        XCTAssertEqual(back.objects[0].network, model.document.objects[0].network)
        // Opened again: the session reads the network.
        model.replaceDocument(back)
        XCTAssertEqual(session.graph.nodes.map(\.name), ["box1"])
    }

    func testScriptedSteps() throws {
        let modeller = ScriptModeller(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let json = #"[{"workspace": "procedural"}, {"network": "new"}, {"node": {"add": "polyextrude", "after": "box1"}},"#
            + #" {"parm": {"node": "polyextrude1", "name": "dist", "value": 0.5}}, {"node": {"add": "grid", "name": "floor"}},"#
            + #" {"node": {"add": "merge"}}, {"wire": {"from": "polyextrude1", "to": "merge1"}}, {"wire": {"from": "floor", "to": "merge1"}},"#
            + #" {"flag": {"node": "merge1", "display": true}}]"#
        let steps = try ModellerStep.decode(list: JSONSerialization.jsonObject(with: Data(json.utf8))).get()
        _ = try modeller.perform(steps)
        let state = try modeller.state()
        let network = try XCTUnwrap(state["network"] as? [String: Any])
        XCTAssertEqual(network["display"] as? String, "merge1")
        let nodes = try XCTUnwrap(network["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.map { $0["name"] as? String }, ["box1", "polyextrude1", "floor", "merge1"])
        XCTAssertEqual(nodes[3]["inputs"] as? [String], ["polyextrude1", "floor"])
        XCTAssertEqual(nodes[3]["prims"] as? Int, 6 + 81)
        // Bad steps say what to send.
        let bad = try JSONSerialization.jsonObject(with: Data(#"[{"node": {"add": "teapot"}}]"#.utf8))
        guard case .failure(let f) = ModellerStep.decode(list: bad) else { return XCTFail("teapot") }
        XCTAssertTrue(f.description.contains("kinds: box"))
    }

    func testWindowPicture() throws {
        guard let path = ProcessInfo.processInfo.environment["MODELING_PNG"] else { throw XCTSkip("MODELING_PNG not set") }
        model.viewSize = [900, 640]
        model.pixelScale = 2
        model.setWorkspace(.procedural)
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        session.selection = [box]
        let ex = session.add(.polyextrude)!
        session.setParam(ex, "dist", .float(0.4))
        session.setParam(ex, "inset", .float(0.1))
        session.setParam(ex, "split", .string("individual"))
        session.selection = [ex]
        let n = session.add(.attribnoise)!
        session.setParam(n, "amp", .float(0.05))
        session.toggleTemplate(box)
        session.focus = ex
        let rep = try XCTUnwrap(ModelingPictures.window(model))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("window-procedural.png"))
    }
}
