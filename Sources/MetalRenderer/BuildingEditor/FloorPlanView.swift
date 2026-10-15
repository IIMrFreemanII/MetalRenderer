import SwiftUI
import simd

/// The Floor Plan window: the shown building's plan, a storey at a time, drawn from above (its front at the bottom),
/// and its tools: each click or drag is a hand edit of this building (PlanEdit, saved with it: LotOverride), one undo
/// step. While walking, where the walker is and which way it looks.
struct FloorPlanView: View {
    @EnvironmentObject var model: BuildingEditorModel

    enum Tool: String, CaseIterable { case look = "Look", wall = "Wall", door = "Door", split = "Split", merge = "Merge", type = "Type" }
    enum Scope: String, CaseIterable { case floor = "This floor", upper = "Upper floors", all = "Every floor" }

    @State private var storey = 0
    @State private var tool = Tool.look
    @State private var scope = Scope.floor
    @State private var roomType = RoomType.bedroom
    @State private var mergeFirst: SIMD2<Float>?
    @State private var drag: (from: SIMD2<Float>, to: SIMD2<Float>)?
    /// Where the room looked at is (the room there now, after any edit).
    @State private var pickedAt: SIMD2<Float>?
    private var picked: PlanRoom? {
        guard let at = pickedAt, let plan = model.plan, !plan.storeys.isEmpty else { return nil }
        return plan.storeys[clamped(plan)].room(at: at)
    }

    var body: some View {
        VStack(spacing: 6) {
            toolbar.padding(.horizontal, 10).padding(.top, 8)
            GeometryReader { geo in
                if let plan = model.plan, plan.storeys.indices.contains(clamped(plan)) {
                    let f = plan.storeys[clamped(plan)]
                    let map = Mapping(f, size: geo.size)
                    Canvas { ctx, _ in draw(f, plan, map, &ctx) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in drag = (map.plan(g.startLocation), map.plan(g.location)) }
                            .onEnded { g in
                                let from = map.plan(g.startLocation), to = map.plan(g.location)
                                drag = nil
                                let moved = hypot(g.location.x - g.startLocation.x, g.location.y - g.startLocation.y) > 4
                                act(from: from, to: moved ? to : nil, f, plan)
                            })
                } else {
                    Text("The plan of the workshop's building shows here (the Building workshop scene).")
                        .font(.system(size: 11)).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            status.padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(minWidth: 380, minHeight: 360)
        .onChange(of: model.walker?.storey) { s in if let s, tool == .look { storey = s } }
    }

    private func clamped(_ plan: BuildingPlan) -> Int { min(max(storey, 0), plan.storeys.count - 1) }

    // MARK: - The toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Stepper("Floor \(storey)", value: $storey, in: 0...max((model.plan?.storeys.count ?? 1) - 1, 0)).fixedSize()
                Picker("", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 120).help("Which floors an edit is for")
                Spacer()
                Button { model.undo.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.undo.canUndo)
                Button { model.undo.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.undo.canRedo)
            }
            HStack {
                Picker("", selection: $tool) { ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                if tool == .type {
                    Picker("", selection: $roomType) {
                        ForEach(RoomType.allCases.filter { !$0.isCore }, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                }
            }
            Text(help).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .font(.system(size: 11))
    }

    private var help: String {
        switch tool {
        case .look: return "Click a room to see it. Walking (V in the workshop), the plan follows the floor you are on."
        case .wall: return "Drag a wall to move it (with every room along it)."
        case .door: return "Click a wall for a door; click a door to turn it, Option-click to take it out; drag a door along its wall."
        case .split: return "Click a room to split it across its longer side there (Option: the other way)."
        case .merge: return "Click two rooms side by side to make them one."
        case .type: return "Pick what a room is for, then click it."
        }
    }

    private var status: some View {
        HStack {
            if let r = picked {
                Text(String(format: "%@ · %.1f × %.1f m (%.1f m²)%@", r.type.title, r.rect.size.x, r.rect.size.y, r.area,
                            r.unit >= 0 ? " · unit \(r.unit)" : " · common")).font(.system(size: 10))
            }
            if let first = mergeFirst { Text(String(format: "Merging the room at (%.1f, %.1f) with…", first.x, first.y)).font(.system(size: 10)) }
            Spacer()
            Text(model.currentRef.title).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
        }
    }

    // MARK: - Drawing

    /// The plan's metres (x, z) to the view's points: the whole storey fitted, its front (+z) at the bottom.
    struct Mapping {
        var lo: SIMD2<Float>, scale: Float, offset: CGPoint
        init(_ f: FloorPlan, size: CGSize) {
            var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
            for r in f.usable { lo = simd_min(lo, r.lo); hi = simd_max(hi, r.hi) }
            if lo.x > hi.x { lo = [-5, -5]; hi = [5, 5] }
            lo -= SIMD2(1, 1); hi += SIMD2(1, 1)
            scale = min(Float(size.width) / (hi.x - lo.x), Float(size.height) / (hi.y - lo.y))
            self.lo = lo
            offset = CGPoint(x: (size.width - CGFloat((hi.x - lo.x) * scale)) / 2, y: (size.height - CGFloat((hi.y - lo.y) * scale)) / 2)
        }
        func view(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: offset.x + CGFloat((p.x - lo.x) * scale), y: offset.y + CGFloat((p.y - lo.y) * scale)) }
        func plan(_ v: CGPoint) -> SIMD2<Float> { SIMD2(Float(v.x - offset.x) / scale + lo.x, Float(v.y - offset.y) / scale + lo.y) }
        func rect(_ r: CityPlan.Rect) -> CGRect {
            let a = view(r.lo), b = view(r.hi)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
    }

    private func color(_ t: RoomType) -> Color {
        switch t {
        case .living, .dining: return Color(red: 0.95, green: 0.86, blue: 0.7)
        case .bedroom, .study: return Color(red: 0.8, green: 0.86, blue: 0.95)
        case .kitchen, .kitchenette: return Color(red: 0.95, green: 0.93, blue: 0.7)
        case .bath, .wc, .toilets: return Color(red: 0.75, green: 0.92, blue: 0.92)
        case .entrance, .landing, .corridor, .lobby: return Color(white: 0.9)
        case .stairs, .lift: return Color(white: 0.72)
        case .office, .openOffice, .meeting: return Color(red: 0.86, green: 0.9, blue: 0.82)
        case .shop, .backroom: return Color(red: 0.95, green: 0.8, blue: 0.8)
        case .storage, .hall: return Color(white: 0.82)
        }
    }

    private func draw(_ f: FloorPlan, _ plan: BuildingPlan, _ map: Mapping, _ ctx: inout GraphicsContext) {
        for r in f.rooms {
            let rect = map.rect(r.rect)
            ctx.fill(Path(rect), with: .color(color(r.type).opacity(picked?.id == r.id ? 1 : 0.85)))
            ctx.stroke(Path(rect), with: .color(.black.opacity(0.55)), lineWidth: 1.2)
            if r.type == .stairs, let st = f.stair {
                // The steps: lines across the well.
                let w = map.rect(st.well)
                for k in 1..<10 {
                    var p = Path()
                    if st.alongX {
                        let x = w.minX + w.width * CGFloat(k) / 10
                        p.move(to: CGPoint(x: x, y: w.minY)); p.addLine(to: CGPoint(x: x, y: w.maxY))
                    } else {
                        let y = w.minY + w.height * CGFloat(k) / 10
                        p.move(to: CGPoint(x: w.minX, y: y)); p.addLine(to: CGPoint(x: w.maxX, y: y))
                    }
                    ctx.stroke(p, with: .color(.black.opacity(0.3)), lineWidth: 0.6)
                }
            }
            if r.type == .lift {
                var p = Path()
                p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.stroke(p, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
            }
            if rect.width > 34 && rect.height > 18 {
                ctx.draw(Text(r.type.title).font(.system(size: 9)).foregroundColor(.black.opacity(0.75)), at: CGPoint(x: rect.midX, y: rect.midY - 5))
                ctx.draw(Text(String(format: "%.0f m²", r.area)).font(.system(size: 8)).foregroundColor(.black.opacity(0.5)),
                         at: CGPoint(x: rect.midX, y: rect.midY + 6))
            }
        }
        // The outer walls: a thick line round the plan.
        for u in f.usable {
            ctx.stroke(Path(map.rect(CityPlan.Rect(lo: u.lo - SIMD2(plan.outer, plan.outer) / 2, hi: u.hi + SIMD2(plan.outer, plan.outer) / 2))),
                       with: .color(.black.opacity(0.8)), lineWidth: CGFloat(plan.outer * map.scale))
        }
        // Doors: the opening cleared, the leaf's swing as an arc; rooms that are one: a dashed line.
        for d in f.doors {
            let e: SIMD2<Float> = d.alongX ? SIMD2(1, 0) : SIMD2(0, 1)
            let a = map.view(d.at - e * d.width / 2), b = map.view(d.at + e * d.width / 2)
            var gap = Path()
            gap.move(to: a); gap.addLine(to: b)
            if d.kind == .open {
                ctx.stroke(gap, with: .color(.white), lineWidth: 3)
                ctx.stroke(gap, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                continue
            }
            ctx.stroke(gap, with: .color(.white), lineWidth: d.b < 0 ? CGFloat(plan.outer * map.scale) + 1 : 3)
            let into: SIMD2<Float> = d.into >= 0 && f.rooms.indices.contains(d.into) ? f.rooms[d.into].rect.center : d.at
            let n: SIMD2<Float> = d.alongX ? SIMD2(0, into.y > d.at.y ? 1 : -1) : SIMD2(into.x > d.at.x ? 1 : -1, 0)
            let hinge = d.at - e * (d.hingeLow ? 1 : -1) * d.width / 2
            let leafEnd = hinge + n * d.width
            var swing = Path()
            swing.move(to: map.view(hinge)); swing.addLine(to: map.view(leafEnd))
            let start = atan2(Double(map.view(d.hingeLow ? d.at + e * d.width / 2 : d.at - e * d.width / 2).y - map.view(hinge).y),
                              Double(map.view(d.hingeLow ? d.at + e * d.width / 2 : d.at - e * d.width / 2).x - map.view(hinge).x))
            let end = atan2(Double(map.view(leafEnd).y - map.view(hinge).y), Double(map.view(leafEnd).x - map.view(hinge).x))
            var delta = end - start
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            swing.addArc(center: map.view(hinge), radius: CGFloat(d.width * map.scale), startAngle: .radians(end), endAngle: .radians(start), clockwise: delta > 0)
            ctx.stroke(swing, with: .color(d.kind == .lift ? .gray : .brown), lineWidth: 1)
        }
        // The drag under way.
        if let drag {
            var p = Path()
            p.move(to: map.view(drag.from)); p.addLine(to: map.view(drag.to))
            ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
        if let first = mergeFirst {
            ctx.fill(Path(ellipseIn: CGRect(x: map.view(first).x - 4, y: map.view(first).y - 4, width: 8, height: 8)), with: .color(.accentColor))
        }
        // You are here.
        if let w = model.walker, w.building == 0, w.storey == f.storey, let p = w.local {
            let at = map.view(SIMD2(p.x, p.z))
            let dir = SIMD2(sin(w.yaw), -cos(w.yaw))
            var arrow = Path()
            arrow.move(to: at)
            arrow.addLine(to: map.view(SIMD2(p.x, p.z) + dir * 1.2))
            ctx.stroke(arrow, with: .color(.red), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)), with: .color(.red))
        }
    }

    // MARK: - Tools

    private var storeys: StoreySel {
        switch scope {
        case .floor: return .one(storey)
        case .upper: return .range(1, max((model.plan?.storeys.count ?? 2) - 1, 1))
        case .all: return .all
        }
    }

    private func act(from p: SIMD2<Float>, to: SIMD2<Float>?, _ f: FloorPlan, _ plan: BuildingPlan) {
        let option = NSEvent.modifierFlags.contains(.option)
        let room = f.room(at: p)
        switch tool {
        case .look:
            pickedAt = room == nil ? nil : p
        case .wall:
            guard let to else { return }
            model.addEdit(PlanEdit(op: .moveWall, storeys: storeys, at: p, to: to))
        case .door:
            let near = f.doors.filter { $0.kind != .open && $0.b >= 0 }.min { distance($0.at, p) < distance($1.at, p) }
            if let d = near, distance(d.at, p) < max(0.7, d.width / 2 + 0.2) {
                if let to {
                    model.addEdit(PlanEdit(op: .moveDoor, storeys: storeys, at: d.at, to: to))
                } else {
                    model.addEdit(PlanEdit(op: option ? .removeDoor : .flipDoor, storeys: storeys, at: d.at))
                }
            } else if to == nil {
                model.addEdit(PlanEdit(op: .addDoor, storeys: storeys, at: p, width: 0.9))
            }
        case .split:
            guard let r = room, !r.type.isCore else { return }
            // Across the longer side: a wall along z for a room wider than deep.
            var alongX = r.rect.size.y > r.rect.size.x
            if option { alongX.toggle() }
            model.addEdit(PlanEdit(op: .split, storeys: storeys, at: p, alongX: alongX))
        case .merge:
            if let first = mergeFirst {
                mergeFirst = nil
                model.addEdit(PlanEdit(op: .merge, storeys: storeys, at: first, to: p))
            } else if room != nil {
                mergeFirst = p
            }
        case .type:
            guard room != nil else { return }
            model.addEdit(PlanEdit(op: .setType, storeys: storeys, at: p, type: roomType))
        }
    }
}
