import AppKit
import Plants
import simd

/// How the selected species' Swift file stands.
enum PlantCompileStatus: Equatable {
    struct Failure: Equatable {
        var message: String
        var node: Int32?
    }

    case idle                       // it's built in, its code the app's
    case waiting                    // the graph runs until it's compiled
    case compiling
    case compiled(seconds: Double)
    case incomplete(String)         // wires missing: the plant stays as its recipe last said
    case failed([Failure])
}

/// The plant's graph on the canvas: every edit makes a new graph, which is an edit of the species, with its one undo step.
extension PlantEditorModel: GraphCanvasModel {
    /// The selected species' graph, every node with its place (the recipe's standard graph until it's edited; a built-in
    /// species' file, where it's at hand).
    var graph: PlantGraph {
        let d = def
        if let graph = d.graph { return PlantGraphLayout.laidOut(graph) }
        if builtInGraphs[d.id] == nil, let read = PlantPrograms.sourceGraph(d) { builtInGraphs[d.id] = read }
        if let read = builtInGraphs[d.id], d.sameRecipe(as: PlantCatalog.builtIn[species]) { return PlantGraphLayout.laidOut(read) }
        return PlantGraphLayout.laidOut(PlantGraph.standard(d))
    }

    /// `graph`, in the order it runs, as how the species grows.
    func setGraph(_ graph: PlantGraph) {
        var d = def
        d.setGraph(graph.ordered)
        def = d
    }

    func setSettings(_ id: Int32, _ settings: PlantNodeSettings) {
        var g = graph
        guard let i = g.nodes.firstIndex(where: { $0.id == id }), g.nodes[i].settings != settings else { return }
        g.nodes[i].settings = settings
        setGraph(g)
    }

    // MARK: - Nodes

    func addNode(_ kind: PlantNodeKind, at: SIMD2<Float>?) {
        var g = graph
        let id = g.nextID
        let from = selection.compactMap { Int32($0) }.first.flatMap(g.node)
        let onTwig = from?.side == .twig
        let preset: PlantPreset = onTwig && [.grow, .skeleton, .leaves].contains(kind) ? .twig : .standard
        var node = PlantNode(id: id, name: g.uniqueName(kind.rawValue), side: onTwig ? .twig : .plant, preset: preset,
                             settings: .new(kind, preset: preset), inputs: Array(repeating: -1, count: kind.pins.count))
        node.at = at ?? from.map { ($0.at ?? .zero) + [0, PlantGraphLayout.rowGap] } ?? graphPoint(hover)
        // Wired below the selected one, into the first pin that takes what it makes.
        if let from, let pin = kind.pins.firstIndex(where: { $0.type == .any || $0.type == g.output(of: from.id) }) {
            node.inputs[pin] = from.id
            if kind == .code { node.settings = .code(PlantCode(on: g.output(of: from.id))) }
        }
        g.nodes.append(node)
        setGraph(g)
        selection = ["\(id)"]
        focus = "\(id)"
        closeSearch()
    }

    /// Every node where the layout puts it.
    func layoutAll() {
        setGraph(PlantGraphLayout.laidOut(graph, all: true))
        frameAll(in: canvasSize)
    }

    /// A node (an error's): selected and in view.
    func show(_ node: Int32) {
        selection = ["\(node)"]
        focus = "\(node)"
    }

    // MARK: - The stage shown

    /// The node the workshop is to show the plant at: the pinned one, or else the one selected.
    var previewedID: Int32? { pinned ?? focus.flatMap { Int32($0) } }
    var previewed: PlantNode? { previewedID.flatMap(graph.node) }

    /// Why `node` has nothing to look at, if it hasn't.
    func stageProblem(_ node: Int32) -> String? { graph.stageProblem(node) }

    /// PlantSceneSettings.stage for that: all of the plant for its Output, or for a node with nothing to look at.
    var wantedStage: Int {
        let g = graph
        guard let node = previewed, node.id != g.end(of: .plant), g.stageProblem(node.id) == nil else { return -1 }
        return Int(node.id)
    }

    /// Pins the selected node, or lets go of the pin if that's the one pinned.
    func togglePin(_ id: Int32? = nil) {
        guard let id = id ?? focus.flatMap({ Int32($0) }) else { pinned = nil; return }
        pinned = pinned == id ? nil : id
    }

    /// Tells the workshop which stage to show, and frames it once it's in if it's on the other side from the last.
    func showStage() {
        if let pin = pinned, graph.node(pin) == nil { pinned = nil; return }
        guard controller.settings.scene.kind == .plants, controller.settings.scene.plants.species == selected else { return }
        let stage = wantedStage, was = controller.settings.scene.plants.stage
        guard stage != was else { return }
        let g = graph
        func onTwig(_ id: Int) -> Bool { id >= 0 && g.node(Int32(id))?.side == .twig }
        if onTwig(stage) != onTwig(was) { frameStage = stage }
        workshop { $0.stage = stage }
    }

    /// The nodes' thumbnails, for the species as it is now.
    func refreshThumbnails() {
        guard thumbnailsWanted else { return }
        let plants = controller.settings.scene.plants
        thumbnails.want(def, species: species, age: plants.age, variant: plants.variant, seed: UInt64(max(plants.seed, 0)))
    }

    // MARK: - GraphCanvasModel

    func click(_ id: String, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        focus = id
    }

    func clearSelection() {
        selection = []
        focus = nil
    }

    func selectAll() { selection = Set(graph.nodes.map { "\($0.id)" }) }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        var g = graph
        let gone = Set(selection.compactMap { Int32($0) })
        g.nodes.removeAll { gone.contains($0.id) }
        for i in g.nodes.indices { g.nodes[i].inputs = g.nodes[i].inputs.map { gone.contains($0) ? -1 : $0 } }
        setGraph(g)
        clearSelection()
    }

    /// What copying puts on the pasteboard.
    private struct Clip: Codable {
        var plantNodes: [PlantNode]
    }

    func copySelection() {
        let nodes = graph.nodes.filter { selection.contains("\($0.id)") }
        guard !nodes.isEmpty, let data = try? JSONEncoder().encode(Clip(plantNodes: nodes)) else { return }
        pasteboard.clearContents()
        pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    func paste() {
        guard let text = pasteboard.string(forType: .string), let clip = try? JSONDecoder().decode(Clip.self, from: Data(text.utf8)) else { return }
        var g = graph
        var map: [Int32: Int32] = [:]
        var added: Set<String> = []
        for node in clip.plantNodes {
            let id = g.nextID + Int32(map.count)
            map[node.id] = id
        }
        for var node in clip.plantNodes {
            node.id = map[node.id]!
            node.name = g.uniqueName(node.name)
            node.at = (node.at ?? .zero) + [30, 30]
            node.inputs = node.inputs.map { map[$0] ?? -1 }
            g.nodes.append(node)
            added.insert("\(node.id)")
        }
        setGraph(g)
        selection = added
        focus = added.count == 1 ? added.first : nil
    }

    func moveSelection(by delta: SIMD2<Float>, ids: Set<String>?) {
        var g = graph
        let moving = ids ?? selection
        for i in g.nodes.indices where moving.contains("\(g.nodes[i].id)") { g.nodes[i].at = (g.nodes[i].at ?? .zero) + delta }
        var d = def
        d.setGraph(g)
        def = d
    }

    func wire(into owner: String, _ input: String) -> (from: String, output: String)? {
        guard let id = Int32(owner), let i = Int(input), let n = graph.node(id), n.inputs.indices.contains(i), n.inputs[i] >= 0 else { return nil }
        return ("\(n.inputs[i])", "out")
    }

    /// Whether `from` can be wired into pin `input` of `to`: what it carries, not round in a circle, not across the twig
    /// and the plant but by the palette.
    func canLink(_ g: PlantGraph, from: Int32, to: Int32, input: Int) -> Bool {
        guard let n = g.node(to), n.kind.pins.indices.contains(input), from != to else { return false }
        let pin = n.kind.pins[input], carried = g.output(of: from)
        guard pin.type == .any || carried == .any || pin.type == carried else { return false }
        var stack = [from], seen = Set<Int32>()
        while let id = stack.popLast() {
            if id == to { return false }
            guard seen.insert(id).inserted, let a = g.node(id) else { continue }
            stack += a.inputs.filter { $0 >= 0 }
        }
        return true
    }

    @discardableResult
    func link(_ from: String, _ output: String, to: String, _ input: String) -> Bool {
        guard let a = Int32(from), let b = Int32(to), let i = Int(input) else { return false }
        var g = graph
        guard canLink(g, from: a, to: b, input: i), let n = g.nodes.firstIndex(where: { $0.id == b }) else { return false }
        g.nodes[n].inputs[i] = a
        setGraph(g)
        return true
    }

    func unlink(_ to: String, _ input: String) {
        guard let b = Int32(to), let i = Int(input) else { return }
        var g = graph
        guard let n = g.nodes.firstIndex(where: { $0.id == b }), g.nodes[n].inputs.indices.contains(i) else { return }
        g.nodes[n].inputs[i] = -1
        setGraph(g)
    }

    func openSearch() { searchAt = graphPoint(hover) }
    func closeSearch() { searchAt = nil; focusCanvas?() }

    func frameAll(in size: CGSize) { frame(PlantGraphLayout.bounds(graph), in: size) }

    // MARK: - Its Swift

    /// The file of the species as it is now.
    var swiftText: String {
        var d = def
        d.graph = graph
        return PlantSwift.emit(d).text
    }

    /// The species as it is now, compiled behind the workshop before long: the file written from its graph, and
    /// from then on what grows it.
    func compileLater() {
        compileSoon?.cancel()
        let d = def
        guard let graph = d.graph else {
            compile = PlantPrograms.compiled(PlantGraph.standard(d)) != nil || d.sameRecipe(as: isBuiltIn ? PlantCatalog.builtIn[species] : d) ? .idle : .waiting
            return
        }
        if let why = graph.wiring {
            compile = .incomplete(why)
            return
        }
        if PlantPrograms.compiled(graph) != nil {
            compile = .compiled(seconds: 0)
            return
        }
        compile = .waiting
        let work = DispatchWorkItem { [weak self] in self?.compileNow(d) }
        compileSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func compileNow(_ d: Foliage.SpeciesDef) {
        if let why = PlantCompiler.shared.problem() {
            compile = .failed([.init(message: why, node: nil)])
            return
        }
        compile = .compiling
        let emitted = PlantSwift.emit(d)
        PlantCompiler.shared.compileBehind(d, latest: true) { [weak self] result in
            let seconds = PlantCompiler.shared.lastCompileSeconds
            DispatchQueue.main.async {
                guard let self, self.def.graph?.key == d.graph?.key else { return }
                switch result {
                case .success:
                    self.compile = .compiled(seconds: seconds)
                    // What only its compiled file can run runs now.
                    if d.graph?.hasCode == true { self.push(final: true) }
                case .failure(.failed(let why)):
                    self.compile = .failed(why.split(separator: "\n").map { line in
                        let number = line.dropFirst(5).prefix { $0.isNumber }
                        return .init(message: String(line), node: Int(number).flatMap { emitted.lines[$0] })
                    })
                }
            }
        }
    }
}
