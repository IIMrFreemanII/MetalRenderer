import AppKit
import Modeling
import SwiftUI
import UniformTypeIdentifiers
import simd

/// The modelling window, laid out as Blender's: the top bar (File, Edit, the workspaces), the 3D view's header
/// (mode, select modes, menus, pivot, proportional editing, overlays, X-ray, shading) and tool settings, the viewport
/// with the toolbar (T) on its left, the sidebar (N) and the navigation gizmo on its right, the Outliner and the
/// Properties to the right, the status bar at the bottom.
struct ModelingView: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        VStack(spacing: 0) {
            ModelingTopBar()
            HStack(spacing: 1) {
                VStack(spacing: 0) {
                    ModelingHeader()
                    ModelingToolSettings()
                    ZStack(alignment: .topLeading) {
                        ModelingViewport(model: model)
                        if model.shading.mode == .rendered, let stage = model.stage {
                            RenderedViewport(stage: stage).allowsHitTesting(false)
                        }
                        ViewportOverlay()
                    }
                }
                .background(BlenderTheme.window)
                ModelingSidebar()
                    .frame(width: 310)
            }
            .background(BlenderTheme.window)
            ModelingStatusBar()
        }
        .background(BlenderTheme.window)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Top bar

struct ModelingTopBar: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "cube.transparent").foregroundColor(BlenderTheme.orange).padding(.horizontal, 6)
            Menu("File") { fileMenu }.modifier(TopMenuStyle())
            Menu("Edit") {
                Button("Undo  ⌘Z") { model.perform(.undo) }.disabled(!model.undo.canUndo)
                Button("Redo  ⇧⌘Z") { model.perform(.redo) }.disabled(!model.undo.canRedo)
                Divider()
                Toggle("Emulate 3 Button Mouse", isOn: $model.emulateMiddleButton)
                Toggle("Emulate Numpad", isOn: $model.emulateNumpad)
            }.modifier(TopMenuStyle())
            Divider().frame(height: 14).padding(.horizontal, 4)
            ForEach(Workspace.allCases) { w in
                Button { model.setWorkspace(w) } label: {
                    Text(w.title)
                        .font(BlenderTheme.font)
                        .foregroundColor(model.workspace == w ? BlenderTheme.text : BlenderTheme.textDim)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(model.workspace == w ? BlenderTheme.panel : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text((model.document.asset ?? model.document.name) + (model.dirty ? " •" : ""))
                .font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim)
                .padding(.trailing, 10)
        }
        .frame(height: 26)
        .background(BlenderTheme.window)
    }

    @ViewBuilder private var fileMenu: some View {
        Button("New") { model.newDocument() }
        Menu("Open Asset") {
            ForEach(ModelStore.list().prefix(40), id: \.slug) { a in Button(a.slug) { model.open(asset: a.slug) } }
        }
        Button("Save  ⌘S") { model.save() }
        Button("Save As…") { SaveAsPrompt.ask(model) }
        Divider()
        Button("Import OBJ or glTF…") { FilePanels.importFile(model) }
        Menu("Export") {
            Button("Wavefront (.obj)…") { FilePanels.export(model, type: "obj") }
            Button("glTF Binary (.glb)…") { FilePanels.export(model, type: "glb") }
        }
        Divider()
        Button("Edit the Scene's Selection") { model.editSceneSelection() }
        Button("Place in Scene") {
            model.save()
            if let slug = model.document.asset { model.host?.placeModelAsset(slug) }
        }
    }
}

struct TopMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(BlenderTheme.font)
            .fixedSize()
            .padding(.horizontal, 6)
    }
}

/// Save As: a name for the asset.
enum SaveAsPrompt {
    static func ask(_ model: ModelingModel) {
        let alert = NSAlert()
        alert.messageText = "Save the model as an asset"
        alert.informativeText = "It goes to the asset library (Assets/Models) under this name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = model.document.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { model.save(as: field.stringValue) }
    }
}

enum FilePanels {
    static func importFile(_ model: ModelingModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["obj", "glb", "gltf"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { model.importFile(url) } }
    }

    static func export(_ model: ModelingModel, type: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: type)].compactMap { $0 }
        panel.nameFieldStringValue = "\(model.document.name).\(type)"
        if panel.runModal() == .OK, let url = panel.url { model.exportFile(url) }
    }
}

// MARK: - The 3D view's header

struct ModelingHeader: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        HStack(spacing: 6) {
            BPicker(options: EditorMode.allCases.map { ($0, $0.title) }, selection: Binding(get: { model.mode }, set: { model.setMode($0) }))
            if model.mode == .edit {
                BSegmented(items: [(SelectMode.vertex, "circle.grid.cross", "Vertex (1)"), (.edge, "line.diagonal", "Edge (2)"),
                                   (.face, "square.fill", "Face (3)")],
                           selection: Binding(get: { model.selectMode }, set: { model.setSelectMode($0) }))
            }
            menus
            Spacer(minLength: 8)
            if !model.operatorStatus.isEmpty {
                Text(model.operatorStatus).font(BlenderTheme.font.monospacedDigit()).foregroundColor(BlenderTheme.text).lineLimit(1)
                Spacer(minLength: 8)
            }
            if model.mode != .sculpt {
                BPicker(options: ModelingModel.PivotMode.allCases.map { ($0, $0.title) }, selection: $model.pivotMode)
                    .help("Transform Pivot Point")
                BButton(symbol: "circle.dashed", on: model.proportional, help: "Proportional Editing (O)") { model.proportional.toggle() }
            }
            Divider().frame(height: 16)
            BButton(symbol: "circle.hexagongrid", on: model.overlays.enabled, help: "Overlays") { model.overlays.enabled.toggle() }
            overlayMenu
            BButton(symbol: "square.on.square.dashed", on: model.shading.xray, help: "Toggle X-Ray (Alt Z)") { model.shading.xray.toggle() }
            BSegmented(items: [(ViewportShading.Mode.wireframe, "globe", "Wireframe"), (.solid, "circle.fill", "Solid"),
                               (.matcap, "circle.lefthalf.filled", "Material Preview (MatCap)"), (.rendered, "sun.max.fill", "Rendered")],
                       selection: $model.shading.mode)
            shadingMenu
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(BlenderTheme.header)
    }

    @ViewBuilder private var menus: some View {
        Menu("View") { MenuItems(menu: model.viewMenu()) }.modifier(TopMenuStyle())
        if model.mode != .sculpt {
            Menu("Select") {
                Button("All  A") { model.perform(.selectAll) }
                Button("None  Alt A") { model.perform(.deselectAll) }
                Button("Invert  Ctrl I") { model.perform(.invertSelection) }
                Divider()
                Button("Box Select  B") { model.perform(.boxSelect) }
                Button("Circle Select  C") { model.perform(.circleSelect) }
                if model.mode == .edit {
                    Divider()
                    Button("More  Ctrl +") { model.perform(.selectMore) }
                    Button("Less  Ctrl -") { model.perform(.selectLess) }
                    Button("Linked  Ctrl L") { model.perform(.selectLinked(pick: false)) }
                }
            }.modifier(TopMenuStyle())
            Menu("Add") { MenuItems(menu: model.addMenu()) }.modifier(TopMenuStyle())
        }
        switch model.mode {
        case .object:
            Menu("Object") { MenuItems(menu: model.contextMenu()) }.modifier(TopMenuStyle())
        case .edit:
            Menu("Mesh") {
                MenuItems(menu: model.extrudeMenu())
                Divider()
                Menu("Merge") { MenuItems(menu: model.mergeMenu()) }
                Menu("Separate") { MenuItems(menu: model.separateMenu()) }
                Menu("Normals") { MenuItems(menu: model.normalsMenu()) }
                Menu("Delete") { MenuItems(menu: model.deleteMenu()) }
            }.modifier(TopMenuStyle())
            Menu("Vertex") { MenuItems(menu: model.vertexMenu()) }.modifier(TopMenuStyle())
            Menu("Edge") { MenuItems(menu: model.edgeMenu()) }.modifier(TopMenuStyle())
            Menu("Face") { MenuItems(menu: model.faceMenu()) }.modifier(TopMenuStyle())
            Menu("UV") { MenuItems(menu: model.uvMenu()) }.modifier(TopMenuStyle())
        case .sculpt:
            Menu("Sculpt") { if let s = model.sculpt { MenuItems(menu: s.menu(model: model)) } }.modifier(TopMenuStyle())
            Menu("Mask") { if let s = model.sculpt { MenuItems(menu: s.maskMenu(model: model)) } }.modifier(TopMenuStyle())
            Menu("Face Sets") { if let s = model.sculpt { MenuItems(menu: s.faceSetsMenu(model: model)) } }.modifier(TopMenuStyle())
        }
    }

    private var overlayMenu: some View {
        Menu {
            Toggle("Grid", isOn: $model.overlays.grid)
            Toggle("Axes", isOn: $model.overlays.axes)
            Toggle("3D Cursor", isOn: $model.overlays.showCursor)
            Toggle("Wireframe", isOn: $model.overlays.wireframe)
            Toggle("Face Orientation", isOn: $model.shading.faceOrientation)
            Toggle("Statistics", isOn: $model.overlays.statistics)
            Toggle("Face Dots (face select)", isOn: $model.overlays.faceDots)
        } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
        .modifier(TopMenuStyle())
    }

    private var shadingMenu: some View {
        Menu {
            Picker("Color", selection: $model.shading.colorMode) {
                ForEach(ViewportShading.ColorMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("MatCap", selection: $model.shading.matcap) {
                ForEach(Array(MatCaps.names.enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
            }
            Toggle("Backface Culling", isOn: $model.shading.backfaceCulling)
            Toggle("Outline", isOn: $model.shading.showOutline)
        } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
        .modifier(TopMenuStyle())
    }
}

/// A ModelingMenu's items as SwiftUI menu items.
struct MenuItems: View {
    let menu: ModelingMenu
    var body: some View {
        ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
            if item.separator {
                Divider()
            } else if let sub = item.submenu {
                Menu(item.title) { MenuItems(menu: sub) }
            } else {
                Button(item.shortcut.isEmpty ? item.title : "\(item.title)    \(item.shortcut)") { item.action?() }
            }
        }
    }
}

// MARK: - Tool settings

/// The row under the header: the active tool's or brush's settings.
struct ModelingToolSettings: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.mode {
            case .sculpt: sculpt
            default: transform
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(BlenderTheme.region)
    }

    @ViewBuilder private var transform: some View {
        Text(model.tool.title).font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
        if model.proportional {
            BPicker(title: "Falloff", options: ProportionalFalloff.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $model.proportionalFalloff)
            BNumber(label: "Size", value: $model.proportionalSize, step: 0.01, range: 0.001...1000).frame(width: 110)
            BCheck(title: "Connected Only", on: $model.proportionalConnected).fixedSize()
        }
    }

    @ViewBuilder private var sculpt: some View {
        let b = $model.sculptBrush
        BPicker(options: SculptBrushKind.allCases.map { ($0, $0.title) },
                selection: Binding(get: { model.sculptBrush.kind }, set: { model.selectBrush($0) }))
        BNumber(label: "Radius", value: b.radius, step: 0.5, range: 1...1000, format: "%.0f", unit: " px").frame(width: 120)
        BButton(symbol: "hand.draw", on: model.sculptBrush.pressureRadius, help: "Pen pressure sets the radius") { model.sculptBrush.pressureRadius.toggle() }
        BNumber(label: "Strength", value: b.strength, step: 0.005, range: 0...1).frame(width: 120)
        BButton(symbol: "hand.draw.fill", on: model.sculptBrush.pressureStrength, help: "Pen pressure sets the strength") { model.sculptBrush.pressureStrength.toggle() }
        BSegmented(items: [(false, "plus", "Add"), (true, "minus", "Subtract (Ctrl)")], selection: b.subtract)
        BPicker(title: "Falloff", options: ProportionalFalloff.allCases.map { ($0, $0.rawValue.capitalized) }, selection: b.falloff)
        Text("Symmetry").font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim)
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                BButton(title: ["X", "Y", "Z"][i], on: model.sculptBrush.symmetry[i]) { model.sculptBrush.symmetry[i].toggle() }
            }
        }
        BNumber(label: "Autosmooth", value: b.autosmooth, step: 0.005, range: 0...1).frame(width: 130)
        Divider().frame(height: 16)
        BButton(title: "Dyntopo", on: model.dyntopo, help: "Dynamic Topology (Ctrl D)") { model.toggleDyntopo() }
        if model.dyntopo {
            BNumber(label: "Detail", value: $model.dyntopoDetail, step: 0.1, range: 1...100, format: "%.1f", unit: " px").frame(width: 110)
        }
        BNumber(label: "Voxel", value: $model.voxelSize, step: 0.001, range: 0.0005...10, format: "%.4f", unit: " m").frame(width: 130)
        BButton(title: "Remesh", help: "Voxel Remesh (Ctrl R)") { model.voxelRemesh() }
    }
}

// MARK: - Over the viewport

/// What the viewport has over it: the toolbar, the sidebar (N), the navigation gizmo, box and circle select, the
/// statistics.
struct ViewportOverlay: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let r = model.selectionRect {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(.white)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }
            if let c = model.selectionCircle {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(.white)
                    .frame(width: CGFloat(2 * c.radius), height: CGFloat(2 * c.radius))
                    .offset(x: CGFloat(c.centre.x - c.radius), y: CGFloat(c.centre.y - c.radius))
                    .allowsHitTesting(false)
            }
            HStack(alignment: .top, spacing: 0) {
                if model.showToolbar && model.mode != .sculpt { ModelingToolbar().padding(6) }
                if model.showToolbar && model.mode == .sculpt { SculptToolbar().padding(6) }
                VStack(alignment: .leading, spacing: 2) {
                    ViewTitle(view: model.view)
                    Text("(\(model.document.objects.count)) \(model.activeObject?.name ?? "")").font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim)
                    if model.overlays.statistics { Text(model.statistics).font(BlenderTheme.small).foregroundColor(BlenderTheme.text) }
                }
                .padding(8)
                .allowsHitTesting(false)
                Spacer()
                NavigationGizmo(view: model.view).padding(.top, 8).padding(.trailing, 6)
                if model.showSidebar { NPanel().frame(width: 240).padding(6) }
            }
            if model.search != nil { OperatorSearchView().frame(maxWidth: .infinity).padding(.top, 40) }
        }
    }

}

/// "User Perspective", "Front Orthographic" …
struct ViewTitle: View {
    @ObservedObject var view: CameraPublisher
    var body: some View {
        let c = view.camera
        Text("\(c.aligned?.title ?? "User") \(c.orthographic ? "Orthographic" : "Perspective")")
            .font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
    }
}

/// The toolbar (T): the mode's tools, one active.
struct ModelingToolbar: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(ModelingTool.tools(for: model.mode).enumerated()), id: \.offset) { _, group in
                VStack(spacing: 1) {
                    ForEach(group) { t in
                        Button { model.tool = t; model.redraw() } label: {
                            Image(systemName: t.symbol)
                                .font(.system(size: 14))
                                .foregroundColor(BlenderTheme.text)
                                .frame(width: 30, height: 30)
                                .background(model.tool == t ? BlenderTheme.active : BlenderTheme.widget)
                        }
                        .buttonStyle(.plain)
                        .help(t.title)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// Sculpt mode's toolbar: the brushes.
struct SculptToolbar: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        VStack(spacing: 1) {
            ForEach(SculptBrushKind.allCases) { k in
                Button { model.selectBrush(k) } label: {
                    Image(systemName: k.symbol)
                        .font(.system(size: 13))
                        .foregroundColor(BlenderTheme.text)
                        .frame(width: 30, height: 30)
                        .background(model.sculptBrush.kind == k ? BlenderTheme.active : BlenderTheme.widget)
                }
                .buttonStyle(.plain)
                .help(k.shortcut.isEmpty ? k.title : "\(k.title) (\(k.shortcut))")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Blender's navigation gizmo: the axes as the view sees them (click one: view from it), drag to orbit; below it,
/// zoom and pan by dragging, and perspective/orthographic.
struct NavigationGizmo: View {
    @EnvironmentObject var model: ModelingModel
    @ObservedObject var view: CameraPublisher
    @State private var last: CGPoint?

    private struct Ball { var axis: Int; var positive: Bool; var point: CGPoint; var depth: Float }

    private func balls(_ size: CGFloat) -> [Ball] {
        let c = view.camera
        var out: [Ball] = []
        for i in 0..<3 {
            let a = BlenderAxes.basis[i]
            for positive in [true, false] {
                let d = positive ? a : -a
                let p = CGPoint(x: size / 2 + CGFloat(simd_dot(d, c.right)) * size * 0.36, y: size / 2 - CGFloat(simd_dot(d, c.up)) * size * 0.36)
                out.append(Ball(axis: i, positive: positive, point: p, depth: simd_dot(d, c.forward)))
            }
        }
        return out.sorted { $0.depth > $1.depth }
    }

    private static let colors = [BlenderTheme.axisX, BlenderTheme.axisY, BlenderTheme.axisZ]

    var body: some View {
        let size: CGFloat = 86
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06)).frame(width: size, height: size)
                Canvas { g, _ in
                    for b in balls(size) {
                        if b.positive {
                            var line = Path()
                            line.move(to: CGPoint(x: size / 2, y: size / 2))
                            line.addLine(to: b.point)
                            g.stroke(line, with: .color(Self.colors[b.axis]), lineWidth: 2)
                        }
                        let r: CGFloat = b.positive ? 8 : 6
                        let rect = CGRect(x: b.point.x - r, y: b.point.y - r, width: 2 * r, height: 2 * r)
                        g.fill(Path(ellipseIn: rect), with: .color(Self.colors[b.axis].opacity(b.positive ? 1 : 0.45)))
                        if b.positive {
                            g.draw(Text(["X", "Y", "Z"][b.axis]).font(.system(size: 9, weight: .bold)).foregroundColor(.black), at: b.point)
                        }
                    }
                }
                .frame(width: size, height: size)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if let l = last {
                        model.camera.orbit(dx: Float(g.location.x - l.x), dy: Float(g.location.y - l.y))
                    }
                    last = g.location
                }
                .onEnded { g in
                    defer { last = nil }
                    guard abs(g.translation.width) + abs(g.translation.height) < 3 else { return }
                    // A click: the ball under it, nearest the view.
                    let hit = balls(size).filter { hypot($0.point.x - g.location.x, $0.point.y - g.location.y) < 10 }.min { $0.depth < $1.depth }
                    guard let b = hit else { return }
                    let views: [[ViewportCamera.AlignedView]] = [[.right, .left], [.back, .front], [.top, .bottom]]
                    model.camera.align(views[b.axis][b.positive ? 0 : 1])
                })
            VStack(spacing: 2) {
                DragButton(symbol: "plus.magnifyingglass") { _, dy in model.camera.dolly(pow(1.01, dy)) }
                DragButton(symbol: "hand.raised") { dx, dy in model.camera.pan(dx: dx, dy: dy, viewHeight: model.viewSize.y) }
                Button { model.camera.toggleOrthographic() } label: {
                    Image(systemName: view.camera.orthographic ? "square.grid.3x3" : "cube").font(.system(size: 12))
                        .foregroundColor(BlenderTheme.text).frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("Perspective/Orthographic (Numpad 5)")
            }
        }
    }
}

/// A round button you drag (the gizmo's zoom and pan).
struct DragButton: View {
    let symbol: String
    let drag: (Float, Float) -> Void
    @State private var last: CGPoint?
    var body: some View {
        Image(systemName: symbol).font(.system(size: 12)).foregroundColor(BlenderTheme.text)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(0.1)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if let l = last { drag(Float(g.location.x - l.x), Float(g.location.y - l.y)) }
                    last = g.location
                }
                .onEnded { _ in last = nil })
    }
}

// MARK: - Status bar

struct ModelingStatusBar: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(model.hints.enumerated()), id: \.offset) { _, h in
                HStack(spacing: 3) {
                    Text(h.0).font(BlenderTheme.small.weight(.semibold)).foregroundColor(BlenderTheme.text)
                        .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(BlenderTheme.widget))
                    Text(h.1).font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim)
                }
            }
            Spacer()
            Text(model.message).font(BlenderTheme.small).foregroundColor(BlenderTheme.text).lineLimit(1)
            Spacer()
            Text(model.statistics).font(BlenderTheme.small.monospacedDigit()).foregroundColor(BlenderTheme.textDim)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(BlenderTheme.header)
    }
}
