import XCTest
import simd
@testable import MetalRenderer

/// The skin's UVs (SkinAtlas), the base's head in them (SkinChart) and the textures drawn over it (SkinTextures).
/// Skipped where Assets/Characters isn't there. `METALRENDERER_SKIN_DUMP=<folder>` writes the textures as PNGs.
final class CharacterSkinTests: XCTestCase {
    private func kit() throws -> CharacterKit {
        guard let kit = CharacterKit.shared() else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        return kit
    }

    private func texel(_ image: FoliageTextures.Image, _ uv: SIMD2<Float>) -> SIMD4<Float> {
        let x = min(Int(uv.x * Float(image.width)), image.width - 1), y = min(Int(uv.y * Float(image.height)), image.height - 1)
        let i = 4 * (y * image.width + x)
        return SIMD4((0..<4).map { Float(image.pixels[i + $0]) / 255 })
    }

    /// Every skin vertex has a place in the atlas: the head's above the last row, mirrored vertices at the same place
    /// (the map folds at the face's middle), the body's on the last row.
    func testTheSkinHasUVs() throws {
        let k = try kit()
        let c = k.base.character
        let sculpt = FaceSculpt(c)!
        let surface = Set([CharacterBase.Region.head.rawValue, CharacterBase.Region.neck.rawValue, CharacterBase.Region.trunk.rawValue])
        var head = 0
        for v in c.positions.indices where surface.contains(k.base.regions[v]) {
            let uv = c.uvs[v], q = sculpt.local(c.positions[v])
            XCTAssert(uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1, "vertex \(v): \(uv)")
            if q.y > 1.5 { head += 1; XCTAssertLessThan(uv.y, 1) }
            if q.y < SkinAtlas.bottom { XCTAssertEqual(uv.y, 1) }
        }
        XCTAssertGreaterThan(head, 10_000)
        XCTAssertEqual(SkinAtlas.uv([0.03, 1.68, 0.08]), SkinAtlas.uv([-0.03, 1.68, 0.08]))
    }

    /// The chart covers the head: nearly every texel above the neck shows a point of it, on the head's surface (the
    /// sculpt's distance near zero), where the atlas says.
    func testTheChartCoversTheHead() throws {
        let k = try kit()
        let chart = k.chart
        var covered = 0, total = 0, off = 0
        for y in stride(from: 0, to: chart.size, by: 8) {
            let height = SkinAtlas.top - (Float(y) + 0.5) / Float(chart.size) * (SkinAtlas.top - SkinAtlas.bottom)
            guard height > 1.57, height < 1.8 else { continue }   // (the head's mesh, not the neck's body)
            for x in stride(from: 0, to: chart.size, by: 8) {
                let i = y * chart.size + x
                total += 1
                guard chart.covered[i] else { continue }
                covered += 1
                if abs(FaceSculpt.field(chart.points[i])) > 0.003 { off += 1 }
            }
        }
        XCTAssertGreaterThan(Float(covered) / Float(total), 0.97)
        XCTAssertLessThan(Float(off) / Float(total), 0.03, "texels whose point isn't on the head")
    }

    /// The textures: plain from the neck down; the features where the face's landmarks put them, as strong as the
    /// DNA asks; the wrinkles deeper with age.
    func testTheTexturesFollowTheFaceAndTheDNA() throws {
        let k = try kit()
        let chart = k.chart
        var plain = CharacterDNA()
        plain.hair.beard = "none"
        var marked = plain
        marked.look.freckles = 1
        marked.look.lipstick = 1
        marked.look.blush = 1
        let a = SkinTextures.colour(chart, SkinTextures.Marks(plain)), b = SkinTextures.colour(chart, SkinTextures.Marks(marked))
        // The body (last row): plain.
        let neutral = SkinTextures.colourScale
        for x in stride(from: 0, to: a.width, by: 64) {
            let t = texel(a, SIMD2((Float(x) + 0.5) / Float(a.width), 0.999))
            XCTAssertEqual(t.x, neutral, accuracy: 2 / 255)
            XCTAssertEqual(t.y, neutral, accuracy: 2 / 255)
        }
        // The lips' middle: lipstick takes green out; the cheek: blush and freckles darken it; the forehead's top much
        // less.
        let lips = SkinAtlas.uv([0.008, 1.62, 0.1]), cheek = SkinAtlas.uv([0.045, 1.65, 0.084]), forehead = SkinAtlas.uv([0, 1.78, 0.07])
        XCTAssertLessThan(texel(b, lips).y, texel(a, lips).y - 0.2)
        let cheekDrop = simd_reduce_add(texel(a, cheek) - texel(b, cheek)), foreheadDrop = simd_reduce_add(texel(a, forehead) - texel(b, forehead))
        XCTAssertGreaterThan(cheekDrop, 0.08)
        XCTAssertLessThan(foreheadDrop, cheekDrop / 2)
        // Wrinkles: an old forehead's normals stray further from flat than a young one's.
        let young = SkinTextures.normals(chart, wrinkles: 0), old = SkinTextures.normals(chart, wrinkles: 1)
        func stray(_ image: FoliageTextures.Image) -> Float {
            var sum: Float = 0
            for y in 0..<40 {
                for x in 0..<40 {
                    let uv = SkinAtlas.uv([Float(x - 20) * 0.001, 1.72 + Float(y) * 0.001, 0.09])
                    sum += 1 - texel(image, uv).z
                }
            }
            return sum
        }
        XCTAssertGreaterThan(stray(old), stray(young) * 1.3)
        // Flat below the neck.
        let n = texel(young, SIMD2(0.5, 0.999))
        XCTAssertEqual(n.z, 1, accuracy: 2 / 255)
        if let folder = ProcessInfo.processInfo.environment["METALRENDERER_SKIN_DUMP"] {
            let url = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, image) in [("colour", a), ("colour-marked", b), ("normals-young", young), ("normals-old", old),
                                  ("roughness", SkinTextures.roughness(chart))] {
                try ProceduralTextures.png(image.pixels, size: image.width)?.write(to: url.appendingPathComponent("skin-\(name).png"))
            }
        }
    }
}
