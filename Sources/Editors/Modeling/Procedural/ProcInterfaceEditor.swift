import AppKit
import Procedural
import SwiftUI

/// Whose parameters the interface editor edits: a container node's (its network's interface), or the asset's (nil:
/// the top network's).
struct ProcInterfaceTarget: Identifiable {
    var node: String?
    var id: String { node ?? "" }
}

/// Houdini's Edit Parameter Interface: a container's parameters (or the asset's) listed in order, added by type,
/// removed, moved; the one picked edited on the right (name, label, default, range, the node parameters it sets).
/// Apply makes it one undo step; a renamed parameter keeps its values, keys and expressions, and `ch("../old")`
/// inside follows it.
struct ProcInterfaceEditor: View {
    @ObservedObject var session: ProceduralSession
    let target: ProcInterfaceTarget
    @Environment(\.dismiss) private var dismiss
    @State private var params: [PromotedParam] = []
    /// Each entry's name when the editor opened (nil: added here).
    @State private var origins: [String?] = []
    @State private var picked: Int?

    /// The kinds of parameter + adds, and the value each starts with.
    static let kinds: [(title: String, value: ProcParam)] = [
        ("Float", .float(0)), ("Integer", .int(0)), ("Toggle", .bool(false)),
        ("Vector 2", .vec2(.zero)), ("Vector 3", .vec3(.zero)), ("Vector 4", .vec4(.zero)), ("String", .string("")),
    ]

    private var current: [PromotedParam] {
        guard let id = target.node else { return session.root.interface }
        return session.graph.node(id)?.contents?.interface ?? []
    }

    private var title: String {
        target.node.flatMap { session.graph.node($0)?.name }.map { "Parameters of \($0)" } ?? "Asset Parameters"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 10) {
                list.frame(width: 200)
                details.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 300)
            HStack {
                Text(problem ?? "Inside, ch(\"../name\") reads a parameter.").font(.caption)
                    .foregroundColor(problem == nil ? .secondary : .red)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(); dismiss() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(14)
        .frame(width: 620)
        .onAppear {
            params = current
            origins = current.map(\.name)
            picked = params.isEmpty ? nil : 0
        }
    }

    private var list: some View {
        VStack(spacing: 4) {
            List(selection: $picked) {
                ForEach(params.indices, id: \.self) { i in
                    HStack {
                        Text(params[i].title)
                        Spacer()
                        Text(ProcInterfaceEditor.kind(of: params[i].value)).foregroundColor(.secondary).font(.caption)
                    }
                    .tag(i)
                }
                .onMove { from, to in
                    params.move(fromOffsets: from, toOffset: to)
                    origins.move(fromOffsets: from, toOffset: to)
                    picked = nil
                }
            }
            HStack {
                Menu {
                    ForEach(ProcInterfaceEditor.kinds, id: \.title) { k in Button(k.title) { add(k.value) } }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Button { remove() } label: { Image(systemName: "minus") }.buttonStyle(.borderless).disabled(picked == nil)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled((picked ?? 0) == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    .disabled(picked.map { $0 >= params.count - 1 } ?? true)
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let i = picked, i < params.count {
            Form {
                TextField("Name", text: Binding(get: { params[i].name }, set: { params[i].name = ProcInterfaceEditor.channelName($0) }))
                TextField("Label", text: Binding(get: { params[i].title }, set: { params[i].title = $0 }))
                LabeledContent("Default") { defaultEditor(i) }
                if ProcInterfaceEditor.hasRange(params[i].value) {
                    LabeledContent("Range") {
                        HStack {
                            ProcNumberField(value: Double(params[i].span?.lowerBound ?? 0)) { v in setRange(i, lo: Float(v)) }.frame(width: 60)
                            Text("to")
                            ProcNumberField(value: Double(params[i].span?.upperBound ?? 1)) { v in setRange(i, hi: Float(v)) }.frame(width: 60)
                        }
                    }
                }
                LabeledContent("Sets") {
                    VStack(alignment: .leading) {
                        if params[i].targets.isEmpty { Text("nothing: read it with ch(\"../\(params[i].name)\")").foregroundColor(.secondary) }
                        ForEach(params[i].targets, id: \.self) { t in
                            HStack {
                                Text("\(t.node).\(t.param)")
                                Button { params[i].targets.removeAll { $0 == t } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .font(ProcTheme.font)
        } else {
            Text(params.isEmpty ? "No parameters: add one with +" : "Pick a parameter").foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func defaultEditor(_ i: Int) -> some View {
        switch params[i].value {
        case .float(let v): ProcNumberField(value: Double(v)) { params[i].value = .float(Float($0)) }.frame(width: 80)
        case .int(let v): ProcNumberField(value: Double(v), integer: true) { params[i].value = .int(Int($0)) }.frame(width: 80)
        case .bool(let b): Toggle("", isOn: Binding(get: { b }, set: { params[i].value = .bool($0) })).labelsHidden()
        case .string(let s): TextField("", text: Binding(get: { s }, set: { params[i].value = .string($0) }))
        default:
            let v = params[i].value.vec4, n = ProcInterfaceEditor.components(params[i].value)
            HStack {
                ForEach(0..<n, id: \.self) { k in
                    ProcNumberField(value: Double(v[k])) { params[i].value = params[i].value.setting(k, Float($0)) }.frame(width: 56)
                }
            }
        }
    }

    // MARK: Edits

    /// Why Apply can't be pressed: an empty, repeated or reserved name.
    private var problem: String? {
        let names = params.map(\.name)
        if names.contains(where: \.isEmpty) { return "A parameter needs a name" }
        if Set(names).count != names.count { return "Two parameters have one name" }
        let reserved = target.node.flatMap { session.graph.node($0)?.kind.spec.params.map(\.name) } ?? []
        if let r = names.first(where: reserved.contains) { return "\(r) is the node's own parameter" }
        return nil
    }

    private func add(_ value: ProcParam) {
        var name = "parm", k = 1
        while params.contains(where: { $0.name == "\(name)\(k)" }) { k += 1 }
        name = "\(name)\(k)"
        let span: ClosedRange<Float>? = ProcInterfaceEditor.hasRange(value) ? (value == .int(0) ? 0...10 : 0...1) : nil
        params.append(PromotedParam(name, title: "Parameter \(k)", value: value, span: span, targets: []))
        origins.append(nil)
        picked = params.count - 1
    }

    private func remove() {
        guard let i = picked else { return }
        params.remove(at: i)
        origins.remove(at: i)
        picked = params.isEmpty ? nil : min(i, params.count - 1)
    }

    private func move(_ d: Int) {
        guard let i = picked, params.indices.contains(i + d) else { return }
        params.swapAt(i, i + d)
        origins.swapAt(i, i + d)
        picked = i + d
    }

    private func setRange(_ i: Int, lo: Float? = nil, hi: Float? = nil) {
        let a = lo ?? params[i].span?.lowerBound ?? 0, b = hi ?? params[i].span?.upperBound ?? 1
        params[i].span = min(a, b)...max(a, b)
    }

    private func apply() {
        var renamed: [String: String] = [:]
        for (o, p) in zip(origins, params) { if let o, o != p.name { renamed[o] = p.name } }
        session.setInterface(target.node, params, renamed: renamed)
    }

    // MARK: Kinds

    static func kind(of v: ProcParam) -> String {
        switch v {
        case .float: "Float"
        case .int: "Integer"
        case .bool: "Toggle"
        case .vec2: "Vector 2"
        case .vec3: "Vector 3"
        case .vec4: "Vector 4"
        case .string: "String"
        default: "Other"
        }
    }

    static func hasRange(_ v: ProcParam) -> Bool {
        switch v {
        case .float, .int: true
        default: false
        }
    }

    static func components(_ v: ProcParam) -> Int {
        switch v {
        case .vec2: 2
        case .vec3: 3
        default: 4
        }
    }

    /// A name as a channel takes it: letters, digits and underscores, not starting with a digit.
    static func channelName(_ s: String) -> String {
        var out = String(s.filter { $0.isLetter || $0.isNumber || $0 == "_" })
        while out.first?.isNumber == true { out.removeFirst() }
        return out
    }
}
