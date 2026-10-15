import AppKit
import SwiftUI

/// The Material Painter's window: the layers on the left (each its thumbnail, visibility, blend, opacity, mask), the
/// texture set in the middle (a channel of it, the UV layout over it), and on the right the selected layer's
/// properties, the brush and tool, and the set's. Painting happens in the main view (paint mode: the toolbar's
/// Paint, or Tab here).
struct PainterView: View {
    @EnvironmentObject var model: PainterModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                LayerList().frame(minWidth: 250, idealWidth: 280, maxWidth: 360)
                TextureSetView().frame(minWidth: 360, idealWidth: 560)
                PainterInspector().frame(minWidth: 290, idealWidth: 330, maxWidth: 420)
            }
            Divider()
            HStack {
                Text(model.message.isEmpty ? hint : model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    private var hint: String {
        model.painting ? "Paint mode: drag to paint, right-drag or Option-drag orbits, scroll zooms, [ ] brush size, Esc leaves"
            : "Pick an object in the view, or show one in the painter workshop; then Paint (Tab)"
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(model.picking ? "Cancel pick" : "Pick object") { model.picking ? model.cancelPick() : model.pickObject() }
            Menu("Workshop") {
                ForEach(PainterWorkshopSettings.Subject.allCases, id: \.self) { s in Button(s.title) { model.showInWorkshop(s) } }
            }
            .frame(width: 110)
            Picker("", selection: Binding(get: { model.object ?? -1 }, set: { model.object = $0 < 0 ? nil : $0 })) {
                if model.status.objects.isEmpty { Text("Nothing painted").tag(-1) }
                ForEach(model.status.objects, id: \.index) { o in Text(o.document).tag(o.index) }
            }
            .frame(width: 260)
            Divider().frame(height: 18)
            Toggle(isOn: Binding(get: { model.painting }, set: { model.setPaintMode($0) })) { Label("Paint", systemImage: "paintbrush.pointed") }
                .toggleStyle(.button)
                .keyboardShortcut(.tab, modifiers: [])
                .disabled(model.object == nil)
            Picker("", selection: $model.tool) { ForEach(PaintTool.allCases) { Text($0.title).tag($0) } }.frame(width: 140)
            Toggle("Eraser", isOn: $model.brush.eraser).toggleStyle(.button)
            Spacer()
            Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).disabled(model.document == nil)
            Picker("", selection: $model.exportFormat) {
                ForEach(MatExport.Format.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 120)
            Button("Export…") { model.export() }.disabled(model.document == nil)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// The layers, top first, as Painter lists them.
private struct LayerList: View {
    @EnvironmentObject var model: PainterModel

    var body: some View {
        VStack(spacing: 0) {
            if let d = model.document {
                List(selection: Binding(get: { model.selectedLayer }, set: { model.selectLayer($0) })) {
                    ForEach(d.layers.reversed()) { layer in LayerRow(layer: layer).tag(layer.id) }
                }
                .listStyle(.inset)
            } else {
                Spacer()
                Text("No painted object").foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("Fill layer") { model.addFill() }
                    Button("Paint layer") { model.addPaint() }
                    Button("The object as it was") { model.addOriginal() }
                    Divider()
                    ForEach(SmartMaterial.all()) { m in Button(m.name) { model.addSmart(m) } }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).frame(width: 34)
                Button { model.duplicateLayer() } label: { Image(systemName: "plus.square.on.square") }
                Button { model.moveLayer(1) } label: { Image(systemName: "arrow.up") }
                Button { model.moveLayer(-1) } label: { Image(systemName: "arrow.down") }
                Spacer()
                Button { model.deleteLayer() } label: { Image(systemName: "trash") }.disabled(model.selectedLayer == nil)
            }
            .buttonStyle(.borderless)
            .padding(6)
            .disabled(model.document == nil)
        }
    }
}

private struct LayerRow: View {
    @EnvironmentObject var model: PainterModel
    let layer: PaintLayer

    var body: some View {
        HStack(spacing: 6) {
            Button { model.updateLayer(layer.id, layer.visible ? "Hide layer" : "Show layer") { $0.visible.toggle() } } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).lineLimit(1)
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if layer.mask != nil {
                Image(systemName: layer.mask?.generator != nil ? "wand.and.stars" : "circle.lefthalf.filled").foregroundStyle(.secondary)
            }
        }
    }

    private var thumbnail: some View {
        Group {
            if let t = model.thumbnails[layer.id] {
                Image(decorative: t, scale: 1).resizable().interpolation(.medium)
            } else {
                Rectangle().fill(Color(red: Double(layer.values.color.x), green: Double(layer.values.color.y), blue: Double(layer.values.color.z)))
            }
        }
        .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var summary: String {
        let kind = layer.kind == .paint ? "Paint" : layer.graph.map { "Fill: \($0)" } ?? "Fill"
        return "\(kind) · \(layer.blend.title) · \(Int(layer.opacity * 100))%"
    }
}

/// The texture set: a channel of it (the renderer's picture), the layout's triangles over it.
private struct TextureSetView: View {
    @EnvironmentObject var model: PainterModel
    @State private var showWires = true
    @State private var zoom: CGFloat = 1

    private let views = [("basecolor", "Base colour"), ("orm", "Occlusion · roughness · metallic"), ("normal", "Normal"), ("height", "Height"),
                         ("emissive", "Emissive"), ("opacity", "Opacity"), ("occlusion", "Bake: occlusion"),
                         ("curvature", "Bake: curvature"), ("thickness", "Bake: thickness")]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.view) { ForEach(views, id: \.0) { Text($0.1).tag($0.0) } }
                    .frame(width: 240)
                    .onChange(of: model.view) { _ in model.refreshPictures() }
                Toggle("UVs", isOn: $showWires)
                Slider(value: $zoom, in: 1...4).frame(width: 100)
                Spacer()
                if let o = model.currentObject {
                    Text("\(o.resolution)² · \(o.triangles) triangles · \(o.charts) \(o.ownUVs ? "islands (own UVs)" : "charts (unwrapped)")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            GeometryReader { g in
                ScrollView([.horizontal, .vertical]) {
                    let side = min(g.size.width, g.size.height) * zoom
                    ZStack {
                        Rectangle().fill(Color(white: 0.12))
                        if let p = model.picture { Image(decorative: p, scale: 1).resizable().interpolation(.medium) }
                        if showWires { Wireframe(corners: model.status.wireframe).stroke(Color.white.opacity(0.35), lineWidth: 0.5) }
                    }
                    .frame(width: side, height: side)
                    .frame(minWidth: g.size.width, minHeight: g.size.height)
                }
            }
        }
    }
}

private struct Wireframe: Shape {
    let corners: [SIMD2<Float>]
    func path(in r: CGRect) -> Path {
        var p = Path()
        func pt(_ v: SIMD2<Float>) -> CGPoint { CGPoint(x: r.minX + CGFloat(v.x) * r.width, y: r.minY + CGFloat(v.y) * r.height) }
        for t in stride(from: 0, to: corners.count - 2, by: 3) {
            p.move(to: pt(corners[t])); p.addLine(to: pt(corners[t + 1])); p.addLine(to: pt(corners[t + 2])); p.closeSubpath()
        }
        return p
    }
}

/// The right pane: the selected layer, the brush, the set.
private struct PainterInspector: View {
    @EnvironmentObject var model: PainterModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { Text("Layer").tag(0); Text("Brush").tag(1); Text("Texture set").tag(2) }
                .pickerStyle(.segmented).padding(6)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case 0: LayerInspector()
                    case 1: BrushInspector()
                    default: SetInspector()
                    }
                }
                .padding(10)
            }
        }
    }
}

/// A slider of one undo step a drag.
private struct Row: View {
    @EnvironmentObject var model: PainterModel
    let title: String
    let value: Float
    let range: ClosedRange<Float>
    let set: (Float) -> Void

    var body: some View {
        HStack {
            Text(title).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: Double(range.lowerBound)...Double(range.upperBound),
                   onEditingChanged: { $0 ? model.beginDrag() : model.endDrag() })
            Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

private func colourBinding(_ get: @escaping () -> SIMD3<Float>, _ set: @escaping (SIMD3<Float>) -> Void) -> Binding<Color> {
    Binding(get: {
        let c = get()
        // Shown in sRGB.
        func s(_ x: Float) -> Double { Double(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) }
        return Color(.sRGB, red: s(c.x), green: s(c.y), blue: s(c.z), opacity: 1)
    }, set: { color in
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
        func l(_ x: CGFloat) -> Float { let v = Float(x); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        set(SIMD3(l(ns.redComponent), l(ns.greenComponent), l(ns.blueComponent)))
    })
}

/// The values a layer (or the brush) has: colour, roughness, metallic, height, emissive, opacity, for the channels
/// it writes.
private struct ValuesEditor: View {
    @EnvironmentObject var model: PainterModel
    let values: PaintValues
    let channels: Set<PaintChannel>
    let set: (_ name: String, _ change: @escaping (inout PaintValues) -> Void) -> Void

    var body: some View {
        if channels.contains(.color) {
            ColorPicker("Colour", selection: colourBinding({ values.color }, { c in set("Colour") { $0.color = c } }), supportsOpacity: false)
        }
        if channels.contains(.roughness) { Row(title: "Roughness", value: values.roughness, range: 0...1) { v in set("Roughness") { $0.roughness = v } } }
        if channels.contains(.metallic) { Row(title: "Metallic", value: values.metallic, range: 0...1) { v in set("Metallic") { $0.metallic = v } } }
        if channels.contains(.height) { Row(title: "Height", value: values.height, range: 0...1) { v in set("Height") { $0.height = v } } }
        if channels.contains(.emissive) {
            ColorPicker("Emissive", selection: colourBinding({ values.emissive }, { c in set("Emissive") { $0.emissive = c } }), supportsOpacity: false)
        }
        if channels.contains(.opacity) { Row(title: "Opacity", value: values.opacity, range: 0...1) { v in set("Opacity") { $0.opacity = v } } }
    }
}

private struct ChannelToggles: View {
    let channels: Set<PaintChannel>
    let set: (Set<PaintChannel>) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading) {
            ForEach(PaintChannel.allCases) { c in
                Toggle(c.title, isOn: Binding(get: { channels.contains(c) }, set: { on in
                    var s = channels
                    if on { s.insert(c) } else { s.remove(c) }
                    set(s)
                }))
            }
        }
    }
}

private struct LayerInspector: View {
    @EnvironmentObject var model: PainterModel

    var body: some View {
        if let l = model.selected {
            let id = l.id
            TextField("Name", text: Binding(get: { l.name }, set: { n in model.updateLayer(id, "Rename layer") { $0.name = n } }))
            Text(l.kind == .paint ? "Paint layer: what the brush puts there" : "Fill layer: values or a graph, through its mask")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Blend", selection: Binding(get: { l.blend }, set: { b in model.updateLayer(id, "Blend") { $0.blend = b } })) {
                ForEach(PaintBlend.allCases) { Text($0.title).tag($0) }
            }
            Picker("Height", selection: Binding(get: { l.heightBlend }, set: { b in model.updateLayer(id, "Height blend") { $0.heightBlend = b } })) {
                ForEach(PaintHeightBlend.allCases) { Text($0.title).tag($0) }
            }
            Row(title: "Opacity", value: l.opacity, range: 0...1) { v in model.updateLayer(id, "Layer opacity") { $0.opacity = v } }
            Text("Channels").font(.headline)
            ChannelToggles(channels: l.channels) { s in model.updateLayer(id, "Channels") { $0.channels = s } }
            if l.kind == .fill {
                Text("Fill").font(.headline)
                Picker("Graph", selection: Binding(get: { l.graph ?? "" }, set: { g in model.updateLayer(id, "Fill graph") { $0.graph = g.isEmpty ? nil : g } })) {
                    Text("Values").tag("")
                    ForEach(MaterialLibrary.names, id: \.self) { Text($0).tag($0) }
                }
                if l.graph != nil {
                    Picker("Projection", selection: Binding(get: { l.projection }, set: { p in model.updateLayer(id, "Projection") { $0.projection = p } })) {
                        ForEach(PaintLayer.Projection.allCases) { Text($0.title).tag($0) }
                    }
                    Row(title: "Tiles / m", value: l.tiling, range: 0.1...8) { v in model.updateLayer(id, "Tiling") { $0.tiling = v } }
                } else {
                    ValuesEditor(values: l.values, channels: l.channels) { name, change in model.updateLayer(id, name) { change(&$0.values) } }
                }
            }
            Divider()
            MaskEditor(layer: l)
        } else {
            Text("No layer selected").foregroundStyle(.secondary)
        }
    }
}

private struct MaskEditor: View {
    @EnvironmentObject var model: PainterModel
    let layer: PaintLayer

    var body: some View {
        let id = layer.id
        Text("Mask").font(.headline)
        if let m = layer.mask {
            HStack {
                Button("White") { model.updateLayer(id, "Mask white") { $0.mask?.base = 1 } }
                Button("Black") { model.updateLayer(id, "Mask black") { $0.mask?.base = 0 } }
                Spacer()
                Button("Remove") { model.setMask(id, base: nil) }
            }
            Toggle("Paint on the mask", isOn: Binding(get: { model.paintsMask }, set: { model.paintsMask = $0; model.sendBrush() }))
            Picker("Generator", selection: Binding(get: { m.generator?.kind }, set: { k in
                model.setGenerator(id, k.map { kind in var g = m.generator ?? PaintGenerator(); g.kind = kind; return g })
            })) {
                Text("None").tag(PaintGenerator.Kind?.none)
                ForEach(PaintGenerator.Kind.allCases) { Text($0.title).tag(Optional($0)) }
            }
            if let g = m.generator {
                Row(title: "Amount", value: g.amount, range: 0...1) { v in model.setGenerator(id, { var c = g; c.amount = v; return c }()) }
                Row(title: "Contrast", value: g.contrast, range: 0...1) { v in model.setGenerator(id, { var c = g; c.contrast = v; return c }()) }
                Row(title: "Scale / m", value: g.scale, range: 0.5...40) { v in model.setGenerator(id, { var c = g; c.scale = v; return c }()) }
                Stepper("Seed \(g.seed)", value: Binding(get: { g.seed }, set: { s in model.setGenerator(id, { var c = g; c.seed = s; return c }()) }))
                Toggle("Invert", isOn: Binding(get: { g.invert }, set: { v in model.setGenerator(id, { var c = g; c.invert = v; return c }()) }))
                if g.kind == .graph {
                    Picker("Graph", selection: Binding(get: { g.graph }, set: { n in model.setGenerator(id, { var c = g; c.graph = n; return c }()) })) {
                        ForEach(MaterialLibrary.names, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Its Mesh Map nodes read this object's bakes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Button("Add white mask") { model.setMask(id, base: 1) }
                Button("Add black mask") { model.setMask(id, base: 0) }
            }
        }
    }
}

private struct BrushInspector: View {
    @EnvironmentObject var model: PainterModel

    var body: some View {
        let b = model.brush
        Text("Tip").font(.headline)
        Row(title: "Size", value: b.size, range: 1...300) { model.brush.size = $0 }
        Row(title: "Hardness", value: b.hardness, range: 0...1) { model.brush.hardness = $0 }
        Row(title: "Opacity", value: b.opacity, range: 0...1) { model.brush.opacity = $0 }
        Row(title: "Flow", value: b.flow, range: 0.01...1) { model.brush.flow = $0 }
        Row(title: "Spacing", value: b.spacing, range: 0.02...2) { model.brush.spacing = $0 }
        Picker("Stamp", selection: $model.brush.stamp) {
            Text("Round").tag(-1)
            ForEach(Array(PaintStamps.builtIn.enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
        }
        Row(title: "Angle", value: b.angle, range: -180...180) { model.brush.angle = $0 }
        Toggle("Follow the stroke", isOn: $model.brush.followStroke)
        Row(title: "Angle jitter", value: b.angleJitter, range: 0...180) { model.brush.angleJitter = $0 }
        Row(title: "Size jitter", value: b.sizeJitter, range: 0...1) { model.brush.sizeJitter = $0 }
        Row(title: "Scatter", value: b.scatter, range: 0...2) { model.brush.scatter = $0 }
        Row(title: "Squash", value: b.aspect, range: 0.1...1) { model.brush.aspect = $0 }
        Toggle("Pressure: size", isOn: $model.brush.pressureSize)
        Toggle("Pressure: opacity", isOn: $model.brush.pressureOpacity)
        Picker("Symmetry", selection: $model.brush.symmetry) { ForEach(PaintBrush.Symmetry.allCases) { Text($0.title).tag($0) } }
        Divider()
        Text("Paints").font(.headline)
        ChannelToggles(channels: b.channels) { model.brush.channels = $0 }
        ValuesEditor(values: b.values, channels: b.channels) { _, change in change(&model.brush.values) }
        Divider()
        Text("Stencil").font(.headline)
        Toggle("Paint through a stencil", isOn: $model.brush.stencil.enabled)
        if b.stencil.enabled {
            HStack {
                TextField("Image or graph:<name>", text: $model.brush.stencil.image)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg, .tiff]
                    if panel.runModal() == .OK, let url = panel.url { model.brush.stencil.image = url.path }
                }
            }
            Row(title: "Scale", value: b.stencil.scale, range: 0.1...4) { model.brush.stencil.scale = $0 }
            Row(title: "Turn", value: b.stencil.rotation, range: -180...180) { model.brush.stencil.rotation = $0 }
            Row(title: "Offset X", value: b.stencil.offset.x, range: -1...1) { model.brush.stencil.offset.x = $0 }
            Row(title: "Offset Y", value: b.stencil.offset.y, range: -1...1) { model.brush.stencil.offset.y = $0 }
        }
    }
}

private struct SetInspector: View {
    @EnvironmentObject var model: PainterModel
    @State private var smartName = "My smart material"

    var body: some View {
        if let d = model.document {
            Picker("Resolution", selection: Binding(get: { d.resolution }, set: { r in model.setSet("Resolution") { $0.resolution = r } })) {
                ForEach(PaintDocument.resolutions, id: \.self) { Text("\($0) × \($0)").tag($0) }
            }
            if d.resolution >= 4096 { Text("4K: four times the memory and time of 2K.").font(.caption).foregroundStyle(.orange) }
            Row(title: "Height depth", value: d.heightDepth * 1000, range: 0.5...20) { v in model.setSet("Height depth") { $0.heightDepth = v / 1000 } }
            Text("millimetres from the surface to height 1").font(.caption).foregroundStyle(.secondary)
            Toggle("Parallax", isOn: Binding(get: { d.parallax }, set: { v in model.setSet("Parallax") { $0.parallax = v } }))
            Row(title: "Normal", value: d.normalStrength, range: 0...3) { v in model.setSet("Normal strength") { $0.normalStrength = v } }
            Row(title: "Occlusion", value: d.aoStrength, range: 0...1) { v in model.setSet("Occlusion") { $0.aoStrength = v } }
            Row(title: "Emission", value: d.emissiveIntensity, range: 0...40) { v in model.setSet("Emission") { $0.emissiveIntensity = v } }
            Row(title: "Cut-off", value: d.alphaCutoff, range: 0.05...0.95) { v in model.setSet("Cut-off") { $0.alphaCutoff = v } }
            Divider()
            Text("Smart material").font(.headline)
            HStack {
                TextField("Name", text: $smartName)
                Button("Save fills") { model.saveSmart(smartName) }
            }
            Text("The fill layers, their masks and generators, to drop on other objects.").font(.caption).foregroundStyle(.secondary)
            if let o = model.currentObject {
                Divider()
                Text("Instance \(o.instance), \(o.baked ? "mesh maps baked" : "mesh maps bake with the first generator")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No painted object").foregroundStyle(.secondary)
        }
    }
}
