import SwiftUI

/// The building editor: the styles across the top, the selected one's tabs below, and the workshop's controls, its
/// building's cost and saving at the foot.
struct BuildingEditorView: View {
    @EnvironmentObject var model: BuildingEditorModel
    var showPlan: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            stylesStrip.padding(.horizontal, 10).padding(.top, 8)
            header.padding(.horizontal, 10).padding(.vertical, 6)
            Picker("", selection: $model.tab) {
                ForEach(BuildingEditorModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch model.tab {
                    case .massing: MassingTab()
                    case .facade: FacadeTab()
                    case .floors: FloorsTab()
                    case .rooms: RoomsTab()
                    case .furnish: FurnishTab()
                    case .look: BuildingLookTab()
                    case .site: SiteTab()
                    }
                }
                .padding(10)
            }
            Divider()
            footer.padding(10)
        }
        .frame(minWidth: 420, idealWidth: 450, minHeight: 540, idealHeight: 780)
    }

    // MARK: - Styles

    private var stylesStrip: some View {
        HStack(spacing: 6) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.catalog.styles, id: \.id) { d in
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
                Button("New Style from \(model.def.name)…") { model.newStyle(); askName() }
                Button("Rename \(model.def.name)…") { askName() }.disabled(model.isBuiltIn)
                Button("Reset \(model.def.name) to Built-in") { model.resetToBuiltIn() }.disabled(!model.isBuiltIn)
                Divider()
                Button("Delete \(model.def.name)") { model.deleteStyle() }.disabled(model.isBuiltIn)
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
            Text(model.def.programme.use.title + " · " + model.def.id + ".json").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - The foot

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.stats, model.inWorkshop {
                Text(String(format: "%@: %d storeys, %.0f m · %d rooms, %d doors · %@ triangles outside, %@ inside · built in %.0f ms%@",
                            s.style, s.storeys, s.height, s.rooms, s.doors, count(s.shellTriangles), count(s.interiorTriangles), s.buildMs,
                            s.orphaned > 0 ? " · \(s.orphaned) edits find nothing" : ""))
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            if let w = model.walker {
                Text(walking(w)).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            if model.inWorkshop { workshopControls } else {
                HStack {
                    Text("The workshop shows one building, inside and out, and follows every edit.").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button("Workshop") { model.goToWorkshop() }
                }
            }
            HStack {
                Button { model.undo.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.undo.canUndo).help("Undo (Cmd-Z)")
                Button { model.undo.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.undo.canRedo).help("Redo (Shift-Cmd-Z)")
                Button { showPlan() } label: { Image(systemName: "square.split.2x2") }.help("The Floor Plan window")
                Spacer()
                if model.inWorkshop { Button("City") { model.goToCity() }.help("The city, with these styles") }
                Button("Revert") { model.revert() }.disabled(model.savedDef == model.def || model.savedDef == nil)
                    .help("This style as it is saved")
                Button("Revert All") { model.revertAll() }.disabled(!model.isDirty)
                Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).disabled(!model.isDirty)
                    .help("Every changed style and single building to Assets/Buildings")
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
        let p = model.workshopSettings
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(get: { p.layout }, set: { l in model.workshop { $0.layout = l } })) {
                    ForEach(BuildingSceneSettings.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Picker("", selection: Binding(get: { p.view }, set: { v in model.workshop { $0.view = v } })) {
                    ForEach(BuildingSceneSettings.View.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Spacer()
                Button { model.frame() } label: { Image(systemName: "viewfinder") }.help("Frame the building (F)")
            }
            if p.view != .full {
                HStack {
                    Stepper("Cut above floor \(p.cut)", value: Binding(get: { p.cut }, set: { c in model.workshop { $0.cut = c } }),
                            in: 0...max((model.stats?.storeys ?? 1) - 1, 0))
                    Spacer()
                }
            }
            HStack {
                Button { model.randomizeSeed() } label: { Label("Seed \(p.seed)", systemImage: "dice") }
                    .help("Another building of the same style")
                Button { model.mutate() } label: { Label("Mutate", systemImage: "wand.and.stars") }
                    .help("Six variations of this style along a street; pick one")
                PressButton(title: "Compare", help: "Hold: the saved styles in place of the edited ones") { model.compare($0) }
                    .disabled(!model.isDirty)
                Toggle("Night", isOn: Binding(get: { p.night }, set: { v in model.workshop { $0.night = v } })).toggleStyle(.checkbox)
            }
            if p.layout == .mutate && !model.mutants.isEmpty {
                HStack(spacing: 4) {
                    Text("Use:").foregroundColor(.secondary)
                    ForEach(model.mutants.indices, id: \.self) { k in Button("\(k + 1)") { model.pick(k) } }
                    Text("(left to right after the original)").foregroundColor(.secondary).font(.system(size: 10))
                }
            }
            Text("V walks in (W A S D, Space jumps, C crouches, E or a click opens doors and flips switches, F the flashlight, 0–9 in a lift).")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func walking(_ w: WalkerStatus) -> String {
        var s = String(format: "Walking at (%.1f, %.1f, %.1f)", w.position.x, w.position.y, w.position.z)
        if let storey = w.storey { s += ", floor \(storey)" }
        if w.crouched { s += ", crouched" }
        if w.flashlight { s += ", flashlight on" }
        if let m = w.message { s += " · " + m }
        return s
    }

    /// A name for the selected style, asked in a dialog (the panel never takes the keyboard).
    private func askName() {
        guard !model.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = "Name the style"
        alert.icon = NSImage(systemSymbolName: "building.2", accessibilityDescription: nil)
        alert.informativeText = "Its file in Assets/Buildings/Styles is named after it."
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
