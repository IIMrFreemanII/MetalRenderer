import Foundation
import simd

/// A lift: a cab in its shaft from the ground floor to the top, the landing doors that slide open when it stands at
/// a floor, and the buttons that call it (one by each landing door; inside it, the number keys). It goes where it is
/// called in turn: shuts its doors, moves at up to 1.5 m/s (easing in and out), opens them, waits.
struct Lift {
    enum State { case idle, closing, moving, opening, waiting }

    struct Button {
        var position: SIMD3<Float>
        var floor: Int
    }

    /// The shaft's inside (x, z: the world), the floors' heights, and the side its doors are on (x, z, unit: out of the
    /// shaft).
    var shaft: CityPlan.Rect
    var floors: [Float]
    var doorSide: SIMD2<Float>
    var doorWidth: Float = 1.0
    var buttons: [Button] = []
    /// Where the cab's floor is, the floor it stands at (or last left), how open its doors are (0...1).
    var y: Float
    var at: Int
    var doors: Float = 1
    var state = State.waiting
    private var queue: [Int] = []
    private var from: Float = 0
    private var progress: Float = 0
    private var waited: Float = 0

    init(shaft: CityPlan.Rect, floors: [Float], doorSide: SIMD2<Float>) {
        self.shaft = shaft
        self.floors = floors
        self.doorSide = doorSide
        y = floors.first ?? 0
        at = 0
    }

    mutating func call(_ floor: Int) {
        let f = min(max(floor, 0), floors.count - 1)
        if f == at && state != .moving { state = .opening; return }
        if !queue.contains(f) { queue.append(f) }
    }

    /// Someone standing at `feet`: in the cab, or in the doorway of the floor it stands at with its doors open, the
    /// doors stay open (a call keeps them open too, until it is that call's turn).
    mutating func hold(_ feet: SIMD3<Float>) {
        guard state == .waiting, doors > 0, floors.indices.contains(at) else { return }
        let (lo, hi) = doorway(at)
        let p = SIMD2(feet.x, feet.z), near = 0.6 as Float
        let inDoorway = p.x > lo.x - near && p.x < hi.x + near && p.y > lo.z - near && p.y < hi.z + near && abs(feet.y - floors[at]) < 0.5
        let inCab = cab.contains(p) && abs(feet.y - y) < 0.5
        if (inDoorway || inCab) && queue.isEmpty { waited = 0 }
    }

    /// Moves it on by `dt`; whether anything moved.
    mutating func advance(_ dt: Float) -> Bool {
        switch state {
        case .waiting, .idle:
            waited += dt
            if let next = queue.first, waited > 1.5 || state == .idle {
                if next == at { queue.removeFirst(); state = .opening; return true }
                state = .closing
                return true
            }
            if waited > 8 && doors > 0 { state = .closing; queue.removeAll(); return true }
            return false
        case .closing:
            doors = max(0, doors - dt * 1.2)
            if doors == 0 {
                if let next = queue.first, next != at {
                    from = y
                    progress = 0
                    state = .moving
                } else {
                    state = .idle
                }
            }
            return true
        case .moving:
            guard let next = queue.first else { state = .idle; return false }
            let distance = abs(floors[next] - from)
            progress = min(1, progress + dt * 1.5 / max(distance, 0.1))
            let eased = progress * progress * (3 - 2 * progress)
            y = from + (floors[next] - from) * eased
            if progress >= 1 {
                at = next
                queue.removeFirst()
                state = .opening
            }
            return true
        case .opening:
            doors = min(1, doors + dt * 1.2)
            if doors == 1 { state = .waiting; waited = 0 }
            return true
        }
    }

    /// The cab's inside, a little inside the shaft.
    var cab: CityPlan.Rect { CityPlan.Rect(lo: shaft.lo + SIMD2(0.08, 0.08), hi: shaft.hi - SIMD2(0.08, 0.08)) }

    /// What the walker meets: the cab's floor and its three walls (the door side open), and each landing's door
    /// panel unless the cab stands there with its doors open.
    var colliders: [Interior.Collider] {
        let c = cab
        var out = [Interior.Collider(lo: SIMD3(c.lo.x, y - 0.15, c.lo.y), hi: SIMD3(c.hi.x, y, c.hi.y))]
        let t: Float = 0.06
        let sides: [(SIMD2<Float>, Interior.Collider)] = [
            (SIMD2(1, 0), Interior.Collider(lo: SIMD3(c.hi.x - t, y, c.lo.y), hi: SIMD3(c.hi.x, y + 2.3, c.hi.y))),
            (SIMD2(-1, 0), Interior.Collider(lo: SIMD3(c.lo.x, y, c.lo.y), hi: SIMD3(c.lo.x + t, y + 2.3, c.hi.y))),
            (SIMD2(0, 1), Interior.Collider(lo: SIMD3(c.lo.x, y, c.hi.y - t), hi: SIMD3(c.hi.x, y + 2.3, c.hi.y))),
            (SIMD2(0, -1), Interior.Collider(lo: SIMD3(c.lo.x, y, c.lo.y), hi: SIMD3(c.hi.x, y + 2.3, c.lo.y + t)))]
        for (n, box) in sides where dot(n, doorSide) < 0.5 { out.append(box) }
        // The landing doors: shut ones are in the way.
        for k in floors.indices where landing(k) < 0.8 {
            let (lo, hi) = doorway(k)
            out.append(Interior.Collider(lo: lo, hi: hi))
        }
        return out
    }

    /// Floor `k`'s landing door: the box of its panels.
    func doorway(_ k: Int) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let mid = (shaft.lo + shaft.hi) / 2 + doorSide * ((doorSide.x != 0 ? shaft.size.x : shaft.size.y) / 2)
        let across = SIMD2(-doorSide.y, doorSide.x) * doorWidth / 2
        let a = mid - across, b = mid + across
        return (SIMD3(min(a.x, b.x) - 0.05, floors[k], min(a.y, b.y) - 0.05), SIMD3(max(a.x, b.x) + 0.05, floors[k] + 2.1, max(a.y, b.y) + 0.05))
    }

    /// The landing door of floor `k`: how far it has slid open (0...1).
    func landing(_ k: Int) -> Float { k == at && abs(y - floors[k]) < 0.01 ? doors : 0 }
}
