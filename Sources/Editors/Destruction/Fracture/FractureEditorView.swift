import Characters
import Effects
import EngineCore
import MetalRenderer
import Physics
import Plants
import SwiftUI

/// The Fracture Editor's window: the destruction scene's objects, the selected one's recipe (material, pattern, seed,
/// pieces at each level, how hard it breaks, the pattern's own shape), a preview of its pieces held apart, and what
/// it is made of.
struct FractureEditorView: View {
    @EnvironmentObject var model: FractureEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.inScene || model.objects.isEmpty {
                Text("The Fracture Editor edits the Destruction scene's objects.").foregroundColor(.secondary)
                Button("Open the Destruction scene") { model.openScene() }
                Spacer()
            } else {
                Picker("Object", selection: $model.selected) {
                    ForEach(model.objects, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
                Form {
                    recipeSection
                    previewSection
                    if let info = model.info {
                        Section(header: Text("Made of")) {
                            Text("\(info.nodes) bodies in \(info.levels) levels, \(info.leaves) smallest pieces, \(info.welds) welds")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Apply") { model.apply() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.edited)
                    Button("Revert") { model.revert() }
                    Spacer()
                    Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command)
                }
                Text(model.message).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 380, minHeight: 520)
    }

    private var recipeSection: some View {
        Section(header: Text("Recipe")) {
            Picker("Material", selection: binding(\.material)) {
                ForEach(FractureMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Pattern", selection: binding(\.pattern)) {
                ForEach(FracturePattern.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Seed \(model.recipe.seed)")
                Spacer()
                Button("New seed") { model.reseed() }
            }
            ForEach(0..<FractureRecipe.maxLevels, id: \.self) { level in
                count(level)
            }
            slider("Toughness", \.toughness, 0.1...10, log: true)
            slider("Weld strength", \.strength, 0.1...10, log: true)
            slider("Clustering", \.clustering, 0...1)
            slider("Jitter", \.jitter, 0...1)
            switch model.recipe.pattern {
            case .splinters:
                Picker("Grain", selection: binding(\.grain)) {
                    Text("X").tag(SIMD3<Float>(1, 0, 0)); Text("Y").tag(SIMD3<Float>(0, 1, 0)); Text("Z").tag(SIMD3<Float>(0, 0, 1))
                }
                slider("Stretch", \.stretch, 1...10)
            case .bricks:
                slider("Brick length", \.brick.x, 0.1...0.8)
                slider("Brick height", \.brick.y, 0.04...0.4)
            case .radial:
                slider("Crack centre x", \.centre.x, -0.6...0.6)
                slider("Crack centre y", \.centre.y, -0.8...0.8)
            case .voronoi:
                EmptyView()
            }
        }
    }

    private var previewSection: some View {
        Section(header: Text("Preview")) {
            Toggle("Pieces held apart", isOn: Binding(get: { model.previewing }, set: { model.previewing = $0; model.updatePreview() }))
            Stepper("Level \(model.level)", value: Binding(get: { model.level }, set: { model.level = $0; if model.previewing { model.updatePreview() } }),
                    in: 1...max((model.info?.levels ?? 2) - 1, 1))
            HStack {
                Text("Apart")
                Slider(value: Binding(get: { Double(model.explode) }, set: { model.explode = Float($0) }), in: 0...1.5,
                       onEditingChanged: { editing in if !editing && model.previewing { model.updatePreview() } })
            }
        }
    }

    /// Level `level`'s pieces a piece (0: it isn't cut; bricks' first level is the courses').
    private func count(_ level: Int) -> some View {
        let value = Binding<Double>(get: { Double(level < model.recipe.counts.count ? model.recipe.counts[level] : 0) },
                                    set: { v in
                                        while model.recipe.counts.count <= level { model.recipe.counts.append(0) }
                                        model.recipe.counts[level] = Int(v.rounded())
                                        model.changed()
                                    })
        let top: Double = level == 0 ? 64 : level == 1 ? 16 : 8
        return HStack {
            Text(level == 0 ? "Pieces" : "Then each in")
            Slider(value: value, in: 0...top, step: 1)
            Text("\(Int(value.wrappedValue))").frame(width: 28, alignment: .trailing)
        }
    }

    private func binding<T>(_ path: WritableKeyPath<FractureRecipe, T>) -> Binding<T> {
        Binding(get: { model.recipe[keyPath: path] }, set: { model.recipe[keyPath: path] = $0; model.changed() })
    }

    private func slider(_ title: String, _ path: WritableKeyPath<FractureRecipe, Float>, _ range: ClosedRange<Float>, log: Bool = false) -> some View {
        let value = Binding<Double>(
            get: { let v = Double(model.recipe[keyPath: path]); return log ? log2(max(v, 1e-6)) : v },
            set: { x in model.recipe[keyPath: path] = Float(log ? pow(2, x) : x); model.changed() })
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        return HStack {
            Text(title)
            Slider(value: value, in: (log ? log2(lo) : lo)...(log ? log2(hi) : hi))
            Text(String(format: "%.2f", model.recipe[keyPath: path])).frame(width: 40, alignment: .trailing)
        }
    }
}
