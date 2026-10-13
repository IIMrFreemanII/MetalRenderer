import AppKit
import SwiftUI

/// The Material Designer's window: the toolbar (the graph shown, its file, export, the workshop), the node library,
/// the canvas, and on the right the 2D view of a node's image, the 3D preview of the material and the inspector; the
/// status line under them.
struct MaterialEditorView: View {
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        VStack(spacing: 0) {
            MaterialToolbar()
            Divider()
            HStack(spacing: 0) {
                MaterialLibraryList().frame(width: 176)
                Divider()
                MaterialCanvasView()
                Divider()
                VStack(spacing: 0) {
                    Material2DPanel().frame(height: 250)
                    Divider()
                    Material3DPanel().frame(height: 240)
                    Divider()
                    MaterialInspector()
                }
                .frame(width: 340)
                .background(GraphColors.chrome)
            }
            Divider()
            MaterialStatusLine()
        }
        .background(GraphColors.chrome)
        .preferredColorScheme(.dark)
    }
}

struct MaterialToolbar: View {
    @EnvironmentObject var model: MaterialEditorModel
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { model.selectedGraph }, set: { model.select($0) })) {
                ForEach(model.graphNames, id: \.self) { n in
                    Text(n + (model.isDirty(n) ? " •" : "")).tag(n)
                }
            }
            .labelsHidden()
            .frame(width: 200)
            Menu {
                Button("New Graph") { model.newGraph() }
                Button("Duplicate") { model.duplicate() }
                Button("Rename…") { newName = model.selectedGraph; renaming = true }.disabled(model.isBuiltIn(model.selectedGraph))
                Divider()
                Button(model.isBuiltIn(model.selectedGraph) ? "Reset to Built-in" : "Delete") { model.deleteGraph() }
            } label: { Label("Graph", systemImage: "square.stack.3d.up") }
                .frame(width: 90)
                .popover(isPresented: $renaming) {
                    HStack {
                        TextField("Name", text: $newName).frame(width: 180).onSubmit { model.rename(newName); renaming = false }
                        Button("Rename") { model.rename(newName); renaming = false }
                    }
                    .padding(10)
                }
            Divider().frame(height: 18)
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }.disabled(!model.isDirty)
            Menu {
                Button("Revert \(model.selectedGraph)") { model.revert() }.disabled(!model.isDirty(model.selectedGraph))
                Button("Revert All") { model.revertAll() }.disabled(!model.isDirty)
            } label: { Image(systemName: "arrow.uturn.backward") }.frame(width: 40)
            Menu {
                ForEach(MatExport.Format.allCases, id: \.self) { f in Button("Export \(f.rawValue)…") { export(f) } }
                Divider()
                Button("Copy as Swift") { model.copyAsSwift() }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }.frame(width: 96)
            Spacer()
            Button { model.frameAll(in: model.canvasSize) } label: { Label("Frame", systemImage: "rectangle.dashed") }.help("Frame the graph (F)")
            Divider().frame(height: 18)
            if model.inWorkshop {
                Picker("", selection: Binding(get: { model.scene.materialWorkshop.layout }, set: { model.setLayout($0) })) {
                    ForEach(MaterialWorkshopSettings.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 100)
                Picker("", selection: Binding(get: { model.scene.materialWorkshop.backdrop }, set: { model.setBackdrop($0) })) {
                    ForEach(MaterialWorkshopSettings.Backdrop.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 90)
            } else {
                Button { model.showInWorkshop() } label: { Label("Workshop", systemImage: "cube") }
                    .help("Show the material in the material workshop (path traced)")
            }
            MaterialAssignButton()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func export(_ format: MatExport.Format) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "The \(model.selectedGraph) outputs as \(format.rawValue) files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url, format: format)
    }
}

/// The node library: every node by family (a click adds it in the middle of the view), the outputs, other graphs as
/// subgraphs; a function's math nodes while one is edited.
struct MaterialLibraryList: View {
    @EnvironmentObject var model: MaterialEditorModel
    @State private var filter = ""

    private var centre: SIMD2<Float> { model.graphPoint(CGPoint(x: model.canvasSize.width / 2 - 60, y: model.canvasSize.height / 2 - 60)) }
    private func shown(_ title: String) -> Bool { filter.isEmpty || title.lowercased().contains(filter.lowercased()) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(6)
            List {
                if model.editingFunction != nil {
                    ForEach(["Inputs", "Sampling", "Math", "Vector", "Logic", "Random"], id: \.self) { family in
                        let kinds = MatFnKind.allCases.filter { $0.spec.family == family && $0 != .result && shown($0.spec.title) }
                        if !kinds.isEmpty {
                            Section(family) {
                                ForEach(kinds, id: \.self) { k in item(k.spec.title, MatColors.function(family)) { model.addFunctionNode(k, at: centre) } }
                            }
                        }
                    }
                } else {
                    ForEach(MatFamily.allCases, id: \.self) { family in
                        let kinds = MatOpKind.allCases.filter { $0.spec.family == family && $0 != .subgraph && $0 != .output && shown($0.spec.title) }
                        if !kinds.isEmpty {
                            Section(family.rawValue) {
                                ForEach(kinds, id: \.self) { k in item(k.spec.title, MatColors.family(family)) { model.addNode(k, at: centre) } }
                            }
                        }
                    }
                    Section("Outputs") {
                        ForEach(MatChannel.allCases.filter { shown($0.title) }, id: \.self) { c in
                            item(c.title, MatColors.family(.graph)) { model.addOutput(c, at: centre) }
                                .opacity(model.graph.channels[c] == nil ? 1 : 0.4)
                        }
                    }
                    Section("Subgraphs") {
                        ForEach(model.graphNames.filter { $0 != model.selectedGraph && shown($0) }, id: \.self) { n in
                            item(n, MatColors.family(.graph)) { model.addSubgraph(n, at: centre) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func item(_ title: String, _ color: Color, add: @escaping () -> Void) -> some View {
        Button(action: add) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 12)
                Text(title).font(.system(size: 11)).foregroundColor(GraphColors.text)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The 2D view: the pinned node's image, else the focused one's (else the base colour's): tiled 3 × 3 or not, a
/// channel or all, brighter or darker.
struct Material2DPanel: View {
    @EnvironmentObject var model: MaterialEditorModel
    @State private var settings = Mat2DSettings()

    var body: some View {
        let id = model.previewNodeID
        let step = id.flatMap { model.step($0) }
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(id.map { model.graph.node($0)?.kind.spec.title ?? $0 } ?? "2D").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let s = step { Text(verbatim: "\(s.pixels) px \(s.outputs.first?.rawValue ?? "")").foregroundColor(.secondary).font(.system(size: 10)) }
                Spacer()
                Picker("", selection: $settings.channel) {
                    Text("RGB").tag(0); Text("R").tag(1); Text("G").tag(2); Text("B").tag(3); Text("A").tag(4)
                }
                .labelsHidden().frame(width: 64).controlSize(.small)
                Toggle("3×3", isOn: Binding(get: { settings.tiles > 1 }, set: { settings.tiles = $0 ? 3 : 1 })).controlSize(.small)
            }
            ZStack {
                if let device = model.engine?.device {
                    Mat2DView(device: device, texture: step.flatMap { model.engine?.texture($0.hash) }, grey: step?.outputs.first == .grey,
                              settings: settings)
                } else {
                    Color.black
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Text("Exposure").font(.system(size: 10))
                Slider(value: $settings.exposure, in: 0.1...4).controlSize(.mini)
                Text("Zoom").font(.system(size: 10))
                Slider(value: $settings.zoom, in: 0.5...4).controlSize(.mini)
            }
        }
        .padding(6)
    }
}

/// The 3D preview: the material on a shape, turned by dragging.
struct Material3DPanel: View {
    @EnvironmentObject var model: MaterialEditorModel
    @State private var shape = MatPreviewShape.sphere
    @State private var turn = SIMD2<Float>(0.6, 0.35)
    @State private var dragStart: SIMD2<Float>?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Preview").font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("", selection: $shape) { ForEach(MatPreviewShape.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 90).controlSize(.small)
            }
            ZStack {
                if let device = model.engine?.device {
                    Mat3DView(device: device, outputs: model.result?.outputs, shape: shape, turn: turn)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            let start = dragStart ?? turn
                            if dragStart == nil { dragStart = turn }
                            turn = SIMD2(start.x - Float(g.translation.width) * 0.01, min(max(start.y + Float(g.translation.height) * 0.01, -1.4), 1.4))
                        }.onEnded { _ in dragStart = nil })
                } else {
                    Color.black
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(6)
    }
}

struct MaterialStatusLine: View {
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        HStack(spacing: 10) {
            if let m = model.message {
                Text(m).lineLimit(1)
                Button { model.clearMessage() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
            } else if let e = model.planError {
                Text(e).foregroundColor(.red).lineLimit(1)
            } else if let r = model.result {
                Text(String(format: "%@ · %d nodes · baked %d · GPU %.1f ms%@", model.selectedGraph, r.plan.steps.count, r.baked, r.gpuMilliseconds,
                            r.errors.isEmpty ? "" : " · \(r.errors.count) errors"))
                    .foregroundColor(r.errors.isEmpty ? .secondary : .orange)
            }
            Spacer()
            if model.isDirty { Text("unsaved").foregroundColor(.orange) }
            Text("Tab adds a node · double-click a pixel processor to edit it · F frames").foregroundColor(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

/// Click-to-pick: arms a pick in the renderer's view; what was picked then (its material, its colour, the graph it
/// already is) with Assign (the shown graph replaces it: MaterialAssignments) and Remove, and this scene's assignments.
struct MaterialAssignButton: View {
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if model.picking { model.cancelPick() } else { model.pick() }
            } label: {
                Label(model.picking ? "Click in the view…" : "Pick", systemImage: "eyedropper")
            }
            .help("Pick a material in the renderer's view, to give it this graph")
            .popover(isPresented: Binding(get: { model.picked != nil && !model.picking }, set: { if !$0 { model.clearPick() } }), arrowEdge: .bottom) {
                if let p = model.picked { PickedMaterial(pick: p) }
            }
            if !model.sceneAssignments.isEmpty {
                Menu {
                    ForEach(model.sceneAssignments, id: \.material) { e in
                        Button("Material \(e.material): \(e.graph) — remove") { model.unassign(e.material) }
                    }
                } label: { Text("\(model.sceneAssignments.count) assigned") }
                    .frame(width: 96)
            }
        }
    }
}

struct PickedMaterial: View {
    let pick: MaterialPick
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: Double(LinearColorPicker.encode(min(pick.albedo.x, 1))), green: Double(LinearColorPicker.encode(min(pick.albedo.y, 1))),
                                blue: Double(LinearColorPicker.encode(min(pick.albedo.z, 1)))))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text("Material \(pick.material)").font(.system(size: 12, weight: .semibold))
                    Text("instance \(pick.instance) · " + String(format: "%.1f, %.1f, %.1f", pick.position.x, pick.position.y, pick.position.z))
                        .foregroundColor(.secondary)
                    if let g = pick.graph { Text("now: \(g)").foregroundColor(.orange) }
                }
            }
            if model.scene.kind == .world {
                Text("The open world's tiles keep their own materials").foregroundColor(.secondary)
            } else {
                HStack {
                    Button("Assign \(model.selectedGraph)") { model.assign(model.selectedGraph, to: pick); model.clearPick() }
                        .keyboardShortcut(.defaultAction)
                    if pick.graph != nil { Button("Remove") { model.unassign(pick.material); model.clearPick() } }
                    Button("Cancel") { model.clearPick() }
                }
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 300)
    }
}
