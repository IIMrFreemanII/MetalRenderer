import AppKit
import Garments
import SwiftUI
import UniformTypeIdentifiers

/// The Garment Designer's window, laid out as Marvelous Designer's: the 2D pattern window on the left and the 3D avatar
/// on the right, each with its toolbar, the inspector at the right, and a status line under them.
struct GarmentView: View {
    @ObservedObject var model: GarmentModel
    @State private var split: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    VStack(spacing: 0) {
                        toolbar2D
                        PatternCanvas(model: model)
                    }
                    .frame(width: max(240, (geo.size.width - 342) * split))
                    VStack(spacing: 0) {
                        toolbar3D
                        ZStack(alignment: .bottomLeading) {
                            if let picture = model.stagePicture {
                                Image(decorative: picture, scale: 2).resizable().aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                            } else if model.stage != nil { GarmentViewport(model: model) } else { Color(GarmentTheme.canvas) }
                            Text(model.simulating ? "Simulating — Space stops" : "Still — Space simulates")
                                .font(.system(size: 11)).padding(6).foregroundColor(model.simulating ? GarmentTheme.swAccent : GarmentTheme.swDim)
                        }
                        .clipped()
                        .background(GeometryReader { g in
                            Color.clear.onAppear { model.viewportRect = g.frame(in: .global) }.onChange(of: g.size) { model.viewportRect = g.frame(in: .global) }
                        })
                    }
                    .frame(width: max(240, (geo.size.width - 342) * (1 - split)))
                    GarmentInspector(model: model).frame(width: 340)
                }
            }
            statusBar
        }
        .background(GarmentTheme.swWindow)
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text(model.garment.name + (model.dirty ? " •" : "")).font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu("Open") {
                ForEach(GarmentStore.list(), id: \.self) { id in Button(id) { model.open(id) } }
            }.frame(width: 80)
            Button("Save") { model.save() }.keyboardShortcut("s")
            Button("Export…") { exportPanel() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(GarmentTheme.swPanel)
    }

    private var toolbar2D: some View {
        HStack(spacing: 2) {
            ForEach(GarmentModel.Tool.allCases.filter { $0 != .trace }) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol).frame(width: 26, height: 22)
                        .background(model.tool == t ? GarmentTheme.swAccent.opacity(0.35) : Color.clear).cornerRadius(4)
                }
                .buttonStyle(.plain).help(t.title)
            }
            Spacer()
            Button { model.frame() } label: { Image(systemName: "viewfinder") }.buttonStyle(.plain).help("Frame the pattern (Shift-F)")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(GarmentTheme.swPanel)
    }

    private var toolbar3D: some View {
        HStack(spacing: 8) {
            Button { model.toggleSimulation() } label: {
                Image(systemName: model.simulating ? "pause.fill" : "play.fill").frame(width: 26, height: 22)
                    .background(model.simulating ? GarmentTheme.swAccent.opacity(0.35) : Color.clear).cornerRadius(4)
            }.buttonStyle(.plain).help("Simulate (Space)")
            Button { model.resetDrape() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).help("Sew again from the arrangement")
            Button { model.tool = .trace } label: {
                Image(systemName: GarmentModel.Tool.trace.symbol).frame(width: 26, height: 22)
                    .background(model.tool == .trace ? GarmentTheme.swAccent.opacity(0.35) : Color.clear).cornerRadius(4)
            }.buttonStyle(.plain).help(GarmentModel.Tool.trace.title)
            Spacer()
            Button("Front") { model.view(0) }.buttonStyle(.plain)
            Button("Side") { model.view(.pi / 2) }.buttonStyle(.plain)
            Button("Back") { model.view(.pi) }.buttonStyle(.plain)
            Picker("", selection: Binding(get: { model.avatar }, set: { model.setAvatar($0) })) {
                ForEach(GarmentAvatars.names(), id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 120)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(GarmentTheme.swPanel)
    }

    private var statusBar: some View {
        HStack {
            Text(model.message.isEmpty ? model.tool.title : model.message).lineLimit(1)
            Spacer()
            if let r = model.report {
                Text("\(r.particles) particles · \(r.colours) colours · \(String(format: "%.1f s", r.sewTime))")
            }
        }
        .font(.system(size: 11)).foregroundColor(GarmentTheme.swDim)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(GarmentTheme.swPanel)
    }

    private func exportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = GarmentStore.id(for: model.garment.name) + ".dxf"
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data, UTType(filenameExtension: "obj") ?? .data,
                                     UTType(filenameExtension: "glb") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.message = "The flat pattern as .dxf, or the draped garment as .obj or .glb"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }
}
