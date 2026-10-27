import AppKit
import Modeling
import Procedural
import SwiftUI
import simd

/// The network view: Houdini's, nodes flowing top to bottom on a dotted grid. Tab adds a node (wired below the
/// selected one), drag from an output dot to an input to wire, click the flags (left: bypass; right: template,
/// display; Option-click display: render), right-click a node for its menu. Keys (GraphHostingView, ProcNetworkHost):
/// Delete, Tab, F frames, L lays out, R display, B bypass, T template, I info.
struct ProcNetworkView: View {
    @ObservedObject var session: ProceduralSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.hasNetwork {
                let g = session.graph
                GraphCanvas(model: session, bounds: ProcNetworkLayout.bounds(g), minimap: minimap(g),
                            items: { ProcNetworkLayout.items(in: $0, of: session.graph) },
                            inputNear: { ProcNetworkLayout.input(near: $0, in: session.graph) },
                            style: ProcTheme.canvas) { drags in
                    graph(g, drags)
                } menu: { at in
                    addMenu(at: at)
                } search: {
                    ProcNodeSearch(session: session)
                }
                if let id = session.infoNode, let n = g.node(id) {
                    ProcNodeInfoView(session: session, node: n).padding(10)
                }
                ProcNetworkBar(session: session)
            } else {
                VStack(spacing: 10) {
                    Text("This object has no network").font(ProcTheme.font).foregroundColor(ProcTheme.dim)
                    HStack {
                        if session.model?.activeObject != nil {
                            Button("New Network on \(session.model?.activeObject?.name ?? "")") { session.makeNetwork() }
                        }
                        Button("Add Procedural Object") { session.addObject() }
                    }
                    Text("The object's mesh becomes what the network makes.").font(ProcTheme.small).foregroundColor(ProcTheme.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ProcTheme.network)
            }
        }
    }

    private func minimap(_ g: ProcGraph) -> [GraphMinimap<ProceduralSession>.Box] {
        g.nodes.map { .init(rect: ProcNetworkLayout.rect($0), color: ProcTheme.body($0.kind), rounded: true) }
    }

    @ViewBuilder private func graph(_ g: ProcGraph, _ drags: GraphDrags<ProceduralSession>) -> some View {
        let area = ProcNetworkLayout.bounds(g).insetBy(dx: -400, dy: -400)
        ZStack(alignment: .topLeading) {
            GraphWires(area: area, wires: wires(g), dragged: drags.wire.flatMap { w in
                g.node(w.from).map { GraphWires.Wire(from: ProcNetworkLayout.output($0), to: w.to, color: ProcTheme.wire, selected: true) }
            }, vertical: true)
            ForEach(g.nodes) { n in
                ProcNodeView(session: session, node: n, drags: drags,
                             info: session.info[n.id], inputs: ProcNetworkLayout.inputCount(g, n),
                             wired: Set(g.links.filter { $0.to == n.id }.map(\.input)))
            }
        }
    }

    private func wires(_ g: ProcGraph) -> [GraphWires.Wire] {
        var out: [GraphWires.Wire] = []
        for n in g.nodes {
            let ins = g.inputs(of: n.id)
            let count = ProcNetworkLayout.inputCount(g, n)
            for (i, from) in ins.enumerated() {
                guard let from, let a = g.node(from) else { continue }
                let selected = session.selection.contains(n.id) || session.selection.contains(from)
                out.append(.init(from: ProcNetworkLayout.output(a), to: ProcNetworkLayout.input(n, i, of: count),
                                 color: selected ? ProcTheme.selected : ProcTheme.wire, selected: selected))
            }
        }
        return out
    }

    @ViewBuilder private func addMenu(at: SIMD2<Float>) -> some View {
        ForEach(ProcFamily.allCases, id: \.self) { f in
            let kinds = ProcNodeKind.allCases.filter { $0.spec.family == f }
            if !kinds.isEmpty {
                Menu(f.title) {
                    ForEach(kinds) { k in Button(k.spec.title) { session.add(k, at: at) } }
                }
            }
        }
        Divider()
        Button("Lay Out All  L") { session.selection = []; session.layout() }
        Button("Frame All  F") { session.frameAll(in: session.canvasSize) }
    }
}

/// One node: the body tinted by family with its icon, the flags (left: bypass; right: template and display), the
/// input dots on top and the output dot under it, the name and type to the right, an error or warning badge.
struct ProcNodeView: View {
    @ObservedObject var session: ProceduralSession
    let node: ProcNode
    let drags: GraphDrags<ProceduralSession>
    let info: ProcNodeInfo?
    let inputs: Int
    let wired: Set<Int>

    var body: some View {
        let L = ProcNetworkLayout.self
        let w = CGFloat(L.size.x), h = CGFloat(L.size.y), f = CGFloat(L.flag)
        let selected = session.selection.contains(node.id)
        let current = session.focus == node.id
        ZStack(alignment: .topLeading) {
            // The body, its flags at its ends.
            HStack(spacing: 0) {
                Rectangle().fill(node.bypass ? ProcTheme.bypass : ProcTheme.flagOff).frame(width: f)
                    .onTapGesture { session.toggleBypass(node.id) }
                    .help("Bypass (B)")
                ZStack {
                    Rectangle().fill(ProcTheme.body(node.kind).opacity(node.bypass ? 0.45 : 1))
                    Image(systemName: node.kind.spec.symbol).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.black.opacity(0.7))
                }
                .gesture(drags.header(node.id))
                Rectangle().fill(node.template ? ProcTheme.template : ProcTheme.flagOff).frame(width: f / 2 + 1)
                    .onTapGesture { session.toggleTemplate(node.id) }
                    .help("Template (T)")
                Rectangle().fill(node.display ? ProcTheme.display : node.render ? ProcTheme.render : ProcTheme.flagOff)
                    .frame(width: f / 2 + 2)
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.option) { session.setRender(node.id) } else { session.setDisplay(node.id) }
                    }
                    .help("Display (R); Option-click: Render")
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(current ? ProcTheme.current : selected ? ProcTheme.selected : Color.black.opacity(0.55),
                        lineWidth: selected || current ? 2 : 1))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .contextMenu { menu }
            // Inputs and output.
            ForEach(0..<inputs, id: \.self) { i in
                let p = ProcNetworkLayout.input(node, i, of: inputs)
                dot(wired.contains(i))
                    .offset(x: p.x - CGFloat(node.at.x) - 9, y: -9)
                    .gesture(drags.fromInput(node.id, "\(i)"))
            }
            dot(false)
                .offset(x: w / 2 - 9, y: h - 9)
                .gesture(drags.fromOutput(node.id, "out"))
            // Name, type, badges.
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).font(ProcTheme.font).foregroundColor(selected ? ProcTheme.selected : ProcTheme.text)
                HStack(spacing: 4) {
                    Text(node.kind.spec.title).font(ProcTheme.small).foregroundColor(ProcTheme.dim)
                    if let ms = info?.milliseconds, ms >= 1, info?.cached == false {
                        Text(String(format: "%.0f ms", ms)).font(ProcTheme.small).foregroundColor(ProcTheme.dim.opacity(0.8))
                    }
                }
            }
            .fixedSize()
            .offset(x: w + 8, y: 0)
            .allowsHitTesting(false)
            if let e = info?.error {
                badge("exclamationmark", ProcTheme.error).offset(x: -16, y: 5).help(e)
            } else if let warn = info?.warnings.first {
                badge("exclamationmark", ProcTheme.warning).offset(x: -16, y: 5).help(warn)
            }
            if !node.comment.isEmpty {
                Text(node.comment).font(ProcTheme.small).foregroundColor(ProcTheme.dim).fixedSize()
                    .offset(x: 0, y: h + 10).allowsHitTesting(false)
            }
        }
        .offset(x: CGFloat(node.at.x), y: CGFloat(node.at.y))
    }

    private func dot(_ filled: Bool) -> some View {
        ZStack {
            Circle().fill(filled ? ProcTheme.wire : Color(white: 0.22))
            Circle().stroke(Color(white: 0.75), lineWidth: 1.2)
        }
        .frame(width: 8, height: 8)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .heavy)).foregroundColor(.white)
            .frame(width: 13, height: 13).background(Circle().fill(color))
    }

    @ViewBuilder private var menu: some View {
        Button("Display Flag") { session.setDisplay(node.id) }
        Button("Render Flag") { session.setRender(node.id) }
        Button(node.template ? "Template Flag Off" : "Template Flag") { session.toggleTemplate(node.id) }
        Button(node.bypass ? "Bypass Off" : "Bypass") { session.toggleBypass(node.id) }
        Divider()
        Button("Info") { session.infoNode = node.id }
        Button("Rename…") { ProcRenamePrompt.ask(session, node) }
        Divider()
        Button("Delete") { session.selection = [node.id]; session.deleteSelection() }
    }
}

/// Rename: the node's new name.
enum ProcRenamePrompt {
    static func ask(_ session: ProceduralSession, _ node: ProcNode) {
        let alert = NSAlert()
        alert.messageText = "Rename \(node.name)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = node.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { session.rename(node.id, to: field.stringValue) }
    }
}

/// Save as Procedural Asset: its name.
enum ProcAssetPrompt {
    static func ask(_ session: ProceduralSession) {
        let alert = NSAlert()
        alert.messageText = "Save the network as a procedural asset"
        alert.informativeText = "It goes to Assets/Procedural; a scene places it as proc:<name>, each copy with its own values of the promoted parameters."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = session.assetSlug ?? session.model?.activeObject?.name ?? "asset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { session.saveAsset(named: field.stringValue) }
    }
}

/// Tab's menu: every node kind by name, its family beside it.
struct ProcNodeSearch: View {
    @ObservedObject var session: ProceduralSession

    var body: some View {
        GraphNodeSearch(placeholder: "Add a node", items: ProcNodeKind.allCases.map { k in
            .init(id: k.rawValue, title: k.spec.title, detail: k.spec.family.title) { session.add(k, at: session.searchAt) }
        }, close: { session.closeSearch() })
    }
}

/// The bar over the network: what the network holds, whether it is cooking, and its menu.
struct ProcNetworkBar: View {
    @ObservedObject var session: ProceduralSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundColor(ProcTheme.dim)
            Text(session.model?.activeObject?.name ?? "").font(ProcTheme.font).foregroundColor(ProcTheme.text)
            if session.cooking { ProgressView().controlSize(.mini) }
            Spacer()
            Menu("Network") {
                Button("Lay Out All  L") { session.selection = []; session.layout() }
                Button("Frame All  F") { session.frameAll(in: session.canvasSize) }
                Divider()
                Button("Save as Procedural Asset…") { ProcAssetPrompt.ask(session) }
                Button("Place Asset in Scene") { session.placeAsset() }.disabled(session.assetSlug == nil)
                Divider()
                Button("Bake Network (keep the mesh)") { session.bakeNetwork() }
                Button("Add Procedural Object") { session.addObject() }
            }
            .menuStyle(.borderlessButton).fixedSize().font(ProcTheme.font)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(ProcTheme.paneHeader.opacity(0.92))
    }
}

/// A node's info (Houdini's middle-click popup): its counts, attributes, groups, cook time, error.
struct ProcNodeInfoView: View {
    @ObservedObject var session: ProceduralSession
    let node: ProcNode

    var body: some View {
        let i = session.info[node.id]
        let geo = session.focus == node.id || session.graph.displayNode == node.id ? session.displayGeometry : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(node.name)").font(.system(size: 12, weight: .semibold)).foregroundColor(ProcTheme.text)
                Text(node.kind.spec.title).font(ProcTheme.small).foregroundColor(ProcTheme.dim)
                Spacer()
                Button { session.infoNode = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Text(node.kind.spec.summary).font(ProcTheme.small).foregroundColor(ProcTheme.dim).fixedSize(horizontal: false, vertical: true)
            if let e = i?.error { Text(e).font(ProcTheme.small).foregroundColor(ProcTheme.error) }
            ForEach(i?.warnings ?? [], id: \.self) { w in Text(w).font(ProcTheme.small).foregroundColor(ProcTheme.warning) }
            if let i, i.error == nil {
                Text("\(i.points) points  \(i.vertices) vertices  \(i.prims) primitives").font(ProcTheme.small).foregroundColor(ProcTheme.text)
                Text(i.cached ? "From the cache" : String(format: "Cooked in %.2f ms", i.milliseconds)).font(ProcTheme.small).foregroundColor(ProcTheme.dim)
            }
            if let geo, session.graph.displayNode == node.id {
                ForEach(AttributeClass.allCases) { c in
                    let t = geo.table(c)
                    let names = (c == .point ? ["P"] : []) + t.attributes.map { "\($0.name) (\($0.values.type.rawValue))" }
                    if !names.isEmpty || !t.groups.isEmpty {
                        Text("\(c.title): " + (names + t.groupNames.map { "group \($0)" }).joined(separator: ", "))
                            .font(ProcTheme.small).foregroundColor(ProcTheme.label).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(ProcTheme.paneHeader))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
        .padding(.top, 24)
    }
}

/// The network view in its own hosting view inside the Modeller's window: its keys, scrolls and pinches
/// (GraphHostingView), and Houdini's network keys.
struct ProcNetworkHost: NSViewRepresentable {
    let session: ProceduralSession

    func makeNSView(context: Context) -> GraphHostingView {
        let host = GraphHostingView(rootView: AnyView(ProcNetworkView(session: session)))
        host.model = session
        host.keys = { [weak session] event in
            guard let session, session.searchAt == nil else { return false }
            let target = session.focus ?? session.selection.first
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "l": session.layout()
            case "r": if let t = target { session.setDisplay(t) }
            case "b": if let t = target { session.toggleBypass(t) }
            case "t": if let t = target { session.toggleTemplate(t) }
            case "i": session.infoNode = session.infoNode == nil ? target : nil
            default: return false
            }
            return true
        }
        session.focusCanvas = { [weak host] in
            guard let host, let window = host.window, window.firstResponder !== host else { return }
            window.makeFirstResponder(host)
        }
        return host
    }

    func updateNSView(_ nsView: GraphHostingView, context: Context) {}
}
