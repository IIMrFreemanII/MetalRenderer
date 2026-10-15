import Foundation

/// Painted objects' documents on disk: `Assets/Painter/<slug>.painter/`, a folder each — its `document.json` (the
/// layers), the painted pixels as PNGs (`layers/`), and the finished texture set (`final/`). The folder is
/// `METALRENDERER_PAINTER` if set (`none`: nothing is read or written), or `Painter` in the assets folder.
enum PainterStore {
    static let suffix = ".painter"

    static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_PAINTER"] {
        case "none": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Painter")
        }
    }

    /// A document's package.
    static func package(_ name: String) -> URL? { folder?.appendingPathComponent(PaintDocument.slug(name) + suffix) }

    /// The saved document of that name, if there is one.
    static func load(_ name: String) -> PaintDocument? {
        guard let url = package(name)?.appendingPathComponent("document.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PaintDocument.self, from: data)
    }
}
