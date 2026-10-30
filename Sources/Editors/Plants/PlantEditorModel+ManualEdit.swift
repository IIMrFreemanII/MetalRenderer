import Effects
import EngineCore
import MetalRenderer
import Plants
import simd

/// What a Manual Edit node's tool does with a click in the view (Unreal's TRS and Branch Removal modes).
enum PlantEditTool: String, CaseIterable {
    case transform      // a click selects a point; its handle moves and turns it
    case removeBranch   // a click cuts a branch off
    case trim           // a click cuts a branch beyond the point
}

/// The tool of a Manual Edit node, in the workshop's view. The first time it's taken up, what the view shows becomes the
/// node's hero plant. While it's up the workshop shows the stems; a click goes to the tool, the handle's drag is one undo
/// step that the workshop follows as a slider's.
extension PlantEditorModel {
    /// The node's tool, taken up.
    func startEditing(_ id: Int32, tool: PlantEditTool) {
        guard let node = graph.node(id), case .manualEdit(var e) = node.settings, node.side == .plant else { return }
        if !inWorkshop { goToWorkshop() }
        if e.seed == 0 {
            let p = scene.plants, count = max(def.variants(p.age), 1)
            e.age = p.age.rawValue
            e.variant = min(p.variant, count - 1)
            e.seed = def.plantSeed(UInt64(max(p.seed, 0)), p.age, e.variant)
            setSettings(id, .manualEdit(e))
        }
        guard let editing = PlantEditing(graph: graph, node: id, species: species) else {
            stopEditing()
            return
        }
        if editNode != id { editingView = scene.plants.view }
        self.editing = editing
        editNode = id
        editTool = tool
        editUpstream = upstream(of: id)
        editPick = nil
        editWeights = []
        hoverPick = nil
        let age = Foliage.Age(rawValue: e.age) ?? .mature, variant = e.variant
        workshop { $0.species = self.selected; $0.layout = .single; $0.age = age; $0.variant = variant; $0.view = .skeleton }
        sendTool()
    }

    func stopEditing() {
        guard editNode != nil else { return }
        editNode = nil
        editTool = nil
        editing = nil
        editPick = nil
        editWeights = []
        hoverPick = nil
        controller.setPlantTool(nil)
        if let view = editingView {
            editingView = nil
            workshop { $0.view = view }
        }
    }

    /// What it takes of the plant: the nodes before it, to tell when it has to be taken again.
    private func upstream(of id: Int32) -> [PlantNode] {
        let g = graph.canonical, all = graph.nodes
        guard let at = all.firstIndex(where: { $0.id == id }) else { return [] }
        return g.nodes.indices.filter { $0 < at && all[$0].side == .plant }.map { g.nodes[$0] }
    }

    /// The catalog changed (a tool's edit, an undo, an edit of another stage): the tool goes on from there.
    func catalogChangedUnderTool() {
        guard let id = editNode else { return }
        guard let node = graph.node(id), case .manualEdit(let e) = node.settings else { return stopEditing() }
        let now = upstream(of: id)
        if now != editUpstream {
            editUpstream = now
            editing = PlantEditing(graph: graph, node: id, species: species)
            editPick = nil
            editWeights = []
            hoverPick = nil
            if editing == nil { return stopEditing() }
        } else {
            editing?.update(e)
        }
        // (An undo can take away what was picked.)
        if let pick = editPick, editing?.isThere(pick) != true { editPick = nil; editWeights = [] }
        if let pick = hoverPick, editing?.isThere(pick) != true { hoverPick = nil }
        sendTool()
    }

    /// The spread of a move changed.
    func setSpread(_ spread: PlantEditing.Spread) {
        editSpread = spread
        if let pick = editPick, let editing { editWeights = editing.weights(pick, spread) }
        sendTool()
    }

    /// The node selected's moves or its cuts taken out, its tool up or not.
    func clearEditing(moves: Bool) {
        guard let id = focus.flatMap({ Int32($0) }), let node = graph.node(id), case .manualEdit(let e) = node.settings else { return }
        var cleared = e
        if moves {
            cleared.points = []
            cleared.moves = []
            cleared.turns = []
        } else {
            cleared.removed = []
        }
        setSettings(id, .manualEdit(cleared))
    }

    private func changeEditing(_ change: (inout PlantEditing) -> Void) {
        guard let id = editNode, var editing else { return }
        change(&editing)
        self.editing = editing
        setSettings(id, .manualEdit(editing.settings))
    }

    // MARK: - The mouse

    func plantToolEvent(_ event: PlantToolEvent) {
        guard editNode != nil, let editing else { return }
        switch event {
        case .hover(let origin, let direction):
            let pick = editing.pick(origin: origin, direction: direction)
            guard pick != hoverPick else { return }
            hoverPick = pick
            sendTool()
        case .click(let origin, let direction):
            let pick = editing.pick(origin: origin, direction: direction)
            switch editTool {
            case .transform:
                editPick = pick
                editWeights = pick.map { editing.weights($0, editSpread) } ?? []
                sendTool()
            case .removeBranch, .trim:
                guard let pick else { return }
                let trim = editTool == .trim
                hoverPick = nil
                changeEditing { $0.remove(pick, trim: trim) }
            case nil: break
            }
        case .moved(let delta, let phase):
            drag(phase) {
                let weights = editWeights
                changeEditing { $0.move(by: delta, weights: weights) }
            }
        case .turned(let axis, let angle, let phase):
            drag(phase) {
                guard let pick = editPick else { return }
                changeEditing { $0.turn(pick, axis: axis, angle: angle) }
            }
        }
    }

    private func drag(_ phase: Int, step: () -> Void) {
        switch phase {
        case 0: beginDrag()
        case 1: if editPick != nil { step() }
        default: endDrag()
        }
    }

    // MARK: - The view

    /// What the tool draws, sent to the renderer.
    func sendTool() {
        guard let editing else { return }
        var lines: [VFXGizmos.Segment] = []
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD4<Float>, _ width: Float) { lines.append(VFXGizmos.line(a, b, color, width)) }
        if !editWeights.isEmpty {
            for line in editing.lines(weights: editWeights) {
                add(line.a, line.b, SIMD4<Float>(1, 0.45 + 0.4 * (1 - line.weight), 0.1, 1), 2 + 2 * line.weight)
            }
        }
        if let pick = hoverPick {
            switch editTool {
            case .trim, .removeBranch:
                let from = editTool == .trim ? pick.index : 0
                for line in editing.lines(branch: pick.branch, from: from) { add(line.a, line.b, [1, 0.2, 0.15, 1], 4) }
            case .transform, nil:
                for line in editing.lines(branch: pick.branch) { add(line.a, line.b, [1, 0.95, 0.4, 1], 2) }
            }
        }
        let handle = editTool == .transform ? editPick.map { editing.position($0.point) } : nil
        controller.setPlantTool(PlantToolOverlay(lines: lines, handle: handle, rings: editPick.map(editing.canTurn) ?? false))
    }
}
