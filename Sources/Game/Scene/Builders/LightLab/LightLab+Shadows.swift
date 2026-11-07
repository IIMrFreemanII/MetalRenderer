import EngineCore
import Materials
import MetalRenderer
import simd

extension Scene {
    /// A neutral grey (albedo 0.5) for a shadow booth's props.
    private func shadowGrey() -> Int { addMaterial(albedo: SIMD3(repeating: 0.5)) }

    /// A constant light at local `p` (a sphere, spot, rect...), the pose fixed.
    private func shadowLight(_ kind: LightKind, _ b: BoothFrame, at p: SIMD3<Float>, color: SIMD3<Float>, toward local: SIMD3<Float> = [0, -1, 0]) {
        let pose = LightPose(position: b.p(p.x, p.y, p.z), direction: normalize(b.dir(local)))
        addLight(kind, color: color, motion: .constant) { _ in pose }
    }

    /// Booth 8, contact: 1 mm wires, thin poles, a plate 1 cm over the floor (ray epsilons, contact shadows).
    /// One sphere light (r 0.05) high in the booth.
    func boothContact(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self), grey = shadowGrey()
        object("Light") { shadowLight(.sphere(radius: 0.05), b, at: [-0.6, 2.7, 1.0], color: [22, 22, 22]) }
        object("Wires") {
            // 1 mm thick, 1.5 m long (along across), their undersides 2, 10 and 30 cm over the floor
            for (i, h) in [Float(0.02), 0.10, 0.30].enumerated() {
                let z = 0.8 + 0.4 * Float(i)
                labSlab(kit, b, [-0.75, h, z - 0.0005], [0.75, h + 0.001, z + 0.0005], grey)
            }
        }
        object("Poles") {
            for (i, w) in [Float(0.01), 0.02, 0.05].enumerated() {
                let x = 0.3 + 0.35 * Float(i)
                labSlab(kit, b, [x - w / 2, 0, 2.4 - w / 2], [x + w / 2, 1.0, 2.4 + w / 2], grey)
            }
        }
        object("Plate") { labSlab(kit, b, [-1.3, 0.01, 2.6], [-0.7, 0.03, 3.2], grey) }
        object("Cube") { labSlab(kit, b, [0.95, 0, 3.05], [1.25, 0.3, 3.35], grey) }
    }

    /// Booth 9, penumbra ramp: one occluder under 5 light sizes (penumbra width, noise in soft shadows).
    /// Four sizes (0.005, 0.05, 0.2, 0.6) over four identical 0.3 m cubes on 0.8 m posts, with baffles between.
    func boothPenumbra(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self), grey = shadowGrey()
        let xs: [Float] = [-1.6, -0.9, 0, 1.2], radii: [Float] = [0.005, 0.05, 0.2, 0.6], z: Float = 2.2
        for (i, x) in xs.enumerated() {
            object(String(format: "Cube %d (light radius %g)", i + 1, radii[i])) {
                labSlab(kit, b, [x - 0.03, 0, z - 0.03], [x + 0.03, 0.8, z + 0.03], grey)          // post
                labSlab(kit, b, [x - 0.15, 0.8, z - 0.15], [x + 0.15, 1.1, z + 0.15], grey)        // cube
                shadowLight(.sphere(radius: radii[i]), b, at: [x, 2.15, z], color: [20, 20, 20])
            }
        }
        object("Baffles") {   // hanging from the ceiling (overlapping it) down to 1.5 m, 1 cm thick
            for x in [Float(-1.25), -0.45, 0.5] { labSlab(kit, b, [x - 0.005, 1.5, 1.4], [x + 0.005, 3.01, 3.4], grey) }
        }
    }

    /// Booth 10, leaks: a 1 cm wall with a light behind, corners, mesh gaps, a light in a closed box (leaks, self-intersection).
    /// Each enclosure is dark outside; anything lit there is a leak.
    func boothLeaks(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self), grey = shadowGrey()
        object("Divided chamber") {   // back-left quarter: a wall across and a return wall, overlapping the shell at every seam
            labSlab(kit, b, [-2.05, -0.01, 2.495], [0.005, 3.01, 2.505], grey)
            labSlab(kit, b, [-0.005, -0.01, 2.49], [0.005, 3.01, 4.05], grey)
            shadowLight(.sphere(radius: 0.08), b, at: [-1.0, 1.5, 3.25], color: [30, 30, 30])
        }
        object("Corner, 1 mm gap") {   // two boxes face to face, 1 mm apart, a light behind them
            labSlab(kit, b, [0.0, -0.01, 2.0], [1.5, 3.01, 2.1], grey)
            labSlab(kit, b, [1.501, -0.01, 2.0], [2.05, 3.01, 4.05], grey)
            shadowLight(.sphere(radius: 0.08), b, at: [0.8, 1.5, 3.0], color: [30, 30, 30])
        }
        object("Closed box") {   // 0.6 m cube, 2 cm walls, six slabs overlapping at the edges, a light inside
            let c = SIMD3<Float>(1.0, 0.3, 1.0), h: Float = 0.3, t: Float = 0.02
            labSlab(kit, b, [c.x - h, c.y - h, c.z - h], [c.x + h, c.y - h + t, c.z + h], grey)
            labSlab(kit, b, [c.x - h, c.y + h - t, c.z - h], [c.x + h, c.y + h, c.z + h], grey)
            labSlab(kit, b, [c.x - h, c.y - h, c.z - h], [c.x - h + t, c.y + h, c.z + h], grey)
            labSlab(kit, b, [c.x + h - t, c.y - h, c.z - h], [c.x + h, c.y + h, c.z + h], grey)
            labSlab(kit, b, [c.x - h, c.y - h, c.z - h], [c.x + h, c.y + h, c.z - h + t], grey)
            labSlab(kit, b, [c.x - h, c.y - h, c.z + h - t], [c.x + h, c.y + h, c.z + h], grey)
            shadowLight(.sphere(radius: 0.03), b, at: c, color: [3, 3, 3])
        }
    }

    /// Booth 11, tinted glass: colour panes, stacked panes, a glass sphere (glassShadowTint in both modes).
    /// Window glass (`addGlassMaterial`, instances with `maskGlass`) for the panes; solid glass (`addSolidGlassMaterial`,
    /// `maskLiquid`) for the sphere.
    func boothTintedGlass(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        func pane(_ name: String, _ x: Float, _ z: Float, _ tint: SIMD3<Float>) {
            object(name) {
                let box = b.worldBox([x - 0.3, 0.3, z - 0.005], [x + 0.3, 1.1, z + 0.005])
                addInstance(kit.cube, addGlassMaterial(tint: tint), translate((box.lo + box.hi) / 2) * scale(box.hi - box.lo), mask: Scene.maskGlass)
            }
        }
        object("Colour panes") {
            pane("Red", -0.7, 2.0, [1, 0.1, 0.1])
            pane("Green", 0, 2.0, [0.1, 1, 0.1])
            pane("Blue", 0.7, 2.0, [0.1, 0.1, 1])
            shadowLight(.spot(radius: 0.05, inner: Scene.degrees(14), outer: Scene.degrees(20)), b, at: [0, 2.7, 0.9], color: [60, 60, 60],
                        toward: [0, -1.5, 2.6])
        }
        object("Stacked panes") {
            pane("Yellow", 1.45, 1.6, [1, 1, 0.1])
            pane("Cyan", 1.45, 1.66, [0.1, 1, 1])
            shadowLight(.spot(radius: 0.05, inner: Scene.degrees(10), outer: Scene.degrees(14)), b, at: [1.45, 2.7, 0.8], color: [40, 40, 40],
                        toward: [0, -1.7, 1.5])
        }
        object("Glass sphere") {
            addInstance(kit.sphere, addSolidGlassMaterial(tint: [0.9, 0.95, 1]), translate(b.p(-1.4, 0.25, 2.5)) * scale(0.25), mask: Scene.maskLiquid)
            shadowLight(.spot(radius: 0.05, inner: Scene.degrees(12), outer: Scene.degrees(16)), b, at: [-1.4, 2.7, 1.2], color: [40, 40, 40],
                        toward: [0, -2.45, 1.3])
        }
    }

    /// Booth 12, cut-outs: two bar gratings and two alpha-tested sheets, each under a spot (alpha-tested shadow rays).
    /// Both gratings are real bars: a coarse one (1 cm bars every 3 cm) and a fine one (5 mm bars every 1.5 cm). The
    /// sheets are thin boxes (a cube mesh with top-down UVs: the alpha test reads the mesh's) with a procedural material whose graph has an opacity output ("Perforated Metal": round
    /// holes, about 5 cm; "Swamp Leaves": a leaf card), which makes them alpha-tested in every ray query. Until a
    /// material's bake lands its opacity is one white pixel, so the sheet is solid.
    func boothCutouts(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self), grey = shadowGrey()
        func grating(_ name: String, centreX: Float, bar: Float, pitch: Float) {
            object(name) {
                let n = Int(0.8 / pitch)
                for i in 0...n {
                    let x = centreX - 0.4 + pitch * Float(i)
                    labSlab(kit, b, [x - bar / 2, 0.99, 1.8], [x + bar / 2, 1.0, 2.6], grey)
                }
                labSlab(kit, b, [centreX - 0.41, 0.99, 1.79], [centreX + 0.41, 1.0, 1.8], grey)
                labSlab(kit, b, [centreX - 0.41, 0.99, 2.6], [centreX + 0.41, 1.0, 2.61], grey)
            }
        }
        grating("Fine grating (card stand-in)", centreX: -0.6, bar: 0.005, pitch: 0.015)
        grating("Coarse grating (real bars)", centreX: 0.6, bar: 0.01, pitch: 0.03)
        object("Spot") {
            shadowLight(.spot(radius: 0.05, inner: Scene.degrees(30), outer: Scene.degrees(36)), b, at: [0, 2.8, 2.2], color: [40, 40, 40])
        }
        let catalog = MaterialCatalog.resolve(settings.materials)
        // The kit's cube has no UVs, and the alpha test reads the mesh's: top-down UVs (x, z), the same on the top and the
        // bottom face (a ray's two hits must see the same hole; per-face UVs would mirror one of them).
        let cube = Scene.cubeMesh()
        let uvCube = addMesh(cube, uvs: cube.0.map { SIMD2($0.x + 0.5, $0.z + 0.5) }, label: "box uv")
        func sheet(_ name: String, graph: String, centreX: Float) {
            object(name) {
                let material = addProceduralMaterial(graph: graph, catalog: catalog)
                let box = b.worldBox([centreX - 0.4, 0.99, 1.8], [centreX + 0.4, 1.0, 2.6])
                addInstance(uvCube, material, translate((box.lo + box.hi) / 2) * scale(box.hi - box.lo))
                shadowLight(.spot(radius: 0.05, inner: Scene.degrees(14), outer: Scene.degrees(18)), b, at: [centreX, 2.8, 2.2], color: [40, 40, 40])
            }
        }
        sheet("Perforated metal sheet", graph: "Perforated Metal", centreX: -1.55)
        sheet("Leaf card", graph: "Swamp Leaves", centreX: 1.55)
    }

    /// Booth 13, terminator: a low-poly sphere, normal-mapped bumps (shading against geometric normal).
    /// Two spheres (icosphere subdivisions 1 and 4), and, with no normal-map builder at hand, a panel of 45-degree
    /// ridges (bevelled), all under one rect light at the left wall that grazes them.
    func boothTerminator(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self), grey = shadowGrey()
        object("Low-poly sphere") {
            addInstance(addMesh(Scene.icosphere(subdivisions: 1), label: "ball low"), grey, translate(b.p(-1.0, 0.45, 2.7)) * scale(0.45))
        }
        object("Smooth sphere") {
            addInstance(addMesh(Scene.icosphere(subdivisions: 4), label: "ball smooth"), grey, translate(b.p(0, 0.45, 2.7)) * scale(0.45))
        }
        object("Ridged panel") {
            labSlab(kit, b, [0.8, 0.05, 3.3], [1.9, 1.1, 3.35], grey)
            for i in 0..<6 { kit.box(b.p(0.9 + 0.18 * Float(i), 0.58, 3.25), [0.1, 1.0, 0.1], grey, yaw: b.yaw(.pi / 4)) }
        }
        object("Rect light") {
            shadowLight(.rect(width: 1.0, height: 1.0), b, at: [-1.9, 0.7, 3.3], color: [8, 8, 8], toward: [1, 0, -0.3])
        }
    }
}
