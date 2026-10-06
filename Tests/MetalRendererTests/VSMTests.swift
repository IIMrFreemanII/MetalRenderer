import XCTest
import simd
@testable import MetalRenderer

/// Virtual shadow maps (VSM.swift): which lights get maps, and their views as Shaders/VSM.metal reads them (CPU replicas
/// of vsmClip, vsmPickView's sphere face and vsmPageClip).
final class VSMTests: XCTestCase {
    private func light(_ type: Float, position: SIMD3<Float> = .zero, radius: Float = 0.1, axis: SIMD3<Float> = [0, -1, 0],
                       params: SIMD4<Float> = .zero) -> GPULight {
        GPULight(positionRadius: SIMD4(position, radius), color: SIMD4(1, 1, 1, 4 * type), axis: SIMD4(axis, 0), params: params)
    }

    private func sun(toward d: SIMD3<Float>) -> GPULight {
        light(GPULight.sun, radius: 0.0047, axis: normalize(d), params: [0, 0, 0, 100])
    }

    /// vsmClip, then the window position in pages (x right, y down) and the stored depth.
    private func project(_ v: GPUVSMView, _ q: SIMD3<Float>) -> (pages: SIMD2<Float>, depth: Float, w: Float) {
        let p = SIMD4(q - SIMD3(v.origin.x, v.origin.y, v.origin.z), 1)
        let c = SIMD4(dot(v.x, p), dot(v.y, p), dot(v.z, p), dot(v.w, p))
        let ndc = SIMD2(c.x, c.y) / c.w
        return (SIMD2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5) * Float(v.pages), c.z / c.w, c.w)
    }

    private func views(_ l: VSMTargets.Light, _ g: GPULight, camera: SIMD3<Float>) -> [GPUVSMView] {
        (0..<l.views).map { v in
            var view = VSMTargets.view(l, v, g, camera: camera)
            view.pages = UInt32(VSMTargets.pagesASide(l, view: v))
            return view
        }
    }

    func testMappedLights() {
        var settings = VSMSettings()
        settings.levels = 6
        settings.maxLights = 2
        let lights = [
            light(GPULight.rect),
            sun(toward: [0.3, 1, 0.2]),
            light(GPULight.spot, params: [cos(0.5), cos(0.4), 0, 0]),
            light(GPULight.spot, params: [cos(1.5), cos(1.4), 0, 0]),   // too wide: rays
            light(GPULight.sphere),
            light(GPULight.sphere),                                     // past maxLights: rays
        ]
        let mapped = VSMTargets.mapped(lights, settings: settings)
        XCTAssertEqual(mapped.map(\.index), [1, 2, 4])
        XCTAssertEqual(mapped.map(\.kind), [.sun, .spot, .sphere])
        XCTAssertEqual(mapped.map(\.levels), [6, 8, 6], "the sun's levels; a 128-page spot's mips; a 32-page face's")
        XCTAssertEqual(mapped.map(\.views), [6, 8, 36])
        XCTAssertEqual(mapped.map(\.firstView), [0, 6, 14])
        XCTAssertEqual(VSMTargets.pagesASide(mapped[1], view: 3), 16)
        XCTAssertEqual(VSMTargets.pagesASide(mapped[2], view: 7), 16, "face 1, mip 1")
    }

    /// The sun's levels: the camera in the middle of each window, texels of 16 m x 2^l / 16384, nearer the sun deeper.
    func testSunLevels() {
        let s = sun(toward: [0.3, 1, 0.2]), d = normalize(SIMD3<Float>(0.3, 1, 0.2))
        let l = VSMTargets.Light(index: 0, kind: .sun, firstView: 0, levels: 4)
        let camera = SIMD3<Float>(123.4, 5, -67.8)
        for (level, v) in views(l, s, camera: camera).enumerated() {
            let at = project(v, camera)
            XCTAssertEqual(at.pages.x, 64.5, accuracy: 0.5)
            XCTAssertEqual(at.pages.y, 64.5, accuracy: 0.5)
            XCTAssertEqual(v.params.x, 16 * Float(1 << level) / 16384, accuracy: 1e-6)
            XCTAssertGreaterThan(project(v, camera + d).depth, at.depth, "nearer the sun: larger")
            XCTAssertEqual((project(v, camera + d).depth - at.depth) * v.params.y, 1, accuracy: 1e-3, "params.y: metres a unit")
            // The window's pages are named by where they are: the camera's page is window page 64 of absolute `window`.
            let (right, _) = VSMTargets.basis(d)
            let page = Int32(floor(dot(camera, right) / (16 * Float(1 << level) / 128)))
            XCTAssertEqual(v.window.x + 64, page)
        }
        // A moved camera moves the window, not the pages: a point keeps its absolute page.
        let q = camera + [3, 0, 1]
        let a = views(l, s, camera: camera)[0], b = views(l, s, camera: camera + [40, 0, 25])[0]
        let pa = SIMD2<Int32>(project(a, q).pages, rounding: .down) &+ a.window
        let pb = SIMD2<Int32>(project(b, q).pages, rounding: .down) &+ b.window
        XCTAssertEqual(pa, pb)
        XCTAssertTrue(VSMTargets.sameLight(a, b), "a scrolled window is the same light")
        XCTAssertFalse(VSMTargets.sameLight(a, views(l, sun(toward: [0.31, 1, 0.2]), camera: camera)[0]), "a turned sun isn't")
    }

    /// A spot's view: its axis in the middle, its outer cone inside, depth NEAR / distance; mips double the texels.
    func testSpotView() {
        let position = SIMD3<Float>(1, 4, 2), axis = normalize(SIMD3<Float>(0.2, -1, 0.1))
        let g = light(GPULight.spot, position: position, radius: 0.2, axis: axis, params: [cos(0.6), cos(0.5), 0, 0])
        let l = VSMTargets.Light(index: 0, kind: .spot, firstView: 0, levels: 8)
        let vs = views(l, g, camera: .zero)
        let centre = project(vs[0], position + axis * 3)
        XCTAssertEqual(centre.pages.x, 64, accuracy: 1e-3)
        XCTAssertEqual(centre.pages.y, 64, accuracy: 1e-3)
        XCTAssertEqual(centre.depth, vs[0].params.z / 3, accuracy: 1e-5)
        let (right, _) = VSMTargets.basis(axis)
        let edge = project(vs[0], position + (axis * cos(Float(0.6)) + right * sin(Float(0.6))) * 2)
        XCTAssertTrue(edge.pages.x > 0 && edge.pages.x < 128, "the outer cone is in view")
        XCTAssertEqual(vs[3].params.x, vs[0].params.x * 8, accuracy: 1e-7)
        XCTAssertEqual(vs[3].pages, 16)
    }

    /// A sphere light's faces: every direction is in view on the face of its major axis (vsmPickView).
    func testSphereFaces() {
        let position = SIMD3<Float>(-2, 3, 1)
        let l = VSMTargets.Light(index: 0, kind: .sphere, firstView: 0, levels: 6)
        let vs = views(l, light(GPULight.sphere, position: position), camera: .zero)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let d = normalize(SIMD3<Float>(Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng),
                                           Float.random(in: -1...1, using: &rng)))
            let a = abs(d)
            let face = a.x >= a.y && a.x >= a.z ? (d.x >= 0 ? 0 : 1) : a.y >= a.z ? (d.y >= 0 ? 2 : 3) : (d.z >= 0 ? 4 : 5)
            let at = project(vs[face * l.levels], position + d * 5)
            XCTAssertTrue(at.w > 0 && at.pages.x >= 0 && at.pages.x <= 32 && at.pages.y >= 0 && at.pages.y <= 32, "\(d)")
        }
    }

    /// vsmPageClip: a point of window page (px, py) lands in that page's own clip space, inside [-1, 1].
    func testPageClip() {
        let n: Float = 128
        for (page, inside) in [(SIMD2<Float>(3, 70), SIMD2<Float>(0.25, 0.8)), ([127, 0], [0.9, 0.1])] {
            let at = page + inside   // window pages
            let ndc = SIMD2((at.x / n) * 2 - 1, 1 - (at.y / n) * 2), w: Float = 2.5
            let c = SIMD4(ndc.x * w, ndc.y * w, 0, w)
            let x = c.x * n + c.w * (n - 2 * page.x - 1), y = c.y * n + c.w * (1 - n + 2 * page.y)
            XCTAssertEqual(x / w, inside.x * 2 - 1, accuracy: 1e-3)
            XCTAssertEqual(y / w, 1 - inside.y * 2, accuracy: 1e-3)
        }
    }
}
