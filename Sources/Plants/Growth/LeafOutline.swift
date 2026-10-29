import EngineCore
import Foundation
import simd

extension Foliage {
    /// A leaf as its own outline, not a kite or a card: a scanned leaf sheet's leaves (Assets/Textures/leaves, 3 by 3;
    /// a species' own, LeafRecipe.sheet, as its info.json's "cells" say), each traced from the sheet's opacity into a
    /// polygon whose UVs are where it is on the sheet. The texture then fits the shape exactly, with nothing cut out at
    /// render time (an alpha test would hand every leaf ray back to the shader). Without the sheet, ovate outlines stand
    /// in, laid out on 3 by 3 cells.
    package struct LeafOutline {
        /// Across the leaf (-0.5...0.5 of its widest) and along it (0 base, 1 tip), and where that is on the sheet.
        package struct Point { package var across: Float; package var along: Float; package var uv: SIMD2<Float> }
        package var base: Point
        package var sides: [(left: Point, right: Point)]    // `rows` of them, base to tip
        package var tip: Point
        package var aspect: Float                           // widest over length

        package static let rows = 4
        package static let cells = 3
        package static let size = MeshSize(vertices: 2 + 2 * rows, indices: 3 * 2 * rows)

        /// The sheet the species that don't name theirs share (LeafRecipe.sheet).
        package static let defaultSheet = "leaves"

        /// The default sheet's leaves.
        package static var sheet: [LeafOutline] { sheet(defaultSheet) }

        /// Sheet `name`'s leaves, traced once (or the ovate stand-ins, if it isn't there).
        package static func sheet(_ name: String) -> [LeafOutline] {
            lock.lock()
            defer { lock.unlock() }
            if let known = traces[name] { return known }
            let made = traced(name) ?? ovate()
            traces[name] = made
            return made
        }
        private static var traces: [String: [LeafOutline]] = [:]
        private static let lock = NSLock()

        /// Sheet `name`'s grid of leaves, columns and rows (3 by 3 if it isn't there).
        package static func grid(_ name: String) -> SIMD2<Int> { TextureSet.find(name)?.cells ?? SIMD2(cells, cells) }

        /// Traces each cell of a sheet's opacity: its leaf's lowest and highest rows (the sheet's leaves stand tip up,
        /// as Surface.metal's sheet leaves read it), and its edges at `rows` heights between.
        static func traced(_ name: String) -> [LeafOutline]? {
            guard let set = TextureSet.find(name) else { return nil }
            // (64 pixels to the cell across the sheet's longer way: a 3 by 3 sheet's cells 64 square, a 3 by 2's 64 by 96.)
            let grid = set.cells, side = 64 * max(grid.x, grid.y), cw2 = side / grid.x, ch2 = side / grid.y
            guard let g = set.gray(.opacity, size: side) else { return nil }
            var out: [LeafOutline] = []
            for cy in 0..<grid.y {
                for cx in 0..<grid.x {
                    let x0 = cx * cw2, y0 = cy * ch2
                    func solid(_ x: Int, _ y: Int) -> Bool { g.pixels[(y0 + y) * side + x0 + x] > 127 }
                    let filled = (0..<ch2).filter { y in (0..<cw2).contains { solid($0, y) } }
                    guard let top = filled.first, let bottom = filled.last, bottom - top > 8 else { return nil }
                    func edges(_ y: Int) -> (Int, Int) {
                        let xs = (0..<cw2).filter { solid($0, y) }
                        return (xs.first ?? cw2 / 2, xs.last ?? cw2 / 2)
                    }
                    func uv(_ x: Float, _ y: Int) -> SIMD2<Float> { SIMD2((Float(x0) + x + 0.5) / Float(side), (Float(y0 + y) + 0.5) / Float(side)) }
                    let length = Float(bottom - top)
                    let baseEdges = edges(bottom), tipEdges = edges(top)
                    let baseX = Float(baseEdges.0 + baseEdges.1) / 2, tipX = Float(tipEdges.0 + tipEdges.1) / 2
                    var rows: [(left: Int, right: Int, y: Int, t: Float)] = []
                    for k in 1...LeafOutline.rows {
                        let t = Float(k) / Float(LeafOutline.rows + 1)
                        let y = bottom - Int((t * length).rounded())
                        let e = edges(y)
                        rows.append((e.0, e.1 + 1, y, t))
                    }
                    let widest = max(Float(rows.map { $0.right - $0.left }.max() ?? 1), 1)
                    func axis(_ t: Float) -> Float { baseX + (tipX - baseX) * t }
                    func point(_ x: Float, _ y: Int, _ t: Float) -> Point { Point(across: (x - axis(t)) / widest, along: t, uv: uv(x, y)) }
                    out.append(LeafOutline(base: point(baseX, bottom, 0),
                                           sides: rows.map { (point(Float($0.left), $0.y, $0.t), point(Float($0.right), $0.y, $0.t)) },
                                           tip: point(tipX, top, 1), aspect: widest / length))
                }
            }
            return out
        }

        /// Ovate leaves on the same cells (widest a third of the way up, two fifths as wide as long).
        static func ovate() -> [LeafOutline] {
            (0..<(cells * cells)).map { c in
                let cell = SIMD2(Float(c % cells), Float(c / cells))
                func uv(_ a: Float, _ t: Float) -> SIMD2<Float> { (cell + SIMD2(0.5 + a * 0.62, 0.93 - t * 0.85)) / Float(cells) }
                func p(_ a: Float, _ t: Float) -> Point { Point(across: a, along: t, uv: uv(a, t)) }
                let sides = (1...rows).map { k -> (left: Point, right: Point) in
                    let t = Float(k) / Float(rows + 1)
                    let w = 0.5 * sin(.pi * pow(t, 0.8))
                    return (p(-w, t), p(w, t))
                }
                return LeafOutline(base: p(0, 0), sides: sides, tip: p(0, 1), aspect: 0.4)
            }
        }
    }

    /// An outline leaf at `a`: one of `sheet`'s leaves (picked by `index`, mirrored or not), its sides folded up
    /// over the midrib like a kite's. Its V carries its number (1...1023, the whole part) so that the shading tells
    /// one leaf from the next however many triangles it has (the texture wraps: the number doesn't move it).
    /// `tag`: its twig's health, 0...7, carried as the whole part of its U.
    static func writeOutline(_ a: LeafAnchor, fold: Float, index: Int, tag: Int = 0, sheet: [LeafOutline], into w: inout MeshWriter) {
        var h = UInt32(truncatingIfNeeded: index) &* 0x9E3779B1
        h ^= h >> 15
        let outline = sheet[Int(h % UInt32(sheet.count))]
        let mirror: Float = (h >> 8) & 1 == 0 ? 1 : -1
        let number = Float(index % 1023 + 1)
        let d = a.direction, n = a.normal, side = cross(d, n) * mirror
        let width = a.length * outline.aspect
        let tilt = side * (2 * fold)
        func vertex(_ q: LeafOutline.Point) -> UInt32 {
            let lift = n * (fold * width * abs(2 * q.across))
            let normal = q.across == 0 ? n : normalize(n - tilt * (q.across > 0 ? 1 : -1))
            return w.vertex(a.position + d * (q.along * a.length) + side * (q.across * width) + lift, normal,
                            SIMD2(q.uv.x + Float(min(max(tag, 0), 7)), q.uv.y + number))
        }
        let base = vertex(outline.base)
        var rows: [(UInt32, UInt32)] = []
        for s in outline.sides { rows.append((vertex(s.left), vertex(s.right))) }
        let tip = vertex(outline.tip)
        // (Wound as the kite is: base, its right, then on toward the tip.)
        w.triangle(base, rows[0].1, rows[0].0)
        for k in 0..<(rows.count - 1) {
            w.triangle(rows[k].0, rows[k].1, rows[k + 1].1)
            w.triangle(rows[k].0, rows[k + 1].1, rows[k + 1].0)
        }
        w.triangle(rows[rows.count - 1].0, rows[rows.count - 1].1, tip)
    }
}
