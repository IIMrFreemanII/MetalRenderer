import SwiftUI

/// The VFX editor: the effects (a menu), what to do with the shown one (new, save, Copy as Swift, the stage), its
/// graph on the canvas, the inspector of what is selected, and a line of how it runs.
struct VFXEditorView: View {
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VFXPreviewBar()
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

/// Where the effect is shown and its clock: the stage (and its backdrop) or the scene that places it; play, pause,
/// restart, a step, the speed, the timeline (dragging it scrubs: back is a replay from the start); the gizmos and the
/// stats.
struct VFXPreviewBar: View {
    @EnvironmentObject var model: VFXEditorModel
    @State private var scrubbing = false

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { model.onStage ? 0 : 1 }, set: { $0 == 0 ? model.showOnStage() : model.showInScene() })) {
                Text("Stage").tag(0)
                Text("In Scene").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            .disabled(model.placingScene == nil && model.onStage)
            .help(model.placingScene.map { "In Scene: the \($0.title) scene, which places it" } ?? "Only the stage shows this effect")
            if model.onStage {
                Menu {
                    ForEach(VFXBackdrop.allCases, id: \.self) { b in Button(b.title) { model.setBackdrop(b) } }
                } label: { Text(model.scene.stage.backdrop.title) }
                .frame(width: 90).help("The stage's backdrop")
            }
            Divider().frame(height: 18)
            Button { model.restart() } label: { Image(systemName: "backward.end.fill") }.help("Back to the start")
            Button { model.playPause() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
                .help(model.paused ? "Play (Space in the view)" : "Pause (Space in the view)")
            Button { model.stepFrame() } label: { Image(systemName: "forward.frame.fill") }.help("One step (1/60 s), paused")
            Menu {
                ForEach([Float(0.1), 0.25, 0.5, 1, 2], id: \.self) { x in Button(String(format: "%g×", x)) { model.setSpeed(x) } }
            } label: { Text(String(format: "%g×", model.timeScale)) }
            .frame(width: 56).help("Speed")
            TimelineView(.animation(minimumInterval: 1 / 30, paused: model.paused || scrubbing)) { _ in
                let t = model.time
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { Double(min(t, model.duration)) }, set: { model.setTime(Float($0)) }),
                           in: 0...Double(model.duration)) { editing in scrubbing = editing }
                        .controlSize(.small)
                    Text(String(format: "%5.2f s", t)).font(.system(size: 11).monospacedDigit()).frame(width: 58, alignment: .trailing)
                }
            }
            Menu {
                ForEach([Float(5), 10, 20, 60], id: \.self) { d in Button("\(Int(d)) s") { model.duration = d } }
            } label: { Text("\(Int(model.duration)) s") }
            .frame(width: 54).help("The timeline's length")
            Divider().frame(height: 18)
            Toggle(isOn: $model.showGizmos) { Image(systemName: "move.3d") }.toggleStyle(.button).help("Gizmos: shapes, fields, colliders; drag the selected emitter's arrows in the view")
            Toggle(isOn: $model.showStats) { Image(systemName: "chart.bar.xaxis") }.toggleStyle(.button).help("Stats")
                .popover(isPresented: $model.showStats, arrowEdge: .bottom) { VFXStatsView().environmentObject(model) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// The effect's emitters as they run: alive against capacity, fixed or generated code; the particle passes' GPU times
/// (the passes are timed while this shows) and the last compile.
struct VFXStatsView: View {
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.selectedEffect): stats").font(.system(size: 12, weight: .semibold))
            if let s = model.status {
                let mine = s.emitters.filter { $0.effect == model.selectedEffect }
                if mine.isEmpty { Text("Not in this scene").foregroundColor(.secondary) }
                ForEach(mine.indices, id: \.self) { i in
                    let e = mine[i]
                    HStack(spacing: 6) {
                        Text(e.name).frame(width: 90, alignment: .leading).lineLimit(1)
                        ProgressView(value: Double(e.alive), total: Double(max(e.capacity, 1))).frame(width: 120)
                            .tint(e.alive >= e.capacity ? .orange : .accentColor)
                        Text("\(e.alive) / \(e.capacity)").font(.system(size: 11).monospacedDigit()).frame(width: 90, alignment: .trailing)
                        Text(e.program ? "code" : "fixed").foregroundColor(e.program ? VFXColors.family(.curve) : .secondary).frame(width: 36)
                    }
                }
                Divider()
                let all = s.emitters
                Text("Scene: \(all.reduce(0) { $0 + $1.alive }) of \(all.reduce(0) { $0 + $1.capacity }) particles, \(all.count) emitters")
                    .foregroundColor(.secondary)
                if s.passMs.isEmpty {
                    Text("GPU: timing the passes…").foregroundColor(.secondary)
                } else {
                    ForEach(s.passMs.keys.sorted(), id: \.self) { k in
                        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(String(format: "%.2f ms", s.passMs[k]!)).monospacedDigit() }
                    }
                    HStack {
                        Text("all of them").fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.2f ms", s.passMs.values.reduce(0, +))).monospacedDigit().fontWeight(.medium)
                    }
                }
                if let ms = s.compileMs { Text(String(format: "Last compile of the effects' code: %.0f ms", ms)).foregroundColor(.secondary) }
            } else {
                Text("No particles in this scene").foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 380)
    }
}
