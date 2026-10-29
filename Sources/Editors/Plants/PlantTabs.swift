import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
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

/// What the growth tabs show for the grass: it isn't grown.
struct NotGrown: View {
    var body: some View {
        Text("Grass is patches of blades, not grown: see Leaves.").font(.system(size: 11)).foregroundColor(.secondary)
    }
}

/// How long the plant grows, toward what height, and its trunk's shoot.
struct GrowthTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        if model.def.growth != nil {
            let g = Binding($model.def.growth, or: Growth.Params())
            VStack(alignment: .leading, spacing: 8) {
                EditorGroup(title: "The plant") {
                    ParamRows(table: PlantParams.growth, root: g)
                    Text("Each cycle every live bud grows an internode or stays dormant; the plant stops at its height.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                EditorGroup(title: "The trunk", copy: { model.copy(.shoot) }, paste: { model.paste(.shoot) }) {
                    ShootEditor(shoot: g.trunk)
                }
            }
        } else {
            NotGrown()
        }
    }
}

/// The branches: their own shoot (or the trunk's), the hormones that hold buds back, forks and gravity.
struct BranchingTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        if model.def.growth != nil {
            let g = Binding($model.def.growth, or: Growth.Params())
            VStack(alignment: .leading, spacing: 8) {
                EditorGroup(title: "The branches", copy: { model.copy(.shoot, shoot: .branches) },
                            paste: { model.paste(.shoot, shoot: .branches) }) {
                    Toggle("Grow as the trunk does", isOn: Binding(get: { g.wrappedValue.branch == nil },
                                                                   set: { g.wrappedValue.branch = $0 ? nil : g.wrappedValue.trunk }))
                        .font(.system(size: 11))
                    if g.wrappedValue.branch != nil { ShootEditor(shoot: Binding(g.branch, or: Growth.Shoot())) }
                }
                EditorGroup(title: "Hormones") {
                    ParamRows(table: PlantParams.hormones, root: g)
                    Text("Dominance: buds near a growing tip stay dormant. Ethylene: old wood, bare of twigs.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                EditorGroup(title: "Forks") {
                    Toggle("Tips fork", isOn: Binding(get: { g.wrappedValue.bifurcation != nil },
                                                      set: { g.wrappedValue.bifurcation = $0 ? Growth.Bifurcation() : nil }))
                        .font(.system(size: 11))
                    if g.wrappedValue.bifurcation != nil {
                        ParamRows(table: PlantParams.bifurcation, root: Binding(g.bifurcation, or: Growth.Bifurcation()))
                    }
                }
                EditorGroup(title: "Gravity") {
                    ParamRows(table: PlantParams.gravity, root: g)
                    Text("The branches sag under their own weight, as beams.").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        } else {
            NotGrown()
        }
    }
}

/// The light the buds get (shadows cast down through the crown) and the shedding of shaded branches.
struct LightTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        if model.def.growth != nil {
            let g = Binding($model.def.growth, or: Growth.Params())
            VStack(alignment: .leading, spacing: 8) {
                EditorGroup(title: "Light", copy: { model.copy(.light) }, paste: { model.paste(.light) }) {
                    ParamRows(table: PlantParams.light, root: g.light)
                    Text("Shade from the wood and leaves above: buds without enough light stay dormant, and shaded internodes grow shorter.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                EditorGroup(title: "Senescence") {
                    Toggle("Sheds shaded branches", isOn: Binding(get: { g.wrappedValue.senescence != nil },
                                                                  set: { g.wrappedValue.senescence = $0 ? Growth.Senescence() : nil }))
                        .font(.system(size: 11))
                    if g.wrappedValue.senescence != nil {
                        ParamRows(table: PlantParams.senescence, root: Binding(g.senescence, or: Growth.Senescence()))
                    }
                }
            }
        } else {
            NotGrown()
        }
    }
}

/// The twigs (Unreal's graft palette and foliage distributor): where they hang, and the twig itself, grown as a
/// small plant of its own.
struct TwigsTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        if model.def.growth != nil {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Twigs (leafy sprays hung on the young wood)", isOn: Binding(get: { model.def.twigs != nil },
                                                                                   set: { model.def.twigs = $0 ? Growth.Twigs() : nil }))
                    .font(.system(size: 11))
                if model.def.twigs != nil {
                    let t = Binding($model.def.twigs, or: Growth.Twigs())
                    EditorGroup(title: "Where they hang", copy: { model.copy(.twigs) }, paste: { model.paste(.twigs) }) {
                        ParamRows(table: PlantParams.twigs, root: t)
                        Text("Kinds run from sparse (in the shade) to dense (in the light).")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    EditorGroup(title: "The twig") {
                        ParamRows(table: Array(PlantParams.growth.prefix(2)), root: t.growth)
                        ParamRows(table: Array(PlantParams.hormones.prefix(1)), root: t.growth)
                    }
                    EditorGroup(title: "Its stem", copy: { model.copy(.shoot, twig: true) }, paste: { model.paste(.shoot, twig: true) }) {
                        ShootEditor(shoot: t.growth.trunk)
                    }
                    EditorGroup(title: "Its side shoots", copy: { model.copy(.shoot, shoot: .branches, twig: true) },
                                paste: { model.paste(.shoot, shoot: .branches, twig: true) }) {
                        Toggle("Grow as its stem does", isOn: Binding(get: { t.wrappedValue.growth.branch == nil },
                                                                      set: { t.wrappedValue.growth.branch = $0 ? nil : t.wrappedValue.growth.trunk }))
                            .font(.system(size: 11))
                        if t.wrappedValue.growth.branch != nil { ShootEditor(shoot: Binding(t.growth.branch, or: Growth.Shoot())) }
                    }
                }
            }
        } else {
            NotGrown()
        }
    }
}

struct LeavesTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.def.grass != nil {
                EditorGroup(title: "Grass patch") {
                    ParamRows(table: PlantParams.grass, root: Binding($model.def.grass, or: Foliage.GrassPatch()))
                }
            } else {
                if model.def.twigs != nil {
                    EditorGroup(title: "On the twigs", copy: { model.copy(.leaves, twig: true) }, paste: { model.paste(.leaves, twig: true) }) {
                        LeafEditor(leaf: Binding(get: { model.def.twigs?.leaf ?? Foliage.LeafRecipe() },
                                                 set: { l in if model.def.twigs != nil { model.def.twigs?.leaf = l } }))
                    }
                }
                EditorGroup(title: "On the plant's own stems", copy: { model.copy(.leaves) }, paste: { model.paste(.leaves) }) {
                    Toggle("Leaves on its stems (a fern's pinnae)", isOn: Binding(get: { model.def.leaf != nil }, set: { on in
                        model.def.leaf = on ? Foliage.LeafRecipe() : nil
                    })).font(.system(size: 11))
                    if model.def.leaf != nil {
                        LeafEditor(leaf: Binding($model.def.leaf, or: Foliage.LeafRecipe()))
                    }
                }
            }
        }
    }
}

/// The wood: its colour and texture, how branches thin, how the axes wander, and the trunk's flared, buttressed foot.
struct BarkTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorGroup(title: "Bark") {
                LinearColorPicker(title: "Colour", color: $model.def.look.bark)
                Picker("Texture", selection: $model.def.look.barkTexture) {
                    Text("Rough").tag(FoliageTextures.Kind.roughBark); Text("Birch").tag(FoliageTextures.Kind.birchBark)
                }
                .font(.system(size: 11))
                Text("Younger branches are paler; moss grows on the trunk's upper side, low down.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if model.def.growth != nil {
                let g = Binding($model.def.growth, or: Growth.Params())
                EditorGroup(title: "Wood", copy: { model.copy(.wood) }, paste: { model.paste(.wood) }) {
                    ParamRows(table: PlantParams.wood, root: g.wood)
                    Toggle("Flat stems (ribbons, a fern's fronds)", isOn: g.wood.ribbon).font(.system(size: 11))
                }
            }
        }
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

struct LookTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorGroup(title: "Colours", copy: { model.copy(.look) }, paste: { model.paste(.look) }) {
                ForEach(model.def.look.leaves.indices, id: \.self) { i in
                    HStack {
                        LinearColorPicker(title: "Leaf shade \(i + 1)", color: Binding($model.def.look.leaves, i, or: .zero))
                        Spacer()
                        Button { if model.def.look.leaves.indices.contains(i) { model.def.look.leaves.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(model.def.look.leaves.count <= 1)
                    }
                }
                Button("Add a shade") { model.def.look.leaves.append(model.def.look.leaves.last ?? [0.12, 0.24, 0.07]) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Toggle("Turns in autumn", isOn: Binding(get: { model.def.look.autumn != nil },
                                                        set: { model.def.look.autumn = $0 ? [0.3, 0.14, 0.035] : nil })).font(.system(size: 11))
                if model.def.look.autumn != nil {
                    LinearColorPicker(title: "Autumn", color: Binding($model.def.look.autumn, or: [0.3, 0.14, 0.035]))
                }
            }
            EditorGroup(title: "Surface") {
                ParamRows(table: PlantParams.look, root: $model.def.look)
                Picker("Leaf texture", selection: $model.def.look.leafTexture) {
                    Text("Leaf").tag(FoliageTextures.Kind.leaf); Text("Needle").tag(FoliageTextures.Kind.needle)
                    Text("Grass").tag(FoliageTextures.Kind.grass)
                }
                Toggle("Evergreen (no leaf fall)", isOn: $model.def.look.evergreen)
                Toggle("Stems are leaves (fronds)", isOn: $model.def.stemsAreLeaves)
            }
            .font(.system(size: 11))
        }
    }
}

struct HabitatTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Grows as", selection: Binding(get: { model.def.role }, set: { setRole($0) })) {
                Text("Tree").tag(Foliage.Role.tree); Text("Bush").tag(Foliage.Role.bush); Text("Ground cover").tag(Foliage.Role.groundCover)
            }
            .pickerStyle(.segmented).font(.system(size: 11))
            if model.def.role == .tree {
                EditorGroup(title: "Its weight against the other trees", copy: { model.copy(.habitat) }, paste: { model.paste(.habitat) }) {
                    Toggle("A fixed share of all trees", isOn: Binding(get: { model.def.habitat.share != nil },
                                                                       set: { model.def.habitat.share = $0 ? 0.03 : nil })).font(.system(size: 11))
                    if model.def.habitat.share != nil {
                        ValueRow(title: "Share", value: Binding(get: { model.def.habitat.share ?? 0 }, set: { model.def.habitat.share = $0 }),
                                 range: 0...0.5, digits: 3)
                        ParamRows(table: Array(PlantParams.tree.suffix(2)), root: $model.def.habitat)
                    } else {
                        ParamRows(table: PlantParams.tree, root: $model.def.habitat)
                    }
                }
                Text("Height: 0 on low ground, 1 up the hills. Stand: −1…1 patches. Light: clearings, edges, the trail.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else if model.def.habitat.cover != nil {
                EditorGroup(title: "How thickly it grows", copy: { model.copy(.habitat) }, paste: { model.paste(.habitat) }) {
                    ParamRows(table: Array(PlantParams.tree.prefix(1)), root: $model.def.habitat)
                    ParamRows(table: PlantParams.cover, root: Binding($model.def.habitat.cover, or: Foliage.Habitat.Cover()))
                    Toggle("In the open (not under the trees)", isOn: Binding(get: { model.def.habitat.cover?.open ?? false },
                                                                             set: { model.def.habitat.cover?.open = $0 })).font(.system(size: 11))
                    Toggle("On a grid in the forest's clearing", isOn: Binding(get: { model.def.habitat.cover?.grid != nil },
                                                                               set: { model.def.habitat.cover?.grid = $0 ? 2 : nil })).font(.system(size: 11))
                }
            }
            Stepper("Order among the others: \(model.def.habitat.order)", value: $model.def.habitat.order, in: 0...999).font(.system(size: 11))
            Text("Where it grows shows in the Forest and the Open world, not the workshop.").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func setRole(_ role: Foliage.Role) {
        var d = model.def
        d.role = role
        if role != .tree, d.habitat.cover == nil { d.habitat.cover = Foliage.Habitat.Cover() }
        if role == .tree { d.habitat.cover = nil }
        model.def = d
    }
}

struct AgesTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorGroup(title: "Variants of each age") {
                ForEach(Foliage.Age.allCases, id: \.self) { age in
                    Stepper("\("\(age)".capitalized): \(model.def.variants(age))", value: Binding(
                        get: { model.def.ages.variants[age.rawValue] },
                        set: { model.def.ages.variants[age.rawValue] = $0 }), in: (age == .mature ? 1 : 0)...8)
                    .font(.system(size: 11))
                }
            }
            if model.def.growth != nil {
                let g = Binding($model.def.growth, or: Growth.Params())
                EditorGroup(title: "Young: of the mature plant") { ParamRows(table: PlantParams.age, root: g.young) }
                EditorGroup(title: "Sapling: of the mature plant") { ParamRows(table: PlantParams.age, root: g.sapling) }
                Text("A younger plant is the same seed grown fewer cycles toward a lower height.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}
