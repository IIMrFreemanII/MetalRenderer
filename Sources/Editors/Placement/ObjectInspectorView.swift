import Procedural
import SwiftUI

/// The Object inspector: the selected object of the scene's file, and a procedural asset's promoted parameters for
/// this copy (its `proc:` values). A value is set when a field is submitted or a slider let go: each makes the scene
/// again with the asset cooked anew.
struct ObjectInspectorView: View {
    @ObservedObject var model: ObjectInspectorModel
    /// Opens the asset in the Modeller's Procedural workspace.
    var editAsset: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = model.placed {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.object.name).font(.headline).lineLimit(1)
                    Text(p.object.asset)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                Divider()
                if model.isProcedural {
                    procedural
                } else {
                    note("Not a procedural asset: only a proc: object has values of its own.")
                }
            } else {
                note("Select an object of the scene's file (click it in the view) to see it here.")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var procedural: some View {
        if let message = model.message {
            note(message)
        } else if let asset = model.asset, let slug = model.reference?.slug {
            let rows = model.rows
            if rows.isEmpty {
                note("\(asset.name) promotes no parameters (right-click a parameter in the Modeller: Promote to Asset Parameter).")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            ObjectInspectorRow(row: row, set: { model.set(row.param.name, $0) }, revert: { model.revert(row.param.name) })
                        }
                    }
                }
            }
            HStack {
                Button("Reset All") { model.revertAll() }.disabled(!rows.contains(where: \.overridden))
                Spacer()
                Button("Edit Asset in Modeller") { editAsset(slug) }
            }
            .controlSize(.small)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One promoted parameter: its title, an editor for its kind of value, and (when this copy sets it) a button back to
/// the asset's default.
struct ObjectInspectorRow: View {
    let row: ObjectInspectorModel.Row
    let set: (ProcParam) -> Void
    let revert: () -> Void
    /// A slider's value while it is dragged (set when let go).
    @State private var dragged: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.param.title)
                .fontWeight(row.overridden ? .semibold : .regular)
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
                .help(row.param.targets.map { "\($0.node).\($0.param)" }.joined(separator: ", "))
            editor
            Button(action: revert) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Back to the asset's default")
                .opacity(row.overridden ? 1 : 0)
                .disabled(!row.overridden)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var editor: some View {
        switch row.value {
        case .float(let v):
            number(Double(v), integer: false) { set(.float(Float($0))) }
        case .int(let v):
            number(Double(v), integer: true) { set(.int(Int($0.rounded()))) }
        case .bool(let b):
            Toggle("", isOn: Binding(get: { b }, set: { set(.bool($0)) })).labelsHidden()
            Spacer(minLength: 0)
        case .vec2(let v):
            components([v.x, v.y]) { set(.vec2(SIMD2($0[0], $0[1]))) }
        case .vec3(let v):
            components([v.x, v.y, v.z]) { set(.vec3(SIMD3($0[0], $0[1], $0[2]))) }
        case .vec4(let v):
            components([v.x, v.y, v.z, v.w]) { set(.vec4(SIMD4($0[0], $0[1], $0[2], $0[3]))) }
        case .string(let s):
            ObjectInspectorTextField(text: s) { set(.string($0)) }
        default:
            Text(ProcAssetReference.text(row.value)).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// A field, and a slider over the parameter's span when it has one.
    @ViewBuilder private func number(_ v: Double, integer: Bool, _ commit: @escaping (Double) -> Void) -> some View {
        ObjectInspectorNumberField(value: dragged ?? v, integer: integer, commit: commit).frame(width: 64)
        if let span = row.param.span, span.upperBound > span.lowerBound {
            let range = Double(span.lowerBound)...Double(span.upperBound)
            Slider(value: Binding(get: { min(max(dragged ?? v, range.lowerBound), range.upperBound) },
                                  set: { dragged = integer ? $0.rounded() : $0 }),
                   in: range) { editing in
                if !editing, let d = dragged {
                    dragged = nil
                    if d != v { commit(d) }
                }
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private func components(_ v: [Float], _ commit: @escaping ([Float]) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(v.indices, id: \.self) { k in
                ObjectInspectorNumberField(value: Double(v[k]), integer: false) { x in
                    var w = v
                    w[k] = Float(x)
                    commit(w)
                }
            }
        }
    }
}

/// A number: Return or leaving the field sets it (a simple expression too: `2*1.5`).
struct ObjectInspectorNumberField: View {
    let value: Double
    var integer = false
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { if !focused { text = format($0) } }
            .onChange(of: focused) { if !$0 { submit() } }
            .onSubmit { submit() }
    }

    private func format(_ v: Double) -> String { integer ? String(Int(v.rounded())) : String(format: "%g", v) }

    private func submit() {
        let v = ProcNumberField.evaluate(text).map { integer ? $0.rounded() : $0 }
        if let v, v != value { commit(v) }
        text = format(v ?? value)
    }
}

/// Text: Return or leaving the field sets it.
struct ObjectInspectorTextField: View {
    let text: String
    let commit: (String) -> Void
    @State private var editing = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $editing)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { editing = text }
            .onChange(of: text) { if !focused { editing = $0 } }
            .onChange(of: focused) { if !$0, editing != text { commit(editing) } }
            .onSubmit { if editing != text { commit(editing) } }
    }
}
