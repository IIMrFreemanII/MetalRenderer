import Foundation
import simd

/// What a pin takes: a grey image, a colour one, or either (the node's outputs then follow what is wired: colour if
/// any of its `any` inputs gets colour). A colour wired into a grey pin is its luminance; a grey into a colour pin, its
/// grey in R, G and B.
enum MatPinType: String {
    case grey, color, any
}

/// An image input: its name (the links'), its title, what it takes, and whether the node works without it.
struct MatInputSpec {
    let name: String
    let title: String
    let type: MatPinType
    var optional = false

    init(_ name: String, _ title: String? = nil, _ type: MatPinType = .any, optional: Bool = false) {
        self.name = name
        self.title = title ?? name.capitalized
        self.type = type
        self.optional = optional
    }
}

/// A parameter: its name (the key of `params`), its title, its default, a slider's span and a choice's choices.
/// Packed for the kernels in the spec's order, one float4 a parameter (MatPlan.pack).
struct MatParamSpec {
    let name: String
    let title: String
    let value: MatParam
    var span: ClosedRange<Float>?
    var choices: [String] = []

    init(_ name: String, _ title: String, _ value: MatParam, span: ClosedRange<Float>? = nil, choices: [String] = []) {
        self.name = name
        self.title = title
        self.value = value
        self.span = span
        self.choices = choices
    }
}

/// How a node reads its inputs, which decides how it is baked and whether the shading can run it as code
/// (MatShaderCode): from the pixel's UV alone (a generator), its inputs at the same pixel (point-wise), at another
/// place (resample: a transform, a warp), at a few places around (a neighbourhood: `taps` of them), or anywhere, over
/// passes (global: a blur, a distance, a flood fill: baked only).
enum MatShape: Equatable {
    case generator
    case pointwise
    case resample
    case neighbourhood(taps: Int)
    case global

    /// What evaluating it costs the shading, in input evaluations (for MatShaderCode's budget); nil: it can't.
    var shaderTaps: Int? {
        switch self {
        case .generator, .pointwise, .resample: return 1
        case .neighbourhood(let t): return t
        case .global: return nil
        }
    }
}

/// The node families (the library's sections; the editor colours the headers by them).
enum MatFamily: String, CaseIterable {
    case graph = "Graph", noise = "Noises", pattern = "Patterns", adjust = "Adjustments", blend = "Blending",
         filter = "Filters", height = "Height & Normal", advanced = "Advanced"
}

struct MatOpSpec {
    let title: String
    let family: MatFamily
    let inputs: [MatInputSpec]
    /// Its outputs: a fixed type, or `.any`: its `any` inputs' (grey without them, unless `anyDefault`).
    let outputs: [(name: String, type: MatPinType)]
    let params: [MatParamSpec]
    let shape: MatShape
    /// What an `any` output is when nothing decides it.
    var anyDefault = MatType.grey
    let summary: String

    func param(_ name: String) -> MatParamSpec? { params.first { $0.name == name } }
    func input(_ name: String) -> MatInputSpec? { inputs.first { $0.name == name } }
}

/// The blend modes, in the order the kernel numbers them (Shaders: matBlend).
enum MatBlendMode: String, CaseIterable {
    case copy, add, subtract, multiply, screen, overlay, softLight, hardLight, darken, lighten, difference, divide,
         colorDodge, colorBurn, linearLight, exclusion
}

/// The nodes. Their kernels are MaterialShaders/*.metal, `mat_<kind>`, reading their parameters in the spec's order.
enum MatOpKind: String, Codable, CaseIterable {
    // Graph
    case input, output, subgraph, uniform, uniformColor, bitmap, meshMap
    // Noises
    case whiteNoise, valueNoise, perlinNoise, fractalSum, cells, anisotropicNoise, scratches, grunge, fibers
    // Patterns
    case shape, gradient, checker, bricks, waves, tileSampler
    // Adjustments
    case levels, curve, gradientMap, hsl, invert, grayscale, histogramScan, posterize, rgbaSplit, rgbaMerge
    // Blending
    case blend, heightBlend
    // Filters
    case transform, mirror, warp, directionalWarp, blur, directionalBlur, slopeBlur, edgeDetect
    // Height & Normal
    case normal, normalCombine, ambientOcclusion, curvature
    // Advanced
    case distance, bevel, floodFill, autoLevels, pixelProcessor, code

    var spec: MatOpSpec {
        typealias P = MatParamSpec
        typealias I = MatInputSpec
        let seed = P("seed", "Seed", .int(0), span: 0...100)
        func f(_ name: String, _ title: String, _ v: Float, _ span: ClosedRange<Float>) -> P { P(name, title, .float(v), span: span) }
        func i(_ name: String, _ title: String, _ v: Int, _ span: ClosedRange<Float>) -> P { P(name, title, .int(v), span: span) }
        func c(_ name: String, _ title: String, _ choices: [String]) -> P { P(name, title, .choice(choices[0]), choices: choices) }
        func spec(_ title: String, _ family: MatFamily, _ inputs: [I] = [], _ outputs: [(String, MatPinType)] = [("out", .grey)],
                  _ params: [P] = [], _ shape: MatShape = .pointwise, any: MatType = .grey, _ summary: String) -> MatOpSpec {
            MatOpSpec(title: title, family: family, inputs: inputs, outputs: outputs.map { (name: $0.0, type: $0.1) }, params: params,
                      shape: shape, anyDefault: any, summary: summary)
        }
        switch self {
        case .input:
            return spec("Input", .graph, [], [("out", .any)],
                        [P("value", "Default", .color([0.5, 0.5, 0.5, 1])), c("type", "Type", ["grey", "color"]), P("name", "Name", .text("input"))],
                        .generator, "A subgraph's image input (its node's pin); its default when nothing is wired.")
        case .output:
            return spec("Output", .graph, [I("in", "In")], [("out", .any)],
                        [c("usage", "Usage", ["baseColor", "normal", "roughness", "metallic", "ambientOcclusion", "height", "opacity", "emissive", "none"]),
                         P("name", "Name", .text("output"))],
                        .pointwise, "A channel of the material (base colour, normal, roughness...), or a subgraph's output.")
        case .subgraph:
            return spec("Subgraph", .graph, [], [], [P("graph", "Graph", .text(""))], .global,
                        "Another graph as a node: its inputs and outputs are its pins, its exposed parameters its own.")
        case .uniform:
            return spec("Uniform Grey", .graph, [], [("out", .grey)], [f("value", "Value", 0.5, 0...1)], .generator, "One grey everywhere.")
        case .uniformColor:
            return spec("Uniform Colour", .graph, [], [("out", .color)], [P("color", "Colour", .color([0.5, 0.5, 0.5, 1]))], .generator,
                        "One colour everywhere.")
        case .bitmap:
            return spec("Bitmap", .graph, [], [("out", .color)], [P("path", "File", .text("")), c("channel", "As", ["color", "luminance"])], .global,
                        "An image file (PNG, JPEG, EXR), stretched over the tile.")

        case .meshMap:
            return spec("Mesh Map", .graph, [], [("out", .color)],
                        [c("map", "Map", ["curvature", "occlusion", "thickness", "position", "normal", "height"]),
                         P("context", "Object", .text(""))], .global,
                        "A painted object's bake (Material Painter): its curvature, occlusion, thickness, position, normal or height "
                        + "over its texture set; a neutral grey outside the painter.")

        case .whiteNoise:
            return spec("White Noise", .noise, [], [("out", .grey)], [seed], .generator, "A random grey a pixel.")
        case .valueNoise:
            return spec("Value Noise", .noise, [], [("out", .grey)], [i("scale", "Scale", 8, 1...64), seed], .generator,
                        "Random greys on a grid of `scale` cells, smoothly between.")
        case .perlinNoise:
            return spec("Perlin Noise", .noise, [], [("out", .grey)], [i("scale", "Scale", 8, 1...64), f("disorder", "Disorder", 0, 0...1), seed],
                        .generator, "Gradient noise, tiling, `scale` cells across.")
        case .fractalSum:
            return spec("Fractal Sum", .noise, [], [("out", .grey)],
                        [i("scale", "Scale", 4, 1...32), i("octaves", "Octaves", 6, 1...10), f("roughness", "Roughness", 0.5, 0...1),
                         c("mode", "Mode", ["fbm", "ridged", "turbulence", "billow"]), seed],
                        .generator, "Octaves of Perlin noise summed: clouds (fbm), ridges, turbulence, billows.")
        case .cells:
            return spec("Cells", .noise, [], [("out", .grey)],
                        [i("scale", "Scale", 8, 1...64), f("jitter", "Jitter", 1, 0...1), c("mode", "Mode", ["f1", "f2", "borders", "cellValue", "crystal"]), seed],
                        .generator, "Worley noise: the distance to the nearest point (F1), the second nearest, the cells' borders, a grey a cell.")
        case .anisotropicNoise:
            return spec("Anisotropic Noise", .noise, [], [("out", .grey)],
                        [i("scaleX", "Scale X", 4, 1...64), i("scaleY", "Scale Y", 128, 1...512), f("smoothness", "Smoothness", 1, 0...1), seed],
                        .generator, "Value noise stretched along X: brushed metal, wood grain.")
        case .scratches:
            return spec("Scratches", .noise, [], [("out", .grey)],
                        [i("count", "Per Cell", 3, 1...16), f("length", "Length", 0.25, 0.01...1), f("width", "Width", 0.003, 0.0005...0.03),
                         f("angle", "Angle", 0, 0...1), f("angleRandom", "Angle Random", 1, 0...1), f("intensityRandom", "Intensity Random", 0.6, 0...1),
                         i("scale", "Cells", 6, 1...32), seed],
                        .generator, "Thin random lines, each a segment in a cell of a grid.")
        case .grunge:
            return spec("Grunge", .noise, [], [("out", .grey)],
                        [i("scale", "Scale", 4, 1...32), f("contrast", "Contrast", 0.6, 0...1), f("spots", "Spots", 0.5, 0...1), seed],
                        .generator, "Dirt: fractal noise broken up by cells and spots.")
        case .fibers:
            return spec("Fibers", .noise, [], [("out", .grey)],
                        [i("count", "Per Cell", 4, 1...16), f("length", "Length", 0.3, 0.01...1), f("width", "Width", 0.006, 0.0005...0.05),
                         f("angle", "Angle", 0.25, 0...1), f("angleRandom", "Angle Random", 0.2, 0...1), f("curvature", "Curvature", 0.15, -1...1),
                         f("intensityRandom", "Intensity Random", 0.5, 0...1), i("scale", "Cells", 6, 1...32), seed],
                        .generator, "Curved strands, rounded across, their ends tapered: straw, grass, bark fibre, twigs.")

        case .shape:
            return spec("Shape", .pattern, [], [("out", .grey)],
                        [c("kind", "Shape", ["square", "disc", "polygon", "star", "bell", "cone", "pyramid", "paraboloid", "hemisphere", "ring", "leaf", "blade"]),
                         f("size", "Size", 0.8, 0...1), i("sides", "Sides", 6, 3...12), f("softness", "Softness", 0.01, 0...0.5),
                         f("angle", "Angle", 0, 0...1), i("tiling", "Tiling", 1, 1...16)],
                        .generator, "A shape in the middle of the tile (or a grid of them).")
        case .gradient:
            return spec("Gradient", .pattern, [], [("out", .grey)],
                        [c("mode", "Mode", ["linear", "radial", "angular", "diamond", "axial"]), f("angle", "Angle", 0, 0...1), i("repeats", "Repeats", 1, 1...16)],
                        .generator, "A ramp from black to white.")
        case .checker:
            return spec("Checker", .pattern, [], [("out", .grey)], [i("tiles", "Tiles", 8, 1...64)], .generator, "Black and white squares.")
        case .bricks:
            return spec("Bricks", .pattern, [], [("out", .grey), ("random", .grey)],
                        [i("columns", "Columns", 4, 1...32), i("rows", "Rows", 8, 1...64), f("offset", "Row Offset", 0.5, 0...1),
                         f("gap", "Gap", 0.02, 0...0.2), f("bevel", "Bevel", 0.15, 0...1), f("heightRandom", "Height Random", 0.3, 0...1),
                         f("roundness", "Roundness", 0, 0...1), seed],
                        .generator, "Bricks in rows: their height (bevelled, each its own), and a random grey a brick.")
        case .waves:
            return spec("Waves", .pattern, [], [("out", .grey)],
                        [i("frequency", "Frequency", 8, 1...64), f("angle", "Angle", 0, 0...1), c("wave", "Wave", ["sine", "triangle", "square", "saw"])],
                        .generator, "Parallel waves across the tile.")
        case .tileSampler:
            return spec("Tile Sampler", .pattern, [I("pattern", "Pattern", .any, optional: true)], [("out", .any)],
                        [i("columns", "Columns", 8, 1...64), i("rows", "Rows", 8, 1...64),
                         c("kind", "Shape", ["disc", "square", "bell", "pyramid", "hemisphere"]),
                         f("size", "Size", 0.8, 0...2), f("sizeRandom", "Size Random", 0.2, 0...1), f("positionRandom", "Position Random", 0.3, 0...1),
                         f("rotation", "Rotation", 0, 0...1), f("rotationRandom", "Rotation Random", 0, 0...1), f("lumRandom", "Grey Random", 0.4, 0...1),
                         f("rowOffset", "Row Offset", 0, 0...1), c("blend", "Blend", ["max", "add"]), seed],
                        .neighbourhood(taps: 9), "Copies of a pattern (or a shape) on a grid, each moved, turned, scaled and darkened at random.")

        case .levels:
            return spec("Levels", .adjust, [I("in", "In")], [("out", .any)],
                        [f("inLow", "In Low", 0, 0...1), f("inHigh", "In High", 1, 0...1), f("gamma", "Midtones", 1, 0.1...4),
                         f("outLow", "Out Low", 0, 0...1), f("outHigh", "Out High", 1, 0...1)],
                        .pointwise, "Remaps the values: the input's range to the output's, with a gamma between.")
        case .curve:
            return spec("Curve", .adjust, [I("in", "In")], [("out", .any)], [P("curve", "Curve", .curve(VFXCurve(from: 0, to: 1)))], .pointwise,
                        "Remaps the values through a curve.")
        case .gradientMap:
            return spec("Gradient Map", .adjust, [I("in", "In", .grey)], [("out", .color)],
                        [P("gradient", "Gradient", .gradient(VFXGradient([.init(0, [0, 0, 0, 1]), .init(1, [1, 1, 1, 1])])))], .pointwise,
                        "A grey to a colour, through a gradient.")
        case .hsl:
            return spec("HSL", .adjust, [I("in", "In", .color)], [("out", .color)],
                        [f("hue", "Hue", 0, -0.5...0.5), f("saturation", "Saturation", 0, -1...1), f("lightness", "Lightness", 0, -1...1)],
                        .pointwise, "Shifts the hue, saturation and lightness.")
        case .invert:
            return spec("Invert", .adjust, [I("in", "In")], [("out", .any)], [], .pointwise, "1 − the value (not alpha).")
        case .grayscale:
            return spec("Grayscale", .adjust, [I("in", "In", .color)], [("out", .grey)],
                        [c("mode", "From", ["luminance", "average", "red", "green", "blue", "alpha"])], .pointwise, "A colour to a grey.")
        case .histogramScan:
            return spec("Histogram Scan", .adjust, [I("in", "In", .grey)], [("out", .grey)],
                        [f("position", "Position", 0.5, 0...1), f("contrast", "Contrast", 0.5, 0...1), P("invert", "Invert", .bool(false))],
                        .pointwise, "A threshold that can be soft: a mask from the greys above `position`.")
        case .posterize:
            return spec("Posterize", .adjust, [I("in", "In")], [("out", .any)], [i("steps", "Steps", 4, 2...64)], .pointwise, "Values in steps.")
        case .rgbaSplit:
            return spec("RGBA Split", .adjust, [I("in", "In", .color)], [("r", .grey), ("g", .grey), ("b", .grey), ("a", .grey)], [], .pointwise,
                        "A colour's four channels as greys.")
        case .rgbaMerge:
            return spec("RGBA Merge", .adjust,
                        [I("r", "R", .grey, optional: true), I("g", "G", .grey, optional: true), I("b", "B", .grey, optional: true), I("a", "A", .grey, optional: true)],
                        [("out", .color)], [P("fill", "Unwired", .color([0, 0, 0, 1]))], .pointwise, "Four greys as a colour's channels.")

        case .blend:
            return spec("Blend", .blend, [I("fg", "Foreground"), I("bg", "Background"), I("mask", "Mask", .grey, optional: true)], [("out", .any)],
                        [c("mode", "Mode", MatBlendMode.allCases.map(\.rawValue)), f("opacity", "Opacity", 1, 0...1)], .pointwise,
                        "The foreground over the background: a blend mode, its opacity, a mask.")
        case .heightBlend:
            return spec("Height Blend", .blend, [I("top", "Top", .grey), I("bottom", "Bottom", .grey), I("mask", "Mask", .grey, optional: true)],
                        [("out", .grey), ("mask", .grey)],
                        [f("offset", "Height Offset", 0.5, 0...1), f("contrast", "Contrast", 0.9, 0...1)], .pointwise,
                        "Two heights joined where the higher one wins (softly), and the mask of where the top shows.")

        case .transform:
            return spec("Transform", .filter, [I("in", "In")], [("out", .any)],
                        [P("offset", "Offset", .vec2(.zero)), f("rotation", "Rotation", 0, 0...1), P("scale", "Tiling", .vec2([1, 1]))],
                        .resample, "Moves, turns and tiles the input (it wraps).")
        case .mirror:
            return spec("Mirror", .filter, [I("in", "In")], [("out", .any)], [c("axis", "Axis", ["x", "y", "both"])], .resample,
                        "The input mirrored about the tile's middle.")
        case .warp:
            return spec("Warp", .filter, [I("in", "In"), I("gradient", "Gradient", .grey)], [("out", .any)],
                        [f("intensity", "Intensity", 0.05, 0...1)], .neighbourhood(taps: 5), "Pushes the input along the slopes of another image.")
        case .directionalWarp:
            return spec("Directional Warp", .filter, [I("in", "In"), I("intensity", "Intensity", .grey)], [("out", .any)],
                        [f("amount", "Amount", 0.05, 0...1), f("angle", "Angle", 0, 0...1)], .resample,
                        "Pushes the input one way, by how bright another image is.")
        case .blur:
            return spec("Blur", .filter, [I("in", "In")], [("out", .any)], [f("radius", "Radius", 4, 0...64)], .global,
                        "Gaussian blur, `radius` pixels.")
        case .directionalBlur:
            return spec("Directional Blur", .filter, [I("in", "In")], [("out", .any)],
                        [f("radius", "Length", 0.02, 0...0.25), f("angle", "Angle", 0, 0...1)], .neighbourhood(taps: 16), "Motion blur one way.")
        case .slopeBlur:
            return spec("Slope Blur", .filter, [I("in", "In"), I("slope", "Slope", .grey)], [("out", .any)],
                        [i("samples", "Samples", 8, 1...32), f("intensity", "Intensity", 0.03, -0.25...0.25), c("mode", "Mode", ["blur", "min", "max"])],
                        .global, "Smears the input along the slopes of another image: erosion, drips.")
        case .edgeDetect:
            return spec("Edge Detect", .filter, [I("in", "In", .grey)], [("out", .grey)],
                        [f("width", "Width", 1, 0.5...16), f("threshold", "Threshold", 0.5, 0...1)], .neighbourhood(taps: 9),
                        "The edges of a mask.")

        case .normal:
            return spec("Normal", .height, [I("in", "Height", .grey)], [("out", .color)],
                        [f("intensity", "Intensity", 4, 0...32), P("directX", "DirectX (Y down)", .bool(false))], .neighbourhood(taps: 4),
                        "A tangent-space normal map from a height.")
        case .normalCombine:
            return spec("Normal Combine", .height, [I("base", "Base", .color), I("detail", "Detail", .color)], [("out", .color)], [], .pointwise,
                        "A detail normal map over a base one (whiteout).")
        case .ambientOcclusion:
            return spec("Ambient Occlusion", .height, [I("in", "Height", .grey)], [("out", .grey)],
                        [f("radius", "Radius", 0.04, 0.002...0.25), f("depth", "Height Depth", 0.04, 0...0.5), i("quality", "Directions", 8, 4...16)],
                        .global, "How much of the sky each point of a height sees.")
        case .curvature:
            return spec("Curvature", .height, [I("in", "Height", .grey)], [("out", .grey)], [f("intensity", "Intensity", 4, 0...64)],
                        .neighbourhood(taps: 5), "Convex white, concave black, flat grey: edges and crevices.")

        case .distance:
            return spec("Distance", .advanced, [I("in", "Mask", .grey)], [("out", .grey)],
                        [f("distance", "Max Distance", 0.1, 0.001...1), f("threshold", "Threshold", 0.5, 0...1)], .global,
                        "How far each pixel is from the mask (white on it, black `distance` away).")
        case .bevel:
            return spec("Bevel", .advanced, [I("in", "Mask", .grey)], [("out", .grey)],
                        [f("distance", "Distance", 0.03, 0.001...0.5), f("smoothing", "Smoothing", 0.5, 0...1), f("threshold", "Threshold", 0.5, 0...1)],
                        .global, "A mask's shapes as heights, sloped `distance` in from their edges.")
        case .floodFill:
            return spec("Flood Fill", .advanced, [I("in", "Mask", .grey)], [("random", .grey), ("gradient", .grey), ("position", .color), ("size", .color)],
                        [f("threshold", "Threshold", 0.5, 0...1), f("angleRandom", "Gradient Angle Random", 1, 0...1), seed], .global,
                        "Each shape of a mask on its own: a random grey, a gradient across it, its centre (RG), its size (RG).")
        case .autoLevels:
            return spec("Auto Levels", .advanced, [I("in", "In", .grey)], [("out", .grey)], [], .global, "The darkest grey to black, the lightest to white.")
        case .pixelProcessor:
            return spec("Pixel Processor", .advanced,
                        [I("in0", "In 0", .any, optional: true), I("in1", "In 1", .any, optional: true), I("in2", "In 2", .any, optional: true),
                         I("in3", "In 3", .any, optional: true)],
                        [("out", .any)], [c("mode", "Output", ["color", "grey"])], .resample, any: .color,
                        "A function of the pixel (its position, the inputs sampled anywhere), as a graph of math nodes.")
        case .code:
            return spec("Code", .advanced,
                        [I("in0", "In 0", .any, optional: true), I("in1", "In 1", .any, optional: true), I("in2", "In 2", .any, optional: true),
                         I("in3", "In 3", .any, optional: true)],
                        [("out", .any)],
                        [c("mode", "Output", ["color", "grey"]), f("a", "a", 0, 0...1), f("b", "b", 0, 0...1), f("c", "c", 0, 0...1), f("d", "d", 0, 0...1),
                         P("code", "Metal", .text("return sampleInput(0, uv);"))],
                        .resample, any: .color,
                        "Metal: the body of `float4 f(float2 uv)`, with sampleInput(i, uv), a, b, c, d, size and seed.")
        }
    }

    /// The kernel that bakes it (MaterialShaders/*.metal).
    var kernel: String { "mat_" + rawValue }
}
