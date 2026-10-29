import EngineCore
import Foundation

/// The plant workshop (Scene+Plants.swift): which plants it shows, and how.
package struct PlantSceneSettings: Equatable, Codable {
    /// The species' id (PlantCatalog), and the age and seeded variant of the one plant shown.
    package var species = "oak"
    package var age = Foliage.Age.mature
    package var variant = 0
    /// What the variants are grown from: the library's seed (SceneSettings.seed), so the workshop's oak 2 at seed 1 is
    /// the forest's.
    package var seed = 1
    package var layout = Layout.single
    package var view = View.plant
    /// Registry keys (PlantCatalog.register), session state: the editor's variations of the species to show beside it
    /// (layout `mutate`), and the definition to show in its place (comparing with the saved one). "" = none.
    package var mutants = ""
    package var compare = ""

    package enum Layout: Int, CaseIterable, Codable {
        case single         // the one plant
        case lineup         // every age (rows) and variant (columns)
        case mutate         // the plant and the editor's variations of it, in a row

        package var title: String { ["One plant", "Ages and variants", "Variations"][rawValue] }
    }
    package enum View: Int, CaseIterable, Codable {
        case plant
        case skeleton       // the stems as thin lines, a colour to a level; no leaves
        case light          // a grown plant's stems by the light they get (dark blue in deep shade to yellow in full sun)

        package var title: String { ["Plant", "Skeleton", "Light"][rawValue] }
    }

    package static let variantRange = 0...7

    /// (As the memberwise initializer, for the modules above this one.)
    package init(species: String = "oak", age: Foliage.Age = Foliage.Age.mature, variant: Int = 0, seed: Int = 1, layout: Layout = Layout.single, view: View = View.plant, mutants: String = "", compare: String = "") {
        self.species = species
        self.age = age
        self.variant = variant
        self.seed = seed
        self.layout = layout
        self.view = view
        self.mutants = mutants
        self.compare = compare
    }
}
