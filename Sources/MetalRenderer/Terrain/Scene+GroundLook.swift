import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants
import QuartzCore
import simd

extension Scene {
    /// The realistic ground's tiling noise (brightness, hue, roughness, break-up: RGBA), shared by every terrain.
    package func terrainMacroTexture() -> UInt32 {
        addGeneratedTexture(name: "terrain-macro", width: 512, height: 512, key: "v1", srgb: false) {
            var pixels = [UInt8](repeating: 0, count: 512 * 512 * 4)
            for j in 0..<512 {
                for i in 0..<512 {
                    let u = Float(i) / 512, v = Float(j) / 512
                    for c in 0..<4 {
                        let s = UInt32(71 + 13 * c)
                        let n = 0.6 * FoliageTextures.noise(u * 4, v * 4, 4, 4, s) + 0.3 * FoliageTextures.noise(u * 11, v * 11, 11, 11, s + 1)
                            + 0.15 * FoliageTextures.noise(u * 29, v * 29, 29, 29, s + 2)
                        pixels[(j * 512 + i) * 4 + c] = UInt8(min(max(0.5 + 0.5 * n, 0), 1) * 255)
                    }
                }
            }
            return FoliageTextures.Image(width: 512, height: 512, pixels: pixels)
        }
    }

    /// A material for a realistic layer: its scan, or without it its colour over the generated detail.
    package func groundLayerMaterial(set: String, color: SIMD3<Float>, tint: SIMD3<Float> = .one, roughness: Float = 1, detail: UInt32) -> Int {
        if let m = addScanMaterial(set, tint: tint, roughness: roughness) { return m }
        var m = GPUMaterial(albedo: SIMD4(color / FoliageTextures.mean, 0), emission: SIMD4(.zero, 0.95 * roughness))
        m.textures.x = detail
        return addMaterial(m)
    }

    /// The scene's terrain's ground as `look` says (with the realistic look on; after `addTerrain`, before
    /// `finishTerrainLayers`).
    package func addGroundLook(_ look: GroundLook) {
        guard settings.realism != .off, let t = terrain else { return }
        let detail = t.detail != .max ? t.detail : terrainDetailTexture()
        var rows = GroundRows()
        for l in look.layers.prefix(GroundLook.maxLayers) {
            rows.materials.append(groundLayerMaterial(set: l.set, color: l.color, tint: l.tint, roughness: l.roughness, detail: detail))
            rows.metres.append(l.metres ?? TextureSet.find(l.set)?.metres ?? 3)
            rows.contrast.append(l.contrast)
        }
        final class Drawn { var maps: (FoliageTextures.Image, FoliageTextures.Image)? }
        let drawn = Drawn(), n = look.texels, key = look.key
        func maps() -> (FoliageTextures.Image, FoliageTextures.Image) {
            if let m = drawn.maps { return m }
            // (The last few scenes' maps, by their keys: realism high reads them on the CPU at every make, and a
            // workshop is made again at every edit.)
            if let m = GroundLook.recent(key) { drawn.maps = m; return m }
            let m = look.draw()
            drawn.maps = m
            GroundLook.remember(key, m)
            return m
        }
        rows.mapA = addGeneratedTexture(name: "ground-map-a", width: n, height: n, key: key, srgb: false) { maps().0 }
        if look.layers.count > 4 {
            rows.mapB = addGeneratedTexture(name: "ground-map-b", width: n, height: n, key: key, srgb: false) { maps().1 }
        }
        rows.rock = look.rock ?? -1
        rows.slope = look.slope
        rows.lo = look.lo
        rows.size = look.size
        t.ground = rows
        // (Realism high: the near ground refined once every sector is in: finishTerrainLayers.)
        if settings.realism == .high { t.pendingRefine = (look, rows, maps()) }
    }

    /// Realism high: the terrain's level-0 sectors within REFINE_REACH of the detail centre (a rectangle of them, so
    /// that their seams with the coarse ones are only on its outside) made again fine, 0.25 m (at most 4 x 4 a cell)
    /// apart, their ground raised by `look`'s relief (GroundRelief: the shader's height lerp on the CPU). Before the
    /// renderer has the meshes: each takes its coarse mesh's place.
    package func refineTerrain(_ look: GroundLook, rows: GroundRows, maps: (FoliageTextures.Image, FoliageTextures.Image)) {
        guard let t = terrain else { return }
        let started = CACurrentMediaTime()
        let reach: Float = 32
        let grid = t.field.grid, offset = t.offset
        let center = terrainDetailCenter ?? Scene.demoCamera(settings.kind).map { SIMD2($0.position.x, $0.position.z) } ?? .zero
        func rect(_ s: TerrainSector) -> (lo: SIMD2<Float>, hi: SIMD2<Float>) {
            let a = grid.place(s.first.x, s.first.y) - offset, b = grid.place(s.last.x, s.last.y) - offset
            return (SIMD2(Float(a.x), Float(a.y)), SIMD2(Float(b.x), Float(b.y)))
        }
        let chosen = t.parts.indices.filter { k in
            let p = t.parts[k]
            guard p.sector.level == 0, p.sector.subdiv == 1 else { return false }
            let r = rect(p.sector)
            return r.hi.x > center.x - reach && r.lo.x < center.x + reach && r.hi.y > center.y - reach && r.lo.y < center.y + reach
        }
        guard !chosen.isEmpty else {
            print("Terrain: no level-0 sector within \(Int(reach)) m of \(center) to refine (\(t.parts.count) parts)")
            return
        }
        // The block's outline: a side on it has a coarse neighbour (a seam) unless it is the terrain's own edge.
        let block = chosen.map { rect(t.parts[$0].sector) }
        let lo = block.map(\.lo).reduce(SIMD2(repeating: .infinity), simd_min), hi = block.map(\.hi).reduce(SIMD2(repeating: -.infinity), simd_max)
        let edgeLo = grid.lo.map { grid.place($0.x, $0.y) - offset }, edgeHi = grid.hi.map { grid.place($0.x, $0.y) - offset }
        let subdiv = min(4, max(2, Int((grid.cell / 0.25).rounded())))
        // The relief: the look's layers' scans, and the painted layers' (their scans by name, as their materials).
        let ground = look.layers.prefix(GroundLook.maxLayers).enumerated().map { k, l in
            GroundRelief.Layer(height: TextureSet.find(l.set)?.heightField(), scale: 1 / max(rows.metres[k], 0.05), contrast: l.contrast,
                               relief: l.relief ?? GroundRelief.relief(of: l.set))
        }
        let painted: [GroundRelief.Layer?] = (1..<TerrainTile.layers).map { l in
            guard let metres = t.scanMetres[l], l < t.meshStyle.layers.count, let set = t.meshStyle.layers[l].scanSet else { return nil }
            return GroundRelief.Layer(height: TextureSet.find(set)?.heightField(), scale: 1 / max(metres, 0.05), contrast: 1,
                                      relief: GroundRelief.relief(of: set))
        }
        let relief = GroundRelief(ground: ground, painted: painted, maps: maps, lo: look.lo, size: look.size, rock: look.rock ?? -1,
                                  slope: look.slope, offset: offset)
        var style = t.meshStyle
        style.relief = relief
        t.meshStyle = style
        let snapshot = t.field.snapshot()
        var sectors: [TerrainSector] = chosen.map { k in
            var s = t.parts[k].sector
            let r = rect(s)
            s.subdiv = subdiv
            func seam(_ side: Float, _ outline: Float, _ edge: Float?) -> Bool { side == outline && side != edge }
            s.seams = (seam(r.lo.y, lo.y, edgeLo.map { Float($0.y) }) ? 1 : 0) | (seam(r.hi.y, hi.y, edgeHi.map { Float($0.y) }) ? 2 : 0)
                | (seam(r.lo.x, lo.x, edgeLo.map { Float($0.x) }) ? 4 : 0) | (seam(r.hi.x, hi.x, edgeHi.map { Float($0.x) }) ? 8 : 0)
            return s
        }
        var meshes = [TerrainSectorMesh?](repeating: nil, count: sectors.count)
        meshes.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: sectors.count) { i in out[i] = TerrainSectorMesh(snapshot, sector: sectors[i], style: style) }
        }
        var triangles = 0
        for (i, k) in chosen.enumerated() {
            guard let m = meshes[i] else { continue }
            let name = sectors[i].meshName(terrain: t.name)
            replaceBorrowed(t.parts[k].mesh, with: m.borrowed, bounds: m.bounds, name: name)
            t.replace(k, sector: sectors[i], name: name)
            t.fineParts.insert(k)
            triangles += sectors[i].triangleCount
        }
        sectors.removeAll()
        print(String(format: "Terrain: %d sectors near the camera refined %dx (%.0fk triangles) in %.0f ms", chosen.count, subdiv,
                     Double(triangles) / 1000, (CACurrentMediaTime() - started) * 1000))
    }

    /// The realistic look's grass on the scene's terrain round `center` (Flora.meadow), where `density` says, with its own
    /// flora (the built-in grass) unless the scene's has grass. How many patches.
    @discardableResult
    package func addMeadowGrass(center: SIMD2<Float>, reach: Float, seed: UInt64, flora given: Flora? = nil, density: (Float, Float) -> Float) -> Int {
        guard settings.realism != .off, let t = terrain else { return 0 }
        let flora = given ?? Flora(self, seed: seed, catalog: .builtIn, species: [.grass])
        func ground(_ x: Float, _ z: Float) -> (Float, SIMD3<Float>) {
            let h = t.height(x, z), dx = t.height(x + 0.5, z) - t.height(x - 0.5, z), dz = t.height(x, z + 0.5) - t.height(x, z - 0.5)
            return (h, simd_normalize(SIMD3(-dx, 1, -dz)))
        }
        return flora.meadow(center: center, reach: reach, seed: seed, ground: ground, density: density)
    }

    /// The generated detail texture the plain layers' colours are multiplied by.
    package func terrainDetailTexture() -> UInt32 {
        addGeneratedTexture(name: "terrain-detail", width: 512, height: 512, key: "v\(FoliageTextures.version)") {
            FoliageTextures.image(512, 512, normalized: true) { u, v in
                let clumps = FoliageTextures.noise(u * 6, v * 6, 6, 6, 41) + 0.6 * FoliageTextures.noise(u * 17, v * 17, 17, 17, 42)
                let specks = FoliageTextures.noise(u * 60, v * 60, 60, 60, 43)
                return SIMD3(repeating: max(0.75 + 0.3 * clumps + 0.22 * specks, 0.1))
            }
        }
    }
}
