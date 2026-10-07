import Foundation
import simd

/// A building's facades: a split grammar. A wall is cut into storeys, each storey into a pier at either end and
/// equal bays between them (the same bays on every storey, so the windows line up), and each bay gets a tile: a
/// window, a window with a balcony, a door, a shop window, a loading door. Everything is made in the facade's own
/// frame: x along the wall from its start, y up, z out of it, the wall's face at z = 0.
///
/// Nothing is laid flat on anything else (coplanar faces show as noise when ray traced): a wall is cut around its
/// openings, what projects is a box without its back, and the members of a frame meet edge to edge.
extension BuildingAssembler {
    /// A bay's rectangle on the wall: one storey high.
    struct Cell {
        var x0: Float, x1: Float, y0: Float, y1: Float
        var width: Float { x1 - x0 }
        var center: Float { (x0 + x1) / 2 }
    }

    /// A rectangular hole in the wall.
    struct Opening {
        var x0: Float, x1: Float, y0: Float, y1: Float
    }

    /// The wall from `a` to `c` of `tier`. `kind`: what it looks onto; `front`: it has the building's door;
    /// `depth`: how deep the building is behind it; `crowdedStart` / `crowdedEnd`: the wall around that corner has
    /// rooms behind it too, so this one keeps its own away from the corner.
    mutating func facade(from a: SIMD2<Float>, to c: SIMD2<Float>, tier: BuildingTier, kind: CityPlan.Edge, front: Bool, depth: Float,
                         crowdedStart: Bool, crowdedEnd: Bool) {
        let span = length(c - a), e = (c - a) / span
        b.setFrame(float4x4(columns: (SIMD4(e.x, 0, e.y, 0), SIMD4(0, 1, 0, 0), SIMD4(-e.y, 0, e.x, 0), SIMD4(a.x, 0, a.y, 1))))
        let top = tier.top
        let pier = min(style.pier, span * 0.15)
        let usable = span - 2 * pier
        guard kind != .party, usable >= 1.6 else {
            b[.wall].wall(x0: 0, x1: span, y0: tier.y0, y1: top)
            return
        }
        let count = max(1, Int((usable / style.bay).rounded()))
        let bay = usable / Float(count)

        // The piers at the ends: the base's material on the ground floor, the wall's above.
        let baseTop = tier.ground ? tier.y0 + tier.heights[0] : tier.y0
        for (x0, x1) in [(Float(0), pier), (span - pier, span)] {
            b[.base].wall(x0: x0, x1: x1, y0: tier.y0, y1: baseTop)
            b[.wall].wall(x0: x0, x1: x1, y0: baseTop, y1: top)
        }

        // Rooms: half the building's depth at most, and none where the next wall's rooms would be.
        let roomDepth = min(style.roomDepth, depth / 2 - 0.4)
        let clear = roomDepth + 0.4
        func roomFits(_ cell: Cell) -> Bool {
            roomDepth >= 2 && cell.x0 >= (crowdedStart ? clear : 0.3) && cell.x1 <= span - (crowdedEnd ? clear : 0.3)
        }

        // What the ground floor is, and which columns of bays have balconies.
        let street = kind == .street
        let shops = tier.ground && street && rng.next() < style.shops
        let door = front ? count / 2 : -1
        let every = style.balconies >= 1 ? 1 : style.balconies >= 0.5 ? 2 : style.balconies > 0 ? 3 : 0
        let phase = every > 0 ? rng.int(every) : 0
        let awnings = shops && style.kind != .office && rng.next() < 0.5
        // An office's storeys are lit, or dark, more or less together.
        let together = style.kind == .office

        var y = tier.y0
        for (storey, height) in tier.heights.enumerated() {
            let ground = tier.ground && storey == 0
            let wallSlot: Building.Slot = ground ? .base : .wall
            let plain = storeysBelow + storey >= plainFrom
            let storeyLit = together ? rng.range(0.2, 1.8) : 1
            let floor = ground ? y + BuildingAssembler.step : y
            if !ground && storeysBelow + storey >= ribbonFrom {
                // Too many windows to make each: one ribbon of glass along the wall, and a blind or a light behind it.
                var ribbon = style.window
                (ribbon.share, ribbon.maxWidth, ribbon.mullions, ribbon.transom) = (1, .infinity, 0, false)
                window(Cell(x0: pier, x1: span - pier, y0: y, y1: y + height), floor: floor, ribbon, wall: wallSlot, plain: true,
                       balcony: false, room: 0, lit: spec.lit * storeyLit)
                y += height
                continue
            }
            for k in 0..<count {
                let cell = Cell(x0: pier + Float(k) * bay, x1: pier + Float(k + 1) * bay, y0: y, y1: y + height)
                if ground && k == door {
                    doorTile(cell, floor: floor, glazed: style.kind == .office)
                } else if ground && style.loadingDoors && street && (k + phase) % 2 == 0 {
                    loadingDoor(cell, floor: floor)
                } else if ground && shops {
                    shopWindow(cell, floor: floor, room: roomFits(cell) ? min(roomDepth + 1.5, depth / 2 - 0.4) : 0, awning: awnings)
                } else {
                    let balcony = !ground && every > 0 && (k + phase) % every == 0 && kind != .party
                    window(cell, floor: floor, ground ? style.groundWindow : style.window, wall: wallSlot, plain: plain, balcony: balcony,
                           room: roomFits(cell) ? roomDepth : 0, lit: spec.lit * storeyLit)
                }
            }
            if ground && shops && style.kind != .office {
                // The shops' sign: a board over their windows, the facade's bays long.
                b[.accent].box([pier, y + height - 0.78, 0], [span - pier, y + height - 0.34, 0.09],
                               faces: [.front, .top, .bottom, .left, .right])
            }
            y += height
        }
    }

    // MARK: - Pieces

    /// Of a detail's faces, those a building at its level has: all of them in full, the front alone when flat.
    private func shown(_ faces: MeshBuilder.Faces) -> MeshBuilder.Faces {
        spec.detail == .full ? faces : faces.intersection(.front)
    }

    /// The wall of `cell` around `o`, and the hole's sides, `thickness` deep.
    private mutating func cutWall(_ cell: Cell, _ o: Opening, slot: Building.Slot, thickness: Float) {
        wallAround(cell, o, slot: slot)
        reveal(o, slot: slot, thickness: thickness)
    }

    /// The wall of `cell` around `o`.
    private mutating func wallAround(_ cell: Cell, _ o: Opening, slot: Building.Slot) {
        b[slot].wall(x0: cell.x0, x1: o.x0, y0: cell.y0, y1: cell.y1)
        b[slot].wall(x0: o.x1, x1: cell.x1, y0: cell.y0, y1: cell.y1)
        b[slot].wall(x0: o.x0, x1: o.x1, y0: cell.y0, y1: o.y0)
        b[slot].wall(x0: o.x0, x1: o.x1, y0: o.y1, y1: cell.y1)
    }

    /// The sides of hole `o`, `thickness` deep.
    private mutating func reveal(_ o: Opening, slot: Building.Slot, thickness: Float) {
        b[slot].box([o.x0, o.y0, -thickness], [o.x1, o.y1, 0], faces: [.left, .right, .top, .bottom])
    }

    /// What `body` adds, as a module of the building (Building.Module) at `anchor` in the facade if its windows are
    /// modules, or in place. (A storey's row of shells as one module traced no faster and shared a quarter as much.)
    private mutating func module(at anchor: SIMD3<Float>, _ body: (inout BuildingAssembler) -> Void) {
        guard spec.modules else { body(&self); return }
        let facade = b[.wall].frame
        let kept = b.beginModule(at: anchor)
        body(&self)
        b.addModule(b.endModule(kept),
                    placement: facade * float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(anchor, 1))))
    }

    /// A frame in opening `o`, with its glass: members `width` wide around it, `mullions` upright bars and maybe a
    /// transom; the glass `recess` behind the wall's face. The uprights run the full height and the others between
    /// them, so no two members' faces overlap.
    private mutating func glaze(_ o: Opening, recess: Float, width f: Float, mullions: Int, transom: Bool, frame: Bool) {
        b[.glass].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: -recess)
        guard frame else { return }
        frameMembers(o, recess: recess, width: f, mullions: mullions, transom: transom)
    }

    /// `glaze`'s frame alone.
    private mutating func frameMembers(_ o: Opening, recess: Float, width f: Float, mullions: Int, transom: Bool) {
        let back = -recess, face = -recess + 0.04
        b[.frame].box([o.x0, o.y0, back], [o.x0 + f, o.y1, face], faces: shown([.front, .right]))
        b[.frame].box([o.x1 - f, o.y0, back], [o.x1, o.y1, face], faces: shown([.front, .left]))
        // The uprights between the two sides, then the top, the bottom and the transom in each gap.
        var edges: [Float] = [o.x0 + f]
        for m in 0..<mullions {
            let x = o.x0 + (o.x1 - o.x0) * Float(m + 1) / Float(mullions + 1)
            b[.frame].box([x - f / 2, o.y0 + f, back], [x + f / 2, o.y1 - f, face], faces: shown([.front, .left, .right]))
            edges += [x - f / 2, x + f / 2]
        }
        edges.append(o.x1 - f)
        let bar = o.y0 + (o.y1 - o.y0) * 0.68
        for g in stride(from: 0, to: edges.count, by: 2) {
            // Between two uprights the top and bottom members reach to the mullions' middles (their ends are hidden).
            let x0 = g == 0 ? edges[g] : edges[g] - f / 2, x1 = g == edges.count - 2 ? edges[g + 1] : edges[g + 1] + f / 2
            b[.frame].box([x0, o.y1 - f, back], [x1, o.y1, face], faces: shown([.front, .bottom]))
            b[.frame].box([x0, o.y0, back], [x1, o.y0 + f, face], faces: shown([.front, .top]))
            if transom { b[.frame].box([edges[g], bar - f / 2, back], [edges[g + 1], bar + f / 2, face], faces: [.front, .top, .bottom]) }
        }
    }

    /// What is behind the glass of opening `o`, at the wall's back (`thickness` behind its face): with probability
    /// `share` a room `room` deep (a shop's has a counter and shelves), otherwise a blind and the dark under it; at
    /// night, with probability `lit`, a light: the blind glows, or the room's lamps are on.
    private mutating func behind(_ o: Opening, _ cell: Cell, floor: Float, thickness: Float, room: Float, lit: Float,
                                 share: Float? = nil, shop: Bool = false) {
        let z = -thickness
        b.windows += 1
        // Every window draws the same numbers, whatever it turns out to be.
        let isRoom = rng.next() < (share ?? spec.rooms) && room >= 2, isLit = spec.night && rng.next() < lit
        let blind = rng.next(), side = rng.next()
        if isRoom && !isLit && spec.detail == .flat {   // seen from afar, a room is the dark behind the glass
            b.rooms += 1
            b[.dark].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: z)
            return
        }
        guard isRoom else {
            if isLit {
                b.lights += 1
                b[.lit].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: z)
            } else {
                // A blind drawn all the way, part of the way or not at all.
                let drawn: Float = blind < 0.25 ? 0 : blind < 0.5 ? 1 : 0.2 + 0.6 * (blind - 0.5) * 2
                let edge = o.y1 - (o.y1 - o.y0) * drawn
                b[.blind].wall(x0: o.x0, x1: o.x1, y0: edge, y1: o.y1, z: z)
                b[.dark].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: edge, z: z)
            }
            return
        }
        b.rooms += 1
        // The room: as wide as the bay less its walls, from the floor to a ceiling under the next floor.
        let gap: Float = shop ? 0.06 : 0.12
        let x0 = min(o.x0, cell.x0 + gap), x1 = max(o.x1, cell.x1 - gap)
        let y0 = min(o.y0, floor + 0.03), y1 = max(o.y1, cell.y1 - (shop ? 0.45 : 0.3))
        let back = z - room
        b[.interior].wall(x0: x0, x1: o.x0, y0: y0, y1: y1, z: z)
        b[.interior].wall(x0: o.x1, x1: x1, y0: y0, y1: y1, z: z)
        b[.interior].wall(x0: o.x0, x1: o.x1, y0: y0, y1: o.y0, z: z)
        b[.interior].wall(x0: o.x0, x1: o.x1, y0: o.y1, y1: y1, z: z)
        b[.interior].box([x0, y0, back], [x1, y1, z], faces: [.left, .right, .top, .back])
        b[.floor].floor(x0: x0, x1: x1, z0: back, z1: z, y: y0)
        // Something in it, so there is depth to look into: a counter and shelves, or a cupboard against a side wall.
        if shop {
            b[.accent].box([x0 + 0.4, y0, back + 0.8], [x1 - 0.4, y0 + 0.95, back + 1.4], faces: shown([.left, .right, .top, .front, .back]))
            let sx = side < 0.5 ? x0 + 0.04 : x1 - 0.44
            b[.accent].box([sx, y0, back + 1.8], [sx + 0.4, y0 + 1.9, z - 0.8], faces: shown([.left, .right, .top, .front, .back]))
        } else {
            let w = min(1.4, (x1 - x0) * 0.4), d = min(0.6, room * 0.3), h = 0.7 + 0.8 * side
            let fx = side < 0.5 ? x0 + 0.05 : x1 - 0.05 - w
            b[.accent].box([fx, y0, back + 0.05], [fx + w, y0 + h, back + 0.05 + d], faces: shown([.left, .right, .top, .front]))
        }
        if isLit {
            b.lights += 1
            let cx = (x0 + x1) / 2
            for cz in shop ? [z - room * 0.3, z - room * 0.7] : [z - room * 0.45] {
                b[.lamp].floor(x0: cx - 0.45, x1: cx + 0.45, z0: cz - 0.22, z1: cz + 0.22, y: y1 - 0.04, up: false)
            }
        }
    }

    // MARK: - Tiles

    /// A window in `cell`, or with `balcony` a glazed door onto a balcony.
    private mutating func window(_ cell: Cell, floor: Float, _ w: WindowStyle, wall: Building.Slot, plain: Bool, balcony: Bool,
                                 room: Float, lit: Float) {
        let width = min(min(max(cell.width * w.share, w.minWidth), w.maxWidth), cell.width - 0.16)
        let y0 = floor + (balcony ? 0.06 : w.sill)
        let y1 = min(y0 + (balcony ? max(w.height, 2.15) : w.height), cell.y1 - 0.3)
        guard width >= 0.5, y1 - y0 >= 0.5 else {
            b[wall].wall(x0: cell.x0, x1: cell.x1, y0: cell.y0, y1: cell.y1)
            return
        }
        let o = Opening(x0: cell.center - width / 2, x1: cell.center + width / 2, y0: y0, y1: y1)
        let thickness = w.recess + 0.08
        let mullions = width > 1.0 ? w.mullions : 0, transom = w.transom && !balcony
        if spec.modules && !plain {
            // Its shell a module: the same window elsewhere is the same mesh, placed there. The wall around it, its
            // glass and what is behind it are the building's own.
            wallAround(cell, o, slot: wall)
            b[.glass].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: -w.recess)
            module(at: [o.x0, o.y0, 0]) {
                $0.reveal(o, slot: wall, thickness: thickness)
                $0.frameMembers(o, recess: w.recess, width: w.frame, mullions: mullions, transom: transom)
                $0.windowTrim(o, cell, w, width: width, balcony: balcony)
            }
            behind(o, cell, floor: floor, thickness: thickness, room: room, lit: lit)
            if balcony { self.balcony(cell, floor: floor) }
            return
        }
        cutWall(cell, o, slot: wall, thickness: thickness)
        glaze(o, recess: w.recess, width: w.frame, mullions: mullions, transom: transom, frame: !plain)
        behind(o, cell, floor: floor, thickness: thickness, room: room, lit: lit)
        if balcony { self.balcony(cell, floor: floor) }
        guard !plain else { return }
        windowTrim(o, cell, w, width: width, balcony: balcony)
    }

    /// A window's sill, lintel and shutters, as its style has them.
    private mutating func windowTrim(_ o: Opening, _ cell: Cell, _ w: WindowStyle, width: Float, balcony: Bool) {
        if w.sillTrim && !balcony {
            b[.trim].box([o.x0 - 0.08, o.y0 - 0.09, 0], [o.x1 + 0.08, o.y0, 0.1], faces: shown([.front, .top, .bottom, .left, .right]))
        }
        if w.lintel {
            b[.trim].box([o.x0 - 0.1, o.y1, 0], [o.x1 + 0.1, o.y1 + 0.16, 0.06], faces: shown([.front, .top, .bottom, .left, .right]))
        }
        if w.shutters && !balcony {
            let leaf = min((o.x1 - o.x0) / 2, (cell.width - width) / 2 - 0.06)
            if leaf > 0.2 {
                b[.accent].box([o.x0 - leaf, o.y0, 0], [o.x0 - 0.02, o.y1, 0.04], faces: shown([.front, .top, .bottom, .left, .right]))
                b[.accent].box([o.x1 + 0.02, o.y0, 0], [o.x1 + leaf, o.y1, 0.04], faces: shown([.front, .top, .bottom, .left, .right]))
            }
        }
    }

    /// A balcony in front of `cell`: a slab at the floor and the style's balustrade around it.
    private mutating func balcony(_ cell: Cell, floor: Float) {
        let x0 = cell.x0 + 0.15, x1 = cell.x1 - 0.15, out: Float = 1.15, rail: Float = 1.05
        b[.trim].box([x0, floor - 0.16, 0], [x1, floor, out], faces: [.front, .top, .bottom, .left, .right])
        switch style.balustrade {
        case .solid:
            b[.trim].box([x0, floor, out - 0.1], [x1, floor + rail, out], faces: [.front, .back, .top, .left, .right])
            b[.trim].box([x0, floor, 0], [x0 + 0.1, floor + rail, out - 0.1], faces: shown([.left, .right, .top]))
            b[.trim].box([x1 - 0.1, floor, 0], [x1, floor + rail, out - 0.1], faces: shown([.left, .right, .top]))
        case .glass:
            b[.glass].wall(x0: x0 + 0.03, x1: x1 - 0.03, y0: floor + 0.05, y1: floor + rail, z: out - 0.04)
            for x in [x0 + 0.03, x1 - 0.03] {
                b[.glass].quad([x, floor + 0.05, 0.03], [x, floor + 0.05, out - 0.04], [x, floor + rail, out - 0.04], [x, floor + rail, 0.03])
            }
            b[.frame].box([x0, floor + rail, out - 0.07], [x1, floor + rail + 0.04, out - 0.01], faces: shown(.all))
        case .bars:
            // A rail and flat bars under it: single faces (every surface is two-sided).
            b[.frame].box([x0, floor + rail, out - 0.07], [x1, floor + rail + 0.06, out], faces: shown(.all))
            for x in [x0, x1 - 0.06] { b[.frame].box([x, floor + rail, 0], [x + 0.06, floor + rail + 0.06, out - 0.07], faces: [.left, .right, .top, .bottom]) }
            let bars = max(2, Int((x1 - x0) / 0.22))
            for k in 0...bars {
                let x = x0 + 0.01 + (x1 - x0 - 0.06) * Float(k) / Float(bars)
                b[.frame].wall(x0: x, x1: x + 0.04, y0: floor, y1: floor + rail, z: out - 0.035)
            }
            for x in [x0 + 0.03, x1 - 0.03] where spec.detail == .full {
                for k in 1...4 {
                    let z = (out - 0.07) * Float(k) / 5
                    b[.frame].quad([x, floor, z], [x, floor, z + 0.04], [x, floor + rail, z + 0.04], [x, floor + rail, z])
                }
            }
        }
    }

    /// The building's door: a leaf in the style's accent colour with a step up to it, or glass doors (a lobby's).
    private mutating func doorTile(_ cell: Cell, floor: Float, glazed: Bool) {
        let width = min(glazed ? 2.4 : 1.3, cell.width - 0.3), height = min(glazed ? 2.8 : 2.3, cell.y1 - floor - 0.5)
        guard width >= 0.8, height >= 1.9 else {
            b[.base].wall(x0: cell.x0, x1: cell.x1, y0: cell.y0, y1: cell.y1)
            return
        }
        let o = Opening(x0: cell.center - width / 2, x1: cell.center + width / 2, y0: floor, y1: floor + height)
        let recess: Float = 0.25, thickness = recess + 0.08
        cutWall(cell, o, slot: .base, thickness: thickness)
        if glazed {
            glaze(o, recess: recess, width: 0.08, mullions: 1, transom: false, frame: true)
            behind(o, cell, floor: floor, thickness: thickness, room: 0, lit: max(spec.lit, 0.7))
        } else {
            // The leaf closes the wall: nothing is behind it.
            b[.accent].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: -recess)
            b[.frame].box([o.x0, o.y0, -recess], [o.x0 + 0.07, o.y1, -recess + 0.05], faces: shown([.front, .right]))
            b[.frame].box([o.x1 - 0.07, o.y0, -recess], [o.x1, o.y1, -recess + 0.05], faces: shown([.front, .left]))
            b[.frame].box([o.x0 + 0.07, o.y1 - 0.07, -recess], [o.x1 - 0.07, o.y1, -recess + 0.05], faces: shown([.front, .bottom]))
            b[.metal].box([o.x1 - 0.22, o.y0 + 1.0, -recess], [o.x1 - 0.16, o.y0 + 1.12, -recess + 0.07],
                          faces: [.front, .top, .bottom, .left, .right])   // the handle
        }
        b[.trim].box([o.x0 - 0.25, cell.y0, 0], [o.x1 + 0.25, floor, 0.5], faces: shown([.front, .top, .left, .right]))
    }

    /// A shop's window: wide, from a low riser nearly to the sign, with the shop behind it and maybe an awning.
    private mutating func shopWindow(_ cell: Cell, floor: Float, room: Float, awning: Bool) {
        let office = style.kind == .office
        let o = Opening(x0: cell.x0 + (office ? 0.06 : 0.14), x1: cell.x1 - (office ? 0.06 : 0.14),
                        y0: floor + (office ? 0.1 : 0.45), y1: cell.y1 - (office ? 0.5 : 0.9))
        guard o.x1 - o.x0 >= 0.8, o.y1 - o.y0 >= 1 else {
            b[.base].wall(x0: cell.x0, x1: cell.x1, y0: cell.y0, y1: cell.y1)
            return
        }
        let recess: Float = office ? 0.1 : 0.16, thickness = recess + 0.08
        cutWall(cell, o, slot: .base, thickness: thickness)
        glaze(o, recess: recess, width: 0.08, mullions: o.x1 - o.x0 > 2.4 ? 1 : 0, transom: false, frame: true)
        // A shop is a room more often than not (if the city has rooms at all), and its light stays on late.
        behind(o, cell, floor: floor, thickness: thickness, room: room, lit: max(spec.lit, 0.6),
               share: spec.rooms > 0 ? max(spec.rooms, 0.75) : 0, shop: true)
        if awning {
            // A sloping sheet over the window, with its two cheeks.
            let y = o.y1 + 0.08, out: Float = 1.25, drop: Float = 0.55
            let x0 = o.x0 - 0.05, x1 = o.x1 + 0.05
            b[.accent].quad([x0, y, 0], [x1, y, 0], [x1, y - drop, out], [x0, y - drop, out])
            b[.accent].triangle([x0, y, 0], [x0, y - drop, out], [x0, y - drop, 0])
            b[.accent].triangle([x1, y, 0], [x1, y - drop, 0], [x1, y - drop, out])
        }
    }

    /// A warehouse's loading door: a tall opening closed by a ribbed shutter.
    private mutating func loadingDoor(_ cell: Cell, floor: Float) {
        let o = Opening(x0: cell.x0 + 0.5, x1: cell.x1 - 0.5, y0: floor, y1: min(floor + 3.8, cell.y1 - 0.9))
        guard o.x1 - o.x0 >= 1.5, o.y1 - o.y0 >= 2 else {
            b[.base].wall(x0: cell.x0, x1: cell.x1, y0: cell.y0, y1: cell.y1)
            return
        }
        let recess: Float = 0.22
        cutWall(cell, o, slot: .base, thickness: recess)
        b[.metal].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: -recess)
        // The shutter's ribs.
        let ribs = Int((o.y1 - o.y0) / 0.45)
        for k in 1..<max(ribs, 2) {
            let y = o.y0 + (o.y1 - o.y0) * Float(k) / Float(ribs)
            b[.metal].box([o.x0, y - 0.03, -recess], [o.x1, y + 0.03, -recess + 0.03], faces: shown([.front, .top, .bottom]))
        }
        b[.accent].box([o.x0 - 0.12, o.y1, 0], [o.x1 + 0.12, o.y1 + 0.22, 0.08], faces: shown([.front, .top, .bottom, .left, .right]))
    }
}
