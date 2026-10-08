import SwiftUI

/// The plant editor: the species across the top, the selected one's tabs below, and the workshop's controls, its
/// plant's cost and saving at the foot.
struct PlantEditorView: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(spacing: 0) {
            speciesStrip.padding(.horizontal, 10).padding(.top, 8)
            header.padding(.horizontal, 10).padding(.vertical, 6)
            Picker("", selection: $model.tab) {
                ForEach(PlantEditorModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch model.tab {
                    case .stems: StemsTab()
                    case .leaves: LeavesTab()
                    case .boughs: BoughsTab()
                    case .look: LookTab()
                    case .habitat: HabitatTab()
                    case .ages: AgesTab()
                    }
                }
                .padding(10)
            }
            Divider()
            footer.padding(10)
        }
        .frame(minWidth: 400, idealWidth: 430, minHeight: 520, idealHeight: 760)
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
                Button("New Species from \(model.def.name)") { model.newSpecies() }
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
            if model.isBuiltIn {
                Text(model.def.name).font(.headline)
            } else {
                TextField("Name", text: Binding(get: { model.def.name }, set: { model.rename($0) })).font(.headline)
                    .textFieldStyle(.plain)
            }
            if let base = model.def.basedOn { Text("from \(base)").font(.system(size: 10)).foregroundColor(.secondary) }
            Spacer()
            Text(model.def.id + ".json").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - The foot

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.stats, model.inWorkshop {
                Text(String(format: "%@: %.1f m · %@ triangles (%@ traced, %@ leaves) · %d parts, %d boughs · built in %.0f ms",
                            s.species, s.height, count(s.triangles), count(s.traced), count(s.leafTriangles), s.parts, s.boughs, s.buildMs))
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
                if model.inWorkshop { Button("Forest") { model.goToForest() }.help("The forest, with these plants") }
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
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
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
                Button { model.randomizeSeed() } label: { Label("Seed \(model.scene.plants.seed)", systemImage: "dice") }
                    .help("Other plants of the same recipe")
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
