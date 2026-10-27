import AppKit
import Modeling
import Procedural
import SwiftUI
import simd

/// A handle being dragged: the node and parameter it sets, which point of a list (a curve's), the axis it is held
/// to (nil: free, in the view's plane), and where it started.
struct ProcHandleDrag {
    var node: String
    var param: String
    var index: Int?
    var axis: Int?
    var start: SIMD3<Float>
    var mouse: SIMD2<Float>
}

/// What the viewport shows of a network besides the display node's mesh: the current node's handles (its centre or
/// translate, a curve's points), normals, the mesh coloured by Cd.
extension ProceduralSession {
    /// A handle: where it is (the object's space), the parameter it sets, and whether it has axes.
    struct Handle {
        var at: SIMD3<Float>
        var param: String
        var index: Int?
        var axes: Bool
    }

    /// The current node's handles: a vector parameter that places it (`t`, `origin`, `p`) with axes, and each point of
    /// a points list.
    var handles: [Handle] {
        guard showHandles, let id = focus ?? graph.displayNode, let n = graph.node(id) else { return [] }
        var out: [Handle] = []
        for name in ["t", "origin"] where n.spec.param(name).map({ if case .vector = $0.ui { true } else { false } }) == true {
            out.append(Handle(at: n.param(name).vec3, param: name, index: nil, axes: true))
        }
        if case .points(let pts) = n.param("points") {
            for (i, p) in pts.enumerated() { out.append(Handle(at: p, param: "points", index: i, axes: false)) }
        }
        return out
    }

    private func screen(_ p: SIMD3<Float>, _ m: ModelingModel, _ toWorld: float4x4) -> SIMD2<Float>? {
        let w = toWorld * SIMD4(p, 1)
        return m.camera.project(SIMD3(w.x, w.y, w.z), size: m.viewSize).map { SIMD2($0.x, $0.y) }
    }

    private func handleScale(_ p: SIMD3<Float>, _ m: ModelingModel) -> Float {
        let depth = max(simd_dot(p - m.camera.eye, m.camera.forward), 0.01)
        return m.camera.metresPerPoint(depth: depth, viewHeight: m.viewSize.y) * 70
    }

    /// The handles drawn: three axes and a box at a placing parameter, a cross at each curve point.
    func handleLines(_ m: ModelingModel, transform: float4x4) -> [OverlayLine] {
        var lines: [OverlayLine] = []
        let colors: [SIMD4<Float>] = [[0.9, 0.2, 0.25, 1], [0.35, 0.8, 0.2, 1], [0.2, 0.45, 0.95, 1]]
        for h in handles {
            let w4 = transform * SIMD4(h.at, 1)
            let w = SIMD3(w4.x, w4.y, w4.z)
            let s = handleScale(w, m)
            if h.axes {
                for i in 0..<3 {
                    var axis = SIMD3<Float>.zero
                    axis[i] = 1
                    let active = handleDrag?.param == h.param && handleDrag?.axis == i
                    lines.append(OverlayLine(w, w + axis * s, color: active ? [1, 0.9, 0.3, 1] : colors[i], width: 3))
                }
            }
            let r = s * (h.axes ? 0.08 : 0.06)
            let c: SIMD4<Float> = handleDrag?.param == h.param && handleDrag?.index == h.index ? [1, 0.9, 0.3, 1] : [1, 1, 1, 1]
            lines.append(OverlayLine(w - [r, 0, 0], w + [r, 0, 0], color: c, width: 2.5))
            lines.append(OverlayLine(w - [0, r, 0], w + [0, r, 0], color: c, width: 2.5))
            lines.append(OverlayLine(w - [0, 0, r], w + [0, 0, r], color: c, width: 2.5))
        }
        return lines
    }

    /// A press on a handle: its drag starts (true), else the viewport's own click goes on.
    func beginHandleDrag(at p: SIMD2<Float>, _ m: ModelingModel, transform: float4x4) -> Bool {
        guard let id = focus ?? graph.displayNode else { return false }
        var best: (ProcHandleDrag, Float)?
        for h in handles {
            guard let c = screen(h.at, m, transform) else { continue }
            if h.axes {
                let w4 = transform * SIMD4(h.at, 1)
                let s = handleScale(SIMD3(w4.x, w4.y, w4.z), m)
                for i in 0..<3 {
                    var axis = SIMD3<Float>.zero
                    axis[i] = s
                    guard let e = screen(h.at + (transform.inverse * SIMD4(axis, 0)).xyz, m, transform) else { continue }
                    let ab = e - c
                    let t = max(0.2, min(1, simd_dot(p - c, ab) / max(simd_length_squared(ab), 1e-6)))
                    let d = simd_distance(p, c + ab * t)
                    if d < 8, d < best?.1 ?? .infinity { best = (ProcHandleDrag(node: id, param: h.param, index: nil, axis: i, start: h.at, mouse: p), d) }
                }
            }
            let d = simd_distance(p, c)
            if d < 10, d < best?.1 ?? .infinity { best = (ProcHandleDrag(node: id, param: h.param, index: h.index, axis: nil, start: h.at, mouse: p), d) }
        }
        guard let b = best?.0 else { return false }
        handleDrag = b
        beginDrag()
        m.redraw()
        return true
    }

    /// The drag moved: along its axis (as the axis runs on screen), or freely in the view's plane through the handle.
    func dragHandle(to p: SIMD2<Float>, _ m: ModelingModel, transform: float4x4) {
        guard let d = handleDrag, let n = graph.node(d.node) else { return }
        var at = d.start
        if let i = d.axis {
            var axis = SIMD3<Float>.zero
            axis[i] = 1
            let local = (transform.inverse * SIMD4(axis, 0)).xyz
            guard let c = screen(d.start, m, transform), let e = screen(d.start + local, m, transform) else { return }
            let ab = e - c
            at = d.start + local * (simd_dot(p - d.mouse, ab) / max(simd_length_squared(ab), 1e-6))
        } else {
            let w4 = transform * SIMD4(d.start, 1)
            let w = SIMD3(w4.x, w4.y, w4.z)
            let (o, dir) = m.camera.ray(at: p, size: m.viewSize)
            let nrm = m.camera.forward
            let denom = simd_dot(dir, nrm)
            guard abs(denom) > 1e-6 else { return }
            let hit = o + dir * (simd_dot(w - o, nrm) / denom)
            at = (transform.inverse * SIMD4(hit, 1)).xyz
        }
        if let i = d.index, case .points(var pts) = n.param(d.param), i < pts.count {
            pts[i] = at
            setParamLive(d.node, d.param, .points(pts))
        } else {
            setParamLive(d.node, d.param, .vec3(at))
        }
    }

    func endHandleDrag() {
        guard handleDrag != nil else { return }
        handleDrag = nil
        endDrag("Move Handle")
    }

    // MARK: Normals and colours

    /// The display geometry's normals as short lines (vertex N, else point N, else primitive N).
    func normalLines(transform: float4x4) -> [OverlayLine] {
        guard showNormals, let g = displayGeometry else { return [] }
        let b = g.bounds
        let len = b.isEmpty ? 0.1 : simd_length(b.hi - b.lo) * 0.04
        var lines: [OverlayLine] = []
        let color: SIMD4<Float> = [0.35, 0.75, 1, 1]
        func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>) {
            let a = (transform * SIMD4(p, 1)).xyz, e = (transform * SIMD4(p + n * len, 1)).xyz
            lines.append(OverlayLine(a, e, color: color))
        }
        if let vn = g.vertices.vectors3("N") {
            for v in 0..<min(g.vertexCount, 50_000) { add(g.P[Int(g.vertexPoint[v])], vn[v]) }
        } else if let pn = g.points.vectors3("N") {
            for i in 0..<min(g.pointCount, 50_000) { add(g.P[i], pn[i]) }
        } else {
            for p in 0..<min(g.primCount, 50_000) where g.isPolygon(p) { add(g.primCenter(p), g.primNormal(p)) }
        }
        return lines
    }

    /// The display geometry coloured by Cd (a primitive's, or its points' or vertices' mean), its colours quantised
    /// to a palette of 216 the viewport takes as material colours; nil without Cd.
    func colorDraw(_ scene: ViewportScene) -> (mesh: ViewportMesh, palette: [SIMD4<Float>])? {
        guard showColors, let g = displayGeometry,
              g.prims.vectors3("Cd") != nil || g.points.vectors3("Cd") != nil || g.vertices.vectors3("Cd") != nil else { return nil }
        let key = g.hashValueForDraw
        if let c = colorMesh, c.key == key { return (c.mesh, c.palette) }
        let primCd = g.prims.vectors3("Cd"), pointCd = g.points.vectors3("Cd"), vertexCd = g.vertices.vectors3("Cd")
        var (mesh, _) = g.editMesh()
        var f = 0
        for p in 0..<g.primCount where g.isPolygon(p) && f < mesh.faceCount {
            var c = SIMD3<Float>(repeating: 0.8)
            if let primCd { c = primCd[p] } else {
                let r = g.vertexRange(p)
                c = .zero
                for v in r { c += vertexCd?[v] ?? pointCd![Int(g.vertexPoint[v])] }
                c /= Float(r.count)
            }
            let q = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 5
            let k = Int(q.x.rounded()) * 36 + Int(q.y.rounded()) * 6 + Int(q.z.rounded())
            mesh.faceMaterial[f] = UInt16(k)
            f += 1
        }
        mesh.touch()
        // sRGB-ish steps made linear, as material colours are.
        let palette = (0..<216).map { k -> SIMD4<Float> in
            let c = SIMD3(Float(k / 36), Float(k / 6 % 6), Float(k % 6)) / 5
            return SIMD4(c * c, 1)
        }
        let vm = colorMesh?.mesh ?? ViewportMesh(device: scene.device)
        vm.setFaces(mesh, edit: false)
        colorMesh = (key, vm, palette)
        return (vm, palette)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

// MARK: - Over the viewport

/// The viewport's procedural overlays: its display toggles, and point and primitive numbers (and point dots) drawn
/// where the camera shows them.
struct ProcViewportOverlay: View {
    @ObservedObject var session: ProceduralSession
    @ObservedObject var view: CameraPublisher
    let model: ModelingModel

    var body: some View {
        ZStack(alignment: .top) {
            if let g = session.displayGeometry, session.pointNumbers || session.primNumbers || session.showPoints, let o = model.activeObject {
                Canvas { ctx, _ in
                    let m = o.transform.matrix
                    func at(_ p: SIMD3<Float>) -> CGPoint? {
                        let w = (m * SIMD4(p, 1)).xyz
                        return view.camera.project(w, size: model.viewSize).map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                    }
                    if session.showPoints {
                        var dots = Path()
                        for i in 0..<min(g.pointCount, 200_000) {
                            if let c = at(g.P[i]) { dots.addEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)) }
                        }
                        ctx.fill(dots, with: .color(Color(red: 0.95, green: 0.85, blue: 0.3)))
                    }
                    if session.pointNumbers {
                        for i in 0..<min(g.pointCount, 3000) {
                            if let c = at(g.P[i]) {
                                ctx.draw(Text("\(i)").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(red: 1, green: 0.95, blue: 0.5)),
                                         at: CGPoint(x: c.x + 6, y: c.y - 6))
                            }
                        }
                    }
                    if session.primNumbers {
                        for p in 0..<min(g.primCount, 3000) {
                            if let c = at(g.primCenter(p)) {
                                ctx.draw(Text("\(p)").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(red: 0.6, green: 0.85, blue: 1)), at: c)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            HStack(spacing: 2) {
                toggle("circle.grid.3x3.fill", "Points", $session.showPoints)
                toggle("number", "Point Numbers", $session.pointNumbers)
                toggle("number.square", "Primitive Numbers", $session.primNumbers)
                toggle("arrow.up.right", "Normals", $session.showNormals)
                toggle("paintpalette", "Colour by Cd", $session.showColors)
                toggle("move.3d", "Handles", $session.showHandles)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.45)))
            .padding(.top, 6)
        }
    }

    private func toggle(_ symbol: String, _ help: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundColor(on.wrappedValue ? ProcTheme.selected : ProcTheme.dim)
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(on.wrappedValue ? Color.white.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - The spreadsheet

/// The left area's tabs (Houdini's Scene View and Geometry Spreadsheet).
struct ProcLeftTabs: View {
    @ObservedObject var session: ProceduralSession

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ProceduralSession.LeftTab.allCases, id: \.self) { t in
                Button { session.leftTab = t } label: {
                    Text(t.rawValue).font(ProcTheme.font)
                        .foregroundColor(session.leftTab == t ? ProcTheme.text : ProcTheme.dim)
                        .padding(.horizontal, 12).frame(height: 22)
                        .background(session.leftTab == t ? ProcTheme.pane : ProcTheme.paneHeader)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .background(ProcTheme.paneHeader)
    }
}

/// The geometry spreadsheet: the current node's points, vertices, primitives or detail, a row each, a column per
/// attribute component (P[x], P[y] …) and group.
struct ProcSpreadsheet: View {
    @ObservedObject var session: ProceduralSession

    private var shown: (name: String, geometry: ProcGeo)? {
        if let i = session.inspected, i.id == session.focus { return (session.graph.node(i.id)?.name ?? "", i.geometry) }
        guard let g = session.displayGeometry else { return nil }
        return (session.graph.displayNode.flatMap { session.graph.node($0)?.name } ?? "", g)
    }

    private struct Column: Identifiable {
        var id: String { title }
        var title: String
        var cell: (Int) -> String
    }

    private func columns(_ g: ProcGeo, _ c: AttributeClass) -> [Column] {
        var out: [Column] = []
        if c == .vertex { out.append(Column(title: "Point Num") { "\(g.vertexPoint[$0])" }) }
        if c == .point {
            for (k, axis) in ["x", "y", "z"].enumerated() { out.append(Column(title: "P[\(axis)]") { String(format: "%.4g", g.P[$0][k]) }) }
        }
        let t = g.table(c)
        for a in t.attributes {
            let n = a.values.type.components
            if a.values.type == .string || n == 1 {
                out.append(Column(title: a.name) { a.values.string($0) })
            } else {
                for k in 0..<n {
                    let axis = ["x", "y", "z", "w"][k]
                    out.append(Column(title: "\(a.name)[\(axis)]") { String(format: "%.4g", a.values.component($0, k)) })
                }
            }
        }
        for gr in t.groups { out.append(Column(title: "group:\(gr.name)") { gr.members[$0] ? "1" : "0" }) }
        if c == .primitive {
            out.append(Column(title: "Vertices") { "\(g.primSize($0))" })
            out.append(Column(title: "Type") { g.primClosed[$0] ? "Polygon" : "Polyline" })
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AttributeClass.allCases) { c in
                    Button { session.spreadsheetClass = c } label: {
                        Text("\(c.title) \(shown?.geometry.count(c) ?? 0)").font(ProcTheme.font)
                            .foregroundColor(session.spreadsheetClass == c ? ProcTheme.text : ProcTheme.dim)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(session.spreadsheetClass == c ? ProcTheme.field : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Node: \(shown?.name ?? "—")").font(ProcTheme.small).foregroundColor(ProcTheme.dim)
            }
            .padding(4)
            .background(ProcTheme.paneHeader)
            if let g = shown?.geometry {
                let c = session.spreadsheetClass
                let cols = columns(g, c)
                let rows = g.count(c)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(0..<min(rows, 1_000_000), id: \.self) { r in
                                HStack(spacing: 0) {
                                    Text("\(r)").frame(width: 56, alignment: .trailing).foregroundColor(ProcTheme.dim)
                                    ForEach(cols) { col in Text(col.cell(r)).frame(width: 84, alignment: .trailing).lineLimit(1) }
                                }
                                .font(ProcTheme.mono)
                                .foregroundColor(ProcTheme.text)
                                .frame(height: 18)
                                .background(r % 2 == 0 ? ProcTheme.pane : ProcTheme.paneHeader.opacity(0.6))
                            }
                        } header: {
                            HStack(spacing: 0) {
                                Text("").frame(width: 56)
                                ForEach(cols) { col in Text(col.title).frame(width: 84, alignment: .trailing).lineLimit(1) }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(ProcTheme.label)
                            .frame(height: 20)
                            .background(ProcTheme.paneHeader)
                        }
                    }
                }
            } else {
                Text("Nothing cooked").font(ProcTheme.font).foregroundColor(ProcTheme.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ProcTheme.pane)
    }
}
