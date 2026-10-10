import Foundation
import simd

/// Builds a material graph in Swift: nodes added with their parameters and what is wired into them, outputs named
/// by channel; `graph` lays the nodes out in columns (each right of what feeds it).
///
///     var b = MatBuilder("Red Bricks")
///     let bricks = b.node(.bricks, ["rows": .int(10)])
///     b.output(.normal, b.node(.normal, ["intensity": .float(6)], ["in": bricks]))
struct MatBuilder {
    /// A node's output, to wire: `ref` is its "out", `ref["random"]` another.
    struct Ref {
        let id: String
        var output = "out"
        subscript(_ output: String) -> Ref { Ref(id: id, output: output) }
    }

    private var g: MaterialGraph

    init(_ name: String, size: Int = 10) { g = MaterialGraph(name, size: size) }

    @discardableResult
    mutating func node(_ kind: MatOpKind, _ params: [String: MatParam] = [:], _ inputs: [String: Ref] = [:], id: String? = nil) -> Ref {
        let id = VFXEffect.unique(id ?? kind.rawValue, g.allIDs)
        g.nodes.append(MatNode(kind, params, id: id))
        for (pin, r) in inputs.sorted(by: { $0.key < $1.key }) { g.links.append(MatLink(r.id, r.output, to: id, pin)) }
        return Ref(id: id)
    }

    /// An output node of channel `c`, fed by `from`.
    mutating func output(_ c: MatChannel, _ from: Ref) {
        node(.output, ["usage": .choice(c.rawValue), "name": .text(c.rawValue)], ["in": from], id: c.rawValue)
    }

    mutating func set(_ change: (inout MaterialGraph) -> Void) { change(&g) }

    var graph: MaterialGraph { MatLayout.arranged(g) }
}

/// The built-in graphs: the Material Designer's starters, and what a scene can name before anything is saved.
enum MaterialLibrary {
    static let all: [MaterialGraph] = [redBricks(), cobblestone(), rustedPaint(), brushedSteel(), scratchedCopper(), perforatedMetal(),
                                       oakPlanks(), barkAndMoss(), scifiPanels(), marble()]
    static var names: [String] { all.map(\.name) }
    static func named(_ name: String) -> MaterialGraph? { all.first { $0.name == name } }

    /// Colours as sRGB values (what the graph works in), alpha 1.
    static func rgb(_ r: Float, _ g: Float, _ b: Float) -> MatParam { .color([r, g, b, 1]) }
    static func gradient(_ keys: (Float, SIMD3<Float>)...) -> MatParam {
        .gradient(VFXGradient(keys.map { VFXGradient.Key($0.0, SIMD4($0.1, 1)) }))
    }

    /// Red bricks in pale mortar, each brick its own shade and height, dirt in the joints.
    static func redBricks() -> MaterialGraph {
        var b = MatBuilder("Red Bricks")
        let bricks = b.node(.bricks, ["columns": .int(4), "rows": .int(10), "gap": .float(0.008), "bevel": .float(0.3),
                                      "heightRandom": .float(0.25)])
        let noise = b.node(.fractalSum, ["scale": .int(8), "octaves": .int(7), "roughness": .float(0.55)])
        let pits = b.node(.levels, ["inLow": .float(0.25), "inHigh": .float(0.75), "outLow": .float(0.82)], ["in": noise])
        let height = b.node(.blend, ["mode": .choice("multiply")], ["fg": pits, "bg": bricks])
        let mortar = b.node(.histogramScan, ["position": .float(0.97), "contrast": .float(0.95), "invert": .bool(true)], ["in": bricks])
        let shade = b.node(.gradientMap, ["gradient": gradient((0, [0.42, 0.13, 0.08]), (0.5, [0.58, 0.2, 0.12]), (1, [0.68, 0.32, 0.2]))],
                           ["in": bricks["random"]])
        let speckle = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.5)], ["fg": noise, "bg": shade])
        let mortarColor = b.node(.uniformColor, ["color": rgb(0.62, 0.58, 0.52)])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": mortarColor, "bg": speckle, "mask": mortar])
        let ao = b.node(.ambientOcclusion, ["radius": .float(0.03)], ["in": height])
        let rough = b.node(.levels, ["outLow": .float(0.95), "outHigh": .float(0.72)], ["in": height])
        b.output(.baseColor, color)
        b.output(.normal, b.node(.normal, ["intensity": .float(5)], ["in": height]))
        b.output(.roughness, rough)
        b.output(.ambientOcclusion, ao)
        b.output(.height, height)
        return b.graph
    }
}

extension MaterialLibrary {
    /// A steel sheet punched with round holes in rows (its opacity cuts them), brushed, a little dirty at the edges.
    static func perforatedMetal() -> MaterialGraph {
        var b = MatBuilder("Perforated Metal")
        let holes = b.node(.tileSampler, ["columns": .int(10), "rows": .int(10), "kind": .choice("disc"), "size": .float(0.62),
                                          "sizeRandom": .float(0), "positionRandom": .float(0), "lumRandom": .float(0), "rowOffset": .float(0.5)])
        let solid = b.node(.invert, [:], ["in": holes])
        let rim = b.node(.bevel, ["distance": .float(0.012), "smoothing": .float(0.6)], ["in": solid])
        let brushed = b.node(.anisotropicNoise, ["scaleX": .int(3), "scaleY": .int(256)])
        let grime = b.node(.grunge, ["scale": .int(3), "contrast": .float(0.5)])
        let steel = b.node(.gradientMap, ["gradient": gradient((0, [0.66, 0.67, 0.69]), (1, [0.84, 0.85, 0.86]))], ["in": brushed])
        let dirty = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.35)], ["fg": grime, "bg": steel])
        let rough = b.node(.levels, ["outLow": .float(0.22), "outHigh": .float(0.45)], ["in": grime])
        b.output(.baseColor, dirty)
        b.output(.metallic, b.node(.uniform, ["value": .float(1)]))
        b.output(.roughness, rough)
        b.output(.normal, b.node(.normal, ["intensity": .float(3)], ["in": rim]))
        b.output(.height, rim)
        b.output(.opacity, solid)
        b.set { $0.surface.heightDepth = 0.01 }
        return b.graph
    }
}

extension MaterialLibrary {
    /// Polished white marble with grey veins: waves warped by turbulence, a gradient; it runs as code in the shading
    /// (MatShaderCode: every node of it can), sharp however near the view comes.
    static func marble() -> MaterialGraph {
        var b = MatBuilder("Marble")
        let turbulence = b.node(.fractalSum, ["scale": .int(3), "octaves": .int(6), "roughness": .float(0.55), "mode": .choice("fbm")])
        let bands = b.node(.waves, ["frequency": .int(4), "angle": .float(0), "wave": .choice("sine")])
        let veins = b.node(.warp, ["intensity": .float(0.06)], ["in": bands, "gradient": turbulence])
        let sharp = b.node(.levels, ["inLow": .float(0.0), "inHigh": .float(0.25), "gamma": .float(0.7)], ["in": veins])
        let color = b.node(.gradientMap, ["gradient": gradient((0, [0.42, 0.43, 0.46]), (0.35, [0.78, 0.78, 0.79]), (1, [0.95, 0.94, 0.92]))],
                           ["in": sharp])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.25), "outHigh": .float(0.08)], ["in": sharp]))
        b.output(.normal, b.node(.normal, ["intensity": .float(0.6)], ["in": sharp]))
        b.set { $0.surface.shaderMode = true; $0.surface.heightDepth = 0 }
        return b.graph
    }
}

extension MaterialLibrary {
    /// Rounded stones of many greys and browns, set in dirt.
    static func cobblestone() -> MaterialGraph {
        var b = MatBuilder("Cobblestone")
        let near = b.node(.cells, ["scale": .int(7), "jitter": .float(0.85), "mode": .choice("f1")])
        let edges = b.node(.cells, ["scale": .int(7), "jitter": .float(0.85), "mode": .choice("borders")])
        let shade = b.node(.cells, ["scale": .int(7), "jitter": .float(0.85), "mode": .choice("cellValue")])
        let dome = b.node(.levels, ["inLow": .float(0), "inHigh": .float(0.9), "gamma": .float(0.6), "outLow": .float(1), "outHigh": .float(0)], ["in": near])
        let joints = b.node(.histogramScan, ["position": .float(0.88), "contrast": .float(0.85)], ["in": edges])
        let grain = b.node(.fractalSum, ["scale": .int(16), "octaves": .int(5), "roughness": .float(0.5)])
        let stones = b.node(.blend, ["mode": .choice("multiply")], ["fg": joints, "bg": dome])
        let height = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.25)], ["fg": grain, "bg": stones])
        let tint = b.node(.gradientMap, ["gradient": gradient((0, [0.33, 0.31, 0.29]), (0.5, [0.5, 0.47, 0.42]), (1, [0.62, 0.55, 0.46]))], ["in": shade])
        let speckled = b.node(.blend, ["mode": .choice("overlay"), "opacity": .float(0.5)], ["fg": grain, "bg": tint])
        let dirt = b.node(.uniformColor, ["color": rgb(0.22, 0.19, 0.15)])
        let gaps = b.node(.invert, [:], ["in": joints])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": dirt, "bg": speckled, "mask": gaps])
        b.output(.baseColor, color)
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(3)], ["in": height]))
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.95), "outHigh": .float(0.6)], ["in": height]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.04), "depth": .float(0.05)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.05 }
        return b.graph
    }

    /// Teal paint over steel, rusting through in patches: blistered at their edges, bare metal where it flaked.
    static func rustedPaint() -> MaterialGraph {
        var b = MatBuilder("Rusted Paint")
        let grime = b.node(.grunge, ["scale": .int(3), "contrast": .float(0.7), "spots": .float(0.6)])
        let clouds = b.node(.fractalSum, ["scale": .int(5), "octaves": .int(7), "roughness": .float(0.6)])
        let mix = b.node(.blend, ["mode": .choice("multiply")], ["fg": clouds, "bg": grime])
        let rust = b.node(.histogramScan, ["position": .float(0.62), "contrast": .float(0.8)], ["in": mix])
        let flake = b.node(.edgeDetect, ["width": .float(3), "threshold": .float(0.5)], ["in": rust])
        let rustColor = b.node(.gradientMap, ["gradient": gradient((0, [0.25, 0.1, 0.05]), (0.5, [0.48, 0.2, 0.08]), (1, [0.7, 0.38, 0.15]))], ["in": clouds])
        let paint = b.node(.uniformColor, ["color": rgb(0.18, 0.45, 0.47)])
        let worn = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.25)], ["fg": grime, "bg": paint])
        let steel = b.node(.uniformColor, ["color": rgb(0.62, 0.62, 0.64)])
        let painted = b.node(.blend, ["mode": .choice("copy")], ["fg": rustColor, "bg": worn, "mask": rust])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": steel, "bg": painted, "mask": flake])
        let height = b.node(.blend, ["mode": .choice("add"), "opacity": .float(0.3)], ["fg": clouds, "bg": rust])
        b.output(.baseColor, color)
        b.output(.metallic, flake)
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.38), "outHigh": .float(0.9)], ["in": rust]))
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(2)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.01 }
        return b.graph
    }

    /// Steel brushed one way, a few scratches across.
    static func brushedSteel() -> MaterialGraph {
        var b = MatBuilder("Brushed Steel")
        let brushed = b.node(.anisotropicNoise, ["scaleX": .int(2), "scaleY": .int(400), "smoothness": .float(1)])
        let fine = b.node(.anisotropicNoise, ["scaleX": .int(8), "scaleY": .int(900), "smoothness": .float(1), "seed": .int(3)])
        let streaks = b.node(.blend, ["mode": .choice("overlay"), "opacity": .float(0.6)], ["fg": fine, "bg": brushed])
        let scratches = b.node(.scratches, ["count": .int(2), "length": .float(0.35), "width": .float(0.0015), "angleRandom": .float(0.3)])
        let steel = b.node(.gradientMap, ["gradient": gradient((0, [0.68, 0.69, 0.7]), (1, [0.86, 0.87, 0.88]))], ["in": streaks])
        let rough = b.node(.levels, ["outLow": .float(0.22), "outHigh": .float(0.34)], ["in": streaks])
        let roughness = b.node(.blend, ["mode": .choice("lighten"), "opacity": .float(0.6)], ["fg": scratches, "bg": rough])
        b.output(.baseColor, steel)
        b.output(.metallic, b.node(.uniform, ["value": .float(1)]))
        b.output(.roughness, roughness)
        let height = b.node(.blend, ["mode": .choice("subtract"), "opacity": .float(0.5)], ["fg": scratches, "bg": streaks])
        b.output(.normal, b.node(.normal, ["intensity": .float(0.4)], ["in": height]))
        b.set { $0.surface.heightDepth = 0 }
        return b.graph
    }

    /// Copper, scratched bright, gone green (verdigris) in its hollows.
    static func scratchedCopper() -> MaterialGraph {
        var b = MatBuilder("Scratched Copper")
        let clouds = b.node(.fractalSum, ["scale": .int(4), "octaves": .int(7), "roughness": .float(0.55)])
        let grime = b.node(.grunge, ["scale": .int(4), "contrast": .float(0.8), "spots": .float(0.3)])
        let patina = b.node(.histogramScan, ["position": .float(0.3), "contrast": .float(0.7)], ["in": grime])
        let scratches = b.node(.scratches, ["count": .int(4), "length": .float(0.2), "width": .float(0.002), "angleRandom": .float(1)])
        let copper = b.node(.gradientMap, ["gradient": gradient((0, [0.78, 0.45, 0.32]), (1, [0.95, 0.66, 0.52]))], ["in": clouds])
        let green = b.node(.gradientMap, ["gradient": gradient((0, [0.22, 0.45, 0.38]), (1, [0.42, 0.66, 0.55]))], ["in": clouds])
        let bright = b.node(.blend, ["mode": .choice("screen"), "opacity": .float(0.5)], ["fg": scratches, "bg": copper])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": green, "bg": bright, "mask": patina])
        b.output(.baseColor, color)
        b.output(.metallic, b.node(.invert, [:], ["in": patina]))
        let rough = b.node(.levels, ["outLow": .float(0.25), "outHigh": .float(0.85)], ["in": patina])
        b.output(.roughness, b.node(.blend, ["mode": .choice("subtract"), "opacity": .float(0.15)], ["fg": scratches, "bg": rough]))
        let height = b.node(.blend, ["mode": .choice("subtract"), "opacity": .float(0.4)], ["fg": scratches, "bg": clouds])
        b.output(.normal, b.node(.normal, ["intensity": .float(0.8)], ["in": height]))
        b.set { $0.surface.heightDepth = 0 }
        return b.graph
    }

    /// Oak boards: each its own shade, the grain running along them, their joints dark.
    static func oakPlanks() -> MaterialGraph {
        var b = MatBuilder("Oak Planks")
        let boards = b.node(.bricks, ["columns": .int(2), "rows": .int(6), "offset": .float(0.35), "gap": .float(0.003), "bevel": .float(0.06),
                                      "heightRandom": .float(0.05)])
        let wobble = b.node(.fractalSum, ["scale": .int(2), "octaves": .int(4), "roughness": .float(0.5)])
        let grain = b.node(.anisotropicNoise, ["scaleX": .int(3), "scaleY": .int(160), "smoothness": .float(1)])
        let rings = b.node(.waves, ["frequency": .int(24), "angle": .float(0.25), "wave": .choice("sine")])
        let warped = b.node(.warp, ["intensity": .float(0.03)], ["in": rings, "gradient": wobble])
        let wood = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.6)], ["fg": warped, "bg": grain])
        let tone = b.node(.gradientMap, ["gradient": gradient((0, [0.36, 0.22, 0.12]), (0.6, [0.58, 0.39, 0.22]), (1, [0.72, 0.53, 0.33]))], ["in": wood])
        let shade = b.node(.levels, ["outLow": .float(0.7), "outHigh": .float(1)], ["in": boards["random"]])
        let shaded = b.node(.blend, ["mode": .choice("multiply")], ["fg": shade, "bg": tone])
        let joints = b.node(.histogramScan, ["position": .float(0.98), "contrast": .float(0.95), "invert": .bool(true)], ["in": boards])
        let dark = b.node(.uniformColor, ["color": rgb(0.12, 0.08, 0.05)])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": dark, "bg": shaded, "mask": joints])
        let height = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.15)], ["fg": wood, "bg": boards])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.65), "outHigh": .float(0.45)], ["in": wood]))
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(2)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.015 }
        return b.graph
    }

    /// Furrowed bark, moss on its ridges.
    static func barkAndMoss() -> MaterialGraph {
        var b = MatBuilder("Bark and Moss")
        let furrows = b.node(.anisotropicNoise, ["scaleX": .int(12), "scaleY": .int(3), "smoothness": .float(0.8)])
        let ridges = b.node(.fractalSum, ["scale": .int(4), "octaves": .int(6), "roughness": .float(0.5), "mode": .choice("ridged")])
        let bark = b.node(.blend, ["mode": .choice("multiply")], ["fg": ridges, "bg": furrows])
        let height = b.node(.levels, ["inLow": .float(0.05), "inHigh": .float(0.7)], ["in": bark])
        let clumps = b.node(.grunge, ["scale": .int(5), "contrast": .float(0.6), "spots": .float(0)])
        let mossy = b.node(.blend, ["mode": .choice("multiply")], ["fg": clumps, "bg": height])
        let moss = b.node(.histogramScan, ["position": .float(0.42), "contrast": .float(0.7)], ["in": mossy])
        let barkColor = b.node(.gradientMap, ["gradient": gradient((0, [0.1, 0.07, 0.05]), (0.6, [0.3, 0.22, 0.16]), (1, [0.45, 0.36, 0.27]))], ["in": height])
        let mossColor = b.node(.gradientMap, ["gradient": gradient((0, [0.2, 0.3, 0.08]), (1, [0.38, 0.52, 0.14]))], ["in": clumps])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": mossColor, "bg": barkColor, "mask": moss])
        let raised = b.node(.blend, ["mode": .choice("add"), "opacity": .float(0.15)], ["fg": moss, "bg": height])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.uniform, ["value": .float(0.9)]))
        b.output(.height, raised)
        b.output(.normal, b.node(.normal, ["intensity": .float(5)], ["in": raised]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.03), "depth": .float(0.06)], ["in": raised]))
        b.set { $0.surface.heightDepth = 0.06 }
        return b.graph
    }

    /// Dark metal panels, inset, with glowing cyan strips between them.
    static func scifiPanels() -> MaterialGraph {
        var b = MatBuilder("Sci-fi Panels")
        let panels = b.node(.bricks, ["columns": .int(3), "rows": .int(4), "offset": .float(0), "gap": .float(0.012), "bevel": .float(0.08),
                                      "heightRandom": .float(0.15)])
        let strips = b.node(.waves, ["frequency": .int(4), "wave": .choice("square"), "angle": .float(0.25)])
        let thin = b.node(.edgeDetect, ["width": .float(2), "threshold": .float(0.5)], ["in": strips])
        let gaps = b.node(.histogramScan, ["position": .float(0.97), "contrast": .float(0.9), "invert": .bool(true)], ["in": panels])
        let glow = b.node(.blend, ["mode": .choice("multiply")], ["fg": thin, "bg": gaps])
        let grime = b.node(.grunge, ["scale": .int(4), "contrast": .float(0.4), "spots": .float(0.2)])
        let plate = b.node(.gradientMap, ["gradient": gradient((0, [0.16, 0.17, 0.19]), (1, [0.34, 0.36, 0.39]))], ["in": panels["random"]])
        let worn = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.35)], ["fg": grime, "bg": plate])
        let cyan = b.node(.gradientMap, ["gradient": gradient((0, [0, 0, 0]), (1, [0.3, 0.9, 1]))], ["in": glow])
        b.output(.baseColor, worn)
        b.output(.metallic, b.node(.uniform, ["value": .float(0.85)]))
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.3), "outHigh": .float(0.55)], ["in": grime]))
        b.output(.height, panels)
        b.output(.normal, b.node(.normal, ["intensity": .float(3)], ["in": panels]))
        b.output(.emissive, cyan)
        b.set { $0.surface.heightDepth = 0.02; $0.surface.emissiveIntensity = 6 }
        return b.graph
    }
}

/// Where the editor draws a graph's nodes, in the graph's units: a node a box of its header, its thumbnail, its
/// inputs (left) and outputs (right). A graph never laid out (every node at the origin: the built-in ones) is
/// arranged in columns by how far each node is from the graph's sources.
enum MatLayout {
    static let nodeWidth: CGFloat = 150
    static let header: CGFloat = 22
    static let thumb: CGFloat = 112
    static let row: CGFloat = 16
    static let gap: CGFloat = 6
    static let columnSpacing: Float = 210

    static func height(inputs: Int, outputs: Int) -> CGFloat { header + thumb + CGFloat(max(inputs, outputs, 1)) * row + gap }

    /// `g` with its nodes placed, if it was never laid out.
    static func arranged(_ g: MaterialGraph) -> MaterialGraph {
        guard g.nodes.count > 1, g.nodes.allSatisfy({ $0.at == .zero }) else { return g }
        var out = g
        var depth: [String: Int] = [:]
        func d(_ id: String, _ seen: Set<String>) -> Int {
            if let k = depth[id] { return k }
            let feeds = g.links.filter { $0.to == id }.map(\.from).filter { !seen.contains($0) }
            let k = feeds.isEmpty ? 0 : 1 + (feeds.map { d($0, seen.union([id])) }.max() ?? 0)
            depth[id] = k
            return k
        }
        var columnY: [Int: Float] = [:]
        for i in out.nodes.indices {
            let k = d(out.nodes[i].id, [])
            let y = columnY[k] ?? 0
            out.nodes[i].at = SIMD2(Float(k) * columnSpacing, y)
            let spec = out.nodes[i].kind.spec
            columnY[k] = y + Float(height(inputs: spec.inputs.count, outputs: spec.outputs.count)) + 24
        }
        return out
    }
}
