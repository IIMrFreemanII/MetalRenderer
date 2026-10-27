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

    /// The Object inspector's Edit Asset in Modeller: the asset's network on a new object, in the Procedural tab.
    func testOpenAsset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proc-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var g = ProcGraph()
        let box = g.add(.box)
        let sub = g.add(.subdivide)
        g.link(box, to: sub)
        g.setDisplay(sub)
        try ProcStore.write(ProcAsset(name: "Pebble", graph: g, materials: [MaterialSlot(name: "Material", baseColor: [0.3, 0.3, 0.35, 1])]), slug: "pebble", in: folder)
        let objects = model.document.objects.count
        XCTAssertFalse(session.openAsset("nothing", in: folder))
        XCTAssertEqual(model.document.objects.count, objects)
        XCTAssertTrue(session.openAsset("pebble", in: folder))
        XCTAssertEqual(model.workspace, .procedural)
        XCTAssertEqual(model.document.objects.count, objects + 1)
        XCTAssertEqual(model.activeObject?.name, "Pebble")
        XCTAssertEqual(model.activeObject?.materials.map(\.baseColor), [[0.3, 0.3, 0.35, 1]])   // (the slot the cook names)
        XCTAssertEqual(session.assetSlug, "pebble")
        XCTAssertEqual(session.graph.nodes.map(\.name), ["box1", "subdivide1"])
        XCTAssertEqual(mesh.faceCount, 24)
        model.undo.undo()
        XCTAssertEqual(model.document.objects.count, objects)
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

    /// Keys: Alt-click's, auto-key on a keyed parameter, deleting them, the curves' edits, the frame range and its
    /// loop, the scripted steps.
    func testKeys() throws {
        model.setWorkspace(.procedural)
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        func width() -> Float { let x = mesh.positions.map(\.x); return (x.max() ?? 0) - (x.min() ?? 0) }
        session.setKeys(box, "size")
        XCTAssertEqual(Set(session.graph.node(box)!.curves.keys), ["sizex", "sizey", "sizez"])
        // Auto-key: a changed component keys on the frame; the others keep their one key.
        session.frame = 10
        session.setParam(box, "size", .vec3([3, 1, 1]))
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.map(\.frame), [1, 10])
        XCTAssertEqual(session.graph.node(box)?.curves["sizey"]?.keys.count, 1)
        XCTAssertEqual(width(), 3, accuracy: 1e-5)
        XCTAssertEqual(session.current(session.graph.node(box)!, "size").vec3.x, 3)
        session.frame = 1
        XCTAssertEqual(width(), 1, accuracy: 1e-5)
        // A drag's values at one frame: one undo step (after another edit: edits of one parameter in a row coalesce).
        session.setFrameRange(1...100)
        session.frame = 10
        session.setParam(box, "size", .vec3([4, 1, 1]))
        session.setParam(box, "size", .vec3([5, 1, 1]))
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.value(at: 10), 5)
        model.undo.undo()
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.value(at: 10), 3)
        // An expression replaces the channel's keys; keys replace an expression.
        session.setExpression(box, "sizez", "$F")
        XCTAssertNil(session.graph.node(box)?.curves["sizez"])
        session.setKeys(box, "size")
        XCTAssertNil(session.graph.node(box)?.expressions["sizez"])
        XCTAssertEqual(session.graph.node(box)?.curves["sizez"]?.value(at: 10), 10)
        // Interpolation, deleting the frame's keys, Delete Channels keeping the frame's value.
        session.setInterpolation(box, "size", .constant)
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.last?.interpolation, .constant)
        session.deleteKeys(box, "size")
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.map(\.frame), [1])
        XCTAssertNil(session.graph.node(box)?.curves["sizez"])         // its only key gone: its value as set
        XCTAssertEqual(session.graph.node(box)?.param("size").vec3.z, 10)
        session.frame = 1
        session.setParam(box, "size", .vec3([2, 1, 10]))
        session.deleteChannels(box, "size")
        XCTAssertEqual(session.graph.node(box)?.curves, [:])
        XCTAssertEqual(session.graph.node(box)?.param("size").vec3, [2, 1, 10])
        // The curve editor's edits: keys moved (a drag, one undo step), slopes, extrapolation.
        session.frame = 1
        session.setKeys(box, "size")
        session.frame = 5
        session.setParam(box, "size", .vec3([6, 1, 10]))
        let start = session.shownCurves.filter { $0.channel == "sizex" }
        XCTAssertEqual(start.count, 1)
        session.beginDrag()
        let picks: Set<ProcCurveEditor.Pick> = [.init(node: box, channel: "sizex", frame: 5)]
        session.setCurvesLive(ProcCurveEditor.moving(start, picks, 2, 1))
        session.setCurvesLive(ProcCurveEditor.moving(start, picks, 3, 1))
        session.endDrag("Move Keys")
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.map(\.frame), [1, 8])
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.last?.value, 7)
        model.undo.undo()
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.map(\.frame), [1, 5])
        var c = try XCTUnwrap(session.graph.node(box)?.curves["sizex"])
        c.update(1) { $0.slopes = [0.5, 0.5] }
        c.after = .cycle
        session.setCurves([(box, "sizex", c)], "Slopes")
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.last?.slopes, [0.5, 0.5])
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.after, .cycle)
        // The timeline's move of the keys on a frame.
        session.setCurves(ProcTimeline.moved(session.shownCurves, from: 5, by: -1), "Move Keys")
        XCTAssertEqual(session.graph.node(box)?.curves["sizex"]?.keys.map(\.frame), [1, 4])
        // The frame range, and play's loop over it.
        session.setFrameRange(1...4)
        XCTAssertEqual(session.graph.frames, 1...4)
        // The scripted steps, and the state they show.
        let modeller = ScriptModeller(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let json = #"[{"workspace": "procedural"}, {"network": "new"}, {"range": [1, 24]},"#
            + #" {"keyframe": {"node": "box1", "channel": "sizey", "frame": 1, "value": 1, "interpolation": "linear"}},"#
            + #" {"keyframe": {"node": "box1", "channel": "sizey", "frame": 11, "value": 3}}, {"frame": 6}]"#
        _ = try modeller.perform(try ModellerStep.decode(list: JSONSerialization.jsonObject(with: Data(json.utf8))).get())
        let network = try XCTUnwrap(try modeller.state()["network"] as? [String: Any])
        XCTAssertEqual(network["frames"] as? [Int], [1, 24])
        let node = try XCTUnwrap((network["nodes"] as? [[String: Any]])?.first)
        XCTAssertEqual(((node["keys"] as? [String: Any])?["sizey"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((node["channels"] as? [String: Any])?["sizey"] as? Double, 2)
        // The timeline and the curve editor in the window.
        if let path = ProcessInfo.processInfo.environment["MODELING_PNG"] {
            session.lowerTab = .curves
            model.viewSize = [900, 640]
            model.pixelScale = 2
            session.focus = box
            let rep = try XCTUnwrap(ModelingPictures.window(model))
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("window-procedural-keys.png"))
        }
    }

    func testExpressionsAndTheFrame() throws {
        model.setWorkspace(.procedural)
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        func width() -> Float { let x = mesh.positions.map(\.x); return (x.max() ?? 0) - (x.min() ?? 0) }
        session.setExpression(box, "sizex", "$F")
        session.frame = 3
        XCTAssertEqual(width(), 3, accuracy: 1e-5)
        XCTAssertEqual(session.info[box]?.channels["sizex"], 3)
        model.undo.undo()
        XCTAssertNil(session.graph.node(box)?.expressions["sizex"])
        XCTAssertEqual(width(), 1, accuracy: 1e-5)
        // A number typed over an expression: the value, the expression gone.
        session.setExpression(box, "sizex", "$F")
        session.setChannelValue(box, "size", 0, 2)
        XCTAssertNil(session.graph.node(box)?.expressions["sizex"])
        XCTAssertEqual(width(), 2, accuracy: 1e-5)
        // Delete Channels keeps the last value.
        session.setExpression(box, "sizex", "$F * 2")
        session.frame = 2
        session.deleteChannels(box, "size")
        XCTAssertEqual(session.graph.node(box)?.expressions, [:])
        XCTAssertEqual(session.graph.node(box)?.param("size").vec3.x, 4)
        // Copy Parameter, Paste Relative References.
        session.selection = [box]
        let xf = try XCTUnwrap(session.add(.transform))
        session.copiedParameter = (box, "size")
        session.pasteRelativeReferences(xf, "t")
        XCTAssertEqual(session.graph.node(xf)?.expressions["ty"], "ch(\"../box1/sizey\")")
        XCTAssertEqual(session.info[xf]?.channels["tx"], 4)
        // The scripted steps, and the state they show.
        let modeller = ScriptModeller(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let json = #"[{"workspace": "procedural"}, {"network": "new"}, {"expr": {"node": "box1", "channel": "sizey", "source": "$F + 1"}},"#
            + #" {"frame": 5}]"#
        _ = try modeller.perform(try ModellerStep.decode(list: JSONSerialization.jsonObject(with: Data(json.utf8))).get())
        let network = try XCTUnwrap(try modeller.state()["network"] as? [String: Any])
        XCTAssertEqual(network["frame"] as? Double, 5)
        let node = try XCTUnwrap((network["nodes"] as? [[String: Any]])?.first)
        XCTAssertEqual(node["expressions"] as? [String: String], ["sizey": "$F + 1"])
        XCTAssertEqual((node["channels"] as? [String: Any])?["sizey"] as? Double, 6)
        let bad = try JSONSerialization.jsonObject(with: Data(#"[{"expr": {"node": "box1", "channel": "nope", "source": "1"}}]"#.utf8))
        XCTAssertThrowsError(try modeller.perform(try ModellerStep.decode(list: bad).get()))
        // A failing expression; the node above it cooked from the cache keeps its channels' values for the pane.
        session.setExpression(box, "sizez", "$F * 0.5")
        session.setExpression(xf, "rx", "nofunction()")
        XCTAssertEqual(session.info[xf]?.error, "Rotate: nofunction() isn't a function here")
        XCTAssertEqual(session.info[box]?.channels["sizez"], 1)
        // The pane with an expression (green) and one that fails (red).
        if let path = ProcessInfo.processInfo.environment["MODELING_PNG"] {
            model.viewSize = [900, 640]
            model.pixelScale = 2
            session.focus = box
            let rep = try XCTUnwrap(ModelingPictures.window(model))
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("window-procedural-expressions.png"))
        }
    }

    func testHandlesDragParameters() throws {
        model.setWorkspace(.procedural)
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        session.selection = [box]
        let xform = session.add(.transform)!
        session.focus = xform
        model.camera.frame(AABB(lo: [-2, -2, -2], hi: [2, 2, 2]), aspect: 800 / 600)
        // The transform's handle at its translate (the origin): drag its X axis to the right on screen.
        let c = try XCTUnwrap(model.camera.project([0, 0, 0], size: model.viewSize))
        let e = try XCTUnwrap(model.camera.project([0.3, 0, 0], size: model.viewSize))
        let dir = simd_normalize(SIMD2(e.x - c.x, e.y - c.y))
        let start = SIMD2(c.x, c.y) + dir * 30
        model.mouseDown(.left, at: start, flags: [])
        XCTAssertEqual(session.handleDrag?.axis, 0)
        model.mouseDragged(to: start + dir * 40, flags: [])
        model.mouseDragged(to: start + dir * 80, flags: [])
        model.mouseUp(.left, at: start + dir * 80, flags: [])
        let t = session.graph.node(xform)!.param("t").vec3
        XCTAssertGreaterThan(t.x, 0.1)
        XCTAssertEqual(t.y, 0, accuracy: 1e-4)
        XCTAssertEqual(mesh.bounds.centroid.x, t.x, accuracy: 1e-4)
        XCTAssertEqual(model.undo.undoActionName, "Move Handle")
        model.undo.undo()
        XCTAssertEqual(session.graph.node(xform)!.param("t").vec3, .zero)
        // A curve's points are handles too.
        let curve = session.add(.curve, at: [200, 0])!
        session.focus = curve
        XCTAssertEqual(session.handles.count, 4)
    }

    func testInspection() {
        model.setWorkspace(.procedural)
        session.makeNetwork()
        let box = session.graph.nodes[0].id
        session.selection = [box]
        let color = session.add(.color)!
        session.setParam(color, "color", .vec3([1, 0, 0]))
        session.setParam(color, "class", .string("primitive"))
        // The current node other than the display node is cooked for the spreadsheet.
        session.setDisplay(box)
        session.focus = color
        XCTAssertEqual(session.inspected?.id, color)
        XCTAssertEqual(session.inspected?.geometry.prims.vectors3("Cd")?.first, [1, 0, 0])
        session.setDisplay(color)
        session.showNormals = true
        XCTAssertEqual(session.normalLines(transform: matrix_identity_float4x4).count, 6)
        let f = model.frame()
        let drawn = f.objects.first { $0.active }
        XCTAssertEqual(drawn?.materialColors.count, 216)
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
        session.pointNumbers = true
        let rep = try XCTUnwrap(ModelingPictures.window(model))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("window-procedural.png"))
        session.leftTab = .spreadsheet
        session.focus = n
        let sheet = try XCTUnwrap(ModelingPictures.window(model))
        try XCTUnwrap(sheet.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("window-procedural-spreadsheet.png"))
    }
}
