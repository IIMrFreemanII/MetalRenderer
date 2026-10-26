import Foundation
import simd

/// Every kind of node, by Houdini's type names where there is one. `spec` says what each is; `cook`
/// (ProcNodeKind+Cook.swift) makes its geometry.
package enum ProcNodeKind: String, Codable, CaseIterable, Identifiable {
    // Generate
    case box, grid, sphere, tube, torus, circle, line, add, file
    // Transform & combine
    case transform, merge, copyxform, mirror
    // Polygon
    case polyextrude, subdivide, boolean, polybevel, polyreduce, divide, fuse, clean, facet, normal, reverse, smooth,
         thicken, uvunwrap
    // Attribute
    case attribcreate, attribdelete, attribrename, attribrandomize, attribnoise, attribpromote, color, measure,
         connectivity, sort
    // Scatter & copy
    case scatter, copytopoints, attribtransfer, ray, pointjitter, voronoifracture
    // Curve
    case curve, resample, sweep, revolve, polywire, carve, ends, lsystem
    // Group
    case groupcreate, blast
    // Utility
    case null, output, switchnode = "switch", attribwrangle, foreachbegin, foreachend

    package var id: String { rawValue }

    package var spec: ProcNodeSpec { ProcNodeKind.specs[self]! }

    private static let specs: [ProcNodeKind: ProcNodeSpec] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeSpec()) })

    private static let classes2: [AttributeClass] = [.point, .primitive]
    private static func onlyFor(_ param: String, _ values: String...) -> ProcParamSpec.Condition {
        ProcParamSpec.Condition(param: param, values: values)
    }

    // swiftlint:disable:next function_body_length
    private func makeSpec() -> ProcNodeSpec {
        typealias P = ProcParamSpec
        let orient = P.menu("orient", "Orientation", ["ZX", "XY", "YZ"])
        let center = P.vec3("t", "Center", .zero)
        let pointsOrPrims = P.menu("grouptype", "Group Type", ["primitives", "points"])
        switch self {
        // MARK: Generate
        case .box:
            return ProcNodeSpec("Box", .generate, "box", symbol: "cube", params: [
                P.vec3("size", "Size", [1, 1, 1]), center, P.float("scale", "Uniform Scale", 1, 0...10),
                P.vec3("divs", "Divisions", [1, 1, 1]),
            ], "A box of polygons, each side split into divisions.")
        case .grid:
            return ProcNodeSpec("Grid", .generate, "grid", symbol: "square.grid.3x3", params: [
                orient, P.vec2("size", "Size", [10, 10]), center,
                P.int("rows", "Rows", 10, 2...100), P.int("cols", "Columns", 10, 2...100),
            ], "A flat grid of quads: rows and columns of points.")
        case .sphere:
            return ProcNodeSpec("Sphere", .generate, "sphere", symbol: "globe", params: [
                P.menu("type", "Primitive Type", ["polygon", "ico", "quad"]),
                P.vec3("rad", "Radius", [1, 1, 1]), center, P.float("scale", "Uniform Scale", 1, 0...10),
                P.int("rows", "Rows", 13, 3...100, when: ProcNodeKind.onlyFor("type", "polygon")),
                P.int("cols", "Columns", 24, 3...100, when: ProcNodeKind.onlyFor("type", "polygon")),
                P.int("freq", "Frequency", 2, 0...6, when: ProcNodeKind.onlyFor("type", "ico", "quad")),
            ], "A sphere: rings of quads (polygon), an icosphere, or a cube pushed round (quad).")
        case .tube:
            return ProcNodeSpec("Tube", .generate, "tube", symbol: "cylinder", params: [
                P.vec2("rad", "Radius (top, bottom)", [1, 1]), P.float("height", "Height", 1, 0...10), center,
                P.int("rows", "Rows", 2, 2...100), P.int("cols", "Columns", 12, 3...100), P.bool("caps", "End Caps", true),
            ], "A tube along Y; with caps, a cylinder (a cone if a radius is 0).")
        case .torus:
            return ProcNodeSpec("Torus", .generate, "torus", symbol: "circle.circle", params: [
                P.vec2("rad", "Radius", [1, 0.5]), center, P.int("rows", "Rows", 12, 3...100), P.int("cols", "Columns", 24, 3...100),
            ], "A ring of quads round Y.")
        case .circle:
            return ProcNodeSpec("Circle", .generate, "circle", symbol: "circle", params: [
                P.menu("arc", "Arc Type", ["closed", "open", "sliced"]), orient, P.vec2("rad", "Radius", [1, 1]), center,
                P.int("divs", "Divisions", 12, 3...100), P.float("beginangle", "Begin Angle", 0, 0...360),
                P.float("endangle", "End Angle", 360, 0...360),
            ], "A circle or arc: a polygon (closed, sliced like a pie) or an open curve.")
        case .line:
            return ProcNodeSpec("Line", .generate, "line", symbol: "line.diagonal", params: [
                P.vec3("origin", "Origin", .zero), P.vec3("dir", "Direction", [0, 1, 0]), P.float("dist", "Length", 1, 0...10),
                P.int("points", "Points", 2, 2...100),
            ], "An open polyline of evenly spaced points.")
        case .add:
            return ProcNodeSpec("Add", .generate, "add", symbol: "plus.circle", inputs: ["Geometry"], params: [
                P("points", "Points", .points([]), .points),
                P.menu("connect", "Connect", ["none", "open", "closed"]),
            ], "Adds points (to its input, if wired) and, if asked, a polyline or polygon through them.")
        case .file:
            return ProcNodeSpec("File", .generate, "file", symbol: "doc", params: [
                P("file", "Geometry", .string(""), .file, help: "mesh:<slug> (a model asset) or object:<name> (one of the Modeller's)"),
            ], "Reads a model asset or another object of the Modeller's document.")

        // MARK: Transform & combine
        case .transform:
            return ProcNodeSpec("Transform", .transform, "transform", symbol: "move.3d", inputs: ["Geometry"], params: [
                P.group(), pointsOrPrims.with(value: "points"),
                P.menu("xord", "Transform Order", ["SRT", "STR", "RST", "RTS", "TSR", "TRS"]),
                P.menu("rord", "Rotate Order", ["XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX"]),
                P.vec3("t", "Translate", .zero), P.vec3("r", "Rotate", .zero), P.vec3("s", "Scale", [1, 1, 1]),
                P.vec3("p", "Pivot", .zero), P.float("scale", "Uniform Scale", 1, 0...10), P.bool("invert", "Invert", false),
            ], "Moves, rotates and scales the geometry (or a group of it); normals and up vectors turn with it.")
        case .merge:
            return ProcNodeSpec("Merge", .transform, "merge", symbol: "arrow.triangle.merge", inputs: ["Geometry"], multiInput: true,
                                params: [], "All its inputs' geometry as one, their attributes joined.")
        case .copyxform:
            return ProcNodeSpec("Copy and Transform", .transform, "copyxform", symbol: "square.on.square", inputs: ["Geometry"], params: [
                P.int("ncy", "Total Number", 2, 1...50), P.vec3("t", "Translate", [1, 0, 0]), P.vec3("r", "Rotate", .zero),
                P.vec3("s", "Scale", [1, 1, 1]), P.vec3("p", "Pivot", .zero), P.float("scale", "Uniform Scale", 1, 0...2),
                P.bool("copynum", "Copy Number Attribute", true),
            ], "Copies of the input, each transformed once more than the one before.")
        case .mirror:
            return ProcNodeSpec("Mirror", .transform, "mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                inputs: ["Geometry"], params: [
                P.group("group", "Group", .primitive), P.vec3("origin", "Origin", .zero), P.vec3("dir", "Direction", [1, 0, 0]),
                P.bool("keeporiginal", "Keep Original", true), P.bool("consolidate", "Consolidate Seam", true),
                P.float("distance", "Seam Distance", 0.001, 0...0.1),
            ], "Reflects the geometry across a plane, joining the halves at the seam.")

        // MARK: Polygon
        case .polyextrude:
            return ProcNodeSpec("PolyExtrude", .polygon, "polyextrude", symbol: "square.stack.3d.up", inputs: ["Geometry"], params: [
                P.group("group", "Group", .primitive), P.menu("split", "Extrusion", ["connected", "individual"]),
                P.float("dist", "Distance", 0.2, -1...1), P.float("inset", "Inset", 0, 0...1), P.int("divs", "Divisions", 1, 1...20),
                P.bool("outputback", "Output Back", false),
                P.text("frontgroup", "Front Group", "extrudeFront", folder: "Output Groups"),
                P.text("sidegroup", "Side Group", "extrudeSide", folder: "Output Groups"),
            ], "Pushes polygons out along their normals, with walls round them (connected regions share walls' points).")
        case .subdivide:
            return ProcNodeSpec("Subdivide", .polygon, "subdivide", symbol: "circle.grid.3x3", inputs: ["Geometry"], params: [
                P.int("iterations", "Depth", 1, 0...5), P.bool("creases", "Keep Sharp Edges", false),
            ], "Catmull-Clark subdivision (UVs follow; other attributes are taken from the nearest original element).")
        case .boolean:
            return ProcNodeSpec("Boolean", .polygon, "boolean", symbol: "square.on.circle", inputs: ["A", "B"], params: [
                P.menu("operation", "Operation", ["union", "intersect", "subtract"], "subtract"),
                P.menu("solver", "Solver", ["exact", "voxel"]),
                P.float("voxel", "Voxel Size", 0.02, 0.001...0.2, when: ProcNodeKind.onlyFor("solver", "voxel")),
            ], "Union, intersection or difference of two closed meshes.")
        case .polybevel:
            return ProcNodeSpec("PolyBevel", .polygon, "polybevel", symbol: "square.dashed", inputs: ["Geometry"], params: [
                P.group("group", "Points", .point), P.float("dist", "Distance", 0.1, 0...1), P.int("divs", "Divisions", 1, 1...10),
                P.float("angle", "Angle Limit", 30, 0...180),
            ], "Bevels edges: those between the group's points, or with no group every edge sharper than the angle.")
        case .polyreduce:
            return ProcNodeSpec("PolyReduce", .polygon, "polyreduce", symbol: "triangle", inputs: ["Geometry"], params: [
                P.float("percentage", "Keep (%)", 50, 1...100),
            ], "Fewer triangles where the surface stays the same (quadric edge collapse).")
        case .divide:
            return ProcNodeSpec("Divide", .polygon, "divide", symbol: "triangle.lefthalf.filled", inputs: ["Geometry"], params: [
                P.group("group", "Group", .primitive),
            ], "Triangulates polygons (fans for convex ones, ear clipping otherwise); vertex attributes are kept.")
        case .fuse:
            return ProcNodeSpec("Fuse", .polygon, "fuse", symbol: "link", inputs: ["Geometry"], params: [
                P.group("group", "Points", .point), P.float("dist", "Distance", 0.001, 0...1),
                P.bool("removedegen", "Remove Degenerate", true),
            ], "Points closer than the distance become one (the first's attributes).")
        case .clean:
            return ProcNodeSpec("Clean", .polygon, "clean", symbol: "sparkles", inputs: ["Geometry"], params: [
                P.bool("removeunused", "Remove Unused Points", true), P.bool("removedegen", "Remove Degenerate", true),
            ], "Removes points no primitive uses and primitives with too few distinct points.")
        case .facet:
            return ProcNodeSpec("Facet", .polygon, "facet", symbol: "diamond", inputs: ["Geometry"], params: [
                P.bool("unique", "Unique Points", true), P.bool("removenormals", "Remove Normals", true),
            ], "Each primitive its own points (a flat-shaded look), normals removed.")
        case .normal:
            return ProcNodeSpec("Normal", .polygon, "normal", symbol: "arrow.up.to.line", inputs: ["Geometry"], params: [
                P.menu("type", "Add Normals To", ["vertices", "points", "primitives"]),
                P.float("cusp", "Cusp Angle", 60, 0...180, when: ProcNodeKind.onlyFor("type", "vertices")),
                P.menu("weighting", "Weighting", ["area", "equal"]),
            ], "Computes N: per vertex with sharp edges past the cusp angle, per point (smooth), or per primitive.")
        case .reverse:
            return ProcNodeSpec("Reverse", .polygon, "reverse", symbol: "arrow.uturn.backward", inputs: ["Geometry"], params: [
                P.group("group", "Group", .primitive),
            ], "Reverses primitives' vertex order, turning polygons' fronts round.")
        case .smooth:
            return ProcNodeSpec("Smooth", .polygon, "smooth", symbol: "drop", inputs: ["Geometry"], params: [
                P.group("group", "Points", .point), P.int("iterations", "Iterations", 10, 0...100), P.float("strength", "Strength", 0.5, 0...1),
            ], "Moves points toward their neighbours' average.")
        case .thicken:
            return ProcNodeSpec("Thicken", .polygon, "thicken", symbol: "square.3.layers.3d", inputs: ["Geometry"], params: [
                P.float("thickness", "Thickness", 0.05, 0...1), P.float("offset", "Offset", -1, -1...1),
                P.bool("even", "Even Thickness", false), P.bool("rim", "Fill Rim", true),
            ], "Gives a surface thickness (a second shell and its rim).")
        case .uvunwrap:
            return ProcNodeSpec("UV Unwrap", .polygon, "uvunwrap", symbol: "square.grid.2x2", inputs: ["Geometry"], params: [
                P.menu("method", "Method", ["smart", "seams"]), P.float("angle", "Angle Limit", 66, 1...89),
            ], "Flattens the surface into UV islands packed into 0...1: the vertex attribute uv.")

        // MARK: Attribute
        case .attribcreate:
            return ProcNodeSpec("Attribute Create", .attribute, "attribcreate", symbol: "plus.square", inputs: ["Geometry"], params: [
                P.text("name", "Name", "attrib1"), P.classes(), P.menu("type", "Type", AttributeType.allCases.map(\.rawValue)),
                P.vec4("value", "Value", .zero), P.text("string", "String", when: ProcNodeKind.onlyFor("type", "string")),
                P.group("group", "Group"),
            ], "Makes an attribute (or sets it) to a value, on the group's elements.")
        case .attribdelete:
            return ProcNodeSpec("Attribute Delete", .attribute, "attribdelete", symbol: "minus.square", inputs: ["Geometry"], params: [
                P.text("ptdel", "Point Attributes"), P.text("vtxdel", "Vertex Attributes"),
                P.text("primdel", "Primitive Attributes"), P.text("dtldel", "Detail Attributes"),
                P.bool("negate", "Delete Non-Selected", false),
            ], "Removes attributes by name pattern (`Cd uv`, `tmp*`, `* ^N`).")
        case .attribrename:
            return ProcNodeSpec("Attribute Rename", .attribute, "attribrename", symbol: "character.cursor.ibeam", inputs: ["Geometry"], params: [
                P.classes(), P.attribute("from", "From", ""), P.text("to", "To"),
            ], "Gives an attribute another name.")
        case .attribrandomize:
            return ProcNodeSpec("Attribute Randomize", .attribute, "attribrandomize", symbol: "dice", inputs: ["Geometry"], params: [
                P.text("name", "Name", "Cd"), P.classes(), P.int("dims", "Dimensions", 3, 1...4),
                P.vec4("min", "Min", .zero), P.vec4("max", "Max", [1, 1, 1, 1]), P.int("seed", "Seed", 0, 0...100),
                P.group("group", "Group"),
            ], "Random values between min and max, the same for the same element number and seed.")
        case .attribnoise:
            return ProcNodeSpec("Attribute Noise", .attribute, "attribnoise", symbol: "waveform.path", inputs: ["Geometry"], params: [
                P.text("name", "Name", "P"), P.classes("class", "Class", .point, ProcNodeKind.classes2),
                P.menu("op", "Operation", ["add", "set", "multiply", "alongnormal"]),
                P.float("amp", "Amplitude", 0.1, 0...2), P.float("freq", "Frequency", 1, 0...20), P.vec3("offset", "Offset", .zero),
                P.int("octaves", "Octaves", 3, 1...8), P.float("rough", "Roughness", 0.5, 0...1), P.int("seed", "Seed", 0, 0...100),
                P.group("group", "Group"),
            ], "Fractal noise over the elements' positions, added to (or setting, scaling) an attribute: P for a bumpy surface.")
        case .attribpromote:
            return ProcNodeSpec("Attribute Promote", .attribute, "attribpromote", symbol: "arrow.up.arrow.down", inputs: ["Geometry"], params: [
                P.attribute("name", "Name", "", nil), P.classes("from", "Original Class", .point), P.classes("to", "New Class", .primitive),
                P.menu("method", "Method", ["average", "minimum", "maximum", "sum", "first", "last"]),
                P.bool("deleteoriginal", "Delete Original", true),
            ], "Moves an attribute to another class, combining the values that meet.")
        case .color:
            return ProcNodeSpec("Color", .attribute, "color", symbol: "paintpalette", inputs: ["Geometry"], params: [
                P.classes("class", "Class", .point), P.menu("mode", "Color Type", ["constant", "random", "ramp"]),
                P.color("color", "Color", [1, 1, 1], when: ProcNodeKind.onlyFor("mode", "constant")),
                P.int("seed", "Seed", 0, 0...100, when: ProcNodeKind.onlyFor("mode", "random")),
                P.attribute("rampattr", "Ramp Attribute", "", nil, when: ProcNodeKind.onlyFor("mode", "ramp")),
                P.group("group", "Group"),
            ], "Sets Cd: one colour, random colours, or a heat ramp over an attribute's range.")
        case .measure:
            return ProcNodeSpec("Measure", .attribute, "measure", symbol: "ruler", inputs: ["Geometry"], params: [
                P.menu("type", "Measure", ["area", "perimeter"]), P.text("name", "Attribute"),
            ], "Each primitive's area or perimeter, as a primitive attribute (named for what it measures).")
        case .connectivity:
            return ProcNodeSpec("Connectivity", .attribute, "connectivity", symbol: "point.3.connected.trianglepath.dotted", inputs: ["Geometry"], params: [
                P.classes("class", "Class", .point, ProcNodeKind.classes2), P.text("name", "Attribute", "class"),
            ], "Numbers the connected pieces: an integer attribute, the same on everything joined.")
        case .sort:
            return ProcNodeSpec("Sort", .attribute, "sort", symbol: "arrow.up.arrow.down.square", inputs: ["Geometry"], params: [
                P.classes("class", "Class", .point, ProcNodeKind.classes2),
                P.menu("key", "Sort By", ["none", "x", "y", "z", "random", "attribute"]),
                P.int("seed", "Seed", 0, 0...100, when: ProcNodeKind.onlyFor("key", "random")),
                P.attribute("attribute", "Attribute", "", nil, when: ProcNodeKind.onlyFor("key", "attribute")),
                P.bool("reverse", "Reverse", false),
            ], "Renumbers points or primitives in an order.")

        // MARK: Scatter & copy
        case .scatter:
            return ProcNodeSpec("Scatter", .scatter, "scatter", symbol: "circle.dotted", inputs: ["Surface"], params: [
                P.bool("usedensity", "Use Density", false), P.int("npts", "Force Total Count", 1000, 0...20000, when: ProcNodeKind.onlyFor("usedensity", "0")),
                P.float("density", "Density (per unit area)", 10, 0...1000, when: ProcNodeKind.onlyFor("usedensity", "1")),
                P.int("seed", "Global Seed", 0, 0...100), P.int("relaxiterations", "Relax Iterations", 0, 0...20),
                P.attribute("densityattr", "Density Attribute", "", nil), P.text("attribs", "Output Attributes", "*"),
            ], "Points on the surface, as many where it is bigger (or denser); each with N and the primitive it is on.")
        case .copytopoints:
            return ProcNodeSpec("Copy to Points", .scatter, "copytopoints", symbol: "square.grid.3x3.square", inputs: ["Geometry", "Target Points"], params: [
                P.group("targetgroup", "Target Points", .point), P.text("attribs", "Copy Attributes", "*"),
                P.menu("attribclass", "Onto", ["point", "primitive"]), P.bool("copyattrib", "Copy Number Attribute", false),
            ], "A copy of the first input on each point of the second: turned by orient (or N and up), sized by pscale and scale.")
        case .attribtransfer:
            return ProcNodeSpec("Attribute Transfer", .scatter, "attribtransfer", symbol: "arrow.right.circle", inputs: ["Geometry", "Source"], params: [
                P.classes("class", "Class", .point, ProcNodeKind.classes2), P.text("attribs", "Attributes", "*"),
                P.float("distance", "Max Distance (0: any)", 0, 0...10),
            ], "Attributes from the second input's nearest points (or primitives) onto the first's.")
        case .ray:
            return ProcNodeSpec("Ray", .scatter, "ray", symbol: "arrow.down.to.line.compact", inputs: ["Points", "Surface"], params: [
                P.group("group", "Group", .point), P.menu("method", "Method", ["project", "minimum"]),
                P.vec3("dir", "Direction", [0, -1, 0]), P.bool("usenormal", "Along N", false), P.bool("bothways", "Both Ways", true),
                P.float("offset", "Offset", 0, -1...1), P.bool("putnormal", "Point N from Surface", true),
            ], "Moves points onto the surface: along a direction (or their N), or to its nearest place.")
        case .pointjitter:
            return ProcNodeSpec("Point Jitter", .scatter, "pointjitter", symbol: "aqi.medium", inputs: ["Geometry"], params: [
                P.group("group", "Group", .point), P.float("amount", "Amount", 0.1, 0...2), P.vec3("scale", "Scale", [1, 1, 1]),
                P.int("seed", "Seed", 0, 0...100),
            ], "Moves points by random offsets.")
        case .voronoifracture:
            return ProcNodeSpec("Voronoi Fracture", .scatter, "voronoifracture", symbol: "square.split.diagonal.2x2", inputs: ["Geometry", "Cell Points"], params: [
                P.bool("cutinput", "Cut the Input", true), P.text("interiorgroup", "Interior Group", "inside"),
            ], "Breaks the geometry into a piece per point: each point's Voronoi cell (cut out of the mesh), named piece0, piece1 …")

        // MARK: Curve
        case .curve:
            return ProcNodeSpec("Curve", .curve, "curve", symbol: "scribble", params: [
                P("points", "Points", .points([[0, 0, 0], [1, 0, 0.5], [2, 0, 0], [3, 0, 0.5]]), .points),
                P.menu("type", "Type", ["polygon", "smooth"]), P.int("segs", "Segments per Span", 8, 1...32, when: ProcNodeKind.onlyFor("type", "smooth")),
                P.bool("closed", "Closed", false),
            ], "A curve through points: straight between them, or smooth (Catmull-Rom).")
        case .resample:
            return ProcNodeSpec("Resample", .curve, "resample", symbol: "point.topleft.down.to.point.bottomright.curvepath", inputs: ["Curves"], params: [
                P.group("group", "Group", .primitive), P.bool("dolength", "Maximum Segment Length", true),
                P.float("length", "Length", 0.1, 0.001...2, when: ProcNodeKind.onlyFor("dolength", "1")),
                P.int("segs", "Maximum Segments", 10, 1...200, when: ProcNodeKind.onlyFor("dolength", "0")),
                P.menu("treatpolysas", "Treat Polygons As", ["straight", "subdivision"]), P.bool("docurveu", "Curve U Attribute", true),
            ], "Points evenly spaced along each curve (or smoothed through it); attributes follow; curveu 0 to 1 along it.")
        case .sweep:
            return ProcNodeSpec("Sweep", .curve, "sweep", symbol: "point.3.filled.connected.trianglepath.dotted", inputs: ["Backbone", "Cross Section"], params: [
                P.menu("surfaceshape", "Surface Shape", ["tube", "square", "ribbon", "input"]),
                P.float("radius", "Radius", 0.1, 0...2, when: ProcNodeKind.onlyFor("surfaceshape", "tube")),
                P.int("cols", "Columns", 8, 3...64, when: ProcNodeKind.onlyFor("surfaceshape", "tube")),
                P.float("width", "Width", 0.2, 0...2, when: ProcNodeKind.onlyFor("surfaceshape", "square", "ribbon")),
                P.float("scale", "Scale", 1, 0...5), P.bool("applyscale", "Apply Scale Along Curve", false),
                P("scaleramp", "Scale Ramp", .ramp([[0, 1], [1, 1]]), .ramp),
                P.float("twist", "Twist (degrees)", 0, -720...720), P.float("roll", "Roll", 0, -180...180),
                P.vec3("up", "Up", [0, 1, 0]), P.bool("endcaps", "End Caps", true), P.bool("polygonsasbackbones", "Polygons as Backbones", false),
                P.bool("computeuvs", "Compute UVs", true, folder: "UVs"), P.vec2("uvscale", "UV Scale", [1, 1], folder: "UVs"),
            ], "A cross-section (a tube, a square, a ribbon or the second input's curve) swept along each curve, carried along it without twisting.")
        case .revolve:
            return ProcNodeSpec("Revolve", .curve, "revolve", symbol: "rotate.3d", inputs: ["Curves"], params: [
                P.vec3("origin", "Origin", .zero), P.vec3("dir", "Axis", [0, 1, 0]), P.int("divs", "Divisions", 24, 3...128),
                P.float("beginangle", "Start Angle", 0, 0...360), P.float("endangle", "End Angle", 360, 0...360),
            ], "A surface turned round an axis from each curve (a lathe).")
        case .polywire:
            return ProcNodeSpec("PolyWire", .curve, "polywire", symbol: "line.3.horizontal.decrease", inputs: ["Curves"], params: [
                P.float("radius", "Wire Radius", 0.05, 0...1), P.int("divs", "Divisions", 8, 3...32), P.bool("caps", "End Caps", true),
            ], "A tube round every curve and polygon edge loop (a point's width scales it).")
        case .carve:
            return ProcNodeSpec("Carve", .curve, "carve", symbol: "scissors.badge.ellipsis", inputs: ["Curves"], params: [
                P.float("firstu", "First U", 0, 0...1), P.float("secondu", "Second U", 1, 0...1),
            ], "The part of each curve between two places along it (0 its start, 1 its end).")
        case .ends:
            return ProcNodeSpec("Ends", .curve, "ends", symbol: "circle.bottomhalf.filled", inputs: ["Geometry"], params: [
                P.group("group", "Group", .primitive), P.menu("closeu", "Close U", ["close", "open", "unroll"]),
            ], "Closes curves into polygons, opens polygons into curves, or unrolls them (the first point again at the end).")
        case .lsystem:
            return ProcNodeSpec("L-System", .curve, "lsystem", symbol: "leaf", params: [
                P.int("generations", "Generations", 4, 0...8), P.text("premise", "Premise", "F"),
                P("rules", "Rules", .string("F=F[+F]F[-F][&F]F"), .code, help: "one rule a line: F=…; X:0.5=… a chance"),
                P.float("angle", "Angle", 25, 0...180), P.float("variance", "Angle Variance", 0, 0...45),
                P.float("step", "Step Size", 0.2, 0...2), P.float("stepscale", "Step Scale (\")", 0.9, 0...2),
                P.float("width", "Width", 1, 0...2), P.float("widthscale", "Width Scale (!)", 0.7, 0...2), P.int("seed", "Seed", 0, 0...100),
            ], "Branching curves by Lindenmayer's rules, drawn by a turtle: F f + - & ^ \\ / | [ ] ! \". Each point has width and generation.")

        // MARK: Group
        case .groupcreate:
            return ProcNodeSpec("Group Create", .group, "groupcreate", symbol: "circle.dashed", inputs: ["Geometry"], params: [
                P.text("groupname", "Group Name", "group1"), pointsOrPrims,
                P.menu("mergeop", "Initial Merge", ["replace", "union", "intersect", "subtract"]),
                P.text("basegroup", "Base Group", folder: "Base"),
                P.bool("usebounds", "Keep in Bounding Region", false, folder: "Bounding"),
                P.vec3("boundmin", "Min", [-0.5, -0.5, -0.5], folder: "Bounding"), P.vec3("boundmax", "Max", [0.5, 0.5, 0.5], folder: "Bounding"),
                P.bool("usenormal", "Keep by Normals", false, folder: "Normal"),
                P.vec3("dir", "Direction", [0, 1, 0], folder: "Normal"), P.float("angle", "Spread Angle", 30, 0...180, folder: "Normal"),
                P.bool("userandom", "Keep Random", false, folder: "Random"),
                P.float("percent", "Percent", 50, 0...100, folder: "Random"), P.int("seed", "Seed", 0, 0...100, folder: "Random"),
            ], "Makes a group from a pattern, a box, a facing direction and a random share, each narrowing the last.")
        case .blast:
            return ProcNodeSpec("Blast", .group, "blast", symbol: "scissors", inputs: ["Geometry"], params: [
                P.group(), pointsOrPrims, P.bool("negate", "Delete Non-Selected", false),
                P.bool("removegrp", "Delete Group", false),
            ], "Deletes a group's primitives or points (a point's primitives go with it).")

        // MARK: Utility
        case .null:
            return ProcNodeSpec("Null", .flow, "null", symbol: "circle.slash", inputs: ["Geometry"], params: [],
                                "Passes its input on: a named place in the network.")
        case .output:
            return ProcNodeSpec("Output", .flow, "output", symbol: "arrow.down.to.line", inputs: ["Geometry"], params: [
                P.int("outputidx", "Output Index", 0, 0...4),
            ], "What the network (an asset) outputs, whatever has the display flag.")
        case .attribwrangle:
            return ProcNodeSpec("Attribute Wrangle", .flow, "attribwrangle", symbol: "chevron.left.forwardslash.chevron.right",
                                inputs: ["Geometry", "Input 2", "Input 3", "Input 4"], params: [
                P.menu("class", "Run Over", ["points", "primitives", "vertices", "detail"]), P.group("group", "Group"),
                P("snippet", "Swift Snippet", .string("@P.y += sin(@P.x * 4) * 0.1"), .code,
                  help: "@P, f@mass, v@up, i@id, s@name …; @ptnum, @numpt; point(1, \"P\", n), nearpoint(1, @P), addpoint(p); rand, noise, fit, lerp"),
            ], "Runs Swift over every point (primitive, vertex, or the detail) on every core: @name binds an attribute, as VEX does.")
        case .foreachbegin:
            return ProcNodeSpec("Block Begin", .flow, "foreach_begin", symbol: "arrow.triangle.2.circlepath", inputs: ["Geometry"], params: [],
                                "Where a For-Each loop's body starts: in the loop, the piece (or the last pass's output) it works on.")
        case .foreachend:
            return ProcNodeSpec("Block End", .flow, "foreach_end", symbol: "arrow.triangle.2.circlepath.circle", inputs: ["Body"], params: [
                P("blockpath", "Block Begin", .string(""), .text, help: "the Block Begin node's name (empty: the nearest one above)"),
                P.menu("iterationmethod", "Iteration Method", ["pieces", "points", "count"]),
                P.menu("gather", "Gather Method", ["merge", "feedback"]),
                P.attribute("pieceattrib", "Piece Attribute", "name", .primitive, when: ProcNodeKind.onlyFor("iterationmethod", "pieces")),
                P.int("iterations", "Iterations", 10, 1...100, when: ProcNodeKind.onlyFor("iterationmethod", "count")),
            ], "Runs the body once per piece (by an attribute, else by connectivity), per point, or a count of times; merges the passes, or feeds each into the next.")
        case .switchnode:
            return ProcNodeSpec("Switch", .flow, "switch", symbol: "switch.2", inputs: ["Geometry"], multiInput: true, params: [
                P.int("input", "Select Input", 0, 0...9),
            ], "Passes one of its inputs on; only that one is cooked.")
        }
    }
}

extension ProcParamSpec {
    /// The same parameter with another default.
    func with(value: String) -> ProcParamSpec {
        var p = self
        p.value = .string(value)
        return p
    }
}
