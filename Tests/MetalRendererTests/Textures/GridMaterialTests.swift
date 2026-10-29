import XCTest
import simd
@testable import EngineCore
@testable import MetalRenderer

/// Scene+GridMaterial.swift: a grid floor's look is where Surface.metal's previewGrid reads it.
final class GridMaterialTests: XCTestCase {
    func testTheLookIsWhereTheShaderReadsIt() throws {
        let scene = Scene()
        let look = GridLook(tile: [0.2, 0.3, 0.4], size: 2, line: 0.4, subgrid: 0.6, crosses: 0.7, roughness: 0.5, specular: 0.2)
        let index = scene.addGridMaterial(look)
        let m = scene.materials[index]
        XCTAssertEqual(m.albedo, SIMD4(0.2, 0.3, 0.4, 0))
        XCTAssertEqual(m.emission, SIMD4(0, 0, 0, 0.5))
        XCTAssertEqual(m.params, SIMD4(0.2, 1, 0, 0), "a plain dielectric: no light, hair, leaf or skin")
        XCTAssertEqual(m.textures, SIMD4(repeating: .max))
        let extra = try XCTUnwrap(scene.materialExtras[index])
        XCTAssertEqual(extra.textures, SIMD4(.max, .max, GPUMaterialExtra.gridKind, .max), "no textures: the textured shading is skipped")
        XCTAssertEqual(extra.surface, SIMD4(0.6, 2, 0.4, 0.7))
    }

    /// A subgrid below 0 would read as a leaf (Surface.metal leafLook: the extra's x below 0).
    func testTheSubgridIsNeverALeaf() {
        let scene = Scene()
        var look = GridLook.previewFloor
        look.subgrid = -1
        XCTAssertGreaterThanOrEqual(scene.materialExtras[scene.addGridMaterial(look)]!.surface.x, 0)
    }

    /// Unreal's M_Grid as the vegetation editor shows it: metre tiles of 0.18, lines half that, no subgrid, a tenth of
    /// the usual specular.
    func testThePreviewFloorIsUnrealsGrid() {
        let look = GridLook.previewFloor
        XCTAssertEqual(look.tile, SIMD3(repeating: 0.18))
        XCTAssertEqual(look.size, 1)
        XCTAssertEqual(look.line, 0.5)
        XCTAssertEqual(look.subgrid, 0)
        XCTAssertEqual(look.specular, 0.1)
    }
}
