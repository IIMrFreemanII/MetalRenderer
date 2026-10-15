import SwiftUI
import simd

// MARK: - Controls for a style's choices

/// A choice of numbers (Choice<Float>): a slider for each option, and one more or one fewer.
struct FloatChoiceRow: View {
    let title: String
    @Binding var choice: Choice<Float>
    let range: ClosedRange<Double>
    var digits = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Button { choice.options.append(choice.options.last ?? Float(range.lowerBound)) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                Button { if choice.options.count > 1 { choice.options.removeLast() } } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(choice.options.count <= 1)
            }
            ForEach(choice.options.indices, id: \.self) { i in
                ValueRow(title: choice.options.count > 1 ? "  or" : "  always", value: Binding($choice.options, i, or: 0), range: range, digits: digits)
            }
        }
    }
}

/// A choice of whole numbers (Choice<Int>).
struct IntChoiceRow: View {
    let title: String
    @Binding var choice: Choice<Int>
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 130, alignment: .leading)
            ForEach(choice.options.indices, id: \.self) { i in
                Stepper("\(choice.options[i])", value: Binding($choice.options, i, or: 0), in: range).font(.system(size: 11)).fixedSize()
            }
            Spacer()
            Button { choice.options.append(choice.options.last ?? range.lowerBound) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            Button { if choice.options.count > 1 { choice.options.removeLast() } } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).disabled(choice.options.count <= 1)
        }
    }
}

/// A choice among an enum's cases: a toggle for each (at least one stays on).
struct CaseChoiceRow<T: CaseIterable & Equatable & Codable & Hashable>: View {
    let title: String
    @Binding var options: [T]
    let name: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).frame(width: 130, alignment: .leading)
            ForEach(Array(T.allCases), id: \.self) { c in
                let on = options.contains(c)
                Button(name(c)) {
                    if on { if options.count > 1 { options.removeAll { $0 == c } } } else { options.append(c) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor.opacity(0.3) : Color.clear))
            }
            Spacer()
        }
    }
}

/// A list of colours to pick from: a well for each, one more or one fewer.
struct ColorListRow: View {
    let title: String
    @Binding var colors: [SIMD3<Float>]

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).frame(width: 90, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(colors.indices, id: \.self) { i in
                        LinearColorPicker(title: "", color: Binding($colors, i, or: SIMD3(repeating: 0.5))).labelsHidden().frame(width: 34)
                    }
                }
            }
            Button { colors.append(colors.last ?? SIMD3(repeating: 0.7)) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            Button { if colors.count > 1 { colors.removeLast() } } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).disabled(colors.count <= 1)
        }
    }
}

/// A material of a style's palette: its colours, how much they vary, its surface.
struct MaterialEditor: View {
    let title: String
    @Binding var material: MaterialDef

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ColorListRow(title: title, colors: $material.colors)
            HStack {
                Picker("", selection: Binding(get: { material.finishes.first?.surface }, set: { s in
                    if material.finishes.isEmpty { material.finishes = [MaterialDef.Finish()] }
                    material.finishes[0].surface = s
                })) {
                    Text("Plain").tag(SurfaceKind?.none)
                    ForEach(SurfaceKind.allCases, id: \.self) { Text("\($0)".capitalized).tag(SurfaceKind?.some($0)) }
                }
                .labelsHidden().frame(width: 110)
                Toggle("Glossy", isOn: Binding(get: { material.finishes.first?.specular ?? false }, set: { v in
                    if material.finishes.isEmpty { material.finishes = [MaterialDef.Finish()] }
                    material.finishes[0].specular = v
                    if v && material.finishes[0].roughness > 0.8 { material.finishes[0].roughness = 0.4 }
                })).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
            }
            ValueRow(title: "Shade varies", value: $material.shade, range: 0...0.4)
            if material.like != nil {
                ValueRow(title: "Like \(material.like!) (chance)", value: $material.likeChance, range: 0...1)
            }
        }
    }
}

// MARK: - The tabs

struct MassingTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let def = Binding(get: { model.def }, set: { model.def = $0 })
        EditorGroup(title: "Plan and height", copy: { model.copy(.massing) }, paste: { model.paste(.massing) }) {
            CaseChoiceRow(title: "Plan shapes", options: def.massing.shapes) { "\($0)" == "courtyard" ? "Court" : "\($0)".capitalized }
            HStack {
                Toggle("Its own floors", isOn: Binding(get: { def.wrappedValue.massing.floors != nil },
                                                       set: { def.wrappedValue.massing.floors = $0 ? Span(3, 6) : nil }))
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Text("(otherwise its district's)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            if def.wrappedValue.massing.floors != nil {
                ValueRow(title: "Floors, least", value: Binding(def.massing.floors, or: Span(3)).lo, range: 1...60, digits: 0)
                ValueRow(title: "Floors, most", value: Binding(def.massing.floors, or: Span(3)).hi, range: 1...60, digits: 0)
            }
            ParamRows(table: BuildingParams.proportions, root: def)
        }
        EditorGroup(title: "Steps and the top") {
            ParamRows(table: BuildingParams.massing, root: def)
            IntChoiceRow(title: "Tower setbacks", choice: def.massing.setbacks, range: 0...4)
            CaseChoiceRow(title: "Roof", options: def.massing.roof.options) { "\($0)".capitalized }
            FloatChoiceRow(title: "Parapet height", choice: def.massing.parapet, range: 0...2)
        }
    }
}

struct FacadeTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let def = Binding(get: { model.def }, set: { model.def = $0 })
        EditorGroup(title: "Windows", copy: { model.copy(.facade) }, paste: { model.paste(.facade) }) {
            FloatChoiceRow(title: "Width (share of the bay)", choice: def.window.share, range: 0.1...1)
            FloatChoiceRow(title: "Sill height", choice: def.window.sill, range: 0...2)
            FloatChoiceRow(title: "Recess", choice: def.window.recess, range: 0.02...0.4)
            IntChoiceRow(title: "Mullions", choice: def.window.mullions, range: 0...6)
            ParamRows(table: BuildingParams.window, root: def)
            FloatChoiceRow(title: "Piers at the ends", choice: def.proportions.pier, range: 0.1...3)
        }
        EditorGroup(title: "Pieces") {
            ParamRows(table: BuildingParams.facade, root: def)
            FloatChoiceRow(title: "Balconies (share of columns)", choice: def.facade.balconies, range: 0...1)
            CaseChoiceRow(title: "Balustrades", options: def.facade.balustrade.options) { "\($0)".capitalized }
            Toggle("Loading doors (a warehouse's)", isOn: def.facade.loadingDoors).toggleStyle(.checkbox).font(.system(size: 11))
            Toggle("Plinth", isOn: def.facade.plinth).toggleStyle(.checkbox).font(.system(size: 11))
        }
    }
}

struct FloorsTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let def = Binding(get: { model.def }, set: { model.def = $0 })
        EditorGroup(title: "Walls and slabs") { ParamRows(table: BuildingParams.walls, root: def) }
        EditorGroup(title: "The core: stair, lift, corridor") { ParamRows(table: BuildingParams.core, root: def) }
        EditorGroup(title: "This building's own plan (\(model.currentRef.title))", copy: { model.copy(.plan) }, paste: { model.paste(.plan) }) {
            let edits = model.currentOverride?.edits ?? []
            let orphaned = Set(model.plan?.orphaned ?? [])
            if edits.isEmpty {
                Text("No hand edits: draw them in the Floor Plan window (Window > Floor Plan, or the button below).")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            ForEach(edits.indices, id: \.self) { k in
                HStack {
                    Text(describe(edits[k])).font(.system(size: 11)).foregroundColor(orphaned.contains(k) ? .orange : .primary)
                    if orphaned.contains(k) { Text("finds nothing").font(.system(size: 10)).foregroundColor(.orange) }
                    Spacer()
                    Button { model.removeEdit(k) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("Clear") { model.clearEdits() }.disabled(edits.isEmpty)
            }
        }
    }

    private func describe(_ e: PlanEdit) -> String {
        let at = String(format: "(%.1f, %.1f)", e.at.x, e.at.y)
        let where_: String
        switch e.storeys {
        case .one(let s): where_ = "floor \(s)"
        case .range(let a, let b): where_ = "floors \(a)–\(b)"
        case .all: where_ = "every floor"
        }
        switch e.op {
        case .split: return "Split at \(at), \(where_)"
        case .merge: return "Merge at \(at), \(where_)"
        case .setType: return "\(e.type?.title ?? "?") at \(at), \(where_)"
        case .moveWall: return "Wall at \(at) moved, \(where_)"
        case .addDoor: return "Door at \(at), \(where_)"
        case .removeDoor: return "No door at \(at), \(where_)"
        case .moveDoor: return "Door at \(at) moved, \(where_)"
        case .flipDoor: return "Door at \(at) turned, \(where_)"
        }
    }
}

struct RoomsTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let def = Binding(get: { model.def }, set: { model.def = $0 })
        EditorGroup(title: "What it is for", copy: { model.copy(.rooms) }, paste: { model.paste(.rooms) }) {
            Picker("Use", selection: def.programme.use) {
                ForEach(BuildingUse.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).font(.system(size: 11))
            Text(useNote(def.wrappedValue.programme.use)).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        EditorGroup(title: "Rooms") { ParamRows(table: BuildingParams.rooms, root: def) }
    }

    private func useNote(_ use: BuildingUse) -> String {
        switch use {
        case .house: return "One home over every storey: the stair against a side wall, a hall beside it, rooms in front and behind; a shop in front if the street has shops."
        case .apartments: return "Flats off a corridor past the stair and lift, each with its rooms on its windows and a hall and bathroom along its door; narrow buildings a flat a floor."
        case .offices: return "Open floors round a core of stairs, lifts and toilets, meeting rooms and offices along the windows; a lobby on the ground floor."
        case .warehouse: return "A hall, its stair and a small office with a WC in its back corners; racks and pallets."
        }
    }
}

struct FurnishTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let def = Binding(get: { model.def }, set: { model.def = $0 })
        EditorGroup(title: "Furniture and lights", copy: { model.copy(.furnish) }, paste: { model.paste(.furnish) }) {
            ParamRows(table: BuildingParams.furnish, root: def)
            LinearColorPicker(title: "Ceiling lights' colour", color: def.interior.lightColor)
        }
        EditorGroup(title: "glTF props (Assets/Props/props.json)") {
            let library = PropLibrary.shared
            Toggle("Use them in place of the pieces they name", isOn: def.interior.models).toggleStyle(.checkbox).font(.system(size: 11))
            if library.entries.isEmpty {
                Text("None listed. A props.json there names each model's file (from Assets), the piece it replaces, its rooms and how often: "
                     + "{\"props\": [{\"file\": \"Props/armchair.glb\", \"replaces\": \"armchair\", \"rooms\": [\"living\"], \"chance\": 0.5}]}")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(library.entries.indices, id: \.self) { i in
                let e = library.entries[i]
                Text("\(e.file): for \(e.replaces.rawValue)\(e.rooms.map { " in " + $0.map(\.title).joined(separator: ", ") } ?? "")"
                     + "\(e.chance.map { String(format: ", %.0f%%", $0 * 100) } ?? "")").font(.system(size: 10))
            }
        }
        EditorGroup(title: "Finishes") {
            ColorListRow(title: "Paints", colors: def.interior.paints)
            ColorListRow(title: "Woods", colors: def.interior.woods)
            ColorListRow(title: "Tiles", colors: def.interior.tiles)
            ColorListRow(title: "Fabrics", colors: def.interior.fabrics)
            ColorListRow(title: "Carpets", colors: def.interior.carpets)
            ColorListRow(title: "Doors", colors: def.interior.doors)
            LinearColorPicker(title: "Ceilings", color: def.interior.ceiling)
        }
    }
}

struct BuildingLookTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let def = Binding(get: { model.def }, set: { model.def = $0 })
        EditorGroup(title: "Outside", copy: { model.copy(.look) }, paste: { model.paste(.look) }) {
            MaterialEditor(title: "Walls", material: def.palette.wall)
            MaterialEditor(title: "Ground floor", material: def.palette.base)
            MaterialEditor(title: "Trim", material: def.palette.trim)
            MaterialEditor(title: "Frames", material: def.palette.frame)
            MaterialEditor(title: "Glass", material: def.palette.glass)
            MaterialEditor(title: "Accents", material: def.palette.accent)
            MaterialEditor(title: "Roof", material: def.palette.roofing)
            MaterialEditor(title: "Metal", material: def.palette.metal)
        }
        EditorGroup(title: "At night") {
            ColorListRow(title: "Blinds glow", colors: def.palette.glow)
            ParamRows(table: BuildingParams.glow, root: def)
        }
    }
}

struct SiteTab: View {
    @EnvironmentObject var model: BuildingEditorModel

    var body: some View {
        let p = model.workshopSettings
        EditorGroup(title: model.scene.buildings.pinned.map { "Pinned: \($0.title)" } ?? "The workshop's lot") {
            if p.pinned == nil {
                ValueRow(title: "Width (front)", value: Binding(get: { p.lot.x }, set: { v in model.workshop { $0.lot.x = v } }),
                         range: Double(BuildingSceneSettings.widthRange.lowerBound)...Double(BuildingSceneSettings.widthRange.upperBound), digits: 1, unit: "m")
                ValueRow(title: "Depth", value: Binding(get: { p.lot.y }, set: { v in model.workshop { $0.lot.y = v } }),
                         range: Double(BuildingSceneSettings.depthRange.lowerBound)...Double(BuildingSceneSettings.depthRange.upperBound), digits: 1, unit: "m")
                HStack {
                    Stepper("Floors \(p.floors)", value: Binding(get: { p.floors }, set: { v in model.workshop { $0.floors = v } }),
                            in: BuildingSceneSettings.floorRange).font(.system(size: 11))
                    Spacer()
                    Picker("", selection: Binding(get: { p.sides }, set: { v in model.workshop { $0.sides = v } })) {
                        ForEach(BuildingSceneSettings.Sides.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
            } else {
                HStack {
                    Text("The city's building, with its own plan's edits.").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Button("Unpin") { model.unpin() }
                }
            }
            HStack {
                Toggle("Night", isOn: Binding(get: { p.night }, set: { v in model.workshop { $0.night = v } })).toggleStyle(.checkbox)
                Spacer()
                Button("Pin the city's building nearest the camera") { model.pinNearest() }.disabled(!model.scene.kind.isCity)
            }
            .font(.system(size: 11))
        }
        EditorGroup(title: "This building's own") {
            let o = model.currentOverride
            HStack {
                Picker("Style", selection: Binding(get: { o?.style ?? "" }, set: { v in model.editOverride { $0.style = v.isEmpty ? nil : v } })) {
                    Text("Its lot's").tag("")
                    ForEach(model.catalog.styles, id: \.id) { Text($0.name).tag($0.id) }
                }
                .frame(width: 220)
                Spacer()
            }
            HStack {
                Toggle("Its own floors", isOn: Binding(get: { o?.floors != nil }, set: { v in model.editOverride { $0.floors = v ? model.workshopSettings.floors : nil } }))
                    .toggleStyle(.checkbox)
                if let f = o?.floors {
                    Stepper("\(f)", value: Binding(get: { f }, set: { v in model.editOverride { $0.floors = v } }), in: 1...60)
                }
                Spacer()
            }
        }
        .font(.system(size: 11))
        EditorGroup(title: "Where the city builds it (against its district's own)") {
            let def = Binding(get: { model.def }, set: { model.def = $0 })
            ForEach(CityStyle.allCases.filter { $0 != .mixed }, id: \.self) { district in
                ValueRow(title: district.title, value: Binding(get: { def.wrappedValue.districts[district.name] ?? 0 },
                                                               set: { def.wrappedValue.districts[district.name] = $0 > 0.001 ? $0 : nil }),
                         range: 0...3)
            }
        }
    }
}
