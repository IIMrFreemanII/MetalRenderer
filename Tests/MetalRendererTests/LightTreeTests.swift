import XCTest
import simd
@testable import MetalRenderer

/// The light tree (LightTree.swift), MegaLights' far field: every light but the suns at the end of its path, nodes
/// that bound their children, and refits that follow the lights.
final class LightTreeTests: XCTestCase {
    private func light(_ type: Float, at p: SIMD3<Float>, radius: Float = 0.1, color: Float = 1,
                       axis: SIMD3<Float> = .zero, params: SIMD4<Float> = .zero) -> GPULight {
        GPULight(positionRadius: SIMD4(p, radius), color: SIMD4(color, color, color, 4 * type),
                 axis: SIMD4(axis, 0), params: params)
    }

    /// A row of spheres, a spot, a rect and a sun.
    private func lights() -> [GPULight] {
        var out = (0..<37).map { light(GPULight.sphere, at: [Float($0), 0, Float($0 % 5)], color: Float($0 + 1)) }
        out.append(light(GPULight.spot, at: [3, 4, 0], axis: [0, -1, 0], params: [cos(0.6), cos(0.4), 0, 0]))
        out.append(light(GPULight.rect, at: [8, 2, 1], radius: 0, axis: [0, -1, 0], params: [0.5, 0, 0, 0.25]))
        out.append(light(GPULight.sun, at: .zero, radius: 0.01, axis: [0, 1, 0]))
        return out
    }

    private func contains(_ outer: GPULightTreeNode, _ inner: GPULightTreeNode) -> Bool {
        let lo = SIMD3(outer.lo.x, outer.lo.y, outer.lo.z), hi = SIMD3(outer.hi.x, outer.hi.y, outer.hi.z)
        let ilo = SIMD3(inner.lo.x, inner.lo.y, inner.lo.z), ihi = SIMD3(inner.hi.x, inner.hi.y, inner.hi.z)
        return all(lo .<= ilo + 1e-5) && all(hi .>= ihi - 1e-5)
    }

    private func checkStructure(_ tree: LightTree, file: StaticString = #filePath, line: UInt = #line) {
        for (i, n) in tree.nodes.enumerated() where n.link.x & LightTree.leaf == 0 {
            let a = tree.nodes[Int(n.link.x)], b = tree.nodes[Int(n.link.y)]
            XCTAssertGreaterThan(Int(n.link.x), i, "children come after their parent", file: file, line: line)
            XCTAssertTrue(contains(n, a) && contains(n, b), "node \(i) bounds its children", file: file, line: line)
            XCTAssertEqual(n.lo.w, a.lo.w + b.lo.w, accuracy: 1e-3 * max(n.lo.w, 1), "node \(i) sums their power", file: file, line: line)
            XCTAssertEqual(a.link.z, UInt32(i), file: file, line: line)
            XCTAssertEqual(b.link.z, UInt32(i), file: file, line: line)
        }
    }

    func testEveryLightButTheSunsEndsItsPath() {
        let records = lights()
        let tree = LightTree(lights: records)
        XCTAssertEqual(tree.nodes.count, 2 * (records.count - 1) - 1)
        for (l, path) in tree.paths.enumerated() {
            if Int(records[l].color.w) / 4 == Int(GPULight.sun) {
                XCTAssertEqual(path.y, LightTree.notInTree)
                continue
            }
            XCTAssertLessThanOrEqual(path.y, 32)
            var node = 0
            for depth in 0..<Int(path.y) {
                let link = tree.nodes[node].link
                XCTAssertEqual(link.x & LightTree.leaf, 0)
                node = Int((path.x >> UInt32(depth)) & 1 == 0 ? link.x : link.y)
            }
            XCTAssertEqual(tree.nodes[node].link.x, LightTree.leaf | UInt32(l))
        }
        checkStructure(tree)
    }

    /// A spot's and a rect's cones (both down) merge to a cone down; with an omnidirectional light, every direction.
    func testConesMerge() {
        let spot = light(GPULight.spot, at: [0, 4, 0], axis: [0, -1, 0], params: [cos(0.6), cos(0.4), 0, 0])
        let rect = light(GPULight.rect, at: [1, 4, 0], radius: 0, axis: [0, -1, 0], params: [0.5, 0, 0, 0.25])
        let down = LightTree(lights: [spot, rect]).nodes[0]
        XCTAssertLessThan(distance(SIMD3(down.axis.x, down.axis.y, down.axis.z), [0, -1, 0]), 1e-4)
        XCTAssertEqual(down.hi.w, cos(0.4), accuracy: 1e-4, "the spot's inner cone holds the rect's normal")
        XCTAssertEqual(down.axis.w, 0, accuracy: 1e-5, "the rect's cosine falloff reaches 90 degrees")
        let all = LightTree(lights: [spot, rect, light(GPULight.sphere, at: [2, 0, 0])]).nodes[0]
        XCTAssertEqual(all.hi.w, -1)
    }

    /// Moved lights take their bounds with them, dimmed ones their power, up to the root.
    func testRefitFollowsTheLights() {
        var records = lights()
        var tree = LightTree(lights: records)
        let before = tree.version
        records[5].positionRadius = SIMD4(100, 50, -20, 0.1)
        records[9].color = SIMD4(0, 0, 0, records[9].color.w)
        tree.refit(lights: records, moved: [5], scaled: [9])
        XCTAssertGreaterThan(tree.version, before)
        let root = tree.nodes[0]
        XCTAssertGreaterThanOrEqual(root.hi.x, 100.1 - 1e-4)
        XCTAssertGreaterThanOrEqual(root.hi.y, 50.1 - 1e-4)
        XCTAssertLessThanOrEqual(root.lo.z, -20.1 + 1e-4)
        XCTAssertEqual(root.lo.w, LightTree(lights: records).nodes[0].lo.w, accuracy: 1e-3)
        checkStructure(tree)
        tree.refit(lights: records, moved: [], scaled: [])
        XCTAssertEqual(tree.version, before + 1, "nothing changed: no new version")
    }

    func testSunsAloneMakeNoTree() {
        XCTAssertTrue(LightTree(lights: [light(GPULight.sun, at: .zero, axis: [0, 1, 0])]).nodes.isEmpty)
    }
}
