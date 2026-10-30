import EngineCore
import Plants
import SwiftUI
import simd

/// Bindings SwiftUI may still read after an edit took away what they point at (the twigs, forks or a cover turned
/// off, an undo): they read a stand-in then, and write nothing.
extension Binding {
    /// Element `i` of `array`, or `stand` once the array is shorter.
    package init<E>(_ array: Binding<[E]>, _ i: Int, or stand: E) where Value == E {
        self.init(get: { array.wrappedValue.indices.contains(i) ? array.wrappedValue[i] : stand },
                  set: { if array.wrappedValue.indices.contains(i) { array.wrappedValue[i] = $0 } })
    }
    /// What `optional` holds, or `stand` while it holds nothing (a write then is dropped).
    package init<W>(_ optional: Binding<W?>, or stand: W) where Value == W {
        self.init(get: { optional.wrappedValue ?? stand }, set: { if optional.wrappedValue != nil { optional.wrappedValue = $0 } })
    }
}

/// How buds (or leaves) are set round an axis: a spiral, alternate sides, or whorls of n.
struct PhyllotaxisPicker: View {
    var title = "Buds"
    @Binding var phyllotaxis: Foliage.Phyllotaxis

    var body: some View {
        HStack {
            Picker(title, selection: Binding(get: { kind }, set: { k in
                phyllotaxis = k == 0 ? .spiral : k == 1 ? .distichous : .whorled(3)
            })) {
                Text("Spiral").tag(0); Text("Alternate").tag(1); Text("Whorls").tag(2)
            }
            if case .whorled(let n) = phyllotaxis {
                Stepper("of \(n)", value: Binding(get: { n }, set: { phyllotaxis = .whorled(min(max($0, 2), 8)) }), in: 2...8)
            }
        }
        .font(.system(size: 11))
    }

    private var kind: Int {
        switch phyllotaxis { case .spiral: return 0; case .distichous: return 1; case .whorled: return 2 }
    }
}

/// One kind of axis (the trunk's, the branches', a twig's): its numbers, how its buds are set, and its two ramps by
/// how far up toward the target height a bud is (Unreal's apical and axillary priority ramps).
struct ShootEditor: View {
    @Binding var shoot: Growth.Shoot

    var body: some View {
        ParamRows(table: PlantParams.shoot, root: $shoot)
        PhyllotaxisPicker(phyllotaxis: $shoot.phyllotaxis)
        CurveEditor(title: "Tip growth (1: grows on)", curve: $shoot.apicalRamp, range: 0...1.2, lineRange: 0...1,
                    xLabel: "foot → target height")
        CurveEditor(title: "Buds sprouting", curve: $shoot.axillaryRamp, range: 0...1.2, lineRange: 0...1,
                    xLabel: "foot → target height")
    }
}

/// A leaf recipe: its shape, arrangement, numbers and size along the stem it grows on.
struct LeafEditor: View {
    @Binding var leaf: Foliage.LeafRecipe

    var body: some View {
        Picker("Shape", selection: $leaf.shape) {
            ForEach(Foliage.LeafShape.allCases, id: \.self) { Text($0 == .outline ? "Scanned" : $0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.segmented).font(.system(size: 11))
        PhyllotaxisPicker(title: "Arrangement", phyllotaxis: $leaf.phyllotaxis)
        ParamRows(table: PlantParams.leaf, root: $leaf)
        CurveEditor(title: "Size along the stem", curve: $leaf.size, range: 0...1.6, lineRange: 0...2)
    }
}

/// A Grower's settings: how long the plant grows, its axes, the hormones that hold buds back, its light, its ages.
struct GrowInspector: View {
    @Binding var g: Growth.Params

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorGroup(title: "The plant") {
                ParamRows(table: PlantParams.growth, root: $g)
                Text("Each cycle every live bud grows an internode or stays dormant; the plant stops at its height.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            EditorGroup(title: "The trunk") { ShootEditor(shoot: $g.trunk) }
            EditorGroup(title: "The branches") {
                Toggle("Grow as the trunk does", isOn: Binding(get: { g.branch == nil }, set: { g.branch = $0 ? nil : g.trunk }))
                    .font(.system(size: 11))
                if g.branch != nil { ShootEditor(shoot: Binding($g.branch, or: Growth.Shoot())) }
            }
            EditorGroup(title: "Hormones") {
                ParamRows(table: PlantParams.hormones, root: $g)
                Text("Dominance: buds near a growing tip stay dormant. Ethylene: old wood, bare of twigs.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            EditorGroup(title: "Forks") {
                Toggle("Tips fork", isOn: Binding(get: { g.bifurcation != nil }, set: { g.bifurcation = $0 ? Growth.Bifurcation() : nil }))
                    .font(.system(size: 11))
                if g.bifurcation != nil { ParamRows(table: PlantParams.bifurcation, root: Binding($g.bifurcation, or: Growth.Bifurcation())) }
            }
            EditorGroup(title: "Gravity") {
                ParamRows(table: PlantParams.gravity, root: $g)
                Text("The branches sag under their own weight, as beams.").font(.system(size: 10)).foregroundColor(.secondary)
            }
            EditorGroup(title: "Light") {
                ParamRows(table: PlantParams.light, root: $g.light)
                Text("Shade from the wood and leaves above: buds without enough light stay dormant, and shaded internodes grow shorter.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            EditorGroup(title: "Senescence") {
                Toggle("Sheds shaded branches", isOn: Binding(get: { g.senescence != nil }, set: { g.senescence = $0 ? Growth.Senescence() : nil }))
                    .font(.system(size: 11))
                if g.senescence != nil { ParamRows(table: PlantParams.senescence, root: Binding($g.senescence, or: Growth.Senescence())) }
            }
            EditorGroup(title: "Young: of the mature plant") { ParamRows(table: PlantParams.age, root: $g.young) }
            EditorGroup(title: "Sapling: of the mature plant") { ParamRows(table: PlantParams.age, root: $g.sapling) }
        }
    }
}

/// What the selected node's settings are: the sliders of the tables its kind has.
struct PlantNodeInspector: View {
    @ObservedObject var model: PlantEditorModel
    let node: PlantNode

    /// The node's settings of one kind, read and written through the model.
    private func settings<T>(_ read: @escaping (PlantNodeSettings) -> T?, _ write: @escaping (T) -> PlantNodeSettings, or stand: T) -> Binding<T> {
        let id = node.id
        return Binding(get: { model.graph.node(id).flatMap { read($0.settings) } ?? stand },
                       set: { model.setSettings(id, write($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.kind.title).font(.headline)
                Text(node.name).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
            }
            ForEach(node.doc, id: \.self) { line in
                Text(line.replacingOccurrences(of: #"^//+\s?"#, with: "", options: .regularExpression)).font(.system(size: 10)).foregroundColor(.secondary)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch node.settings {
        case .grow:
            GrowInspector(g: settings({ if case .grow(let s) = $0 { return s } else { return nil } }, { .grow($0) }, or: Growth.Params()))
        case .growMore:
            let s = settings({ if case .growMore(let s) = $0 { return s } else { return nil } }, { .growMore($0) }, or: Growth.GrowMore())
            EditorGroup(title: "Grows on") {
                Stepper("\(s.wrappedValue.cycles) cycles", value: s.cycles, in: 1...40).font(.system(size: 11))
                Toggle("Its grafts and spurs grow too", isOn: s.revive).font(.system(size: 11))
            }
        case .grafts:
            let s = settings({ if case .grafts(let s) = $0 { return s } else { return nil } }, { .grafts($0) }, or: Growth.Grafts())
            EditorGroup(title: "Grafts") {
                Stepper("\(s.wrappedValue.perBranch) on a branch", value: s.perBranch, in: 1...12).font(.system(size: 11))
                Stepper("From generation \(s.wrappedValue.fromGeneration)", value: s.fromGeneration, in: 1...8).font(.system(size: 11))
                Stepper("\(s.wrappedValue.segments) internodes", value: s.segments, in: 1...8).font(.system(size: 11))
                ValueRow(title: "From the root's share", value: s.from, range: 0...1)
                ValueRow(title: "Internode", value: s.length, range: 0.02...1, unit: "m")
                ValueRow(title: "Size, inside", value: s.scale.x, range: 0...4)
                ValueRow(title: "Size, at the tips", value: s.scale.y, range: 0...4)
                ValueRow(title: "Angle, inside", value: s.angle.x, range: 0...1.6)
                ValueRow(title: "Angle, at the tips", value: s.angle.y, range: 0...1.6)
            }
        case .spurs:
            let s = settings({ if case .spurs(let s) = $0 { return s } else { return nil } }, { .spurs($0) }, or: Growth.Spurs())
            EditorGroup(title: "Spurs") {
                ValueRow(title: "Length", value: s.length, range: 0.02...1.5, unit: "m")
                ValueRow(title: "Angle", value: s.angle, range: 0...1.6)
                Stepper("From node \(s.wrappedValue.fromNode)", value: s.fromNode, in: 0...12).font(.system(size: 11))
            }
        case .carve:
            let s = settings({ if case .carve(let s) = $0 { return s } else { return nil } }, { .carve($0) }, or: Growth.Carve())
            EditorGroup(title: "Carve") { ValueRow(title: "The trunk's foot cut off", value: s.share, range: 0...0.6) }
        case .skeleton:
            let s = settings({ if case .skeleton(let s) = $0 { return s } else { return nil } }, { .skeleton($0) }, or: Growth.Wood())
            EditorGroup(title: "Wood") {
                ParamRows(table: PlantParams.wood, root: s)
                Toggle("Flat stems (ribbons, a fern's fronds)", isOn: s.ribbon).font(.system(size: 11))
            }
        case .leaves:
            EditorGroup(title: "Leaves") {
                LeafEditor(leaf: settings({ if case .leaves(let s) = $0 { return s } else { return nil } }, { .leaves($0) }, or: Foliage.LeafRecipe()))
            }
        case .twig:
            Text("Its wood and its leaves, as many as its place in the palette has.").font(.system(size: 11)).foregroundColor(.secondary)
        case .palette:
            let s = settings({ if case .palette(let s) = $0 { return s } else { return nil } }, { .palette($0) }, or: Foliage.Palette())
            EditorGroup(title: "The twigs") {
                Stepper("\(s.wrappedValue.count) of them", value: s.count, in: 1...16).font(.system(size: 11))
                ValueRow(title: "The sparsest's leaves", value: Binding(get: { s.wrappedValue.sparse ?? 0.55 }, set: { s.wrappedValue.sparse = $0 }), range: 0...1)
                Text("They run from sparse (in the shade) to dense (in the light).").font(.system(size: 10)).foregroundColor(.secondary)
            }
        case .distribute:
            let s = settings({ if case .distribute(let s) = $0 { return s } else { return nil } }, { .distribute($0) }, or: Growth.Twigs())
            EditorGroup(title: "Where they hang") {
                ParamRows(table: PlantParams.twigs, root: s)
                Toggle("Left and right of the branch in turn", isOn: Binding(get: { s.wrappedValue.alternate == true }, set: { s.wrappedValue.alternate = $0 ? true : nil }))
                    .font(.system(size: 11))
            }
        case .output:
            let s = settings({ if case .output(let s) = $0 { return s } else { return nil } }, { .output($0) }, or: Foliage.Assembly())
            EditorGroup(title: "The plant") { Toggle("Stems are leaves (fronds)", isOn: s.stemsAreLeaves).font(.system(size: 11)) }
        case .grass:
            let s = settings({ if case .grass(let s) = $0 { return s } else { return nil } }, { .grass($0) }, or: Foliage.GrassPatch())
            EditorGroup(title: "Grass patch") { ParamRows(table: PlantParams.grass, root: s) }
        case .code:
            let s = settings({ if case .code(let s) = $0 { return s } else { return nil } }, { .code($0) }, or: PlantCode(text: ""))
            VStack(alignment: .leading, spacing: 4) {
                Text("Its function, on what's wired in. It runs from the next time it compiles.").font(.system(size: 10)).foregroundColor(.secondary)
                TextEditor(text: s.text).font(.system(size: 11, design: .monospaced)).frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        case .statement(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Swift the graph can't read as a stage, kept as it's written. It runs when its file is compiled.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}
