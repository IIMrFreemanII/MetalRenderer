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
///   {"frame": 12}                                      the frame expressions and keys read ($F, $T)
///   {"keyframe": {"node": "box1", "channel": "tx", "frame": 24, "value": 2, "interpolation": "linear"}}   a key
///                                                      (value: the channel's on the frame; "delete": true removes it)
///   {"range": [1, 48]}                                 the frames the network plays
///   {"node": {"add": "asset", "asset": "fence"}}       a node of the library's asset `fence`
///   {"dive": "subnet1"}, {"dive": ".."}, {"dive": "/"}  into a subnetwork's or asset's network, up a level, to the top
///   {"collapse": {"nodes": ["box1", "xform1"], "name": "wall"}}   the nodes into a subnetwork; {"extract": "wall"}
///   {"interface": {"node": "wall", "add": {"name": "height", "value": 2, "range": [0, 10]}}}   a parameter of a
///                                                      container (no node: the asset's); {"remove": name},
///                                                      {"rename": {"from": a, "to": b}} as well
///   {"definition": {"node": "fence1", "action": "allow" | "match" | "save"}}   an asset node's contents
///
/// Cooks are synchronous in a scripted Modeller: a step's state shows its result.
enum ProceduralStep {
    case network(String)
    case add(ProcNodeKind, name: String?, after: String?, at: SIMD2<Float>?, asset: String?)
    case remove(String)
    case select(String)
    case parm(node: String, name: String, value: Any)
    case wire(from: String, to: String, input: Int?)
    case unwire(to: String, input: Int)
    case flag(node: String, display: Bool?, template: Bool?, bypass: Bool?, render: Bool?)
    case expr(node: String, channel: String, source: String)
    case frame(Float)
    case keyframe(node: String, channel: String, frame: Float?, value: Float?, interpolation: ProcInterpolation?, delete: Bool)
    case range(ClosedRange<Int>)
    case dive(String)
    case collapse(nodes: [String], name: String?)
    case extract(String)
    case interface(node: String?, add: [String: Any]?, remove: String?, rename: (from: String, to: String)?)
    case definition(node: String, action: String)

    static let keys = ["network", "node", "parm", "wire", "unwire", "flag", "expr", "frame", "keyframe", "range",
                       "dive", "collapse", "extract", "interface", "definition"]

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
                if kind == .asset, o["asset"] as? String == nil { return bad("an asset node names its asset: {\"add\": \"asset\", \"asset\": slug}") }
                return .success(.add(kind, name: o["name"] as? String, after: o["after"] as? String, at: at, asset: o["asset"] as? String))
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
        case "keyframe":
            guard let node = o["node"] as? String, let channel = o["channel"] as? String else {
                return bad("give {\"node\": name, \"channel\": \"tx\", \"frame\": 24, \"value\": 2}")
            }
            var interpolation: ProcInterpolation?
            if let i = o["interpolation"] as? String {
                guard let m = ProcInterpolation(rawValue: i) else { return bad("interpolation: \(ProcInterpolation.allCases.map(\.rawValue).joined(separator: ", "))") }
                interpolation = m
            }
            return .success(.keyframe(node: node, channel: channel, frame: (o["frame"] as? NSNumber)?.floatValue,
                                      value: (o["value"] as? NSNumber)?.floatValue, interpolation: interpolation, delete: o["delete"] as? Bool ?? false))
        case "range":
            guard let r = (value as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }), r.count == 2, r[0] <= r[1] else { return bad("[first, last]") }
            return .success(.range(r[0]...r[1]))
        case "dive":
            guard let n = value as? String else { return bad("a container's name, \"..\" or \"/\"") }
            return .success(.dive(n))
        case "collapse":
            guard let nodes = o["nodes"] as? [String], !nodes.isEmpty else { return bad("give {\"nodes\": [names], \"name\": name}") }
            return .success(.collapse(nodes: nodes, name: o["name"] as? String))
        case "extract":
            guard let n = value as? String else { return bad("a subnetwork's name") }
            return .success(.extract(n))
        case "interface":
            let r = o["rename"] as? [String: Any]
            let rename = (r?["from"] as? String).flatMap { a in (r?["to"] as? String).map { (a, $0) } }
            guard o["add"] != nil || o["remove"] != nil || rename != nil else { return bad("give \"add\", \"remove\" or \"rename\"") }
            return .success(.interface(node: o["node"] as? String, add: o["add"] as? [String: Any], remove: o["remove"] as? String, rename: rename))
        case "definition":
            guard let node = o["node"] as? String, let a = o["action"] as? String, ["allow", "match", "save"].contains(a) else {
                return bad("give {\"node\": name, \"action\": \"allow\" | \"match\" | \"save\"}")
            }
            return .success(.definition(node: node, action: a))
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
        case let .add(.asset, name, _, at, asset?):
            try needNetwork()
            guard let new = s.addAsset(asset, at: at ?? s.graph.nodes.last.map { $0.at + [0, ProcNetworkLayout.rowGap] } ?? .zero) else {
                throw Failure("couldn't add the asset \(asset)")
            }
            if let name { s.rename(new, to: name) }
            return "added \(s.graph.node(new)?.name ?? new)"
        case let .add(kind, name, after, at, _):
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
            guard let spec = s.graph.node(n)?.spec.param(name) else {
                throw Failure("\(node) has no parameter \(name); its: \(s.graph.node(n)?.spec.params.map(\.name).joined(separator: ", ") ?? "")")
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
            guard let pn = s.graph.node(n), ProcExprContext.locate(channel, in: pn) != nil else {
                let all = s.graph.node(n)?.spec.params.flatMap(ProcExprContext.channels) ?? []
                throw Failure("\(node) has no channel \(channel); its: \(all.joined(separator: ", "))")
            }
            s.setExpression(n, channel, source)
            return source.isEmpty ? "removed \(node)/\(channel)'s expression" : "set \(node)/\(channel) to \(source)"
        case .frame(let f):
            s.frame = f
            return "frame \(ProcExprContext.format(f))"
        case let .keyframe(node, channel, frame, value, interpolation, delete):
            let n = try id(node)
            guard let p = s.graph.node(n), let (spec, k) = ProcExprContext.locate(channel, in: p) else {
                let all = s.graph.node(n)?.spec.params.flatMap(ProcExprContext.channels) ?? []
                throw Failure("\(node) has no channel \(channel); its: \(all.joined(separator: ", "))")
            }
            let f = frame ?? s.frame
            var curve = p.curves[channel] ?? ProcCurve()
            if delete {
                curve.remove(at: f)
            } else {
                let now = s.current(p, spec.name)
                curve.set(f, value ?? (k.map { now.vec4[$0] } ?? now.float))
                if let interpolation, let i = curve.index(at: f) { curve.update(i) { $0.interpolation = interpolation } }
            }
            s.setCurves([(n, channel, curve.keys.isEmpty ? nil : curve)], delete ? "Delete Key" : "Set Key")
            return delete ? "removed \(node)/\(channel)'s key on \(ProcExprContext.format(f))" : "keyed \(node)/\(channel) on \(ProcExprContext.format(f))"
        case .range(let r):
            s.setFrameRange(r)
            return "frames \(r.lowerBound)-\(r.upperBound)"
        case .dive(let to):
            try needNetwork()
            switch to {
            case "..": s.up()
            case "/": s.jump(to: 0)
            default:
                let n = try id(to)
                guard s.graph.node(n)?.kind.isContainer == true else { throw Failure("\(to) has no network inside") }
                s.dive(into: n)
            }
            return "at /" + s.levels.dropFirst().map(\.name).joined(separator: "/")
        case let .collapse(nodes, name):
            s.selection = Set(try nodes.map(id))
            s.collapseSelection()
            guard let made = s.selection.first, s.selection.count == 1, s.graph.node(made)?.kind == .subnet else {
                throw Failure("couldn't collapse \(nodes.joined(separator: ", ")) (more than one feeding the outside?)")
            }
            if let name { s.rename(made, to: name) }
            return "collapsed into \(s.graph.node(made)?.name ?? made)"
        case .extract(let name):
            let n = try id(name)
            guard s.graph.node(n)?.kind == .subnet else { throw Failure("\(name) isn't a subnetwork") }
            s.extract(n)
            return "extracted \(name)"
        case let .interface(node, add, remove, rename):
            let n = try node.map(id)
            var params = n.map { s.graph.node($0)?.contents?.interface ?? [] } ?? s.root.interface
            var renamed: [String: String] = [:]
            if let add {
                guard let name = add["name"] as? String, let raw = add["value"] else { throw Failure("add: give {\"name\": …, \"value\": …}") }
                let value: ProcParam
                switch raw {
                case let x as NSNumber where CFGetTypeID(x) == CFBooleanGetTypeID(): value = .bool(x.boolValue)
                case let x as NSNumber: value = CFNumberIsFloatType(x) ? .float(x.floatValue) : .int(x.intValue)
                case let t as String: value = .string(t)
                case let a as [Any]:
                    let c = a.compactMap { ($0 as? NSNumber)?.floatValue }
                    switch c.count {
                    case 2: value = .vec2(SIMD2(c[0], c[1]))
                    case 3: value = .vec3(SIMD3(c[0], c[1], c[2]))
                    case 4: value = .vec4(SIMD4(c[0], c[1], c[2], c[3]))
                    default: throw Failure("a vector has 2 to 4 numbers")
                    }
                default: throw Failure("can't read \(raw) as a parameter's value")
                }
                let r = (add["range"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
                params.removeAll { $0.name == name }
                params.append(PromotedParam(name, title: add["title"] as? String, value: value,
                                            span: r.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }, targets: []))
            }
            if let remove { params.removeAll { $0.name == remove } }
            if let (a, b) = rename {
                guard let i = params.firstIndex(where: { $0.name == a }) else { throw Failure("no parameter \(a)") }
                params[i].name = b
                renamed[a] = b
            }
            s.setInterface(n, params, renamed: renamed)
            return "parameters of \(node ?? "the asset"): \(params.map(\.name).joined(separator: ", "))"
        case let .definition(node, action):
            let n = try id(node)
            guard s.graph.node(n)?.kind == .asset else { throw Failure("\(node) isn't an asset node") }
            switch action {
            case "allow": s.allowEditing(n)
            case "match": s.matchDefinition(n)
            default: guard s.saveDefinition(n) else { throw Failure("couldn't save \(node)'s definition") }
            }
            return "\(action) \(node)"
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
                if !n.curves.isEmpty {
                    e["keys"] = n.curves.mapValues { c in c.keys.map { k -> [String: Any] in
                        ["frame": Double(k.frame), "value": Double(k.value), "interpolation": k.interpolation.rawValue]
                    } }
                }
                if let c = n.contents {
                    e["contents"] = c.nodes.count
                    if n.kind == .asset { e["asset"] = n.definition ?? ""; e["locked"] = !n.editable }
                }
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
            "path": s.levels.dropFirst().map(\.name),
            "locked": s.locked,
            "frame": Double(s.frame),
            "frames": [g.frames.lowerBound, g.frames.upperBound],
        ]
    }
}
