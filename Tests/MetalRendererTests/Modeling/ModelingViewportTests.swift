import Metal
import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// The modelling window's viewport, drawn offscreen: the shading modes draw the mesh, the picking pass finds the
/// object, face, edge or vertex under a point. MODELING_PNG=<folder> also writes each picture there.
final class ModelingViewportTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: ViewportRenderer!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        renderer = try ViewportRenderer(device: device)
    }

    private func frame(_ doc: ModelingDocument, scene: ViewportScene, mode: EditorMode = .object, selectMode: SelectMode = .vertex,
                       shading: ViewportShading.Mode = .solid, xray: Bool = false) -> ViewportFrame {
        var f = ViewportFrame()
        f.size = [480, 320]
        f.pixelScale = 1
        f.shading.mode = shading
        f.shading.xray = xray
        f.camera = ViewportCamera()
        f.objects = scene.objects(doc, mode: mode, selectMode: selectMode, wire: shading == .wireframe)
        return f
    }

    private func write(_ f: ViewportFrame, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MODELING_PNG"] else { return }
        let image = try XCTUnwrap(renderer.snapshot(f))
        try ViewportRenderer.writePNG(image, to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }

    private func pixel(_ p: [UInt8], _ f: ViewportFrame, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let o = (y * f.size.x + x) * 4
        return SIMD3(Int(p[o + 2]), Int(p[o + 1]), Int(p[o]))   // BGRA
    }

    func testShadingModesDrawTheCube() throws {
        let doc = ModelingDocument.startup()
        let scene = ViewportScene(device: device)
        let background = pixel(renderer.pixels(frame(ModelingDocument(), scene: scene)), frame(doc, scene: scene), 5, 5)
        for mode in [ViewportShading.Mode.solid, .matcap, .wireframe] {
            let f = frame(doc, scene: scene, shading: mode)
            let p = renderer.pixels(f)
            XCTAssertEqual(p.count, 480 * 320 * 4)
            let centre = pixel(p, f, 240, 160)
            if mode != .wireframe {
                XCTAssertGreaterThan(abs(centre.x - background.x) + abs(centre.y - background.y) + abs(centre.z - background.z), 40, "\(mode): the cube covers the centre")
            }
            XCTAssertEqual(pixel(p, f, 2, 2), background, "\(mode): the corner is the background")
            try write(f, "object-\(mode.rawValue)")
        }
        // Selected: an orange outline round it.
        let f = frame(doc, scene: scene)
        let p = renderer.pixels(f)
        var orange = 0
        for y in 0..<f.size.y { for x in 0..<f.size.x { let c = pixel(p, f, x, y); if c.x > 200 && c.y > 90 && c.y < 225 && c.z < 160 && c.x - c.z > 90 { orange += 1 } } }
        XCTAssertGreaterThan(orange, 100, "the active object's outline")
    }

    func testEditModeOverlays() throws {
        var doc = ModelingDocument.startup()
        doc.objects[0].mesh.selectAll(true)
        let scene = ViewportScene(device: device)
        for sm in SelectMode.allCases {
            let f = frame(doc, scene: scene, mode: .edit, selectMode: sm)
            try write(f, "edit-\(sm)")
        }
        try write(frame(doc, scene: scene, mode: .edit, xray: true), "edit-xray")
        // A shot from Blender's start-up angle with the grid and the cube: the grid draws.
        var f = frame(doc, scene: scene)
        f.camera.align(.top)
        try write(f, "top-ortho")
    }

    func testPickingObjectsAndElements() throws {
        let doc = ModelingDocument.startup()
        let scene = ViewportScene(device: device)
        // Object mode: the cube is object 0 (id 1) at the centre; nothing in the corner.
        let f = frame(doc, scene: scene)
        XCTAssertEqual(renderer.pick(f, at: [240, 160], radius: 2, edit: false).first?.id, 1)
        XCTAssertTrue(renderer.pick(f, at: [3, 3], radius: 2, edit: false).isEmpty)
        // Edit mode, face select: a face of the cube (kind 1).
        let fe = frame(doc, scene: scene, mode: .edit, selectMode: .face)
        let hit = try XCTUnwrap(renderer.pick(fe, at: [240, 160], radius: 2, edit: true).first)
        XCTAssertEqual(hit.id >> 28, 1)
        XCTAssertLessThan(Int(hit.id & 0x0FFF_FFFF) - 1, 6)
        // Vertex select: the vertex nearest the camera, where it projects.
        let fv = frame(doc, scene: scene, mode: .edit, selectMode: .vertex)
        let cube = doc.objects[0].mesh
        let eye = fv.camera.eye
        let nearest = (0..<cube.vertexCount).min { simd_distance(cube.positions[$0], eye) < simd_distance(cube.positions[$1], eye) }!
        let at = try XCTUnwrap(fv.camera.project(cube.positions[nearest], size: [480, 320]))
        let picks = renderer.pick(fv, at: [Int(at.x), Int(at.y)], radius: 6, edit: true)
        let vertex = try XCTUnwrap(picks.first { $0.id >> 28 == 3 })
        XCTAssertEqual(Int(vertex.id & 0x0FFF_FFFF) - 1, nearest)
    }

    func testCameraProjectsAndUnprojects() {
        var c = ViewportCamera()
        let size = SIMD2<Float>(800, 600)
        for p in [SIMD3<Float>(0.3, 0.2, -0.4), [1, 1, 1], [-2, 0.5, 0]] {
            let s = c.project(p, size: size)!
            let ray = c.ray(at: SIMD2(s.x, s.y), size: size)
            // The point is on the ray through its own pixel.
            let t = simd_dot(p - ray.origin, ray.direction)
            XCTAssertLessThan(simd_distance(ray.origin + ray.direction * t, p), 1e-3)
        }
        c.align(.front)
        XCTAssertTrue(c.orthographic)
        XCTAssertEqual(simd_distance(c.forward, [0, 0, -1]), 0, accuracy: 1e-6)
        c.orbit(dx: 10, dy: 0)
        XCTAssertFalse(c.orthographic, "auto perspective: orbiting off a numpad view goes back")
        var box = AABB()
        box.grow([-1, -1, -1]); box.grow([1, 1, 1])
        c.frame(box, aspect: 1.33)
        XCTAssertEqual(c.target, .zero)
        // The box fits: its corners project inside the view.
        for corner in [SIMD3<Float>(-1, -1, -1), [1, 1, 1], [1, -1, 1], [-1, 1, -1]] {
            let s = c.project(corner, size: size)!
            XCTAssertTrue(s.x >= 0 && s.x <= size.x && s.y >= 0 && s.y <= size.y)
        }
    }
}
