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
}
