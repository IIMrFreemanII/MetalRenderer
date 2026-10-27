import Foundation
import MetalRenderer
import Modeling
import Procedural
import simd

/// The scripted Modeller's steps for the Procedural workspace (ModellerStep, ScriptModeller), by node name:
///
///   {"network": "new" | "object" | "bake" | "layout"}   a network on the active object, a procedural object, the
///                                                      network baked away, the nodes laid out
///   {"node": {"add": "polyextrude", "name": "push", "after": "box1", "at": [x, y]}}   a node (wired below `after`,
///                                                      or the selected one, and displayed); {"node": {"remove": "push"}};
///                                                      {"node": {"select": "push"}}
///   {"parm": {"node": "box1", "name": "size", "value": [2, 1, 1]}}   a parameter (numbers, [x, y(, z(, w))],
///                                                      true/false, strings, [[x, y, z], …] for points)
///   {"wire": {"from": "box1", "to": "merge1", "input": 1}}   a wire ({"unwire": {"to": …, "input": …}} takes one off)
///   {"flag": {"node": "box1", "display": true, "template": true, "bypass": false, "render": true}}
///   {"expr": {"node": "box1", "channel": "sizex", "source": "$F * 0.1"}}   a channel's expression ("" removes it)
///   {"frame": 12}                                      the frame expressions read ($F, $T)
///
/// Cooks are synchronous in a scripted Modeller: a step's state shows its result.
enum ProceduralStep {
    case network(String)
    case add(ProcNodeKind, name: String?, after: String?, at: SIMD2<Float>?)
    case remove(String)
    case select(String)
    case parm(node: String, name: String, value: Any)
    case wire(from: String, to: String, input: Int?)
    case unwire(to: String, input: Int)
    case flag(node: String, display: Bool?, template: Bool?, bypass: Bool?, render: Bool?)
    case expr(node: String, channel: String, source: String)
    case frame(Float)

    static let keys = ["network", "node", "parm", "wire", "unwire", "flag", "expr", "frame"]

    typealias Failure = ScriptRequests.Failure

    static func decode(_ key: String, _ value: Any) -> Result<ProceduralStep, Failure> {
        func bad(_ text: String) -> Result<ProceduralStep, Failure> { .failure(Failure("\(key): \(text)", badRequest: true)) }
        let o = value as? [String: Any] ?? [:]
        switch key {
        case "network":
            guard let s = value as? String, ["new", "object", "bake", "layout"].contains(s) else { return bad("new, object, bake or layout") }
            return .success(.network(s))
        case "node":
            if let k = o["add"] as? String {
                guard let kind = ProcNodeKind(rawValue: k) ?? ProcNodeKind.allCases.first(where: { $0.spec.title.lowercased() == k.lowercased() }) else {
                    return bad("no node kind \(k); kinds: \(ProcNodeKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                let at = (o["at"] as? [Any]).flatMap { a -> SIMD2<Float>? in
                    let c = a.compactMap { ($0 as? NSNumber)?.floatValue }
                    return c.count == 2 ? SIMD2(c[0], c[1]) : nil
                }
                return .success(.add(kind, name: o["name"] as? String, after: o["after"] as? String, at: at))
            }
            if let n = o["remove"] as? String { return .success(.remove(n)) }
            if let n = o["select"] as? String { return .success(.select(n)) }
            return bad("give {\"add\": kind}, {\"remove\": name} or {\"select\": name}")
        case "parm":
            guard let node = o["node"] as? String, let name = o["name"] as? String, let v = o["value"] else {
                return bad("give {\"node\": name, \"name\": parameter, \"value\": …}")
            }
            return .success(.parm(node: node, name: name, value: v))
        case "wire":
            guard let from = o["from"] as? String, let to = o["to"] as? String else { return bad("give {\"from\": name, \"to\": name, \"input\": n}") }
            return .success(.wire(from: from, to: to, input: o["input"] as? Int))
        case "unwire":
            guard let to = o["to"] as? String else { return bad("give {\"to\": name, \"input\": n}") }
            return .success(.unwire(to: to, input: o["input"] as? Int ?? 0))
        case "expr":
            guard let node = o["node"] as? String, let channel = o["channel"] as? String, let source = o["source"] as? String else {
                return bad("give {\"node\": name, \"channel\": \"tx\", \"source\": \"$F * 0.1\"}")
            }
            return .success(.expr(node: node, channel: channel, source: source))
        case "frame":
            guard let f = (value as? NSNumber)?.floatValue else { return bad("a number") }
            return .success(.frame(f))
        default:
            guard let node = o["node"] as? String else { return bad("give {\"node\": name, \"display\": true, …}") }
            return .success(.flag(node: node, display: o["display"] as? Bool, template: o["template"] as? Bool,
                                  bypass: o["bypass"] as? Bool, render: o["render"] as? Bool))
        }
    }

    /// Runs the step on the Modeller's Procedural session: what it did, for the step's reply.
    func execute(in m: ModelingModel) throws -> String {
        let s = m.procedural
        s.synchronous = true
        func id(_ name: String) throws -> String {
            guard let n = s.graph.named(name) ?? s.graph.node(name) else {
                throw Failure("no node \(name); the network's: \(s.graph.nodes.map(\.name).joined(separator: ", "))")
            }
            return n.id
        }
        func needNetwork() throws { if !s.hasNetwork { throw Failure("the active object has no network ({\"network\": \"new\"} first)") } }
        switch self {
        case .network(let what):
            switch what {
            case "new": s.makeNetwork()
            case "object": s.addObject()
            case "bake": try needNetwork(); s.bakeNetwork()
            default: try needNetwork(); s.selection = []; s.layout()
            }
            return "network \(what)"
        case let .add(kind, name, after, at):
            try needNetwork()
            let above = try after.map(id)
            // (Wired only below `after`: not the Tab menu's selected node.)
            if above == nil { s.selection = [] }
            guard let new = s.add(kind, at: at ?? (above == nil ? s.graph.nodes.last.map { $0.at + [0, ProcNetworkLayout.rowGap] } ?? .zero : nil),
                                  after: above) else { throw Failure("couldn't add \(kind.rawValue)") }
            if let name { s.rename(new, to: name) }
            return "added \(s.graph.node(new)?.name ?? new)"
        case .remove(let name):
            s.selection = [try id(name)]
            s.deleteSelection()
            return "removed \(name)"
        case .select(let name):
            let n = try id(name)
            s.selection = [n]
            s.focus = n
            return "selected \(name)"
        case let .parm(node, name, value):
            let n = try id(node)
            guard let spec = s.graph.node(n)?.kind.spec.param(name) else {
                throw Failure("\(node) has no parameter \(name); its: \(s.graph.node(n)?.kind.spec.params.map(\.name).joined(separator: ", ") ?? "")")
            }
            guard let v = ProceduralStep.value(value, like: spec.value) else { throw Failure("\(name): can't read \(value) as \(spec.value)") }
            s.setParam(n, name, v)
            return "set \(node).\(name)"
        case let .wire(from, to, input):
            let a = try id(from), b = try id(to)
            guard s.link(a, "out", to: b, input.map(String.init) ?? "node") else { throw Failure("can't wire \(from) into \(to) (a loop, or no such input)") }
            return "wired \(from) → \(to)"
        case let .unwire(to, input):
            s.unlink(try id(to), String(input))
            return "unwired \(to).\(input)"
        case let .flag(node, display, template, bypass, render):
            let n = try id(node)
            guard let current = s.graph.node(n) else { throw Failure("no node \(node)") }
            if display == true { s.setDisplay(n) }
            if render == true { s.setRender(n) }
            if let t = template, t != current.template { s.toggleTemplate(n) }
            if let b = bypass, b != current.bypass { s.toggleBypass(n) }
            return "flags of \(node)"
        case let .expr(node, channel, source):
            let n = try id(node)
            guard let kind = s.graph.node(n)?.kind, ProcExprContext.locate(channel, in: kind) != nil else {
                let all = s.graph.node(n)?.kind.spec.params.flatMap(ProcExprContext.channels) ?? []
                throw Failure("\(node) has no channel \(channel); its: \(all.joined(separator: ", "))")
            }
            s.setExpression(n, channel, source)
            return source.isEmpty ? "removed \(node)/\(channel)'s expression" : "set \(node)/\(channel) to \(source)"
        case .frame(let f):
            s.frame = f
            return "frame \(ProcExprContext.format(f))"
        }
    }

    /// A JSON value as a parameter of the kind `like` is.
    static func value(_ v: Any, like: ProcParam) -> ProcParam? {
        let numbers = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
        switch like {
        case .float: return (v as? NSNumber).map { .float($0.floatValue) }
        case .int: return (v as? NSNumber).map { .int($0.intValue) }
        case .bool: return (v as? Bool).map { .bool($0) } ?? (v as? NSNumber).map { .bool($0.boolValue) }
        case .string: return (v as? String).map { .string($0) }
        case .vec2: return numbers.flatMap { $0.count == 2 ? .vec2(SIMD2($0[0], $0[1])) : nil }
        case .vec3: return numbers.flatMap { $0.count == 3 ? .vec3(SIMD3($0[0], $0[1], $0[2])) : nil }
        case .vec4: return numbers.flatMap { $0.count == 4 ? .vec4(SIMD4($0[0], $0[1], $0[2], $0[3])) : nil }
        case .points:
            guard let list = v as? [[Any]] else { return nil }
            let pts = list.map { $0.compactMap { ($0 as? NSNumber)?.floatValue } }
            guard pts.allSatisfy({ $0.count == 3 }) else { return nil }
            return .points(pts.map { SIMD3($0[0], $0[1], $0[2]) })
        case .ramp:
            guard let list = v as? [[Any]] else { return nil }
            let keys = list.map { $0.compactMap { ($0 as? NSNumber)?.floatValue } }
            guard keys.allSatisfy({ $0.count == 2 }) else { return nil }
            return .ramp(keys.map { SIMD2($0[0], $0[1]) })
        }
    }

    /// The network as the scripted Modeller's state shows it.
    static func state(_ s: ProceduralSession) -> [String: Any]? {
        guard s.hasNetwork else { return nil }
        let g = s.graph
        return [
            "display": g.displayNode.flatMap { g.node($0)?.name } ?? "",
            "nodes": g.nodes.map { n -> [String: Any] in
                var e: [String: Any] = ["name": n.name, "kind": n.kind.rawValue, "display": n.display, "template": n.template,
                                        "bypass": n.bypass, "render": n.render, "at": [Double(n.at.x), Double(n.at.y)],
                                        "inputs": g.inputs(of: n.id).map { $0.flatMap { g.node($0)?.name } ?? "" }]
                if !n.params.isEmpty { e["params"] = n.params.keys.sorted() }
                if !n.expressions.isEmpty { e["expressions"] = n.expressions }
                if let i = s.info[n.id] {
                    if !i.channels.isEmpty {
                        e["channels"] = i.channels.mapValues { v -> Any in v.map { Double($0) } ?? "per element" }
                    }
                    if let err = i.error { e["error"] = err }
                    if !i.warnings.isEmpty { e["warnings"] = i.warnings }
                    e["points"] = i.points
                    e["prims"] = i.prims
                    e["vertices"] = i.vertices
                }
                return e
            },
            "interface": g.interface.map(\.name),
            "frame": Double(s.frame),
        ]
    }
}
