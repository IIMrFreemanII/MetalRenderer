import EngineCore
import Foundation
import Plants
import simd

// MARK: - The graph's edits and checks (the VFX editor's, the benchmarks')

extension VFXEffect {
    /// Every emitter's, block's and node's id.
    package var allIDs: Set<String> {
        var ids = Set(nodes.map(\.id))
        for e in emitters {
            ids.insert(e.id)
            for c in VFXContext.allCases { for b in e[c] { ids.insert(b.id) } }
        }
        return ids
    }

    /// The emitters, blocks and nodes of `ids` gone, and the wires to and from them.
    package mutating func remove(_ ids: Set<String>) {
        var gone = ids
        for e in emitters where ids.contains(e.id) {
            for c in VFXContext.allCases { for b in e[c] { gone.insert(b.id) } }
        }
        emitters.removeAll { ids.contains($0.id) }
        for i in emitters.indices { for c in VFXContext.allCases { emitters[i][c].removeAll { gone.contains($0.id) } } }
        nodes.removeAll { gone.contains($0.id) }
        links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
    }

    package mutating func setParam(_ owner: String, _ name: String, _ value: VFXParam) {
        if let k = nodes.firstIndex(where: { $0.id == owner }) {
            nodes[k].params[name] = value
            return
        }
        for e in emitters.indices {
            for c in VFXContext.allCases {
                if let k = emitters[e][c].firstIndex(where: { $0.id == owner }) { emitters[e][c][k].params[name] = value; return }
            }
        }
    }

    package mutating func setEnabled(_ block: String, _ on: Bool) {
        for e in emitters.indices {
            for c in VFXContext.allCases {
                if let k = emitters[e][c].firstIndex(where: { $0.id == block }) { emitters[e][c][k].enabled = on; return }
            }
        }
    }

    /// The pin spec of input `input` of node or block `id`.
    package func pin(_ id: String, _ input: String) -> VFXPinSpec? {
        if let n = node(id) { return n.kind.spec.pin(input) }
        return block(id)?.block.kind.spec.pin(input)
    }

    /// What node `id`'s output `output` carries: its kind's, or its generic inputs' widest (what is wired into them,
    /// else their values').
    package func outputType(_ id: String, _ output: String = "out", seen: Set<String> = []) -> VFXType {
        guard let n = node(id), !seen.contains(id) else { return .float }
        let spec = n.kind.spec
        if let t = spec.outputs.first(where: { $0.name == output })?.type { return t }
        var t = VFXType.bool
        for p in spec.inputs where p.generic { t = VFXType.wider(t, inputType(id, p.name, seen: seen.union([id]))) }
        return t == .bool ? .float : t
    }

    /// What input `input` of node or block `id` gets: what is wired into it, else its value's type.
    package func inputType(_ id: String, _ input: String, seen: Set<String> = []) -> VFXType {
        if let l = link(into: id, input) { return outputType(l.from, l.output, seen: seen) }
        guard let p = pin(id, input) else { return .float }
        let value = node(id)?.param(input) ?? block(id)?.block.param(input) ?? p.value
        switch value {
        case .vec3: return .vec3
        case .color, .gradient: return .color
        case .bool: return .bool
        default: return p.generic ? .float : (p.wire ?? .float)
        }
    }

    /// The pin's type as drawn: a generic one's is what it gets.
    package func pinType(_ id: String, _ input: String) -> VFXType {
        guard let p = pin(id, input) else { return .float }
        return p.generic ? inputType(id, input) : (p.wire ?? inputType(id, input))
    }

    /// Whether node `from`'s output can be wired into `to`'s input: the input takes a wire, the output is the node's,
    /// and `to` isn't upstream of `from` (no loop).
    package func canLink(_ from: String, _ output: String, to: String, _ input: String) -> Bool {
        guard from != to, let n = node(from), n.kind.spec.outputs.contains(where: { $0.name == output }),
              pin(to, input)?.wire != nil else { return false }
        guard node(to) != nil else { return true }   // a block: nothing comes out of it
        return !upstream(of: from).contains(to)
    }

    /// The nodes whose outputs reach node `id` (through any number of wires).
    package func upstream(of id: String) -> Set<String> {
        var found = Set<String>(), stack = [id]
        while let n = stack.popLast() {
            for l in links where l.to == n && !found.contains(l.from) {
                found.insert(l.from)
                stack.append(l.from)
            }
        }
        return found
    }
}
