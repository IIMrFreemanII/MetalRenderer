import SwiftUI

/// The character editor: the characters across the top, the selected one's tabs below, and the workshop's controls,
/// its character's cost and saving at the foot.
struct CharacterEditorView: View {
    @EnvironmentObject var model: CharacterEditorModel
    @State private var clips: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            strip.padding(.horizontal, 10).padding(.top, 8)
            header.padding(.horizontal, 10).padding(.vertical, 6)
            Picker("", selection: $model.tab) {
                ForEach(CharacterEditorModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch model.tab {
                    case .body:
                        CharacterGroup(title: "Body", groups: [.macro], table: CharacterParams.macro)
                        CharacterGroup(title: "Shape", groups: [.shape], table: CharacterParams.shape)
                    case .face:
                        expressions
                        ForEach(CharacterParams.faceSections, id: \.self) { section in
                            CharacterGroup(title: section, groups: [.face], table: CharacterParams.face.filter { $0.section == section },
                                           ownSliders: true)
                        }
                    case .proportions:
                        CharacterGroup(title: "Bone lengths and sizes", groups: [.bones], table: CharacterParams.bones)
                    case .skin:
                        CharacterGroup(title: "Skin", groups: [.skin], table: CharacterParams.skin)
                        hairStyle
                        CharacterGroup(title: "Hair colour and cut", groups: [.hair], table: CharacterParams.hair)
                    }
                }
                .padding(10)
            }
            Divider()
            footer.padding(10)
        }
        .frame(minWidth: 400, idealWidth: 430, minHeight: 520, idealHeight: 760)
        .onAppear {
            // The library's clips, for the pose menu (the kit may take seconds to make the first time: not here).
            DispatchQueue.global(qos: .userInitiated).async {
                let names = CharacterKit.shared()?.clips.map(\.name) ?? []
                DispatchQueue.main.async { clips = names }
            }
        }
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.catalog.characters, id: \.id) { d in
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
                    }
                }
            }
            Menu {
                Button("New Character from \(model.dna.name)…") { model.newCharacter(); askName() }
                Button("Rename \(model.dna.name)…") { askName() }.disabled(model.isBuiltIn)
                Button("Reset \(model.dna.name) to Built-in") { model.resetToBuiltIn() }.disabled(!model.isBuiltIn)
                Divider()
                Button("Delete \(model.dna.name)") { model.deleteCharacter() }.disabled(model.isBuiltIn)
            } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).frame(width: 34)
        }
        .font(.system(size: 11))
    }

    private var header: some View {
        HStack {
            Text(model.dna.name).font(.headline)
            if !model.isBuiltIn {
                Button { askName() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Rename")
            }
            if let base = model.dna.basedOn { Text("from \(base)").font(.system(size: 10)).foregroundColor(.secondary) }
            Spacer()
            Button { model.randomize(CharacterParam.Group.allCases) } label: { Label("Randomize all", systemImage: "dice") }
                .buttonStyle(.borderless).font(.system(size: 11)).help("Every unlocked slider at random")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.stats, model.inWorkshop {
                Text(String(format: "%@: %.2f m · %d vertices, %d triangles · made in %.0f ms", s.name, s.height, s.vertices, s.triangles, s.buildMs))
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            if model.inWorkshop { workshopControls } else {
                HStack {
                    Text("The workshop shows the character and follows every edit.").font(.system(size: 11)).foregroundColor(.secondary)
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
                Button("Revert") { model.revert() }.disabled(model.savedDNA == model.dna || model.savedDNA == nil)
                    .help("This character as it is saved")
                Button("Revert All") { model.revertAll() }.disabled(!model.isDirty)
                Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).disabled(!model.isDirty)
                    .help("Every changed character to Assets/CharacterDefs")
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

    /// The Face tab's preview: what the workshop's faces do, whether their eyes follow the camera, and the close-up.
    private var expressions: some View {
        let w = model.scene.characterWorkshop
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Expression", selection: Binding(get: { w.expression }, set: { e in model.workshop { $0.expression = e } })) {
                    ForEach(FaceExpression.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 230)
                Spacer()
                Button("Close-up") { model.workshop { $0.view = .face }; model.frame() }.disabled(!model.inWorkshop || w.view == .face)
                    .help("The workshop's camera on the face")
            }
            Toggle("Eyes follow the camera", isOn: Binding(get: { w.lookAt }, set: { on in model.workshop { $0.lookAt = on } }))
            Text("Every face blinks; each slider moves both sides alike.").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .disabled(!model.inWorkshop)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// The hair's style and the beard (CharacterHair's lists), each with a lock, and how the workshop draws hair.
    private var hairStyle: some View {
        let w = model.scene.characterWorkshop
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hair").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { w.hair }, set: { m in model.workshop { $0.hair = m } })) {
                    ForEach(CharacterSceneSettings.HairMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190).disabled(!model.inWorkshop)
                .help("Strands (each hair), the caps crowds have, or none")
            }
            lockedPicker("Style", id: CharacterParams.hairStyleID, value: \.hair.style, options: CharacterHair.styles.map { ($0.id, $0.title) })
            lockedPicker("Beard", id: CharacterParams.beardID, value: \.hair.beard, options: CharacterHair.beards.map { ($0.id, $0.title) })
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func lockedPicker(_ title: String, id: String, value: WritableKeyPath<CharacterDNA, String>,
                              options: [(id: String, title: String)]) -> some View {
        HStack(spacing: 4) {
            Button { model.toggleLock(id) } label: {
                Image(systemName: model.isLocked(id) ? "lock.fill" : "lock.open").foregroundColor(model.isLocked(id) ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless).frame(width: 16).help("Locked: Randomize leaves it alone")
            Picker(title, selection: Binding(get: { model.dna[keyPath: value] }, set: { v in var d = model.dna; d[keyPath: value] = v; model.dna = d })) {
                ForEach(options, id: \.id) { Text($0.title).tag($0.id) }
            }
        }
    }

    private var workshopControls: some View {
        let w = model.scene.characterWorkshop
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(get: { w.layout }, set: { l in model.workshop { $0.layout = l } })) {
                    ForEach(CharacterSceneSettings.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Picker("", selection: Binding(get: { w.view }, set: { v in model.workshop { $0.view = v }; model.frame() })) {
                    ForEach(CharacterSceneSettings.View.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                Spacer()
                Button { model.frame() } label: { Image(systemName: "viewfinder") }.help("Frame the character (F)")
            }
            HStack {
                Picker("Pose", selection: Binding(get: { w.pose }, set: { p in model.workshop { $0.pose = p } })) {
                    ForEach(CharacterSceneSettings.Pose.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 150)
                if w.pose == .clip {
                    Picker("", selection: Binding(get: { w.clip }, set: { c in model.workshop { $0.clip = c } })) {
                        ForEach(clips, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                Spacer()
            }
            HStack {
                Button { model.mutate() } label: { Label("Mutate", systemImage: "wand.and.stars") }
                    .help("Five variations of this character side by side; pick one")
                PressButton(title: "Compare", help: "Hold (or hold C): the saved character in place of this one") { model.compare($0) }
                    .disabled(model.savedDNA == model.dna)
            }
            if w.layout == .mutate && !model.mutants.isEmpty {
                HStack(spacing: 4) {
                    Text("Use:").foregroundColor(.secondary)
                    ForEach(model.mutants.indices, id: \.self) { k in Button("\(k + 1)") { model.pick(k) } }
                    Text("(left to right after the original)").foregroundColor(.secondary).font(.system(size: 10))
                }
            }
        }
    }

    /// A name for the selected character, asked in a dialog (the panel never takes the keyboard).
    private func askName() {
        guard !model.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = "Name the character"
        alert.icon = NSImage(systemSymbolName: "person", accessibilityDescription: nil)
        alert.informativeText = "Its file in Assets/CharacterDefs is named after it."
        let field = NSTextField(string: model.dna.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != model.dna.name { model.rename(name) }
    }
}

/// A group of the DNA's sliders, each with a lock, and a button that draws the group's unlocked ones at random.
struct CharacterGroup: View {
    let title: String
    let groups: [CharacterParam.Group]
    let table: [CharacterParam]
    /// Its dice draws only its own sliders (a section of the face), not its groups' all.
    var ownSliders = false
    @EnvironmentObject var model: CharacterEditorModel

    var body: some View {
        let dna = Binding(get: { model.dna }, set: { model.dna = $0 })
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button { if ownSliders { model.randomize(only: table.map(\.id)) } else { model.randomize(groups) } } label: { Image(systemName: "dice") }
                    .buttonStyle(.borderless).help("These sliders at random (the unlocked ones)")
            }
            ForEach(table.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Button { model.toggleLock(table[i].id) } label: {
                        Image(systemName: model.isLocked(table[i].id) ? "lock.fill" : "lock.open")
                            .foregroundColor(model.isLocked(table[i].id) ? .accentColor : .secondary)
                    }
                    .buttonStyle(.borderless).frame(width: 16).help("Locked: Randomize and Mutate leave it alone")
                    ParamRow(param: table[i].param, root: dna)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
