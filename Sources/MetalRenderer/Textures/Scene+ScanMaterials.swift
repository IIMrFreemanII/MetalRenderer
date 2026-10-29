import Buildings
import Characters
import CoreGraphics
import Effects
import EngineCore
import Foundation
import ImageIO
import Landscape
import Materials
import Physics
import Plants
import simd

extension Scene {
    /// A scanned material (TextureSet `set`): its albedo (times `tint`), normal, and occlusion-roughness-height maps,
    /// tiled every `metres` of UV (nil: the scan's own size; a mesh's UVs are metres). Nil if the set isn't there.
    /// `roughness` scales the scan's (after it is raised to at least `minRoughness`: natural surfaces stay above
    /// REFLECTION_MAX_ROUGHNESS, where a traced reflection costs much and shows little); `ao` how much its occlusion darkens it.
    package func addScanMaterial(_ name: String, tint: SIMD3<Float> = .one, roughness: Float = 1, ao: Float = 1, specular: Float = 1,
                         normalScale: Float = 1, minRoughness: Float = 0.7, leafSheet: Bool = false) -> Int? {
        guard let set = TextureSet.find(name), let albedoData = set.data(.albedo), let normalData = set.data(.normal) else { return nil }
        let model = set.cacheModel, floor = Int(minRoughness * 100)
        let known = scanTextures["\(name) \(floor)"] ?? scanTextures.first { $0.key.hasPrefix("\(name) ") }.map { SIMD3($0.value.x, $0.value.y, .max) }
        let side = Self.scanSize(set)
        // (A leaf sheet's made ready for its tint: TextureSet.sheetAlbedo.)
        let albedo = known?.x ?? (leafSheet && set.url(.opacity) != nil
            ? addTexture(TextureSource(data: Data(), srgb: true, name: "scan/\(name)/albedo", modelPath: model, cacheKey: "sheet-albedo-v1",
                                       raw: Self.albedoSize(set), pixels: {
                                           let (w, h) = Self.albedoSize(set)
                                           return Data(set.sheetAlbedo()?.pixels ?? [UInt8](repeating: 128, count: w * h * 4)) }))
            : addTexture(TextureSource(data: albedoData, srgb: true, name: "scan/\(name)/albedo", modelPath: model, cacheKey: "albedo")))
        let normal = known?.y ?? addTexture(TextureSource(data: normalData, srgb: false, name: "scan/\(name)/normal", modelPath: model, cacheKey: "normal"))
        let ormh = known.flatMap { $0.z == .max ? nil : $0.z } ?? addTexture(TextureSource(
            data: Data(), srgb: false, name: "scan/\(name)/ormh-\(floor)", modelPath: model, cacheKey: "ormh-v2-\(side.x)x\(side.y)-\(floor)",
            raw: (side.x, side.y), pixels: { Data(set.ormh(minRoughness: minRoughness)?.pixels ?? [UInt8](repeating: 255, count: side.x * side.y * 4)) }))
        scanTextures["\(name) \(floor)"] = SIMD3(albedo, normal, ormh)
        let index = addMaterial(GPUMaterial(albedo: SIMD4(tint, 0), emission: SIMD4(.zero, roughness), params: SIMD4(specular, normalScale, 0, 0),
                                            textures: SIMD4(albedo, ormh, normal, .max)))
        var extra = GPUMaterialExtra()
        extra.textures.z = 2   // a scan's (Surface.metal: its GI hits take its colour alone)
        extra.surface = SIMD4(0, 1, 0.5, ao)
        materialExtras[index] = extra
        return index
    }

    /// A leaf sheet's material (TextureSet `name`, "leaves" the shared one: its leaves `cells` a row): each generated
    /// leaf shows one of them (Surface.metal, its extras' parallax minus the cells: a kite leaf's pick; an outline
    /// leaf's UVs are its own place on the sheet), two-sided where the camera sees it (LEAF_TRANSMIT). `albedo`: its
    /// colour over the sheet's (the season changes it: LeafMaterial.gain), `translucency` as a leaf's.
    package func addLeafSheetMaterial(_ name: String = "leaves", albedo: SIMD3<Float>, translucency: Float, cells: Int = 3) -> Int? {
        // (Roughness 0.35...1 from the scan's map, about 0.6 over a leaf: glossy enough for its reflection rays and a
        // sun highlight, as Unreal's foliage material's 0.5 has. From 0.62, every leaf came out past 0.75, matte.)
        guard let index = addScanMaterial(name, tint: albedo, roughness: 1, ao: 0, specular: 0.6, normalScale: 0.7, minRoughness: 0.35,
                                          leafSheet: true)
        else { return nil }
        var m = materials[index]
        m.params.w = translucency
        setMaterial(index, m)
        materialExtras[index]?.surface.x = -Float(cells)
        hasLeafSheets = true
        return index
    }

    /// Leaves of the realistic look that aren't a sheet's (grass, needles, fronds): each its own shade, two-sided where
    /// the camera sees it, fluttering (Surface.metal leafLook). `grid`: the sheet its outline leaves were traced from,
    /// columns and rows (each leaf's own cell then shows the generated leaf whole), carried in `surface.z` as
    /// 16 × columns + rows (no opacity map reads it on these).
    package func markRealisticLeaf(_ index: Int, grid: SIMD2<Int> = SIMD2(3, 3)) {
        var extra = materialExtras[index] ?? GPUMaterialExtra()
        extra.surface.x = -0.25
        extra.surface.z = Float(16 * grid.x + grid.y)
        materialExtras[index] = extra
        hasLeafSheets = true
    }

    /// The size of a set's albedo, read from the file's header.
    package static func albedoSize(_ set: TextureSet) -> (Int, Int) {
        guard let url = set.url(.albedo), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return (2048, 2048) }
        return (w, h)
    }

    /// The size of a set's roughness (what its packed map is drawn at), read from the file's header.
    package static func scanSize(_ set: TextureSet) -> SIMD2<Int> {
        guard let url = set.url(.roughness) ?? set.url(.albedo), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return [2048, 2048] }
        return [w, h]
    }
}
