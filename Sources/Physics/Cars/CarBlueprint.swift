import EngineCore
import Foundation
import simd

/// A car as nodes and beams (BeamNG's jbeam, generated): what PhysicsWorld.addCar makes particles and beams of.
///
/// The body is a row of cross-sections ("stations") about every `stationSpacing` from the rear bumper to the front,
/// each a ring of ten nodes on the body's profile (CarSpec): the sills, the belt line, the top's edges and middle, and
/// the floor inside the wheels. Each ring is triangulated by chords (a bulkhead), and each station is tied to the next
/// by beams along the body, two diagonals across each panel (shear) and beams to the station after next (bending).
/// The cabin's beams are stronger than the crumple zones' in front of the windshield and behind the rear window, the
/// floor's rails stronger still. An engine block of eight nodes sits on mounts in the front. Each wheel hangs from a
/// knuckle of five nodes (kingpin top and bottom, two hub nodes, a steering arm) on a double wishbone: two arms up, two
/// down, a tie rod (the steering's, at the front), a spring with its damper, a bump stop and a rebound strap.
package struct CarBlueprint {
    package struct Beam {
        package var a: Int
        package var b: Int
        package var kind: CarBeamKind
        package var zone: CarBeamZone
        package var hull = false
        /// A wheel's corner's (CarBeam.cornerBit).
        package var corner = false
        /// Overrides: stiffness (N/m), damping, rest length; a tie rod's steering (CarBeamLimit.steer).
        package var stiffness: Float?
        package var damping: Float?
        package var rest: Float?
        package var steer: Float = 0
    }

    /// A wheel's corner: where its wheel is, its knuckle's nodes and its flags (CarWheel's).
    package struct Corner {
        package var centre: SIMD3<Float>
        package var hubIn: Int
        package var hubOut: Int
        package var arm: Int
        package var front: Bool
        /// +1 the car's left, -1 its right.
        package var side: Float
        package var hubOffset: Float
    }

    package var spec: CarSpec
    package var nodes: [SIMD3<Float>] = []
    package var masses: [Float] = []
    package var beams: [Beam] = []
    /// Each station's z, and its ring's nodes (`ringSlots` of them: `slot`'s order).
    package var stations: [Float] = []
    package var rings: [[Int]] = []
    /// The node hull's triangles, facing out: what the panels are embedded in (CarSurface).
    package var hull: [SIMD3<Int32>] = []
    package var corners: [Corner] = []
    package var engine: [Int] = []
    /// The floor's middle at the rear axle and at the front, and the left sill in the middle: the car's frame.
    package var frame = SIMD3<Int>()

    /// A node's radius (m): how close it comes to what it meets.
    package static let radius: Float = 0.06
    package static let stationSpacing: Float = 0.34
    package static let knuckleMass: Float = 4, mountMass: Float = 2
    /// A ring's slots, round the section from the left sill over the top to the right one, then the floor back.
    package enum Slot: Int, CaseIterable {
        case sillL, beltL, topL, crown, topR, beltR, sillR, floorR, floorMid, floorL
    }
    package static let ringSlots = Slot.allCases.count
    /// The chords that triangulate a ring (with its edges): eight triangles.
    package static let ringTriangles: [SIMD3<Int>] = [[0, 1, 9], [9, 1, 8], [8, 1, 5], [8, 5, 7], [7, 5, 6], [1, 2, 3], [1, 3, 5], [5, 3, 4]]

    /// A beam's stiffness (N/m), damping (N s/m), yield and strength (N), hardening and strain limit, by its zone.
    package static func strength(_ zone: CarBeamZone) -> (k: Float, c: Float, yield: Float, strength: Float, hardening: Float, strain: Float) {
        switch zone {
        case .crumple: return (2e6, 250, 9e3, 40e3, 1, 0.35)
        case .cabin: return (3e6, 300, 30e3, 120e3, 1, 0.35)
        case .roof: return (3e6, 300, 25e3, 100e3, 1, 0.35)
        case .rail: return (5e6, 400, 55e3, 220e3, 1.5, 0.5)
        case .cabinRail: return (8e6, 500, 150e3, 400e3, 1.5, 0.5)
        case .bumper: return (1e6, 200, 8e3, 30e3, 1, 0.4)
        case .engine: return (2e6, 300, 25e3, 150e3, 1, 0.5)
        case .suspension: return (5e7, 0, .infinity, .infinity, 0, .infinity)
        case .bend: return (0.5e6, 100, 5e3, 40e3, 1, 0.5)
        }
    }

    package init(_ spec: CarSpec) {
        self.spec = spec
        buildBody()
        buildEngine()
        distributeMass()
        // The sprung mass's share on each axle, from where its centre is.
        let sprung = masses.reduce(Float(0), +), centre = zip(nodes, masses).reduce(Float(0)) { $0 + $1.0.z * $1.1 } / sprung
        let front = simd_clamp((centre - spec.rearAxle) / spec.wheelbase, 0.3, 0.7)
        for isFront in [true, false] {
            let share = isFront ? front : 1 - front
            for side: Float in [1, -1] { buildCorner(front: isFront, side: side, sprung: sprung * share / 2) }
        }
        let mid = stations.count / 2
        frame = SIMD3(rings[nearestStation(spec.rearAxle)][Slot.floorMid.rawValue], rings[nearestStation(spec.frontAxle)][Slot.floorMid.rawValue],
                      rings[mid][Slot.sillL.rawValue])
        pairMirrors()
    }

    /// The beams in mirrored pairs (a beam, then its mirror across the car's middle, the left one first in every other
    /// pair): solved one after another, in the order built, the left side's went first and a launch pulled the car to
    /// one side.
    private mutating func pairMirrors() {
        var mirror = [Int](repeating: -1, count: nodes.count)
        var at: [SIMD3<Int32>: Int] = [:]
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p * 1000).rounded(.toNearestOrAwayFromZero)) }
        for (i, p) in nodes.enumerated() { at[key(p)] = i }
        for (i, p) in nodes.enumerated() { mirror[i] = at[key(SIMD3(-p.x, p.y, p.z))] ?? i }
        var index: [SIMD2<Int>: [Int]] = [:]
        for (k, b) in beams.enumerated() { index[SIMD2(min(b.a, b.b), max(b.a, b.b)), default: []].append(k) }
        var placed = [Bool](repeating: false, count: beams.count), ordered: [Beam] = [], pairs = 0
        for k in beams.indices where !placed[k] {
            let b = beams[k], ma = mirror[b.a], mb = mirror[b.b]
            let twin = index[SIMD2(min(ma, mb), max(ma, mb))]?.first { $0 != k && !placed[$0] && beams[$0].kind == b.kind }
            placed[k] = true
            guard let t = twin else { ordered.append(b); continue }
            placed[t] = true
            ordered += pairs % 2 == 0 ? [b, beams[t]] : [beams[t], b]
            pairs += 1
        }
        beams = ordered
    }

    package func nearestStation(_ z: Float) -> Int {
        stations.indices.min { abs(stations[$0] - z) < abs(stations[$1] - z) }!
    }

    // MARK: The body

    /// Slot `s`'s place at station z (car space).
    package func ringPoint(_ s: Slot, _ z: Float) -> SIMD3<Float> {
        let hw = spec.halfWidth(z), top = spec.topHeight(z), tw = spec.topHalfWidth(z), fw = min(spec.floorHalfWidth, hw - 0.1)
        switch s {
        case .sillL: return [hw, spec.sideHeight(z), z]
        case .beltL: return [hw, spec.beltHeight(z), z]
        case .topL: return [tw, top, z]
        case .crown: return [0, top + 0.03, z]
        case .topR: return [-tw, top, z]
        case .beltR: return [-hw, spec.beltHeight(z), z]
        case .sillR: return [-hw, spec.sideHeight(z), z]
        case .floorR: return [-fw, spec.sill, z]
        case .floorMid: return [0, spec.sill, z]
        case .floorL: return [fw, spec.sill, z]
        }
    }

    /// Which zone a panel's beam at `z` is in: the bumpers', the crumple zones', or the cabin's (its roof's, its floor's).
    private func zone(_ z: Float, end: Bool, floor: Bool, top: Bool) -> CarBeamZone {
        if end { return floor ? .rail : .bumper }
        let crumple = z > spec.windshieldBase - 0.05 || z < spec.rearWindowBase + 0.05
        if floor { return crumple ? .rail : .cabinRail }
        if crumple { return .crumple }
        return top ? .roof : .cabin
    }

    private static func isFloor(_ s: Int) -> Bool {
        s == Slot.sillL.rawValue || s == Slot.sillR.rawValue || s == Slot.floorL.rawValue || s == Slot.floorR.rawValue || s == Slot.floorMid.rawValue
    }

    private static func isTop(_ s: Int) -> Bool { s == Slot.topL.rawValue || s == Slot.crown.rawValue || s == Slot.topR.rawValue }

    private mutating func node(_ p: SIMD3<Float>, mass: Float) -> Int {
        nodes.append(p)
        masses.append(mass)
        return nodes.count - 1
    }

    private mutating func beam(_ a: Int, _ b: Int, _ kind: CarBeamKind, _ zone: CarBeamZone, hull: Bool = false) {
        beams.append(Beam(a: a, b: b, kind: kind, zone: zone, hull: hull))
    }

    private mutating func buildBody() {
        let n = max(Int(((spec.frontEnd - spec.rearEnd) / CarBlueprint.stationSpacing).rounded()) + 1, 6)
        stations = (0..<n).map { spec.rearEnd + (spec.frontEnd - spec.rearEnd) * Float($0) / Float(n - 1) }
        let ring = CarBlueprint.ringSlots
        for z in stations {
            // (Weights for now: distributeMass makes them kilograms. The floor carries more of the body.)
            rings.append(Slot.allCases.map { s in node(ringPoint(s, z), mass: CarBlueprint.isFloor(s.rawValue) ? 1.5 : 1) })
        }
        for (k, z) in stations.enumerated() {
            let r = rings[k], end = k == 0 || k == n - 1
            // The ring's edges (the hull's), and its chords.
            for s in 0..<ring {
                let t = (s + 1) % ring
                let floor = CarBlueprint.isFloor(s) && CarBlueprint.isFloor(t)
                beam(r[s], r[t], .plastic, zone(z, end: end, floor: floor, top: CarBlueprint.isTop(s) && CarBlueprint.isTop(t)), hull: true)
            }
            for (a, b) in [(9, 1), (8, 1), (8, 5), (7, 5), (1, 3), (5, 3), (1, 5)] {
                beam(r[a], r[b], .plastic, zone(z, end: end, floor: false, top: false))
            }
        }
        for k in 0..<(n - 1) {
            let r0 = rings[k], r1 = rings[k + 1], z = (stations[k] + stations[k + 1]) / 2, end = k == 0 || k == n - 2
            for s in 0..<ring {
                let t = (s + 1) % ring
                let floor = CarBlueprint.isFloor(s)
                beam(r0[s], r1[s], .plastic, zone(z, end: end, floor: floor, top: CarBlueprint.isTop(s)), hull: true)
                let panelFloor = floor && CarBlueprint.isFloor(t), top = CarBlueprint.isTop(s) && CarBlueprint.isTop(t)
                beam(r0[s], r1[t], .plastic, zone(z, end: end, floor: panelFloor, top: top), hull: true)
                beam(r0[t], r1[s], .plastic, zone(z, end: end, floor: panelFloor, top: top))
                // The hull's two triangles of the panel, facing out.
                appendHull(r0[s], r0[t], r1[t])
                appendHull(r0[s], r1[t], r1[s])
            }
            if k + 2 < n {
                for s in 0..<ring { beam(r0[s], rings[k + 2][s], .plastic, .bend) }
            }
        }
        // The ends: each ring's triangles, facing back at the rear and forward at the front.
        for k in [0, n - 1] {
            for t in CarBlueprint.ringTriangles {
                let a = rings[k][t.x], b = rings[k][t.y], c = rings[k][t.z]
                let normal = cross(nodes[b] - nodes[a], nodes[c] - nodes[a])
                let outward: Float = k == 0 ? -1 : 1
                hull.append(normal.z * outward >= 0 ? SIMD3(Int32(a), Int32(b), Int32(c)) : SIMD3(Int32(a), Int32(c), Int32(b)))
            }
        }
    }

    /// A panel's triangle, wound to face away from the body's middle line at its height.
    private mutating func appendHull(_ a: Int, _ b: Int, _ c: Int) {
        let pa = nodes[a], pb = nodes[b], pc = nodes[c]
        let centre = (pa + pb + pc) / 3
        let middle = SIMD3<Float>(0, (spec.sill + spec.belt) / 2, centre.z)
        let normal = cross(pb - pa, pc - pa)
        hull.append(dot(normal, centre - middle) >= 0 ? SIMD3(Int32(a), Int32(b), Int32(c)) : SIMD3(Int32(a), Int32(c), Int32(b)))
    }

    /// The `count` ring nodes nearest `p` (of `slots` only, if given).
    private func nearestRing(_ p: SIMD3<Float>, count: Int, slots: [Slot]? = nil) -> [Int] {
        let all = slots.map { s in rings.flatMap { r in s.map { r[$0.rawValue] } } } ?? rings.flatMap { $0 }
        return Array(all.sorted { simd_distance_squared(nodes[$0], p) < simd_distance_squared(nodes[$1], p) }.prefix(count))
    }

    /// The sides' nodes (the sills and the belt line): the rails what hangs in the car is held from.
    private static let sides: [Slot] = [.sillL, .beltL, .beltR, .sillR]

    // MARK: The engine

    private mutating func buildEngine() {
        let mid = spec.style == .coupe ? spec.frontAxle - 0.4 : spec.frontAxle - 0.05
        let height = spec.sill + 0.06 + (min(spec.topHeight(mid), spec.cowl) - spec.sill) * 0.42
        let centre = SIMD3<Float>(0, height, mid), half = SIMD3<Float>(0.28, 0.2, 0.26)
        for k in 0..<8 {
            let corner = SIMD3<Float>(k & 1 == 0 ? -1 : 1, k & 2 == 0 ? -1 : 1, k & 4 == 0 ? -1 : 1)
            engine.append(node(centre + corner * half, mass: spec.engineMass / 8))
        }
        for i in 0..<8 {
            for j in (i + 1)..<8 { beam(engine[i], engine[j], .rigid, .engine) }
        }
        // Held from the sides (the floor's middle is a sheet: an engine on it sagged it 6 cm).
        for e in engine {
            for r in nearestRing(nodes[e], count: 2, slots: CarBlueprint.sides) + nearestRing(nodes[e], count: 1) where !beams.contains(where: {
                $0.a == e && $0.b == r
            }) {
                beam(e, r, .plastic, .engine)
            }
        }
    }

    // MARK: The suspension

    /// A wheel's corner carrying `sprung` kg of the body (the knuckles' and mounts' added after).
    private mutating func buildCorner(front: Bool, side s: Float, sprung: Float) {
        let firstBeam = beams.count
        defer { for k in firstBeam..<beams.count { beams[k].corner = true } }
        let R = spec.wheelRadius, zc = front ? spec.frontAxle : spec.rearAxle
        let g: Float = 9.81
        let km = CarBlueprint.knuckleMass, mm = CarBlueprint.mountMass
        let staticTyre = (sprung + 5 * km + 6 * mm + spec.wheelMass) * g / spec.tyreStiffness
        let c = SIMD3<Float>(s * spec.track / 2, R - staticTyre, zc)
        let inward = SIMD3<Float>(-s, 0, 0)
        let hub: Float = 0.09
        let hubIn = node(c + inward * hub, mass: km)
        let hubOut = node(c - inward * hub, mass: km)
        // The kingpin (top to bottom) 6 cm inboard of the wheel's middle: the drive's pull at the wheel turns the knuckle
        // less about it (13 to 16 cm inboard, a front-wheel-drive car toed its wheels out under power and wandered).
        let top = node(c + inward * 0.06 + SIMD3(0, 0.19, 0), mass: km)
        let bottom = node(c + inward * 0.04 + SIMD3(0, -0.14, 0), mass: km)
        // The steering arm ahead of the axle (front steer): the drive's pull moves the knuckle forward on its mounts a
        // little, and about an arm behind the axle that toed the wheel out (2.7 degrees under a front-wheel drive's
        // launch, and the car wandered); ahead of it, about nothing. A rear corner holds its toe with a second link
        // behind the axle too (with the one alone, its wheels toed out a degree under drive and a tall car weaved).
        let arm = node(c + inward * 0.15 + SIMD3(0, 0, 0.14), mass: front ? km : km / 2)
        let toeArm: Int? = front ? nil : node(c + inward * 0.15 + SIMD3(0, 0, -0.14), mass: km / 2)
        let knuckle = [hubIn, hubOut, top, bottom, arm] + (toeArm.map { [$0] } ?? [])
        for i in 0..<knuckle.count {
            for j in (i + 1)..<knuckle.count { beam(knuckle[i], knuckle[j], .rigid, .suspension) }
        }
        let inner = s * (spec.track / 2)
        let upperF = node([inner - s * 0.5, nodes[top].y + 0.03, zc + 0.16], mass: mm)
        let upperB = node([inner - s * 0.5, nodes[top].y + 0.03, zc - 0.16], mass: mm)
        let lowerF = node([inner - s * 0.52, nodes[bottom].y + 0.02, zc + 0.22], mass: mm)
        let lowerB = node([inner - s * 0.52, nodes[bottom].y + 0.02, zc - 0.22], mass: mm)
        let tower = node([inner - s * 0.3, min(c.y + 0.42, spec.beltHeight(zc) - 0.05), zc], mass: mm)
        let rack = node([inner - s * 0.5, nodes[arm].y, nodes[arm].z], mass: front ? mm : mm / 2)
        let toeRack: Int? = toeArm.map { node([inner - s * 0.5, nodes[$0].y, nodes[$0].z], mass: mm / 2) }
        // The mounts are a subframe (each tied to every other), held from the sides and the floor near it.
        let mounts = [upperF, upperB, lowerF, lowerB, tower, rack] + (toeRack.map { [$0] } ?? [])
        for i in 0..<mounts.count {
            for j in (i + 1)..<mounts.count { beam(mounts[i], mounts[j], .plastic, .cabinRail) }
        }
        for m in mounts {
            // (A front rack, ahead of the axle, is held as the crumple zone's rails are: as the cabin's, it stiffened the
            // front against a wall.)
            let zone: CarBeamZone = front && m == rack ? .rail : .cabinRail
            for r in nearestRing(nodes[m], count: 2, slots: CarBlueprint.sides) + nearestRing(nodes[m], count: 2) where !beams.contains(where: {
                $0.a == m && $0.b == r
            }) {
                beam(m, r, .plastic, zone)
            }
        }
        // The wishbones (the kingpin's ends are their ball joints), the tie rod (and a rear corner's second toe link).
        for (a, b) in [(top, upperF), (top, upperB), (bottom, lowerF), (bottom, lowerB)] { beam(a, b, .rigid, .suspension) }
        var tie = Beam(a: arm, b: rack, kind: front ? .steer : .rigid, zone: .suspension)
        // Steering left turns a front wheel's nose to +x: its arm, ahead of the axle, to +x too, lengthening the left
        // tie rod and shortening the right one.
        if front { tie.steer = s * 0.14 }
        beams.append(tie)
        if let toeArm, let toeRack { beams.append(Beam(a: toeArm, b: toeRack, kind: .rigid, zone: .suspension)) }
        // The spring and damper, preloaded to hold the car's corner at this ride height (the rate at the wheel is the
        // spring's along it x the square of its lean); a bump stop and a rebound strap at the ends of the travel.
        let d = nodes[tower] - nodes[bottom], length = simd_length(d), lean = max(d.y / length, 0.3)
        let rate = spec.spring / (lean * lean)
        let corner = (sprung + 6 * mm) * g / lean
        beams.append(Beam(a: bottom, b: tower, kind: .spring, zone: .suspension, stiffness: rate, damping: spec.damper / (lean * lean),
                          rest: length + corner / rate))
        beams.append(Beam(a: bottom, b: tower, kind: .compression, zone: .suspension, stiffness: rate * 8, damping: spec.damper / (lean * lean),
                          rest: length - spec.travel * lean))
        beams.append(Beam(a: bottom, b: tower, kind: .tension, zone: .suspension, stiffness: rate * 8, damping: 0,
                          rest: length + spec.travel * lean))
        corners.append(Corner(centre: c, hubIn: hubIn, hubOut: hubOut, arm: arm, front: front, side: s, hubOffset: hub))
    }

    /// The ring nodes' weights made kilograms: the car's mass less its wheels, engine, knuckles and mounts (before the
    /// corners are built).
    private mutating func distributeMass() {
        let ringNodes = rings.flatMap { $0 }
        let weights = ringNodes.reduce(Float(0)) { $0 + masses[$1] }
        let rest = spec.mass - 4 * spec.wheelMass - spec.engineMass - 4 * (5 * CarBlueprint.knuckleMass + 6 * CarBlueprint.mountMass)
        for n in ringNodes { masses[n] *= max(rest, 100) / weights }
    }

    package var bodyMass: Float { masses.reduce(0, +) }

    /// How far a tyre gives before its rim touches (m): the rim's radius is the wheel's less this.
    package static let tyreDepth: Float = 0.07
    /// A wheel's body's shape (the rim: its tyre is the car's, CarTires.swift), standing along y.
    package var rimShape: SDFShape {
        SDFShape(.cylinder(halfHeight: spec.wheelWidth / 2, radius: spec.wheelRadius - CarBlueprint.tyreDepth, rounding: 0.02))
    }
}
