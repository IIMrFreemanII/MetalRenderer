import Foundation
import simd

/// A garment as a tailor makes one (README, "The garment designer"): flat panels cut from fabric, laid out on a pattern
/// sheet (metres, y up), sewn edge to edge, placed round a body and draped by the cloth solver (GarmentSolver). The
/// document is what the designer edits and what a `.garment.json` holds (GarmentFile); `GarmentBuild` turns it into
/// the solver's arrays.
package struct Garment: Codable, Equatable {
    package var name: String
    package var panels: [Panel] = []
    package var seams: [Seam] = []
    package var fabrics: [Fabric] = [.preset(.cotton)]
    /// Buttons and snaps: two points on panels held together (a button through its hole).
    package var buttons: [Button] = []
    /// The template it was made from and its parameters, if any: changing them makes the panels again.
    package var template: TemplateRef?
    /// Who it was draped on: "Y Bot", "X Bot", or a character's id (CharacterStore).
    package var avatar: String = GarmentAvatar.yBot
    /// The particles' spacing in the panels' meshes (metres): 2 cm drapes a shirt in about 6k particles.
    package var particleDistance: Float = 0.02
    /// The last drape (each particle's place, in build order), so that a garment opens as it was left.
    package var drape: [SIMD3<Float>]?

    package init(name: String) { self.name = name }

    package func panel(id: Int) -> Panel? { panels.first { $0.id == id } }
    package func panelIndex(id: Int) -> Int? { panels.firstIndex { $0.id == id } }
    package var nextPanelID: Int { (panels.map(\.id).max() ?? -1) + 1 }
    package var nextSeamID: Int { (seams.map(\.id).max() ?? -1) + 1 }

    /// The fabric of panel `p` (the first if its index is out of range).
    package func fabric(of p: Panel) -> Fabric { fabrics.indices.contains(p.fabric) ? fabrics[p.fabric] : fabrics.first ?? .preset(.cotton) }
}

/// Where the designer's avatars come from: the character library's mannequins, or a saved character.
package enum GarmentAvatar {
    package static let yBot = "Y Bot"
    package static let xBot = "X Bot"
    package static let mannequins = [yBot, xBot]
}

/// A point of a panel's outline: where it is on the sheet, and the handles of the curves into and out of it (offsets
/// from the point; zero: the edge is straight at this end).
package struct PathPoint: Codable, Equatable {
    package var p: SIMD2<Float>
    package var handleIn: SIMD2<Float> = .zero
    package var handleOut: SIMD2<Float> = .zero
    /// A smooth point keeps its handles opposite when one is dragged.
    package var smooth = false

    package init(_ p: SIMD2<Float>, handleIn: SIMD2<Float> = .zero, handleOut: SIMD2<Float> = .zero, smooth: Bool = false) {
        self.p = p
        self.handleIn = handleIn
        self.handleOut = handleOut
        self.smooth = smooth
    }
    package var isCurved: Bool { handleIn != .zero || handleOut != .zero }
}

/// A line drawn inside a panel: a fold (the cloth bends there to its angle: a crease, a pleat's edge), an elastic (it
/// shrinks there to `ratio` of its length: a gathered waist), or a topstitch (drawn, a little stiffer).
package struct InternalLine: Codable, Equatable {
    package enum Kind: String, Codable, CaseIterable { case fold, elastic, topstitch }
    package var points: [SIMD2<Float>]
    package var kind: Kind = .fold
    /// A fold's angle (radians, 0 = flat; positive folds toward the panel's outside, as a crease is pressed).
    package var foldAngle: Float = 0
    /// How stiff the fold is against bending away from its angle (0...1 of the fabric's bending).
    package var foldStrength: Float = 0.5
    /// An elastic's length as a share of the line's (0.5...1).
    package var ratio: Float = 0.8

    package init(_ points: [SIMD2<Float>], kind: Kind = .fold, foldAngle: Float = 0) {
        self.points = points
        self.kind = kind
        self.foldAngle = foldAngle
    }
}

/// A piece of fabric: a closed outline (its points counter-clockwise on the sheet), the lines inside it, the fabric's
/// direction, and where it goes round the body.
package struct Panel: Codable, Equatable, Identifiable {
    package var id: Int
    package var name: String
    package var points: [PathPoint]
    package var lines: [InternalLine] = []
    /// The warp's direction on the sheet (radians from +x): the grain line.
    package var grain: Float = .pi / 2
    package var fabric = 0
    /// Its layer: an outer garment's panels (1, 2 …) stay outside an inner one's (0) where they meet.
    package var layer = 0
    package var arrangement: Arrangement?
    /// Frozen: it stays where it is, as a solid the rest drapes over.
    package var frozen = false
    /// The particles' spacing for this panel (nil: the garment's).
    package var particleDistance: Float?
    /// A mirrored copy of another panel (its id): edits of either reach both, mirrored across the sheet's y axis
    /// through their middle.
    package var mirrorOf: Int?
    /// Shown or not (a hidden panel isn't built: it is set aside while the rest is worked on).
    package var hidden = false

    package init(id: Int, name: String, points: [PathPoint]) {
        self.id = id
        self.name = name
        self.points = points
    }

    package var edgeCount: Int { points.count }
}

/// One stretch of a panel's edge: from `t0` to `t1` of edge `edge`'s length (fractions; `t0 > t1` runs it backwards).
package struct SeamEnd: Codable, Equatable {
    package var panel: Int
    package var edge: Int
    package var t0: Float = 0
    package var t1: Float = 1

    package init(panel: Int, edge: Int, t0: Float = 0, t1: Float = 1) {
        self.panel = panel
        self.edge = edge
        self.t0 = t0
        self.t1 = t1
    }
    package var reversed: SeamEnd { SeamEnd(panel: panel, edge: edge, t0: t1, t1: t0) }
}

/// Two runs of edges sewn together, each a list of stretches in order (several on one side: an N:1 seam, the long side's
/// length shared between the short ones by their lengths). Each side's first point meets the other's first.
package struct Seam: Codable, Equatable, Identifiable {
    package enum Kind: String, Codable, CaseIterable {
        case normal      // the two edges joined, the cloth carried on across the seam
        case turned      // the seam allowance turned in: a crisper ridge
        case zipper      // drawn as a zip; held closed
        case elastic     // gathered: the longer side shrinks to the shorter
    }
    package var id: Int
    package var a: [SeamEnd]
    package var b: [SeamEnd]
    package var kind: Kind = .normal
    /// The angle the seam settles to (radians, 0 = the cloth carries straight on).
    package var foldAngle: Float = 0
    package var topstitch = false

    package init(id: Int, a: [SeamEnd], b: [SeamEnd], kind: Kind = .normal) {
        self.id = id
        self.a = a
        self.b = b
        self.kind = kind
    }
}

/// A button: a point on one panel held to a point on another (its hole), a few millimetres apart.
package struct Button: Codable, Equatable {
    package var panel: Int
    package var at: SIMD2<Float>
    package var holePanel: Int
    package var hole: SIMD2<Float>
    package var radius: Float = 0.007
    package init(panel: Int, at: SIMD2<Float>, holePanel: Int, hole: SIMD2<Float>) {
        self.panel = panel
        self.at = at
        self.holePanel = holePanel
        self.hole = hole
    }
}

/// Where a panel starts round the body before it is sewn: one of the avatar's slots (a cylinder round a part of the
/// body, GarmentArrangement), and the panel's place on it (`offset`: metres round it and up it from the slot's middle).
package struct Arrangement: Codable, Equatable {
    package var slot: ArrangementSlot
    package var offset: SIMD2<Float> = .zero
    /// The panel wrapped with its sheet's x reversed (seen from inside): a back panel drawn as seen from the back.
    package var flipped = false
    /// How far outside the body (metres) the slot's cylinder is.
    package var clearance: Float = 0.05

    package init(slot: ArrangementSlot, offset: SIMD2<Float> = .zero, flipped: Bool = false) {
        self.slot = slot
        self.offset = offset
        self.flipped = flipped
    }
}

/// The body's slots: each wraps a panel round a part of the body, its middle facing one way (GarmentArrangement).
/// The trunk's, the legs', the neck's and the head's stand upright from the floor under that part (`offset.y`: the
/// panel's middle's height); the arms' run along the arm from the shoulder (`offset.y`: how far up the arm toward
/// the shoulder, negative down it), their middle on top of the arm.
package enum ArrangementSlot: String, Codable, CaseIterable {
    case chestFront, chestBack, hipsFront, hipsBack
    case armLeft, armRight
    case legLeftFront, legLeftBack, legRightFront, legRightBack
    case neckFront, neckBack, head

    package var isBack: Bool { rawValue.hasSuffix("Back") }
    package var label: String {
        switch self {
        case .chestFront: return "Chest, front"
        case .chestBack: return "Chest, back"
        case .hipsFront: return "Hips, front"
        case .hipsBack: return "Hips, back"
        case .armLeft: return "Left arm"
        case .armRight: return "Right arm"
        case .legLeftFront: return "Left leg, front"
        case .legLeftBack: return "Left leg, back"
        case .legRightFront: return "Right leg, front"
        case .legRightBack: return "Right leg, back"
        case .neckFront: return "Neck, front"
        case .neckBack: return "Neck, back"
        case .head: return "Head"
        }
    }
}

/// A template a garment came from, and the parameters it was made with.
package struct TemplateRef: Codable, Equatable {
    package var kind: GarmentTemplate.Kind
    package var params: GarmentTemplate.Params
}

extension Garment {
    /// `other` added to this garment as a layer over it (a jacket over a shirt): its panels set down right of these
    /// with new ids, `layer` out (Panel.layer: kept outside where they meet), their seams, buttons and fabrics with them.
    package func adding(_ other: Garment, layer: Int) -> Garment {
        var g = self
        var right: Float = 0
        for p in panels { right = max(right, p.bounds.hi.x) }
        var left = Float.infinity
        for p in other.panels { left = min(left, p.bounds.lo.x) }
        let shift = SIMD2<Float>(right + 0.2 - (left.isFinite ? left : 0), 0)
        var ids: [Int: Int] = [:]
        var next = nextPanelID
        let fabricBase = g.fabrics.count
        g.fabrics += other.fabrics
        for var p in other.panels {
            ids[p.id] = next
            p.id = next
            next += 1
            p.translate(shift)
            p.layer += layer
            p.fabric += fabricBase
            g.panels.append(p)
        }
        for i in g.panels.indices where g.panels[i].id >= nextPanelID { g.panels[i].mirrorOf = g.panels[i].mirrorOf.flatMap { ids[$0] } }
        var seamID = nextSeamID
        for var s in other.seams {
            s.id = seamID
            seamID += 1
            s.a = s.a.map { var e = $0; e.panel = ids[e.panel] ?? e.panel; return e }
            s.b = s.b.map { var e = $0; e.panel = ids[e.panel] ?? e.panel; return e }
            g.seams.append(s)
        }
        for var b in other.buttons {
            b.panel = ids[b.panel] ?? b.panel
            b.holePanel = ids[b.holePanel] ?? b.holePanel
            b.at += shift
            b.hole += shift
            g.buttons.append(b)
        }
        g.template = nil
        g.drape = nil
        g.name = "\(name) + \(other.name)"
        return g
    }
}
