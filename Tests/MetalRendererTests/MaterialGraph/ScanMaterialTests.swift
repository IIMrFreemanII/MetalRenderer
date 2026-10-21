import XCTest
import Metal
import ImageIO
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Plants

/// Scanned materials from downloads (ScanMaterial): which file is which map, the name a download suggests, an import
/// from a folder and from a .zip (the maps copied, the graph wired, the bake reading greys as greys), an EXR as a PNG.
final class ScanMaterialTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("scan-material-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    func testMapsByName() {
        func m(_ name: String) -> String? {
            ScanMaterial.map(of: URL(fileURLWithPath: "/x/" + name)).map { $0.0.rawValue + ($0.directX ? " dx" : "") }
        }
        // Poly Haven's.
        XCTAssertEqual(m("rock_wall_17_diff_4k.jpg"), "albedo")
        XCTAssertEqual(m("rock_wall_17_nor_gl_4k.exr"), "normal")
        XCTAssertEqual(m("rock_wall_17_nor_dx_4k.exr"), "normal dx")
        XCTAssertEqual(m("rock_wall_17_rough_4k.exr"), "roughness")
        XCTAssertEqual(m("rock_wall_17_disp_4k.png"), "height")
        XCTAssertEqual(m("rock_wall_17_ao_4k.jpg"), "ao")
        XCTAssertEqual(m("rock_wall_17_arm_4k.jpg"), "arm")
        XCTAssertEqual(m("metal_plate_02_diff_2k.jpg"), "albedo")
        XCTAssertEqual(m("metal_plate_02_metal_2k.jpg"), "metallic")
        // ambientCG's.
        XCTAssertEqual(m("Rock030_4K-JPG_Color.jpg"), "albedo")
        XCTAssertEqual(m("Rock030_4K-JPG_NormalGL.jpg"), "normal")
        XCTAssertEqual(m("Rock030_4K-JPG_NormalDX.jpg"), "normal dx")
        XCTAssertEqual(m("Rock030_4K-JPG_Roughness.jpg"), "roughness")
        XCTAssertEqual(m("Rock030_4K-JPG_Displacement.jpg"), "height")
        XCTAssertEqual(m("Rock030_4K-JPG_AmbientOcclusion.jpg"), "ao")
        XCTAssertEqual(m("Rock030_4K-JPG_Opacity.jpg"), "opacity")
        // Not maps.
        XCTAssertNil(m("Rock030.png"))
        XCTAssertNil(m("rock_wall_17_4k.blend"))
        XCTAssertNil(m("Rock030_4K-JPG.usda"))
    }

    func testSuggestedNames() {
        XCTAssertEqual(ScanMaterial.suggestedName(for: URL(fileURLWithPath: "/d/rock_wall_17_4k.blend.zip")), "Rock Wall 17")
        XCTAssertEqual(ScanMaterial.suggestedName(for: URL(fileURLWithPath: "/d/Rock030_4K-JPG.zip")), "Rock030")
        XCTAssertEqual(ScanMaterial.suggestedName(for: URL(fileURLWithPath: "/d/brown_mud_02")), "Brown Mud 02")
    }

    /// A download's folder: colour, a DirectX normal (and a worse JPEG of it), a grey roughness and height, a .blend and
    /// a preview that are not maps.
    private func download(_ name: String) throws -> URL {
        let dir = temp.appendingPathComponent(name)
        let maps = dir.appendingPathComponent("textures")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let side = 32
        func png(_ file: String, _ v: SIMD4<Float>, grey: Bool) throws {
            try MatExport.write(Array(repeating: v, count: side * side), side: side, grey: grey, srgb: !grey, format: .png8,
                                to: maps.appendingPathComponent(file))
        }
        try png("test_rock_diff_1k.png", [0.6, 0.4, 0.2, 1], grey: false)
        try png("test_rock_nor_dx_1k.png", [0.5, 0.5, 1, 1], grey: false)
        try png("test_rock_rough_1k.png", [0.8, 0.8, 0.8, 1], grey: true)
        try png("test_rock_disp_1k.png", [0.7, 0.7, 0.7, 1], grey: true)
        try png("test_rock.png", [1, 0, 0, 1], grey: false)
        try Data("not a map".utf8).write(to: dir.appendingPathComponent("test_rock_1k.blend"))
        try Data("{\"metres\": 2.5}".utf8).write(to: dir.appendingPathComponent("info.json"))
        return dir
    }

    func testInstallFromAFolderAndAZip() throws {
        let source = try download("test_rock_1k")
        XCTAssertEqual(ScanMaterial.metres(in: source), 2.5)
        let detected = ScanMaterial.detect(in: source)
        XCTAssertEqual(Set(detected.files.keys), [.albedo, .normal, .roughness, .height])
        XCTAssertTrue(detected.normalDirectX)

        let root = temp.appendingPathComponent("Textures")
        let a = try ScanMaterial.install(from: source, name: "Test Rock", metres: 2.5, texturesRoot: root)
        XCTAssertEqual(a.folder.lastPathComponent, "test-rock")
        let files = try FileManager.default.contentsOfDirectory(atPath: a.folder.path).sorted()
        XCTAssertEqual(files, ["albedo.png", "height.png", "info.json", "normal.png", "roughness.png"])
        let g = a.graph
        XCTAssertEqual(g.name, "Test Rock")
        XCTAssertEqual(g.size, 8, "32 pixels: the smallest size")
        XCTAssertTrue(g.surface.normalDirectX)
        XCTAssertEqual(g.surface.uvScale, 1 / 2.5, accuracy: 1e-6)
        XCTAssertGreaterThan(g.surface.displacement, 0)
        let bitmaps = g.nodes.filter { $0.kind == .bitmap }
        XCTAssertEqual(bitmaps.count, 4)
        for n in bitmaps { XCTAssertTrue(n.text("path").hasPrefix(a.folder.resolvingSymlinksInPath().path), n.text("path")) }
        let usages = Set(g.nodes.filter { $0.kind == .output }.map { $0.choice("usage") })
        XCTAssertEqual(usages, ["baseColor", "normal", "roughness", "height", "ambientOcclusion"])

        // The same as a .zip: unpacked, into a folder of its own.
        let zip = temp.appendingPathComponent("test_rock_1k.zip")
        let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", source.path, zip.path])
        ditto.waitUntilExit()
        let b = try ScanMaterial.install(from: zip, name: "Test Rock", metres: 2.5, texturesRoot: root)
        XCTAssertEqual(b.folder.lastPathComponent, "test-rock-2")
        XCTAssertEqual(b.graph.nodes.filter { $0.kind == .bitmap }.count, 4)

        // No colour map: nothing is copied.
        let empty = temp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ScanMaterial.install(from: empty, name: "Nothing", metres: 1, texturesRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nothing").path))

        // Baked: the grey files read as greys (their luminance, not their red's).
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let engine = MatEngine(device: device)
        let r = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        let height = engine.read(try XCTUnwrap(r.outputs.height))
        XCTAssertEqual(height[100].x, 0.7, accuracy: 0.01)
        let orm = engine.read(try XCTUnwrap(r.outputs.orm))
        XCTAssertEqual(orm[100].y, 0.8, accuracy: 0.01, "roughness")
    }

    /// With SCAN_IMPORT=<a download's .zip or folder>: imports it into a temporary folder and bakes it, printing what
    /// it found, how long each step took and every output's mean.
    func testImportADownload() throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_IMPORT"] else { throw XCTSkip("SCAN_IMPORT=<zip or folder>") }
        let t0 = Date()
        let a = try ScanMaterial.install(from: URL(fileURLWithPath: path), name: ScanMaterial.suggestedName(for: URL(fileURLWithPath: path)),
                                         metres: 1.8, texturesRoot: temp.appendingPathComponent("Textures"))
        print("imported \(a.graph.name) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s, size \(a.graph.size), skipped \(a.skipped)")
        for f in try FileManager.default.contentsOfDirectory(atPath: a.folder.path).sorted() { print("  \(f)") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let engine = MatEngine(device: device)
        let t1 = Date()
        let r = engine.evaluateNow(try MatPlan(a.graph, library: { _ in nil }))
        print("baked in \(String(format: "%.2f", Date().timeIntervalSince(t1))) s")
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        for (name, t) in [("baseColor", r.outputs.baseColor), ("normal", r.outputs.normal), ("orm", r.outputs.orm), ("height", r.outputs.height)] {
            guard let t else { continue }
            let px = engine.read(t, level: 4)
            let mean = px.reduce(SIMD4<Float>.zero, +) / Float(max(px.count, 1))
            print("  \(name) mean \(mean)")
        }
    }

    /// The built-in scan's maps are in Assets/ (Git LFS) and read.
    func testRockWallMapsAreThere() throws {
        let g = MaterialLibrary.rockWall17()
        XCTAssertEqual(g.size, 12)
        for n in g.nodes where n.kind == .bitmap {
            let url = Scene.assetsDirectory.appendingPathComponent(n.text("path"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    /// An EXR (here one macOS writes) as a 16-bit PNG: the values kept, a colour map's turned sRGB.
    func testEXRToPNG() throws {
        let side = 8
        let pixels = (0..<(side * side)).map { i in SIMD4<Float>(Float(i) / 64, 0.25, 0.75, 1) }
        let exr = temp.appendingPathComponent("map.exr")
        try MatExport.write(pixels, side: side, grey: false, srgb: false, format: .exr, to: exr)
        let png = temp.appendingPathComponent("map.png")
        try ScanMaterial.convertEXR(exr, to: png, srgb: false)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
        var back = [SIMD4<Float>](repeating: .zero, count: side * side)
        back.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 32, bytesPerRow: side * 16,
                                space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        for i in [0, 13, 63] {
            XCTAssertEqual(back[i].x, pixels[i].x, accuracy: 1e-3)
            XCTAssertEqual(back[i].y, 0.25, accuracy: 1e-3)
            XCTAssertEqual(back[i].z, 0.75, accuracy: 1e-3)
        }
    }
}
