import SwiftUI
import simd

/// The inspector: the focused node's parameters (each can be exposed as the graph's input), its size and precision,
/// its error; a function node's values; with nothing focused, the graph's own settings (size, precision, seed, how the
/// renderer uses it) and its exposed inputs.
struct MaterialInspector: View {
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.editingFunction != nil, let id = model.focus, let n = model.function?.node(id) {
                    functionNode(n)
                } else if model.editingFunction == nil, let id = model.focus, let n = model.graph.node(id) {
                    node(n)
                } else {
                    graphSettings
                }
            }
            .padding(8)
        }
        .font(.system(size: 11))
    }

    // MARK: - A node

    @ViewBuilder
    private func node(_ n: MatNode) -> some View {
        let spec = n.kind.spec
        VFXSection(title: n.kind == .subgraph ? n.text("graph") : spec.title, subtitle: n.id) {
            Text(spec.summary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = model.errors[n.id] {
                Text(e).foregroundColor(.red).font(.system(size: 10, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if n.kind == .pixelProcessor {
                Button("Edit Function") {
                    model.editingFunction = n.id
                    DispatchQueue.main.async { model.frameAll(in: model.canvasSize) }
                }
            }
        }
        if n.kind == .subgraph {
            subgraphInputs(n)
        } else if !spec.params.isEmpty {
            VFXSection(title: "Parameters") {
                ForEach(spec.params.filter { !(n.kind == .code && $0.name == "code") }, id: \.name) { p in
                    MatParamRow(node: n, spec: p)
                }
            }
        }
        if n.kind == .code { CodeEditor(node: n) }
        VFXSection(title: "Image", subtitle: model.step(n.id).map { "\($0.pixels) × \($0.pixels), \($0.outputs.map(\.rawValue).joined(separator: ", "))" } ?? "") {
            Picker("Size", selection: Binding(get: { MatSizeChoice(n.size) }, set: { model.setSize(n.id, $0.size) })) {
                ForEach(MatSizeChoice.all, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Precision", selection: Binding(get: { n.bits }, set: { model.setBits(n.id, $0) })) {
                ForEach(MatBits.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    @ViewBuilder
    private func subgraphInputs(_ n: MatNode) -> some View {
        if let sub = model.catalog.graph(n.text("graph")) {
            VFXSection(title: "Its inputs") {
                if sub.inputs.isEmpty { Text("It exposes no parameters").foregroundColor(.secondary) }
                ForEach(sub.inputs, id: \.name) { input in
                    MatValueEditor(title: input.title, value: n.params[input.name] ?? input.value, span: input.span, choices: []) {
                        model.setParam(n.id, input.name, $0)
                    }
                }
                Button("Open \(sub.name)") { model.select(sub.name) }
            }
        } else {
            Text("No graph named \"\(n.text("graph"))\"").foregroundColor(.red)
        }
    }

    // MARK: - A function node

    @ViewBuilder
    private func functionNode(_ n: MatFnNode) -> some View {
        let spec = n.kind.spec
        VFXSection(title: spec.title, subtitle: n.id) {
            ForEach(spec.inputs, id: \.name) { p in
                if model.function?.link(into: n.id, p.name) != nil {
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text("wired").foregroundColor(.secondary)
                        Button("Disconnect") { model.unlink(n.id, p.name) }.controlSize(.small)
                    }
                } else {
                    MatValueEditor(title: p.name, value: n.param(p.name), span: p.span, choices: p.choices) { model.setParam(n.id, p.name, $0) }
                }
            }
            if spec.inputs.isEmpty { Text("No values").foregroundColor(.secondary) }
        }
        if let code = try? model.function?.code() {
            VFXSection(title: "Metal") {
                Text(code.metal).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The graph

    @ViewBuilder
    private var graphSettings: some View {
        let g = model.graph
        VFXSection(title: model.selectedGraph, subtitle: String(1 << g.size) + " px") {
            Picker("Size", selection: Binding(get: { g.size }, set: { s in model.edit { $0.size = s } })) {
                ForEach(8...12, id: \.self) { Text("\(1 << $0) × \(1 << $0)").tag($0) }
            }
            Picker("Precision", selection: Binding(get: { g.bits }, set: { b in model.edit { $0.bits = b } })) {
                Text("Auto (16-bit grey, 8-bit colour)").tag(MatBits.inherit)
                ForEach(MatBits.allCases.filter { $0 != .inherit }, id: \.self) { Text($0.title).tag($0) }
            }
            VFXIntRow(title: "Seed", value: g.seed, range: 0...9999) { s in model.edit { $0.seed = s } }
            if let e = model.planError { Text(e).foregroundColor(.red) }
            if let r = model.result {
                Text(String(format: "Baked: %d of %d nodes, GPU %.1f ms", r.baked, r.plan.steps.count, r.gpuMilliseconds)).foregroundColor(.secondary)
            }
        }
        VFXSection(title: "In the renderer") {
            VFXSliderRow(title: "Parallax depth", value: g.surface.heightDepth, span: 0...0.2) { v in model.setSurface { $0.heightDepth = v } }
            VFXSliderRow(title: "UV scale", value: g.surface.uvScale, span: 0.1...16) { v in model.setSurface { $0.uvScale = v } }
            VFXSliderRow(title: "Normal strength", value: g.surface.normalStrength, span: 0...4) { v in model.setSurface { $0.normalStrength = v } }
            VFXSliderRow(title: "AO strength", value: g.surface.aoStrength, span: 0...1) { v in model.setSurface { $0.aoStrength = v } }
            VFXSliderRow(title: "Opacity cutoff", value: g.surface.alphaCutoff, span: 0...1) { v in model.setSurface { $0.alphaCutoff = v } }
            VFXSliderRow(title: "Emissive", value: g.surface.emissiveIntensity, span: 0...64) { v in model.setSurface { $0.emissiveIntensity = v } }
            Toggle("Normal map is DirectX (green down)", isOn: Binding(get: { g.surface.normalDirectX }, set: { v in model.setSurface { $0.normalDirectX = v } }))
            Toggle("Run as code in the shading", isOn: Binding(get: { g.surface.shaderMode }, set: { v in model.setSurface { $0.shaderMode = v } }))
                .help("The renderer computes it at every shading point (resolution-free) instead of sampling its bake; an edit of its structure recompiles the shaders")
            if g.surface.shaderMode, let r = model.result {
                let reasons = MatShaderCode.reasons(r.plan)
                if reasons.isEmpty {
                    Text("Runs as code: \(MatShaderCode.evaluations(r.plan)) node evaluations a point").foregroundColor(.secondary)
                } else {
                    ForEach(reasons.sorted { $0.key < $1.key }, id: \.key) { id, why in
                        Text((id.isEmpty ? "" : "\(id): ") + why + " — baked instead").foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Channels: " + MatChannel.allCases.filter { g.channels[$0] != nil }.map(\.title).joined(separator: ", "))
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !g.inputs.isEmpty {
            VFXSection(title: "Exposed inputs", subtitle: "a subgraph node's parameters") {
                ForEach(g.inputs, id: \.name) { input in
                    MatValueEditor(title: input.title, value: input.value, span: input.span, choices: []) { model.setInput(input.name, $0) }
                }
            }
        }
    }
}

/// A node's size choice: inherited, relative (½ ... ×4) or absolute (256 ... 4096).
struct MatSizeChoice: Hashable {
    let size: MatSize
    init(_ s: MatSize) { size = s }
    static let all: [MatSizeChoice] = [MatSizeChoice(.inherit)] + (-3...2).filter { $0 != 0 }.map { MatSizeChoice(.relative($0)) }
        + (8...12).map { MatSizeChoice(.absolute($0)) }
    var title: String {
        switch size {
        case .inherit: return "Inherit"
        case .relative(let d): return d < 0 ? "Relative ÷\(1 << -d)" : "Relative ×\(1 << d)"
        case .absolute(let a): return "\(1 << a) px"
        }
    }
}

/// A node's parameter: its editor, and whether it is the graph's exposed input.
struct MatParamRow: View {
    let node: MatNode
    let spec: MatParamSpec
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        if let input = node.exposed[spec.name] {
            HStack {
                Text(spec.title)
                Spacer()
                Text("= input \(input)").foregroundColor(.secondary)
                Button("Unexpose") { model.expose(node.id, spec.name, false) }.controlSize(.small)
            }
        } else {
            HStack(alignment: .top, spacing: 2) {
                MatValueEditor(title: spec.title, value: node.param(spec.name), span: spec.span, choices: spec.choices) {
                    model.setParam(node.id, spec.name, $0)
                }
                if !spec.value.isText {
                    Menu {
                        Button("Expose as the graph's input") { model.expose(node.id, spec.name, true) }
                        Button("Reset to default") { model.setParam(node.id, spec.name, spec.value) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                }
            }
        }
    }
}

/// A value's editor by its kind.
struct MatValueEditor: View {
    let title: String
    let value: MatParam
    let span: ClosedRange<Float>?
    let choices: [String]
    let set: (MatParam) -> Void

    var body: some View {
        switch value {
        case .float(let f):
            if let span { VFXSliderRow(title: title, value: f, span: span) { set(.float($0)) } }
            else { VFXNumberRow(title: title, value: f) { set(.float($0)) } }
        case .int(let i):
            if let span, span.upperBound - span.lowerBound <= 512 {
                VFXSliderRow(title: title, value: Float(i), span: span) { set(.int(Int($0.rounded()))) }
            } else {
                VFXIntRow(title: title, value: i, range: span.map { Int($0.lowerBound)...Int($0.upperBound) } ?? -100_000...100_000) { set(.int($0)) }
            }
        case .bool(let b):
            Toggle(title, isOn: Binding(get: { b }, set: { set(.bool($0)) }))
        case .vec2(let v):
            HStack(spacing: 4) {
                Text(title).frame(width: 80, alignment: .leading).lineLimit(1)
                VFXNumberField(value: v.x) { set(.vec2([$0, v.y])) }
                VFXNumberField(value: v.y) { set(.vec2([v.x, $0])) }
            }
        case .color(let c):
            MatColorRow(title: title, color: c) { set(.color($0)) }
        case .choice(let s):
            Picker(title, selection: Binding(get: { s }, set: { set(.choice($0)) })) {
                if !choices.contains(s) { Text(s.isEmpty ? "—" : s).tag(s) }
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
        case .curve(let c):
            VFXCurveEditor(title: title, curve: c) { set(.curve($0)) }
        case .gradient(let g):
            VFXGradientEditor(title: title, gradient: g, set: { set(.gradient($0)) }, srgb: true)
        case .text(let t):
            VFXTextRow(title: title, text: t) { set(.text($0)) }
        }
    }
}

/// A colour as the graph has it: sRGB values (what a colour picker shows), and its opacity.
struct MatColorRow: View {
    let title: String
    let color: SIMD4<Float>
    let set: (SIMD4<Float>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ColorPicker(title, selection: Binding(get: {
                Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z), opacity: 1)
            }, set: { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                set(SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), color.w))
            }), supportsOpacity: false)
            VFXSliderRow(title: "Opacity", value: color.w, span: 0...1) { a in set(SIMD4(color.x, color.y, color.z, a)) }
        }
    }
}

/// A Code node's Metal: edited as text, compiled when applied (Cmd-Return), its compiler's errors on the node.
struct CodeEditor: View {
    let node: MatNode
    @EnvironmentObject var model: MaterialEditorModel
    @State private var text = ""

    var body: some View {
        VFXSection(title: "Metal", subtitle: "float4 f(float2 uv)") {
            Text("sampleInput(i, uv) reads input i; a, b, c, d are its parameters; size, seed.").foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 140)
                .onAppear { text = node.text("code") }
                .onChange(of: node.text("code")) { text = $0 }
            HStack {
                Spacer()
                Button("Revert") { text = node.text("code") }.disabled(text == node.text("code"))
                Button("Apply") { model.setParam(node.id, "code", .text(text)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text == node.text("code"))
            }
        }
    }
}
