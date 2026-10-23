import AppKit
import Combine
import EngineCore
import Foundation
import Metal
import Modeling
import simd

/// What the modelling window needs of the app (RendererController; nothing in the tests): the scene's selected object
/// to edit, what to do when an asset is saved, the Rendered view's stage.
protocol ModelingHost: AnyObject {
    var metalDevice: MTLDevice? { get }
    /// The main view's selected object as a model (its meshes and materials) and where it came from, or why there is
    /// none (main thread).
    func modelOfSelection(_ done: @escaping (ModelingDocument?, String, ModelSource?) -> Void)
    /// A model asset was saved: the scene picks it up (replacing what it was opened from, if `source` names it).
    func modelAssetSaved(_ slug: String, source: ModelSource?)
    /// Put a model asset in the main scene, in front of the camera.
    func placeModelAsset(_ slug: String)
}

/// Where an edited model came from in the main scene: what saving replaces there.
struct ModelSource: Equatable {
    /// The placed object (index in the scene's file), if it is one.
    var placedObject: Int?
    /// The instances it was made of.
    var instances: [Int]
}

/// The tools of the toolbar (T), as Blender's: what a left drag does.
enum ModelingTool: String, CaseIterable, Identifiable {
    case select, cursor, move, rotate, scale
    case extrude, inset, bevel, loopCut, knife
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select Box"
        case .cursor: "Cursor"
        case .move: "Move"
        case .rotate: "Rotate"
        case .scale: "Scale"
        case .extrude: "Extrude Region"
        case .inset: "Inset Faces"
        case .bevel: "Bevel"
        case .loopCut: "Loop Cut"
        case .knife: "Knife"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow.and.square.on.square.dashed"
        case .cursor: "scope"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: "arrow.clockwise"
        case .scale: "arrow.up.left.and.arrow.down.right"
        case .extrude: "square.stack.3d.up"
        case .inset: "square.inset.filled"
        case .bevel: "square.dashed.inset.filled"
        case .loopCut: "rectangle.split.2x1"
        case .knife: "scissors"
        }
    }

    static func tools(for mode: EditorMode) -> [[ModelingTool]] {
        switch mode {
        case .object: [[.select, .cursor], [.move, .rotate, .scale]]
        case .edit: [[.select, .cursor], [.move, .rotate, .scale], [.extrude, .inset, .bevel, .loopCut, .knife]]
        case .sculpt: []
        }
    }
}

/// A popup menu (X, M, Shift-A, the context menu …): items with what they do.
struct ModelingMenu {
    struct Item {
        var title: String
        var shortcut = ""
        var action: (() -> Void)?
        var submenu: ModelingMenu?
        var separator = false
        static let separator = Item(title: "", separator: true)
    }
    var title: String
    var items: [Item]
}

/// The modelling window's state and its edits, on the main thread: the document and its undo, the mode, tools, the
/// view and what draws it, the operator running (a modal one: G, extrude, bevel …). The views read it; the viewport
/// sends it input. Coarse changes publish (the outliner, the panels); the viewport redraws through `needsDisplay`.
final class ModelingModel: ObservableObject {
    weak var host: ModelingHost?
    let undo = UndoManager()

    private(set) var document: ModelingDocument
    /// Published when the document changes in a way the panels show (objects, names, the active one, modifiers …).
    @Published private(set) var revision = 0
    @Published var mode: EditorMode = .object
    @Published var selectMode: SelectMode = .vertex
    @Published var tool: ModelingTool = .select
    @Published var shading = ViewportShading() {
        didSet {
            redraw()
            if (shading.mode == .rendered) != (oldValue.mode == .rendered) { updateStage() }
        }
    }
    /// The Rendered view's renderer, while it shows.
    var stage: StageRenderer?
    @Published var overlays = ViewportOverlays() { didSet { redraw() } }
    @Published var showToolbar = true
    @Published var showSidebar = false
    @Published var propertiesTab: PropertiesTab = .object
    /// The header's text while an operator runs ("Move  D: …"), and the status bar's hints and message.
    @Published var operatorStatus = ""
    @Published var hints: [(String, String)] = ModelingKeymap.hints(.object)
    @Published var message = ""
    @Published var proportional = false
    @Published var proportionalFalloff = ProportionalFalloff.smooth
    @Published var proportionalSize: Float = 1
    @Published var proportionalConnected = false
    @Published var pivotMode: PivotMode = .median
    /// Blender's Emulate 3 Button Mouse: Option-drag orbits (a trackpad's or a two-button mouse's middle button).
    @Published var emulateMiddleButton = UserDefaults.standard.bool(forKey: "modeller.emulate3") {
        didSet { UserDefaults.standard.set(emulateMiddleButton, forKey: "modeller.emulate3") }
    }
    @Published var emulateNumpad = UserDefaults.standard.bool(forKey: "modeller.emulateNumpad") {
        didSet { UserDefaults.standard.set(emulateNumpad, forKey: "modeller.emulateNumpad") }
    }
    /// Where the document came from in the main scene (saving replaces it there).
    var source: ModelSource?
    /// Unsaved changes.
    @Published private(set) var dirty = false

    enum PropertiesTab: String, CaseIterable, Identifiable {
        case object, modifiers, material, data
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .object: "square.fill"
            case .modifiers: "wrench.fill"
            case .material: "circle.lefthalf.filled"
            case .data: "triangle.fill"
            }
        }
        var title: String { rawValue.capitalized }
    }

    enum PivotMode: String, CaseIterable { case median, cursor, active
        var title: String { self == .median ? "Median Point" : self == .cursor ? "3D Cursor" : "Active Element" }
    }

    // MARK: The view

    var camera = ViewportCamera() {
        didSet {
            redraw()
            if camera != view.camera { view.camera = camera }
            stage?.setCamera(camera)
        }
    }
    /// The camera as the views that show it (the navigation gizmo) observe it, apart from the rest.
    let view = CameraPublisher()
    /// The viewport's size in points and its backing scale.
    var viewSize = SIMD2<Float>(800, 600)
    var pixelScale: Float = 2
    /// The edited mesh's active vertex, edge or face (last clicked): drawn white.
    var activeElement: (vertex: Int?, edge: Int?, face: Int?) = (nil, nil, nil)
    /// The running modal operator, if any.
    var modal: ModalOperator? { didSet { refreshStatus() } }
    /// Lines the running operator or tool draws.
    var previewLines: [OverlayLine] = []
    /// The viewport's renderer and buffers (the window's; a headless one in the tests).
    var renderer: ViewportRenderer?
    var scene: ViewportScene?
    /// Called when the viewport should draw again.
    var needsDisplay: () -> Void = {}
    /// Shows a popup menu at a point of the viewport (the window's; recorded in the tests).
    var presentMenu: (ModelingMenu, SIMD2<Float>) -> Void = { _, _ in }
    /// The last mouse position over the viewport (points, top left).
    var mouse = SIMD2<Float>(400, 300)
    /// Sculpt mode's session (its mesh, tree, brush, strokes), while in it.
    var sculpt: SculptController?
    /// The sculpt brush, and the other brushes' settings.
    @Published var sculptBrush = SculptBrush() { didSet { redraw() } }
    var brushes: [SculptBrushKind: SculptBrush] = [:]
    @Published var voxelSize: Float = 0.05
    @Published var dyntopo = false
    @Published var dyntopoDetail: Float = 12
    /// What the current press began (navigation, a click, a stroke).
    var gesture: Gesture = .none
    /// Box select's rectangle and circle select's circle (points), drawn over the viewport.
    @Published var selectionRect: CGRect?
    @Published var selectionCircle: (centre: SIMD2<Float>, radius: Float)?
    /// The tool gizmo's handle under the mouse (highlighted).
    var hoveredHandle: GizmoHandle?
    /// The last coalesced edit (a field being dragged makes one undo step).
    var coalesceKey = ""
    var coalesceTime = Date.distantPast
    /// The workspace tab (Layout, Modeling, Sculpting, UV Editing).
    @Published var workspace: Workspace = .layout

    init(host: ModelingHost? = nil, document: ModelingDocument = .startup()) {
        self.host = host
        self.document = document
        undo.groupsByEvent = false
        undo.levelsOfUndo = 64
    }

    func redraw() { needsDisplay() }

    var activeIndex: Int? { document.active.flatMap { $0 < document.objects.count ? $0 : nil } }
    var activeObject: ModelObject? { activeIndex.map { document.objects[$0] } }

    // MARK: Undo

    /// What one undo step restores.
    private struct UndoState {
        var document: ModelingDocument
        var mode: EditorMode
        var selectMode: SelectMode
    }

    private var undoState: UndoState { UndoState(document: document, mode: mode, selectMode: selectMode) }

    /// One undo step named `name`: the document as it was before.
    func registerUndo(_ name: String, before: ModelingDocument? = nil, mode beforeMode: EditorMode? = nil) {
        var state = undoState
        if let before { state.document = before }
        if let beforeMode { state.mode = beforeMode }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(state, name: name) }
        undo.setActionName(name)
        undo.endUndoGrouping()
    }

    private func restore(_ state: UndoState, name: String) {
        let now = undoState
        undo.registerUndo(withTarget: self) { m in m.restore(now, name: name) }
        undo.setActionName(name)
        cancelModal()
        if mode == .sculpt && state.mode != .sculpt {
            if let s = sculpt { scene?.overrides[s.objectID] = nil }
            sculpt = nil
        }
        document = state.document
        if state.mode == .sculpt && mode != .sculpt { enterSculpt() } else if state.mode == .sculpt { sculpt?.reload(from: document, model: self) }
        mode = state.mode
        selectMode = state.selectMode
        activeElement = (nil, nil, nil)
        documentChanged(dirty: true)
    }

    /// Changes the document as one undo step.
    func edit(_ name: String, _ change: (inout ModelingDocument) -> Void) {
        let before = document
        change(&document)
        registerUndo(name, before: before)
        documentChanged(dirty: true)
    }

    /// Changes the active object's mesh (edit mode) as one undo step.
    func editMesh(_ name: String, _ change: (inout EditMesh) -> Void) {
        guard let i = activeIndex else { return }
        edit(name) { change(&$0.objects[i].mesh) }
    }

    /// The document as changed without an undo step of its own (a modal operator's preview; its step is registered
    /// when it finishes).
    func setDocument(_ d: ModelingDocument, coarse: Bool = false) {
        document = d
        if coarse { revision += 1 }
        redraw()
    }

    func documentChanged(dirty: Bool = false) {
        if dirty { self.dirty = true }
        revision += 1
        refreshStatus()
        redraw()
        stageDocumentChanged()
    }

    func markSaved() { dirty = false }

    /// The whole document replaced (New, Open): its own undo history.
    func replaceDocument(_ d: ModelingDocument, source: ModelSource? = nil) {
        cancelModal()
        if mode != .object { setMode(.object, undoable: false) }
        document = d
        self.source = source
        undo.removeAllActions()
        dirty = false
        activeElement = (nil, nil, nil)
        if let box = documentBounds() { camera.frame(box, aspect: viewSize.x / max(viewSize.y, 1)) }
        documentChanged()
    }

    // MARK: Statistics

    /// The status bar's statistics: "Verts 8/8 | Edges 12/12 | Faces 6/6 | Objects 1/1".
    var statistics: String {
        switch mode {
        case .edit:
            guard let m = activeObject?.mesh else { return "" }
            return "Verts \(m.selectedVertices.count)/\(m.vertexCount) | Edges \(m.selectedEdges.count)/\(m.edgeCount) | Faces \(m.selectedFaces.count)/\(m.faceCount)"
        case .sculpt:
            guard let s = sculpt else { return "" }
            return "Verts \(s.vertexCount) | Faces \(s.triangleCount)"
        case .object:
            var v = 0, f = 0
            for o in document.objects where o.visible { v += o.mesh.vertexCount; f += o.mesh.faceCount }
            return "Objects \(document.selection.count)/\(document.objects.count) | Verts \(v) | Faces \(f)"
        }
    }

    func refreshStatus() {
        if let m = modal {
            operatorStatus = m.status(self)
            hints = m.hints
        } else {
            operatorStatus = ""
            hints = ModelingKeymap.hints(mode)
        }
    }

    // MARK: The frame

    /// What the viewport draws now.
    func frame() -> ViewportFrame {
        var f = ViewportFrame()
        f.camera = camera
        f.size = SIMD2(Int((viewSize.x * pixelScale).rounded()), Int((viewSize.y * pixelScale).rounded()))
        f.pixelScale = pixelScale
        f.shading = shading
        f.overlays = overlays
        f.cursor = document.cursor
        if let scene {
            f.objects = scene.objects(document, mode: mode, selectMode: selectMode, active: activeElement,
                                      wire: shading.mode == .wireframe || overlays.wireframe)
        }
        f.lines = previewLines + toolGizmoLines()
        if let s = sculpt, mode == .sculpt { f.lines += s.cursorLines(self) }
        return f
    }

    /// The bounds of the visible objects in the world (nil: nothing).
    func documentBounds(selectedOnly: Bool = false) -> AABB? {
        var b = AABB()
        var any = false
        for o in document.objects where o.visible && (!selectedOnly || document.selection.contains(o.id)) {
            let m = o.transform.matrix
            for p in o.mesh.positions {
                let q = m * SIMD4(p, 1)
                b.grow(SIMD3(q.x, q.y, q.z))
                any = true
            }
        }
        return any ? b : nil
    }

    // MARK: Modes

    /// Object, edit or sculpt mode for the active object.
    func setMode(_ new: EditorMode, undoable: Bool = true) {
        guard new != mode else { return }
        cancelModal()
        if new != .object && activeObject == nil { message = "No active object"; return }
        let before = mode
        // Sculpting goes into the document first, so the step back to sculpt mode has it.
        if mode == .sculpt { leaveSculpt() }
        if undoable { registerUndo("Toggle \(new.title)", mode: before) }
        mode = new
        if new == .sculpt { enterSculpt() }
        if new == .edit, let i = activeIndex {
            // Edit mode starts with the active object selected alone.
            document.selection = [document.objects[i].id]
        }
        if new != .edit { activeElement = (nil, nil, nil) }
        if new == .object && [.extrude, .inset, .bevel, .loopCut, .knife].contains(tool) { tool = .select }
        documentChanged()
    }

    func setSelectMode(_ m: SelectMode, extend: Bool = false) {
        guard mode == .edit, let i = activeIndex else { return }
        let old = selectMode
        edit("Select Mode") { $0.objects[i].mesh.convertSelection(from: old, to: m) }
        selectMode = m
        redraw()
    }

    // MARK: Messages

    func report(_ text: String) {
        message = text
    }
}

/// Blender's workspaces: a mode and a layout each.
enum Workspace: String, CaseIterable, Identifiable {
    case layout, modeling, sculpting, uv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .layout: "Layout"
        case .modeling: "Modeling"
        case .sculpting: "Sculpting"
        case .uv: "UV Editing"
        }
    }
}

extension ModelingModel {
    /// A workspace tab: its mode and shading (Sculpting: MatCap; UV Editing: the UV view in the sidebar).
    func setWorkspace(_ w: Workspace) {
        workspace = w
        switch w {
        case .layout:
            setMode(.object)
        case .modeling:
            setMode(.edit)
            if shading.mode == .matcap { shading.mode = .solid }
        case .sculpting:
            setMode(.sculpt)
            shading.mode = .matcap
        case .uv:
            setMode(.edit)
            selectMode = .face
            propertiesTab = .data
        }
    }
}

/// The view's camera, published on its own so that orbiting redraws the navigation gizmo, not every panel.
final class CameraPublisher: ObservableObject {
    @Published var camera = ViewportCamera()
}
