import EngineCore
import Foundation
import simd

/// A program as data: its stages in the order they are called and what is wired into each, which the node editor edits
/// and PlantSwift writes as Swift and reads back. A species' recipe (SpeciesDef's growth, twigs, leaf) is this graph's
/// standard shape (`standard`).
package struct PlantGraph: Codable, Equatable {
    package var nodes: [PlantNode] = []
    /// What the file it came from says besides its nodes.
    package var source: Source? = nil

    /// The comments and the rest of a program's file, kept so that the file comes back as it was.
    package struct Source: Codable, Equatable {
        package var header = ""                     // all before the type's declaration
        package var declaration = ""                // its line, to the brace
        package var speciesDoc: [String] = []
        package var speciesNotes = PlantNotes()
        package var paletteDoc: [String] = []
        package var paletteNotes = PlantNotes()
        package var twigDoc: [String] = []
        package var plantDoc: [String] = []
        package var extras: [String] = []           // members that aren't the program's own, as they are written
        package var footer = ""                     // all after the type

        package init() {}
    }

    package init(nodes: [PlantNode] = []) { self.nodes = nodes }

    package func node(_ id: Int32) -> PlantNode? { nodes.first { $0.id == id } }
    package func first(_ kind: PlantNodeKind, _ side: PlantSide) -> PlantNode? { nodes.first { $0.kind == kind && $0.side == side } }
    package var nextID: Int32 { (nodes.map(\.id).max() ?? -1) + 1 }

    /// A name no other node has, in the file's code.
    package func uniqueName(_ wanted: String, except id: Int32? = nil) -> String {
        var name = wanted, n = 2
        while nodes.contains(where: { $0.name == name && $0.id != id }) || name == "p" {
            name = "\(wanted)\(n)"
            n += 1
        }
        return name
    }
}

package enum PlantSide: String, Codable { case twig, plant }

package enum PlantNodeKind: String, Codable, CaseIterable {
    case grow, growMore, grafts, spurs, carve, skeleton, leaves, twig, palette, distribute, output, grass, code, statement

    /// What's added by the editor's menus (a statement only comes from a file).
    package static let adding: [PlantNodeKind] = [.grow, .growMore, .grafts, .spurs, .carve, .skeleton, .leaves, .twig, .palette, .distribute, .output, .grass, .code]

    package var title: String {
        switch self {
        case .grow: return "Grower"
        case .growMore: return "Grow More"
        case .grafts: return "Graft Distributor"
        case .spurs: return "Spurs"
        case .carve: return "Carve"
        case .skeleton: return "Mesh Builder"
        case .leaves: return "Leaves"
        case .twig: return "Twig"
        case .palette: return "Twig Palette"
        case .distribute: return "Foliage Distributor"
        case .output: return "Output"
        case .grass: return "Grass Patch"
        case .code: return "Swift Code"
        case .statement: return "Swift Statement"
        }
    }

    /// What a node of it is called in its file (`twig`: on the twig's side).
    func name(side: PlantSide) -> String {
        let base: String
        switch self {
        case .skeleton: base = "wood"
        case .distribute: base = "twigs"
        default: base = rawValue
        }
        guard side == .twig, self != .twig, self != .palette else { return base }
        return "twig" + base.prefix(1).uppercased() + base.dropFirst()
    }

    /// Its input pins.
    package var pins: [PlantPin] {
        switch self {
        case .grow, .grass, .statement: return []
        case .growMore, .grafts, .spurs, .carve, .skeleton: return [PlantPin("In", .growing)]
        case .leaves: return [PlantPin("Stems", .skeleton)]
        case .twig: return [PlantPin("Stems", .skeleton), PlantPin("Leaves", .leaves)]
        case .palette: return [PlantPin("Twig", .twigMesh)]
        case .distribute: return [PlantPin("Stems", .skeleton), PlantPin("Palette", .palette)]
        case .output: return [PlantPin("Wood", .skeleton), PlantPin("Twigs", .twigs, optional: true), PlantPin("Leaves", .leaves, optional: true)]
        case .code: return [PlantPin("In", .any)]
        }
    }

    /// What its output carries (.any: a code node's is what's wired into it).
    package var output: PlantWire {
        switch self {
        case .grow, .growMore, .grafts, .spurs, .carve: return .growing
        case .skeleton: return .skeleton
        case .leaves: return .leaves
        case .twig: return .twigMesh
        case .palette: return .palette
        case .distribute: return .twigs
        case .output, .grass: return .plant
        case .code, .statement: return .any
        }
    }
}

/// What a wire carries.
package enum PlantWire: String, Codable {
    case growing, skeleton, leaves, twigMesh, palette, twigs, plant, any

    /// The type on the wire, in a program's Swift. (`any`: nothing says yet; a stem is the likeliest.)
    var swiftType: String {
        switch self {
        case .growing: return "Growing"
        case .skeleton, .any: return "PlantSkeleton"
        case .leaves: return "LeafSet"
        case .twigMesh: return "Foliage.Mesh"
        case .palette: return "TwigPalette"
        case .twigs: return "TwigPlacement"
        case .plant: return "Foliage.Plant"
        }
    }
}

package struct PlantPin: Equatable {
    package let name: String
    package let type: PlantWire
    package let optional: Bool

    init(_ name: String, _ type: PlantWire, optional: Bool = false) {
        self.name = name
        self.type = type
        self.optional = optional
    }
}

/// A Swift Code node's function, in its file: `static func name(_ p: inout PlantContext, _ input: T) -> T { ... }`.
package struct PlantCode: Codable, Equatable {
    package var text: String

    package init(text: String) { self.text = text }

    /// A function that hands on what's on its wire: a new node's.
    package init(on wire: PlantWire) {
        let type = wire.swiftType
        text = "static func code(_ p: inout PlantContext, _ input: \(type)) -> \(type) {\n    input\n}"
    }

    /// What names the text, whatever else the file holds: a compiled function runs as long as this is the same.
    package var hash: String { PlantCompiler.hash(text) }
}

/// A Grow More node's settings: the plant goes on growing (Unreal's second Grower, after the graft distributor).
extension Growth {
    package struct GrowMore: Codable, Equatable {
        package var cycles = 3
        package var revive = true                   // the grafts and spurs, set as they are, grow too

        package init() {}
    }
}

package enum PlantNodeSettings: Codable, Equatable {
    case grow(Growth.Params)
    case growMore(Growth.GrowMore)
    case grafts(Growth.Grafts)
    case spurs(Growth.Spurs)
    case carve(Growth.Carve)
    case skeleton(Growth.Wood)
    case leaves(Foliage.LeafRecipe)
    case twig
    case palette(Foliage.Palette)
    case distribute(Growth.Twigs)
    case output(Foliage.Assembly)
    case grass(Foliage.GrassPatch)
    case code(PlantCode)
    case statement(String)

    package var kind: PlantNodeKind {
        switch self {
        case .grow: return .grow
        case .growMore: return .growMore
        case .grafts: return .grafts
        case .spurs: return .spurs
        case .carve: return .carve
        case .skeleton: return .skeleton
        case .leaves: return .leaves
        case .twig: return .twig
        case .palette: return .palette
        case .distribute: return .distribute
        case .output: return .output
        case .grass: return .grass
        case .code: return .code
        case .statement: return .statement
        }
    }

    /// A new node's.
    package static func new(_ kind: PlantNodeKind, preset: PlantPreset) -> PlantNodeSettings {
        switch kind {
        case .grow: return .grow(preset == .twig ? Growth.Twigs.twigGrowth : Growth.Params())
        case .growMore: return .growMore(Growth.GrowMore())
        case .grafts: return .grafts(Growth.Grafts())
        case .spurs: return .spurs(Growth.Spurs())
        case .carve: return .carve(Growth.Carve())
        case .skeleton: return .skeleton(preset == .twig ? Growth.Twigs.twigGrowth.wood : Growth.Wood())
        case .leaves: return .leaves(preset == .twig ? Growth.Twigs().leaf : Foliage.LeafRecipe())
        case .twig: return .twig
        case .palette: return .palette(Foliage.Palette())
        case .distribute: return .distribute(Growth.Twigs())
        case .output: return .output(Foliage.Assembly())
        case .grass: return .grass(Foliage.GrassPatch())
        case .code: return .code(PlantCode(on: .any))
        case .statement: return .statement("")
        }
    }
}

/// The comments on a settings closure's lines, by the line's path ("trunk.segment").
package struct PlantNotes: Codable, Equatable {
    package var above: [String: [String]] = [:]
    package var trailing: [String: String] = [:]

    package init() {}
}

package struct PlantNode: Codable, Equatable {
    package var id: Int32
    package var name: String                        // its `let`, in the file
    package var side: PlantSide
    package var preset: PlantPreset
    package var settings: PlantNodeSettings
    /// By pin, a node's id (-1: nothing wired in).
    package var inputs: [Int32]
    package var at: SIMD2<Float>? = nil             // nil: where the editor lays it out
    package var doc: [String] = []                  // the comment lines over it, in the file
    package var notes = PlantNotes()

    package var kind: PlantNodeKind { settings.kind }
    package var isStatement: Bool { if case .statement = settings { return true }; return false }

    package init(id: Int32, name: String, side: PlantSide, preset: PlantPreset, settings: PlantNodeSettings, inputs: [Int32]) {
        self.id = id
        self.name = name
        self.side = side
        self.preset = preset
        self.settings = settings
        self.inputs = inputs
    }
}

// MARK: - Whether it can run

extension PlantGraph {
    /// What's wired out of `id`.
    package func output(of id: Int32) -> PlantWire {
        guard let n = node(id) else { return .any }
        if n.kind == .code, let from = n.inputs.first { return output(of: from) }
        return n.kind.output
    }

    /// Why the graph can't be run stage by stage, if it can't: a statement only its compiled file can run, or `wiring`.
    package var problem: String? {
        if let n = nodes.first(where: \.isStatement) { return "\(n.name.isEmpty ? "A statement" : n.name) runs only when its file is compiled" }
        return wiring
    }

    /// Why the graph has no file that compiles, if it hasn't: a pin not wired, or wired wrongly. (A statement is its
    /// file's as written, and what it declares is only the compiler's to judge: an Output is asked for only without one.)
    package var wiring: String? {
        var seen = Set<Int32>()
        for n in nodes {
            defer { seen.insert(n.id) }
            if let why = pinProblem(n, seen: seen) { return why }
        }
        for n in nodes where n.kind != .distribute {
            if n.inputs.contains(where: { node($0).map { $0.side != n.side } ?? false }) { return "\(n.kind.title) \(n.name) is wired across the twig and the plant" }
        }
        if nodes.contains(where: \.isStatement) { return nil }
        let ends = nodes.filter { $0.side == .plant && ($0.kind == .output || $0.kind == .grass) }
        if ends.count != 1 { return ends.isEmpty ? "There's no Output" : "There's more than one Output" }
        return nil
    }

    /// What's wrong with what's wired into `n`, if anything is (`seen`: what may come before it).
    func pinProblem(_ n: PlantNode, seen: Set<Int32>? = nil) -> String? {
        for (pin, id) in zip(n.kind.pins, n.inputs + Array(repeating: -1, count: max(0, n.kind.pins.count - n.inputs.count))) {
            if id < 0 {
                if !pin.optional { return "\(n.kind.title) \(n.name): nothing is wired into \(pin.name)" }
                continue
            }
            if let seen, !seen.contains(id) { return "\(n.kind.title) \(n.name): its \(pin.name) comes after it, or from nothing" }
            let wire = output(of: id)
            if pin.type != .any && wire != .any && wire != pin.type {
                return "\(n.kind.title) \(n.name): \(pin.name) doesn't take what's wired into it"
            }
        }
        return nil
    }

    package var hasCode: Bool {
        nodes.contains { if case .code = $0.settings { return true }; return $0.isStatement }
    }

    /// In the order they can run, the order they had wherever that does, and each on its side: upstream of the palette
    /// is the twig's.
    package var ordered: PlantGraph {
        var out = self
        var placed = Set<Int32>(), sorted: [PlantNode] = []
        var left = nodes
        while !left.isEmpty {
            guard let i = left.firstIndex(where: { n in n.inputs.allSatisfy { $0 < 0 || placed.contains($0) || node($0) == nil } }) else {
                sorted += left     // (a cycle: left to `problem`)
                break
            }
            placed.insert(left[i].id)
            sorted.append(left.remove(at: i))
        }
        out.nodes = sorted
        var twig = Set<Int32>()
        var stack = nodes.filter { $0.kind == .palette }.map(\.id)
        while let id = stack.popLast() {
            guard twig.insert(id).inserted, let n = node(id) else { continue }
            stack += n.inputs.filter { $0 >= 0 }
        }
        for i in out.nodes.indices { out.nodes[i].side = twig.contains(out.nodes[i].id) ? .twig : .plant }
        return out
    }
}

// MARK: - Running one

extension PlantGraph {
    /// What a side's function returns: the plant's Output, the wire into the palette. (Not the last node: one can hang off
    /// the chain, wired to nothing, after them.)
    package func end(of side: PlantSide) -> Int32? {
        switch side {
        case .plant: return nodes.last { $0.side == .plant && ($0.kind == .output || $0.kind == .grass) }?.id
        case .twig:
            if let wired = nodes.first(where: { $0.kind == .palette })?.inputs.first, wired >= 0 { return wired }
            return nodes.last { $0.side == .twig && $0.kind == .twig }?.id
        }
    }

    /// One run of the graph's side, calling the stages as a program's code would (the same draws in the same order).
    private func run(_ side: PlantSide, _ p: inout PlantContext) -> Int32 {
        let ran = stages(side, &p)
        return end(of: side).flatMap { ran.wire[$0] } ?? ran.last
    }

    /// The stages of a side, in order: which of the context's values each node's output is, and the last one.
    /// `partial` (a graph looked at before it's whole): only what can run runs, and only as far as `until`. `each` sees
    /// every stage that ran, with the wires so far.
    func stages(_ side: PlantSide, _ p: inout PlantContext, partial: Bool = false, until: Int32? = nil,
                each: (PlantNode, [Int32: Int32], inout PlantContext) -> Void = { _, _, _ in }) -> (wire: [Int32: Int32], last: Int32) {
        var wire: [Int32: Int32] = [:]
        var last: Int32 = -1
        func w<T>(_ id: Int32) -> Wire<T> { Wire(node: wire[id] ?? -1) }
        func optional<T>(_ id: Int32) -> Wire<T>? { id >= 0 ? w(id) : nil }
        for node in nodes where node.side == side {
            if partial {
                guard pinProblem(node) == nil, zip(node.kind.pins, node.inputs).allSatisfy({ $0.type == .palette || $1 < 0 || wire[$1] != nil }) else { continue }
            }
            var out: Int32 = -1
            let i = node.inputs
            switch node.settings {
            case .grow(let s): out = p.grow(settings: s, preset: node.preset).node
            case .growMore(let s): out = p.growMore(w(i[0]), settings: s).node
            case .grafts(let s): out = p.grafts(w(i[0]), settings: s).node
            case .spurs(let s): out = p.spurs(w(i[0]), settings: s).node
            case .carve(let s): out = p.carve(w(i[0]), settings: s).node
            case .skeleton(let s): out = p.skeleton(w(i[0]), settings: s, preset: node.preset).node
            case .leaves(let s): out = p.leaves(w(i[0]), settings: s, preset: node.preset).node
            case .twig: out = p.twig(w(i[0]), leaves: w(i[1])).node
            case .palette, .statement: continue
            case .distribute(let s): out = p.distribute(w(i[0]), palette: p.palette, settings: s).node
            case .output(let s): out = p.output(w(i[0]), twigs: optional(i[1]), leaves: optional(i[2]), settings: s).node
            case .grass(let s): out = p.grass(settings: s).node
            case .code(let c): out = p.code(c.hash, input: wire[i[0]] ?? -1)
            }
            wire[node.id] = out
            last = out
            each(node, wire, &p)
            if node.id == until { break }
        }
        return (wire, last)
    }

    package func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        guard nodes.contains(where: { $0.side == .twig }) else { return p.noTwig() }
        return Wire(node: run(.twig, &p))
    }

    package func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> { Wire(node: run(.plant, &p)) }
}

// MARK: - As a recipe

extension PlantGraph {
    private mutating func add(_ side: PlantSide, _ settings: PlantNodeSettings, _ preset: PlantPreset = .standard, _ inputs: [Int32] = []) -> Int32 {
        let id = nextID
        nodes.append(PlantNode(id: id, name: uniqueName(settings.kind.name(side: side)), side: side, preset: preset, settings: settings, inputs: inputs))
        return id
    }

    /// The chain of stages from the seed to the skeleton that `p` holds.
    private mutating func chain(_ side: PlantSide, _ p: Growth.Params, _ preset: PlantPreset) -> Int32 {
        var at = add(side, .grow(p.growOnly(preset)), preset)
        if let g = p.grafts { at = add(side, .grafts(g), .standard, [at]) }
        if let s = p.spurs { at = add(side, .spurs(s), .standard, [at]) }
        if let c = p.carve {
            var carve = Growth.Carve()
            carve.share = c
            at = add(side, .carve(carve), .standard, [at])
        }
        return add(side, .skeleton(p.wood), preset, [at])
    }

    /// The twig side of `t`, ending in its palette; the palette's node.
    private mutating func addTwigSide(_ t: Growth.Twigs) -> Int32 {
        let wood = chain(.twig, t.growth, .twig)
        let leaf = add(.twig, .leaves(t.leaf), .twig, [wood])
        let twig = add(.twig, .twig, .standard, [wood, leaf])
        var palette = Foliage.Palette()
        palette.count = t.palette
        palette.sparse = t.sparse
        return add(.twig, .palette(palette), .standard, [twig])
    }

    /// `t` as a graph of its twig side only.
    package static func twigs(_ t: Growth.Twigs) -> PlantGraph {
        var g = PlantGraph()
        _ = g.addTwigSide(t)
        return g
    }

    /// The recipe's standard shape: the stages it has, in order.
    package static func standard(_ def: Foliage.SpeciesDef) -> PlantGraph {
        var g = PlantGraph()
        if let grass = def.grass {
            _ = g.add(.plant, .grass(grass))
            return g
        }
        let palette = def.twigs.map { g.addTwigSide($0) }
        let wood = g.chain(.plant, def.growth ?? Growth.Params(), .standard)
        var twigs: Int32 = -1, leaves: Int32 = -1
        if let t = def.twigs, let palette { twigs = g.add(.plant, .distribute(t.placingOnly), .standard, [wood, palette]) }
        if let leaf = def.leaf { leaves = g.add(.plant, .leaves(leaf), .standard, [wood]) }
        var assembly = Foliage.Assembly()
        assembly.stemsAreLeaves = def.stemsAreLeaves
        _ = g.add(.plant, .output(assembly), .standard, [wood, twigs, leaves])
        return g
    }

    /// The Params that the chain of stages on `side` holds.
    private func params(_ side: PlantSide) -> Growth.Params? {
        guard let grow = first(.grow, side), case .grow(var p) = grow.settings else { return nil }
        if case .grafts(let s)? = first(.grafts, side)?.settings { p.grafts = s }
        if case .spurs(let s)? = first(.spurs, side)?.settings { p.spurs = s }
        if case .carve(let s)? = first(.carve, side)?.settings { p.carve = s.share }
        if case .skeleton(let s)? = first(.skeleton, side)?.settings { p.wood = s }
        return p
    }

    /// What the recipe's fields say of the graph. All of it if the graph is `isStandard`; otherwise the stages the
    /// recipe has room for, what the scenes ask of a species (how many twigs, which leaf sheet).
    package func project(into def: inout Foliage.SpeciesDef) {
        def.grass = nil
        def.growth = nil
        def.twigs = nil
        def.leaf = nil
        def.stemsAreLeaves = false
        if case .grass(let s)? = first(.grass, .plant)?.settings { def.grass = s }
        def.growth = params(.plant)
        if case .distribute(var t)? = first(.distribute, .plant)?.settings {
            if let p = params(.twig) { t.growth = p }
            if case .leaves(let leaf)? = first(.leaves, .twig)?.settings { t.leaf = leaf }
            if case .palette(let palette)? = first(.palette, .twig)?.settings {
                t.palette = palette.count
                t.sparse = palette.sparse
            }
            def.twigs = t
        }
        if case .leaves(let leaf)? = first(.leaves, .plant)?.settings { def.leaf = leaf }
        if case .output(let a)? = first(.output, .plant)?.settings { def.stemsAreLeaves = a.stemsAreLeaves }
    }

    /// The graph with `def`'s recipe in it, whose nodes keep their places and notes: an edit made to the recipe (Mutate,
    /// a section pasted). A graph of the same stages is that recipe's standard graph; another keeps its shape, the
    /// recipe going to the stages it has room for.
    package func applying(_ def: Foliage.SpeciesDef) -> PlantGraph {
        let made = PlantGraph.standard(def)
        if made.nodes.map(\.kind) == nodes.map(\.kind) && isStandard {
            var out = self
            for i in out.nodes.indices { out.nodes[i].settings = made.nodes[i].settings }
            return out
        }
        if isStandard {
            var out = made
            out.source = source
            for i in out.nodes.indices {
                guard let old = nodes.first(where: { $0.kind == out.nodes[i].kind && $0.side == out.nodes[i].side }) else { continue }
                out.nodes[i].at = old.at
                out.nodes[i].doc = old.doc
                out.nodes[i].notes = old.notes
            }
            return out
        }
        var out = self
        for i in out.nodes.indices {
            guard let same = made.first(out.nodes[i].kind, out.nodes[i].side), first(out.nodes[i].kind, out.nodes[i].side)?.id == out.nodes[i].id else { continue }
            out.nodes[i].settings = same.settings
        }
        return out
    }

    /// What names the graph as what it grows (a compiled program's key).
    package var key: String {
        var hasher = GeneratedCache.Hasher()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        hasher.add((try? encoder.encode(canonical)).map { [UInt8]($0) } ?? [])
        (source?.extras ?? []).forEach { hasher.add($0) }
        return String(hasher.name().prefix(16))
    }

    /// The graph with what doesn't change the plant taken out, its nodes numbered in order.
    package var canonical: PlantGraph {
        var out = self
        out.source = nil
        var number: [Int32: Int32] = [:]
        for (i, node) in nodes.enumerated() { number[node.id] = Int32(i) }
        for i in out.nodes.indices {
            out.nodes[i].id = Int32(i)
            out.nodes[i].name = ""
            out.nodes[i].preset = .standard
            out.nodes[i].at = nil
            out.nodes[i].doc = []
            out.nodes[i].notes = PlantNotes()
            out.nodes[i].inputs = out.nodes[i].inputs.map { number[$0] ?? -1 }
        }
        return out
    }

    /// Whether its recipe says all of it.
    package var isStandard: Bool {
        var def = Foliage.SpeciesDef(id: "", name: "", seedIndex: 0, role: .tree, look: Foliage.Look())
        project(into: &def)
        return PlantGraph.standard(def).canonical == canonical
    }
}

extension Foliage.SpeciesDef {
    /// A species from what its program says of it and its graph.
    package init(_ info: Foliage.SpeciesInfo, graph: PlantGraph) {
        self.init(id: info.id, name: info.name, seedIndex: info.seedIndex, role: info.role, ages: info.ages, look: info.look,
                  habitat: info.habitat, basedOn: info.basedOn)
        graph.project(into: &self)
    }

    /// What it says of itself apart from how it grows.
    package var info: Foliage.SpeciesInfo {
        Foliage.SpeciesInfo(id: id) {
            $0.name = name
            $0.seedIndex = seedIndex
            $0.role = role
            $0.ages = ages
            $0.look = look
            $0.habitat = habitat
            $0.basedOn = basedOn
        }
    }

    /// The graph that grows it.
    package var grownGraph: PlantGraph { graph ?? PlantGraph.standard(self) }

    /// `graph` as how it grows, its recipe said by it.
    package mutating func setGraph(_ graph: PlantGraph) {
        self.graph = graph
        graph.project(into: &self)
    }

    /// What decides its plants, which the catalog's fingerprint names: moving a node doesn't, nor being compiled, unless
    /// that's what makes its code run.
    var fingerprintForm: Foliage.SpeciesDef {
        var d = self
        guard let graph else { return d }
        if graph.isStandard {
            d.graph = nil
        } else {
            d.graph = graph.canonical
            // (A statement doesn't run until then.)
            if graph.hasCode, PlantPrograms.compiled(graph) != nil { d.basedOn = (basedOn ?? "") + " compiled" }
        }
        return d
    }
}
