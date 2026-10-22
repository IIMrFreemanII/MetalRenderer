import CoreGraphics
import Effects
import EngineCore
import Foundation
import simd

/// The material workshop (Scene+Materials.swift): the graph whose material it shows (by name: MaterialCatalog's),
/// on which shapes, against what.
package struct MaterialWorkshopSettings: Equatable, Codable {
    package var graph = "Red Bricks"
    package var layout = Layout.lineup
    package var backdrop = Backdrop.studio

    package enum Layout: String, Codable, CaseIterable {
        /// (`card`: a standing card and a tile on the ground, for a cut-out material: a plant, a decal.)
        case lineup, sphere, cube, cylinder, plane, card
        package var title: String { self == .lineup ? "Line-up" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    package enum Backdrop: String, Codable, CaseIterable {
        case studio, outdoor, dark
        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(graph: String = "Red Bricks", layout: Layout = Layout.lineup, backdrop: Backdrop = Backdrop.studio) {
        self.graph = graph
        self.layout = layout
        self.backdrop = backdrop
    }
}

/// The painter workshop (Scene+Painter.swift): the object it paints (a shape, the base character, a glTF model's
/// largest part), with which document (PaintDocuments, by name), against what.
package struct PainterWorkshopSettings: Equatable, Codable {
    package var subject = Subject.sphere
    /// `.model`: the glTF file (a path, or a name under Assets).
    package var model = ""
    package var document = "Workshop"
    package var backdrop = MaterialWorkshopSettings.Backdrop.studio

    package enum Subject: String, Codable, CaseIterable {
        case sphere, cube, cylinder, plane, character, model
        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(subject: Subject = Subject.sphere, model: String = "", document: String = "Workshop", backdrop: MaterialWorkshopSettings.Backdrop = MaterialWorkshopSettings.Backdrop.studio) {
        self.subject = subject
        self.model = model
        self.document = document
        self.backdrop = backdrop
    }
}
