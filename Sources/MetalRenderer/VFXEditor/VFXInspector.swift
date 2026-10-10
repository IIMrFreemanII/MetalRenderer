import SwiftUI
import simd

/// The selected item's parameters (the focus: a block, a node or an emitter), or the effect's own (its origin, fields
/// and colliders) when nothing is. A pin with a wire shows where from, and lets it go.
struct VFXInspector: View {
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let fx = model.effect
                if let id = model.focus, let n = fx.node(id) {
                    node(n, fx)
                } else if let id = model.focus, let (e, b) = fx.block(id) {
                    block(b, emitter: fx.emitters[e], fx)
                } else if let id = model.focus, let e = fx.emitter(id) {
                    emitter(e)
                } else {
                    effect(fx)
                }
            }
            .padding(10)
        }
        .font(.system(size: 11))
    }

    // MARK: - A block

    private func block(_ b: VFXBlock, emitter: VFXEmitter, _ fx: VFXEffect) -> some View {
        VFXSection(title: b.kind.spec.title, subtitle: emitter.name) {
            Text(b.kind.spec.summary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Enabled", isOn: Binding(get: { b.enabled }, set: { on in model.edit { $0.setEnabled(b.id, on) } }))
            ForEach(b.kind.spec.pins, id: \.name) { p in
                VFXParamEditor(owner: b.id, pin: p, value: b.param(p.name))
            }
            HStack {
                Button("Move Up") { model.moveBlock(b.id, by: -1) }
                Button("Move Down") { model.moveBlock(b.id, by: 1) }
                Spacer()
                Button("Delete") { model.selection = [b.id]; model.deleteSelection() }
            }
            .controlSize(.small)
        }
    }

    // MARK: - A node

    private func node(_ n: VFXNode, _ fx: VFXEffect) -> some View {
        let spec = n.kind.spec
        return VFXSection(title: spec.title, subtitle: spec.family.rawValue) {
            ForEach(spec.inputs, id: \.name) { p in
                VFXParamEditor(owner: n.id, pin: p, value: n.param(p.name))
            }
            ForEach(spec.outputs, id: \.name) { o in
                HStack {
                    Text("Out: \(o.name)").foregroundColor(.secondary)
                    Spacer()
                    Text(fx.outputType(n.id, o.name).rawValue).foregroundColor(VFXColors.pin(fx.outputType(n.id, o.name)))
                }
            }
            HStack {
                Text("id \(n.id)").foregroundColor(.secondary).font(.system(size: 10))
                Spacer()
                Button("Delete") { model.selection = [n.id]; model.deleteSelection() }.controlSize(.small)
            }
        }
    }

    // MARK: - An emitter

    private func emitter(_ e: VFXEmitter) -> some View {
        VFXSection(title: e.name, subtitle: "Emitter") {
            VFXTextRow(title: "Name", text: e.name) { name in
                model.edit { fx in if let i = fx.emitters.firstIndex(where: { $0.id == e.id }) { fx.emitters[i].name = name } }
            }
            VFXIntRow(title: "Capacity", value: e.capacity, range: 1...200_000) { n in
                model.edit { fx in if let i = fx.emitters.firstIndex(where: { $0.id == e.id }) { fx.emitters[i].capacity = n } }
            }
            Toggle("Seed of its own", isOn: Binding(get: { e.seed != nil }, set: { on in
                model.edit { fx in
                    if let i = fx.emitters.firstIndex(where: { $0.id == e.id }) { fx.emitters[i].seed = on ? (e.seed ?? 1) : nil }
                }
            }))
            if let seed = e.seed {
                VFXIntRow(title: "Seed", value: Int(seed), range: 0...Int(Int32.max)) { n in
                    model.edit { fx in if let i = fx.emitters.firstIndex(where: { $0.id == e.id }) { fx.emitters[i].seed = UInt32(n) } }
                }
            }
            Text("Capacity, the renderer (Billboard, Mesh, Trail, Distortion) and shadows on or off make the scene again; other values are live.")
                .foregroundColor(.secondary).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Delete Emitter") { model.selection = [e.id]; model.deleteSelection() }.controlSize(.small)
            }
        }
    }

    // MARK: - The effect

    private func effect(_ fx: VFXEffect) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VFXSection(title: fx.name, subtitle: model.isBuiltIn(fx.name) ? "Built-in effect" : "Effect") {
                if !model.isBuiltIn(fx.name) {
                    VFXTextRow(title: "Name", text: fx.name) { model.rename($0) }
                }
                VFXVectorRow(title: "Origin", value: fx.origin) { v in model.edit { $0.origin = v } }
                Text("Where it is made about: the stage centres it there, and a scene's own copy is moved from it to its place.")
                    .foregroundColor(.secondary).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                ForEach(fx.emitters) { e in
                    Button { model.click(e.id) } label: {
                        HStack { Image(systemName: "sparkles"); Text(e.name); Spacer(); Text("\(e.capacity)").foregroundColor(.secondary) }
                    }
                    .buttonStyle(.plain)
                }
                Button("Add Emitter") { model.addEmitter() }.controlSize(.small)
            }
            VFXSection(title: "Fields", subtitle: "\(fx.fields.count)") {
                ForEach(fx.fields.indices, id: \.self) { i in field(i, fx.fields[i]) }
                Button("Add Field") {
                    model.edit { fx in
                        fx.fields.append(VFXField(name: VFXEffect.unique("field", Set(fx.fields.map(\.name))), kind: .vortex,
                                                  center: fx.origin, radius: 1, height: 2, swirl: 2, lift: 1))
                    }
                }
                .controlSize(.small)
            }
            VFXSection(title: "Colliders", subtitle: "\(fx.colliders.count)") {
                ForEach(fx.colliders.indices, id: \.self) { i in collider(i, fx.colliders[i]) }
                Button("Add Collider") {
                    model.edit { fx in
                        fx.colliders.append(VFXCollider(name: VFXEffect.unique("collider", Set(fx.colliders.map(\.name))),
                                                        shape: .sphere(center: fx.origin, radius: 0.5)))
                    }
                }
                .controlSize(.small)
                Text("The scenes' own: floor, and in the particles scene crate, bowl, stand and plinth.")
                    .foregroundColor(.secondary).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ i: Int, _ f: VFXField) -> some View {
        func set(_ change: @escaping (inout VFXField) -> Void) { model.edit { fx in if fx.fields.indices.contains(i) { change(&fx.fields[i]) } } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VFXTextRow(title: "Name", text: f.name) { n in set { $0.name = n } }
                Picker("", selection: Binding(get: { f.kind }, set: { k in set { $0.kind = k } })) {
                    ForEach(VFXField.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 80)
                Button { model.edit { fx in if fx.fields.indices.contains(i) { fx.fields.remove(at: i) } } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            VFXVectorRow(title: "Centre", value: f.center) { v in set { $0.center = v } }
            VFXSliderRow(title: "Radius", value: f.radius, span: 0.1...10) { v in set { $0.radius = v } }
            VFXSliderRow(title: "Height", value: f.height, span: 0.1...20) { v in set { $0.height = v } }
            if f.kind == .vortex { VFXSliderRow(title: "Swirl", value: f.swirl, span: 0...10) { v in set { $0.swirl = v } } }
            VFXSliderRow(title: "Lift", value: f.lift, span: 0...10) { v in set { $0.lift = v } }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)))
    }

    private func collider(_ i: Int, _ c: VFXCollider) -> some View {
        func set(_ change: @escaping (inout VFXCollider) -> Void) { model.edit { fx in if fx.colliders.indices.contains(i) { change(&fx.colliders[i]) } } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VFXTextRow(title: "Name", text: c.name) { n in set { $0.name = n } }
                Button { model.edit { fx in if fx.colliders.indices.contains(i) { fx.colliders.remove(at: i) } } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            switch c.shape {
            case .plane(let n, let p):
                VFXVectorRow(title: "Normal", value: n) { v in set { $0.shape = .plane(normal: v, point: p) } }
                VFXVectorRow(title: "Point", value: p) { v in set { $0.shape = .plane(normal: n, point: v) } }
            case .sphere(let center, let r):
                VFXVectorRow(title: "Centre", value: center) { v in set { $0.shape = .sphere(center: v, radius: r) } }
                VFXSliderRow(title: "Radius", value: r, span: 0.01...10) { v in set { $0.shape = .sphere(center: center, radius: v) } }
            case .box(let center, let h):
                VFXVectorRow(title: "Centre", value: center) { v in set { $0.shape = .box(center: v, halfExtents: h) } }
                VFXVectorRow(title: "Half extents", value: h) { v in set { $0.shape = .box(center: center, halfExtents: v) } }
            }
            Picker("Shape", selection: Binding(get: { c.shapeName }, set: { name in set { $0.shape = VFXCollider.shape(name, at: $0.center) } })) {
                ForEach(["plane", "sphere", "box"], id: \.self) { Text($0).tag($0) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)))
    }
}

extension VFXCollider {
    var shapeName: String {
        switch shape {
        case .plane: return "plane"
        case .sphere: return "sphere"
        case .box: return "box"
        }
    }
    var center: SIMD3<Float> {
        switch shape {
        case .plane(_, let p): return p
        case .sphere(let c, _): return c
        case .box(let c, _): return c
        }
    }
    static func shape(_ name: String, at c: SIMD3<Float>) -> Shape {
        switch name {
        case "plane": return .plane(normal: [0, 1, 0], point: c)
        case "box": return .box(center: c, halfExtents: [0.5, 0.5, 0.5])
        default: return .sphere(center: c, radius: 0.5)
        }
    }
}

// MARK: - Rows

/// A titled group.
struct VFXSection<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(subtitle).foregroundColor(.secondary)
            }
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }
}

/// One parameter of a block or a node: wired (where from, and let go), or its value's editor.
struct VFXParamEditor: View {
    let owner: String
    let pin: VFXPinSpec
    let value: VFXParam
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        if let link = model.effect.link(into: owner, pin.name) {
            HStack {
                Circle().fill(VFXColors.pin(model.effect.pinType(owner, pin.name))).frame(width: 7, height: 7)
                Text(pin.title)
                Spacer()
                Text("← \(model.effect.node(link.from)?.kind.spec.title ?? link.from)\(link.output == "out" ? "" : ".\(link.output)")")
                    .foregroundColor(.secondary)
                Button("Disconnect") { model.unlink(owner, pin.name) }.controlSize(.small)
            }
        } else {
            editor
        }
    }

    private func set(_ v: VFXParam) { model.setParam(owner, pin.name, v) }

    @ViewBuilder
    private var editor: some View {
        switch value {
        case .float(let f):
            if let span = pin.span { VFXSliderRow(title: pin.title, value: f, span: span) { set(.float($0)) } }
            else { VFXNumberRow(title: pin.title, value: f) { set(.float($0)) } }
        case .int(let i):
            VFXIntRow(title: pin.title, value: i, range: pin.span.map { Int($0.lowerBound)...Int($0.upperBound) } ?? 0...100_000) { set(.int($0)) }
        case .range(let a, let b):
            VStack(alignment: .leading, spacing: 2) {
                VFXSliderRow(title: pin.title + " from", value: a, span: pin.span ?? 0...max(b * 2, 1)) { set(.range($0, max(b, $0))) }
                VFXSliderRow(title: "to", value: b, span: pin.span ?? 0...max(b * 2, 1)) { set(.range(min(a, $0), $0)) }
            }
        case .vec3(let v):
            VFXVectorRow(title: pin.title, value: v) { set(.vec3($0)) }
        case .color(let c):
            VFXColorRow(title: pin.title, color: c) { set(.color($0)) }
        case .bool(let b):
            Toggle(pin.title, isOn: Binding(get: { b }, set: { set(.bool($0)) }))
        case .choice(let s):
            choice(s)
        case .names(let names):
            VFXNamesRow(title: pin.title, names: names, options: colliderNames(names)) { set(.names($0)) }
        case .curve(let c):
            VFXCurveEditor(title: pin.title, curve: c) { set(.curve($0)) }
        case .gradient(let g):
            VFXGradientEditor(title: pin.title, gradient: g) { set(.gradient($0)) }
        }
    }

    /// The choices: the pin's, or the effect's emitters (a parent), fields; a free name otherwise (a mesh, a material).
    @ViewBuilder
    private func choice(_ s: String) -> some View {
        let fx = model.effect
        let options: [String]? = !pin.choices.isEmpty ? pin.choices
            : pin.name == "parent" ? fx.emitters.map(\.id).filter { $0 != fx.block(owner).map { fx.emitters[$0.emitter].id } }
            : pin.name == "field" ? fx.fields.map(\.name) : nil
        if let options {
            Picker(pin.title, selection: Binding(get: { s }, set: { set(.choice($0)) })) {
                if !options.contains(s) { Text(s.isEmpty ? "—" : s).tag(s) }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } else {
            VFXTextRow(title: pin.title, text: s) { set(.choice($0)) }
        }
    }

    private func colliderNames(_ current: [String]) -> [String] {
        var all = model.effect.colliders.map(\.name)
        for n in ["floor", "crate", "bowl", "stand", "plinth"] + current where !all.contains(n) { all.append(n) }
        return all
    }
}

/// A float as a slider over `span` (dragging: one undo step) and a field (any value).
struct VFXSliderRow: View {
    let title: String
    let value: Float
    let span: ClosedRange<Float>
    let set: (Float) -> Void
    @Environment(\.editorDrag) private var drag

    var body: some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 110, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { Double(min(max(value, span.lowerBound), span.upperBound)) }, set: { set(Float($0)) }),
                   in: Double(span.lowerBound)...Double(span.upperBound)) { editing in editing ? drag.begin() : drag.end() }
                .controlSize(.small)
            VFXNumberField(value: value, set: set).frame(width: 64)
        }
    }
}

/// A float as a field only.
struct VFXNumberRow: View {
    let title: String
    let value: Float
    let set: (Float) -> Void
    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading).lineLimit(1)
            Spacer()
            VFXNumberField(value: value, set: set).frame(width: 90)
        }
    }
}

/// A number field: its value set when Return is pressed or it loses the focus.
struct VFXNumberField: View {
    let value: Float
    let set: (Float) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 11).monospacedDigit())
            .focused($focused)
            .onAppear { text = VFXSummary.number(value) }
            .onChange(of: value) { v in if !focused { text = VFXSummary.number(v) } }
            .onChange(of: focused) { f in if !f { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "∞" || t.lowercased() == "inf" { set(.greatestFiniteMagnitude); return }
        if let f = Float(t), f.isFinite { if f != value { set(f) } } else { text = VFXSummary.number(value) }
    }
}

struct VFXIntRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void
    var body: some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading).lineLimit(1)
            Spacer()
            VFXNumberField(value: Float(value)) { set(min(max(Int($0.rounded()), range.lowerBound), range.upperBound)) }.frame(width: 80)
            Stepper("", onIncrement: { set(min(value + 1, range.upperBound)) }, onDecrement: { set(max(value - 1, range.lowerBound)) })
                .labelsHidden()
        }
    }
}

struct VFXVectorRow: View {
    let title: String
    let value: SIMD3<Float>
    let set: (SIMD3<Float>) -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(title).frame(width: 80, alignment: .leading).lineLimit(1)
            ForEach(0..<3, id: \.self) { k in
                VFXNumberField(value: value[k]) { f in var v = value; v[k] = f; set(v) }
            }
        }
    }
}

struct VFXTextRow: View {
    let title: String
    let text: String
    let set: (String) -> Void
    @State private var edited = ""
    var body: some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            TextField("", text: $edited)
                .textFieldStyle(.roundedBorder)
                .onAppear { edited = text }
                .onChange(of: text) { edited = $0 }
                .onSubmit { if edited != text && !edited.isEmpty { set(edited) } }
        }
    }
}

/// A colour (linear, HDR): its hue and shade in a colour well, how bright past white (its largest part, at least 1),
/// and its opacity.
struct VFXColorRow: View {
    let title: String
    let color: SIMD4<Float>
    let set: (SIMD4<Float>) -> Void

    var body: some View {
        let rgb = SIMD3(color.x, color.y, color.z), k = max(rgb.max(), 1)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                LinearColorPicker(title: title, color: Binding(get: { rgb / k }, set: { c in set(SIMD4(c * k, color.w)) }))
                Spacer()
                Text("×").foregroundColor(.secondary)
                VFXNumberField(value: k) { nk in set(SIMD4(rgb / k * max(nk, 0), color.w)) }.frame(width: 56)
            }
            VFXSliderRow(title: "Opacity", value: color.w, span: 0...1) { a in set(SIMD4(rgb, a)) }
        }
    }
}

struct VFXNamesRow: View {
    let title: String
    let names: [String]
    let options: [String]
    let set: ([String]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            ForEach(options, id: \.self) { n in
                Toggle(n, isOn: Binding(get: { names.contains(n) }, set: { on in
                    set(on ? names + [n] : names.filter { $0 != n })
                }))
                .padding(.leading, 10)
            }
        }
    }
}

// MARK: - Curves and gradients

/// A curve of up to 8 keys over 0...1: drag a key (one undo step), double-click to add one, Option-click to remove one;
/// smooth or straight between; the selected key's numbers below.
struct VFXCurveEditor: View {
    let title: String
    let curve: VFXCurve
    let set: (VFXCurve) -> Void
    @Environment(\.editorDrag) private var drag
    @State private var selected: Int?
    @State private var dragged: Int?
    /// The values shown, fixed while a key is dragged (so it doesn't run away).
    @State private var heldRange: ClosedRange<Float>?
    @State private var lastClick: (time: TimeInterval, at: CGPoint)?

    private var range: ClosedRange<Float> {
        if let heldRange { return heldRange }
        let r = curve.range
        let lo = min(r.lowerBound, 0), hi = max(r.upperBound, lo + 1e-3)
        return lo...(hi + (hi - lo) * 0.15)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Toggle("Smooth", isOn: Binding(get: { curve.smooth }, set: { var c = curve; c.smooth = $0; set(c) })).controlSize(.small)
            }
            GeometryReader { geo in canvas(geo.size) }.frame(height: 96)
            HStack {
                Text(String(format: "values %.3g to %.3g", range.lowerBound, range.upperBound)).foregroundColor(.secondary)
                Spacer()
                Text("t: 0 → 1").foregroundColor(.secondary)
            }
            .font(.system(size: 9))
            if let k = selected, curve.keys.indices.contains(k) {
                HStack {
                    Text("Key \(k + 1)").foregroundColor(.secondary)
                    VFXNumberField(value: curve.keys[k].x) { t in move(k, SIMD2(min(max(t, 0), 1), curve.keys[k].y)) }
                    VFXNumberField(value: curve.keys[k].y) { v in move(k, SIMD2(curve.keys[k].x, v)) }
                }
            }
        }
    }

    private func toView(_ p: SIMD2<Float>, _ size: CGSize) -> CGPoint {
        let r = range, y = (p.y - r.lowerBound) / max(r.upperBound - r.lowerBound, 1e-6)
        return CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(y)) * size.height)
    }

    private func fromView(_ q: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        let r = range
        let x = Float(min(max(q.x / max(size.width, 1), 0), 1))
        let y = r.lowerBound + Float(1 - min(max(q.y / max(size.height, 1), 0), 1)) * (r.upperBound - r.lowerBound)
        return SIMD2(x, y)
    }

    private func canvas(_ size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35))
            Path { p in
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            Path { p in
                for i in 0...96 {
                    let x = Float(i) / 96, q = toView(SIMD2(x, curve.value(x)), size)
                    if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                }
            }
            .stroke(VFXColors.pin(.float), lineWidth: 1.5)
            ForEach(curve.keys.indices, id: \.self) { i in
                Circle().fill(selected == i ? VFXColors.selected : VFXColors.pin(.float)).frame(width: 8, height: 8)
                    .position(toView(curve.keys[i], size))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in drag(g, size) }
            .onEnded { g in
                if dragged != nil { drag.end() }
                dragged = nil
                heldRange = nil
                clicked(g, size)
            })
    }

    private func nearest(_ at: CGPoint, _ size: CGSize) -> Int? {
        func d(_ i: Int) -> CGFloat { let q = toView(curve.keys[i], size); return hypot(q.x - at.x, q.y - at.y) }
        return curve.keys.indices.min { d($0) < d($1) }.flatMap { d($0) < 10 ? $0 : nil }
    }

    private func drag(_ g: DragGesture.Value, _ size: CGSize) {
        if dragged == nil {
            guard let k = nearest(g.startLocation, size) else { dragged = -1; return }
            selected = k
            if NSEvent.modifierFlags.contains(.option), curve.keys.count > 2 {
                var c = curve
                c.keys.remove(at: k)
                selected = nil
                dragged = -1
                set(c)
                return
            }
            dragged = k
            heldRange = range
            drag.begin()
        }
        guard let k = dragged, k >= 0 else { return }
        move(k, fromView(g.location, size))
    }

    /// Key k to p, kept between its neighbours.
    private func move(_ k: Int, _ p: SIMD2<Float>) {
        var c = curve, q = p
        let lo = k > 0 ? c.keys[k - 1].x + 0.001 : 0, hi = k < c.keys.count - 1 ? c.keys[k + 1].x - 0.001 : 1
        q.x = min(max(q.x, lo), hi)
        c.keys[k] = q
        set(c)
    }

    private func clicked(_ g: DragGesture.Value, _ size: CGSize) {
        guard hypot(g.translation.width, g.translation.height) < 3 else { lastClick = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, now - last.time < NSEvent.doubleClickInterval, hypot(last.at.x - g.location.x, last.at.y - g.location.y) < 6 {
            lastClick = nil
            guard curve.keys.count < VFXCurve.maxKeys, nearest(g.location, size) == nil else { return }
            var c = curve
            let p = fromView(g.location, size)
            c.keys.append(p)
            c.keys.sort { $0.x < $1.x }
            selected = c.keys.firstIndex(of: p)
            set(c)
        } else {
            lastClick = (now, g.location)
        }
    }
}

/// A gradient of up to 8 colour keys: drag a stop along the bar (one undo step), double-click the bar to add one,
/// Option-click a stop to remove it; the selected stop's colour, brightness and opacity below. `srgb`: its colours are
/// sRGB values (the Material Designer's), shown and edited as they are, not linear ones.
struct VFXGradientEditor: View {
    let title: String
    let gradient: VFXGradient
    let set: (VFXGradient) -> Void
    var srgb = false
    @Environment(\.editorDrag) private var drag
    @State private var selected = 0
    @State private var dragged: Int?
    @State private var lastClick: (time: TimeInterval, at: CGPoint)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            GeometryReader { geo in bar(geo.size) }.frame(height: 36)
            if gradient.keys.indices.contains(selected) {
                let key = gradient.keys[selected]
                if srgb {
                    MatColorRow(title: "Key \(selected + 1)", color: key.color) { c in var g = gradient; g.keys[selected].color = c; set(g) }
                } else {
                    VFXColorRow(title: "Key \(selected + 1)", color: key.color) { c in var g = gradient; g.keys[selected].color = c; set(g) }
                }
                VFXSliderRow(title: "At", value: key.t, span: 0...1) { t in move(selected, t) }
            }
        }
    }

    private func bar(_ size: CGSize) -> some View {
        let h: CGFloat = 20
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // A checker under it, for the opacity.
                for i in 0..<Int(size.width / 6) + 1 {
                    for j in 0..<Int(h / 6) + 1 where (i + j) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: CGFloat(i) * 6, y: CGFloat(j) * 6, width: 6, height: 6)), with: .color(Color.white.opacity(0.15)))
                    }
                }
                let n = 64
                for i in 0..<n {
                    let c = gradient.value((Float(i) + 0.5) / Float(n))
                    let rgb = SIMD3(c.x, c.y, c.z) / max(max(c.x, c.y, c.z), 1)
                    let shown = srgb ? rgb : SIMD3(LinearColorPicker.encode(rgb.x), LinearColorPicker.encode(rgb.y), LinearColorPicker.encode(rgb.z))
                    ctx.fill(Path(CGRect(x: size.width * CGFloat(i) / CGFloat(n), y: 0, width: size.width / CGFloat(n) + 0.5, height: h)),
                             with: .color(Color(.sRGB, red: Double(shown.x), green: Double(shown.y), blue: Double(shown.z), opacity: Double(c.w))))
                }
            }
            .frame(height: h)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            ForEach(gradient.keys.indices, id: \.self) { i in
                Image(systemName: "triangle.fill").font(.system(size: 9))
                    .foregroundColor(i == selected ? VFXColors.selected : .white)
                    .position(x: CGFloat(gradient.keys[i].t) * size.width, y: h + 7)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in drag(g, size) }
            .onEnded { g in
                if dragged.map({ $0 >= 0 }) == true { drag.end() }
                dragged = nil
                clicked(g, size)
            })
    }

    private func drag(_ g: DragGesture.Value, _ size: CGSize) {
        if dragged == nil {
            let t = Float(g.startLocation.x / max(size.width, 1))
            let k = gradient.keys.indices.min { abs(gradient.keys[$0].t - t) < abs(gradient.keys[$1].t - t) }
            guard let k, abs(CGFloat(gradient.keys[k].t - t) * size.width) < 8 else { dragged = -1; return }
            selected = k
            if NSEvent.modifierFlags.contains(.option), gradient.keys.count > 1 {
                var gr = gradient
                gr.keys.remove(at: k)
                selected = 0
                dragged = -1
                set(gr)
                return
            }
            dragged = k
            drag.begin()
        }
        guard let k = dragged, k >= 0 else { return }
        move(k, Float(g.location.x / max(size.width, 1)))
    }

    /// Key k to t, kept between its neighbours.
    private func move(_ k: Int, _ t: Float) {
        var g = gradient
        let lo = k > 0 ? g.keys[k - 1].t + 0.001 : 0, hi = k < g.keys.count - 1 ? g.keys[k + 1].t - 0.001 : 1
        g.keys[k].t = min(max(t, lo), hi)
        set(g)
    }

    private func clicked(_ g: DragGesture.Value, _ size: CGSize) {
        guard hypot(g.translation.width, g.translation.height) < 3 else { lastClick = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, now - last.time < NSEvent.doubleClickInterval, hypot(last.at.x - g.location.x, last.at.y - g.location.y) < 6 {
            lastClick = nil
            guard gradient.keys.count < VFXGradient.maxKeys else { return }
            let t = Float(min(max(g.location.x / max(size.width, 1), 0), 1))
            var gr = gradient
            gr.keys.append(.init(t, gradient.value(t)))
            gr.keys.sort { $0.t < $1.t }
            selected = gr.keys.firstIndex { $0.t == t } ?? 0
            set(gr)
        } else {
            lastClick = (now, g.location)
        }
    }
}
