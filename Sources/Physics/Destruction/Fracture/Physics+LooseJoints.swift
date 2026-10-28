import EngineCore
import Foundation
import simd

/// Loose joints: a weld that gives way doesn't let its pieces go at once. It goes loose (GPUFractureWeld.info.z = 2):
/// a link at the weld's anchors with some play, about which the pieces hinge, swing and twist up to a bend from where
/// they were welded, and which holds a share of what the weld held. It lets go (info.z = 1) when its load passes that,
/// when it is stretched past its reach, or when it has carried a load long enough (fatigue): floors sag and hang on
/// before they fall, and pieces hang from each other in chains and nets. What impacts do stays as it was: a weld torn
/// while its pieces are shaken by impacts (`struck`) breaks, and a piece its impacts free loses every weld at once,
/// loose ones too (`breakWelds`). So debris flies from a hit, and what the hit leaves hanging sags: held → loose → free.
///
/// A loose pair keeps its contacts (the pieces still collide as they hinge, and press without striking each other:
/// `linked`). The links aren't solved in the contact colouring as a holding weld is: a pair is found by its pieces'
/// boxes, and a held piece's partner swinging away from it lost its pair, so its link was never solved or let go
/// again. They are gathered at the step's start (`gatherLooseLinks`: a few, next to the welds) and solved one after
/// another after the colours, each substep. The CPU's only: the GPU's welds still break at once (Shaders/Physics.metal
/// reads only info.z == 0).
package struct LooseJoints: Equatable, Sendable {
    /// Whether welds go loose at all (off: they break at once, as on the GPU).
    package var on = true
    /// The play (m) between the anchors before the link pulls, and how much further (m) it stretches before it snaps.
    /// Both on top of what the turn opens: pieces that hinge about the edge where they press together open their
    /// anchors (the middle of the face they shared, half its width from the edge: `loose.w`) by the chord the turn
    /// makes. (A link that pulled against that fought the contacts and snapped in a fraction of a second. With 2 cm of
    /// play, the links tied the massive building's cracked ground floor together as masonry: it settled, slept and
    /// stood; with 10 cm its pieces slide off their bearings and it comes down, a second later than without links.)
    package var slack: Float = 0.1
    package var reach: Float = 0.1
    /// How far (rad) the pieces turn from their welded rotation before the link holds them: swing and twist together.
    /// Past a right angle: a link holds less than the weld did (its moment broke it), so a ledge whose weld gave way
    /// can't be held out; it swings down and hangs (rebar).
    package var bend: Float = 1.7
    /// The link is a spring past its play and its bend, of a stiffness its strength gives: it pulls with all it holds
    /// stretched `give` (m) further, and turns back with all its moment bent `bendGive` (rad) further. (Rigid, as a
    /// weld, a swinging slab stopped dead at the bend in a substep, a moment no link held; and a millimetre's stretch
    /// was tens of kN.) A slab hanging on its links settles where its weight stretches them.
    package var give: Float = 0.03
    package var bendGive: Float = 0.2
    /// The share of the weld's strength the link holds (its pull; its moment is the weld's lever x that, as a weld's,
    /// past the bend only).
    package var share: Float = 1
    /// Fatigue: a link whose load lately is over `fatigueFloor` tires at the excess per second, and lets go at
    /// `fatigueLimit` (load s): a slab hanging hard on its links falls sooner.
    package var fatigueFloor: Float = 0.25
    package var fatigueLimit: Float = 1.5
    /// How long (s) a link lasts at most, each its own within `lifetimeSpread` (a share either way) of it, asleep or
    /// not: a structure the hit left sags on its links and then comes down, and not all at once. (With no end, or
    /// one only while its pieces moved, the massive building's blasted ground floor settled onto its links, slept, and
    /// held the storeys up for good.)
    package var lifetime: Float = 3
    package var lifetimeSpread: Float = 0.5
    /// How long (s) a piece is shaken by an impact (`struck`): a weld of it that gives way in that time breaks.
    package var shaken: Float = 0.5
    /// How fast (1/s) the pieces' relative turning fades: a chain swings down and settles.
    package var damping: Float = 3
    /// Within the link's pull, the lighter piece is moved as if at most this many times lighter than the heavier one
    /// (a long chain of heavy pieces on a light one otherwise jitters and stretches).
    package var massRatio: Float = 10

    package init() {}

    /// Welds break at once.
    package static let off: LooseJoints = { var l = LooseJoints(); l.on = false; return l }()
}

extension PhysicsWorld {
    /// The weld between body `i` and partner `code` (holding, loose or broken), if there is one.
    @inline(__always) package static func weldOf(_ i: Int, _ code: UInt32, bodies: UnsafeBufferPointer<GPUPhysicsBody>,
                                         starts: UnsafeBufferPointer<UInt32>, list: UnsafeBufferPointer<SIMD2<UInt32>>,
                                         welds: UnsafeBufferPointer<GPUFractureWeld>) -> Int? {
        guard welds.count > 0, code & PhysicsWorld.staticBit == 0, bodies[i].info.y & PhysicsWorld.pieceBit != 0,
              bodies[Int(code)].info.y & PhysicsWorld.pieceBit != 0 else { return nil }
        for k in Int(starts[i])..<Int(starts[i + 1]) where list[k].x == code { return Int(list[k].y) }
        return nil
    }

    /// Whether body `i` and partner `code` are linked by a loose weld (their contacts are its hinge, not impacts).
    @inline(__always) package static func linked(_ s: StepBuffers, _ i: Int, _ code: UInt32) -> Bool {
        guard let w = weldOf(i, code, bodies: UnsafeBufferPointer(s.bodies), starts: s.weldStarts, list: s.weldList,
                             welds: UnsafeBufferPointer(s.welds)) else { return false }
        return s.welds[w].info.z == 2
    }

    /// The step's loose links (`looseLinks`, in weld order), each a step older; one to a piece that broke into its
    /// children (disabled) is let go, and one whose time is up too, its pieces woken (asleep, they would rest on it).
    package func gatherLooseLinks() {
        looseLinks.removeAll(keepingCapacity: true)
        for w in welds.indices where welds[w].info.z == 2 {
            let a = Int(welds[w].info.x), b = Int(welds[w].info.y)
            welds[w].loose.y -= PhysicsWorld.stepLength
            let why: Float = (bodies[a].info.y | bodies[b].info.y) & PhysicsWorld.disabledBit != 0 ? 5 : welds[w].loose.y <= 0 ? 6 : 0
            guard why == 0 else {
                welds[w].info.z = 1
                welds[w].loose.z = why
                for i in [a, b] where bodies[i].info.y & PhysicsWorld.disabledBit == 0 {
                    bodies[i].info.y &= ~PhysicsWorld.asleep
                    bodies[i].prevPosition.w = 0
                }
                continue
            }
            looseLinks.append(UInt32(w))
        }
    }

    /// The loose links' pulls, one after another (after the contacts' colours, each substep).
    func solveLooseLinks(_ s: StepBuffers, _ loose: LooseJoints, h: Float, substeps: Float) {
        for w in looseLinks {
            let k = Int(w), a = Int(s.welds[k].info.x), b = Int(s.welds[k].info.y)
            var x = s.bodies[a], y = s.bodies[b]
            guard PhysicsWorld.moves(x) || PhysicsWorld.moves(y) else { continue }
            PhysicsWorld.looseLink(&s.welds[k], &x, &y, loose, h: h, substeps: substeps)
            s.bodies[a] = x
            s.bodies[b] = y
        }
    }

    /// The loose links' damping (after the contacts' kicks).
    func dampLooseLinks(_ s: StepBuffers, _ loose: LooseJoints, h: Float) {
        for w in looseLinks {
            let k = Int(w), a = Int(s.welds[k].info.x), b = Int(s.welds[k].info.y)
            var x = s.bodies[a], y = s.bodies[b]
            guard PhysicsWorld.moves(x) || PhysicsWorld.moves(y) else { continue }
            PhysicsWorld.dampLink(s.welds[k], &x, &y, loose, h: h)
            s.bodies[a] = x
            s.bodies[b] = y
        }
    }

    /// The loose welds now (counts for the tests and probes): holding, loose, broken.
    package var weldStates: (holding: Int, loose: Int, broken: Int) {
        var counts = (holding: 0, loose: 0, broken: 0)
        for w in welds {
            switch w.info.z {
            case 0: counts.holding += 1
            case 2: counts.loose += 1
            default: counts.broken += 1
            }
        }
        return counts
    }

    /// Whether a piece took an impact this step or lately (or its parent's break): a weld of it that gives way is torn,
    /// and breaks. (Going loose too, the pieces round the massive building's blasted corners stayed on their links,
    /// and even for half a second that held it up: the collapse that starts there never came.)
    @inline(__always) package static func struck(_ s: GPUFractureState) -> Bool { s.strain.x + s.strain.z > 0 || s.hold.y > 0 }

    /// How long the link weld `w` becomes lasts (s): `lifetime` give or take its spread, by a hash of its pieces.
    @inline(__always) package static func lifetime(_ w: GPUFractureWeld, _ loose: LooseJoints) -> Float {
        var x = w.info.x &* 0x9E37_79B1 ^ w.info.y &* 0x85EB_CA77
        x ^= x >> 15
        x = x &* 0x2C1B_3C6D
        x ^= x >> 12
        let u = Float(x & 0xFFFF) / 65535
        return loose.lifetime * (1 + loose.lifetimeSpread * (2 * u - 1))
    }

    /// Whether weld `w`, giving way with its anchors `gap` (m) and its turn `angle` (rad) from rest, goes loose (else
    /// it breaks): a piece far from where it was welded (one that took its broken parent's place where that had
    /// moved) would be yanked back by the link.
    @inline(__always) package static func goesLoose(_ loose: LooseJoints, gap: Float, angle: Float) -> Bool {
        loose.on && gap < loose.slack + loose.reach && angle < loose.bend
    }

    /// Loose weld `w` between its A (`x`) and B (`y`), one of which moves: the turn back within the bend, then the
    /// anchors within the play (each a spring: XPBD with the compliance its strength gives; the lighter piece's share
    /// capped); its load (the pull over what it holds, the turn's moment over that x the lever) averaged over about a
    /// step as a weld's, and the fatigue it leaves; let go past its strength, its reach, its fatigue or its time.
    @inline(__always) package static func looseLink(_ w: inout GPUFractureWeld, _ x: inout GPUPhysicsBody, _ y: inout GPUPhysicsBody,
                                            _ loose: LooseJoints, h: Float, substeps: Float) {
        let target = PhysicsMath.qmul(x.rotation, w.rest)
        var dq = PhysicsMath.qmul(y.rotation, PhysicsMath.qconj(target))
        if dq.w < 0 { dq = -dq }
        let theta = 2 * PhysicsMath.xyz(dq)
        let angle = length(theta)
        let holds = loose.share * w.anchorA.w, lever = max(w.anchorB.w, 1e-3)
        var moment: Float = 0
        if angle > loose.bend {
            let k = theta / angle, over = angle - loose.bend, wa = turnWeight(x, k) + turnWeight(y, k)
            let alpha = loose.bendGive / (holds * lever) / (h * h)
            if wa > 0 {
                let lambda = over / (wa + alpha)
                moment = lambda / (h * h)
                swivel(&x, &y, k * (lambda * wa))
            }
        }
        let ra = PhysicsMath.qrot(x.rotation, PhysicsMath.xyz(w.anchorA)), rb = PhysicsMath.qrot(y.rotation, PhysicsMath.xyz(w.anchorB))
        let gap = (PhysicsMath.xyz(y.position) + rb) - (PhysicsMath.xyz(x.position) + ra)
        let l = length(gap)
        let play = loose.slack + 2 * w.loose.w * sin(min(angle, loose.bend) / 2)
        var force: Float = 0
        if l > play {
            let n = gap / l
            var wx = weight(x, ra, n), wy = weight(y, rb, n)
            // (The lighter piece moved as if no more than massRatio times lighter.)
            var sx: Float = 1, sy: Float = 1
            if wx > 0 && wy > 0 {
                if wx > loose.massRatio * wy { sx = loose.massRatio * wy / wx } else if wy > loose.massRatio * wx { sy = loose.massRatio * wx / wy }
                wx *= sx
                wy *= sy
            }
            let alpha = loose.give / holds / (h * h)
            if wx + wy > 0 {
                let lambda = (l - play) / (wx + wy + alpha)
                force = lambda / (h * h)
                shove(&x, n * (lambda * sx), ra)
                shove(&y, -n * (lambda * sy), rb)
            }
        }
        let load = force / holds + moment / (holds * lever)
        let k = 1 / substeps, average = Float(bitPattern: w.info.w) * (1 - k) + load * k
        w.info.w = average.bitPattern
        w.loose.x += max(average - loose.fatigueFloor, 0) * h
        // (Why it let go, for the tests and probes: 1 its load, 2 its stretch, 3 its fatigue; 4 its piece came free,
        // `breakWelds`; 5 its piece broke, 6 its time, `gatherLooseLinks`.)
        let why: Float = average > 1 ? 1 : l > play + loose.reach ? 2 : w.loose.x > loose.fatigueLimit ? 3 : 0
        if why > 0 {
            w.info.z = 1
            w.loose.z = why
        }
    }

    /// Loose weld `w`'s damping, between its A (`x`) and B (`y`): their relative turning fades at the link's rate (as
    /// dampJoint, about the anchor).
    @inline(__always) package static func dampLink(_ w: GPUFractureWeld, _ x: inout GPUPhysicsBody, _ y: inout GPUPhysicsBody,
                                           _ loose: LooseJoints, h: Float) {
        let relative = PhysicsMath.xyz(y.angular) - PhysicsMath.xyz(x.angular)
        let speed = length(relative)
        guard speed > 1e-6 else { return }
        let k = relative / speed
        let ra = PhysicsMath.qrot(x.rotation, PhysicsMath.xyz(w.anchorA)), rb = PhysicsMath.qrot(y.rotation, PhysicsMath.xyz(w.anchorB))
        let wa = anchorTurnWeight(x, k, ra), wb = anchorTurnWeight(y, k, rb)
        guard wa + wb > 0 else { return }
        let impulse = speed * min(loose.damping * h, 1) / (wa + wb)
        if wa > 0 {
            let turn = k * (impulse * wa)
            x.angular = SIMD4(PhysicsMath.xyz(x.angular) + turn, x.angular.w)
            x.velocity = SIMD4(PhysicsMath.xyz(x.velocity) - cross(turn, ra), x.velocity.w)
        }
        if wb > 0 {
            let turn = -k * (impulse * wb)
            y.angular = SIMD4(PhysicsMath.xyz(y.angular) + turn, y.angular.w)
            y.velocity = SIMD4(PhysicsMath.xyz(y.velocity) - cross(turn, rb), y.velocity.w)
        }
    }
}
