import Foundation
import simd

/// The stress test: a 40 x 8 x 40 m building in four zones round a cross-shaped aisle, each behind partitions with
/// doorways. A warehouse (pallet racks, forklifts, carts, an overhead conveyor) and a factory floor (two conveyor
/// loops, robot arms, machines, gantry hoists) at the back; a two-level parking garage and an open-plan office with
/// glass meeting rooms at the front, whose wall has a garage entrance, a door and a window band to the sky.
/// `objectCount` props fill it, one instance each: cartons on the racks, parcels and parts on the conveyors,
/// vehicles, machines, desks, chairs, people and drones. A kind of prop with fixed places (rack slots, parking bays,
/// desks, machines, lanes) takes no more than it has, and its share goes to the kinds with room left; drones always
/// have room. About 60% of the props move up to 400 objects; past 1000 the extra ones are mostly cartons in the
/// racks and drones (at 2000, 1256 cartons, 355 drones, a third moving).
/// `lightCount` lights, exactly, of the same total power at any count: light j is in zone j % 4, and every other
/// one of a zone's is a ceiling fixture (high-bay spots, fluorescent tubes, LED panels) or one that travels
/// (headlights, beacons, hoist spots, weld glows), riding the vehicle, arm or hoist with the same slot. Above 256
/// lights they shrink. No props glow, so the scene has no lights but these.
/// Seeded, so every run is identical.
extension Scene {
    func buildStress(objects objectCount: Int, lights lightCount: Int) {
        var rng = SplitMix64(seed: 0x5EED_1234)
        let cube = addMesh(Scene.cubeMesh())
        let quad = addMesh(Scene.quadMesh())

        func matte(_ c: SIMD3<Float>) -> GPUMaterial { Props.matte(c) }
        func shiny(_ c: SIMD3<Float>, metallic: Float = 0, roughness: Float) -> GPUMaterial { Props.shiny(c, metallic: metallic, roughness: roughness) }
        /// Parts that belong together as one mesh of several materials (added side by side, so the offsets reach them).
        func prop(_ parts: [(GPUMaterial, MeshBuilder)]) -> (mesh: Int, material: Int) {
            var merged = MeshBuilder(), offsets: [UInt8] = []
            let first = materials.count
            for (k, (m, b)) in parts.enumerated() {
                _ = addMaterial(m)
                offsets += [UInt8](repeating: UInt8(k), count: b.triangleCount)
                merged.append(b)
            }
            return (addMesh(merged.geometry, uvs: merged.uvs, materials: offsets), first)
        }
        func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ material: Int, mask: UInt32 = Scene.maskGeometry) {
            guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return }
            addInstance(cube, material, translate((lo + hi) / 2) * scale(hi - lo), mask: mask)
        }

        // MARK: The building

        let concrete = addPBRMaterial(baseColor: [0.42, 0.41, 0.39], metallic: 0, roughness: 0.45)
        let wallPaint = addMaterial(albedo: [0.62, 0.62, 0.6])
        let ceilingPaint = addMaterial(albedo: [0.5, 0.5, 0.52])
        let partition = addMaterial(albedo: [0.55, 0.58, 0.6])
        let steel = addPBRMaterial(baseColor: [0.35, 0.37, 0.4], metallic: 1, roughness: 0.4)
        let yellowPaint = addMaterial(albedo: [0.8, 0.62, 0.08])
        let whitePaint = addMaterial(albedo: [0.75, 0.75, 0.72])
        let carpet = addMaterial(albedo: [0.2, 0.24, 0.32])
        let glass = addGlassMaterial(tint: [0.9, 0.95, 0.95])

        let h = Hall.height
        addInstance(quad, concrete, scale([40, 1, 40]))                                                          // floor
        addInstance(quad, ceilingPaint, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([40, 1, 40]))    // ceiling
        slab([-20, 0, -20.3], [20, h, -20], wallPaint)                                                         // back
        slab([-20.3, 0, -20.3], [-20, h, 20.3], wallPaint)                                                     // sides
        slab([20, 0, -20.3], [20.3, h, 20.3], wallPaint)
        // The front, with the garage entrance, the aisle's door and the office's window band.
        slab([-20, 0, 20], [-12.5, h, 20.3], wallPaint)
        slab([-12.5, 2.7, 20], [-6.5, h, 20.3], wallPaint)
        slab([-6.5, 0, 20], [-2, h, 20.3], wallPaint)
        slab([-2, 5, 20], [2, h, 20.3], wallPaint)
        slab([2, 0, 20], [3, h, 20.3], wallPaint)
        slab([3, 0, 20], [15, 1, 20.3], wallPaint)
        slab([3, 2.8, 20], [15, h, 20.3], wallPaint)
        slab([15, 0, 20], [20, h, 20.3], wallPaint)
        slab([3, 1, 20.1], [15, 2.8, 20.14], glass, mask: Scene.maskGlass)
        // Roof beams.
        for z: Float in [-15, -5, 5, 15] { slab([-20, h - 0.35, z - 0.15], [20, h, z + 0.15], steel) }

        /// A partition along x (at z) or along z (at x) from `a` to `b`, `height` tall, with a 2.6 m doorway (a gap in a
        /// barrier lower than that).
        func partitionWall(alongX: Bool, at c: Float, from a: Float, to b: Float, height: Float, door: ClosedRange<Float>,
                           material: Int) {
            func piece(_ lo: Float, _ hi: Float, _ y0: Float, _ y1: Float) {
                if alongX { slab([lo, y0, c - 0.1], [hi, y1, c + 0.1], material) } else { slab([c - 0.1, y0, lo], [c + 0.1, y1, hi], material) }
            }
            piece(a, door.lowerBound, 0, height)
            piece(door.lowerBound, door.upperBound, 2.6, height)
            piece(door.upperBound, b, 0, height)
        }
        // The warehouse and the factory behind safety barriers, the garage and the office behind walls.
        partitionWall(alongX: false, at: -2, from: -20, to: -2, height: 1.1, door: -6 ... -3, material: yellowPaint)
        partitionWall(alongX: true, at: -2, from: -20, to: -2, height: 1.1, door: -13 ... -10, material: yellowPaint)
        partitionWall(alongX: false, at: 2, from: -20, to: -2, height: 1.1, door: -12.5 ... -9.5, material: yellowPaint)
        partitionWall(alongX: true, at: -2, from: 2, to: 20, height: 1.1, door: 9.5 ... 12.5, material: yellowPaint)
        partitionWall(alongX: false, at: -2, from: 2, to: 20, height: 4.4, door: 8 ... 11, material: partition)          // garage (and its parapet)
        partitionWall(alongX: true, at: 2, from: -20, to: -2, height: 4.4, door: -6 ... -3, material: partition)
        partitionWall(alongX: false, at: 2, from: 2, to: 20, height: 3.5, door: 10.5 ... 12.3, material: partition)      // office
        partitionWall(alongX: true, at: 2, from: 2, to: 20, height: 3.5, door: 6 ... 9, material: partition)
        for x: Float in [-2, 2] { for z: Float in [-2, 2] { slab([x - 0.2, 0, z - 0.2], [x + 0.2, h, z + 0.2], steel) } }

        // MARK: Warehouse: racks and the overhead conveyor

        do {
            // One face of rack, x from 0 to 1.2: uprights, beams and a pallet on every slot.
            var uprights = MeshBuilder(), beams = MeshBuilder(), pallets = MeshBuilder()
            for zu in Hall.rackUprights {
                for x: Float in [0.02, 1.1] { uprights.box([x, 0, zu - 0.04], [x + 0.08, Hall.rackTop, zu + 0.04]) }
            }
            for level in Hall.rackLevels.dropFirst() {
                for x: Float in [0.02, 1.1] { beams.box([x, level - 0.12, Hall.rackUprights.first!], [x + 0.08, level, Hall.rackUprights.last!]) }
            }
            for level in Hall.rackLevels {
                for zu in Hall.rackUprights.dropLast() {
                    for dz in Hall.palletOffsets { pallets.box([0.1, level, zu + dz - 0.6], [1.1, level + 0.14, zu + dz + 0.6]) }
                }
            }
            let rack = prop([(matte([0.12, 0.22, 0.5]), uprights), (matte([0.85, 0.35, 0.05]), beams), (matte([0.55, 0.42, 0.26]), pallets)])
            for lo in Hall.rackFaces { addInstance(rack.mesh, rack.material, translate([lo, 0, 0])) }
        }

        /// A conveyor's bed round a loop, with legs down to the floor or hangers up to the ceiling. The bed and its
        /// side rails are swept along the loop: one piece per straight, eight per round corner, so the curves are smooth.
        func conveyor(_ loop: Loop, width: Float, hung: Bool) -> MeshBuilder {
            var b = MeshBuilder()
            let w = width / 2
            // Cross-sections (lateral, height), corners in an order that makes the faces face out.
            let profiles: [[SIMD2<Float>]] = [[[w, 0], [-w, 0], [-w, -0.15], [w, -0.15]],
                                              [[w + 0.04, 0.07], [w, 0.07], [w, 0], [w + 0.04, 0]],
                                              [[-w, 0.07], [-w - 0.04, 0.07], [-w - 0.04, 0], [-w, 0]]]
            let frames = loop.samples(perCorner: 8).map { s -> (SIMD3<Float>, SIMD3<Float>) in
                let (p, h) = loop.at(s)
                return (p, SIMD3(-h.z, 0, h.x))   // where, and the lateral axis (heading x up)
            }
            func at(_ f: (SIMD3<Float>, SIMD3<Float>), _ q: SIMD2<Float>) -> SIMD3<Float> { f.0 + f.1 * q.x + [0, q.y, 0] }
            for i in frames.indices.dropLast() {
                let f0 = frames[i], f1 = frames[i + 1]
                for profile in profiles {
                    for j in profile.indices {
                        let a = profile[j], c = profile[(j + 1) % profile.count]
                        b.quad(at(f0, a), at(f1, a), at(f1, c), at(f0, c))
                    }
                }
            }
            for k in 0..<Int(loop.length / 1.5) {
                let (p, heading) = loop.at(1.5 * Float(k))
                b.frame = Hall.placed(p, facing: heading)
                for side: Float in [-1, 1] {
                    let z = side * (w - 0.05)
                    if hung { b.box([-0.02, 0, z - 0.02], [0.02, Hall.height - loop.y, z + 0.02]) }
                    else { b.box([-0.03, -loop.y, z - 0.03], [0.03, -0.15, z + 0.03]) }
                }
            }
            b.frame = matrix_identity_float4x4
            return b
        }
        let overhead = prop([(shiny([0.3, 0.32, 0.35], metallic: 1, roughness: 0.5), conveyor(Hall.overheadLoop, width: 0.6, hung: true))])
        addInstance(overhead.mesh, overhead.material, matrix_identity_float4x4)

        // MARK: Factory: conveyor loops, gantry rails

        var beds = conveyor(Hall.factoryLoops[0], width: 0.6, hung: false)
        beds.append(conveyor(Hall.factoryLoops[1], width: 0.6, hung: false))
        let belt = prop([(shiny([0.08, 0.08, 0.09], roughness: 0.6), beds)])
        addInstance(belt.mesh, belt.material, matrix_identity_float4x4)
        for z in Hall.railZ { slab([2.3, Hall.railY, z - 0.15], [19.7, Hall.railY + 0.25, z + 0.15], yellowPaint) }

        // MARK: Garage: the deck, its ramp and columns, the bays' lines

        let deckTop = Hall.deck
        slab([-17, deckTop - 0.3, 2], [-2, deckTop, 20], concrete)
        slab([-20, deckTop - 0.3, 2], [-17, deckTop, 6], concrete)
        do {
            var ramp = MeshBuilder()
            let a: SIMD3<Float> = [-20, deckTop, 6], b: SIMD3<Float> = [-17, deckTop, 6]
            let c: SIMD3<Float> = [-17, 0, 19], d: SIMD3<Float> = [-20, 0, 19]
            let down: SIMD3<Float> = [0, -0.3, 0]
            ramp.quad(d, c, b, a)
            ramp.quad(a + down, b + down, c, d)
            ramp.triangle(c, b + down, b)
            ramp.triangle(d, a, a + down)
            ramp.box([-17.15, deckTop, 2], [-17, deckTop + 1.0, 6])   // the landing's rail
            let r = prop([(shiny([0.42, 0.41, 0.39], roughness: 0.45), ramp)])
            addInstance(r.mesh, r.material, matrix_identity_float4x4)
        }
        for x: Float in [-16.6, -9.5, -2.4] {
            for z: Float in [7.5, 12.5, 17.5] where !(x == -9.5 && z == 17.5) {
                slab([x - 0.2, 0, z - 0.2], [x + 0.2, deckTop - 0.3, z + 0.2], concrete)
            }
        }
        for y in Hall.garageLevels {
            var lines = MeshBuilder()
            for (lo, hi) in [(Float(-17), Float(-12)), (-7, -2)] {
                for k in 0...7 {
                    let z = 2.5 + 2.5 * Float(k)
                    lines.box([lo + 0.3, y, z - 0.05], [hi - 0.3, y + 0.005, z + 0.05], faces: .top)
                }
            }
            let l = prop([(matte([0.85, 0.85, 0.8]), lines)])
            addInstance(l.mesh, l.material, matrix_identity_float4x4)
        }
        // The deck's parapet over the aisle sides is the partitions' upper part; along the ramp, a rail.
        slab([-17.15, deckTop, 6], [-17, deckTop + 1.0, 20], whitePaint)

        // MARK: Office: carpet, glass meeting rooms

        addInstance(quad, carpet, translate([11, 0.01, 11]) * scale([18, 1, 18]))
        slab([15.5, 0, 2.1], [15.53, 2.9, 19.9], glass, mask: Scene.maskGlass)
        slab([15.53, 0, 10.98], [19.9, 2.9, 11.02], glass, mask: Scene.maskGlass)
        do {
            var frames = MeshBuilder(), tables = MeshBuilder(), seats = MeshBuilder()
            for z in stride(from: Float(2.1), through: 19.9, by: 2.2) { frames.box([15.48, 0, z - 0.03], [15.55, 2.9, z + 0.03]) }
            frames.box([15.48, 2.9, 2.1], [15.55, 3.0, 19.9])
            for cz: Float in [6.7, 15.3] {
                tables.box([16.6, 0.72, cz - 1.8], [18.8, 0.76, cz + 1.8])
                tables.box([17.5, 0, cz - 1.2], [17.9, 0.72, cz + 1.2])
                for dz: Float in [-1.2, 0, 1.2] {
                    for x: Float in [16.1, 19.3] {
                        seats.box([x - 0.24, 0.42, cz + dz - 0.24], [x + 0.24, 0.48, cz + dz + 0.24])
                        let back: Float = x < 17 ? x - 0.24 : x + 0.2
                        seats.box([back, 0.48, cz + dz - 0.22], [back + 0.04, 0.95, cz + dz + 0.22])
                        seats.cylinder([x, 0, cz + dz], radius: 0.03, height: 0.42, segments: 6, cap: false)
                    }
                }
            }
            let rooms = prop([(shiny([0.15, 0.15, 0.16], metallic: 1, roughness: 0.35), frames),
                              (shiny([0.55, 0.42, 0.3], roughness: 0.35), tables), (matte([0.18, 0.18, 0.2]), seats)])
            addInstance(rooms.mesh, rooms.material, matrix_identity_float4x4)
        }

        // MARK: Props

        let cartons = [[0.62, 0.45, 0.28], [0.7, 0.55, 0.36], [0.82, 0.8, 0.76]].map { addMaterial(albedo: SIMD3<Float>($0.map(Float.init))) }
        let forklift = prop(Props.forklift())
        let agv = prop(Props.agv())
        let pickerMesh = prop(Props.person(shirt: [0.95, 0.75, 0.05], trousers: [0.12, 0.13, 0.16]))
        let parcelMeshes = [[0.62, 0.45, 0.28], [0.7, 0.55, 0.36]].map { c -> (mesh: Int, material: Int) in
            var b = MeshBuilder()
            b.box([-0.2, 0, -0.17], [0.2, 0.3, 0.17])
            return prop([(matte(SIMD3<Float>(c.map(Float.init))), b)])
        }
        let partMeshes: [(mesh: Int, material: Int)] = {
            var drum = MeshBuilder(), crate = MeshBuilder(), tote = MeshBuilder()
            drum.cylinder([0, 0, 0], radius: 0.15, height: 0.3, segments: 12)
            crate.box([-0.18, 0, -0.18], [0.18, 0.32, 0.18])
            tote.box([-0.22, 0, -0.16], [0.22, 0.22, 0.16])
            return [prop([(shiny([0.75, 0.76, 0.78], metallic: 1, roughness: 0.25), drum)]),
                    prop([(matte([0.5, 0.36, 0.2]), crate)]),
                    prop([(shiny([0.1, 0.3, 0.7], roughness: 0.5), tote)])]
        }()
        let arm = prop(Props.robotArm())
        let machine = prop(Props.machine())
        let trolley = prop(Props.trolley())
        let carMeshes = [[0.6, 0.05, 0.04], [0.08, 0.1, 0.14], [0.75, 0.75, 0.77], [0.1, 0.25, 0.55], [0.85, 0.85, 0.82]]
            .map { prop(Props.car(paint: SIMD3<Float>($0.map(Float.init)))) }
        let desk = prop(Props.desk())
        let chair = prop(Props.chair())
        let personMeshes = [[0.2, 0.3, 0.55], [0.7, 0.7, 0.72], [0.45, 0.12, 0.15]].map {
            prop(Props.person(shirt: SIMD3<Float>($0.map(Float.init)), trousers: [0.15, 0.15, 0.2]))
        }
        let robot = prop(Props.robot())
        let drone = prop(Props.drone())

        // Places for what stands still, in a shuffled order, so a few props spread over the whole zone.
        func shuffled<T>(_ a: [T]) -> [T] {
            var a = a
            for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, rng.int(i + 1)) }
            return a
        }
        let cartonSlots = shuffled(Hall.cartonSlots)
        let machineSlots = shuffled(Hall.machineSlots)
        let bays = shuffled(Hall.parkingBays)
        let desks = shuffled(Array(0..<Hall.deskCount))

        enum Kind: Int, CaseIterable {
            case carton, forklift, agv, picker, parcel, part, arm, machine, trolley, parked, car, desk, chair, person, robot, drone
            var weight: Float {
                [0.2, 0.01, 0.04, 0.012, 0.12, 0.16, 0.025, 0.025, 0.008, 0.06, 0.02, 0.08, 0.08, 0.015, 0.008, 0.06][rawValue]
            }
            var zone: Zone {
                switch self {
                case .carton, .forklift, .agv, .picker, .parcel: return .warehouse
                case .part, .arm, .machine, .trolley: return .factory
                case .parked, .car: return .garage
                case .desk, .chair, .person, .robot, .drone: return .office
                }
            }
        }
        let capacity: [Kind: Int] = [.carton: cartonSlots.count, .forklift: Hall.forkliftLanes.count, .agv: Hall.agvCount,
                                     .picker: Hall.pickerLanes.count, .parcel: Hall.parcelCount, .part: Hall.partCount,
                                     .arm: Hall.armBases.count, .machine: machineSlots.count, .trolley: Hall.railZ.count,
                                     .parked: bays.count, .car: Hall.carCount, .desk: desks.count, .chair: Hall.deskCount,
                                     .person: Hall.personLanes.count, .robot: Hall.robotLanes.count]
        // Each prop is of a kind picked by weight among the kinds that still have room (drones always do).
        var taken: [Kind: Int] = [:], open = Kind.allCases
        for _ in 0..<objectCount {
            var u = rng.next() * open.reduce(0) { $0 + $1.weight }, kind = Kind.drone
            for k in open { if u < k.weight { kind = k; break }; u -= k.weight }
            let n = taken[kind, default: 0]
            taken[kind] = n + 1
            if let cap = capacity[kind], n + 1 >= cap { open.removeAll { $0 == kind } }
            let zone = kind == .drone ? Zone(rawValue: rng.int(4))! : kind.zone
            let phase = rng.range(0, 2 * .pi)
            switch kind {
            case .carton:
                let p = cartonSlots[n]
                let size = SIMD3<Float>(rng.range(0.4, 0.46), rng.range(0.34, 0.42), rng.range(0.48, 0.56))
                addInstance(cube, cartons[rng.int(cartons.count)], translate(p + [0, size.y / 2, 0]) * scale(size))
            case .forklift:
                addInstance(forklift.mesh, forklift.material, matrix_identity_float4x4) { t in Hall.forklift(n, t) }
            case .agv:
                addInstance(agv.mesh, agv.material, matrix_identity_float4x4) { t in Hall.agv(n, t) }
            case .picker:
                addInstance(pickerMesh.mesh, pickerMesh.material, matrix_identity_float4x4) { t in Hall.walker(Hall.pickerLanes[n], speed: 0.9, phase: phase, t) }
            case .parcel:
                let m = parcelMeshes[rng.int(parcelMeshes.count)]
                addInstance(m.mesh, m.material, matrix_identity_float4x4) { t in Hall.parcel(n, t) }
            case .part:
                let m = partMeshes[rng.int(partMeshes.count)]
                addInstance(m.mesh, m.material, matrix_identity_float4x4) { t in Hall.part(n, t) }
            case .arm:
                addInstance(arm.mesh, arm.material, matrix_identity_float4x4) { t in Hall.arm(n, t) }
            case .machine:
                let s = machineSlots[n]
                addInstance(machine.mesh, machine.material, Hall.placed(s.position, facing: s.facing))
            case .trolley:
                addInstance(trolley.mesh, trolley.material, matrix_identity_float4x4) { t in Hall.trolley(n, t) }
            case .parked:
                let s = bays[n], m = carMeshes[rng.int(carMeshes.count)]
                addInstance(m.mesh, m.material, Hall.placed(s.position, facing: s.facing))
            case .car:
                let m = carMeshes[rng.int(carMeshes.count)]
                addInstance(m.mesh, m.material, matrix_identity_float4x4) { t in Hall.car(n, t) }
            case .desk:
                let s = Hall.deskSlot(desks[n])
                addInstance(desk.mesh, desk.material, Hall.placed(s.position, facing: s.facing))
            case .chair:
                addInstance(chair.mesh, chair.material, matrix_identity_float4x4) { t in Hall.chair(n, phase: phase, t) }
            case .person:
                let m = personMeshes[rng.int(personMeshes.count)]
                addInstance(m.mesh, m.material, matrix_identity_float4x4) { t in Hall.walker(Hall.personLanes[n], speed: 1.1, phase: phase, t) }
            case .robot:
                addInstance(robot.mesh, robot.material, matrix_identity_float4x4) { t in Hall.walker(Hall.robotLanes[n], speed: 0.7, phase: phase, t) }
            case .drone:
                let box = Hall.airspace[zone.rawValue]
                let c = (box.lo + box.hi) / 2, a = (box.hi - box.lo) / 2
                let amp = SIMD3<Float>(rng.range(0.4, 1), rng.range(0.3, 1), rng.range(0.4, 1)) * a
                let center = c + (a - amp) * SIMD3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1))
                let f = SIMD3<Float>(rng.range(0.15, 0.4), rng.range(0.3, 0.8), rng.range(0.15, 0.4))
                let spin = rng.range(-0.6, 0.6)
                addInstance(drone.mesh, drone.material, matrix_identity_float4x4) { t in
                    let p = center + amp * SIMD3(sin(f.x * t + phase), sin(f.y * t + 2 * phase), cos(f.z * t + phase))
                    return translate(p) * rotate(spin * t + phase, [0, 1, 0])
                }
            }
        }

        // MARK: Lights

        var fixtures = [Int](repeating: 0, count: 4), movers = [Int](repeating: 0, count: 4)
        for j in 0..<lightCount { if (j / 4) % 2 == 0 { fixtures[j % 4] += 1 } else { movers[j % 4] += 1 } }
        // Thousands of lights: smaller fixtures and bulbs.
        let s: Float = lightCount > 256 ? pow(256 / Float(lightCount), 1.0 / 3) : 1
        let highBay = LightKind.spot(radius: 0.25 * s, inner: 35 * .pi / 180, outer: 60 * .pi / 180)
        let tube = LightKind.tube(length: 1.5 * s, radius: 0.03 * s)
        let panel = LightKind.rect(width: 1.2 * s, height: 0.6 * s)
        let headlight = LightKind.spot(radius: 0.07 * s, inner: 12 * .pi / 180, outer: 28 * .pi / 180)
        let hoist = LightKind.spot(radius: 0.12 * s, inner: 20 * .pi / 180, outer: 40 * .pi / 180)
        let beacon = LightKind.sphere(radius: 0.06 * s), weld = LightKind.sphere(radius: 0.04 * s)

        /// What each light is, in order: kind, hue, share of the power, motion and pose.
        var specs: [(kind: LightKind, hue: SIMD3<Float>, weight: Float, motion: LightMotion, pose: (Float) -> LightPose)] = []
        var fixture = [Int](repeating: 0, count: 4), mover = [Int](repeating: 0, count: 4)
        for j in 0..<lightCount {
            let zone = Zone(rawValue: j % 4)!
            if (j / 4) % 2 == 0 {
                let f = fixture[zone.rawValue]
                fixture[zone.rawValue] += 1
                let p = Hall.fixture(zone, f, of: fixtures[zone.rawValue])
                switch zone {
                case .warehouse:
                    specs.append((highBay, [1.0, 0.82, 0.6], 1, .constant, { _ in LightPose(position: [p.x, 7.3, p.y]) }))
                case .factory:
                    specs.append((tube, [0.85, 0.93, 1.0], 1, .constant, { _ in LightPose(position: [p.x, 6.2, p.y], direction: [1, 0, 0]) }))
                case .garage:
                    let y: Float = f % 2 == 0 ? Hall.deck - 0.38 : 7.4
                    if f % 7 == 5 {
                        specs.append((tube, [0.85, 0.93, 1.0], 1, .scaleOnly, { t in
                            let k = Float(Int(t * 12 + Float(f)) &* 7919 % 101) / 101
                            let burst = sin(0.9 * t + Float(f)) > 0.6
                            return LightPose(position: [p.x, y, p.y], direction: [0, 0, 1], scale: SIMD3(repeating: burst && k < 0.45 ? 0.08 : 1))
                        }))
                    } else {
                        specs.append((tube, [0.85, 0.93, 1.0], 1, .constant, { _ in LightPose(position: [p.x, y, p.y], direction: [0, 0, 1]) }))
                    }
                case .office:
                    specs.append((panel, [1.0, 0.9, 0.78], 1, .constant, { _ in
                        LightPose(position: [p.x, 3.4, p.y], direction: [0, -1, 0], tangent: [1, 0, 0])
                    }))
                }
            } else {
                let m = mover[zone.rawValue]
                mover[zone.rawValue] += 1
                switch zone {
                case .warehouse where m % 2 == 0:
                    specs.append((headlight, [0.9, 0.95, 1.0], 0.6, .animated, { t in Hall.pose(Hall.forklift(m / 2, t), at: [0.5, 1.95, 0], toward: [1, -0.35, 0]) }))
                case .warehouse:
                    specs.append((beacon, [1.0, 0.55, 0.1], 0.25, .animated, { t in Hall.pose(Hall.agv(m / 2, t), at: [-0.45, 1.35, 0]) }))
                case .factory where m % 2 == 0:
                    specs.append((hoist, [1.0, 0.85, 0.65], 0.6, .animated, { t in Hall.pose(Hall.trolley(m / 2, t), at: [0, Hall.railY - 0.45, 0.4], toward: [0.1, -1, 0]) }))
                case .factory:
                    specs.append((weld, [0.55, 0.75, 1.0], 0.3, .animated, { t in Hall.pose(Hall.arm(m / 2, t), at: Props.armTip) }))
                case .garage:
                    specs.append((headlight, [0.9, 0.95, 1.0], 0.6, .animated, { t in Hall.pose(Hall.car(m, t), at: [2.28, 0.72, 0], toward: [1, -0.12, 0]) }))
                case .office:
                    let lane = Hall.robotLanes[m % Hall.robotLanes.count], phase = Float(m) * 2.4
                    specs.append((beacon, [0.2, 0.5, 1.0], 0.2, .animated, { t in Hall.pose(Hall.walker(lane, speed: 0.7, phase: phase, t), at: [0, 0.97, 0]) }))
                }
            }
        }
        // Equal power for equal weights, the same total at any count (about four times the old 20 m hall's).
        let total: Float = 240 / specs.reduce(0) { $0 + $1.weight }
        for spec in specs {
            let hue = spec.hue / dot(spec.hue, [0.2126, 0.7152, 0.0722])
            let intensity = total * spec.weight   // a sphere's of the same power
            let color: SIMD3<Float>
            switch spec.kind {
            case .spot(_, _, let outer): color = hue * intensity * 2 / (1 - cos(outer))
            case .rect(let w, let h): color = hue * intensity * 4 / (w * h)
            default: color = hue * intensity
            }
            addLight(spec.kind, color: color, motion: spec.motion, pose: spec.pose)
        }

        defaultCamera = Scene.stressCamera
    }

    /// High over the front of the central aisle, looking down it between the four zones.
    static let stressCamera: Camera = {
        var c = Camera()
        c.position = [0, 6.8, 19.3]
        c.pitch = -0.38
        return c
    }()
}

// MARK: - Layout

/// The stress building's four zones: x < 0 or > 0, z < 0 (back) or > 0 (front).
private enum Zone: Int { case warehouse, factory, garage, office }

/// A closed loop for things that travel: a rectangle with round corners at height y.
private struct Loop {
    let center: SIMD2<Float>, half: SIMD2<Float>, radius: Float, y: Float
    var length: Float { 4 * (half.x - radius) + 4 * (half.y - radius) + 2 * .pi * radius }

    /// Distances round the loop that trace it: each straight's ends and `perCorner` steps round each corner, back to
    /// the start.
    func samples(perCorner n: Int) -> [Float] {
        var out: [Float] = [], s: Float = 0
        let arc = 0.5 * Float.pi * radius
        for i in 0..<4 {
            out.append(s)
            s += 2 * (i % 2 == 0 ? half.x - radius : half.y - radius)
            for k in 0..<n { out.append(s + arc * Float(k) / Float(n)) }
            s += arc
        }
        return out + [length]
    }

    /// Where something `s` metres round the loop is, and which way it faces.
    func at(_ s: Float) -> (position: SIMD3<Float>, heading: SIMD3<Float>) {
        var s = s.truncatingRemainder(dividingBy: length)
        if s < 0 { s += length }
        for (i, d) in [SIMD2<Float>(1, 0), [0, -1], [-1, 0], [0, 1]].enumerated() {
            let n = SIMD2(-d.y, d.x)   // outwards
            let along = i % 2 == 0 ? half.x - radius : half.y - radius, across = i % 2 == 0 ? half.y : half.x
            if s <= 2 * along {
                let p = center + n * across - d * along + d * s
                return (SIMD3(p.x, y, p.y), SIMD3(d.x, 0, d.y))
            }
            s -= 2 * along
            let arc = 0.5 * Float.pi * radius
            if s <= arc || i == 3 {
                let phi = min(s, arc) / radius
                let p = center + n * (across - radius) + d * along + radius * (n * cos(phi) + d * sin(phi))
                let heading = d * cos(phi) - n * sin(phi)
                return (SIMD3(p.x, y, p.y), SIMD3(heading.x, 0, heading.y))
            }
            s -= arc
        }
        return (SIMD3(center.x, y, center.y), [1, 0, 0])
    }
}

/// Where everything in the stress building is and how it moves. A moving prop's pose depends only on its slot and
/// the time, so a light with the same slot rides it.
private enum Hall {
    static let height: Float = 8
    static let deck: Float = 3.3                 // the garage's upper level

    /// Something's frame: at `p`, its local x along `heading` (horizontal), y up.
    static func placed(_ p: SIMD3<Float>, facing heading: SIMD3<Float>) -> float4x4 {
        let x = normalize(SIMD3(heading.x, 0, heading.z) + [1e-6, 0, 0]), z = cross(x, [0, 1, 0])
        return float4x4(SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(p, 1))
    }

    /// A light carried at `local` by something at `frame`, pointing along local `toward`.
    static func pose(_ frame: float4x4, at local: SIMD3<Float>, toward: SIMD3<Float> = [0, -1, 0]) -> Scene.LightPose {
        let p = frame * SIMD4(local, 1), d = frame * SIMD4(normalize(toward), 0)
        return Scene.LightPose(position: SIMD3(p.x, p.y, p.z), direction: SIMD3(d.x, d.y, d.z))
    }

    /// Back and forth from a to b, slowing at the ends; facing the way it goes (`turns`) or always toward b.
    static func shuttle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, speed: Float, phase: Float, turns: Bool, _ t: Float) -> float4x4 {
        let w = speed * .pi / max(length(b - a), 1e-3), x = w * t + phase
        let p = a + (b - a) * (0.5 - 0.5 * cos(x))
        return placed(p, facing: !turns || sin(x) >= 0 ? b - a : a - b)
    }

    // Fixtures: on a grid over each zone, as square as the count allows.
    static let fixtureAreas: [(lo: SIMD2<Float>, hi: SIMD2<Float>)] = [([-19.5, -19.5], [-2.5, -2.5]), ([2.5, -19.5], [19.5, -2.5]),
                                                                       ([-17, 2.5], [-2.5, 19.5]), ([2.5, 2.5], [15.2, 19.5])]
    static func fixture(_ zone: Zone, _ f: Int, of n: Int) -> SIMD2<Float> {
        let cols = Int(Float(n).squareRoot().rounded(.up)), rows = (n + cols - 1) / cols
        let area = fixtureAreas[zone.rawValue]
        let cell = SIMD2(Float(f % cols) + 0.5, Float(f / cols) + 0.5) / SIMD2(Float(cols), Float(rows))
        return area.lo + (area.hi - area.lo) * cell
    }

    /// Where drones fly in each zone: over the racks, under the hoists, high in the garage and the office.
    static let airspace: [(lo: SIMD3<Float>, hi: SIMD3<Float>)] = [([-19, 6.95, -19], [-3, 7.55, -3]), ([3, 3.2, -19], [19, 4.6, -3]),
                                                                    ([-16.5, 5, 2.5], [-2.5, 7.3, 19.5]), ([2.5, 4.2, 2.5], [15, 7.3, 19.5])]

    // MARK: Warehouse

    /// Each rack face's low x (1.2 m deep): one along the wall, two double rows.
    static let rackFaces: [Float] = [-20, -16.2, -15, -9.2, -8]
    static let rackUprights: [Float] = [-18, -15.2, -12.4, -9.6, -6.8]
    static let rackLevels: [Float] = [0, 1.5, 3, 4.5]
    static let rackTop: Float = 6
    static let palletOffsets: [Float] = [0.725, 2.075]   // two pallets a bay, from its upright
    /// Eight cartons on every pallet: 2 x 2, two layers (where each carton's bottom is).
    static let cartonSlots: [SIMD3<Float>] = {
        var out: [SIMD3<Float>] = []
        for x in rackFaces {
            for level in rackLevels {
                for zu in rackUprights.dropLast() {
                    for dz in palletOffsets {
                        for layer in 0..<2 {
                            for (ox, oz) in [(Float(0.36), Float(-0.3)), (0.84, -0.3), (0.36, 0.3), (0.84, 0.3)] {
                                out.append([x + ox, level + 0.14 + 0.43 * Float(layer), zu + dz + oz])
                            }
                        }
                    }
                }
            }
        }
        return out
    }()

    /// Two forklifts in each wide aisle, one in each half, going forward and back (forks toward the back wall).
    static let forkliftLanes: [(x: Float, a: Float, b: Float)] = [(-11.5, -16.2, -13.2), (-11.5, -9.6, -7.4), (-4.4, -16.2, -13.2), (-4.4, -9.6, -7.4)]
    static func forklift(_ k: Int, _ t: Float) -> float4x4 {
        let lane = forkliftLanes[k % forkliftLanes.count]
        return shuttle([lane.x, 0, lane.b], [lane.x, 0, lane.a], speed: 1.0, phase: 1.3 * Float(k), turns: false, t)
    }

    /// Carts round the cross aisle in front of the racks, evenly spaced.
    static let agvLoop = Loop(center: [-11, -4], half: [8.4, 1.3], radius: 1.2, y: 0)
    static let agvCount = Int(agvLoop.length / 2.2)
    static func agv(_ k: Int, _ t: Float) -> float4x4 {
        let (p, heading) = agvLoop.at(Float(k) * agvLoop.length / Float(agvCount) + 0.9 * t)
        return placed(p, facing: heading)
    }

    /// Pickers walk along the rack faces.
    static let pickerLanes: [(SIMD3<Float>, SIMD3<Float>)] = [-17.5, -13.15, -9.85, -6.1, -2.7].map { ([$0, 0, -17.4], [$0, 0, -7.3]) }

    /// The overhead conveyor: a loop over the two wide aisles, above the racks.
    static let overheadLoop = Loop(center: [-7.975, -12.3], half: [3.575, 5.9], radius: 1.4, y: 6.45)
    static let parcelCount = Int(overheadLoop.length / 0.5)
    static func parcel(_ k: Int, _ t: Float) -> float4x4 {
        let (p, heading) = overheadLoop.at(Float(k) * overheadLoop.length / Float(parcelCount) + 0.5 * t)
        return placed(p, facing: heading)
    }

    // MARK: Factory

    static let factoryLoops = [Loop(center: [11, -14.5], half: [6.5, 1.6], radius: 0.8, y: 0.85),
                               Loop(center: [11, -7.5], half: [6.5, 1.6], radius: 0.8, y: 0.85)]
    static let partsPerLoop = Int(factoryLoops[0].length / 0.48)
    static let partCount = 2 * partsPerLoop
    static func part(_ k: Int, _ t: Float) -> float4x4 {
        let loop = factoryLoops[k % 2]
        let (p, heading) = loop.at(Float(k / 2) * loop.length / Float(partsPerLoop) + 0.45 * t * (k % 2 == 0 ? 1 : -1))
        return placed(p, facing: heading)
    }

    /// Arms between the two loops swing from one to the other; the ones along the front reach over the near loop.
    static let armBases: [SIMD3<Float>] = [5, 8, 11, 14, 17].map { SIMD3($0, 0, -11) } + [5, 8, 11, 14, 17].map { SIMD3($0, 0, -3.9) }
    static func arm(_ k: Int, _ t: Float) -> float4x4 {
        let base = armBases[k % armBases.count], phase = 1.7 * Float(k)
        let a = base.z < -10 ? 0.5 * Float.pi * sin(0.6 * t + phase) : -0.5 * Float.pi + 0.6 * sin(0.8 * t + phase)
        return placed(base, facing: [cos(a), 0, sin(a)])
    }

    /// Machines along the back and the side wall, facing the floor.
    static let machineSlots: [(position: SIMD3<Float>, facing: SIMD3<Float>)] =
        (0..<6).map { (SIMD3(4.2 + 2.6 * Float($0), 0, -19), SIMD3<Float>(0, 0, 1)) }
        + (0..<5).map { (SIMD3(19, 0, -16.5 + 3 * Float($0)), SIMD3<Float>(-1, 0, 0)) }

    /// Gantry hoists run along rails under the roof.
    static let railZ: [Float] = [-14.5, -11, -7.5]
    static let railY: Float = 7.15
    static func trolley(_ k: Int, _ t: Float) -> float4x4 {
        let z = railZ[k % railZ.count], phase = 2.1 * Float(k)
        return placed([11 + 7 * sin(0.22 * t + phase), 0, z], facing: [1, 0, 0])
    }

    // MARK: Garage

    static let garageLevels: [Float] = [0, deck]
    /// Bays: two rows on each level, cars nose in or out, 15 cm clear of the cars driving past and of the walls.
    static let parkingBays: [(position: SIMD3<Float>, facing: SIMD3<Float>)] = {
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (i, y) in garageLevels.enumerated() {
            for x: Float in [-14.7, -4.3] {
                for b in 0..<7 {
                    let z = 3.75 + 2.5 * Float(b)
                    out.append(([x, y, z], [(b + i) % 3 == 0 ? -1 : 1, 0, 0]))
                }
            }
        }
        return out
    }()
    /// Four cars drive round each level's aisle, evenly spaced.
    static let carCount = 8
    static func car(_ k: Int, _ t: Float) -> float4x4 {
        let loop = Loop(center: [-9.5, 11], half: [2, 7.5], radius: 2, y: garageLevels[k % 2])
        let (p, heading) = loop.at(Float(k / 2) * loop.length / 4 + (k % 2 == 0 ? 2.6 : 2.2) * t)
        return placed(p, facing: heading)
    }

    // MARK: Office

    /// Islands of four desks in three columns and four rows; slot i: island i / 4, desk i % 4.
    static let deskCount = 48
    static func deskSlot(_ i: Int) -> (position: SIMD3<Float>, facing: SIMD3<Float>) {
        let island = i / 4, d = i % 4
        let cx: Float = [4.4, 8.6, 12.8][island % 3], cz: Float = [4.8, 9.2, 13.6, 18.0][island / 3]
        let side: Float = d < 2 ? 1 : -1
        return ([cx + (d % 2 == 0 ? -0.7 : 0.7), 0, cz + 0.35 * side], [side, 0, 0])
    }
    /// A chair at its desk, turning and rolling a little.
    static func chair(_ i: Int, phase: Float, _ t: Float) -> float4x4 {
        let (p, facing) = deskSlot(i)
        let a: Float = (facing.x > 0 ? 0 : .pi) + 0.5 * sin(0.7 * t + phase)
        let away = SIMD3<Float>(0, 0, facing.x) * (0.75 + 0.12 * sin(0.4 * t + 2 * phase))
        return placed(p + away, facing: [cos(a), 0, sin(a)])
    }
    /// The walkways between the desk rows, the corridor along the meeting rooms and the cross aisle.
    static let personLanes: [(SIMD3<Float>, SIMD3<Float>)] = [7.35, 11.75, 16.15].map { ([3.0, 0, $0], [14.0, 0, $0]) }
        + [([14.9, 0, 2.8], [14.9, 0, 19.4]), ([-18, 0, 0.6], [18, 0, 0.6]), ([18, 0, -0.6], [-18, 0, -0.6])]
    static let robotLanes: [(SIMD3<Float>, SIMD3<Float>)] = [6.65, 11.05, 15.45].map { ([13.8, 0, $0], [3.2, 0, $0]) }
    static func walker(_ lane: (SIMD3<Float>, SIMD3<Float>), speed: Float, phase: Float, _ t: Float) -> float4x4 {
        shuttle(lane.0, lane.1, speed: speed, phase: phase, turns: true, t)
    }
}

// MARK: - Props

/// The props' meshes, each in its own frame: on the floor at the origin, facing +x.
private enum Props {
    typealias Parts = [(GPUMaterial, MeshBuilder)]

    static func matte(_ c: SIMD3<Float>) -> GPUMaterial {
        GPUMaterial(albedo: SIMD4(c, 0), emission: SIMD4(.zero, 1), params: SIMD4(0, 1, 0, 0))
    }
    static func shiny(_ c: SIMD3<Float>, metallic: Float = 0, roughness: Float) -> GPUMaterial {
        GPUMaterial(albedo: SIMD4(c, metallic), emission: SIMD4(.zero, roughness), params: SIMD4(1, 1, 0, 0))
    }
    /// A wheel along z at `c`, capped on its outer side.
    static func wheel(_ b: inout MeshBuilder, _ c: SIMD3<Float>, radius: Float, width: Float) {
        let out: Float = c.z < 0 ? -1 : 1
        b.frame = translate(c - [0, 0, out * width / 2]) * rotate(out * .pi / 2, [1, 0, 0])
        b.cylinder([0, 0, 0], radius: radius, height: width, segments: 12)
        b.frame = matrix_identity_float4x4
    }

    static func forklift() -> Parts {
        var body = MeshBuilder(), dark = MeshBuilder(), tyres = MeshBuilder(), load = MeshBuilder(), pallet = MeshBuilder()
        body.box([-1.0, 0.25, -0.55], [0.55, 1.05, 0.55])
        body.box([-1.25, 0.25, -0.5], [-1.0, 1.15, 0.5])                    // counterweight
        dark.box([-0.75, 1.05, -0.25], [-0.25, 1.5, 0.25])                  // seat
        for x: Float in [-0.95, 0.4] {
            for z: Float in [-0.5, 0.5] { dark.box([x - 0.03, 1.05, z - 0.03], [x + 0.03, 2.1, z + 0.03]) }
        }
        dark.box([-0.98, 2.1, -0.53], [0.43, 2.15, 0.53])                   // guard
        for z: Float in [-0.35, 0.35] { dark.box([0.58, 0.05, z - 0.05], [0.68, 2.5, z + 0.05]) }   // mast
        for z: Float in [-0.3, 0.3] { dark.box([0.68, 0.1, z - 0.06], [1.8, 0.15, z + 0.06]) }      // forks
        for x: Float in [-0.75, 0.35] {
            for z: Float in [-0.47, 0.47] { wheel(&tyres, [x, 0.27, z], radius: 0.27, width: 0.2) }
        }
        pallet.box([0.75, 0.15, -0.6], [1.75, 0.29, 0.6])
        load.box([0.8, 0.29, -0.55], [1.7, 1.1, 0.55])
        return [(matte([0.85, 0.6, 0.05]), body), (shiny([0.12, 0.12, 0.13], metallic: 1, roughness: 0.5), dark),
                (matte([0.04, 0.04, 0.04]), tyres), (matte([0.55, 0.42, 0.26]), pallet), (matte([0.66, 0.5, 0.32]), load)]
    }

    static func agv() -> Parts {
        var body = MeshBuilder(), stripe = MeshBuilder(), load = MeshBuilder()
        body.box([-0.6, 0.05, -0.4], [0.6, 0.3, 0.4])
        stripe.box([-0.61, 0.18, -0.41], [0.61, 0.24, 0.41], faces: .sides)
        stripe.box([-0.47, 0.3, -0.02], [-0.43, 1.28, 0.02])                // the beacon's post
        load.box([-0.3, 0.3, -0.3], [0.45, 0.85, 0.3])
        return [(shiny([0.6, 0.62, 0.65], roughness: 0.4), body), (matte([0.9, 0.4, 0.05]), stripe), (matte([0.62, 0.46, 0.3]), load)]
    }

    static func person(shirt: SIMD3<Float>, trousers: SIMD3<Float>) -> Parts {
        var legs = MeshBuilder(), torso = MeshBuilder(), head = MeshBuilder()
        for z: Float in [-0.1, 0.1] { legs.cylinder([0, 0, z], radius: 0.08, height: 0.85, segments: 8) }
        torso.cylinder([0, 0.85, 0], radius: 0.19, topRadius: 0.22, height: 0.6, segments: 10)
        for z: Float in [-0.26, 0.26] { torso.cylinder([0, 0.82, z], radius: 0.05, height: 0.6, segments: 6) }
        head.ball([0, 1.6, 0], radius: [0.1, 0.12, 0.1], subdivisions: 1)
        return [(matte(trousers), legs), (matte(shirt), torso), (matte([0.6, 0.45, 0.35]), head)]
    }

    /// The tip of the arm's gripper (the weld light's place).
    static let armTip: SIMD3<Float> = [1.47, 1.0, 0]
    static func robotArm() -> Parts {
        var base = MeshBuilder(), arm = MeshBuilder(), tool = MeshBuilder()
        base.cylinder([0, 0, 0], radius: 0.35, height: 0.4, segments: 16)
        arm.cylinder([0, 0.4, 0], radius: 0.16, height: 0.7, segments: 12)
        arm.box([-0.2, 1.05, -0.17], [0.25, 1.35, 0.17])
        arm.box([0.1, 1.3, -0.1], [1.45, 1.45, 0.1])
        arm.box([1.38, 1.15, -0.08], [1.56, 1.45, 0.08])
        tool.box([1.42, 1.08, -0.1], [1.52, 1.15, 0.1])
        return [(matte([0.25, 0.25, 0.27]), base), (matte([0.95, 0.5, 0.05]), arm), (shiny([0.7, 0.7, 0.72], metallic: 1, roughness: 0.3), tool)]
    }

    static func machine() -> Parts {
        var body = MeshBuilder(), window = MeshBuilder(), panel = MeshBuilder(), lamp = MeshBuilder()
        body.box([-0.8, 0, -1.0], [0.8, 1.9, 1.0])
        body.box([-0.8, 1.9, -0.6], [0.2, 2.3, 0.6])
        window.box([0.8, 0.8, -0.6], [0.82, 1.6, 0.4])
        panel.box([0.8, 0.9, 0.55], [0.95, 1.6, 0.9])
        lamp.cylinder([-0.5, 2.3, 0.8], radius: 0.05, height: 0.35, segments: 8)
        return [(matte([0.35, 0.45, 0.4]), body), (shiny([0.05, 0.06, 0.07], roughness: 0.05), window),
                (matte([0.15, 0.15, 0.16]), panel), (matte([0.8, 0.2, 0.1]), lamp)]
    }

    /// A hoist's trolley on its rail, the cable and a crate hanging from it.
    static func trolley() -> Parts {
        var trolley = MeshBuilder(), cable = MeshBuilder(), crate = MeshBuilder()
        let y = Hall.railY
        trolley.box([-0.4, y - 0.3, -0.5], [0.4, y, 0.5])
        cable.box([-0.02, 5.6, -0.02], [0.02, y - 0.3, 0.02])
        cable.box([-0.12, 5.55, -0.08], [0.12, 5.75, 0.08])
        crate.box([-0.5, 4.9, -0.4], [0.5, 5.55, 0.4])
        return [(matte([0.85, 0.65, 0.05]), trolley), (shiny([0.2, 0.2, 0.22], metallic: 1, roughness: 0.4), cable), (matte([0.4, 0.3, 0.18]), crate)]
    }

    static func car(paint: SIMD3<Float>) -> Parts {
        var body = MeshBuilder(), glass = MeshBuilder(), tyres = MeshBuilder(), trim = MeshBuilder()
        body.box([-2.15, 0.3, -0.9], [2.15, 0.95, 0.9])
        body.box([-1.15, 1.38, -0.7], [0.65, 1.42, 0.7])
        glass.quad([0.65, 1.38, -0.7], [0.65, 1.38, 0.7], [1.15, 0.95, 0.8], [1.15, 0.95, -0.8])      // windscreen
        glass.quad([-1.15, 1.38, 0.7], [-1.15, 1.38, -0.7], [-1.55, 0.95, -0.8], [-1.55, 0.95, 0.8])  // rear window
        for z: Float in [-1, 1] {   // side windows, leaning in
            let a: SIMD3<Float> = [-1.55, 0.95, 0.8 * z], b: SIMD3<Float> = [1.15, 0.95, 0.8 * z]
            let c: SIMD3<Float> = [0.65, 1.38, 0.7 * z], d: SIMD3<Float> = [-1.15, 1.38, 0.7 * z]
            if z > 0 { glass.quad(a, b, c, d) } else { glass.quad(b, a, d, c) }
        }
        trim.box([2.15, 0.35, -0.85], [2.18, 0.55, 0.85])
        trim.box([-2.18, 0.35, -0.85], [-2.15, 0.55, 0.85])
        for x: Float in [-1.4, 1.35] {
            for z: Float in [-0.8, 0.8] { wheel(&tyres, [x, 0.33, z], radius: 0.33, width: 0.22) }
        }
        return [(shiny(paint, metallic: 0.6, roughness: 0.3), body), (shiny([0.42, 0.5, 0.56], roughness: 0.08), glass),
                (matte([0.03, 0.03, 0.03]), tyres), (shiny([0.5, 0.5, 0.52], metallic: 1, roughness: 0.3), trim)]
    }

    /// A desk, its user at +z, the monitor at the back.
    static func desk() -> Parts {
        var top = MeshBuilder(), legs = MeshBuilder(), screen = MeshBuilder(), keys = MeshBuilder()
        top.box([-0.69, 0.72, -0.34], [0.69, 0.75, 0.34])
        for x: Float in [-0.66, 0.62] { legs.box([x, 0, -0.32], [x + 0.04, 0.72, 0.32]) }
        legs.box([-0.62, 0.3, -0.34], [0.62, 0.7, -0.32])
        legs.box([-0.04, 0.75, -0.24], [0.04, 0.95, -0.2])
        screen.box([-0.3, 0.92, -0.25], [0.3, 1.27, -0.22])
        keys.box([-0.22, 0.75, 0.0], [0.22, 0.77, 0.15])
        return [(matte([0.82, 0.8, 0.76]), top), (shiny([0.3, 0.3, 0.32], metallic: 1, roughness: 0.4), legs),
                (shiny([0.03, 0.03, 0.035], roughness: 0.1), screen), (matte([0.1, 0.1, 0.11]), keys)]
    }

    /// An office chair, its back toward +z (away from the desk, as a desk's user sits).
    static func chair() -> Parts {
        var seat = MeshBuilder(), frame = MeshBuilder()
        seat.box([-0.25, 0.45, -0.25], [0.25, 0.52, 0.25])
        seat.box([-0.24, 0.55, 0.22], [0.24, 1.0, 0.27])
        frame.cylinder([0, 0.08, 0], radius: 0.03, height: 0.37, segments: 6)
        for k in 0..<5 {
            frame.frame = rotate(2 * .pi * Float(k) / 5, [0, 1, 0])
            frame.box([0, 0.04, -0.02], [0.3, 0.08, 0.02])
        }
        frame.frame = matrix_identity_float4x4
        return [(matte([0.12, 0.13, 0.15]), seat), (shiny([0.4, 0.4, 0.42], metallic: 1, roughness: 0.35), frame)]
    }

    /// A delivery robot: a drum with a lid and a beacon's post.
    static func robot() -> Parts {
        var body = MeshBuilder(), lid = MeshBuilder()
        body.cylinder([0, 0.05, 0], radius: 0.3, height: 0.55, segments: 16)
        lid.cylinder([0, 0.6, 0], radius: 0.28, topRadius: 0.2, height: 0.12, segments: 16)
        lid.box([-0.02, 0.72, -0.02], [0.02, 0.9, 0.02])
        return [(shiny([0.85, 0.86, 0.88], roughness: 0.3), body), (matte([0.15, 0.2, 0.3]), lid)]
    }

    /// A quadcopter, about 45 cm across.
    static func drone() -> Parts {
        var body = MeshBuilder(), rotors = MeshBuilder()
        body.box([-0.09, -0.035, -0.09], [0.09, 0.035, 0.09])
        for k in 0..<2 {
            body.frame = rotate(.pi / 4 + .pi / 2 * Float(k), [0, 1, 0])
            body.box([-0.22, -0.012, -0.015], [0.22, 0.012, 0.015])
        }
        body.frame = matrix_identity_float4x4
        for (x, z) in [(Float(0.155), Float(0.155)), (-0.155, 0.155), (0.155, -0.155), (-0.155, -0.155)] {
            rotors.cylinder([x, 0.015, z], radius: 0.08, height: 0.008, segments: 10)
        }
        return [(matte([0.1, 0.1, 0.11]), body), (matte([0.5, 0.5, 0.52]), rotors)]
    }
}
