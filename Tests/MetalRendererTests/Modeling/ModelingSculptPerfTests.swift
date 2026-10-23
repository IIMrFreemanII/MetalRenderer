import Metal
import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// Sculpting at Blender's scale, timed (release: `Tools/release.sh test --filter ModelingSculptPerfTests` with
/// MODELING_PERF=1): a 2M-triangle sphere's tree, dabs of two sizes, a stroke's dabs with the viewport's copies, and
/// a frame of the viewport drawing it. Prints the times; fails only if a dab takes far longer than its target.
final class ModelingSculptPerfTests: XCTestCase {
    private func time(_ label: String, _ repeats: Int = 1, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repeats { body() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(repeats)
        print(String(format: "  %-48@ %8.2f ms", label as NSString, ms))
        return ms
    }

    func testTwoMillionTriangles() throws {
        guard ProcessInfo.processInfo.environment["MODELING_PERF"] != nil else { throw XCTSkip("MODELING_PERF not set") }
        let sphere = Primitives.quadSphere(n: 410, radius: 1)   // 6 × 410² quads: 2.0M triangles
        print("Sculpt timing: \(sphere.faceCount * 2) triangles, \(sphere.vertexCount) vertices")
        var mesh: SculptMesh!
        _ = time("tree and adjacency (SculptMesh)") { mesh = SculptMesh(sphere) }
        XCTAssertEqual(mesh.triangleCount, sphere.faceCount * 2)
        // Dabs whose spheres hold about 100k and 20k vertices (radius 0.63 and 0.28 on the unit sphere: 10% and 2% of
        // its area); counted below.
        let brush = SculptBrush(kind: .draw)
        let stroke = SculptStroke(mesh: mesh, brush: brush)
        let big = time("draw dab, ~100k vertices (×2 mirrored)", 10) { stroke.dab(at: [0.3, 0.9, 0.3], radius: 0.63, strength: 0.5) }
        let small = time("draw dab, ~20k vertices (×2 mirrored)", 10) { stroke.dab(at: [0.3, 0.9, 0.3], radius: 0.28, strength: 0.5) }
        for r: Float in [0.63, 0.28] {
            let c = simd_normalize(SIMD3<Float>(0.3, 0.9, 0.3))
            print("  vertices within \(r): \(mesh.position.filter { simd_distance(SIMD3($0.x, $0.y, $0.z), c) < r }.count)")
        }
        let smooth = SculptStroke(mesh: mesh, brush: SculptBrush(kind: .smooth))
        _ = time("smooth dab, ~20k vertices (×2 mirrored)", 10) { smooth.dab(at: [0.3, 0.9, 0.3], radius: 0.28, strength: 0.5, smooth: true) }
        _ = time("raycast", 100) { _ = mesh.raycast(origin: [0, 0, 5], direction: [0, 0, -1]) }
        // The viewport's copy of what a dab changed.
        if let device = MTLCreateSystemDefaultDevice() {
            let drawing = SculptDrawing(device: device)
            _ = drawing.prepare(mesh)   // all of it, once
            _ = drawing.prepare(mesh)
            stroke.dirty.removeAll()
            stroke.dab(at: [0.3, 0.9, 0.3], radius: 0.63, strength: 0.5)
            let dirty = stroke.dirty
            _ = time("viewport copy of a big dab's leaves (\(dirty.count))", 10) {
                drawing.markDirty(dirty)
                _ = drawing.prepare(mesh)
            }
            // A frame of the viewport with it, 1440×900 at 2×.
            let renderer = try ViewportRenderer(device: device)
            var f = ViewportFrame()
            f.size = [2880, 1800]
            f.camera.distance = 3.2
            f.shading.mode = .matcap
            var o = ViewportObjectDraw(mesh: drawing.prepare(mesh), transform: matrix_identity_float4x4, color: [0.8, 0.8, 0.8], materialColors: [])
            o.sculpt = true
            f.objects = [o]
            _ = renderer.pixels(f)
            _ = time("viewport frame 2880×1800 (with readback)", 5) { _ = renderer.pixels(f) }
            // The GPU's own time for a frame (no readback).
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ViewportRenderer.colorFormat, width: 2880, height: 1800, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            let target = try XCTUnwrap(device.makeTexture(descriptor: d))
            var gpu: [Double] = []
            for _ in 0..<8 {
                let cb = try XCTUnwrap(renderer.commandQueue?.makeCommandBuffer())
                renderer.encode(f, target: target, into: cb)
                cb.commit()
                cb.waitUntilCompleted()
                gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            print(String(format: "  %-48@ %8.2f ms", "viewport frame 2880×1800, GPU" as NSString, gpu.dropFirst(2).min() ?? 0))
        }
        _ = time("back into the mesh (write)") { var m = sphere; mesh.write(into: &m) }
        // Release targets: 8 ms and 3 ms (a generous margin here, for a debug or busy machine).
        XCTAssertLessThan(big, 40)
        XCTAssertLessThan(small, 15)
    }

    /// Dynamic topology: strokes of mouse events, each a dab, its refinement (×2, mirrored) and the viewport's copy,
    /// finer than the mesh and coarser, with brushes of a few times the detail to some tens of times; then undoing and
    /// redoing each stroke, and packing what they left. On the 2M-triangle sphere, and (the same edge length, brush and
    /// detail) on one of 126k triangles: the work is local, so the two should take about the same.
    func testDynamicTopologyTwoMillion() throws {
        guard ProcessInfo.processInfo.environment["MODELING_PERF"] != nil else { throw XCTSkip("MODELING_PERF not set") }
        let device = MTLCreateSystemDefaultDevice()
        var worst: Double = 0
        for (n, size) in [(410, Float(1)), (103, Float(0.25))] {
            let mesh = SculptMesh(Primitives.quadSphere(n: n, radius: size))
            let drawing = device.map { SculptDrawing(device: $0) }
            _ = drawing?.prepare(mesh)
            _ = drawing?.prepare(mesh)
            print("Dynamic topology: \(mesh.triangleCount) triangles, edges ~\(String(format: "%.4f", 2 * size / Float(n)))")
            // Detail 0.0025: edges split (the mesh's are ~0.005); 0.008: collapsed.
            for (detail, radius) in [(Float(0.0025), Float(0.015)), (0.0025, 0.05), (0.0025, 0.12), (0.008, 0.05), (0.008, 0.12)] {
                let stroke = SculptStroke(mesh: mesh, brush: SculptBrush(kind: .draw))
                if mesh.needsCompaction {
                    _ = time("  packing first (compact)") { mesh.compact() }
                    drawing?.markTrianglesDirty(mesh)
                    _ = drawing?.prepare(mesh)
                }
                stroke.record.beginLayout(mesh)
                var dab = 0.0, refine = 0.0, copy = 0.0, peak = 0.0
                let events = 40
                for i in 0..<events {
                    // Along an arc 0.25 long, wherever the sphere's size.
                    let a = (Float(i) / Float(events) - 0.5) * 0.25 / size
                    let q = SIMD3<Float>(sin(a), cos(a), 0) * size
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    stroke.move(to: q, radius: radius, strength: 0.3)
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    var change = DynTopo.Change()
                    for mirror in stroke.mirrors {
                        if let c = DynTopo.refine(mesh, centre: q * mirror, radius: radius, detail: detail, record: stroke.record) {
                            change.leaves.formUnion(c.leaves); change.triangles += c.triangles
                        }
                    }
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    drawing?.markDirty(stroke.dirty); drawing?.markDirty(change.leaves); drawing?.markTriangles(change.triangles)
                    stroke.dirty.removeAll()
                    _ = drawing?.prepare(mesh)
                    let t3 = DispatchTime.now().uptimeNanoseconds
                    dab += Double(t1 - t0) / 1e6; refine += Double(t2 - t1) / 1e6; copy += Double(t3 - t2) / 1e6
                    if i > 0 { peak = max(peak, Double(t3 - t0) / 1e6) }
                }
                let e = Double(events)
                let label = String(format: "%@, r %.3f (%.0f× detail)", detail < 0.005 ? "finer" : "coarser", radius, radius / detail)
                print(String(format: "  %-30@ per event: dab %.2f, refine %.2f, viewport %.2f ms; slowest %.1f ms; %d triangles",
                             label as NSString, dab / e, refine / e, copy / e, peak, mesh.triangleCount))
                worst = max(worst, (dab + refine + copy) / e)
                let undo = time("    undo the stroke") { stroke.record.swap(into: mesh) }
                _ = time("    redo it") { stroke.record.swap(into: mesh) }
                _ = undo
                drawing?.markTrianglesDirty(mesh)
            }
            XCTAssertNil(mesh.check(boxes: false))
            _ = time("  packing (compact)") { mesh.compact() }
        }
        // Release target: a mouse event in a frame (16 ms) for brushes of up to ~20× the detail; a generous margin here.
        XCTAssertLessThan(worst, 60)
    }
}
