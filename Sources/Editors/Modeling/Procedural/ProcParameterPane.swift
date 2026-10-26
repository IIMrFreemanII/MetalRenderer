import AppKit
import Modeling
import Procedural
import SwiftUI
import simd

/// The parameter pane, Houdini's: the current node's type and name, then its parameters as the spec lists them (those
/// in folders under a tab bar), each row a label and its editor. A label dragged sideways scrubs a number; a row's
/// right-click reverts it or promotes it to the asset's interface. A field dragged is one undo step.
struct ProcParameterPane: View {
    @ObservedObject var session: ProceduralSession
    @State private var folder = ""

    var body: some View {
        VStack(spacing: 0) {
            if let id = session.focus ?? session.graph.displayNode, let n = session.graph.node(id) {
                header(n)
                let spec = n.kind.spec
                let folders = spec.folders.filter { !$0.isEmpty }
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(spec.params.filter { $0.folder.isEmpty && shown($0, n) }, id: \.name) { p in
                            ProcParamRow(session: session, node: n, spec: p)
                        }
                        if !folders.isEmpty {
                            let current = folders.contains(folder) ? folder : folders[0]
                            HStack(spacing: 1) {
                                ForEach(folders, id: \.self) { f in
                                    Button { folder = f } label: {
                                        Text(f).font(ProcTheme.font)
                                            .foregroundColor(f == current ? ProcTheme.text : ProcTheme.dim)
                                            .padding(.horizontal, 10).frame(height: 20)
                                            .background(f == current ? ProcTheme.pane : ProcTheme.paneHeader)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                            }
                            .padding(.top, 6)
                            ForEach(spec.params.filter { $0.folder == current && shown($0, n) }, id: \.name) { p in
                                ProcParamRow(session: session, node: n, spec: p)
                            }
                        }
                        if spec.params.isEmpty {
                            Text("No parameters").font(ProcTheme.small).foregroundColor(ProcTheme.dim).padding(.leading, 8)
                        }
                        if let e = session.info[n.id]?.error {
                            Label(e, systemImage: "exclamationmark.triangle.fill").font(ProcTheme.small)
                                .foregroundColor(ProcTheme.error).padding(8)
                        }
                    }
                    .padding(.vertical, 6)
                }
                interface
            } else {
                Text(session.hasNetwork ? "Select a node" : "").font(ProcTheme.font).foregroundColor(ProcTheme.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ProcTheme.pane)
    }

    private func shown(_ p: ProcParamSpec, _ n: ProcNode) -> Bool {
        guard let c = p.shown else { return true }
        return c.values.contains(n.param(c.param).string)
    }

    private func header(_ n: ProcNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: n.kind.spec.symbol).foregroundColor(ProcTheme.body(n.kind))
            Text(n.kind.spec.title).font(.system(size: 11, weight: .semibold)).foregroundColor(ProcTheme.text)
            ProcNameField(name: n.name) { session.rename(n.id, to: $0) }
                .frame(width: 140)
            Spacer()
            if n.display { flag("Display", ProcTheme.display) }
            if n.template { flag("Template", ProcTheme.template) }
            if n.bypass { flag("Bypass", ProcTheme.bypass) }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(ProcTheme.paneHeader)
        .help(n.kind.spec.summary)
    }

    private func flag(_ title: String, _ color: Color) -> some View {
        Text(title).font(ProcTheme.small).foregroundColor(.black).padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color))
    }

    /// The asset's promoted parameters (what a placed copy can set).
    @ViewBuilder private var interface: some View {
        if !session.graph.interface.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Asset Parameters").font(.system(size: 11, weight: .semibold)).foregroundColor(ProcTheme.label)
                    Spacer()
                    if session.assetSlug != nil {
                        Button("Place Copy in Scene") { session.placeAsset() }.controlSize(.small)
                    }
                }
                ForEach(session.graph.interface) { p in
                    HStack {
                        Text(p.title).font(ProcTheme.small).foregroundColor(ProcTheme.text)
                        switch p.value {
                        case .float(let v): ProcNumberField(value: Double(v)) { session.setInterfaceValue(p.name, .float(Float($0))) }.frame(width: 64)
                        case .int(let v): ProcNumberField(value: Double(v), integer: true) { session.setInterfaceValue(p.name, .int(Int($0))) }.frame(width: 64)
                        default: Text(ProcAssetReference.text(p.value)).font(ProcTheme.small).foregroundColor(ProcTheme.label)
                        }
                        Text(p.targets.map { "\($0.node).\($0.param)" }.joined(separator: ", ")).font(ProcTheme.small).foregroundColor(ProcTheme.dim)
                        Spacer()
                        Button { session.edit("Remove Asset Parameter") { g in g.interface.removeAll { $0.name == p.name } } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(8)
            .background(ProcTheme.paneHeader)
        }
    }
}

/// The node's name, edited in place (Return renames).
struct ProcNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(ProcTheme.font)
            .foregroundColor(ProcTheme.text)
            .padding(.horizontal, 4).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(ProcTheme.field))
            .onAppear { text = name }
            .onChange(of: name) { text = $0 }
            .onSubmit { commit(text) }
    }
}

/// One parameter: its label (drag it sideways to scrub a number) and its editor.
struct ProcParamRow: View {
    @ObservedObject var session: ProceduralSession
    let node: ProcNode
    let spec: ProcParamSpec
    @State private var scrubStart: ProcParam?

    private var value: ProcParam { node.param(spec.name) }
    private func set(_ v: ProcParam) { session.setParam(node.id, spec.name, v) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(spec.title)
                .font(ProcTheme.font)
                .foregroundColor(node.params[spec.name] == nil ? ProcTheme.label : ProcTheme.text)
                .lineLimit(1)
                .frame(width: 118, alignment: .trailing)
                .padding(.top, 2)
                .gesture(scrub)
                .help(spec.help.isEmpty ? spec.name : "\(spec.name): \(spec.help)")
            editor
        }
        .padding(.horizontal, 8)
        .contextMenu {
            Button("Revert to Default") { session.revertParam(node.id, spec.name) }.disabled(node.params[spec.name] == nil)
            Button("Promote to Asset Parameter") { session.promote(node.id, spec.name) }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(spec.name, forType: .string)
            }
        }
    }

    /// Dragging the label: a number or a vector's components by 1% of the span (or 0.01) a point.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if scrubStart == nil { scrubStart = value }
                guard let start = scrubStart else { return }
                let dx = Float(g.translation.width)
                switch (spec.ui, start) {
                case (.number(let r), .float(let f)): set(.float(f + dx * (r.upperBound - r.lowerBound) / 200))
                case (.integer, .int(let i)): set(.int(i + Int(dx / 8)))
                case (.vector, .vec3(let v)): set(.vec3(v + SIMD3(repeating: dx * 0.01)))
                case (.vector, .vec2(let v)): set(.vec2(v + SIMD2(repeating: dx * 0.01)))
                default: break
                }
            }
            .onEnded { _ in scrubStart = nil }
    }

    @ViewBuilder private var editor: some View {
        switch spec.ui {
        case .number(let r):
            HStack(spacing: 4) {
                ProcNumberField(value: Double(value.float)) { set(.float(Float($0))) }.frame(width: 64)
                Slider(value: Binding(get: { Double(min(max(value.float, r.lowerBound), r.upperBound)) },
                                      set: { set(.float(Float($0))) }), in: Double(r.lowerBound)...Double(r.upperBound))
                    .controlSize(.mini)
            }
        case .integer(let r):
            HStack(spacing: 4) {
                ProcNumberField(value: Double(value.int), integer: true) { set(.int(Int($0.rounded()))) }.frame(width: 64)
                Slider(value: Binding(get: { Double(min(max(value.int, r.lowerBound), r.upperBound)) },
                                      set: { set(.int(Int($0.rounded()))) }), in: Double(r.lowerBound)...Double(r.upperBound), step: 1)
                    .controlSize(.mini)
            }
        case .toggle:
            Toggle("", isOn: Binding(get: { value.bool }, set: { set(.bool($0)) })).toggleStyle(.checkbox).labelsHidden()
        case .vector:
            vector
        case .color:
            HStack(spacing: 4) {
                ColorPicker("", selection: Binding(get: {
                    let c = value.vec3
                    return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                }, set: { c in
                    let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                    set(.vec3([Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent)]))
                }), supportsOpacity: false).labelsHidden()
                vector
            }
        case .menu(let items):
            Picker("", selection: Binding(get: { value.string }, set: { set(.string($0)) })) {
                ForEach(items, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 180, alignment: .leading)
        case .text:
            ProcTextField(text: value.string) { set(.string($0)) }
        case .group(let c):
            HStack(spacing: 2) {
                ProcTextField(text: value.string) { set(.string($0)) }
                Menu {
                    let names = inputInfo?.groups[c ?? nodeClass] ?? []
                    if names.isEmpty { Text("No groups") }
                    ForEach(names, id: \.self) { g in Button(g) { set(.string(g)) } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        case .attribute(let c):
            HStack(spacing: 2) {
                ProcTextField(text: value.string) { set(.string($0)) }
                Menu {
                    let attrs = inputInfo?.attributes[c ?? nodeClass] ?? []
                    if attrs.isEmpty { Text("No attributes") }
                    ForEach(attrs.map(\.name), id: \.self) { a in Button(a) { set(.string(a)) } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        case .code:
            ProcCodeField(text: value.string) { set(.string($0)) }
        case .file:
            HStack(spacing: 2) {
                ProcTextField(text: value.string) { set(.string($0)) }
                Menu {
                    Section("Objects") {
                        ForEach(session.model?.document.objects.filter { $0.id != session.objectID }.map(\.name) ?? [], id: \.self) { n in
                            Button(n) { set(.string("object:\(n)")) }
                        }
                    }
                    Section("Model Assets") {
                        ForEach(ModelStore.list().prefix(40).map(\.slug), id: \.self) { s in Button(s) { set(.string("mesh:\(s)")) } }
                    }
                } label: { Image(systemName: "folder") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        case .points:
            pointList
        case .ramp:
            rampList
        }
    }

    /// The first input's cook report (its groups and attributes for the fields' menus).
    private var inputInfo: ProcNodeInfo? {
        session.graph.inputs(of: node.id).first.flatMap { $0 }.flatMap { session.info[$0] }
    }

    /// The class a group or attribute field without one of its own is of: the node's class menu's.
    private var nodeClass: AttributeClass {
        for name in ["grouptype", "class"] {
            switch node.param(name).string {
            case "points", "point": return .point
            case "primitives", "primitive": return .primitive
            case "vertex", "vertices": return .vertex
            case "detail": return .detail
            default: continue
            }
        }
        return .point
    }

    @ViewBuilder private var vector: some View {
        HStack(spacing: 3) {
            switch value {
            case .vec2(let v):
                ForEach(0..<2, id: \.self) { k in ProcNumberField(value: Double(v[k])) { var w = v; w[k] = Float($0); set(.vec2(w)) } }
            case .vec4(let v):
                ForEach(0..<4, id: \.self) { k in ProcNumberField(value: Double(v[k])) { var w = v; w[k] = Float($0); set(.vec4(w)) } }
            default:
                let v = value.vec3
                ForEach(0..<3, id: \.self) { k in ProcNumberField(value: Double(v[k])) { var w = v; w[k] = Float($0); set(.vec3(w)) } }
            }
        }
    }

    private var pointList: some View {
        let pts = value.points
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(pts.indices, id: \.self) { i in
                HStack(spacing: 3) {
                    Text("\(i)").font(ProcTheme.small).foregroundColor(ProcTheme.dim).frame(width: 18, alignment: .trailing)
                    ForEach(0..<3, id: \.self) { k in
                        ProcNumberField(value: Double(pts[i][k])) { var p = pts; p[i][k] = Float($0); set(.points(p)) }
                    }
                    Button { var p = pts; p.remove(at: i); set(.points(p)) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { set(.points(pts + [(pts.last ?? .zero) + [1, 0, 0]])) } label: { Label("Add Point", systemImage: "plus.circle") }
                .buttonStyle(.borderless).font(ProcTheme.small)
        }
    }

    private var rampList: some View {
        let keys = value.ramp
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(keys.indices, id: \.self) { i in
                HStack(spacing: 3) {
                    ProcNumberField(value: Double(keys[i].x)) { var r = keys; r[i].x = Float($0); r.sort { $0.x < $1.x }; set(.ramp(r)) }
                    ProcNumberField(value: Double(keys[i].y)) { var r = keys; r[i].y = Float($0); set(.ramp(r)) }
                    Button { var r = keys; r.remove(at: i); set(.ramp(r)) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { set(.ramp(keys + [SIMD2(1, keys.last?.y ?? 1)])) } label: { Label("Add Key", systemImage: "plus.circle") }
                .buttonStyle(.borderless).font(ProcTheme.small)
        }
    }
}

/// A number field: Return or leaving it sets the value (a typed expression of + - * / is worked out).
struct ProcNumberField: View {
    let value: Double
    var integer = false
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(ProcTheme.mono)
            .foregroundColor(ProcTheme.text)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 4).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(ProcTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ProcTheme.fieldBorder))
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { if !focused { text = format($0) } }
            .onChange(of: focused) { if !$0 { submit() } }
            .onSubmit { submit() }
    }

    private func format(_ v: Double) -> String { integer ? String(Int(v.rounded())) : String(format: "%g", v) }

    private func submit() {
        if let v = ProcNumberField.evaluate(text), v != value { commit(v) }
        text = format(ProcNumberField.evaluate(text) ?? value)
    }

    /// A number, or a simple expression of numbers and + - * / ( ) (nil if it isn't one).
    static func evaluate(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let v = Double(t) { return v }
        var p = ExpressionParser(Array(t.filter { $0 != " " }))
        guard let v = p.sum(), p.i == p.c.count else { return nil }
        return v
    }

    /// Recursive descent: sum = product (± product)*, product = factor (*/ factor)*, factor = ±factor | (sum) | number.
    private struct ExpressionParser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        mutating func sum() -> Double? {
            guard var v = product() else { return nil }
            while i < c.count, c[i] == "+" || c[i] == "-" {
                let op = c[i]; i += 1
                guard let r = product() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func product() -> Double? {
            guard var v = factor() else { return nil }
            while i < c.count, c[i] == "*" || c[i] == "/" {
                let op = c[i]; i += 1
                guard let r = factor() else { return nil }
                v = op == "*" ? v * r : v / r
            }
            return v
        }

        mutating func factor() -> Double? {
            guard i < c.count else { return nil }
            if c[i] == "-" { i += 1; return factor().map { -$0 } }
            if c[i] == "+" { i += 1; return factor() }
            if c[i] == "(" {
                i += 1
                guard let v = sum(), i < c.count, c[i] == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while i < c.count, c[i].isNumber || c[i] == "." || c[i] == "e" { i += 1 }
            return Double(String(c[start..<i]))
        }
    }
}

/// A text field: Return or leaving it sets the value.
struct ProcTextField: View {
    let text: String
    let commit: (String) -> Void
    @State private var editing = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $editing)
            .textFieldStyle(.plain)
            .font(ProcTheme.font)
            .foregroundColor(ProcTheme.text)
            .padding(.horizontal, 4).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(ProcTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ProcTheme.fieldBorder))
            .focused($focused)
            .onAppear { editing = text }
            .onChange(of: text) { if !focused { editing = $0 } }
            .onChange(of: focused) { if !$0, editing != text { commit(editing) } }
            .onSubmit { if editing != text { commit(editing) } }
    }
}

/// Code: a monospaced editor; Apply (or leaving it) sets the value.
struct ProcCodeField: View {
    let text: String
    let commit: (String) -> Void
    @State private var editing = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextEditor(text: $editing)
                .font(ProcTheme.mono)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(ProcTheme.field)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(ProcTheme.fieldBorder))
            Button("Apply") { commit(editing) }.controlSize(.small).disabled(editing == text)
        }
        .onAppear { editing = text }
        .onChange(of: text) { editing = $0 }
    }
}
