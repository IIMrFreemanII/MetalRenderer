import CoreGraphics
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// Who the crowd scene's characters are.
package enum CrowdBodies: Int, CaseIterable, Codable {
    case library        // Assets/Characters: the Mixamo mannequins
    case generated      // the character catalog's people (CharacterCatalog, CharacterBuilder)
    package var title: String { ["Mannequins", "Generated people"][rawValue] }
}

/// The character workshop (Scene+Characters.swift): who it shows, in what pose, and how.
package struct CharacterSceneSettings: Equatable, Codable {
    /// The character's id (CharacterCatalog).
    package var character = "man"
    package var layout = Layout.single
    package var pose = Pose.aPose
    /// Pose `clip`: the clip's name (any clip of the character library).
    package var clip = ""
    package var view = View.body
    /// What the faces do (blinks always), and whether their eyes follow the camera.
    package var expression = FaceExpression.neutral
    package var lookAt = true
    /// How hair is drawn (CharacterHair): strands, the caps crowds have, or none.
    package var hair = HairMode.strands
    /// Registry keys (CharacterCatalog.register), session state: the editor's variations of the character to show
    /// beside it (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    package var mutants = ""
    package var compare = ""

    package enum Layout: Int, CaseIterable, Codable {
        case single         // the character
        case lineup         // every character of the catalog, side by side
        case mutate         // the character and the editor's variations of it, in a row
        package var title: String { ["One character", "Everyone", "Variations"][rawValue] }
    }
    package enum Pose: Int, CaseIterable, Codable {
        case tPose, aPose, idle, walk, clip
        package var title: String { ["T pose", "A pose", "Idle", "Walking", "Clip"][rawValue] }
        /// The clip it plays (CharacterKit's names), for every pose but `clip`.
        package var clipName: String? { [Optional("T-Pose"), "A-Pose", "Idle", "Walking", nil][rawValue] }
    }
    package enum View: Int, CaseIterable, Codable {
        case body           // the whole character
        case face           // its head, close
        package var title: String { ["Body", "Face"][rawValue] }
    }
    package enum HairMode: Int, CaseIterable, Codable {
        case strands, caps, none
        package var title: String { ["Strands", "Caps", "None"][rawValue] }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(character: String = "man", layout: Layout = Layout.single, pose: Pose = Pose.aPose, clip: String = "", view: View = View.body, expression: FaceExpression = FaceExpression.neutral, lookAt: Bool = true, hair: HairMode = HairMode.strands, mutants: String = "", compare: String = "") {
        self.character = character
        self.layout = layout
        self.pose = pose
        self.clip = clip
        self.view = view
        self.expression = expression
        self.lookAt = lookAt
        self.hair = hair
        self.mutants = mutants
        self.compare = compare
    }
}
