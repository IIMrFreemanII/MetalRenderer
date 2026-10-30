import EngineCore
import Foundation
import simd

/// A plant as a Swift file: `emit` writes a species as a program (PlantProgram) in the shape Programs/'s are, which
/// compiles as any Swift does; `parse` reads a file of that shape back as the species and its graph, so that the node
/// editor edits the file. What it doesn't understand stays as written: as a statement or a function, a node of its own.
package enum PlantSwift {
    package static let format = 3

    private static let headerLine = "// plant format \(format): written by the plant editor, which reads this file back as its graph."

    /// A type's name from a species' id.
    private static func typeName(_ id: String) -> String {
        let parts = id.split { !($0.isLetter || $0.isNumber) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let name = parts.joined()
        guard let first = name.first, first.isLetter else { return "Plant" + name }
        return name
    }

    /// The file of `def`, and the node (by id) each of its lines is of.
    package static func emit(_ def: Foliage.SpeciesDef) -> (text: String, lines: [Int: Int32]) {
        var out = ""
        var lineOf: [Int: Int32] = [:]
        var current = 0
        func add(_ text: String, node: Int32? = nil) {
            out += text + "\n"
            current += 1
            if let node { lineOf[current] = node }
        }
        let graph = def.grownGraph.ordered
        let source = graph.source ?? PlantGraph.Source()
        if source.header.isEmpty && source.declaration.isEmpty {
            add(headerLine)
            add("import Plants")
            add("")
        } else {
            for line in source.header.split(separator: "\n", omittingEmptySubsequences: false).dropLast() { add(String(line)) }
        }
        add(source.declaration.isEmpty ? "package enum \(typeName(def.id)): PlantProgram {" : source.declaration)

        /// The body of a `{ $0.x = 1 }`: nothing (no closure), on one line, or a line each.
        func closure(_ opening: String, plain: String, _ value: Any, from base: Any, notes: PlantNotes, indent: String, node: Int32?) {
            let lines = PlantLiteral.lines(value, from: base)
            if lines.isEmpty { add(indent + plain, node: node); return }
            if lines.count == 1, notes.above[lines[0].path] == nil, notes.trailing[lines[0].path] == nil {
                add(indent + opening + " { $0.\(lines[0].written) = \(lines[0].literal) }", node: node)
                return
            }
            add(indent + opening + " {", node: node)
            for line in lines {
                for comment in notes.above[line.path] ?? [] { add(indent + "    " + comment, node: node) }
                let trailing = notes.trailing[line.path].map { " " + $0 } ?? ""
                add(indent + "    $0.\(line.written) = \(line.literal)" + trailing, node: node)
            }
            add(indent + "}", node: node)
        }

        // The species.
        for line in source.speciesDoc { add("    " + line) }
        let species = "package static let species = Foliage.SpeciesInfo(id: \(PlantLiteral.atom(def.id)!))"
        closure(species, plain: species, def.info, from: Foliage.SpeciesInfo(id: def.id), notes: source.speciesNotes, indent: "    ", node: nil)

        // The palette and the twig.
        let palette = graph.nodes.first { $0.kind == .palette }
        if let palette, case .palette(let settings) = palette.settings {
            add("")
            for line in source.paletteDoc { add("    " + line) }
            if let at = palette.at { add("    // @node (\(PlantLiteral.float(at.x)), \(PlantLiteral.float(at.y)))", node: palette.id) }
            let opening = "package static let palette: Foliage.Palette? = Foliage.Palette"
            closure(opening, plain: opening + "()", settings, from: Foliage.Palette(), notes: palette.notes, indent: "    ", node: palette.id)
        }

        /// One side's function: its nodes in order, then what it returns.
        func function(_ signature: String, doc: [String], side: PlantSide, result: Int32?) {
            add("")
            for line in doc { add("    " + line) }
            add("    " + signature + " {")
            for node in graph.nodes where node.side == side && node.kind != .palette { statement(node) }
            if let result, let name = graph.node(result)?.name { add("        return \(name)") }
            add("    }")
        }

        func statement(_ node: PlantNode) {
            let indent = "        "
            for line in node.doc { add(indent + line, node: node.id) }
            if let at = node.at { add(indent + "// @node (\(PlantLiteral.float(at.x)), \(PlantLiteral.float(at.y)))", node: node.id) }
            let name = { (id: Int32) in graph.node(id)?.name ?? "_" }
            let i = node.inputs
            let opening = "let \(node.name) = p."
            let preset = node.preset == .twig ? ".twig" : ""
            func call(_ stage: String, _ args: [String], _ value: Any, _ base: Any) {
                let list = args.joined(separator: ", ")
                closure(opening + stage + (list.isEmpty ? "" : "(\(list))"), plain: opening + stage + "(\(list))", value, from: base,
                        notes: node.notes, indent: indent, node: node.id)
            }
            switch node.settings {
            case .grow(let s):
                let base = node.preset == .twig ? Growth.Twigs.twigGrowth : Growth.Params()
                call("grow", preset.isEmpty ? [] : [preset], s, base)
            case .growMore(let s): call("growMore", [name(i[0])], s, Growth.GrowMore())
            case .grafts(let s): call("grafts", [name(i[0])], s, Growth.Grafts())
            case .spurs(let s): call("spurs", [name(i[0])], s, Growth.Spurs())
            case .carve(let s): call("carve", [name(i[0])], s, Growth.Carve())
            case .skeleton(let s):
                let base = node.preset == .twig ? Growth.Twigs.twigGrowth.wood : Growth.Wood()
                call("skeleton", [name(i[0])] + (preset.isEmpty ? [] : [preset]), s, base)
            case .leaves(let s):
                let base = node.preset == .twig ? Growth.Twigs().leaf : Foliage.LeafRecipe()
                call("leaves", [name(i[0])] + (preset.isEmpty ? [] : [preset]), s, base)
            case .twig:
                add(indent + opening + "twig(\(name(i[0])), leaves: \(name(i[1])))", node: node.id)
            case .distribute(let s):
                call("distribute", [name(i[0]), "palette: p.palette"], s, Growth.Twigs())
            case .output(let s):
                var args = [name(i[0])]
                if i.count > 1, i[1] >= 0 { args.append("twigs: \(name(i[1]))") }
                if i.count > 2, i[2] >= 0 { args.append("leaves: \(name(i[2]))") }
                call("output", args, s, Foliage.Assembly())
            case .grass(let s): call("grass", [], s, Foliage.GrassPatch())
            case .code: add(indent + opening + "code(\(node.name), \(name(i.first ?? -1)))", node: node.id)
            case .statement(let text):
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) { add(indent + line, node: node.id) }
            case .palette: break
            }
        }

        if palette != nil {
            function("package static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh>", doc: source.twigDoc, side: .twig, result: graph.end(of: .twig))
        }
        function("package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant>", doc: source.plantDoc, side: .plant, result: graph.end(of: .plant))

        // Code nodes' functions, and the table that runs them while the graph is what's run.
        let code = graph.nodes.compactMap { n -> (PlantNode, PlantCode)? in
            if case .code(let c) = n.settings { return (n, c) }
            return nil
        }
        for (node, c) in code {
            add("")
            for line in node.doc { add("    " + line, node: node.id) }
            if let at = node.at { add("    // @node (\(PlantLiteral.float(at.x)), \(PlantLiteral.float(at.y)))", node: node.id) }
            let text = c.text.replacing(#/func\s+[A-Za-z_][A-Za-z_0-9]*/#, with: "func \(node.name)", maxReplacements: 1)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { add("    " + line, node: node.id) }
        }
        if !code.isEmpty {
            add("")
            add("    package static let code = [" + code.map { "PlantCodeEntry(\(PlantLiteral.atom($0.1.hash)!), \($0.0.name))" }.joined(separator: ", ") + "]")
        }
        for extra in source.extras {
            add("")
            for line in extra.split(separator: "\n", omittingEmptySubsequences: false) { add(String(line)) }
        }
        add("}")
        if !source.footer.isEmpty { out += source.footer }
        return (out, lineOf)
    }

    /// `def`, read from the file `source`. nil: it has no program in it.
    package static func parse(_ source: String, id: String = "plant") -> Foliage.SpeciesDef? {
        var parser = PlantSwiftParser(source)
        guard let (info, graph) = parser.program(fallbackID: id) else { return nil }
        var def = Foliage.SpeciesDef(info, graph: graph)
        def.graph = graph
        return def
    }
}
