import AppKit
import Foundation
import MetalRenderer
import Modeling
import simd

/// One thing a scripted Modeller does (ScriptModeller): what a user's key, click or drag would, or a setter the
/// window's buttons have. The socket's `modeller` request, the MCP tool, `Tools/script.py --modeller` and a script's
/// `run.modeller.perform` all send them as JSON:
///
///   {"keys": "tab 3 ctrl+r shift+a f3"}      chords through the keymap (ctrl+, shift+, alt+, cmd+; tab, return, esc,
///                                            space, backspace, delete, up, down, left, right, f1-f4, numpad0-9 …)
///   {"type": "1.5"}                          each character a key (a typed value); F3's search: its query
///   {"click": [x, y], "button": "left", "mods": "shift", "count": 2}    points of the viewport, from its top left;
///                                            or {"world": [x, y, z]}, where the camera shows that point
///   {"drag": [[x, y], …], "button", "mods", "pressure": [p, …], "steps": n}   press, moves, release
///   {"move": [x, y]}                         the mouse moved (a modal operator follows it)
///   {"scroll": dy, "at": [x, y], "mods"}     the wheel
///   {"run": "Bridge Edge Loops"}             an operator of the mode's menus by name or menu path (F3's list)
///   {"pick": "Merge ▸ At Center"}            an item of the popup the last key opened (W, X, M, Shift-A …)
///   {"add": "icoSphere"}, {"mode": "edit"}, {"selectMode": "face"}, {"tool": "knife"}, {"shading": "rendered"},
///   {"workspace": "sculpting"}, {"brush": "clay"}
///   {"open": {"primitive": "cube"} | {"asset": "<slug>"} | {"file": "<path>"} | {"selection": true}}
///   {"new": true}, {"save": "<name>"} ({"save": true}: under its asset's name), {"place": true} (the saved model into
///   the app's scene, in front of its camera: `mesh:<slug>`), {"size": [w, h]},
///   {"wait": seconds}, {"close": true}
enum ModellerStep {
    case keys([KeyChord])
    case type(String)
    case click(Point, button: ModelingModel.Button, flags: NSEvent.ModifierFlags, count: Int)
    case drag([Point], button: ModelingModel.Button, flags: NSEvent.ModifierFlags, pressure: [Float])
    case move(Point)
    case scroll(Float, at: Point?, flags: NSEvent.ModifierFlags)
    case run(String)
    case pick(String)
    case add(Primitive)
    case mode(EditorMode)
    case selectMode(SelectMode)
    case tool(ModelingTool)
    case shading(ViewportShading.Mode)
    case workspace(Workspace)
    case brush(SculptBrushKind)
    case open(Open)
    case new
    case save(String?)
    case place
    case size(SIMD2<Float>)
    case wait(Double)
    case close

    /// A point of the viewport (points from its top left), or of the world (where the camera shows it, when the step
    /// runs).
    enum Point: Equatable {
        case screen(SIMD2<Float>), world(SIMD3<Float>)

        func resolved(_ m: ModelingModel) throws -> SIMD2<Float> {
            switch self {
            case .screen(let p): return p
            case .world(let w):
                guard let q = m.camera.project(w, size: m.viewSize) else { throw Failure("\(w) is behind the camera") }
                return SIMD2(q.x, q.y)
            }
        }
    }

    enum Open: Equatable {
        case primitive(Primitive), asset(String), file(String), selection
    }

    typealias Failure = ScriptRequests.Failure

    /// The steps' keys, as the errors list them.
    static let keys = ["keys", "type", "click", "drag", "move", "scroll", "run", "pick", "add", "mode", "selectMode", "tool",
                       "shading", "workspace", "brush", "open", "new", "save", "place", "size", "wait", "close"]

    /// The steps of a JSON list (each an object of one key, or a bare string of keys); the first bad one fails all.
    static func decode(list: Any) -> Result<[ModellerStep], Failure> {
        guard let items = list as? [Any] else { return .failure(Failure("steps: give a list of steps, e.g. [{\"keys\": \"tab\"}]", badRequest: true)) }
        var out: [ModellerStep] = []
        for (k, item) in items.enumerated() {
            switch decode(item) {
            case .success(let s): out.append(s)
            case .failure(let f): return .failure(Failure("step \(k + 1): \(f)", badRequest: true))
            }
        }
        return .success(out)
    }

    static func decode(_ item: Any) -> Result<ModellerStep, Failure> {
        if let text = item as? String { return chords(text).map { .keys($0) } }
        guard let body = item as? [String: Any] else { return .failure(Failure("a step is an object, e.g. {\"keys\": \"tab\"}", badRequest: true)) }
        guard let key = keys.first(where: { body[$0] != nil }) else {
            return .failure(Failure("no step in \(body.keys.sorted()); the steps: \(keys.joined(separator: ", "))", badRequest: true))
        }
        let value = body[key]!
        func bad(_ text: String) -> Result<ModellerStep, Failure> { .failure(Failure("\(key): \(text)", badRequest: true)) }
        func named<E: RawRepresentable & CaseIterable>(_: E.Type) -> E? where E.RawValue == String {
            guard let s = value as? String else { return nil }
            return E(rawValue: s) ?? E.allCases.first { $0.rawValue.lowercased() == s.lowercased() }
        }
        func names<E: RawRepresentable & CaseIterable>(_: E.Type) -> String where E.RawValue == String {
            E.allCases.map(\.rawValue).joined(separator: ", ")
        }
        let button = (body["button"] as? String).flatMap(button(named:)) ?? .left
        if let b = body["button"] as? String, Self.button(named: b) == nil { return bad("button is left, right or middle, not \(b)") }
        let flags = modifiers(body["mods"] as? String ?? "")
        switch key {
        case "keys":
            guard let s = value as? String else { return bad("give the chords as a string, e.g. \"tab ctrl+r\"") }
            return chords(s).map { .keys($0) }
        case "type":
            guard let s = value as? String ?? (value as? NSNumber).map({ "\($0)" }) else { return bad("give the text") }
            return .success(.type(s))
        case "click":
            guard let p = point(value) else { return bad("give the point, [x, y] in viewport points or {\"world\": [x, y, z]}") }
            return .success(.click(p, button: button, flags: flags, count: max(1, body["count"] as? Int ?? 1)))
        case "drag":
            guard let list = value as? [Any] else { return bad("give the points, [[x, y], …]") }
            var points = list.compactMap(point)
            guard points.count == list.count, points.count >= 2 else { return bad("give two points or more, [[x, y], …]") }
            var pressure = (body["pressure"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
            // `steps`: each stretch cut into that many moves (a stroke's dabs come with the moves).
            if let n = body["steps"] as? Int, n > 1 {
                var fine: [Point] = [points[0]], finePressure: [Float] = pressure.isEmpty ? [] : [pressure[0]]
                for k in 1..<points.count {
                    for s in 1...n {
                        let t = Float(s) / Float(n)
                        switch (points[k - 1], points[k]) {
                        case let (.screen(a), .screen(b)): fine.append(.screen(simd_mix(a, b, SIMD2(repeating: t))))
                        case let (.world(a), .world(b)): fine.append(.world(simd_mix(a, b, SIMD3(repeating: t))))
                        default: return bad("steps: the points all of the viewport or all of the world")
                        }
                        if !pressure.isEmpty {
                            let a = pressure[min(k - 1, pressure.count - 1)], b = pressure[min(k, pressure.count - 1)]
                            finePressure.append(a + (b - a) * t)
                        }
                    }
                }
                points = fine
                pressure = finePressure
            }
            return .success(.drag(points, button: button, flags: flags, pressure: pressure))
        case "move":
            guard let p = point(value) else { return bad("give the point, [x, y]") }
            return .success(.move(p))
        case "scroll":
            guard let dy = (value as? NSNumber)?.floatValue else { return bad("give the wheel's steps (up: positive)") }
            return .success(.scroll(dy, at: body["at"].flatMap(point), flags: flags))
        case "run":
            guard let s = value as? String, !s.isEmpty else { return bad("give the operator's name, e.g. \"Bridge Edge Loops\"") }
            return .success(.run(s))
        case "pick":
            guard let s = value as? String, !s.isEmpty else { return bad("give the item's title, or its path (\"Merge ▸ At Center\")") }
            return .success(.pick(s))
        case "add":
            guard let p = named(Primitive.self) else { return bad("one of \(names(Primitive.self))") }
            return .success(.add(p))
        case "mode":
            guard let m = named(EditorMode.self) else { return bad("one of \(names(EditorMode.self))") }
            return .success(.mode(m))
        case "selectMode":
            let all: [String: SelectMode] = ["vertex": .vertex, "edge": .edge, "face": .face]
            guard let m = (value as? String).flatMap({ all[$0.lowercased()] }) ?? (value as? Int).flatMap(SelectMode.init(rawValue:)) else {
                return bad("vertex, edge or face")
            }
            return .success(.selectMode(m))
        case "tool":
            guard let t = named(ModelingTool.self) else { return bad("one of \(names(ModelingTool.self))") }
            return .success(.tool(t))
        case "shading":
            guard let m = named(ViewportShading.Mode.self) else { return bad("one of \(names(ViewportShading.Mode.self))") }
            return .success(.shading(m))
        case "workspace":
            guard let w = named(Workspace.self) else { return bad("one of \(names(Workspace.self))") }
            return .success(.workspace(w))
        case "brush":
            guard let b = named(SculptBrushKind.self) else { return bad("one of \(names(SculptBrushKind.self))") }
            return .success(.brush(b))
        case "open":
            guard let o = value as? [String: Any] else { return bad("give {\"primitive\": …}, {\"asset\": …}, {\"file\": …} or {\"selection\": true}") }
            if let s = o["primitive"] as? String {
                guard let p = Primitive(rawValue: s) else { return bad("primitive: one of \(names(Primitive.self))") }
                return .success(.open(.primitive(p)))
            }
            if let s = o["asset"] as? String { return .success(.open(.asset(s))) }
            if let s = o["file"] as? String { return .success(.open(.file(s))) }
            if o["selection"] != nil { return .success(.open(.selection)) }
            return bad("give {\"primitive\": …}, {\"asset\": …}, {\"file\": …} or {\"selection\": true}")
        case "new":
            return .success(.new)
        case "save":
            return .success(.save(value as? String))
        case "place":
            return .success(.place)
        case "size":
            guard case .screen(let p)? = point(value), p.x >= 64, p.y >= 64 else { return bad("give [width, height] in points, 64 or more") }
            return .success(.size(p))
        case "wait":
            guard let s = (value as? NSNumber)?.doubleValue, s >= 0, s <= 120 else { return bad("give seconds, 0 to 120") }
            return .success(.wait(s))
        default:
            return .success(.close)
        }
    }

    /// The chords of `text`: words split by spaces, each its modifiers then its key (`ctrl+shift+d`, `cmd+z`, `f3`).
    static func chords(_ text: String) -> Result<[KeyChord], Failure> {
        var out: [KeyChord] = []
        for word in text.split(whereSeparator: { $0 == " " || $0 == "," }) {
            var rest = Substring(word)
            var chord = KeyChord("")
            while true {
                let lower = rest.lowercased()
                if lower.hasPrefix("ctrl+") { chord.ctrl = true; rest = rest.dropFirst(5) }
                else if lower.hasPrefix("shift+") { chord.shift = true; rest = rest.dropFirst(6) }
                else if lower.hasPrefix("alt+") { chord.alt = true; rest = rest.dropFirst(4) }
                else if lower.hasPrefix("opt+") { chord.alt = true; rest = rest.dropFirst(4) }
                else if lower.hasPrefix("cmd+") { chord.cmd = true; rest = rest.dropFirst(4) }
                else { break }
            }
            guard !rest.isEmpty else { return .failure(Failure("keys: \"\(word)\" has no key", badRequest: true)) }
            let aliases = ["enter": "return", "escape": "esc", "del": "delete", "backtick": "`", "plus": "=", "minus": "-"]
            let key = rest.lowercased()
            chord.key = aliases[key] ?? key
            out.append(chord)
        }
        guard !out.isEmpty else { return .failure(Failure("keys: give at least one chord", badRequest: true)) }
        return .success(out)
    }

    static func modifiers(_ text: String) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for w in text.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "," }) {
            switch w {
            case "shift": f.insert(.shift)
            case "ctrl", "control": f.insert(.control)
            case "alt", "opt", "option": f.insert(.option)
            case "cmd", "command": f.insert(.command)
            default: break
            }
        }
        return f
    }

    static func button(named s: String) -> ModelingModel.Button? {
        ["left": .left, "right": .right, "middle": .middle][s.lowercased()]
    }

    static func point(_ v: Any) -> Point? {
        if let o = v as? [String: Any], let w = o["world"] as? [Any], w.count == 3 {
            let c = w.compactMap { ($0 as? NSNumber)?.floatValue }
            return c.count == 3 ? .world(SIMD3(c[0], c[1], c[2])) : nil
        }
        guard let a = v as? [Any], a.count == 2, let x = (a[0] as? NSNumber)?.floatValue, let y = (a[1] as? NSNumber)?.floatValue else { return nil }
        return .screen(SIMD2(x, y))
    }
}
