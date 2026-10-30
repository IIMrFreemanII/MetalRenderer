import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import SwiftUI

/// The plant editor: the species across the top, its graph with what's selected beside it (the workshop shows the plant as
/// it stands at that node), how its Swift stands, and
/// the workshop's controls, its plant's cost and saving at the foot.
struct PlantEditorView: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(spacing: 0) {
            speciesStrip.padding(.horizontal, 10).padding(.top, 8)
            header.padding(.horizontal, 10).padding(.vertical, 6)
            HSplitView {
                PlantGraphHost(model: model)
                    .frame(minWidth: 420, minHeight: 300)
                ScrollView {
                    Group {
                        if let id = model.focus.flatMap({ Int32($0) }), let node = model.graph.node(id) {
                            PlantNodeInspector(model: model, node: node)
                        } else {
                            PlantSpeciesInspector()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            }
            Divider()
            status.padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            footer.padding(10)
        }
        .frame(minWidth: 820, idealWidth: 1180, minHeight: 620, idealHeight: 820)
        .background(GraphColors.chrome)
        .sheet(isPresented: $model.showsSwift) { swiftSheet }
    }

    // MARK: - Its Swift

    private var status: some View {
        HStack(spacing: 8) {
            switch model.compile {
            case .idle: Image(systemName: "circle").foregroundColor(.secondary); Text("Nothing to compile")
            case .waiting: Image(systemName: "circle.dotted").foregroundColor(.secondary); Text("The graph runs")
            case .compiling: ProgressView().controlSize(.mini); Text("Compiling its Swift…")
            case .compiled(let seconds):
                Image(systemName: "checkmark.circle").foregroundColor(.green)
                Text(seconds > 0 ? String(format: "Compiled in %.1f s", seconds) : "Compiled")
            case .incomplete(let why): Image(systemName: "exclamationmark.triangle").foregroundColor(.orange); Text(why).lineLimit(1)
            case .failed(let errors):
                Image(systemName: "xmark.octagon").foregroundColor(.red)
                Text(errors.first?.message ?? "Doesn't compile").lineLimit(1)
                ForEach(errors.prefix(3).indices, id: \.self) { i in
                    if let node = errors[i].node { Button("Show") { model.show(node) }.buttonStyle(.link) }
                }
            }
            Spacer()
            stageLine
            Button("Swift") { model.showsSwift = true }.help("The file this graph compiles to")
        }
        .font(.system(size: 11))
    }

    /// What the workshop is showing, of the plant.
    @ViewBuilder private var stageLine: some View {
        if let node = model.previewed {
            let whole = model.wantedStage < 0
            HStack(spacing: 4) {
                Image(systemName: model.pinned == node.id ? "pin.fill" : "eye")
                Text(whole ? "Workshop: the whole plant" : "Workshop: \(node.kind.title) \(node.name)").lineLimit(1)
            }
            .foregroundColor(.secondary)
            .help(whole ? "This node's stage is the plant itself, or has nothing to look at" : "The plant as it stands at this node")
        }
    }

    private var swiftSheet: some View {
        let text = model.swiftText
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(model.def.id).swift").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(GraphColors.canvas)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Close") { model.showsSwift = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 720, height: 640)
    }

    // MARK: - Species

    private var speciesStrip: some View {
        HStack(spacing: 6) {
            ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.catalog.species, id: \.id) { d in
                        Button { model.select(d.id) } label: {
                            HStack(spacing: 3) {
                                Text(d.name).lineLimit(1)
                                if model.isDirty(d.id) { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(d.id == model.selected ? Color.accentColor.opacity(0.25) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .id(d.id)
                    }
                }
            }
            .onAppear { scroller.scrollTo(model.selected) }
            .onChange(of: model.selected) { id in withAnimation { scroller.scrollTo(id) } }
            }
            Menu {
                Button("New Species from \(model.def.name)…") { model.newSpecies(); askName() }
                Button("Rename \(model.def.name)…") { askName() }.disabled(model.isBuiltIn)
                Button("Reset \(model.def.name) to Built-in") { model.resetToBuiltIn() }.disabled(!model.isBuiltIn)
                Divider()
                Button("Delete \(model.def.name)") { model.deleteSpecies() }.disabled(model.isBuiltIn)
            } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).frame(width: 34)
        }
        .font(.system(size: 11))
    }

    private var header: some View {
        HStack {
            Text(model.def.name).font(.headline)
            if !model.isBuiltIn {
                Button { askName() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Rename")
            }
            if let base = model.def.basedOn { Text("from \(base)").font(.system(size: 10)).foregroundColor(.secondary) }
            Spacer()
            Text(model.def.id + ".swift").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - The foot

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.stats, model.inWorkshop {
                Text(String(format: "%@: %.1f m · %@ triangles (%@ traced, %@ leaves) · %d parts, %d twigs · built in %.0f ms",
                            s.species, s.height, count(s.triangles), count(s.traced), count(s.leafTriangles), s.parts, s.twigs, s.buildMs))
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            if model.inWorkshop { workshopControls } else {
                HStack {
                    Text("The workshop shows one plant at a time and follows every edit.").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button("Workshop") { model.goToWorkshop() }
                }
            }
            HStack {
                Button { model.undo.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.undo.canUndo).help("Undo (Cmd-Z)")
                Button { model.undo.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.undo.canRedo).help("Redo (Shift-Cmd-Z)")
                Spacer()
                if model.inWorkshop && model.forest != nil { Button("Forest") { model.goToForest() }.help("The forest, with these plants") }
                Button("Revert") { model.revert() }.disabled(model.savedDef == model.def || model.savedDef == nil)
                    .help("This species as it is saved")
                Button("Revert All") { model.revertAll() }.disabled(!model.isDirty)
                Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).disabled(!model.isDirty)
                    .help("Every changed species to Assets/Plants")
            }
            if let message = model.message {
                HStack {
                    Text(message).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                    Spacer()
                    Button { model.clearMessage() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
        }
        .font(.system(size: 11))
    }

    private var workshopControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(get: { model.scene.plants.layout }, set: { l in model.workshop { $0.layout = l } })) {
                    ForEach(PlantSceneSettings.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 140)
                Picker("", selection: Binding(get: { model.scene.plants.view }, set: { v in model.workshop { $0.view = v } })) {
                    ForEach(PlantSceneSettings.View.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Spacer()
                Button { model.frame() } label: { Image(systemName: "viewfinder") }.help("Frame the plants (F)")
            }
            if model.scene.plants.layout == .single {
                HStack {
                    Picker("Age", selection: Binding(get: { model.scene.plants.age }, set: { a in model.workshop { $0.age = a } })) {
                        ForEach(Foliage.Age.allCases, id: \.self) { Text("\($0)".capitalized).tag($0) }
                    }
                    .frame(width: 150)
                    Stepper("Variant \(model.scene.plants.variant + 1)", value: Binding(
                        get: { model.scene.plants.variant }, set: { v in model.workshop { $0.variant = v } }),
                            in: 0...max(model.def.variants(model.scene.plants.age) - 1, 0))
                    Spacer()
                }
            }
            HStack {
                // Unreal's preview: a person beside the plant, its size written out, the lights turned about it.
                Toggle("Figure", isOn: Binding(get: { model.scene.plants.figure }, set: { f in model.workshop { $0.figure = f } }))
                    .help("A person standing beside the plant, for its size")
                Toggle("Ruler", isOn: Binding(get: { model.scene.plants.ruler }, set: { r in model.workshop { $0.ruler = r } }))
                    .help("The plant's width, depth and height, in metres")
                Slider(value: Binding(get: { model.lightYaw }, set: { y in model.setLights(yaw: y.rounded()) }), in: -180...180)
                    .frame(width: 110).help("Turn the sun and sky about the plant")
                Toggle(isOn: Binding(get: { model.lightSpin }, set: { s in model.setLights(spin: s) })) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button).help("The lights turn by themselves")
            }
            HStack {
                Button { model.randomizeSeed() } label: { Label("Seed \(model.scene.plants.seed)", systemImage: "dice") }
                    .help("Other plants of the same species")
                Button { model.mutate() } label: { Label("Mutate", systemImage: "wand.and.stars") }
                    .help("Six variations of this species side by side; pick one")
                PressButton(title: "Compare", help: "Hold (or hold C): the saved plant in place of this one") { model.compare($0) }
                    .disabled(model.savedDef == model.def)
            }
            if model.scene.plants.layout == .mutate && !model.mutants.isEmpty {
                HStack(spacing: 4) {
                    Text("Use:").foregroundColor(.secondary)
                    ForEach(model.mutants.indices, id: \.self) { k in Button("\(k + 1)") { model.pick(k) } }
                    Text("(left to right after the original)").foregroundColor(.secondary).font(.system(size: 10))
                }
            }
            HStack(spacing: 6) {
                Text("Wind").frame(width: 36, alignment: .leading)
                Slider(value: Binding(get: { model.foliage.wind }, set: { w in model.setWind { $0.wind = w } }), in: 0...1).controlSize(.small)
                Text("Dir").foregroundColor(.secondary)
                Slider(value: Binding(get: { model.foliage.windDirection }, set: { d in model.setWind { $0.windDirection = d } }),
                       in: -180...180).controlSize(.small)
                Text("Gusts").foregroundColor(.secondary)
                Slider(value: Binding(get: { model.foliage.gusts }, set: { g in model.setWind { $0.gusts = g } }), in: 0...1).controlSize(.small)
            }
        }
    }

    /// A name for the selected species, asked in a dialog: the panel never takes the keyboard (the main window keeps
    /// it, for W A S D), so it can't have a text field of its own.
    private func askName() {
        guard !model.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = "Name the species"
        alert.icon = NSImage(systemSymbolName: "leaf", accessibilityDescription: nil)
        alert.informativeText = "Its file in Assets/Plants is named after it."
        let field = NSTextField(string: model.def.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != model.def.name { model.rename(name) }
    }

    private func count(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

/// A button that acts while it is held down and again when it is let go.
struct PressButton: View {
    let title: String
    let help: String
    let action: (Bool) -> Void
    @State private var down = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Text(title)
            .foregroundColor(enabled ? .primary : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(down ? Color.accentColor.opacity(0.35) : Color(nsColor: .controlColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down && enabled { down = true; action(true) } }
                .onEnded { _ in if down { down = false; action(false) } })
            .help(help)
    }
}
