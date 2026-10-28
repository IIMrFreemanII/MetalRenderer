import Characters
import Foundation
import simd

/// A body as the garments see it: its slots' cylinders (ArrangementSlot), found from its skeleton and mesh in its
/// bind pose, and its measurements. A panel is placed by wrapping its sheet round its slot's cylinder: across the
/// sheet is round the cylinder (an ellipse round the trunk, a circle round a limb), up the sheet is along it.
package struct AvatarFrame {
    package struct Slot {
        /// A point of the axis, and the axis (up the sheet: toward the head, or up the arm toward the shoulder).
        package var origin: SIMD3<Float>
        package var axis: SIMD3<Float>
        /// The way the panel's middle faces, and the way across the sheet's +x goes from it.
        package var facing: SIMD3<Float>
        package var side: SIMD3<Float>
        /// Its half widths along `side` and `facing` (round a limb, the same).
        package var radii: SIMD2<Float>
        /// Heights are measured from the floor (the trunk's, the legs', the head's), not from `origin` along the axis.
        package var upright: Bool
    }

    package var measurements: BodyMeasurements
    package var slots: [ArrangementSlot: Slot] = [:]
    package var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>)

    package init(_ c: SkinnedCharacter) {
        let m = BodyMeasurements.measure(c)
        measurements = m
        let poses = c.bindPoses
        func joint(_ name: String) -> SIMD3<Float>? { CharacterBase.joint(name, in: c).map { poses[$0].t } }
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in c.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        bounds = (lo, hi)
        let p = c.positions
        // The trunk's half width and depth at a height (its slice, the arms left out), about its middle.
        func trunk(at y: Float, half: Float) -> (centre: SIMD2<Float>, radii: SIMD2<Float>) {
            let slice = p.filter { abs($0.y - y) < 0.015 && abs($0.x) < half }
            guard slice.count > 8 else { return (.zero, SIMD2(0.17, 0.12)) }
            var a = SIMD2<Float>(repeating: .infinity), b = -a
            for q in slice { a = simd_min(a, SIMD2(q.x, q.z)); b = simd_max(b, SIMD2(q.x, q.z)) }
            return ((a + b) / 2, (b - a) / 2)
        }
        let clearance: Float = 0.045
        let halfShoulders = m.shoulderWidth / 2 * 0.82
        let chest = trunk(at: m.chestHeight, half: halfShoulders), hips = trunk(at: m.hipHeight, half: halfShoulders * 1.25)
        func upright(_ centre: SIMD2<Float>, _ radii: SIMD2<Float>, back: Bool) -> Slot {
            let facing = SIMD3<Float>(0, 0, back ? -1 : 1), axis = SIMD3<Float>(0, 1, 0)
            return Slot(origin: SIMD3(centre.x, 0, centre.y), axis: axis, facing: facing, side: simd_cross(axis, facing),
                        radii: radii + clearance, upright: true)
        }
        let chestRadii = simd_max(chest.radii, hips.radii * SIMD2(0.95, 1))
        slots[.chestFront] = upright(chest.centre, chestRadii, back: false)
        slots[.chestBack] = upright(chest.centre, chestRadii, back: true)
        slots[.hipsFront] = upright(hips.centre, hips.radii, back: false)
        slots[.hipsBack] = upright(hips.centre, hips.radii, back: true)
        let neckCentre = joint("Neck").map { SIMD2($0.x, $0.z) } ?? chest.centre
        let neckR = SIMD2<Float>(repeating: m.neck / (2 * .pi))
        slots[.neckFront] = upright(neckCentre, neckR, back: false)
        slots[.neckBack] = upright(neckCentre, neckR, back: true)
        let headCentre = joint("Head").map { SIMD2($0.x, $0.z) } ?? neckCentre
        slots[.head] = upright(headCentre, SIMD2(0.105, 0.115), back: false)
        // The arms: from the shoulder down to the hand, the panel's middle on top.
        for (slot, side) in [(ArrangementSlot.armLeft, "Left"), (.armRight, "Right")] {
            guard let s = joint(side + "Arm"), let h = joint(side + "Hand") else { continue }
            let axis = simd_normalize(s - h)
            var up = SIMD3<Float>(0, 1, 0) - axis * axis.y
            up = simd_length(up) > 1e-3 ? simd_normalize(up) : SIMD3(0, 0, 1)
            let r = m.upperArm / (2 * .pi) + clearance * 0.8
            slots[slot] = Slot(origin: s, axis: axis, facing: up, side: simd_cross(axis, up), radii: SIMD2(r, r), upright: false)
        }
        // The legs: upright from the floor under the hip's joint, along the leg.
        for (front, back, side) in [(ArrangementSlot.legLeftFront, ArrangementSlot.legLeftBack, "Left"), (.legRightFront, .legRightBack, "Right")] {
            guard let hip = joint(side + "UpLeg"), let foot = joint(side + "Foot") else { continue }
            let axis = simd_normalize(hip - foot)
            let r = m.thigh / (2 * .pi) + clearance * 0.9
            for (slot, sign) in [(front, Float(1)), (back, -1)] {
                var facing = SIMD3<Float>(0, 0, sign) - axis * (axis.z * sign)
                facing = simd_normalize(facing)
                slots[slot] = Slot(origin: hip, axis: axis, facing: facing, side: simd_cross(axis, facing), radii: SIMD2(r, r), upright: true)
            }
        }
    }

    /// Where a point of a panel goes: `local` its place on the sheet from the panel's middle, the slot's arrangement.
    /// `row`: round a limb, the panel's extent across at this height (its left and right, from the middle): the row
    /// is wrapped all the way round (a sleeve) or half way (a trouser leg's half), so that its seams meet under the limb
    /// whatever its width.
    package func place(_ local: SIMD2<Float>, _ a: Arrangement, row: (lo: Float, hi: Float)? = nil) -> SIMD3<Float>? {
        guard let s = slots[a.slot] else { return nil }
        var u = local.x + a.offset.x
        let v = local.y + a.offset.y
        var rx = s.radii.x + a.clearance - 0.045, rz = s.radii.y + a.clearance - 0.045
        var theta: Float
        if let row, !s.upright || a.slot.isLimb {
            // Round the limb: the row's middle on the slot's facing side, its edges `coverage` round from it.
            let half = max(1e-3, (row.hi - row.lo) / 2), mid = (row.hi + row.lo) / 2
            let coverage: Float = a.slot.isArm ? 0.97 * .pi : 0.5 * .pi
            u = local.x - mid
            // (Its own radius: wrapped short of the whole way, its seam would close through the limb.)
            let r = a.slot.isArm ? max(0.03, half / coverage) : max(rx, half / coverage)
            rx = r; rz = r
            theta = u / r
        } else {
            theta = u / ((rx + rz) / 2)
            // Over the shoulders the trunk's front and back lean in toward each other (their shoulder seams meet
            // over the body, not through it).
            if a.slot == .chestFront || a.slot == .chestBack {
                let over = v - (measurements.shoulderHeight - 0.04)
                if over > 0 { rz *= max(0.3, 1 - over * 5.5) }
            }
        }
        if !theta.isFinite { theta = 0 }
        let side = a.flipped ? -s.side : s.side
        // The axis's point at height v (upright: from the floor, along the slanting axis) or v along it.
        let base: SIMD3<Float>
        if s.upright {
            let t = abs(s.axis.y) > 1e-3 ? (v - s.origin.y) / s.axis.y : 0
            base = s.origin + s.axis * t
        } else {
            base = s.origin + s.axis * v
        }
        return base + side * (sin(theta) * rx) + s.facing * (cos(theta) * rz)
    }

    /// Every particle of `b` placed round the body, panel by panel (a panel with no arrangement: flat, in front of the
    /// body, a metre out, its sheet as it is).
    package func place(_ b: GarmentBuild, _ g: Garment) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: .zero, count: b.particleCount)
        for (pi, id) in b.panelIDs.enumerated() {
            guard let panel = g.panel(id: id) else { continue }
            let centre = panel.centre
            let range = b.panelFirst[pi]..<(b.panelFirst[pi] + b.panelCount[pi])
            // Round a limb: each row's extent (2 cm rows of the sheet).
            var rows: [Int: (lo: Float, hi: Float)] = [:]
            if let a = panel.arrangement, a.slot.isLimb {
                for i in range {
                    let l = b.rest2D[i] - centre, k = Int((l.y / 0.02).rounded(.down))
                    let e = rows[k] ?? (l.x, l.x)
                    rows[k] = (min(e.lo, l.x), max(e.hi, l.x))
                }
            }
            for i in range {
                let local = b.rest2D[i] - centre
                if var a = panel.arrangement {
                    // An outer layer starts outside the inner ones.
                    a.clearance += 0.035 * Float(panel.layer)
                    let row = rows[Int((local.y / 0.02).rounded(.down))]
                    out[i] = place(local, a, row: row) ?? SIMD3(b.rest2D[i].x - 1.5, b.rest2D[i].y + 0.2, 1.0)
                } else {
                    out[i] = SIMD3(b.rest2D[i].x - 1.5, b.rest2D[i].y + 0.2, 1.0)
                }
            }
        }
        return out
    }
}

extension ArrangementSlot {
    package var isArm: Bool { self == .armLeft || self == .armRight }
    package var isLimb: Bool { isArm || self == .legLeftFront || self == .legLeftBack || self == .legRightFront || self == .legRightBack }
}
