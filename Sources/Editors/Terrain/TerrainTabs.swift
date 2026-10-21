import EngineCore
import MetalRenderer
import SwiftUI
import simd

/// The Terrain Editor's generator, erosion, scatter and water tabs (TerrainView's inspector).

extension TerrainModel {
    /// The document's generator over the selected tiles (else the whole terrain, or the map's tiles), faded into the
    /// ground around them.
    func generate(border: Float) {
        guard let region else { message = "Select tiles on the map first"; return }
        host.terrain { $0.runTerrainGenerator(region: region, border: border) }
    }

    func erode(_ kind: TerrainErosion.Kind, border: Float) {
        guard let region else { message = "Select tiles on the map first"; return }
        host.terrain { $0.runTerrainErosion(region: region, kind: kind, border: border) }
    }

    func cancelJob() { host.terrain { $0.cancelTerrainJob() } }

    /// Water: a sea at the level under the cursor (or 0), a lake around the place under the cursor, a river along the
    /// brush's last stroke.
    func addWater(_ kind: WaterBody.Kind) {
        let hover = status.hover
        switch kind {
        case .sea:
            edit("Add sea") { $0.water.append(WaterBody(name: "Sea", kind: .sea, level: hover.map { Float($0.y) } ?? 0)) }
        case .lake:
            guard let h = hover else { message = "Point at the lake's basin in the view first"; return }
            edit("Add lake") { $0.water.append(WaterBody(name: "Lake", kind: .lake, level: Float(h.y) + 1, seed: SIMD2(h.x, h.z))) }
        case .river:
            host.terrain { r in
                let path = r.terrain.lastStroke
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard path.count > 1 else { self.message = "Draw the river's line with a brush stroke first (source to mouth)"; return }
                    self.edit("Add river") { $0.water.append(WaterBody(name: "River", kind: .river, points: path)) }
                }
            }
        }
    }

    /// River `index`'s bed carved into the ground along its line (kept for undo).
    func carveRiver(_ index: Int) {
        guard let w = document?.water, w.indices.contains(index), w[index].kind == .river else { return }
        let river = w[index]
        host.terrain { $0.carveTerrainRiver(river) }
    }
}

struct GenerateTab: View {
    @EnvironmentObject var model: TerrainModel
    @State private var border: Float = 60
    @State private var selected = 0

    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        if let d = model.document {
            Text("Its steps in order, each a shape of noise combined with what the steps before made, or an operation on it. "
                 + "Apply runs it over the selected tiles (the whole terrain if none); the brush's Generator stamp paints it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Replaces the ground (else added to it)", isOn: Binding(get: { d.generator.replaces },
                                                                          set: { v in model.edit("Generator replaces") { $0.generator.replaces = v } }))
            ForEach(Array(d.generator.nodes.enumerated()), id: \.offset) { k, node in
                HStack {
                    Toggle("", isOn: Binding(get: { node.enabled }, set: { v in model.edit("Step on or off") { $0.generator.nodes[k].enabled = v } }))
                        .labelsHidden()
                    Text("\(k + 1). \(node.kind.title)").lineLimit(1)
                    Spacer()
                    if node.kind.isSource { Text(node.blend.title).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(selected == k ? Color.accentColor.opacity(0.25) : Color.clear).cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { selected = k }
            }
            HStack {
                Menu {
                    ForEach(GeneratorNode.Kind.allCases) { kind in
                        Button(kind.title) {
                            model.edit("Add step") { $0.generator.nodes.append(GeneratorNode(kind: kind, seed: Int.random(in: 1...9999))) }
                            selected = (model.document?.generator.nodes.count ?? 1) - 1
                        }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).frame(width: 34)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                Spacer()
                Button {
                    model.edit("Delete step") { if $0.generator.nodes.indices.contains(selected) { $0.generator.nodes.remove(at: selected) } }
                    selected = max(selected - 1, 0)
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            if d.generator.nodes.indices.contains(selected) {
                Divider()
                NodeEditor(index: selected, node: d.generator.nodes[selected])
            }
            Divider()
            TerrainSlider(title: "Fade into the ground", value: $border, range: 0...400, format: "%.0f m")
            JobButtons(title: "Apply generator") { model.generate(border: border) }
        }
    }

    private func move(_ by: Int) {
        let to = selected + by
        model.edit("Move step") { d in
            guard d.generator.nodes.indices.contains(selected), d.generator.nodes.indices.contains(to) else { return }
            d.generator.nodes.swapAt(selected, to)
        }
        if model.document?.generator.nodes.indices.contains(to) == true { selected = to }
    }
}

private struct NodeEditor: View {
    @EnvironmentObject var model: TerrainModel
    let index: Int
    let node: GeneratorNode

    private func b<T>(_ path: WritableKeyPath<GeneratorNode, T>) -> Binding<T> {
        Binding(get: { node[keyPath: path] }, set: { v in model.edit("Generator step") { $0.generator.nodes[index][keyPath: path] = v } })
    }
    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: b(\.kind)) { ForEach(GeneratorNode.Kind.allCases) { Text($0.title).tag($0) } }
            if node.kind.isSource {
                Picker("Blend", selection: b(\.blend)) { ForEach(GeneratorNode.Blend.allCases) { Text($0.title).tag($0) } }
                TerrainSlider(title: "Height", value: b(\.amplitude), range: 0...800, format: "%.0f m", onDrag: drag)
                if node.kind != .constant {
                    TerrainSlider(title: "Feature size", value: b(\.scale), range: 5...5000, log: true, format: "%.0f m", onDrag: drag)
                    Stepper("Octaves: \(node.octaves)", value: b(\.octaves), in: 1...12)
                    TerrainSlider(title: "Octave scale", value: b(\.lacunarity), range: 1.5...3, onDrag: drag)
                    TerrainSlider(title: "Octave weight", value: b(\.gain), range: 0.2...0.8, onDrag: drag)
                    Stepper("Seed: \(node.seed)", value: b(\.seed), in: 0...99_999)
                }
                if node.blend == .lerp { TerrainSlider(title: "Amount", value: b(\.amount), range: 0...1, onDrag: drag) }
            } else {
                switch node.kind {
                case .warp:
                    TerrainSlider(title: "Distance", value: b(\.amplitude), range: 0...400, format: "%.0f m", onDrag: drag)
                    TerrainSlider(title: "Feature size", value: b(\.scale), range: 5...5000, log: true, format: "%.0f m", onDrag: drag)
                    TerrainSlider(title: "Amount", value: b(\.amount), range: 0...2, onDrag: drag)
                    Stepper("Seed: \(node.seed)", value: b(\.seed), in: 0...99_999)
                case .terrace:
                    TerrainSlider(title: "Step", value: b(\.amplitude), range: 0.5...100, log: true, format: "%.1f m", onDrag: drag)
                    TerrainSlider(title: "Sharpness", value: b(\.sharpness), range: 0...0.95, onDrag: drag)
                case .plateau, .curve:
                    TerrainSlider(title: "Level", value: b(\.level), range: -200...1000, format: "%.0f m", onDrag: drag)
                    TerrainSlider(title: "Amount", value: b(\.amount), range: 0...2, onDrag: drag)
                case .smooth:
                    TerrainSlider(title: "Passes (x10)", value: b(\.amount), range: 0...3, onDrag: drag)
                default:
                    EmptyView()
                }
            }
        }
    }
}

/// A long job's button, its progress while it runs, and a way to stop it.
private struct JobButtons: View {
    @EnvironmentObject var model: TerrainModel
    let title: String
    let run: () -> Void

    var body: some View {
        if let job = model.status.job {
            HStack {
                ProgressView(value: Double(model.status.progress)) { Text(job).font(.caption) }
                Button("Stop") { model.cancelJob() }
            }
        } else {
            HStack {
                Button(title, action: run)
                Text(model.selectedTiles.isEmpty ? "whole terrain" : "\(model.selectedTiles.count) tiles").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ErosionTab: View {
    @EnvironmentObject var model: TerrainModel
    @State private var kind = TerrainErosion.Kind.both
    @State private var border: Float = 40

    private func b<T>(_ path: WritableKeyPath<ErosionSettings, T>) -> Binding<T> {
        Binding(get: { (model.document?.erosion ?? ErosionSettings())[keyPath: path] },
                set: { v in model.edit("Erosion setting") { $0.erosion[keyPath: path] = v } })
    }
    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        if let d = model.document {
            let e = d.erosion
            Text("Water rains, runs downhill carrying earth and leaves it where it slows; slopes steeper than they can stand crumble. "
                 + "The brushes Erode and Crumble do it where they are dragged.").font(.caption).foregroundStyle(.secondary)
            GroupBox("Water (hydraulic)") {
                VStack(alignment: .leading) {
                    Stepper("Passes: \(e.hydraulicIterations)", value: b(\.hydraulicIterations), in: 0...5000, step: 50)
                    TerrainSlider(title: "Rain a pass", value: b(\.rain), range: 0.001...0.05, log: true, format: "%.3f m", onDrag: drag)
                    TerrainSlider(title: "Evaporation", value: b(\.evaporation), range: 0.001...0.2, log: true, format: "%.3f", onDrag: drag)
                    TerrainSlider(title: "Carrying capacity", value: b(\.capacity), range: 0.05...4, log: true, onDrag: drag)
                    TerrainSlider(title: "Dissolving", value: b(\.dissolve), range: 0.01...1, onDrag: drag)
                    TerrainSlider(title: "Depositing", value: b(\.deposit), range: 0.01...1, onDrag: drag)
                }
            }
            GroupBox("Crumbling (thermal)") {
                VStack(alignment: .leading) {
                    Stepper("Passes: \(e.thermalIterations)", value: b(\.thermalIterations), in: 0...2000, step: 10)
                    TerrainSlider(title: "Steepest it stands", value: b(\.talus), range: 5...80, format: "%.0f°", onDrag: drag)
                    TerrainSlider(title: "Rate", value: b(\.thermalRate), range: 0.01...0.5, onDrag: drag)
                }
            }
            Picker("Erosion", selection: $kind) { ForEach(TerrainErosion.Kind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            TerrainSlider(title: "Fade into the ground", value: $border, range: 0...400, format: "%.0f m")
            JobButtons(title: "Erode") { model.erode(kind, border: border) }
        }
    }
}

struct ScatterTab: View {
    @EnvironmentObject var model: TerrainModel
    @State private var selected = 0

    var body: some View {
        if let d = model.document {
            Text("Rules that place plants, rocks, meshes or buildings on the ground: where (height, slope, a layer painted, patches) "
                 + "and how many. A brush stroke re-scatters what it touches.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(d.scatter.enumerated()), id: \.offset) { k, rule in
                HStack {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in model.edit("Rule on or off") { $0.scatter[k].enabled = v } }))
                        .labelsHidden()
                    VStack(alignment: .leading) {
                        Text(rule.name).lineLimit(1)
                        Text(rule.source.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(selected == k ? Color.accentColor.opacity(0.25) : Color.clear).cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { selected = k }
            }
            HStack {
                Menu {
                    Button("Rocks") { add(ScatterRule(name: "Rocks", source: .rock(roughness: 0.5), density: 6, spacing: 3, slopeMax: 60, sizeMin: 0.4, sizeMax: 1.6, sink: 0.2)) }
                    Menu("Plants") {
                        ForEach(PlantCatalog.resolve(model.host.settings.scene.plantCatalog).species.map(\.id), id: \.self) { id in
                            Button(id) { add(ScatterRule(name: id.capitalized, source: .plant(species: id), density: 3, spacing: 4)) }
                        }
                    }
                    Menu("Buildings") {
                        ForEach(BuildingCatalog.resolve(model.host.settings.scene.buildingCatalog).styles.map(\.id), id: \.self) { id in
                            Button(id) { add(ScatterRule(name: id.capitalized, source: .building(style: id), density: 0.2, spacing: 30, slopeMax: 12, sink: 0.3)) }
                        }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).frame(width: 34)
                Spacer()
                Button {
                    model.edit("Delete rule") { if $0.scatter.indices.contains(selected) { $0.scatter.remove(at: selected) } }
                    selected = max(selected - 1, 0)
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            if d.scatter.indices.contains(selected) {
                Divider()
                ScatterEditor(index: selected, rule: d.scatter[selected], layers: d.layers)
            }
        }
    }

    private func add(_ rule: ScatterRule) {
        var r = rule
        r.seed = Int.random(in: 1...99_999)
        model.edit("Add scatter rule") { $0.scatter.append(r) }
        selected = (model.document?.scatter.count ?? 1) - 1
    }
}

private struct ScatterEditor: View {
    @EnvironmentObject var model: TerrainModel
    let index: Int
    let rule: ScatterRule
    let layers: [TerrainLayer]

    private func b<T>(_ path: WritableKeyPath<ScatterRule, T>) -> Binding<T> {
        Binding(get: { rule[keyPath: path] }, set: { v in model.edit("Scatter rule") { $0.scatter[index][keyPath: path] = v } })
    }
    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: b(\.name))
            TerrainSlider(title: "Per 100 m square", value: b(\.density), range: 0.01...400, log: true, format: "%.2f", onDrag: drag)
            TerrainSlider(title: "At least apart", value: b(\.spacing), range: 0.2...100, log: true, format: "%.1f m", onDrag: drag)
            TerrainSlider(title: "Slope from", value: b(\.slopeMin), range: 0...90, format: "%.0f°", onDrag: drag)
            TerrainSlider(title: "Slope to", value: b(\.slopeMax), range: 0...90, format: "%.0f°", onDrag: drag)
            TerrainSlider(title: "Height from", value: b(\.heightMin), range: -500...2000, format: "%.0f m", onDrag: drag)
            TerrainSlider(title: "Height to", value: b(\.heightMax), range: -500...10000, format: "%.0f m", onDrag: drag)
            Picker("Only on layer", selection: b(\.layer)) {
                Text("Anywhere").tag(Int?.none)
                ForEach(Array(layers.enumerated()), id: \.offset) { k, l in Text("\(k). \(l.name)").tag(Int?.some(k)) }
            }
            if rule.layer != nil { TerrainSlider(title: "Its weight at least", value: b(\.layerThreshold), range: 0.05...1, onDrag: drag) }
            TerrainSlider(title: "Patches", value: b(\.patchScale), range: 5...1000, log: true, format: "%.0f m", onDrag: drag)
            TerrainSlider(title: "Patches cover", value: b(\.patchCover), range: 0...1, onDrag: drag)
            TerrainSlider(title: "Along the ground", value: b(\.alignToGround), range: 0...1, onDrag: drag)
            TerrainSlider(title: "Size from", value: b(\.sizeMin), range: 0.05...5, log: true, onDrag: drag)
            TerrainSlider(title: "Size to", value: b(\.sizeMax), range: 0.05...5, log: true, onDrag: drag)
            TerrainSlider(title: "Sunk", value: b(\.sink), range: 0...3, format: "%.2f m", onDrag: drag)
            Stepper("Seed: \(rule.seed)", value: b(\.seed), in: 0...99_999)
            Toggle("Out of the water", isOn: b(\.avoidWater))
        }
    }
}

struct WaterTab: View {
    @EnvironmentObject var model: TerrainModel
    @State private var selected = 0

    var body: some View {
        if let d = model.document {
            Text("A sea everywhere below its level, a lake filling the basin around a place up to its level, a river along a line, "
                 + "its bed carved into the ground.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(d.water.enumerated()), id: \.offset) { k, w in
                HStack {
                    Text(w.name).lineLimit(1)
                    Spacer()
                    Text(w.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(selected == k ? Color.accentColor.opacity(0.25) : Color.clear).cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { selected = k }
            }
            HStack {
                Menu {
                    Button("Sea") { add(.sea) }
                    Button("Lake under the cursor") { add(.lake) }
                    Button("River along the brush's last stroke") { add(.river) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).frame(width: 34)
                Spacer()
                Button {
                    model.edit("Delete water") { if $0.water.indices.contains(selected) { $0.water.remove(at: selected) } }
                    selected = max(selected - 1, 0)
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            if d.water.indices.contains(selected) {
                Divider()
                WaterEditor(index: selected, water: d.water[selected])
            }
        }
    }

    private func add(_ kind: WaterBody.Kind) {
        model.addWater(kind)
        selected = (model.document?.water.count ?? 1) - 1
    }
}

private struct WaterEditor: View {
    @EnvironmentObject var model: TerrainModel
    let index: Int
    let water: WaterBody

    private func b<T>(_ path: WritableKeyPath<WaterBody, T>) -> Binding<T> {
        Binding(get: { water[keyPath: path] }, set: { v in model.edit("Water") { $0.water[index][keyPath: path] = v } })
    }
    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: b(\.name))
            if water.kind != .river {
                TerrainSlider(title: "Level", value: b(\.level), range: -200...1000, format: "%.2f m", onDrag: drag)
                if let h = model.status.hover { Button("To the height under the cursor") { model.edit("Water level") { $0.water[index].level = Float(h.y) + 0.5 } } }
            } else {
                Text("\(water.points.count) points along it").font(.caption).foregroundStyle(.secondary)
                TerrainSlider(title: "Width", value: b(\.width), range: 1...200, log: true, format: "%.1f m", onDrag: drag)
                TerrainSlider(title: "Depth", value: b(\.depth), range: 0.2...20, log: true, format: "%.1f m", onDrag: drag)
                Button("Carve its bed") { model.carveRiver(index) }
            }
            Divider()
            WaterLookEditor(index: index, water: water)
            Picker("Floating on it", selection: b(\.material)) {
                Text("Nothing").tag("")
                ForEach(MaterialCatalog.resolve(model.host.settings.scene.materials).names, id: \.self) { Text($0).tag($0) }
            }
            .help("A Material Designer graph lying on the water (duckweed, scum), cut out by its opacity")
        }
    }
}

/// A water's look (WaterLook): a preset to start from, then what it absorbs and scatters, its waves, its foam and its
/// flow. Edited live: the scene keeps its water's surfaces.
private struct WaterLookEditor: View {
    @EnvironmentObject var model: TerrainModel
    let index: Int
    let water: WaterBody

    private var look: WaterLook { water.appearance }
    private func b(_ path: WritableKeyPath<WaterLook, Float>) -> Binding<Float> {
        Binding(get: { look[keyPath: path] }, set: { v in
            model.edit("Water's look") { var l = $0.water[index].appearance; l[keyPath: path] = v; $0.water[index].look = l }
        })
    }
    /// A colour per metre, as a colour (its strongest channel 1) and how much of it (that channel's value).
    private func colour(_ path: WritableKeyPath<WaterLook, SIMD3<Float>>) -> Binding<Color> {
        Binding(get: {
            let c = look[keyPath: path], m = max(c.max(), 1e-6)
            return Color(red: Double(c.x / m), green: Double(c.y / m), blue: Double(c.z / m))
        }, set: { v in
            guard let rgb = NSColor(v).usingColorSpace(.deviceRGB) else { return }
            model.edit("Water's look") {
                var l = $0.water[index].appearance
                let strength = l[keyPath: path].max()
                l[keyPath: path] = SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent)) * max(strength, 0.001)
                $0.water[index].look = l
            }
        })
    }
    private func amount(_ path: WritableKeyPath<WaterLook, SIMD3<Float>>) -> Binding<Float> {
        Binding(get: { look[keyPath: path].max() }, set: { v in
            model.edit("Water's look") {
                var l = $0.water[index].appearance
                let c = l[keyPath: path], m = max(c.max(), 1e-6)
                l[keyPath: path] = (m > 1e-5 ? c / m : SIMD3(repeating: 1)) * v
                $0.water[index].look = l
            }
        })
    }
    private func drag(_ on: Bool) { on ? model.beginDrag() : model.endDrag() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Look").font(.headline)
                Spacer()
                Menu("Preset") {
                    ForEach(WaterLook.Preset.allCases) { p in
                        Button(p.title) { model.edit("Water's look") { $0.water[index].look = .preset(p) } }
                    }
                    Divider()
                    Button("Its kind's") { model.edit("Water's look") { $0.water[index].look = nil } }
                }
                .fixedSize()
            }
            HStack {
                ColorPicker("Takes", selection: colour(\.absorption), supportsOpacity: false)
                    .help("The colour the water takes out of the light going through it: red, for clear sea water")
                TerrainSlider(title: "per metre", value: amount(\.absorption), range: 0.01...4, log: true, format: "%.2f", onDrag: drag)
            }
            HStack {
                ColorPicker("Glows", selection: colour(\.scattering), supportsOpacity: false)
                    .help("The colour the water scatters back: its own colour in deep water, the haze under it")
                TerrainSlider(title: "per metre", value: amount(\.scattering), range: 0.001...1, log: true, format: "%.3f", onDrag: drag)
            }
            TerrainSlider(title: "Roughness", value: b(\.roughness), range: 0.002...0.3, log: true, format: "%.3f", onDrag: drag)
            TerrainSlider(title: "Waves (share of the wind's sea)", value: b(\.waves), range: 0...1, format: "%.2f", onDrag: drag)
            TerrainSlider(title: "Chop", value: b(\.chop), range: 0...1.5, format: "%.2f", onDrag: drag)
            TerrainSlider(title: "Ripples", value: b(\.ripples), range: 0...2, format: "%.2f", onDrag: drag)
            TerrainSlider(title: "Crest foam", value: b(\.foam), range: 0...1, format: "%.2f", onDrag: drag)
            TerrainSlider(title: "Shore foam (depth)", value: b(\.shoreFoam), range: 0...3, format: "%.2f m", onDrag: drag)
            if water.kind == .river {
                TerrainSlider(title: "Flow", value: b(\.flowSpeed), range: 0...5, format: "%.1f m/s", onDrag: drag)
                TerrainSlider(title: "White water", value: b(\.whiteWater), range: 0...1, format: "%.2f", onDrag: drag)
            }
        }
    }
}
