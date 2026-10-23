import AppKit
import Metal
import SwiftUI
import XCTest
import simd
@testable import EngineCore
@testable import Editors
@testable import Modeling

/// The Modeller's window driven as a user would, without showing it: keys through the keymap, clicks through the
/// picking pass, modal operators, undo. MODELING_PNG=<folder> also writes the window (its panels drawn by AppKit, the
/// viewport by its renderer) as pictures.
final class ModelingEditorTests: XCTestCase {
    private var model: ModelingModel!
    private var menus: [ModelingMenu] = []

    override func setUpWithError() throws {
        model = ModelingModel()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        model.renderer = try ViewportRenderer(device: device)
        model.scene = ViewportScene(device: device)
        model.viewSize = [800, 600]
        model.pixelScale = 1
        model.presentMenu = { [weak self] m, _ in self?.menus.append(m) }
    }

    private func key(_ k: String, ctrl: Bool = false, shift: Bool = false, alt: Bool = false, cmd: Bool = false) {
        model.keyDown(KeyChord(k, ctrl: ctrl, shift: shift, alt: alt, cmd: cmd))
    }

    private var cube: EditMesh { model.document.objects[0].mesh }

    func testModesAndSelection() {
        XCTAssertEqual(model.mode, .object)
        key("tab")
        XCTAssertEqual(model.mode, .edit)
        key("a")
        XCTAssertEqual(cube.selectedVertices.count, 8)
        key("a", alt: true)
        XCTAssertFalse(cube.hasSelection)
        key("3")
        XCTAssertEqual(model.selectMode, .face)
        key("tab")
        XCTAssertEqual(model.mode, .object)
        // Undo back through them.
        key("z", cmd: true)
        XCTAssertEqual(model.mode, .edit)
    }

    func testClickSelectsWhatIsUnderIt() {
        // Object mode: a click on the cube selects it; on nothing, deselects.
        model.mouseDown(.left, at: [5, 5], flags: [])
        model.mouseUp(.left, at: [5, 5], flags: [])
        XCTAssertTrue(model.document.selection.isEmpty)
        model.mouseDown(.left, at: [400, 300], flags: [])
        model.mouseUp(.left, at: [400, 300], flags: [])
        XCTAssertEqual(model.document.selection, [model.document.objects[0].id])
        // Edit mode, face select: the face under the centre.
        key("tab")
        key("3")
        key("a", alt: true)
        model.mouseDown(.left, at: [400, 300], flags: [])
        model.mouseUp(.left, at: [400, 300], flags: [])
        XCTAssertEqual(cube.selectedFaces.count, 1)
        // Box select over the whole view: the faces that show (three of a cube from this angle).
        model.mouseDown(.left, at: [2, 2], flags: [])
        model.mouseDragged(to: [798, 598], flags: [])
        model.mouseUp(.left, at: [798, 598], flags: [])
        XCTAssertEqual(cube.selectedFaces.count, 3)
    }

    func testExtrudeAndMoveWithTypedValue() {
        key("tab")
        key("3")
        // The top face.
        let top = (0..<cube.faceCount).first { cube.faceNormal($0).y > 0.9 }!
        var d = model.document
        d.objects[0].mesh.select(faces: [top])
        model.setDocument(d)
        key("e")
        XCTAssertNotNil(model.modal)
        key("1")
        key("return")
        XCTAssertNil(model.modal)
        XCTAssertEqual(cube.faceCount, 10)
        XCTAssertEqual(cube.bounds.hi.y, 2, accuracy: 1e-5, "moved one unit along the normal")
        XCTAssertTrue(cube.isClosedManifold())
        // One undo step takes the extrude and the move back.
        key("z", cmd: true)
        XCTAssertEqual(cube.faceCount, 6)
        key("z", shift: true, cmd: true)
        XCTAssertEqual(cube.faceCount, 10)
    }

    func testGrabTwiceSlidesEdges() {
        key("tab")
        var d = model.document
        d.objects[0].mesh.loopCut(0)
        model.setDocument(d)
        let cut = cube
        // G, a move, G again: edge slide, from where the grab started.
        key("g")
        model.mouseMoved(to: [430, 320], flags: [])
        XCTAssertNotEqual(cube.positions, cut.positions)
        key("g")
        XCTAssertEqual(model.modal?.name, "Edge Slide")
        XCTAssertEqual(cube.positions, cut.positions, "back where the grab started")
        for k in ["0", ".", "5", "return"] { key(k) }
        XCTAssertNil(model.modal)
        XCTAssertNotEqual(cube.positions, cut.positions)
        XCTAssertEqual(cube.bounds.lo, cut.bounds.lo, "along the cube's faces")
        XCTAssertEqual(cube.bounds.hi, cut.bounds.hi)
        XCTAssertTrue(cube.isClosedManifold())
        // One undo step back to before the grab.
        key("z", cmd: true)
        XCTAssertEqual(cube.positions, cut.positions)
        // Shift-V on a lone vertex: vertex slide.
        d = model.document
        d.objects[0].mesh.select(vertices: [0])
        model.setDocument(d)
        key("v", shift: true)
        XCTAssertEqual(model.modal?.name, "Vertex Slide")
        key("esc")
        XCTAssertEqual(cube.positions, cut.positions)
    }

    func testOperatorSearchAndSpin() {
        key("tab")
        key("f3")
        XCTAssertNotNil(model.search)
        XCTAssertTrue(model.searchEntries().contains { $0.path == "Edge ▸ Bridge Edge Loops" })
        XCTAssertEqual(model.searchResults("bridge").first?.title, "Bridge Edge Loops")
        XCTAssertEqual(model.searchResults("edge slide").first?.title, "Edge Slide")
        XCTAssertTrue(model.searchResults("zzqq").isEmpty)
        // Spin, run from the search: the top face a quarter turn in 12 steps round the view's axis.
        let top = (0..<cube.faceCount).first { cube.faceNormal($0).y > 0.9 }!
        var d = model.document
        d.objects[0].mesh.select(faces: [top])
        model.setDocument(d)
        model.search?.query = "spin"
        model.searchRun()
        XCTAssertNil(model.search)
        XCTAssertEqual(model.modal?.name, "Spin")
        for k in ["9", "0", "return"] { key(k) }
        XCTAssertNil(model.modal)
        XCTAssertNil(cube.validate())
        XCTAssertEqual(cube.faceCount, 6 + 4 * 12, "the four sides' walls; the face at the end")
        // What ran last comes first.
        key("f3")
        XCTAssertEqual(model.searchResults("").first?.title, "Spin")
        model.closeSearch()
        XCTAssertNil(model.search)
        key("z", cmd: true)
        XCTAssertEqual(cube.faceCount, 6)
    }

    func testGrabRotateScaleInObjectMode() {
        model.mouse = [400, 300]
        key("g")
        key("x")
        key("2")
        key("return")
        // Blender's X is the engine's X.
        XCTAssertEqual(model.document.objects[0].transform.location, [2, 0, 0])
        key("g")
        key("y")
        key("3")
        key("return")
        // Blender's Y is the engine's −Z.
        XCTAssertEqual(model.document.objects[0].transform.location.z, -3, accuracy: 1e-5)
        key("r")
        key("z")
        key("9"); key("0")
        key("return")
        // Turned round Blender's Z (the engine's Y).
        let r = model.document.objects[0].transform.rotationMatrix
        XCTAssertEqual(abs(r.columns.0.z), 1, accuracy: 1e-4)
        key("s")
        key("2")
        key("esc")
        XCTAssertEqual(model.document.objects[0].transform.scale, [1, 1, 1], "Esc puts it back")
        // Alt-G: back to the origin.
        key("g", alt: true)
        XCTAssertEqual(model.document.objects[0].transform.location, .zero)
    }

    func testMenusAndAdd() {
        key("a", shift: true)
        XCTAssertEqual(menus.last?.title, "Add")
        // Add a UV sphere at the cursor: a second object, selected and active.
        model.add(.uvSphere)
        XCTAssertEqual(model.document.objects.count, 2)
        XCTAssertEqual(model.document.active, 1)
        XCTAssertEqual(model.document.selection.count, 1)
        key("x")
        XCTAssertEqual(menus.last?.title, "Delete")
        menus.last?.items.first?.action?()
        XCTAssertEqual(model.document.objects.count, 1)
        // Edit mode: X is the delete menu with its dissolves.
        key("tab")
        key("x")
        XCTAssertTrue(menus.last?.items.contains { $0.title == "Dissolve Edges" } ?? false)
        // Ctrl-1 in object mode: a subdivision modifier.
        key("tab")
        key("2", ctrl: true)
        XCTAssertEqual(model.document.objects[0].modifiers.first?.kind, .subdivision)
        XCTAssertEqual(model.document.objects[0].modifiers.first?.levels, 2)
    }

    func testLoopCutAndInsetModals() {
        key("tab")
        // Loop cut over the cube's middle: preview, then a click cuts and a right click leaves it centred.
        key("r", ctrl: true)
        XCTAssertNotNil(model.modal)
        model.mouseMoved(to: [400, 300], flags: [])
        XCTAssertFalse(model.previewLines.isEmpty)
        model.mouseDown(.left, at: [400, 300], flags: [])
        model.mouseDown(.right, at: [400, 300], flags: [])
        XCTAssertNil(model.modal)
        XCTAssertEqual(cube.faceCount, 10)
        XCTAssertTrue(cube.isClosedManifold())
        // Inset with a typed thickness.
        key("3")
        let top = (0..<cube.faceCount).first { cube.faceNormal($0).y > 0.9 }!
        var d = model.document
        d.objects[0].mesh.select(faces: [top])
        model.setDocument(d)
        key("i")
        key("0"); key("."); key("2")
        key("return")
        XCTAssertEqual(cube.faceCount, 14)
        XCTAssertTrue(cube.isClosedManifold())
    }

    func testSculptStrokeAndUndo() {
        model.add(.icoSphere)
        model.setMode(.sculpt)
        XCTAssertNotNil(model.sculpt)
        let s = model.sculpt!
        let before = s.mesh.position
        // A stroke across the sphere's middle on screen.
        model.mouseDown(.left, at: [380, 300], flags: [])
        model.mouseDragged(to: [400, 300], flags: [])
        model.mouseDragged(to: [420, 300], flags: [])
        model.mouseUp(.left, at: [420, 300], flags: [])
        XCTAssertNotEqual(s.mesh.position, before)
        key("z", cmd: true)
        XCTAssertEqual(s.mesh.position, before)
        key("z", shift: true, cmd: true)
        XCTAssertNotEqual(s.mesh.position, before)
        // Back to object mode: the shape is in the mesh.
        model.setMode(.object)
        let mesh = model.document.objects[1].mesh
        XCTAssertNotEqual(mesh.positions, Primitive.icoSphere.mesh().positions)
        // Ctrl-I / Alt-M work on the mask (sculpt mode again).
        model.setMode(.sculpt)
        key("i", ctrl: true)
        XCTAssertEqual(model.sculpt!.mesh.position.first?.w, 1)
        key("m", alt: true)
        XCTAssertEqual(model.sculpt!.mesh.position.first?.w, 0)
    }

    func testSaveOpenAndRenderedModel() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelingEditorTests-\(UUID().uuidString)")
        setenv("METALRENDERER_MODELS", folder.path, 1)
        defer { unsetenv("METALRENDERER_MODELS"); try? FileManager.default.removeItem(at: folder) }
        var d = model.document
        d.objects[0].modifiers = [Modifier(.subdivision)]
        model.setDocument(d)
        model.save(as: "Test Chair")
        XCTAssertEqual(model.document.asset, "Test-Chair")
        XCTAssertFalse(model.dirty)
        let r = try XCTUnwrap(ModelAsset.readRendered(XCTUnwrap(ModelStore.url("Test-Chair"))))
        XCTAssertEqual(r.triangleCount, 24 * 2 * 4, "subdivided twice for the render (render levels 2): 96 quads")
        model.newDocument()
        model.open(asset: "Test-Chair")
        XCTAssertEqual(model.document.objects.first?.modifiers.first?.kind, .subdivision)
    }

    /// The window as it looks: its panels, and the viewport drawn into it.
    func testWindowPicture() throws {
        guard let path = ProcessInfo.processInfo.environment["MODELING_PNG"] else { throw XCTSkip("MODELING_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        ModelingViewport.pictures = true
        defer { ModelingViewport.pictures = false }
        for (name, setup) in [("window-object", {}), ("window-edit", { self.key("tab") }),
                              ("window-sculpt", { self.model.add(.head); self.model.setWorkspace(.sculpting) }),
                              ("window-search", { self.key("tab"); self.key("f3"); self.model.search?.query = "edge" })] as [(String, () -> Void)] {
            model = ModelingModel()
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            model.renderer = try ViewportRenderer(device: device)
            model.scene = ViewportScene(device: device)
            model.viewSize = [1000, 640]
            model.pixelScale = 2
            setup()
            model.showSidebar = name == "window-object"
            let host = NSHostingView(rootView: ModelingView().environmentObject(model).frame(width: 1440, height: 860))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 860)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
    }
}
