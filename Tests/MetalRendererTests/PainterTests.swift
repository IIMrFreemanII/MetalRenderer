import XCTest
import Metal
import simd
@testable import MetalRenderer

/// The Material Painter past the unwrap: the painted scene (its materials, its corners' UVs, its assignments), the
/// documents, the brush's dabs, the GLB a set exports with, the composite and a stroke on the GPU, and the window's
/// model (its edits as undo steps).
final class PainterTests: XCTestCase {
    // MARK: - The scene

    func testTheWorkshopPaintsItsObject() {
        var s = SceneSettings(kind: .painter)
        s.painterWorkshop.subject = .cube
        s.painterWorkshop.document = "Painter test cube"
        let scene = Scene(s)
        XCTAssertEqual(scene.painted.count, 1)
        let o = scene.painted[0]
        XCTAssertEqual(scene.instances[o.instance].material, o.materials[0])
        XCTAssertEqual(o.slots.count, ProcSlot.allCases.count)
        let triangles = Int(scene.meshes[o.mesh].indexCount) / 3
        XCTAssertEqual(scene.paintUVs.count, 3 * triangles, "three UVs a corner")
        XCTAssertEqual(o.cornerBase, scene.uvs.count, "after the vertices' UVs")
        // The extras say where its corners are, and give the same place back.
        let e = scene.materialExtras[o.materials[0]]!
        XCTAssertEqual(PaintedObject.corners(e).map(Int.init), o.cornerOffset)
        XCTAssertEqual(o.cornerOffset + 3 * o.firstTriangle, o.cornerBase)
        XCTAssertEqual(o.atlas.chartCount, 6, "a box's faces: a chart each")
        XCTAssertNil(PaintedObject.corners(GPUMaterialExtra()))
        XCTAssertEqual(PaintedObject.corners({ var x = GPUMaterialExtra(); x.textures.z = PaintedObject.encode(cornerOffset: -12345); return x }()), -12345)
    }

    func testAssignmentsPaintTheirInstanceAndDropStaleOnes() {
        let s = SceneSettings(kind: .cornell)
        let made = Scene(s)
        guard let i = made.instances.indices.first(where: { made.paintable($0) }) else { return XCTFail("nothing paintable") }
        var a = PaintAssignments()
        a.set(s, instance: i, fingerprint: made.paintFingerprint(i), document: "Painter test cornell")
        let j = made.instances.indices.last { made.paintable($0) && $0 != i }!
        a.set(s, instance: j, fingerprint: "stale", document: "Painter test stale")
        var painted = s
        painted.paintAssignments = PaintAssignments.register(a)
        let scene = Scene(painted)
        XCTAssertEqual(scene.painted.map(\.instance), [i], "the stale one dropped")
        XCTAssertEqual(PaintAssignments.resolve(painted.paintAssignments), a)
        // Unpainting: the entry goes.
        a.set(s, instance: i, fingerprint: "", document: nil)
        a.set(s, instance: j, fingerprint: "", document: nil)
        XCTAssertTrue(a.scenes.isEmpty)
    }

    // MARK: - Documents and brushes

    func testDocumentsRoundTrip() throws {
        var d = PaintDocument(name: "Round trip")
        d.layers += SmartMaterial.builtIn[0].instantiate()
        d.layers[1].mask?.painted = true
        let data = try JSONEncoder().encode(d)
        XCTAssertEqual(try JSONDecoder().decode(PaintDocument.self, from: data), d)
        // An old document without the newer fields still reads.
        let bare = try JSONDecoder().decode(PaintDocument.self, from: Data(#"{"name":"Bare"}"#.utf8))
        XCTAssertEqual(bare.layers.count, 1)
        XCTAssertEqual(bare.resolution, 2048)
        // A smart material's second drop is layers of its own.
        let m = SmartMaterial.builtIn[1]
        XCTAssertTrue(Set(m.instantiate().map(\.id)).isDisjoint(with: m.instantiate().map(\.id)))
        XCTAssertTrue(SmartMaterial.builtIn.allSatisfy { $0.layers.dropFirst().allSatisfy { $0.mask?.generator != nil } })
    }

    func testStrokesBecomeEvenlySpacedDabs() {
        var b = PaintBrush()
        b.size = 10
        b.spacing = 0.25
        b.pressureSize = false
        var dabs = PaintStrokeDabs(brush: b, scale: 1)
        var all = dabs.move(to: [0, 0], pressure: 1)
        all += dabs.move(to: [50, 0], pressure: 1)
        all += dabs.move(to: [100, 0], pressure: 1)
        // A dab every 5 pixels (a quarter of the 20-pixel diameter): 0, 5, ..., 100.
        XCTAssertEqual(all.count, 21)
        for (k, d) in all.enumerated() { XCTAssertEqual(d.centre.x, Float(k) * 5, accuracy: 1e-3) }
        // Pressure shrinks it.
        var p = PaintStrokeDabs(brush: PaintBrush(), scale: 1)
        XCTAssertLessThan(p.move(to: .zero, pressure: 0.5).first!.radius, PaintBrush().size * 0.6)
        // The stencil's frame: the view's centre is its centre.
        var st = PaintBrush.Stencil()
        st.rotation = 30
        let uv = st.frame(screen: [800, 600]) * SIMD3(400, 300, 1)
        XCTAssertEqual(uv.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(uv.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(PaintStamps().names.count, PaintStamps.builtIn.count)
        XCTAssertTrue(PaintStamps.make(3).contains { $0 > 200 } && PaintStamps.make(3).contains { $0 == 0 }, "a leaf in its square")
    }

    func testTheExportedMeshReadsBack() throws {
        let g = Scene.uvSphere(rings: 8, segments: 16)
        let mesh = PaintMesh(positions: g.positions, normals: g.normals, indices: g.indices)
        let atlas = UVUnwrap.unwrap(mesh, resolution: 512)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PainterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sphere.glb")
        try GLBWriter.write(mesh, corners: atlas.corners, name: "sphere", to: url)
        // The set it names, beside it (as Export writes them).
        for part in ["basecolor", "orm", "normal"] {
            try MatExport.write([SIMD4<Float>(1, 1, 1, 1)], side: 1, grey: false, srgb: false, format: .png8,
                                to: folder.appendingPathComponent("sphere_\(part).png"))
        }
        let model = try GLTFLoader.load(url)
        XCTAssertEqual(model.meshes.count, 1)
        let m = model.meshes[0]
        XCTAssertEqual(m.indices.count, mesh.indices.count)
        for i in stride(from: 0, to: m.indices.count, by: 7) {
            XCTAssertEqual(m.uvs[Int(m.indices[i])], atlas.corners[i])
            XCTAssertEqual(simd_distance(m.positions[Int(m.indices[i])], mesh.positions[Int(mesh.indices[i])]), 0, accuracy: 1e-6)
        }
    }

    // MARK: - On the GPU

    /// A painted quad's set: its fill's colour composited, a fill through a black mask left out, then a stroke across
    /// its middle (red where the brush went, the fill elsewhere), and its undo.
    func testCompositeAndStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no GPU") }
        var s = SceneSettings(kind: .painter)
        s.painterWorkshop.subject = .plane
        s.painterWorkshop.document = "Painter test plane"
        var d = PaintDocument(name: s.painterWorkshop.document, resolution: 256)
        var blue = PaintLayer.fill("Blue", PaintValues(color: [0, 0, 1], roughness: 0.2))
        blue.mask = PaintMask(base: 0, generator: nil, painted: false)   // hidden
        var paint = PaintLayer(name: "Paint")
        paint.channels = [.color]
        d.layers = [PaintLayer.fill("Green", PaintValues(color: [0, 1, 0], roughness: 0.7)), blue, paint]
        PaintDocuments.shared.update(d)
        let scene = Scene(s)
        let o = try XCTUnwrap(scene.painted.first)
        let session = try XCTUnwrap(PainterSession(device: device, object: o, document: d))
        func buffer<T>(_ a: [T]) -> MTLBuffer { a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! } }
        let indices = buffer(scene.indices), positions = buffer(scene.positions), normals = buffer(scene.normals), uvs = buffer(scene.uvs + scene.paintUVs)
        let transform = scene.instances[o.instance].transform
        try session.prepare(queue: queue, args: session.objectArgs(transform: transform, scene: scene), indices: indices, positions: positions,
                            normals: normals, offsets: [UInt8](repeating: 0, count: Int(scene.meshes[o.mesh].indexCount) / 3))
        session.sync(d, version: 1)
        func frame(_ view: PaintDabArgs? = nil, surfacePos: MTLTexture? = nil) {
            let f = Metal3Frame(queue: queue, profile: nil, split: false, overlap: false)!
            session.encode(f, scene: scene, transform: transform, sceneTextures: [], indices: indices, positions: positions, normals: normals,
                           uvs: uvs, view: view, surfacePos: surfacePos, stamps: PaintStamps().array(device), stencil: nil,
                           catalog: MaterialCatalog(), now: true)
            f.commit(presenting: nil, wait: true) { _ in }
        }
        frame()
        XCTAssertTrue(session.composited)
        func colourAt(_ uv: SIMD2<Float>) -> SIMD4<Float> {
            let px = PainterPixels.read(session.base, device: device, queue: queue)
            let p = SIMD2<Int>(uv * Float(session.size))
            return px[p.y * session.size + p.x]
        }
        // The plane's own UVs are its layout (0...1.8: tiled, so it is unwrapped: one chart). Its middle is inside it.
        let middle = o.atlas.corners.reduce(SIMD2<Float>.zero, +) / Float(o.atlas.corners.count)
        var c = colourAt(middle)
        XCTAssertGreaterThan(c.y, 0.9, "green")
        XCTAssertLessThan(c.z, 0.1, "the blue fill's mask is black")
        // A stroke: the surface the "render" shows is the plane itself (a surfacePos of its points, made by looking
        // straight down at it).
        var view = PaintDabArgs()
        let eye = SIMD3<Float>(0, 3, 0)
        // Looking down -Y: right = +X, up = -Z.
        let t: Float = 0.5
        let r = SIMD3<Float>(1, 0, 0) / t, u = SIMD3<Float>(0, 0, -1) / t, fw = SIMD3<Float>(0, -1, 0)
        view.viewProjection = float4x4(rows: [SIMD4(r, -dot(r, eye)), SIMD4(u, -dot(u, eye)), SIMD4(0, 0, 0, 0), SIMD4(fw, -dot(fw, eye))])
        view.camera = SIMD4(eye, 0)
        view.screen = [256, 256]
        view.tolerance = 0.05
        let surface = try XCTUnwrap(surfacePosOfPlane(device, queue: queue, view: view, height: transform.columns.3.y + 0.01, instance: o.instance))
        let paintID = d.layers[2].id
        session.beginStroke(layer: paintID, target: .channels([.color]), values: PaintValues(color: [1, 0, 0]), erase: false, stencil: false)
        session.pendingDabs = [PaintDab(centre: [128, 128], radius: 40, hardness: 0.9, opacity: 1, flow: 1)]
        session.endStroke()
        var recorded: PainterSession.UndoRecord?
        session.onStrokeRecorded = { recorded = $0 }
        frame(view, surfacePos: surface)
        frame()
        // Where the dab was: the plane's point under the view's middle, (0, y, 0): its UV in the set.
        let hit = uvOfPoint(o, scene: scene, point: SIMD3(0, 0, 0))
        c = colourAt(hit)
        XCTAssertGreaterThan(c.x, 0.9, "red under the brush")
        XCTAssertLessThan(c.y, 0.1)
        XCTAssertNotNil(recorded, "the stroke's undo kept")
        session.undo(recorded!, undo: true)
        frame()
        c = colourAt(hit)
        XCTAssertGreaterThan(c.y, 0.9, "green again after undo")
        session.undo(recorded!, undo: false)
        frame()
        XCTAssertGreaterThan(colourAt(hit).x, 0.9, "red again after redo")
        // The levels (made again over the tiles the stroke touched only): each texel of level 3 the mean of its 8x8 of level 0.
        let level0 = PainterPixels.read(session.base, device: device, queue: queue)
        let view3 = try XCTUnwrap(session.base.makeTextureView(pixelFormat: session.base.pixelFormat, textureType: .type2D, levels: 3..<4, slices: 0..<1))
        let level3 = PainterPixels.read(view3, device: device, queue: queue)
        var worst: Float = 0
        for y in 0..<view3.height {
            for x in 0..<view3.width {
                var mean = SIMD4<Float>.zero
                for j in 0..<8 { for i in 0..<8 { mean += level0[(8 * y + j) * session.size + 8 * x + i] } }
                worst = max(worst, simd_reduce_max(abs(mean / 64 - level3[y * view3.width + x])))
            }
        }
        XCTAssertLessThan(worst, 4 / 255, "level 3 is level 0's means")
    }

    /// The mesh maps made off the render thread (PaintBakeJob, in bands of rows on a queue of its own) are those of
    /// one pass over the whole set.
    func testBakesInTheBackgroundMatchOnePass() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no GPU") }
        guard device.supportsRaytracing else { throw XCTSkip("no ray tracing") }
        var s = SceneSettings(kind: .painter)
        s.painterWorkshop.subject = .cube
        s.painterWorkshop.document = "Painter bake cube"
        let d = PaintDocument(name: s.painterWorkshop.document, resolution: 512)
        PaintDocuments.shared.update(d)
        let scene = Scene(s)
        let o = try XCTUnwrap(scene.painted.first)
        let session = try XCTUnwrap(PainterSession(device: device, object: o, document: d))
        func buffer<T>(_ a: [T]) -> MTLBuffer { a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! } }
        try session.prepare(queue: queue, args: session.objectArgs(transform: scene.instances[o.instance].transform, scene: scene),
                            indices: buffer(scene.indices), positions: buffer(scene.positions), normals: buffer(scene.normals),
                            offsets: [UInt8](repeating: 0, count: Int(scene.meshes[o.mesh].indexCount) / 3))
        let map = try XCTUnwrap(session.texelMap)
        let mesh = PaintMesh(scene: scene, mesh: o.mesh)
        let job = PaintBakeJob(mesh: mesh, map: map, size: 512, device: device, queue: queue, bandRows: 64)
        let deadline = Date().addingTimeInterval(60)
        while job.done == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let banded = try XCTUnwrap(job.done ?? nil, "the background bake")
        let whole = try XCTUnwrap(PaintBake(mesh: mesh, map: map, size: 512, device: device, queue: queue, bandRows: 512))
        for (a, b, name) in [(banded.occlusion, whole.occlusion, "occlusion"), (banded.curvature, whole.curvature, "curvature")] {
            let pa = PainterPixels.read(a, device: device, queue: queue), pb = PainterPixels.read(b, device: device, queue: queue)
            let worst = zip(pa, pb).reduce(Float(0)) { max($0, abs($1.0.x - $1.1.x)) }
            XCTAssertLessThan(worst, 1.5 / 255, name)
            XCTAssertGreaterThan(pa.reduce(0) { $0 + $1.x } / Float(pa.count), 0.05, "\(name) was made")
        }
    }

    /// The GPU's time for a 2K set: a full composite of a few layers, then a frame of ten dabs (the tiles they touch
    /// stroked, applied and composited again). `PAINTER_PERF=1`.
    func testPaintingCost() throws {
        guard ProcessInfo.processInfo.environment["PAINTER_PERF"] != nil else { throw XCTSkip("PAINTER_PERF=1") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no GPU") }
        var s = SceneSettings(kind: .painter)
        s.painterWorkshop.subject = .plane
        s.painterWorkshop.document = "Painter perf plane"
        var d = PaintDocument(name: s.painterWorkshop.document, resolution: 2048)
        var paint = PaintLayer(name: "Paint")
        paint.channels = [.color, .roughness, .height]
        d.layers = [PaintDocument.baseLayer] + SmartMaterial.builtIn[2].instantiate().map { var l = $0; l.mask = nil; return l } + [paint]
        PaintDocuments.shared.update(d)
        let scene = Scene(s)
        let o = try XCTUnwrap(scene.painted.first)
        let session = try XCTUnwrap(PainterSession(device: device, object: o, document: d))
        func buffer<T>(_ a: [T]) -> MTLBuffer { a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! } }
        let indices = buffer(scene.indices), positions = buffer(scene.positions), normals = buffer(scene.normals), uvs = buffer(scene.uvs + scene.paintUVs)
        let transform = scene.instances[o.instance].transform
        try session.prepare(queue: queue, args: session.objectArgs(transform: transform, scene: scene), indices: indices, positions: positions,
                            normals: normals, offsets: [UInt8](repeating: 0, count: Int(scene.meshes[o.mesh].indexCount) / 3))
        session.sync(d, version: 1)
        var view = PaintDabArgs()
        let eye = SIMD3<Float>(0, 3, 0), t: Float = 0.5
        let r = SIMD3<Float>(1, 0, 0) / t, u = SIMD3<Float>(0, 0, -1) / t, fw = SIMD3<Float>(0, -1, 0)
        view.viewProjection = float4x4(rows: [SIMD4(r, -dot(r, eye)), SIMD4(u, -dot(u, eye)), SIMD4(0, 0, 0, 0), SIMD4(fw, -dot(fw, eye))])
        view.camera = SIMD4(eye, 0)
        view.screen = [256, 256]
        view.tolerance = 0.05
        let surface = try XCTUnwrap(surfacePosOfPlane(device, queue: queue, view: view, height: transform.columns.3.y + 0.01, instance: o.instance))
        func frame(_ v: PaintDabArgs? = nil) -> Double {
            let f = Metal3Frame(queue: queue, profile: nil, split: false, overlap: false)!
            session.encode(f, scene: scene, transform: transform, sceneTextures: [], indices: indices, positions: positions, normals: normals,
                           uvs: uvs, view: v, surfacePos: v == nil ? nil : surface, stamps: PaintStamps().array(device), stencil: nil,
                           catalog: MaterialCatalog(), now: true)
            var ms = 0.0
            f.commit(presenting: nil, wait: true) { times in ms = (times.end - times.start) * 1000 }
            return ms
        }
        _ = frame()
        session.invalidate()
        let full = frame()
        session.beginStroke(layer: paint.id, target: .channels([.color, .roughness, .height]), values: PaintValues(color: [1, 0, 0]), erase: false, stencil: false)
        _ = frame(view)
        var stroke: [Double] = []
        for k in 0..<5 {
            session.pendingDabs = (0..<10).map { PaintDab(centre: [100 + Float(k * 10 + $0) * 1.2, 128], radius: 12, hardness: 0.6, opacity: 1, flow: 0.6) }
            stroke.append(frame(view))
        }
        print(String(format: "Painter cost: full composite at 2K %.2f ms; a frame of 10 dabs %.2f ms (best of 5)", full, stroke.min() ?? 0))
    }

    /// A surfacePos texture (world xyz, instance + 1) of a horizontal plane at `height`, as `view` sees it.
    private func surfacePosOfPlane(_ device: MTLDevice, queue: MTLCommandQueue, view: PaintDabArgs, height: Float, instance: Int) -> MTLTexture? {
        let n = Int(view.screen.x)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: n, height: n, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px = [SIMD4<Float>](repeating: .zero, count: n * n)
        let eye = SIMD3<Float>(view.camera.x, view.camera.y, view.camera.z)
        for y in 0..<n {
            for x in 0..<n {
                // Inverse of the view: ndc -> a point on the plane (looking straight down).
                let ndc = SIMD2<Float>((Float(x) + 0.5) / Float(n) * 2 - 1, 1 - (Float(y) + 0.5) / Float(n) * 2)
                let depth = eye.y - height
                let p = SIMD3<Float>(ndc.x * 0.5 * depth, height, -ndc.y * 0.5 * depth)
                px[y * n + x] = SIMD4(p, Float(instance + 1))
            }
        }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 16) }
        return t
    }

    /// The set's UV of a world point on the painted object (its nearest triangle's corners, interpolated).
    private func uvOfPoint(_ o: PaintedObject, scene: Scene, point: SIMD3<Float>) -> SIMD2<Float> {
        let mesh = PaintMesh(scene: scene, mesh: o.mesh)
        let inv = scene.instances[o.instance].transform.inverse
        let q4 = inv * SIMD4(point, 1)
        let q = SIMD3(q4.x, q4.y, q4.z)
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.corners(t)
            let p0 = mesh.positions[a], p1 = mesh.positions[b], p2 = mesh.positions[c]
            let n = simd_cross(p1 - p0, p2 - p0)
            let area = simd_length(n)
            let w1 = simd_dot(simd_cross(q - p0, p2 - p0), n) / (area * area), w2 = simd_dot(simd_cross(p1 - p0, q - p0), n) / (area * area)
            if w1 >= 0, w2 >= 0, w1 + w2 <= 1 {
                return o.atlas.corners[3 * t] * (1 - w1 - w2) + o.atlas.corners[3 * t + 1] * w1 + o.atlas.corners[3 * t + 2] * w2
            }
        }
        return [0.5, 0.5]
    }

    // MARK: - The window's model

    private final class Host: PainterHost {
        var settings = RenderSettings()
        var sent: [String] = []
        func update(_ change: @escaping (inout RenderSettings) -> Void) { change(&settings) }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) {}
        func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void) {}
        func cancelPick() {}
        var observer: ((PainterStatus) -> Void)?
        func observePainter(_ observer: @escaping (PainterStatus) -> Void) { self.observer = observer }
        func painter(_ work: @escaping (Renderer) -> Void) { sent.append("work") }
        func paintInfo(_ instance: Int, _ answer: @escaping (String?) -> Void) { answer("fp") }
    }

    func testLayerEditsAreUndoSteps() {
        let host = Host()
        let model = PainterModel(host: host)
        var d = PaintDocument(name: "Painter test model")
        d.layers = [PaintDocument.baseLayer]
        PaintDocuments.shared.update(d)
        host.observer?(PainterStatus(objects: [.init(index: 0, instance: 3, document: d.name, resolution: 1024, triangles: 2, charts: 1,
                                                    ownUVs: false, baked: false)]))
        XCTAssertEqual(model.document?.layers.count, 1)
        model.addPaint()
        model.addSmart(SmartMaterial.builtIn[0])
        XCTAssertEqual(model.document?.layers.count, 2 + SmartMaterial.builtIn[0].layers.count)
        XCTAssertEqual(PaintDocuments.shared.document(d.name), model.document, "edits reach the renderer's documents")
        model.undo.undo()
        XCTAssertEqual(model.document?.layers.count, 2)
        model.undo.undo()
        XCTAssertEqual(model.document?.layers.count, 1)
        model.undo.redo()
        XCTAssertEqual(model.document?.layers.count, 2)
        // A layer whose channels gain opacity: the scene is made again (the assignments' key changes).
        let before = host.settings.scene.paintAssignments
        let id = model.document!.layers.last!.id
        model.updateLayer(id, "Channels") { $0.channels.insert(.opacity) }
        XCTAssertNotEqual(host.settings.scene.paintAssignments, before)
        // A pick assigns its instance a document of its own.
        model.assign(instance: 7, fingerprint: "fp", document: "Doc 7")
        XCTAssertEqual(PaintAssignments.resolve(host.settings.scene.paintAssignments).entries(host.settings.scene).map(\.instance), [7])
        // Strokes the renderer kept become undo steps (undoing one asks the renderer).
        host.observer?(PainterStatus(objects: model.status.objects, strokes: [1]))
        let sent = host.sent.count
        model.undo.undo()
        XCTAssertEqual(host.sent.count, sent + 1)
    }
}
