import XCTest
import Metal
@testable import MetalRenderer

/// The texture streamer's bookkeeping (TextureStreamer.swift), on the GPU's device but without running a frame: the
/// feedback a frame's shaders would record is written by hand, and the mapping updates and uploads the streamer
/// answers with are read back. Both kinds of sparse texture: on a sparse heap (Metal 3) and placement sparse (Metal 4).
final class TextureStreamerTests: XCTestCase {
    private var folder: URL!
    private static let framesInFlight = 3

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MetalRendererTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// A streamer of one generated 1024 px texture: levels 0...2 are streamed, level 3 (128 px) and coarser stay.
    private func streamer(placement: Bool) throws -> TextureStreamer {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              TextureStreamer.isSupported(device, api: placement ? .metal4 : .metal3) else {
            throw XCTSkip("no \(placement ? "placement-" : "")sparse textures on this device")
        }
        let model = folder.appendingPathComponent("model.gltf")
        try Data("{}".utf8).write(to: model)
        let source = Scene.TextureSource(data: Data(count: 1024 * 1024 * 4), srgb: false, name: "test", modelPath: model.path,
                                         cacheKey: "0", raw: (1024, 1024))
        return try TextureStreamer(sources: [source], device: device, queue: queue, budgetMB: 64,
                                   slots: TextureStreamerTests.framesInFlight, placement: placement)
    }

    /// One frame: `level` is what its samples wanted (nil: the texture is out of view).
    private func step(_ s: TextureStreamer, _ frame: Int, wants level: Int?) -> TextureStreamWork {
        let slot = frame % TextureStreamerTests.framesInFlight
        if let level {
            s.feedbackBuffer(slot: slot).contents().bindMemory(to: UInt32.self, capacity: TextureStreamer.levelBins)[level] = 100
            s.collect(slot: slot)
        }
        return s.update(frame: UInt32(frame), slot: slot, framesInFlight: TextureStreamerTests.framesInFlight)
    }

    private func unmapped(_ work: TextureStreamWork) -> [Int] {
        work.mappings.flatMap { $0.ops.filter { $0.mode == .unmap }.map(\.level) }
    }

    func testLevelsFollowTheFeedback() throws {
        for placement in [false, true] {
            guard let s = try? streamer(placement: placement) else { continue }
            XCTAssertEqual(s.placement, placement)
            var work = step(s, 0, wants: nil)
            XCTAssertEqual(s.residentLevels, [3], "the first frame maps the levels that stay")
            XCTAssertFalse(work.uploads.isEmpty)
            // In view up close: a level a frame down to the finest.
            for frame in 1...3 {
                work = step(s, frame, wants: 0)
                XCTAssertEqual(s.residentLevels, [3 - frame])
                XCTAssertEqual(work.uploads.map(\.level), [3 - frame])
            }
            // Out of view: two seconds later the levels go back, finest first, and are unmapped once the frames in
            // flight are done.
            var frame = 4, unmaps: [Int] = []
            while unmaps.count < 3 {
                work = step(s, frame, wants: nil)
                XCTAssertTrue(work.uploads.isEmpty)
                for level in unmapped(work) {
                    XCTAssertLessThan(level, s.residentLevels[0], "a level in use was unmapped")
                    unmaps.append(level)
                }
                frame += 1
                XCTAssertLessThan(frame, 400, "the levels of a texture out of view were never given back")
            }
            XCTAssertEqual(unmaps, [0, 1, 2])
            XCTAssertEqual(s.residentLevels, [3])
            // Back in view: mapped and uploaded again.
            for k in 1...3 {
                work = step(s, frame + k, wants: 0)
                XCTAssertEqual(work.uploads.map(\.level), [3 - k])
            }
            XCTAssertEqual(s.residentLevels, [0])
        }
    }

    /// A level that is wanted again before its unmap ran (its frames were still in flight) is still mapped and still
    /// holds its pixels: it comes back as it is, and the unmap is dropped.
    func testALevelWantedAgainBeforeItsUnmapStays() throws {
        for placement in [false, true] {
            guard let s = try? streamer(placement: placement) else { continue }
            var frame = 0
            _ = step(s, frame, wants: nil)
            for _ in 1...4 { frame += 1; _ = step(s, frame, wants: 0) }
            XCTAssertEqual(s.residentLevels, [0])
            // Out of view until the finest level is given back...
            while s.residentLevels == [0] {
                frame += 1
                XCTAssertTrue(unmapped(step(s, frame, wants: nil)).isEmpty)
                XCTAssertLessThan(frame, 400)
            }
            XCTAssertEqual(s.residentLevels, [1])
            // ...and in view again the frame after.
            frame += 1
            var work = step(s, frame, wants: 0)
            XCTAssertEqual(s.residentLevels, [0])
            XCTAssertTrue(work.uploads.isEmpty, "placement \(placement): a level that was never unmapped was uploaded again")
            XCTAssertTrue(work.mappings.isEmpty, "placement \(placement): a level that was never unmapped was mapped again")
            for _ in 0..<8 {
                frame += 1
                work = step(s, frame, wants: 0)
                XCTAssertTrue(unmapped(work).isEmpty, "placement \(placement): a level in use was unmapped")
                XCTAssertEqual(s.residentLevels, [0])
            }
        }
    }
}
