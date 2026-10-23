import AppKit
import Modeling
import SwiftUI
import simd

/// The right-hand column: the Outliner over the Properties editor (its tabs down the left: Object, Modifiers,
/// Material, Data).
struct ModelingSidebar: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        VStack(spacing: 1) {
            Outliner().frame(height: 200)
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(ModelingModel.PropertiesTab.allCases) { t in
                        Button { model.propertiesTab = t } label: {
                            Image(systemName: t.symbol).font(.system(size: 12))
                                .foregroundColor(model.propertiesTab == t ? BlenderTheme.text : BlenderTheme.textDim)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 4).fill(model.propertiesTab == t ? BlenderTheme.panel : .clear))
                        }
                        .buttonStyle(.plain)
                        .help(t.title)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .frame(width: 32)
                .background(BlenderTheme.window)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.activeObject == nil {
                            Text("No active object").font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim).padding()
                        } else {
                            switch model.propertiesTab {
                            case .object: ObjectProperties()
                            case .modifiers: ModifierProperties()
                            case .material: MaterialProperties()
                            case .data: DataProperties()
                            }
                        }
                    }
                    .padding(6)
                }
                .background(BlenderTheme.region)
            }
        }
        .background(BlenderTheme.window)
    }
}

// MARK: - Outliner

struct Outliner: View {
    @EnvironmentObject var model: ModelingModel
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.indent").font(.system(size: 11)).foregroundColor(BlenderTheme.textDim)
                Text("Outliner").font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(BlenderTheme.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(symbol: "shippingbox", title: model.document.name, selected: false, active: false, indent: 0)
                    ForEach(model.document.objects) { o in objectRow(o) }
                }
            }
            .background(BlenderTheme.region)
        }
    }

    private func objectRow(_ o: ModelObject) -> some View {
        let selected = model.document.selection.contains(o.id)
        let active = model.activeObject?.id == o.id
        return HStack(spacing: 4) {
            Rectangle().fill(.clear).frame(width: 14)
            Image(systemName: "triangle").font(.system(size: 10)).foregroundColor(BlenderTheme.orange)
            if renaming == o.id {
                TextField("", text: $newName, onCommit: { model.rename(o.id, to: newName); renaming = nil })
                    .textFieldStyle(.plain).font(BlenderTheme.font)
            } else {
                Text(o.name).font(BlenderTheme.font).foregroundColor(active ? BlenderTheme.orange.opacity(0.95) : BlenderTheme.text)
            }
            if !o.modifiers.isEmpty { Image(systemName: "wrench.fill").font(.system(size: 9)).foregroundColor(BlenderTheme.axisZ) }
            Spacer()
            Button { model.setVisible(o.id, !o.visible) } label: {
                Image(systemName: o.visible ? "eye" : "eye.slash").font(.system(size: 10)).foregroundColor(BlenderTheme.textDim)
            }.buttonStyle(.plain).help("Hide in Viewport")
            Button { model.setRenders(o.id, !o.renders) } label: {
                Image(systemName: o.renders ? "camera" : "camera.badge.ellipsis").font(.system(size: 10)).foregroundColor(BlenderTheme.textDim)
            }.buttonStyle(.plain).help("Part of the saved model (a boolean's cutter isn't)")
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(selected ? BlenderTheme.selectedRow : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { renaming = o.id; newName = o.name }
        .onTapGesture { model.selectObject(o.id, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)) }
    }

    private func row(symbol: String, title: String, selected: Bool, active: Bool, indent: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundColor(BlenderTheme.textDim)
            Text(title).font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }
}

// MARK: - Object

struct TransformPanel: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        if let t = model.blenderTransform {
            VStack(alignment: .leading, spacing: 6) {
                BVector(title: "Location", value: Binding(get: { t.location }, set: { model.setBlenderLocation($0) }), step: 0.01, unit: " m")
                BVector(title: "Rotation", value: Binding(get: { t.rotation }, set: { model.setBlenderRotation($0) }), step: 0.5, format: "%.1f", unit: "°")
                BVector(title: "Scale", value: Binding(get: { t.scale }, set: { model.setBlenderScale($0) }), step: 0.005)
                BVector(title: "Dimensions", value: .constant(t.dimensions), step: 0, unit: " m")
            }
        }
    }
}

struct ObjectProperties: View {
    @EnvironmentObject var model: ModelingModel
    @State private var name = ""

    var body: some View {
        if let o = model.activeObject {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "square.fill").foregroundColor(BlenderTheme.orange)
                    TextField("Name", text: Binding(get: { o.name }, set: { name = $0 }), onCommit: { model.rename(o.id, to: name) })
                        .textFieldStyle(.roundedBorder).font(BlenderTheme.font)
                }
                BPanel(title: "Transform") { TransformPanel() }
                BPanel(title: "Visibility") {
                    BCheck(title: "Show in Viewport", on: Binding(get: { o.visible }, set: { model.setVisible(o.id, $0) }))
                    BCheck(title: "Part of the Saved Model", on: Binding(get: { o.renders }, set: { model.setRenders(o.id, $0) }))
                }
                BPanel(title: "Mesh") {
                    Text("Vertices \(o.mesh.vertexCount)   Edges \(o.mesh.edgeCount)   Faces \(o.mesh.faceCount)")
                        .font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim)
                }
            }
        }
    }
}

// MARK: - Modifiers

struct ModifierProperties: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        if let o = model.activeObject {
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    Section("Generate") {
                        ForEach([Modifier.Kind.array, .bevel, .boolean, .mirror, .solidify, .subdivision, .triangulate, .weld], id: \.self) { k in
                            Button(k.title) { model.addModifier(k) }
                        }
                        Button("Multiresolution") { model.multiresSubdivide() }
                    }
                } label: {
                    HStack { Image(systemName: "wrench.adjustable"); Text("Add Modifier"); Spacer(); Image(systemName: "chevron.down").font(.system(size: 8)) }
                        .font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(BlenderTheme.widget))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                if let r = o.multires { MultiresPanel(data: r) }
                ForEach(o.modifiers) { m in ModifierPanel(modifier: m, others: model.document.objects.filter { $0.id != o.id }) }
            }
        }
    }
}

struct MultiresPanel: View {
    @EnvironmentObject var model: ModelingModel
    let data: MultiresData

    var body: some View {
        BPanel(title: "Multiresolution") {
            HStack {
                BButton(title: "Subdivide") { model.multiresSubdivide() }
                BButton(title: "Delete Higher") { model.multiresDeleteHigher() }
                BButton(title: "Apply Base") { model.multiresApply() }
            }
            level("Level Viewport", data.viewportLevel) { model.setMultiresLevel(viewport: $0) }
            level("Sculpt", data.sculptLevel) { model.setMultiresLevel(sculpt: $0) }
            level("Render", data.renderLevel) { model.setMultiresLevel(render: $0) }
            Text("\(data.levels) level(s)").font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim)
        }
    }

    private func level(_ title: String, _ value: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim)
            Spacer()
            BButton(symbol: "minus") { set(value - 1) }
            Text("\(value)").font(BlenderTheme.font.monospacedDigit()).foregroundColor(BlenderTheme.text).frame(width: 22)
            BButton(symbol: "plus") { set(value + 1) }
        }
    }
}

struct ModifierPanel: View {
    @EnvironmentObject var model: ModelingModel
    let modifier: Modifier
    let others: [ModelObject]

    private func bind<T>(_ key: WritableKeyPath<Modifier, T>) -> Binding<T> {
        Binding(get: { modifier[keyPath: key] }, set: { v in model.updateModifier(modifier.id) { $0[keyPath: key] = v } })
    }

    private func intBinding(_ key: WritableKeyPath<Modifier, Int>) -> Binding<Float> {
        Binding(get: { Float(modifier[keyPath: key]) }, set: { v in model.updateModifier(modifier.id) { $0[keyPath: key] = Int(v.rounded()) } })
    }

    var body: some View {
        BPanel(title: modifier.name, trailing: AnyView(header)) {
            switch modifier.kind {
            case .mirror:
                HStack(spacing: 1) {
                    Text("Axis").font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim).frame(width: 50, alignment: .leading)
                    ForEach(0..<3, id: \.self) { i in
                        BButton(title: ["X", "Y", "Z"][i], on: modifier.axes[i]) { model.updateModifier(modifier.id) { $0.axes[i].toggle() } }
                    }
                }
                BCheck(title: "Merge", on: bind(\.merge))
                BNumber(label: "Merge Distance", value: bind(\.mergeDistance), step: 0.0001, range: 0...1, format: "%.4f", unit: " m")
            case .array:
                BNumber(label: "Count", value: intBinding(\.count), step: 0.1, range: 1...1000, format: "%.0f")
                BCheck(title: "Relative Offset", on: bind(\.useRelative))
                if modifier.useRelative { BVector(title: "Factor", value: bind(\.relativeOffset)) }
                BCheck(title: "Constant Offset", on: bind(\.useConstant))
                if modifier.useConstant { BVector(title: "Distance", value: bind(\.constantOffset), unit: " m") }
                BCheck(title: "Merge", on: bind(\.mergeEnds))
            case .solidify:
                BNumber(label: "Thickness", value: bind(\.thickness), step: 0.001, format: "%.3f", unit: " m")
                BNumber(label: "Offset", value: bind(\.offset), step: 0.01, range: -1...1)
                BCheck(title: "Even Thickness", on: bind(\.evenThickness))
                BCheck(title: "Fill Rim", on: bind(\.fillRim))
            case .subdivision:
                BNumber(label: "Levels Viewport", value: intBinding(\.levels), step: 0.05, range: 0...6, format: "%.0f")
                BNumber(label: "Render", value: intBinding(\.renderLevels), step: 0.05, range: 0...6, format: "%.0f")
                BCheck(title: "Use Creases", on: bind(\.useCreases))
            case .bevel:
                BNumber(label: "Amount", value: bind(\.width), step: 0.001, range: 0...100, format: "%.3f", unit: " m")
                BNumber(label: "Segments", value: intBinding(\.segments), step: 0.05, range: 1...32, format: "%.0f")
                BNumber(label: "Angle", value: Binding(get: { modifier.angleLimit * 180 / .pi }, set: { v in model.updateModifier(modifier.id) { $0.angleLimit = v * .pi / 180 } }),
                        step: 0.5, range: 0...180, format: "%.1f", unit: "°")
            case .boolean:
                BSegmented(items: [(Modifier.BooleanOperation.intersect, "square.on.square.intersection.dashed", "Intersect"),
                                   (.union, "square.on.square", "Union"), (.difference, "square.on.square.dashed", "Difference")],
                           selection: bind(\.operation))
                BPicker(title: "Object", options: [(UUID?.none, "—")] + others.map { (Optional($0.id), $0.name) }, selection: bind(\.operand))
                BPicker(title: "Solver", options: [(Modifier.BooleanSolver.exact, "Exact"), (.voxel, "Voxel")], selection: bind(\.solver))
                if modifier.solver == .voxel {
                    BNumber(label: "Voxel Size", value: bind(\.voxelSize), step: 0.001, range: 0.001...10, format: "%.3f", unit: " m")
                }
            case .triangulate:
                Text("Every face as triangles.").font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim)
            case .weld:
                BNumber(label: "Distance", value: bind(\.mergeDistance), step: 0.0001, range: 0...1, format: "%.4f", unit: " m")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            toggle(modifier.showInEditMode, "square.and.pencil", "Edit Mode") { $0.showInEditMode.toggle() }
            toggle(modifier.showInViewport, "display", "Viewport") { $0.showInViewport.toggle() }
            toggle(modifier.showInRender, "camera", "Render (the saved model)") { $0.showInRender.toggle() }
            Menu {
                Button("Apply") { model.applyModifier(modifier.id) }
                Button("Move Up") { model.moveModifier(modifier.id, by: -1) }
                Button("Move Down") { model.moveModifier(modifier.id, by: 1) }
                Divider()
                Button("Delete") { model.removeModifier(modifier.id) }
            } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { model.removeModifier(modifier.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
        }
        .foregroundColor(BlenderTheme.textDim)
    }

    private func toggle(_ on: Bool, _ symbol: String, _ help: String, _ change: @escaping (inout Modifier) -> Void) -> some View {
        Button { model.updateModifier(modifier.id, change) } label: {
            Image(systemName: symbol).font(.system(size: 10)).foregroundColor(on ? BlenderTheme.text : BlenderTheme.textDim.opacity(0.5))
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - Material

struct MaterialProperties: View {
    @EnvironmentObject var model: ModelingModel
    @State private var slot = 0

    var body: some View {
        if let o = model.activeObject {
            let k = min(slot, max(0, o.materials.count - 1))
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(o.materials.enumerated()), id: \.offset) { i, m in
                        HStack {
                            Circle().fill(Color(.sRGB, red: Double(m.baseColor.x), green: Double(m.baseColor.y), blue: Double(m.baseColor.z))).frame(width: 12, height: 12)
                            Text(m.name).font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(i == k ? BlenderTheme.selectedRow : BlenderTheme.widgetDark)
                        .contentShape(Rectangle())
                        .onTapGesture { slot = i }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack {
                    BButton(symbol: "plus") { model.addMaterialSlot() }
                    BButton(symbol: "minus") { model.removeMaterialSlot(k) }
                    Spacer()
                }
                if model.mode == .edit {
                    HStack {
                        BButton(title: "Assign") { model.assignMaterial(k) }
                        BButton(title: "Select") { model.selectMaterial(k, true) }
                        BButton(title: "Deselect") { model.selectMaterial(k, false) }
                    }
                }
                if k < o.materials.count {
                    let m = o.materials[k]
                    BPanel(title: "Surface") {
                        TextField("Name", text: Binding(get: { m.name }, set: { v in model.updateMaterialSlot(k) { $0.name = v } }))
                            .textFieldStyle(.roundedBorder).font(BlenderTheme.font)
                        ColorPicker("Base Color", selection: Binding(
                            get: { Color(.sRGB, red: Double(m.baseColor.x), green: Double(m.baseColor.y), blue: Double(m.baseColor.z)) },
                            set: { c in
                                let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
                                model.updateMaterialSlot(k) { $0.baseColor = SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), 1) }
                            }))
                            .font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
                        BNumber(label: "Metallic", value: Binding(get: { m.metallic }, set: { v in model.updateMaterialSlot(k) { $0.metallic = v } }), step: 0.005, range: 0...1)
                        BNumber(label: "Roughness", value: Binding(get: { m.roughness }, set: { v in model.updateMaterialSlot(k) { $0.roughness = v } }), step: 0.005, range: 0...1)
                        BVector(title: "Emission", value: Binding(get: { m.emission }, set: { v in model.updateMaterialSlot(k) { $0.emission = v } }), step: 0.01, labels: ["R", "G", "B"])
                        TextField("Material Designer material (optional)", text: Binding(get: { m.graph ?? "" },
                                                                                         set: { v in model.updateMaterialSlot(k) { $0.graph = v.isEmpty ? nil : v } }))
                            .textFieldStyle(.roundedBorder).font(BlenderTheme.small)
                    }
                }
            }
        }
    }
}

// MARK: - Data

struct DataProperties: View {
    @EnvironmentObject var model: ModelingModel

    var body: some View {
        if let o = model.activeObject {
            VStack(alignment: .leading, spacing: 6) {
                BPanel(title: "Normals") {
                    HStack {
                        BButton(title: "Shade Smooth") { model.shade(smooth: true) }
                        BButton(title: "Auto Smooth") { model.shade(smooth: true, autoAngle: 30 * .pi / 180) }
                        BButton(title: "Flat") { model.shade(smooth: false) }
                    }
                }
                BPanel(title: "UV Maps") {
                    HStack {
                        BButton(title: "Unwrap") { model.unwrap(smart: false) }
                        BButton(title: "Smart UV Project") { model.unwrap(smart: true) }
                    }
                    .disabled(model.mode != .edit)
                    if model.mode != .edit { Text("In Edit Mode: select faces, mark seams (Ctrl E), unwrap (U).").font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim) }
                    UVView(mesh: o.mesh, onlySelected: model.mode == .edit).frame(height: 260)
                }
                BPanel(title: "Remesh") {
                    BNumber(label: "Voxel Size", value: $model.voxelSize, step: 0.001, range: 0.0005...10, format: "%.4f", unit: " m")
                    BButton(title: "Voxel Remesh") {
                        if model.mode != .sculpt { model.setMode(.sculpt) }
                        model.voxelRemesh()
                    }
                }
            }
        }
    }
}

/// The UV editor's picture: the faces' UVs in the unit square (selected faces orange), over a checker.
struct UVView: View {
    let mesh: EditMesh
    let onlySelected: Bool

    var body: some View {
        Canvas { g, size in
            let s = min(size.width, size.height)
            let cell = s / 8
            for y in 0..<8 { for x in 0..<8 where (x + y) % 2 == 0 {
                g.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)), with: .color(Color.white.opacity(0.05)))
            } }
            g.stroke(Path(CGRect(x: 0, y: 0, width: s, height: s)), with: .color(BlenderTheme.textDim), lineWidth: 1)
            var plain = Path(), picked = Path()
            let lines = mesh.uvLines(onlySelected: onlySelected && mesh.hasSelection)
            for (a, b, sel) in lines.prefix(200_000) {
                let pa = CGPoint(x: CGFloat(a.x) * s, y: (1 - CGFloat(a.y)) * s), pb = CGPoint(x: CGFloat(b.x) * s, y: (1 - CGFloat(b.y)) * s)
                if sel { picked.move(to: pa); picked.addLine(to: pb) } else { plain.move(to: pa); plain.addLine(to: pb) }
            }
            g.stroke(plain, with: .color(Color.white.opacity(0.5)), lineWidth: 0.5)
            g.stroke(picked, with: .color(BlenderTheme.orange), lineWidth: 0.7)
        }
        .background(BlenderTheme.widgetDark)
    }
}

// MARK: - The sidebar in the viewport (N)

struct NPanel: View {
    @EnvironmentObject var model: ModelingModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(["Item", "Tool", "View"].enumerated()), id: \.offset) { i, t in
                    Button { tab = i } label: {
                        Text(t).font(BlenderTheme.font).foregroundColor(tab == i ? BlenderTheme.text : BlenderTheme.textDim)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 4).fill(tab == i ? BlenderTheme.panel : .clear))
                    }.buttonStyle(.plain)
                }
            }
            switch tab {
            case 0:
                if model.mode == .edit, let median = model.selectionMedian {
                    BPanel(title: "Transform") {
                        BVector(title: "Median", value: Binding(get: { median }, set: { model.setSelectionMedian($0) }), step: 0.01, unit: " m")
                    }
                } else {
                    BPanel(title: "Transform") { TransformPanel() }
                }
            case 1:
                BPanel(title: "Options") {
                    BCheck(title: "Proportional Editing", on: $model.proportional)
                    BCheck(title: "Emulate 3 Button Mouse", on: $model.emulateMiddleButton)
                    BCheck(title: "Emulate Numpad", on: $model.emulateNumpad)
                }
            default:
                BPanel(title: "View") {
                    BNumber(label: "Field of View", value: Binding(get: { model.camera.fovY * 180 / .pi }, set: { model.camera.fovY = $0 * .pi / 180 }),
                            step: 0.2, range: 5...150, format: "%.1f", unit: "°")
                    BNumber(label: "Clip Start", value: Binding(get: { model.camera.near }, set: { model.camera.near = $0 }), step: 0.001, range: 0.0001...10, format: "%.4f", unit: " m")
                }
                BPanel(title: "3D Cursor") {
                    BVector(title: "Location", value: Binding(get: { BlenderAxes.toBlender(model.document.cursor) }, set: { model.setCursor($0) }), step: 0.01, unit: " m")
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(BlenderTheme.region.opacity(0.95)))
    }
}
