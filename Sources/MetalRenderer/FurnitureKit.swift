import Foundation
import simd

/// The furniture and the things on it, made of boxes and cylinders like the buildings: each piece in its own frame,
/// x along the wall it stands against (from 0 to its width), z out from that wall into the room (0 to its depth), y up
/// from the floor. A piece names what each of its parts is made of by a role (`Role`), which a building's palette
/// turns into a material (BuildingFurnish.swift), so the same piece is oak in one flat and walnut in the next.
struct FurnitureItem {
    enum Role: Int, CaseIterable {
        case wood, woodDark, fabric, cushion, linen, metal, chrome, ceramic, dark, screen, stone
        case book0, book1, book2, book3, leaf, pot, soil, carton, glass, shade, paper, rug
    }
    enum Kind: String, CaseIterable, Codable {
        case bed, single, nightstand, wardrobe, sofa, armchair, coffeeTable, tvUnit, rug, diningTable, chair, kitchen, fridge
        case bath, shower, wc, basin, desk, officeChair, bookcase, plant, tallPlant, frame, boxes, deskCluster, meetingTable
        case cubicle, counter, rack, pallet, bench, reception, coatRack
    }

    var kind: Kind
    var size: SIMD3<Float>
    private(set) var boxes: [(role: Role, lo: SIMD3<Float>, hi: SIMD3<Float>, faces: MeshBuilder.Faces)] = []
    private(set) var cylinders: [(role: Role, base: SIMD3<Float>, radius: Float, top: Float?, height: Float, segments: Int)] = []
    private(set) var triangles: [(role: Role, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)] = []
    /// What the walker meets of it (its own frame), if not its bounds: a table's top it can't walk through, its legs.
    var colliders: [(lo: SIMD3<Float>, hi: SIMD3<Float>)]?
    /// It can be pushed and knocked over (a chair, a box): a body of its own (Interior.Prop).
    var pushable = false
    var mass: Float = 5

    init(_ kind: Kind, _ size: SIMD3<Float>) {
        self.kind = kind
        self.size = size
    }

    mutating func box(_ role: Role, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ faces: MeshBuilder.Faces = .all) {
        guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return }
        boxes.append((role, lo, hi, faces))
    }
    /// A box standing on the floor (its bottom face is left out: it would lie on the floor's).
    mutating func block(_ role: Role, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
        box(role, lo, hi, lo.y <= 0.001 ? [.left, .right, .back, .front, .top] : .all)
    }
    mutating func cylinder(_ role: Role, _ base: SIMD3<Float>, radius: Float, top: Float? = nil, height: Float, segments: Int = 10) {
        cylinders.append((role, base, radius, top, height, segments))
    }
    mutating func triangle(_ role: Role, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        triangles.append((role, a, b, c))
    }
    /// Four legs under a top at `height`, `t` thick, inset `inset` from its corners.
    mutating func legs(_ role: Role, width: Float, depth: Float, height: Float, t: Float = 0.045, inset: Float = 0.04) {
        for (x, z) in [(inset, inset), (width - inset - t, inset), (inset, depth - inset - t), (width - inset - t, depth - inset - t)] {
            block(role, [x, 0, z], [x + t, height, z + t])
        }
    }

    // MARK: - The pieces

    static func make(_ kind: Kind, width w: Float, depth d: Float, rng: inout SplitMix64, clutter: Float) -> FurnitureItem {
        var f = FurnitureItem(kind, [w, 0, d])
        func chance(_ p: Float) -> Bool { rng.next() < p }
        switch kind {
        case .bed, .single:
            // Frame, mattress, duvet, pillows, a headboard against the wall.
            f.size.y = 1.0
            f.block(.wood, [0, 0, 0.05], [w, 0.32, d])
            f.box(.linen, [0.03, 0.32, 0.08], [w - 0.03, 0.52, d - 0.03], [.left, .right, .front, .back, .top])
            f.box(.fabric, [0.02, 0.5, 0.65], [w - 0.02, 0.58, d - 0.01], [.left, .right, .front, .back, .top])
            f.block(.wood, [0, 0, 0], [w, 1.0, 0.05])
            let pillows = kind == .bed ? 2 : 1
            for k in 0..<pillows {
                let x0 = 0.08 + Float(k) * (w - 0.16) / Float(pillows), x1 = x0 + (w - 0.16) / Float(pillows) - 0.06
                f.box(.linen, [x0, 0.52, 0.12], [x1, 0.66, 0.55], [.left, .right, .front, .back, .top])
            }
            f.colliders = [([0, 0, 0], [w, 0.58, d]), ([0, 0, 0], [w, 1.0, 0.05])]
        case .nightstand:
            f.size.y = 0.55
            f.block(.wood, [0, 0, 0], [w, 0.5, d])
            f.box(.woodDark, [0.04, 0.3, d], [w - 0.04, 0.32, d + 0.01], [.front, .top, .bottom])
            // A lamp: a base and a shade.
            f.cylinder(.ceramic, [w / 2, 0.5, d / 2], radius: 0.06, height: 0.18)
            f.cylinder(.shade, [w / 2, 0.66, d / 2], radius: 0.13, top: 0.09, height: 0.18, segments: 12)
            if chance(clutter) { f.box(Role(rawValue: Role.book0.rawValue + rng.int(4))!, [0.05, 0.5, 0.05], [0.2, 0.53, 0.26]) }
        case .wardrobe:
            f.size.y = 2.05
            f.block(.wood, [0, 0, 0], [w, 2.05, d])
            let doors = max(2, Int(w / 0.5))
            for k in 1..<doors {
                let x = w * Float(k) / Float(doors)
                f.box(.woodDark, [x - 0.006, 0.05, d], [x + 0.006, 2.0, d + 0.008], [.front, .left, .right])
            }
            for k in 0..<doors {
                let x = w * (Float(k) + 0.5) / Float(doors) + (k % 2 == 0 ? 0.18 : -0.18) * w / Float(doors)
                f.box(.chrome, [x - 0.01, 1.0, d], [x + 0.01, 1.25, d + 0.025], [.front, .left, .right, .top, .bottom])
            }
        case .sofa, .armchair:
            f.size.y = 0.82
            let arm: Float = 0.16
            f.block(.fabric, [0, 0, 0], [w, 0.82, 0.22])                                   // the back
            f.block(.fabric, [0, 0, 0.22], [arm, 0.6, d])                                   // the arms
            f.block(.fabric, [w - arm, 0, 0.22], [w, 0.6, d])
            f.block(.fabric, [arm, 0, 0.22], [w - arm, 0.24, d])                            // the base
            let seats = kind == .sofa ? max(2, Int((w - 2 * arm) / 0.65)) : 1
            for k in 0..<seats {
                let x0 = arm + Float(k) * (w - 2 * arm) / Float(seats), x1 = arm + Float(k + 1) * (w - 2 * arm) / Float(seats)
                f.box(.cushion, [x0 + 0.01, 0.24, 0.24], [x1 - 0.01, 0.42, d - 0.02], [.left, .right, .front, .top])
            }
            if kind == .armchair { f.pushable = true; f.mass = 18 }
        case .coffeeTable:
            f.size.y = 0.42
            f.box(.wood, [0, 0.38, 0], [w, 0.42, d])
            f.legs(.wood, width: w, depth: d, height: 0.38)
            if chance(clutter) { f.box(Role(rawValue: Role.book0.rawValue + rng.int(4))!, [w * 0.2, 0.42, d * 0.3], [w * 0.2 + 0.24, 0.45, d * 0.3 + 0.17]) }
            if chance(clutter) { f.cylinder(.ceramic, [w * 0.7, 0.42, d * 0.5], radius: 0.045, height: 0.09) }
            f.colliders = [([0, 0, 0], [w, 0.42, d])]
        case .tvUnit:
            f.size.y = 1.2
            f.block(.woodDark, [0, 0, 0], [w, 0.48, d])
            let tv = min(w - 0.2, 1.3)
            f.box(.screen, [(w - tv) / 2, 0.55, d * 0.4], [(w + tv) / 2, 0.55 + tv * 0.56, d * 0.4 + 0.04])
            f.box(.dark, [w / 2 - 0.15, 0.48, d * 0.3], [w / 2 + 0.15, 0.55, d * 0.55], [.left, .right, .front, .back, .top])
        case .rug:
            f.size.y = 0.012
            f.box(.rug, [0, 0.002, 0], [w, 0.012, d], [.left, .right, .front, .back, .top])
            f.colliders = []
        case .diningTable, .meetingTable:
            f.size.y = 0.76
            f.box(.wood, [0, 0.72, 0], [w, 0.76, d])
            f.legs(.wood, width: w, depth: d, height: 0.72, t: 0.06)
            if kind == .diningTable {
                for k in 0..<Int(Float(Int(w / 0.6)) * clutter + 0.5) {
                    let x = 0.3 + Float(k) * 0.6
                    guard x < w - 0.2 else { break }
                    f.cylinder(.ceramic, [x, 0.76, 0.22], radius: 0.12, height: 0.015, segments: 14)
                    if chance(0.6) { f.cylinder(.glass, [x + 0.15, 0.76, 0.12], radius: 0.035, height: 0.12, segments: 8) }
                }
            }
            f.colliders = [([0, 0, 0], [w, 0.76, d])]
        case .chair:
            f.size.y = 0.9
            f.box(.wood, [0, 0.43, 0.02], [w, 0.47, d])
            f.legs(.wood, width: w, depth: d, height: 0.43, t: 0.035, inset: 0.02)
            f.box(.wood, [0.02, 0.47, 0.02], [w - 0.02, 0.9, 0.06])
            f.pushable = true
            f.mass = 4
        case .officeChair:
            f.size.y = 1.0
            f.cylinder(.chrome, [w / 2, 0, d / 2], radius: 0.28, top: 0.05, height: 0.08, segments: 5)
            f.cylinder(.chrome, [w / 2, 0.08, d / 2], radius: 0.025, height: 0.36, segments: 6)
            f.box(.fabric, [0.04, 0.44, 0.04], [w - 0.04, 0.52, d - 0.04])
            f.box(.fabric, [0.06, 0.55, 0.02], [w - 0.06, 1.0, 0.1])
            f.pushable = true
            f.mass = 9
        case .kitchen:
            // Base cabinets with a worktop, a sink and a hob in it; wall cabinets above.
            f.size.y = 2.2
            f.block(.wood, [0, 0, 0], [w, 0.86, d - 0.02])
            f.box(.stone, [0, 0.86, 0], [w, 0.9, d])
            let doors = max(1, Int(w / 0.6))
            for k in 1..<max(doors, 1) {
                let x = w * Float(k) / Float(doors)
                f.box(.woodDark, [x - 0.004, 0.1, d - 0.02], [x + 0.004, 0.84, d - 0.012], [.front])
            }
            let sink = min(0.8, w * 0.3)
            f.box(.chrome, [w * 0.25, 0.9, 0.12], [w * 0.25 + sink, 0.905, d - 0.08], [.top])
            f.cylinder(.chrome, [w * 0.25 + sink / 2, 0.9, 0.08], radius: 0.015, height: 0.3, segments: 6)
            if w > 1.6 { f.box(.dark, [w - 0.75, 0.9, 0.08], [w - 0.15, 0.905, d - 0.08], [.top]) }
            f.box(.wood, [0, 1.45, 0], [w, 2.15, 0.34])
            f.colliders = [([0, 0, 0], [w, 0.9, d]), ([0, 1.45, 0], [w, 2.15, 0.34])]
        case .fridge:
            f.size.y = 1.85
            f.block(.ceramic, [0, 0, 0], [w, 1.85, d])
            f.box(.chrome, [w - 0.08, 0.9, d], [w - 0.05, 1.5, d + 0.03], [.front, .left, .right, .top, .bottom])
        case .bath:
            f.size.y = 0.55
            f.block(.ceramic, [0, 0, 0], [w, 0.55, 0.08])
            f.block(.ceramic, [0, 0, d - 0.08], [w, 0.55, d])
            f.block(.ceramic, [0, 0, 0.08], [0.08, 0.55, d - 0.08])
            f.block(.ceramic, [w - 0.08, 0, 0.08], [w, 0.55, d - 0.08])
            f.block(.ceramic, [0.08, 0, 0.08], [w - 0.08, 0.12, d - 0.08])
            f.colliders = [([0, 0, 0], [w, 0.55, d])]
        case .shower:
            f.size.y = 2.0
            f.block(.ceramic, [0, 0, 0], [w, 0.06, d])
            f.box(.glass, [0, 0.06, d - 0.01], [w * 0.7, 2.0, d], [.front, .back])
            f.cylinder(.chrome, [w / 2, 1.9, 0.12], radius: 0.08, height: 0.02, segments: 10)
            f.colliders = [([0, 0, d - 0.02], [w * 0.7, 2.0, d])]
        case .wc:
            f.size.y = 0.8
            f.block(.ceramic, [0.04, 0, 0], [w - 0.04, 0.8, 0.18])                        // the cistern
            f.block(.ceramic, [0.07, 0, 0.18], [w - 0.07, 0.4, d])                         // the bowl
            f.box(.ceramic, [0.05, 0.4, 0.2], [w - 0.05, 0.43, d + 0.02])                  // the seat
        case .basin:
            f.size.y = 1.9
            f.block(.ceramic, [w / 2 - 0.07, 0, 0], [w / 2 + 0.07, 0.7, 0.2])
            f.box(.ceramic, [0, 0.7, 0], [w, 0.86, d])
            f.cylinder(.chrome, [w / 2, 0.86, 0.06], radius: 0.015, height: 0.18, segments: 6)
            f.box(.glass, [0.05, 1.15, 0.01], [w - 0.05, 1.85, 0.02], [.front])           // the mirror
            f.colliders = [([0, 0, 0], [w, 0.86, d])]
        case .desk:
            f.size.y = 0.76
            f.box(.wood, [0, 0.72, 0], [w, 0.76, d])
            f.block(.woodDark, [0, 0, 0.05], [0.04, 0.72, d - 0.05])
            f.block(.woodDark, [w - 0.04, 0, 0.05], [w, 0.72, d - 0.05])
            f.box(.screen, [w / 2 - 0.27, 0.86, 0.12], [w / 2 + 0.27, 1.2, 0.15])
            f.box(.dark, [w / 2 - 0.03, 0.76, 0.13], [w / 2 + 0.03, 0.86, 0.17], [.left, .right, .front, .back])
            f.box(.dark, [w / 2 - 0.2, 0.76, d - 0.3], [w / 2 + 0.2, 0.775, d - 0.15], [.left, .right, .front, .back, .top])
            if chance(clutter) { f.cylinder(.ceramic, [w - 0.2, 0.76, d - 0.25], radius: 0.04, height: 0.1, segments: 8) }
            if chance(clutter) { f.box(.paper, [0.12, 0.76, d - 0.4], [0.42, 0.79, d - 0.18]) }
            f.colliders = [([0, 0, 0], [w, 0.76, d])]
        case .bookcase:
            f.size.y = 1.9
            let t: Float = 0.025, shelves = 5
            f.block(.wood, [0, 0, 0], [t, 1.9, d])
            f.block(.wood, [w - t, 0, 0], [w, 1.9, d])
            f.box(.wood, [t, 0, 0], [w - t, 1.9, 0.015])
            for k in 0...shelves {
                let y = Float(k) * 1.86 / Float(shelves)
                f.box(.wood, [t, y, 0.015], [w - t, y + t, d])
                // Books on each shelf but the top: a row of spines of their own heights, some leaning gaps.
                guard k < shelves else { continue }
                var x = t + 0.01
                while x < w - t - 0.05 {
                    let bw = 0.018 + rng.next() * 0.03, bh = min(0.18 + rng.next() * 0.14, 1.86 / Float(shelves) - 0.04)
                    if rng.next() < clutter {
                        f.box(Role(rawValue: Role.book0.rawValue + rng.int(4))!, [x, y + t, 0.03], [x + bw, y + t + bh, d - 0.03 - rng.next() * 0.04],
                              [.left, .right, .front, .top])
                    }
                    x += bw + (rng.next() < 0.1 ? 0.06 : 0.002)
                }
            }
        case .plant, .tallPlant:
            // A pot, its soil, and leaves fanning out of it (each a pair of thin triangles, bent at its middle).
            let tall = kind == .tallPlant
            let r: Float = tall ? 0.2 : 0.14, h: Float = tall ? 0.38 : 0.24
            f.size.y = tall ? 1.6 : 0.7
            f.cylinder(.pot, [w / 2, 0, d / 2], radius: r * 0.8, top: r, height: h, segments: 12)
            f.cylinder(.soil, [w / 2, h - 0.03, d / 2], radius: r * 0.93, height: 0.02, segments: 12)
            let leaves = tall ? 34 : 16
            for k in 0..<leaves {
                let a = Float(k) * 2.4 + rng.next() * 0.5, up = tall ? 0.2 + rng.next() * 1.2 : 0.05 + rng.next() * 0.1
                let len: Float = tall ? 0.22 + rng.next() * 0.15 : 0.28 + rng.next() * 0.18
                let dir = SIMD3(cos(a), 0, sin(a))
                let root = SIMD3(w / 2, h + up, d / 2) + dir * (tall ? 0.04 : 0.02)
                let mid = root + dir * len * 0.55 + SIMD3(0, tall ? 0.04 : 0.12, 0)
                let tip = root + dir * len + SIMD3(0, tall ? -0.08 : 0.02, 0)
                let side = SIMD3(-dir.z, 0, dir.x) * (tall ? 0.05 : 0.035)
                f.triangle(.leaf, root, mid + side, mid - side)
                f.triangle(.leaf, mid + side, tip, mid - side)
            }
            if tall { f.cylinder(.woodDark, [w / 2, h, d / 2], radius: 0.015, height: 1.35, segments: 5) }
            f.colliders = [([w / 2 - r, 0, d / 2 - r], [w / 2 + r, h, d / 2 + r])]
        case .frame:
            // A picture on the wall at eye height (`d`: its frame's depth).
            f.size.y = 1.9
            let ph = 0.4 + rng.next() * 0.3
            f.box(.woodDark, [0, 1.45 - ph / 2, 0], [w, 1.45 + ph / 2, 0.03], [.left, .right, .front, .top, .bottom])
            f.box(Role(rawValue: Role.book0.rawValue + rng.int(4))!, [0.04, 1.45 - ph / 2 + 0.04, 0.03], [w - 0.04, 1.45 + ph / 2 - 0.04, 0.032], [.front])
            f.colliders = []
        case .boxes:
            // A stack of cartons; the top ones loose.
            f.size.y = 1.0
            var y: Float = 0
            for k in 0..<(1 + rng.int(3)) {
                let s = 0.35 + rng.next() * 0.2
                f.block(.carton, [w / 2 - s / 2 + Float(k % 2) * 0.03, y, d / 2 - s / 2], [w / 2 + s / 2, y + s * 0.8, d / 2 + s / 2])
                y += s * 0.8
            }
            f.size.y = y
            f.pushable = true
            f.mass = 6
        case .deskCluster:
            // Four desks facing each other in pairs, a screen on each.
            f.size.y = 1.2
            for (x0, z0, back) in [(Float(0), Float(0), true), (w / 2, 0, true), (0, d / 2, false), (w / 2, d / 2, false)] {
                let x1 = x0 + w / 2, z1 = z0 + d / 2
                f.box(.wood, [x0 + 0.01, 0.72, z0 + 0.01], [x1 - 0.01, 0.75, z1 - 0.01])
                f.block(.metal, [x0 + 0.03, 0, z0 + 0.03], [x0 + 0.06, 0.72, z1 - 0.03])
                f.block(.metal, [x1 - 0.06, 0, z0 + 0.03], [x1 - 0.03, 0.72, z1 - 0.03])
                let zs: Float = back ? z1 - 0.1 : z0 + 0.06
                f.box(.screen, [(x0 + x1) / 2 - 0.27, 0.85, zs], [(x0 + x1) / 2 + 0.27, 1.17, zs + 0.03])
                f.box(.dark, [(x0 + x1) / 2 - 0.03, 0.75, zs - 0.02], [(x0 + x1) / 2 + 0.03, 0.85, zs + 0.05], [.left, .right, .front, .back])
            }
            f.box(.glass, [0.02, 0.75, d / 2 - 0.005], [w - 0.02, 1.25, d / 2 + 0.005], [.front, .back])
            f.colliders = [([0, 0, 0], [w, 0.76, d])]
        case .cubicle:
            // A WC in a cubicle: two side panels and a door panel, a gap under them.
            f.size.y = 2.0
            f.box(.metal, [0, 0.15, 0], [0.03, 2.0, d])
            f.box(.metal, [w - 0.03, 0.15, 0], [w, 2.0, d])
            f.box(.metal, [0.03, 0.15, d - 0.03], [w * 0.35, 2.0, d])
            var wc = FurnitureItem.make(.wc, width: 0.45, depth: 0.68, rng: &rng, clutter: 0)
            wc.shift([w / 2 - 0.225, 0, 0])
            f.append(wc)
            f.colliders = [([0, 0, 0], [0.03, 2, d]), ([w - 0.03, 0, 0], [w, 2, d]), ([0, 0, d - 0.03], [w * 0.35, 2, d])]
        case .counter, .reception:
            f.size.y = 1.1
            f.block(.woodDark, [0, 0, 0.1], [w, 1.0, d])
            f.box(.stone, [0, 1.0, 0.05], [w, 1.06, d + 0.03])
            if kind == .reception { f.box(.screen, [w * 0.6, 1.06, 0.25], [w * 0.6 + 0.5, 1.36, 0.28]) }
        case .rack:
            // A shop's or a warehouse's shelving: posts, shelves, and what is on them.
            let high: Float = d > 0.8 ? 3.2 : 1.9
            f.size.y = high
            for x in stride(from: Float(0), through: w - 0.05, by: max((w - 0.05) / max(1, (w / 1.8).rounded()), 0.6)) {
                f.block(.metal, [x, 0, 0], [x + 0.05, high, 0.05])
                f.block(.metal, [x, 0, d - 0.05], [x + 0.05, high, d])
            }
            let levels = high > 2 ? 4 : 5
            for k in 0..<levels {
                let y = 0.1 + Float(k) * (high - 0.15) / Float(levels)
                f.box(.metal, [0, y, 0], [w, y + 0.03, d])
                var x: Float = 0.05
                while x < w - 0.3 {
                    let s = 0.25 + rng.next() * 0.35
                    if rng.next() < clutter && x + s < w - 0.05 {
                        f.box(high > 2 ? .carton : Role(rawValue: Role.book0.rawValue + rng.int(4))!, [x, y + 0.03, 0.06],
                              [x + s, y + 0.03 + min(s * 0.8, (high - 0.15) / Float(levels) - 0.08), d - 0.06])
                    }
                    x += s + 0.04
                }
            }
            f.colliders = [([0, 0, 0], [w, high, d])]
        case .pallet:
            f.size.y = 1.2
            f.block(.wood, [0, 0, 0], [w, 0.14, d])
            let h = 0.5 + rng.next() * 0.6
            f.box(.carton, [0.04, 0.14, 0.04], [w - 0.04, 0.14 + h, d - 0.04])
            f.size.y = 0.14 + h
        case .bench:
            f.size.y = 0.46
            f.box(.wood, [0, 0.42, 0], [w, 0.46, d])
            f.block(.metal, [0.1, 0, 0.05], [0.14, 0.42, d - 0.05])
            f.block(.metal, [w - 0.14, 0, 0.05], [w - 0.1, 0.42, d - 0.05])
        case .coatRack:
            f.size.y = 1.8
            f.box(.woodDark, [0, 1.55, 0], [w, 1.62, 0.04], [.left, .right, .front, .top, .bottom])
            for k in 0..<3 {
                let x = w * (Float(k) + 0.5) / 3
                f.box(.chrome, [x - 0.01, 1.5, 0.04], [x + 0.01, 1.58, 0.12], [.left, .right, .front, .top, .bottom])
                if rng.next() < clutter { f.box(.fabric, [x - 0.17, 0.8, 0.06], [x + 0.17, 1.52, 0.22], [.left, .right, .front, .back, .top, .bottom]) }
            }
            f.colliders = []
        }
        return f
    }

    /// Moves every part by `d` (its own frame).
    mutating func shift(_ d: SIMD3<Float>) {
        boxes = boxes.map { ($0.role, $0.lo + d, $0.hi + d, $0.faces) }
        cylinders = cylinders.map { ($0.role, $0.base + d, $0.radius, $0.top, $0.height, $0.segments) }
        triangles = triangles.map { ($0.role, $0.a + d, $0.b + d, $0.c + d) }
    }

    /// `other`'s parts added to its own.
    mutating func append(_ other: FurnitureItem) {
        boxes += other.boxes
        cylinders += other.cylinders
        triangles += other.triangles
    }

    /// Its parts into `out`, placed by `frame` (a rotation about y and a translation), each role's material `material`.
    func emit(into out: inout MaterialMeshes, frame: float4x4, material: (Role) -> SurfaceMaterial) {
        // (Each mesh's frame back to the identity after: the storey's other shapes are given in its own frame.)
        for b in boxes {
            let m = material(b.role)
            out[m].frame = frame
            out[m].box(b.lo, b.hi, faces: b.faces)
            out[m].frame = matrix_identity_float4x4
        }
        for c in cylinders {
            let m = material(c.role)
            out[m].frame = frame
            out[m].cylinder(c.base, radius: c.radius, topRadius: c.top, height: c.height, segments: c.segments)
            out[m].frame = matrix_identity_float4x4
        }
        for t in triangles {
            let m = material(t.role)
            out[m].frame = frame
            out[m].triangle(t.a, t.b, t.c)
            out[m].frame = matrix_identity_float4x4
        }
    }

    /// Its colliders (its own frame): the ones it says, or its bounds.
    var collisionBoxes: [(lo: SIMD3<Float>, hi: SIMD3<Float>)] {
        if let colliders { return colliders }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for b in boxes { lo = simd_min(lo, b.lo); hi = simd_max(hi, b.hi) }
        for c in cylinders {
            let r = max(c.radius, c.top ?? 0)
            lo = simd_min(lo, c.base - SIMD3(r, 0, r)); hi = simd_max(hi, c.base + SIMD3(r, c.height, r))
        }
        return lo.x <= hi.x ? [(lo, hi)] : []
    }
}
