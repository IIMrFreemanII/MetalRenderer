import SwiftUI
import simd

/// Bindings SwiftUI may still read after an edit took away what they point at (a level removed, the boughs or a
/// cover turned off, an undo): they read a stand-in then, and write nothing.
extension Binding {
    /// Element `i` of `array`, or `stand` once the array is shorter.
    init<E>(_ array: Binding<[E]>, _ i: Int, or stand: E) where Value == E {
        self.init(get: { array.wrappedValue.indices.contains(i) ? array.wrappedValue[i] : stand },
                  set: { if array.wrappedValue.indices.contains(i) { array.wrappedValue[i] = $0 } })
    }
    /// What `optional` holds, or `stand` while it holds nothing (a write then is dropped).
    init<W>(_ optional: Binding<W?>, or stand: W) where Value == W {
        self.init(get: { optional.wrappedValue ?? stand }, set: { if optional.wrappedValue != nil { optional.wrappedValue = $0 } })
    }
}

/// A recipe's stem levels: a picker of levels (with + and −), the level's numbers and curves, and the recipe's own
/// numbers. For a plant's recipe or its boughs'.
struct LevelEditor: View {
    @Binding var recipe: Foliage.Recipe
    var bough = false
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        let count = recipe.levels.count, l = min(model.level, count - 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: Binding(get: { l }, set: { model.level = $0 })) {
                    ForEach(0..<count, id: \.self) { i in Text(i == 0 ? (bough ? "Twig" : "Trunk") : "Level \(i)").tag(i) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Button { addLevel() } label: { Image(systemName: "plus") }.disabled(count >= 6).help("Add a level of stems")
                Button { removeLevel() } label: { Image(systemName: "minus") }.disabled(count <= 1).help("Remove the last level")
            }
            EditorGroup(title: l == 0 ? (bough ? "Twig" : "Stems from the ground") : "Level \(l)", clip: .level, bough: bough) {
                ParamRows(table: l == 0 ? PlantParams.trunk : PlantParams.level, root: level(l))
                if l == 0 {
                    ValueRow(title: "Lean (several stems)", value: Binding(get: { recipe.levels[0].down.start },
                                                                          set: { recipe.levels[0].down = .linear($0, $0) }),
                             range: 0...Double.pi / 2)
                }
            }
            if l > 0 {
                EditorGroup(title: "Curves") {
                    CurveEditor(title: l == 1 && !bough ? "Crown profile: limb length up the trunk" : "Length along the parent",
                                curve: level(l).along, range: 0...1.4, crowns: l == 1, lineRange: 0...1.4,
                                xLabel: "parent's foot → tip")
                    CurveEditor(title: "Angle from the parent", curve: level(l).down, range: 0...Float.pi,
                                lineRange: 0...Double.pi, xLabel: "parent's foot → tip")
                    CurveEditor(title: "Radius along the stem", curve: level(l).radius, range: 0...1.4, lineRange: 0...1.4)
                }
            } else {
                EditorGroup(title: "Curves") {
                    CurveEditor(title: "Radius along the stem", curve: level(0).radius, range: 0...1.4, lineRange: 0...1.4)
                }
            }
            if !bough {
                EditorGroup(title: "Thickness and shape") {
                    ParamRows(table: PlantParams.recipe, root: $recipe)
                    Toggle("Prune to an ellipsoid", isOn: Binding(get: { recipe.carve != nil }, set: { on in
                        recipe.carve = on ? Foliage.Carve(center: [0, recipe.levels[0].length * 0.6, 0],
                                                          radii: SIMD3(repeating: max(recipe.levels[0].length * 0.6, 0.3)), fromLevel: 0) : nil
                    })).font(.system(size: 11))
                    if recipe.carve != nil {
                        ValueRow(title: "Centre height", value: carve(\.center.y), range: 0...20)
                        ValueRow(title: "Half width", value: Binding(get: { recipe.carve?.radii.x ?? 1 },
                                                                     set: { recipe.carve?.radii.x = $0; recipe.carve?.radii.z = $0 }), range: 0.1...15)
                        ValueRow(title: "Half height", value: carve(\.radii.y), range: 0.1...15)
                    }
                }
            }
        }
    }

    private func level(_ l: Int) -> Binding<Foliage.Level> { Binding($recipe.levels, l, or: Foliage.Level()) }

    private func carve(_ path: WritableKeyPath<Foliage.Carve, Float>) -> Binding<Float> {
        Binding(get: { recipe.carve?[keyPath: path] ?? 0 }, set: { recipe.carve?[keyPath: path] = $0 })
    }

    private func addLevel() {
        var r = recipe
        var next = r.levels.count > 1 ? r.levels[r.levels.count - 1] : Foliage.Level(count: 5, length: 0.5)
        next.count = max(2, next.count / 2)
        next.along = .taper(0.5)
        r.levels.append(next)
        recipe = r
        model.level = r.levels.count - 1
    }

    private func removeLevel() {
        var r = recipe
        r.levels.removeLast()
        recipe = r
        model.level = min(model.level, r.levels.count - 1)
    }
}

struct StemsTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        if model.def.grass != nil {
            Text("Grass is patches of blades, not grown stems: see Leaves.").font(.system(size: 11)).foregroundColor(.secondary)
        } else {
            LevelEditor(recipe: $model.def.recipe)
        }
    }
}

/// A leaf recipe: its shape, arrangement, numbers and size along the twig.
struct LeafEditor: View {
    @Binding var leaf: Foliage.LeafRecipe

    var body: some View {
        Picker("Shape", selection: $leaf.shape) {
            ForEach(Foliage.LeafShape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.segmented).font(.system(size: 11))
        HStack {
            Picker("Arrangement", selection: Binding(get: { arrangement }, set: { a in
                leaf.phyllotaxis = a == 0 ? .spiral : a == 1 ? .distichous : .whorled(3)
            })) {
                Text("Spiral").tag(0); Text("Opposite sides").tag(1); Text("Whorls").tag(2)
            }
            if case .whorled(let n) = leaf.phyllotaxis {
                Stepper("of \(n)", value: Binding(get: { n }, set: { leaf.phyllotaxis = .whorled(min(max($0, 2), 8)) }), in: 2...8)
            }
        }
        .font(.system(size: 11))
        ParamRows(table: PlantParams.leaf, root: $leaf)
        CurveEditor(title: "Size along the twig", curve: $leaf.size, range: 0...1.6, lineRange: 0...2)
    }

    private var arrangement: Int {
        switch leaf.phyllotaxis { case .spiral: return 0; case .distichous: return 1; case .whorled: return 2 }
    }
}

struct LeavesTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let grass = model.def.grass {
                EditorGroup(title: "Grass patch") {
                    ValueRow(title: "Size", value: Binding(get: { grass.size }, set: { model.def.grass?.size = $0 }), range: 0.5...6, digits: 1)
                    ValueRow(title: "Blades", value: Binding(get: { Float(grass.blades) }, set: { model.def.grass?.blades = Int($0) }),
                             range: 50...3000, digits: 0)
                }
            } else {
                if model.def.bough != nil {
                    EditorGroup(title: "On the boughs", clip: .leaves, bough: true) {
                        if model.def.bough?.leaf != nil {
                            LeafEditor(leaf: Binding(get: { model.def.bough?.leaf ?? Foliage.LeafRecipe() },
                                                     set: { l in if model.def.bough?.leaf != nil { model.def.bough?.leaf = l } }))
                        } else {
                            Button("Add leaves to the boughs") { model.def.bough?.leaf = Foliage.LeafRecipe() }
                        }
                    }
                }
                EditorGroup(title: "On the plant's own stems", clip: .leaves) {
                    Toggle("Leaves on its stems", isOn: Binding(get: { model.def.recipe.leaf != nil }, set: { on in
                        model.def.recipe.leaf = on ? Foliage.LeafRecipe(fromLevel: max(model.def.recipe.levels.count - 1, 0)) : nil
                    })).font(.system(size: 11))
                    if model.def.recipe.leaf != nil {
                        LeafEditor(leaf: Binding($model.def.recipe.leaf, or: Foliage.LeafRecipe()))
                    }
                }
            }
        }
    }
}

struct BoughsTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Boughs (leafy twigs hung on the limbs)", isOn: Binding(get: { model.def.bough != nil && model.def.recipe.graft != nil },
                                                                           set: { on in setBoughs(on) }))
                .font(.system(size: 11)).disabled(model.def.grass != nil)
            if model.def.bough != nil, model.def.recipe.graft != nil {
                EditorGroup(title: "Where they hang", clip: .graft) {
                    ParamRows(table: PlantParams.graft, root: Binding($model.def.recipe.graft, or: Foliage.Graft()))
                    ParamRows(table: PlantParams.palette, root: $model.def.palette)
                }
                Text("The bough").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                LevelEditor(recipe: Binding($model.def.bough, or: Foliage.Recipe(levels: [Foliage.Level()])), bough: true)
            }
        }
    }

    private func setBoughs(_ on: Bool) {
        var d = model.def
        if on {
            d.bough = d.bough ?? PlantCatalog.builtIn[.oak].bough
            d.recipe.graft = d.recipe.graft ?? Foliage.Graft()
        } else {
            d.bough = nil
            d.recipe.graft = nil
        }
        model.def = d
    }
}

struct LookTab: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorGroup(title: "Colours", clip: .look) {
                LinearColorPicker(title: "Bark", color: $model.def.look.bark)
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
                Picker("Bark texture", selection: $model.def.look.barkTexture) {
                    Text("Rough").tag(FoliageTextures.Kind.roughBark); Text("Birch").tag(FoliageTextures.Kind.birchBark)
                }
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
                EditorGroup(title: "Its weight against the other trees", clip: .habitat) {
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
                EditorGroup(title: "How thickly it grows", clip: .habitat) {
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
            rule("Young", $model.def.ages.young)
            rule("Sapling", $model.def.ages.sapling)
        }
    }

    private func rule(_ title: String, _ rule: Binding<Foliage.AgeRule>) -> some View {
        EditorGroup(title: "\(title): of the mature plant") {
            ParamRows(table: PlantParams.age, root: rule)
            Stepper("Levels kept: \(rule.wrappedValue.maxLevels.map(String.init) ?? "all")", value: Binding(
                get: { rule.wrappedValue.maxLevels ?? 7 }, set: { rule.wrappedValue.maxLevels = $0 >= 7 ? nil : $0 }), in: 1...7)
                .font(.system(size: 11))
            ForEach(rule.wrappedValue.counts.indices, id: \.self) { i in
                HStack {
                    Text("Level \(rule.wrappedValue.counts[safe: i]?.level ?? 0) children").font(.system(size: 11)).frame(width: 100, alignment: .leading)
                    let count = Binding(rule.counts, i, or: Foliage.CountRule(level: 1, factor: 1, minimum: 0))
                    Slider(value: count.factor, in: 0...1) { editing in editing ? model.beginDrag() : model.endDrag() }
                        .controlSize(.small)
                    Text(String(format: "×%.2f", count.wrappedValue.factor)).monospacedDigit().foregroundColor(.secondary)
                        .font(.system(size: 11)).frame(width: 40, alignment: .trailing)
                    Stepper("≥ \(count.wrappedValue.minimum)", value: count.minimum, in: 0...20).font(.system(size: 11))
                    Button { if rule.wrappedValue.counts.indices.contains(i) { rule.wrappedValue.counts.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Fewer children on a level") {
                let used = Set(rule.wrappedValue.counts.map(\.level))
                let free = (1..<max(model.def.recipe.levels.count, 2)).first { !used.contains($0) } ?? 1
                rule.wrappedValue.counts.append(Foliage.CountRule(level: free, factor: 0.75, minimum: 2))
            }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
    }
}
