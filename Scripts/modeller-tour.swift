// The Modeller's tools tried as a user would, without a window: a scripted Modeller (`run.modeller`, offscreen) takes
// keys, clicks and drags, and each result is checked (counts, bounds, undo). The window's hand test, done headless.
// With a folder, a picture of the window after each tool, and of the Rendered view at the end.
//
//   Tools/script.py Scripts/modeller-tour.swift [folder for pictures]
import Editors
import Modeling

func run(_ run: ScriptRun) throws {
    let m = run.modeller
    let folder = run.arguments.first
    var failed: [String] = []

    func mesh() throws -> EditMesh {
        let d = try m.document
        guard let a = d.active else { throw ScriptModeller.Failure("no active object") }
        return d.objects[a].mesh
    }
    func check(_ what: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "ok  " : "FAIL") \(what): \(detail)")
        if !ok { failed.append(what) }
    }
    func picture(_ name: String) throws {
        guard let folder else { return }
        try m.capture(.window, scale: 0.5, to: "\(folder)/tour-\(name).png")
    }
    /// A fresh cube in edit mode, face select, the face facing +X picked.
    func cubeWithFace() throws {
        try m.open(.cube)
        try m.keys("tab 3")
        try m.click(world: [1, 0, 0])
    }

    // Extrude: E, typed 1, Return.
    try cubeWithFace()
    try m.keys("e")
    try m.type("1")
    try m.keys("return")
    var mesh0 = try mesh()
    check("extrude", mesh0.faceCount == 10 && mesh0.isClosedManifold() && mesh0.positions.map(\.x).max() == 2,
          "\(mesh0.faceCount) faces, out to x = \(mesh0.positions.map(\.x).max() ?? 0)")
    try picture("extrude")

    // Loop cut: Ctrl-R over an edge, a click places it (then it slides, as Blender's), Return keeps it in the middle.
    try m.open(.cube)
    try m.keys("tab")
    if let p = try m.point([1, 0.5, 0.5]) { try m.move(p.x, p.y) }
    try m.keys("ctrl+r")
    try m.click(world: [1, 0.5, 0.5])
    try m.keys("return")
    mesh0 = try mesh()
    check("loop cut", mesh0.vertexCount == 12 && mesh0.faceCount == 10, "\(mesh0.vertexCount) vertices, \(mesh0.faceCount) faces")
    try picture("loopcut")

    // Edge slide: G G on the new loop, typed 0.5: the shape stays (its bounds), the loop moves.
    let before = mesh0.positions
    try m.keys("g g")
    try m.type("0.5")
    try m.keys("return")
    mesh0 = try mesh()
    let moved = zip(before, mesh0.positions).filter { simd_distance($0, $1) > 1e-4 }.count
    check("edge slide", moved == 4 && mesh0.positions.map(\.x).max() == 1 && mesh0.positions.map(\.y).max() == 1,
          "\(moved) vertices moved, the cube's bounds kept")
    try picture("slide")

    // Bridge: the top and bottom faces (the bottom isn't in view: selected through the document), bridged into a tunnel.
    try m.open(.cube)
    try m.keys("tab 3")
    try m.edit("Select") { d in
        var mesh = d.objects[0].mesh
        mesh.selectAll(false)
        for f in 0..<mesh.faceCount where abs(mesh.faceNormal(f).y) > 0.9 { mesh.setSelected(face: f, true) }
        d.objects[0].mesh = mesh
    }
    try m.run("Bridge Edge Loops")
    mesh0 = try mesh()
    check("bridge", mesh0.faceCount == 8 && mesh0.vertexCount == 8, "\(mesh0.faceCount) faces (a tunnel through the cube)")
    try picture("bridge")

    // Spin: the +X face swept 90° round the view's axis, typed.
    try cubeWithFace()
    try m.run("Spin")
    try m.type("90")
    try m.keys("return")
    mesh0 = try mesh()
    check("spin", mesh0.faceCount > 10, "\(mesh0.faceCount) faces")
    try picture("spin")

    // F3: "inset" typed into the search, Return runs it, a click confirms it.
    try cubeWithFace()
    try m.keys("f3")
    try m.type("inset")
    try m.keys("return")
    if let p = try m.point([1, 0.3, 0.3]) { try m.move(p.x, p.y); try m.click(p.x, p.y) }
    mesh0 = try mesh()
    check("F3 inset", mesh0.faceCount == 10, "\(mesh0.faceCount) faces")
    try picture("inset")

    // Knife: from the top edge of the +X face to a point inside it, Return.
    try m.open(.cube)
    try m.keys("tab")
    try m.keys("k")
    try m.click(world: [1, 1, 0])
    try m.click(world: [1, 0.2, 0.3])
    try m.keys("return")
    mesh0 = try mesh()
    check("knife ending in a face", mesh0.faceCount == 7 && mesh0.isClosedManifold(), "\(mesh0.faceCount) faces")
    try picture("knife")

    // Sculpt: a stroke on an ico sphere moves it, Cmd-Z puts it back.
    try m.open(.icoSphere)
    try m.mode(.sculpt)
    guard let a = try m.point([0.4, 0.3, 0.87]), let b = try m.point([0.75, 0.3, 0.6]) else { throw ScriptModeller.Failure("the sphere isn't in view") }
    try m.drag((0...12).map { k in a + (b - a) * Float(k) / 12 }, pressure: [0.4, 1])
    let stroke = try m.json["undo"] as? String ?? ""
    try picture("sculpt")
    try m.keys("cmd+z")
    try m.mode(.object)
    mesh0 = try mesh()
    check("sculpt stroke and undo", stroke == "Draw" && mesh0.positions == Primitive.icoSphere.mesh().positions, "undo was \"\(stroke)\"")

    // The Rendered view: the head on the stage, path traced.
    if let folder {
        try m.open(.head)
        try m.keys("ctrl+2")
        try m.perform(json: [["shading": "rendered"]])
        let url = try m.capture(.rendered, scale: 0.5, to: "\(folder)/tour-rendered.png")
        print("     rendered: \(url.path)")
        try m.perform(json: [["shading": "solid"]])
    }

    try m.close()
    if failed.isEmpty { print("every check passed") } else { run.fail("failed: \(failed.joined(separator: ", "))") }
}
