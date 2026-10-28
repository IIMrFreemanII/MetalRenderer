import AppKit
import Characters
import Garments
import MetalRenderer
import SwiftUI
import simd

/// The property panel at the right: the garment (its templates, particle spacing, files), the selected panel (fabric,
/// layer, grain, where it goes round the body, freeze), the selected seam, the fabrics, the avatar.
struct GarmentInspector: View {
    @ObservedObject var model: GarmentModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(GarmentModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch model.tab {
                    case .garment: garment
                    case .panel: panel
                    case .seam: seam
                    case .fabric: fabrics
                    case .avatar: avatar
                    }
                }
                .padding(10)
            }
        }
        .foregroundColor(GarmentTheme.swText)
        .background(GarmentTheme.swPanel)
    }

    // MARK: Garment

    private var garment: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Garment")
            TextField("Name", text: Binding(get: { model.garment.name }, set: { v in model.edit("Rename", rebuild: false) { $0.name = v } }))
            Text("New from a template").font(.caption).foregroundColor(GarmentTheme.swDim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 6) {
                ForEach(GarmentTemplate.Kind.allCases, id: \.self) { k in
                    Button(k.label) { model.newFromTemplate(k) }.buttonStyle(.bordered)
                }
            }
            Menu("Wear another over it") {
                ForEach(GarmentTemplate.Kind.allCases, id: \.self) { k in Button(k.label) { model.addLayer(k) } }
            }
            if let t = model.garment.template {
                section("\(t.kind.label) parameters")
                ForEach(GarmentTemplate.specs(t.kind), id: \.key) { spec in
                    slider(spec.label, value: t.params[spec.key], range: spec.range, length: spec.length) { model.setTemplateParam(spec.key, $0) }
                }
                Button("Fit to the avatar's measurements") { model.gradeToAvatar() }
            }
            section("Simulation")
            slider("Particle distance", value: model.garment.particleDistance, range: 0.008...0.05, length: true) { v in
                model.edit("Particle Distance") { $0.particleDistance = v }
            }
            HStack {
                Button(model.simulating ? "Stop (Space)" : "Simulate (Space)") { model.toggleSimulation() }
                Button("Reset drape") { model.resetDrape() }
            }
            if let r = model.report {
                Text("\(r.particles) particles · \(r.constraints) constraints · \(r.colours) colours")
                    .font(.caption).foregroundColor(GarmentTheme.swDim)
                Text(String(format: "Made in %.0f ms · %.1f s draped", r.buildMs, r.sewTime)).font(.caption).foregroundColor(GarmentTheme.swDim)
            }
            section("Display")
            Toggle("Snap to grid and points", isOn: $model.snap)
            Toggle("Edge lengths", isOn: $model.showLengths)
            Toggle("Seam allowance", isOn: $model.showAllowance)
            if model.showAllowance { slider("Allowance", value: model.allowance, range: 0.003...0.03, length: true) { model.allowance = $0 } }
            if !model.mismatchedSeams.isEmpty {
                section("Seams that differ in length")
                ForEach(model.mismatchedSeams, id: \.seam) { m in
                    Button(String(format: "Seam %d: %.1f / %.1f cm", m.seam, m.a * 100, m.b * 100)) { model.selectedSeam = m.seam; model.tab = .seam }
                        .buttonStyle(.plain).foregroundColor(Color(GarmentTheme.warning))
                }
            }
        }
    }

    // MARK: Panel

    @ViewBuilder private var panel: some View {
        let selected = model.garment.panels.filter { model.selection.contains($0.id) }
        if let p = selected.first {
            section(selected.count > 1 ? "\(selected.count) panels" : "Panel")
            if selected.count == 1 {
                TextField("Name", text: Binding(get: { p.name }, set: { v in model.updatePanels("Rename") { $0.name = v } }))
                Text(String(format: "%.0f × %.0f cm · %.2f m²", (p.bounds.hi.x - p.bounds.lo.x) * 100, (p.bounds.hi.y - p.bounds.lo.y) * 100, p.signedArea))
                    .font(.caption).foregroundColor(GarmentTheme.swDim)
            }
            Picker("Fabric", selection: Binding(get: { p.fabric }, set: { v in model.updatePanels("Fabric") { $0.fabric = v } })) {
                ForEach(model.garment.fabrics.indices, id: \.self) { Text(model.garment.fabrics[$0].name).tag($0) }
            }
            Stepper("Layer \(p.layer)", value: Binding(get: { p.layer }, set: { v in model.updatePanels("Layer") { $0.layer = max(0, v) } }), in: 0...5)
            slider("Grain", value: p.grain * 180 / .pi, range: -180...180, length: false, unit: "°") { v in
                model.updatePanels("Grain") { $0.grain = v * .pi / 180 }
            }
            Toggle("Frozen", isOn: Binding(get: { p.frozen }, set: { v in model.updatePanels(v ? "Freeze" : "Unfreeze") { $0.frozen = v } }))
            Toggle("Hidden", isOn: Binding(get: { p.hidden }, set: { v in model.updatePanels("Hide") { $0.hidden = v } }))
            section("Arrangement")
            Picker("Place", selection: Binding(get: { p.arrangement?.slot }, set: { v in
                model.updatePanels("Arrange") { panel in
                    if let v {
                        var a = panel.arrangement ?? Arrangement(slot: v)
                        if panel.arrangement == nil || panel.arrangement?.slot.isLimb != v.isLimb {
                            a.offset = SIMD2(0, v.isArm ? -0.25 : v.isLimb ? 0.6 : 1.2)
                        }
                        a.slot = v
                        panel.arrangement = a
                    } else { panel.arrangement = nil }
                }
            })) {
                Text("None").tag(ArrangementSlot?.none)
                ForEach(ArrangementSlot.allCases, id: \.self) { Text($0.label).tag(ArrangementSlot?.some($0)) }
            }
            if let a = p.arrangement {
                slider("Round", value: a.offset.x, range: -0.6...0.6, length: true) { v in model.updatePanels("Arrange") { $0.arrangement?.offset.x = v } }
                slider(a.slot.isArm ? "Along the arm" : "Height", value: a.offset.y, range: a.slot.isArm ? -0.8...0.2 : 0...2, length: true) { v in
                    model.updatePanels("Arrange") { $0.arrangement?.offset.y = v }
                }
                slider("Clearance", value: a.clearance, range: 0.01...0.2, length: true) { v in model.updatePanels("Arrange") { $0.arrangement?.clearance = v } }
                Toggle("Wrapped from inside", isOn: Binding(get: { a.flipped }, set: { v in model.updatePanels("Arrange") { $0.arrangement?.flipped = v } }))
            }
            section("Internal lines")
            ForEach(p.lines.indices, id: \.self) { k in
                HStack {
                    Picker("", selection: Binding(get: { p.lines[k].kind }, set: { v in
                        model.updatePanels("Line") { if $0.lines.indices.contains(k) { $0.lines[k].kind = v } }
                    })) { ForEach(InternalLine.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    .labelsHidden().frame(width: 100)
                    Button(role: .destructive) { model.updatePanels("Delete Line") { if $0.lines.indices.contains(k) { $0.lines.remove(at: k) } } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
                if p.lines[k].kind == .fold {
                    slider("Fold angle", value: p.lines[k].foldAngle * 180 / .pi, range: -180...180, length: false, unit: "°") { v in
                        model.updatePanels("Fold") { if $0.lines.indices.contains(k) { $0.lines[k].foldAngle = v * .pi / 180 } }
                    }
                } else if p.lines[k].kind == .elastic {
                    slider("Ratio", value: p.lines[k].ratio, range: 0.4...1, length: false) { v in
                        model.updatePanels("Elastic") { if $0.lines.indices.contains(k) { $0.lines[k].ratio = v } }
                    }
                }
            }
            HStack {
                Button("Duplicate") { model.duplicateSelection(mirrored: false) }
                Button("Mirror (linked)") { model.duplicateSelection(mirrored: true) }
                Button("Delete") { model.deleteSelection() }
            }
        } else {
            Text("Select a panel in the pattern window.").foregroundColor(GarmentTheme.swDim)
        }
    }

    // MARK: Seam

    @ViewBuilder private var seam: some View {
        if let id = model.selectedSeam, let s = model.garment.seams.first(where: { $0.id == id }) {
            section("Seam \(s.id)")
            let la = s.a.reduce(Float(0)) { $0 + SeamSampling.length(model.garment, $1) }, lb = s.b.reduce(Float(0)) { $0 + SeamSampling.length(model.garment, $1) }
            Text(String(format: "%.1f cm to %.1f cm (%d:%d)", la * 100, lb * 100, s.a.count, s.b.count)).foregroundColor(GarmentTheme.swDim)
            Picker("Kind", selection: Binding(get: { s.kind }, set: { v in model.updateSeam("Seam Kind") { $0.kind = v } })) {
                ForEach(Seam.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            slider("Fold angle", value: s.foldAngle * 180 / .pi, range: -180...180, length: false, unit: "°") { v in
                model.updateSeam("Seam Fold") { $0.foldAngle = v * .pi / 180 }
            }
            Toggle("Topstitch", isOn: Binding(get: { s.topstitch }, set: { v in model.updateSeam("Topstitch") { $0.topstitch = v } }))
            HStack {
                Button("Flip one side") { model.updateSeam("Flip Seam") { $0.b = $0.b.reversed().map(\.reversed) } }
                Button("Delete") { model.deleteSelection() }
            }
        } else {
            Text("Select a seam (click a coloured edge), or sew with N: click an edge near the end that meets, then the edge it sews to. Shift-click several edges for one side (N:1), Return to sew.")
                .foregroundColor(GarmentTheme.swDim)
        }
    }

    // MARK: Fabrics

    private var fabrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.garment.fabrics.indices, id: \.self) { i in
                let f = model.garment.fabrics[i]
                section(f.name)
                HStack {
                    Menu("Preset") {
                        ForEach(Fabric.Preset.allCases, id: \.self) { p in
                            Button(p.rawValue.capitalized) { model.setFabric(i) { $0 = .preset(p) } }
                        }
                    }
                    ColorPicker("", selection: Binding(get: { Color(red: Double(f.color.x), green: Double(f.color.y), blue: Double(f.color.z)) }, set: { c in
                        let n = NSColor(c).usingColorSpace(.deviceRGB) ?? .white
                        model.setFabric(i) { $0.color = SIMD3(Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent)) }
                    })).labelsHidden()
                }
                slider("Stretch, warp", value: f.warp, range: 0...100, length: false) { v in model.setFabric(i) { $0.warp = v } }
                slider("Stretch, weft", value: f.weft, range: 0...100, length: false) { v in model.setFabric(i) { $0.weft = v } }
                slider("Shear", value: f.shear, range: 0...100, length: false) { v in model.setFabric(i) { $0.shear = v } }
                slider("Bending", value: f.bending, range: 0...100, length: false) { v in model.setFabric(i) { $0.bending = v } }
                slider("Weight (g/m²)", value: f.density, range: 30...1200, length: false) { v in model.setFabric(i) { $0.density = v } }
                slider("Friction", value: f.friction, range: 0...1, length: false) { v in model.setFabric(i) { $0.friction = v } }
                slider("Thickness", value: f.thickness, range: 0.0003...0.008, length: true) { v in model.setFabric(i) { $0.thickness = v } }
                slider("Roughness", value: f.roughness, range: 0.05...1, length: false) { v in model.setFabric(i) { $0.roughness = v } }
                slider("Sheen", value: f.sheen, range: 0...1, length: false) { v in model.setFabric(i) { $0.sheen = v } }
                slider("Sheen spread", value: f.sheenRoughness, range: 0.05...1, length: false) { v in model.setFabric(i) { $0.sheenRoughness = v } }
                if model.garment.fabrics.count > 1 {
                    Button("Remove") { model.edit("Remove Fabric") { g in
                        g.fabrics.remove(at: i)
                        for k in g.panels.indices where g.panels[k].fabric >= i { g.panels[k].fabric = max(0, g.panels[k].fabric - 1) }
                    } }
                }
            }
            Button("Add fabric") { model.edit("Add Fabric") { $0.fabrics.append(.preset(.cotton)) } }
        }
    }

    // MARK: Avatar

    private var avatar: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Avatar")
            Picker("Wearer", selection: Binding(get: { model.avatar }, set: { model.setAvatar($0) })) {
                ForEach(GarmentAvatars.names(), id: \.self) { Text($0).tag($0) }
            }
            let m = model.measurements
            Group {
                row("Height", m.height); row("Chest", m.chest); row("Waist", m.waist); row("Hips", m.hips)
                row("Neck", m.neck); row("Thigh", m.thigh); row("Upper arm", m.upperArm); row("Shoulders", m.shoulderWidth)
                row("Arm", m.armLength); row("Inseam", m.crotchHeight - m.ankleHeight)
            }
            Text("Generated characters change with the Character Editor's sliders; Fit to the avatar's measurements (Garment tab) grades a template to whoever wears it.")
                .font(.caption).foregroundColor(GarmentTheme.swDim)
            section("Motion")
            Picker("Clip", selection: Binding(get: { model.clip }, set: { model.setClip($0) })) {
                Text("Bind pose").tag("")
                ForEach(["Idle", "Walking", "Running", "Hip Hop Dancing"], id: \.self) { Text($0).tag($0) }
            }
            Button("Bake 6 s to a point cache…") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = GarmentStore.id(for: model.garment.name) + ".pc2"
                if panel.runModal() == .OK, let url = panel.url { model.bake(seconds: 6, to: url) }
            }
            section("Trace")
            Text("With the trace tool (T), click round a region of the body in the 3D view; Make Panel flattens it into the pattern.")
                .font(.caption).foregroundColor(GarmentTheme.swDim)
            HStack {
                Button("Make panel (\(model.trace.count) points)") { model.panelFromTrace() }.disabled(model.trace.count < 3)
                Button("Clear") { model.trace = [] }
            }
        }
    }

    // MARK: Pieces

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(GarmentTheme.swAccent).padding(.top, 4)
    }

    private func row(_ name: String, _ v: Float) -> some View {
        HStack { Text(name); Spacer(); Text(String(format: "%.1f cm", v * 100)).foregroundColor(GarmentTheme.swDim) }
    }

    private func slider(_ name: String, value: Float, range: ClosedRange<Float>, length: Bool, unit: String = "",
                        set: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.system(size: 11))
                Spacer()
                Text(length ? String(format: "%.1f cm", value * 100) : String(format: range.upperBound > 10 ? "%.0f%@" : "%.2f%@", value, unit))
                    .font(.system(size: 11)).foregroundColor(GarmentTheme.swDim)
            }
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: Double(range.lowerBound)...Double(range.upperBound))
                .controlSize(.small)
        }
    }
}
