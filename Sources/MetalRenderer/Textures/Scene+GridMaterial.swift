import EngineCore
import simd

/// How a grid floor looks (Scene.addGridMaterial; Surface.metal previewGrid draws it): tiles of `tile` colour `size` m
/// square ruled at their edges, `line` of their colour; a subgrid of five a tile at `subgrid` of the lines' strength and
/// crosses at every other corner at `crosses`; roughness `roughness`, specular `specular`
/// (GPUMaterial.params.x: 1 is a dielectric's 4%).
package struct GridLook: Equatable {
    package var tile: SIMD3<Float>
    package var size: Float = 1
    package var line: Float = 0.5
    package var subgrid: Float = 0.5
    package var crosses: Float = 1
    package var roughness: Float = 0.7
    package var specular: Float = 0.1

    package init(tile: SIMD3<Float>, size: Float = 1, line: Float = 0.5, subgrid: Float = 0.5, crosses: Float = 1,
                 roughness: Float = 0.7, specular: Float = 0.1) {
        self.tile = tile
        self.size = size
        self.line = line
        self.subgrid = subgrid
        self.crosses = crosses
        self.roughness = roughness
        self.specular = specular
    }

    /// Unreal's asset preview floor (its M_Grid): metre tiles of 0.5 grey under its base texture's 0.33 (so 0.167
    /// linear), lines half that, the subgrid at half strength, crosses every 2 m; specular 0.05 (a tenth of Unreal's
    /// 0.5); roughness 0.7, about the mean of Unreal's 0.4...0.8 (its noise over 5 m shows as waves in the far floor's
    /// reflections here).
    package static let previewFloor = GridLook(tile: SIMD3(repeating: 0.167))
}

extension Scene {
    /// A grid floor's material (`look`): world-aligned, on whatever plane a triangle faces most, so its tiles keep
    /// their size whatever the mesh's scale. (Its extra's kind is GPUMaterialExtra.gridKind; no textures.)
    package func addGridMaterial(_ look: GridLook = .previewFloor) -> Int {
        let index = addMaterial(GPUMaterial(albedo: SIMD4(look.tile, 0), emission: SIMD4(.zero, look.roughness),
                                            params: SIMD4(look.specular, 1, 0, 0)))
        var extra = GPUMaterialExtra()
        extra.textures.z = GPUMaterialExtra.gridKind
        extra.surface = SIMD4(max(look.subgrid, 0), look.size, look.line, look.crosses)
        materialExtras[index] = extra
        return index
    }
}
