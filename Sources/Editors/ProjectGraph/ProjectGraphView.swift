import AppKit
import EngineCore
import MetalRenderer
import Physics
import Plants
import SwiftUI
import UniformTypeIdentifiers

/// The Project Graph's window: the toolbar (layout, what is shown, which links, search, pick), the outliner (the tree,
/// as an indented list), the graph and the inspector of what is selected.
struct ProjectGraphView: View {
    @EnvironmentObject var model: ProjectGraphModel

    var body: some View {
        VStack(spacing: 0) {
            ProjectGraphToolbar()
            Divider()
            HSplitView {
                ProjectGraphOutliner()
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                Group {
                    if model.layout == .cone {
                        ConeTreeView(model: model)
                    } else {
                        ProjectGraphCanvas(model: model)
                    }
                }
                .frame(minWidth: 360)
                ProjectGraphInspector()
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 440)
            }
            Divider()
            statusLine
        }
        .background(GraphColors.chrome)
        .preferredColorScheme(.dark)
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            Text("\(model.visible.nodes.count) shown of \(model.graph.nodes.count)")
            if !model.unindexed.isEmpty {
                Text("· \(model.unindexed.count) scenes have no outline yet: open them, or run METALRENDERER_BENCH=outlines")
                    .help(model.unindexed.joined(separator: ", "))
            }
            Spacer()
            Text(model.status).foregroundColor(GraphColors.selected)
        }
        .font(.system(size: 11))
        .foregroundColor(GraphColors.dim)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}

// MARK: - Toolbar

struct ProjectGraphToolbar: View {
    @EnvironmentObject var model: ProjectGraphModel
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.layout) {
                ForEach(GraphLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .labelsHidden()
            Picker("", selection: $model.scope) {
                ForEach(ProjectGraphModel.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
            Divider().frame(height: 18)
            ForEach(ProjectGraph.EdgeKind.allCases.filter { $0 != .child }, id: \.self) { kind in
                edgeToggle(kind)
            }
            Spacer()
            search
            Button(model.picking ? "Picking…" : "Pick") { model.pick() }
                .help("Select what the next click in the view meets")
            Button("Frame") { model.frameAll(in: model.canvasSize) }
                .help("The whole graph in view (F)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func edgeToggle(_ kind: ProjectGraph.EdgeKind) -> some View {
        let on = model.edgeKinds.contains(kind)
        let disabled = kind == .source && model.source == nil
        return Button {
            if on { model.edgeKinds.remove(kind) } else { model.edgeKinds.insert(kind) }
        } label: {
            HStack(spacing: 4) {
                Capsule().fill(ProjectGraphStyle.color(kind)).frame(width: 14, height: 4).opacity(on ? 1 : 0.3)
                Text(kind.title).font(.system(size: 11)).foregroundColor(on ? GraphColors.text : GraphColors.dim)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "No graphify graph (graphify-out/graph.json): run graphify update ." : "Show or hide these links")
    }

    private var search: some View {
        TextField("Search", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .focused($searching)
            .onSubmit { if let first = model.results.first { model.select(first) } }
            .overlay(alignment: .topLeading) {
                if searching && !model.query.isEmpty {
                    results.offset(y: 26)
                }
            }
            .zIndex(10)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.results.isEmpty {
                Text("Nothing found").font(.system(size: 11)).foregroundColor(GraphColors.dim).padding(6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.results, id: \.self) { id in
                        Button { model.select(id); searching = false } label: {
                            HStack {
                                Image(systemName: ProjectGraphStyle.symbol(model.graph[id]?.kind ?? .member)).frame(width: 16)
                                Text(model.name(id)).lineLimit(1)
                                Spacer()
                                Text(model.node(id)?.scene ?? "").foregroundColor(GraphColors.dim)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 6).fill(GraphColors.node))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15)))
        .shadow(radius: 8)
    }
}

// MARK: - Outliner

/// The tree as an indented list: open and close its branches (the graph's open ones are the same), drag a thing onto
/// another or onto a folder to move it there.
struct ProjectGraphOutliner: View {
    @EnvironmentObject var model: ProjectGraphModel

    private struct Row: Identifiable {
        var id: String
        var depth: Int
        var more: Int? = nil     // "more" row of an aggregate: how many are left
    }

    /// The rows: the open branches' children, depth first.
    private var rows: [Row] {
        let g = model.graph
        guard !g.nodes.isEmpty else { return [] }
        let root = model.scope == .scene ? g.index[ProjectGraph.sceneID(model.currentScene)] ?? 0 : 0
        var out: [Row] = []
        func walk(_ n: Int, _ depth: Int) {
            let node = g.nodes[n]
            out.append(Row(id: node.id, depth: depth))
            guard model.isOpen(node.id) || n == root else { return }
            for c in g.children[n] { walk(c, depth + 1) }
            if node.kind == .aggregate {
                let shown = min(node.members.count, ProjectGraph.memberPage * (model.pages[node.id] ?? 1))
                for m in 0..<shown { out.append(Row(id: SceneOutline.memberID(node.id, m), depth: depth + 1)) }
                if shown < node.members.count { out.append(Row(id: node.id + "#more", depth: depth + 1, more: node.members.count - shown)) }
            }
        }
        walk(root, 0)
        return out
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if let more = row.more {
                            Button("\(more) more…") { model.morePages(String(row.id.dropLast(5))) }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(GraphColors.selected)
                                .padding(.leading, CGFloat(row.depth) * 14 + 22).padding(.vertical, 3)
                        } else {
                            ProjectGraphRow(id: row.id, depth: row.depth).id(row.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.focus) { f in if let f { withAnimation { reader.scrollTo(f, anchor: .center) } } }
        }
        .background(GraphColors.chrome)
    }
}

struct ProjectGraphRow: View {
    @EnvironmentObject var model: ProjectGraphModel
    let id: String
    let depth: Int
    @State private var targeted = false

    var body: some View {
        let node = model.node(id)
        let isMember = model.graph[id] == nil
        let kind: ProjectGraph.Kind = isMember ? .member : node?.kind ?? .object
        let branch = !isMember && (node.map { n in !model.graph.children[model.graph.index[id]!].isEmpty || n.kind == .aggregate } ?? false)
        let selected = model.selection.contains(id)
        HStack(spacing: 4) {
            Group {
                if branch {
                    Image(systemName: model.isOpen(id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .onTapGesture { model.setOpen(id, !model.isOpen(id)) }
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            Image(systemName: ProjectGraphStyle.symbol(kind))
                .foregroundColor(ProjectGraphStyle.color(kind, asset: node?.asset?.kind))
                .frame(width: 16)
            Text(model.name(id)).lineLimit(1)
                .foregroundColor(model.isHidden(id) ? GraphColors.dim : GraphColors.text)
                .italic(node?.copyOf != nil)
            if model.isHidden(id) { Image(systemName: "eye.slash").foregroundColor(GraphColors.dim) }
            if node?.kind == .scene && node?.indexed == false {
                Image(systemName: "questionmark.circle").foregroundColor(GraphColors.dim).help(node?.info["Outline"] ?? "")
            }
            Spacer(minLength: 4)
            if !isMember, let n = node, n.count > 1 { Text("\(n.count)").foregroundColor(GraphColors.dim) }
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 8).padding(.vertical, 2.5)
        .background(selected ? GraphColors.selected.opacity(0.22) : targeted ? Color.white.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(id) }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { model.click(id, extend: true) } else { model.select(id) }
        }
        .contextMenu { ProjectGraphMenu(ids: model.selection.contains(id) ? model.selection : [id]) }
        .onDrag { NSItemProvider(object: id as NSString) }
        .onDrop(of: [UTType.text], isTargeted: $targeted) { providers in
            let target = id
            for p in providers {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let dragged = s as? String else { return }
                    DispatchQueue.main.async {
                        let ids = model.selection.contains(dragged) ? model.selection : [dragged]
                        model.move(ids, into: target)
                    }
                }
            }
            return true
        }
    }
}

/// What can be done with things: the outliner's and the canvas's menu, and the inspector's buttons.
struct ProjectGraphMenu: View {
    @EnvironmentObject var model: ProjectGraphModel
    let ids: Set<String>

    var body: some View {
        let one = ids.count == 1 ? ids.first : nil
        if let one {
            Button("Show in Viewport") { model.showInViewport(one) }.disabled(model.node(one)?.scene == nil)
            if let t = model.editorTarget(one) { Button("Open in \(t.title)") { model.openInEditor(one) } }
            Button("Rename…") { model.select(one); model.renaming = one }.disabled(model.lockReason(one) == "Not a thing of a scene")
            Divider()
        }
        let hidden = ids.allSatisfy(model.isHidden)
        Button(hidden ? "Show" : "Hide") { model.setHidden(ids, !hidden) }.disabled(!ids.contains(where: model.canHide))
        Button("Duplicate") { model.paste() }.disabled(!ids.contains(where: model.canHide))
        Button("Move to Folder…") { askFolder() }
        Button("Back Where the Scene Has It") { model.move(ids, toFolder: "") }
        if let one, model.pin(one) != nil { Button("Unpin") { model.setPin(one, nil) } }
    }

    private func askFolder() {
        let alert = NSAlert()
        alert.messageText = "Move to a folder"
        alert.informativeText = "A folder of the scene in the graph (\"Props/Crates\"). The scene itself doesn't change."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.move(ids, toFolder: field.stringValue.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Inspector

struct ProjectGraphInspector: View {
    @EnvironmentObject var model: ProjectGraphModel
    @State private var name = ""
    @FocusState private var naming: Bool

    var body: some View {
        ScrollView {
            if let id = model.focus, let node = model.node(id) {
                content(id, node).padding(10)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing selected").font(.headline).foregroundColor(GraphColors.text)
                    Text("Click a node, or Pick something in the view. Double-click opens its editor, or opens it in the graph.")
                        .foregroundColor(GraphColors.dim)
                    legend
                }
                .font(.system(size: 11))
                .padding(10)
            }
        }
        .background(GraphColors.chrome)
        .onChange(of: model.focus) { _ in name = model.focus.map(model.name) ?? "" }
        .onChange(of: model.renaming) { r in if r != nil { name = model.focus.map(model.name) ?? ""; naming = true; model.renaming = nil } }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([ProjectGraph.Kind.scene, .folder, .object, .aggregate, .light, .effect, .asset, .source], id: \.self) { k in
                HStack { Circle().fill(ProjectGraphStyle.color(k)).frame(width: 9, height: 9); Text(k.rawValue).foregroundColor(GraphColors.dim) }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func content(_ id: String, _ node: ProjectGraph.Node) -> some View {
        let g = model.graph
        let isMember = g[id] == nil
        VStack(alignment: .leading, spacing: 10) {
            // Where it is.
            if let k = g.index[id] ?? SceneOutline.member(of: id).flatMap({ g.index[$0.aggregate] }) {
                let path = g.path(k).dropLast(isMember ? 0 : 1)
                FlowRow(items: path.map { g.nodes[$0].id }) { pid in
                    Button(g.nodes[g.index[pid]!].name) { model.select(pid) }.buttonStyle(.plain).foregroundColor(GraphColors.dim)
                }
                .font(.system(size: 10.5))
            }
            HStack {
                Image(systemName: ProjectGraphStyle.symbol(isMember ? .member : node.kind))
                    .foregroundColor(ProjectGraphStyle.color(isMember ? .member : node.kind, asset: node.asset?.kind))
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($naming)
                    .onSubmit { model.rename(id, to: name) }
                    .disabled(model.lockReason(id) == "Not a thing of a scene")
            }
            Text(subtitle(id, node)).font(.system(size: 11)).foregroundColor(GraphColors.dim)
            buttons(id, node)
            if let reason = node.locked { Label(reason, systemImage: "lock").font(.system(size: 11)).foregroundColor(GraphColors.dim) }
            section("Properties", info(id, node))
            if !node.assets.isEmpty || node.asset != nil { assets(node) }
            references(id)
        }
        .font(.system(size: 11))
        .foregroundColor(GraphColors.text)
    }

    private func subtitle(_ id: String, _ n: ProjectGraph.Node) -> String {
        var parts = [model.graph[id] == nil ? "member" : n.kind.rawValue]
        if let s = n.scene { parts.append(s) }
        if n.count > 1 { parts.append("\(n.count) things") }
        if model.isHidden(id) { parts.append("hidden") }
        if let p = model.pin(id) { parts.append(String(format: "pinned at %.0f, %.0f", p.x, p.y)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func buttons(_ id: String, _ n: ProjectGraph.Node) -> some View {
        HStack {
            if n.scene != nil { Button("Show in Viewport") { model.showInViewport(id) } }
            if let t = model.editorTarget(id) { Button("Open in \(t.title)") { model.openInEditor(id) } }
        }
        if model.canHide(id) {
            HStack {
                Button(model.isHidden(id) ? "Show" : "Hide") { model.setHidden([id], !model.isHidden(id)) }
                Button("Duplicate") { model.select(id); model.paste() }
                Menu("Move") { ProjectGraphMenu(ids: [id]) }.frame(width: 70)
            }
            if n.count > 2000 { Text("Hiding or copying it makes the scene again.").foregroundColor(GraphColors.dim) }
        }
    }

    private func info(_ id: String, _ n: ProjectGraph.Node) -> [(String, String)] {
        var out = n.info.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if let (_, k) = SceneOutline.member(of: id), model.graph[id] == nil, let i = n.members[k] { out.insert(("Instance", "\(i)"), at: 0) }
        if let b = n.bounds {
            let s = b.hi - b.lo
            out.append(("Size", String(format: "%.2f × %.2f × %.2f m", s.x, s.y, s.z)))
        }
        if let c = n.copyOf { out.append(("Copy of", model.name(c))) }
        if let f = n.file { out.append(("File", f.path)) }
        return out
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !rows.isEmpty { Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundColor(GraphColors.dim) }
            ForEach(rows.indices, id: \.self) { k in
                HStack(alignment: .top) {
                    Text(rows[k].0).foregroundColor(GraphColors.dim).frame(width: 90, alignment: .leading)
                    Text(rows[k].1).textSelection(.enabled)
                }
            }
        }
    }

    private func assets(_ n: ProjectGraph.Node) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("MADE FROM AND WITH").font(.system(size: 9.5, weight: .semibold)).foregroundColor(GraphColors.dim)
            ForEach((n.asset.map { [$0] } ?? n.assets), id: \.self) { a in
                let hub = a.id(scope: model.outlinesScope(n.scene))
                HStack {
                    Circle().fill(ProjectGraphStyle.color(.asset, asset: a.kind)).frame(width: 7, height: 7)
                    Text(a.kind.title).foregroundColor(GraphColors.dim)
                    if model.graph[hub] != nil, n.asset == nil {
                        Button(a.name) { model.select(hub) }.buttonStyle(.plain).foregroundColor(GraphColors.selected)
                    } else {
                        Text(a.name)
                    }
                    if let t = EditorTarget(a) {
                        Spacer()
                        Button("Open") { model.openEditor?(t) }.help("In the \(t.title)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func references(_ id: String) -> some View {
        let refs = model.references(id)
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("LINKS (\(refs.count))").font(.system(size: 9.5, weight: .semibold)).foregroundColor(GraphColors.dim)
                ForEach(Array(refs.prefix(80).enumerated()), id: \.offset) { _, r in
                    let other = model.graph.nodes[r.other]
                    HStack {
                        Capsule().fill(ProjectGraphStyle.color(r.kind)).frame(width: 12, height: 3)
                        Image(systemName: r.outgoing ? "arrow.right" : "arrow.left").foregroundColor(GraphColors.dim)
                        Button(other.name) { model.select(other.id) }.buttonStyle(.plain)
                        Spacer()
                        Text(other.scene ?? other.kind.rawValue).foregroundColor(GraphColors.dim)
                        if let f = other.file {
                            Button { model.openSource(f) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.plain)
                                .help("Open \(f.path)")
                        }
                    }
                }
                if refs.count > 80 { Text("and \(refs.count - 80) more").foregroundColor(GraphColors.dim) }
            }
        }
    }
}

/// Items in a row that wraps, with chevrons between them (the inspector's path).
struct FlowRow<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        // (A path is short: a few levels.)
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { k, item in
                if k > 0 { Image(systemName: "chevron.right").font(.system(size: 7)).foregroundColor(GraphColors.dim) }
                content(item).lineLimit(1)
            }
        }
    }
}

extension ProjectGraphModel {
    /// The scope of a scene's outline (what its own assets' ids are made with).
    func outlinesScope(_ scene: String?) -> String {
        guard let scene, let k = graph.index[ProjectGraph.sceneID(scene)] else { return "" }
        return graph.nodes[k].info["Scope"] ?? scene
    }

    /// Opens a source file (its default app: Xcode for Swift).
    func openSource(_ f: SourceIndex.File) {
        let url = Scene.assetsDirectory.deletingLastPathComponent().appendingPathComponent(f.path)
        NSWorkspace.shared.open(url)
    }
}
