import AppKit
import Characters
import EngineCore
import MetalRenderer
import Physics
import Plants
import SwiftUI
import simd

/// The Terrain Editor's window: the tools and the brush on the left, the map in the middle (the terrain from above:
/// tiles to select, a double click flies the camera there, drags paint with the brush when the map's brush is on),
/// and on the right the document: layers, generator, erosion, scatter rules, water, files. Sculpting happens in the
/// main view (sculpt mode: the toolbar's Sculpt, or Tab here).
struct TerrainView: View {
    @EnvironmentObject var model: TerrainModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.name == nil {
                VStack(spacing: 12) {
                    Spacer()
                    Text("This scene's ground isn't a terrain").font(.title3)
                    Text("Terrains: the terrain workshop, the Forest, Mireland, the valley, the city and the open world.")
                        .foregroundStyle(.secondary)
                    workshopMenu.frame(width: 220)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                HSplitView {
                    TerrainTools().frame(minWidth: 250, idealWidth: 270, maxWidth: 340)
                    TerrainMapPane().frame(minWidth: 360, idealWidth: 560)
                    TerrainInspector().frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                }
            }
            Divider()
            HStack {
                Text(model.message.isEmpty ? hint : model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let h = model.status.hover {
                    Text(String(format: "x %.1f  z %.1f  height %.2f m  slope %.0f°", h.x, h.z, h.y, model.status.slope))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if model.status.cpuMs > 0 {
                    Text(String(format: "%d sectors, %.1f ms", model.status.built, model.status.cpuMs)).font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .frame(minWidth: 1000, minHeight: 620)
    }

    private var hint: String {
        model.sculpting ? "Sculpt mode: drag on the ground; Option-drag orbits, right-drag looks (WASD flies); [ ] size, Shift-[ ] strength, Ctrl inverts, Esc leaves"
            : "Sculpt (Tab) to shape the ground in the main view; the map selects tiles, double-click flies there"
    }

    private var workshopMenu: some View {
        Menu("Terrain workshop") {
            ForEach(TerrainWorkshopSettings.Size.allCases, id: \.self) { size in
                Menu(size.title) {
                    ForEach(TerrainWorkshopSettings.Base.allCases, id: \.self) { base in
                        Button(base.title) { model.showWorkshop(size: size, base: base) }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.sculpting }, set: { model.setSculpting($0) })) {
                Label("Sculpt", systemImage: "hand.draw")
            }
            .toggleStyle(.button)
            .keyboardShortcut(.tab, modifiers: [])
            .disabled(model.name == nil)
            Text(model.name ?? "No terrain").font(.headline).lineLimit(1)
            if model.isDirty { Text("edited").font(.caption).foregroundStyle(.orange) }
            Spacer()
            workshopMenu.frame(width: 170)
            Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).disabled(model.name == nil || model.busy)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - Tools and the brush

private struct TerrainTools: View {
    @EnvironmentObject var model: TerrainModel
    private let groups: [(String, [TerrainTool])] = [
        ("Sculpt", [.raise, .lower, .smooth, .flatten, .setHeight, .ramp, .noise, .terrace]),
        ("Erode and generate", [.erode, .crumble, .stamp]),
        ("Paint", [.paint, .erase, .protect, .unprotect]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.0) { title, tools in
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], spacing: 6) {
                        ForEach(tools) { tool in
                            Button { model.choose(tool) } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: tool.symbol).font(.system(size: 17))
                                    Text(tool.title).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(width: 54, height: 44)
                                .background(RoundedRectangle(cornerRadius: 6).fill(model.brush.tool == tool ? Color.accentColor.opacity(0.35)
                                                                                    : Color.secondary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help(tool.title)
                        }
                    }
                }
                Divider()
                BrushSettings()
            }
            .padding(10)
        }
    }
}

/// A labelled slider whose drag is one undo step (the document's); `value` shown by `format`.
struct TerrainSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var log = false
    var format = "%.2f"
    var onDrag: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if log {
                Slider(value: Binding(get: { Foundation.log(Double(value)) }, set: { value = Float(exp($0)) }),
                       in: Foundation.log(Double(range.lowerBound))...Foundation.log(Double(range.upperBound))) { onDrag?($0) }
            } else {
                Slider(value: Binding(get: { Double(value) }, set: { value = Float($0) }),
                       in: Double(range.lowerBound)...Double(range.upperBound)) { onDrag?($0) }
            }
        }
    }
}

private struct BrushSettings: View {
    @EnvironmentObject var model: TerrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brush: \(model.brush.tool.title)").font(.headline)
            TerrainSlider(title: "Radius", value: $model.brush.radius, range: 0.5...500, log: true, format: "%.1f m")
            TerrainSlider(title: "Strength", value: $model.brush.strength, range: 0.01...1)
            TerrainSlider(title: "Hardness", value: $model.brush.hardness, range: 0...0.95)
            TerrainSlider(title: "Spacing", value: $model.brush.spacing, range: 0.05...1)
            TerrainSlider(title: "Held still", value: $model.brush.airbrush, range: 0...30, format: "%.0f dabs/s")
            Toggle("Pen pressure", isOn: $model.brush.pressure)
            switch model.brush.tool {
            case .setHeight:
                TerrainSlider(title: "Height", value: $model.brush.height, range: -200...800, format: "%.1f m")
                if let h = model.status.hover {
                    Button("Pick the height under the cursor") { model.brush.height = Float(h.y) }
                }
            case .noise:
                TerrainSlider(title: "Feature size", value: $model.brush.noiseScale, range: 1...200, log: true, format: "%.0f m")
            case .terrace:
                TerrainSlider(title: "Step", value: $model.brush.terraceStep, range: 0.2...40, log: true, format: "%.1f m")
                TerrainSlider(title: "Sharpness", value: $model.brush.terraceSharpness, range: 0...0.95)
            case .paint:
                Picker("Layer", selection: $model.brush.layer) {
                    ForEach(Array((model.document?.layers ?? TerrainDocument.defaultLayers).enumerated()), id: \.offset) { k, l in
                        Text("\(k). \(l.name)").tag(k)
                    }
                }
            case .ramp:
                Text("Drag from where the ramp starts to where it ends: its width is the brush's.").font(.caption).foregroundStyle(.secondary)
            case .erode, .crumble:
                Text("Erosion's settings: the Erosion tab.").font(.caption).foregroundStyle(.secondary)
            case .stamp:
                Text("Stamps the generator (the Generate tab) where it is dragged.").font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - The map

private struct TerrainMapPane: View {
    @EnvironmentObject var model: TerrainModel
    @State private var drag: [SIMD2<Double>] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.mapView) { ForEach(TerrainMap.View.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 280)
                Toggle("Brush on the map", isOn: $model.mapBrush).toggleStyle(.checkbox)
                Spacer()
                if !model.selectedTiles.isEmpty {
                    Text("\(model.selectedTiles.count) tile\(model.selectedTiles.count == 1 ? "" : "s")").font(.caption)
                    Button("Clear") { model.selectedTiles = [] }.buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(6)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ZStack(alignment: .topLeading) {
                    if let map = model.map {
                        Image(decorative: map.image, scale: 1).resizable().interpolation(.medium).frame(width: side, height: side)
                        Canvas { ctx, size in overlays(ctx, size: size, map: map) }.frame(width: side, height: side)
                    } else {
                        ProgressView().frame(width: side, height: side)
                    }
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard let p = world(g.location, side: side) else { return }
                    if model.mapBrush { drag.append(p) }
                }.onEnded { g in
                    guard let p = world(g.location, side: side) else { return }
                    if model.mapBrush {
                        drag.append(p)
                        model.strokeOnMap(drag)
                        drag = []
                    } else if hypot(g.translation.width, g.translation.height) < 3, let t = model.tile(at: p) {
                        model.select(tile: t, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
                    }
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if let map = model.map { model.flyTo((map.lo + map.hi) / 2) }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(6)
            if let map = model.map {
                Text(String(format: "%.0f m across, heights %.1f ... %.1f m", map.hi.x - map.lo.x, map.low, map.high))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.bottom, 4)
            }
        }
    }

    private func world(_ point: CGPoint, side: CGFloat) -> SIMD2<Double>? {
        guard let map = model.map, side > 0 else { return nil }
        let u = Double(point.x / side), v = Double(point.y / side)
        return map.lo + (map.hi - map.lo) * SIMD2(u, v)
    }

    private func overlays(_ ctx: GraphicsContext, size: CGSize, map: TerrainMap) {
        func screen(_ p: SIMD2<Double>) -> CGPoint {
            let t = (p - map.lo) / (map.hi - map.lo)
            return CGPoint(x: t.x * size.width, y: t.y * size.height)
        }
        guard let name = model.name, let grid = TerrainDocuments.shared.entry(name)?.field.grid else { return }
        // The tiles, the selected ones filled.
        for t in map.tiles {
            let a = screen(grid.corner(t)), b = screen(grid.corner(t &+ 1))
            let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            if model.selectedTiles.contains(t) { ctx.fill(Path(rect), with: .color(.accentColor.opacity(0.25))) }
            ctx.stroke(Path(rect), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
        }
        // The camera: where it is and which way it looks.
        let c = SIMD2(model.status.camera.x, model.status.camera.z), at = screen(c)
        let yaw = Double(model.status.yaw), ahead = CGPoint(x: at.x + sin(yaw) * 18, y: at.y - cos(yaw) * 18)
        var arrow = Path()
        arrow.move(to: at)
        arrow.addLine(to: ahead)
        ctx.stroke(arrow, with: .color(.yellow), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: at.x - 4, y: at.y - 4, width: 8, height: 8)), with: .color(.yellow))
        // The brush under the cursor.
        if let h = model.status.hover {
            let p = screen(SIMD2(h.x, h.z)), r = Double(model.brush.radius) / (map.hi.x - map.lo.x) * size.width
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(.white), lineWidth: 1)
        }
        // A drag on the map with the brush.
        if drag.count > 1 {
            var path = Path()
            path.move(to: screen(drag[0]))
            for p in drag.dropFirst() { path.addLine(to: screen(p)) }
            ctx.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 2)
        }
    }
}

// MARK: - The document

private struct TerrainInspector: View {
    @EnvironmentObject var model: TerrainModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) { ForEach(TerrainModel.Tab.allCases.filter { $0 != .brush }) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).padding(6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch model.tab {
                    case .brush, .layers: LayersTab()
                    case .generate: GenerateTab()
                    case .erosion: ErosionTab()
                    case .scatter: ScatterTab()
                    case .water: WaterTab()
                    case .files: FilesTab()
                    }
                }
                .padding(10)
            }
        }
        .onAppear { if model.tab == .brush { model.tab = .layers } }
    }
}

private struct LayersTab: View {
    @EnvironmentObject var model: TerrainModel
    @State private var selected = 1

    var body: some View {
        if let d = model.document {
            Text("Layer 0 is the ground's own material; the others show by their rules where nothing is painted, and where painted as painted.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(d.layers.enumerated()), id: \.offset) { k, l in
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(Color(red: Double(l.color.x * 1.6), green: Double(l.color.y * 1.6), blue: Double(l.color.z * 1.6)))
                        .frame(width: 16, height: 16)
                    Text("\(k). \(l.name)").lineLimit(1)
                    Spacer()
                    if l.rule.enabled { Image(systemName: "function").foregroundStyle(.secondary) }
                    if !l.material.isEmpty { Image(systemName: "circle.hexagongrid").foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(selected == k ? Color.accentColor.opacity(0.25) : Color.clear).cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { selected = k; model.brush.layer = max(k, 1) }
            }
            Divider()
            if d.layers.indices.contains(selected) { LayerEditor(index: selected, layer: d.layers[selected]) }
        }
    }
}

private struct LayerEditor: View {
    @EnvironmentObject var model: TerrainModel
    let index: Int
    let layer: TerrainLayer

    private func binding<T>(_ path: WritableKeyPath<TerrainLayer, T>, _ name: String) -> Binding<T> {
        Binding(get: { layer[keyPath: path] }, set: { v in model.updateLayer(index, name) { $0[keyPath: path] = v } })
    }
    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: binding(\.name, "Rename layer"))
            if index == 0 {
                Text("The ground's own material (the scene's): its look under every other layer.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Material", selection: binding(\.material, "Layer material")) {
                    Text(layer.builtIn != nil ? "The world's own" : "Plain colour").tag("")
                    ForEach(MaterialCatalog.resolve(model.host.settings.scene.materials).names, id: \.self) { Text($0).tag($0) }
                }
                if layer.material.isEmpty && layer.builtIn == nil {
                    ColorPicker("Colour", selection: Binding(get: {
                        Color(red: Double(layer.color.x), green: Double(layer.color.y), blue: Double(layer.color.z))
                    }, set: { c in
                        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
                        model.updateLayer(index, "Layer colour") { $0.color = [Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent)] }
                    }))
                    TerrainSlider(title: "Roughness", value: binding(\.roughness, "Layer roughness"), range: 0.05...1, onDrag: drag)
                }
                TerrainSlider(title: "Texture size", value: binding(\.tileMetres, "Layer texture size"), range: 0.25...50, log: true,
                              format: "%.1f m", onDrag: drag)
                Divider()
                Toggle("By rule where unpainted", isOn: binding(\.rule.enabled, "Layer rule"))
                if layer.rule.enabled {
                    TerrainSlider(title: "Height from", value: binding(\.rule.heightMin, "Rule height"), range: -500...2000, format: "%.0f m", onDrag: drag)
                    TerrainSlider(title: "Height to", value: binding(\.rule.heightMax, "Rule height"), range: -500...10000, format: "%.0f m", onDrag: drag)
                    TerrainSlider(title: "Height fade", value: binding(\.rule.heightFade, "Rule fade"), range: 0.1...100, log: true, format: "%.1f m", onDrag: drag)
                    TerrainSlider(title: "Slope from", value: binding(\.rule.slopeMin, "Rule slope"), range: 0...90, format: "%.0f°", onDrag: drag)
                    TerrainSlider(title: "Slope to", value: binding(\.rule.slopeMax, "Rule slope"), range: 0...90, format: "%.0f°", onDrag: drag)
                    TerrainSlider(title: "Slope fade", value: binding(\.rule.slopeFade, "Rule fade"), range: 0.5...30, format: "%.1f°", onDrag: drag)
                    TerrainSlider(title: "Edge noise", value: binding(\.rule.noiseAmount, "Rule noise"), range: 0...1, onDrag: drag)
                    TerrainSlider(title: "Noise size", value: binding(\.rule.noiseScale, "Rule noise"), range: 0.5...40, log: true, format: "%.1f /100 m", onDrag: drag)
                    TerrainSlider(title: "Strength", value: binding(\.rule.strength, "Rule strength"), range: 0...1, onDrag: drag)
                }
            }
        }
    }
}

private struct FilesTab: View {
    @EnvironmentObject var model: TerrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedTiles.isEmpty ? "Over the whole terrain (an endless one: the map's tiles)" : "Over the selected tiles")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Import a heightmap") {
                VStack(alignment: .leading) {
                    Toggle("Added to the ground (mid-grey: nothing)", isOn: $model.importAdditive)
                    TerrainSlider(title: model.importAdditive ? "From" : "Black is", value: $model.importLow, range: -500...2000, format: "%.0f m")
                    TerrainSlider(title: model.importAdditive ? "To" : "White is", value: $model.importHigh, range: -500...4000, format: "%.0f m")
                    Text("16-bit PNG or EXR (EXR heights in metres as they are).").font(.caption).foregroundStyle(.secondary)
                    Button("Import heightmap…") { model.importHeights() }
                    Button("Import splat maps…") { model.importSplat() }
                }
            }
            GroupBox("Export") {
                VStack(alignment: .leading) {
                    Picker("Heights as", selection: $model.exportFormat) {
                        Text("16-bit PNG").tag(TerrainIO.Format.png16)
                        Text("EXR (metres)").tag(TerrainIO.Format.exr)
                    }
                    Text("With a JSON of where and how high, and the layers' weights as four RGBA PNGs.").font(.caption).foregroundStyle(.secondary)
                    Button("Export…") { model.export() }.disabled(model.busy)
                }
            }
        }
    }
}
