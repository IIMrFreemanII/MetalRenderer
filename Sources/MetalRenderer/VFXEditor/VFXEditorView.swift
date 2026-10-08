import SwiftUI

/// The VFX editor: the effects (a menu), what to do with the shown one (new, save, Copy as Swift, the stage), its
/// graph on the canvas, the inspector of what is selected, and a line of how it runs.
struct VFXEditorView: View {
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                VFXCanvasView().frame(minWidth: 420)
                VFXInspector().frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
            }
            Divider()
            VFXStatusLine()
        }
        .background(VFXColors.chrome)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.effectNames, id: \.self) { name in
                    Button((model.isDirty(name) ? "• " : "") + name + (model.isEdited(name) ? "  (edited)" : "")) { model.select(name) }
                }
            } label: {
                Text((model.isDirty(model.selectedEffect) ? "• " : "") + model.selectedEffect).font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 170)
            Button { model.newEffect() } label: { Label("New", systemImage: "plus") }
            Button { model.duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if model.isBuiltIn(model.selectedEffect) {
                Button { model.resetToBuiltIn() } label: { Label("Built-in", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.isEdited(model.selectedEffect)).help("This effect as it is built in")
            } else {
                Button { model.deleteEffect() } label: { Label("Delete", systemImage: "trash") }
            }
            Divider().frame(height: 18)
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command).disabled(!model.isDirty)
            Button { model.revert() } label: { Label("Revert", systemImage: "arrow.counterclockwise") }
                .disabled(!model.isDirty(model.selectedEffect)).help("The effect as it is saved")
            Button { model.copyAsSwift() } label: { Label("Copy as Swift", systemImage: "swift") }
            Spacer()
            Button { model.frameAll(in: model.canvasSize) } label: { Label("Frame", systemImage: "rectangle.dashed") }.help("Frame the graph (F)")
            Button { model.showOnStage() } label: { Label("Show on Stage", systemImage: "theatermasks") }
                .disabled(model.onStage && model.scene.stage.effects == [model.selectedEffect])
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Where the shown effect runs and how: on the stage or in the scene (or not there), how many of its emitters run
/// generated code, the compile, and what the lowering left out.
struct VFXStatusLine: View {
    @EnvironmentObject var model: VFXEditorModel
    @State private var showNotes = false
    @State private var showFailure = false

    var body: some View {
        HStack(spacing: 10) {
            where_
            if let s = model.status {
                let mine = s.emitters.filter { $0.effect == model.selectedEffect }
                if !mine.isEmpty {
                    let code = mine.filter(\.program).count
                    let emitters = mine.count == 1 ? "1 emitter" : "\(mine.count) emitters"
                    Text(code == 0 ? "\(emitters), the fixed kernels only" : "\(emitters), \(code) with generated code")
                        .foregroundColor(.secondary)
                }
                if s.compiling {
                    ProgressView().controlSize(.mini)
                    Text("Compiling…").foregroundColor(.secondary)
                } else if let ms = s.compileMs, s.failure == nil, s.emitters.contains(where: \.program) {
                    Text(String(format: "compiled in %.0f ms", ms)).foregroundColor(.secondary)
                }
                if let failure = s.failure {
                    Button("Didn't compile") { showFailure.toggle() }
                        .foregroundColor(.red)
                        .popover(isPresented: $showFailure) {
                            ScrollView { Text(failure).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding() }
                                .frame(width: 560, height: 300)
                        }
                }
                if !s.notes.isEmpty {
                    Button("\(s.notes.count) note\(s.notes.count == 1 ? "" : "s")") { showNotes.toggle() }
                        .foregroundColor(.orange)
                        .popover(isPresented: $showNotes) {
                            VStack(alignment: .leading, spacing: 4) { ForEach(s.notes, id: \.self) { Text($0) } }.padding().frame(width: 420)
                        }
                }
            }
            Spacer()
            if let m = model.message {
                Text(m).foregroundColor(.secondary).lineLimit(1)
                Button { model.clearMessage() } label: { Image(systemName: "xmark.circle.fill") }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    @ViewBuilder
    private var where_: some View {
        if model.onStage && model.inScene {
            Label("On the VFX stage", systemImage: "theatermasks.fill").foregroundColor(.green)
        } else if model.inScene {
            Label("In the scene: \(model.scene.kind.title)", systemImage: "cube.fill").foregroundColor(.green)
        } else {
            Label("Not in this scene", systemImage: "eye.slash").foregroundColor(.secondary)
            Button("Show on Stage") { model.showOnStage() }
        }
    }
}
