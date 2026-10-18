import Foundation

/// The Fracture Editor's saved recipes (FractureRecipe), by object name, in `Assets/Fracture/recipes.json`: what the
/// destruction scene builds its objects from in place of their defaults. `METALRENDERER_FRACTURE=builtin` leaves them
/// out (comparisons between builds), `=<file>` reads another file.
enum FractureStore {
    static let format = 1

    struct File: Codable {
        var format = FractureStore.format
        var recipes: [String: FractureRecipe]
    }

    static var url: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_FRACTURE"] {
        case "builtin": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Fracture/recipes.json")
        }
    }

    static func load(from url: URL? = FractureStore.url) -> [String: FractureRecipe] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        do {
            return try JSONDecoder().decode(File.self, from: data).recipes
        } catch {
            print("Fracture: can't read \(url.lastPathComponent): \(error)")
            return [:]
        }
    }

    static func save(_ recipes: [String: FractureRecipe], to url: URL? = FractureStore.url) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(recipes: recipes)).write(to: url, options: .atomic)
    }
}
