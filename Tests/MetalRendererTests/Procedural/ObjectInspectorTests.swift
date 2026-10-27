import AppKit
import SwiftUI
import XCTest
import simd
@testable import Editors
@testable import EngineCore
@testable import MetalRenderer
@testable import Procedural

/// The main window's Object inspector without a window: a placed `proc:` object's promoted parameters, with this
/// copy's values or the asset's defaults; setting and reverting them sends the object's new asset string.
/// OBJECT_INSPECTOR_PNG=<folder> also draws the panel offscreen.
final class ObjectInspectorTests: XCTestCase {
    /// The renderer's side: what it reports, and the asset strings sent to it.
    private static let kind = SceneKind("procedural")

    private final class Host: ObjectInspectorHost {
        var placed: PlacedStatus?
        var sent: [(index: Int, kind: SceneKind, asset: String)] = []
        private var ticks: [() -> Void] = []
        func observeTick(_ observer: @escaping () -> Void) { ticks.append(observer) }
        func setPlacedAsset(_ index: Int, of kind: SceneKind, to asset: String) { sent.append((index, kind, asset)) }
        func tick() { ticks.forEach { $0() } }
        func select(_ index: Int, _ asset: String, name: String = "Fence") {
            placed = PlacedStatus(kind: ObjectInspectorTests.kind, index: index, object: SceneFile.Object(asset: asset, name: name))
            tick()
        }
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-\(UUID().uuidString)")
        var g = ProcGraph()
        g.setDisplay(g.add(.box))
        g.interface = [PromotedParam("spacing", title: "Spacing", value: .float(1.5), span: 0.3...5, targets: [.init(node: "box1", param: "scale")]),
                       PromotedParam("seed", value: .int(0), targets: [.init(node: "box1", param: "scale")]),
                       PromotedParam("size", value: .vec3([1, 1, 1]), targets: [.init(node: "box1", param: "size")])]
        try ProcStore.write(ProcAsset(name: "Fence", graph: g), slug: "fence", in: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRowsSetAndRevert() throws {
        let host = Host()
        let model = ObjectInspectorModel(host: host, folder: folder)
        XCTAssertNil(model.placed)
        host.select(2, "proc:fence?seed=7")
        XCTAssertTrue(model.isProcedural)
        XCTAssertEqual(model.rows.map(\.param.name), ["spacing", "seed", "size"])
        XCTAssertEqual(model.rows.map(\.overridden), [false, true, false])
        XCTAssertEqual(model.rows[1].value, .int(7))
        XCTAssertEqual(model.rows[0].value, .float(1.5))

        model.set("spacing", .float(2.25))
        XCTAssertEqual(host.sent.last?.index, 2)
        XCTAssertEqual(host.sent.last?.kind, ObjectInspectorTests.kind)
        XCTAssertEqual(host.sent.last?.asset, "proc:fence?seed=7&spacing=2.25")
        // Shown at once, before the renderer reports it back.
        XCTAssertEqual(model.rows[0].value, .float(2.25))
        host.tick()
        XCTAssertEqual(model.placed?.object.asset, "proc:fence?seed=7&spacing=2.25")
        // The renderer has it: its report is taken as it is from then on.
        host.select(2, "proc:fence?seed=7&spacing=2.25")
        model.set("size", .vec3([0.5, 2, 0.5]))
        XCTAssertEqual(host.sent.last?.asset, "proc:fence?seed=7&size=0.5,2.0,0.5&spacing=2.25")

        model.revert("seed")
        XCTAssertEqual(host.sent.last?.asset, "proc:fence?size=0.5,2.0,0.5&spacing=2.25")
        XCTAssertEqual(model.rows[1].value, .int(0))
        XCTAssertFalse(model.rows[1].overridden)
        model.revertAll()
        XCTAssertEqual(host.sent.last?.asset, "proc:fence")
        let count = host.sent.count
        model.revertAll()   // nothing to send
        model.set("spacing", .float(1.5))   // the default, set: this copy's own from then on
        XCTAssertEqual(host.sent.count, count + 1)
        XCTAssertEqual(host.sent.last?.asset, "proc:fence?spacing=1.5")
    }

    func testOtherObjects() {
        let host = Host()
        let model = ObjectInspectorModel(host: host, folder: folder)
        var selected: [Int] = []
        model.onSelect = { selected.append($0.index) }
        host.select(0, "prefab:box", name: "Box")
        XCTAssertFalse(model.isProcedural)
        XCTAssertTrue(model.rows.isEmpty)
        host.select(1, "proc:missing")
        XCTAssertNil(model.asset)
        XCTAssertEqual(model.message, "No procedural asset missing in the library")
        host.select(1, "proc:fence")   // the same object, another string: not another selection
        XCTAssertNil(model.message)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(selected, [0, 1])
        host.placed = nil
        host.tick()
        XCTAssertNil(model.placed)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// A save of the asset (the Modeller's) is read again: another interface shows.
    func testAssetSavedAgain() throws {
        let host = Host()
        let model = ObjectInspectorModel(host: host, folder: folder)
        host.select(0, "proc:fence")
        var asset = try XCTUnwrap(ProcStore.read("fence", in: folder))
        asset.graph.interface.removeLast()
        try ProcStore.write(asset, slug: "fence", in: folder)
        let url = try XCTUnwrap(ProcStore.url("fence", in: folder))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        host.tick()
        XCTAssertEqual(model.rows.map(\.param.name), ["spacing", "seed"])
    }

    func testPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["OBJECT_INSPECTOR_PNG"] else { throw XCTSkip("OBJECT_INSPECTOR_PNG not set") }
        let out = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let host = Host()
        let model = ObjectInspectorModel(host: host, folder: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: ObjectInspectorView(model: model).background(Color(nsColor: .windowBackgroundColor)))   // (cacheDisplay draws no window)
        window.contentView = view
        func shoot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
        }
        try shoot("1-nothing")
        host.select(3, "proc:fence?seed=7&spacing=2.25")
        try shoot("2-fence")
        host.select(0, "prefab:box", name: "Crate")
        try shoot("3-box")
    }
}
