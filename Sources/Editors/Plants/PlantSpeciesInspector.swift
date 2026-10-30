import EngineCore
import Plants
import SwiftUI
import simd

/// What the species is besides how it grows: shown when no node is selected. Its colours, where it grows, how many
/// plants of each age.
struct PlantSpeciesInspector: View {
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.def.name).font(.headline)
            looks
            bark
            habitat
            ages
        }
    }

    private var looks: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorGroup(title: "Colours") {
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
            }
            .font(.system(size: 11))
        }
    }

    private var bark: some View {
        EditorGroup(title: "Bark") {
            LinearColorPicker(title: "Colour", color: $model.def.look.bark)
            Picker("Texture", selection: $model.def.look.barkTexture) {
                Text("Rough").tag(FoliageTextures.Kind.roughBark); Text("Birch").tag(FoliageTextures.Kind.birchBark)
            }
            .font(.system(size: 11))
            Text("Younger branches are paler; moss grows on the trunk's upper side, low down.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var habitat: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Grows as", selection: Binding(get: { model.def.role }, set: { setRole($0) })) {
                Text("Tree").tag(Foliage.Role.tree); Text("Bush").tag(Foliage.Role.bush); Text("Ground cover").tag(Foliage.Role.groundCover)
            }
            .pickerStyle(.segmented).font(.system(size: 11))
            if model.def.role == .tree {
                EditorGroup(title: "Its weight against the other trees") {
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
                EditorGroup(title: "How thickly it grows") {
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

    private var ages: some View {
        EditorGroup(title: "Variants of each age") {
            ForEach(Foliage.Age.allCases, id: \.self) { age in
                Stepper("\("\(age)".capitalized): \(model.def.variants(age))", value: Binding(
                    get: { model.def.ages.variants[age.rawValue] },
                    set: { model.def.ages.variants[age.rawValue] = $0 }), in: (age == .mature ? 1 : 0)...8)
                .font(.system(size: 11))
            }
            Text("How a younger plant grows is its Grower's.").font(.system(size: 10)).foregroundColor(.secondary)
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
