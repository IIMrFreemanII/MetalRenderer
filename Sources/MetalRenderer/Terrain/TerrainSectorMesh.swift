import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// How a terrain's ground is meshed in a scene: where its UVs come from, how deep the skirts under tile sides hang,
/// and which ground material steep cells take.
package struct TerrainMeshStyle {
    /// UVs: the vertex's place from `uvOrigin` (the world's) times `uvScale`, or with `tileLocal` its place from its
    /// tile's corner times `uvScale` (the open world's ground, whose detail repeats every 5 m from each tile's corner).
    var uvOrigin = SIMD2<Double>.zero
    var uvScale: Float = 1
    var tileLocal = false
    /// Skirts hang under the sides of tiles (where a neighbour may be of another level of detail): `2 cell + 2` m deep.
    /// Off, they are flat (a finite terrain's edge, or a sector's side inside its tile, needs none).
    var skirts = false
    /// The kind steep cells (a normal's y under 0.8) take, where the base names kinds (World.Ground.rock).
    var rock: UInt8 = 3
    /// The terrain's layers (their rules make the vertices' weights where nothing is painted; none enabled: layer 0,
    /// the scene's own ground, wherever nothing is painted).
    var layers: [TerrainLayer] = []
    var rules: Bool { layers.contains { $0.rule.enabled } }
    /// The realistic look's relief (realism high): what raises a fine sector's ground (TerrainSector.subdiv).
    var relief: GroundRelief? = nil

    /// (As the memberwise initializer, for the modules above this one.)
    package init(uvOrigin: SIMD2<Double> = SIMD2<Double>.zero, uvScale: Float = 1, tileLocal: Bool = false, skirts: Bool = false, rock: UInt8 = 3, layers: [TerrainLayer] = [], relief: GroundRelief? = nil) {
        self.uvOrigin = uvOrigin
        self.uvScale = uvScale
        self.tileLocal = tileLocal
        self.skirts = skirts
        self.rock = rock
        self.layers = layers
        self.relief = relief
    }
}

/// A terrain sector's mesh (TerrainSector), from a snapshot of the terrain: its vertices in metres from its tile's
/// corner (y the world's), smooth normals from the neighbouring heights (across sectors and tiles, so the sides
/// match), and if the base names kinds, a material offset per triangle. The same layout every time for a sector,
/// so a sector's buffer can be written again in place (`write`).
struct TerrainSectorMesh {
    let sector: TerrainSector
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    var indices: [UInt32]
    var materials: [UInt8]?
    /// Each vertex's 16 layer weights (0...255; layer 0 the mesh's own material): TERRAIN's shading.
    var weights: [SIMD16<UInt8>]
    var bounds: AABB

    private init(sector: TerrainSector, positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
                 materials: [UInt8]?, weights: [SIMD16<UInt8>], bounds: AABB) {
        (self.sector, self.positions, self.normals, self.uvs, self.indices, self.materials, self.weights, self.bounds) =
            (sector, positions, normals, uvs, indices, materials, weights, bounds)
    }

    package init(_ s: TerrainSnapshot, sector: TerrainSector, style: TerrainMeshStyle) {
        if sector.subdiv > 1 {
            self = TerrainSectorMesh.fine(s, sector: sector, style: style)
            return
        }
        self.sector = sector
        let grid = s.grid, step = sector.step, cx = sector.cells.x, cz = sector.cells.y
        let cell = grid.cell * Float(step)
        let tileFirst = grid.firstSample(sector.tile)
        // Heights on the sector's samples and a ring around them (the ring is the neighbours': their normals then
        // match along the sides). A finite terrain's ring outside it is its edge again.
        let w = cx + 3
        let h = s.heights(from: sector.first &- step, count: SIMD2(w, cz + 3), step: step)
        @inline(__always) func at(_ i: Int, _ j: Int) -> Float { h[(j + 1) * w + i + 1] }
        // Whether a ring sample is outside a finite terrain (the normal's difference is then one-sided).
        let lo = grid.lo, hi = grid.hi
        func inside(_ i: Int, _ j: Int) -> (Bool, Bool, Bool, Bool) {
            let gi = sector.first.x + i * step, gj = sector.first.y + j * step
            guard let lo, let hi else { return (true, true, true, true) }
            return (gi - step >= lo.x, gi + step <= hi.x, gj - step >= lo.y, gj + step <= hi.y)
        }

        let vertexCount = sector.vertexCount
        let rules = style.rules
        var weights: [SIMD16<UInt8>] = []; weights.reserveCapacity(vertexCount)
        var positions: [SIMD3<Float>] = []; positions.reserveCapacity(vertexCount)
        var normals: [SIMD3<Float>] = []; normals.reserveCapacity(vertexCount)
        var uvs: [SIMD2<Float>] = []; uvs.reserveCapacity(vertexCount)
        var box = AABB()
        for j in 0...cz {
            for i in 0...cx {
                let gi = sector.first.x + i * step, gj = sector.first.y + j * step
                let p = SIMD3(Float(gi - tileFirst.x) * grid.cell, at(i, j), Float(gj - tileFirst.y) * grid.cell)
                positions.append(p)
                box.grow(p)
                let (l, r, d, u) = inside(i, j)
                let dx = at(r ? i + 1 : i, j) - at(l ? i - 1 : i, j), spanX = Float((r ? 1 : 0) + (l ? 1 : 0)) * cell
                let dz = at(i, u ? j + 1 : j) - at(i, d ? j - 1 : j), spanZ = Float((u ? 1 : 0) + (d ? 1 : 0)) * cell
                // (As Terrain.mesh has them on a finite terrain, as WorldTile.ground on the open world's: the same
                // direction, rounded the same as before.)
                normals.append(grid.isFinite ? normalize(SIMD3(-dx / spanX, 1, -dz / spanZ)) : normalize(SIMD3(-dx, 2 * cell, -dz)))
                // The layers' weights: the rules' (from the height and the slope here), and the paint over them.
                var w = SIMD16<Float>()
                if rules {
                    let n = normals[normals.count - 1], q = grid.place(gi, gj)
                    w = TerrainPaint.ruleWeights(style.layers, height: p.y, slope: acos(min(max(n.y, -1), 1)) * 180 / .pi, x: q.x, z: q.y)
                } else {
                    w[0] = 1
                }
                if let (painted, mask) = s.paint(gi, gj) { w += (SIMD16<Float>(painted) / 255 - w) * mask }
                var bytes = SIMD16<UInt8>()
                for l in 0..<16 { bytes[l] = UInt8(min(max(w[l] * 255, 0), 255).rounded()) }
                weights.append(bytes)
                if style.tileLocal {
                    uvs.append(SIMD2(p.x, p.z) * style.uvScale)
                } else {
                    let q = grid.place(gi, gj) - style.uvOrigin
                    uvs.append(SIMD2(Float(q.x), Float(q.y)) * style.uvScale)
                }
            }
        }
        // Kinds: the base's for level ground, rock where it is steep.
        let n1 = UInt32(cx + 1)
        var kinds: [UInt8]? = nil
        if s.base.kind(sector.first.x, sector.first.y, step: step) != nil {
            // (The tile's kinds read once, where it keeps them.)
            let table = s.base.kinds(sector.tile, step: step), tn = grid.tileCells / step
            let c0 = (sector.first &- tileFirst) / step
            var k = [UInt8](repeating: 0, count: cx * cz)
            for j in 0..<cz {
                for i in 0..<cx {
                    let dx = (at(i + 1, j) + at(i + 1, j + 1) - at(i, j) - at(i, j + 1)) / (2 * cell)
                    let dz = (at(i, j + 1) + at(i + 1, j + 1) - at(i, j) - at(i + 1, j)) / (2 * cell)
                    let up = 1 / (1 + dx * dx + dz * dz).squareRoot()
                    k[j * cx + i] = up < 0.8 ? style.rock
                        : table.map { $0[(c0.y + j) * tn + c0.x + i] } ?? s.base.kind(sector.first.x + i * step, sector.first.y + j * step, step: step) ?? 0
                }
            }
            kinds = k
        }
        var indices: [UInt32] = []; indices.reserveCapacity(sector.indexCount)
        var materials: [UInt8] = []
        if kinds != nil { materials.reserveCapacity(sector.triangleCount) }
        for j in 0..<cz {
            for i in 0..<cx {
                let a = UInt32(j) * n1 + UInt32(i), b = a + 1, c = a + n1, d = c + 1
                indices += [a, d, b, a, c, d]
                if let kinds { materials += [kinds[j * cx + i], kinds[j * cx + i]] }
            }
        }
        // The skirts: under each side, flat where none is wanted (a finite terrain's edge, a side inside the tile).
        let tileLast = tileFirst &+ grid.tileCells
        func skirt(_ count: Int, onTileSide: Bool, vertex: (Int) -> Int, kind: (Int) -> UInt8) {
            let drop: Float = style.skirts && onTileSide ? 2 * cell + 2 : 0
            let first = UInt32(positions.count)
            for k in 0...count {
                let v = vertex(k)
                positions.append(positions[v] - SIMD3(0, drop, 0))
                normals.append(normals[v])
                uvs.append(uvs[v])
                weights.append(weights[v])
            }
            if drop > 0 { for k in 0...count { box.grow(positions[Int(first) + k]) } }
            for k in 0..<count {
                let a = UInt32(vertex(k)), b = UInt32(vertex(k + 1)), c = first + UInt32(k), d = c + 1
                indices += [a, b, d, a, d, c]
                if kinds != nil { materials += [kind(k), kind(k)] }
            }
        }
        let k = kinds ?? []
        skirt(cx, onTileSide: sector.first.y == tileFirst.y, vertex: { $0 }, kind: { k.isEmpty ? 0 : k[$0] })
        skirt(cx, onTileSide: sector.last.y == tileLast.y, vertex: { cz * (cx + 1) + $0 }, kind: { k.isEmpty ? 0 : k[(cz - 1) * cx + $0] })
        skirt(cz, onTileSide: sector.first.x == tileFirst.x, vertex: { $0 * (cx + 1) }, kind: { k.isEmpty ? 0 : k[$0 * cx] })
        skirt(cz, onTileSide: sector.last.x == tileLast.x, vertex: { $0 * (cx + 1) + cx }, kind: { k.isEmpty ? 0 : k[$0 * cx + cx - 1] })
        (self.positions, self.normals, self.uvs, self.indices, self.weights) = (positions, normals, uvs, indices, weights)
        self.materials = kinds == nil ? nil : materials
        bounds = box
    }

    /// A fine sector (TerrainSector.subdiv > 1, the realistic look's near ground): each cell cut into subdiv x subdiv
    /// quads, the ground between the samples smooth (Catmull-Rom across them) and raised by `style.relief`; toward a
    /// side whose neighbour is coarse (`seams`) both fade out over SEAM_FADE metres, so that side lies on the coarse
    /// triangles (the same diagonal) and nothing cracks. Its normals from the displaced grid (the coarse ones'
    /// toward a seam), its weights, UVs and kinds as the coarse cell's around it.
    private static func fine(_ s: TerrainSnapshot, sector: TerrainSector, style: TerrainMeshStyle) -> TerrainSectorMesh {
        let seamFade: Float = 3
        let grid = s.grid, step = sector.step, cx = sector.cells.x, cz = sector.cells.y, k = sector.subdiv
        let cell = grid.cell * Float(step)
        let tileFirst = grid.firstSample(sector.tile)
        // Heights with a ring of two around the sector (a Catmull-Rom spline needs two samples a side).
        let w = cx + 5
        let h = s.heights(from: sector.first &- step &* 2, count: SIMD2(w, cz + 5), step: step)
        @inline(__always) func at(_ i: Int, _ j: Int) -> Float { h[(min(max(j, -2), cz + 2) + 2) * w + min(max(i, -2), cx + 2) + 2] }
        func spline(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
            let t2 = t * t, t3 = t2 * t
            return 0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
        }
        // The samples' normals and weights, as the coarse mesh has them.
        let samples = (cx + 1) * (cz + 1)
        var sampleNormals = [SIMD3<Float>](repeating: [0, 1, 0], count: samples)
        var sampleWeights = [SIMD16<Float>](repeating: SIMD16<Float>(), count: samples)
        let rules = style.rules
        for j in 0...cz {
            for i in 0...cx {
                let dx = at(i + 1, j) - at(i - 1, j), dz = at(i, j + 1) - at(i, j - 1)
                let n = grid.isFinite ? normalize(SIMD3(-dx / (2 * cell), 1, -dz / (2 * cell))) : normalize(SIMD3(-dx, 2 * cell, -dz))
                sampleNormals[j * (cx + 1) + i] = n
                let gi = sector.first.x + i * step, gj = sector.first.y + j * step
                var wt = SIMD16<Float>()
                if rules {
                    let q = grid.place(gi, gj)
                    wt = TerrainPaint.ruleWeights(style.layers, height: at(i, j), slope: acos(min(max(n.y, -1), 1)) * 180 / .pi, x: q.x, z: q.y)
                } else {
                    wt[0] = 1
                }
                if let (painted, mask) = s.paint(gi, gj) { wt += (SIMD16<Float>(painted) / 255 - wt) * mask }
                sampleWeights[j * (cx + 1) + i] = wt
            }
        }
        // Where a fine vertex is between the samples: its cell and the place in it.
        func cellAt(_ fx: Float, _ fz: Float) -> (i: Int, j: Int, u: Float, v: Float) {
            let i = min(max(Int(fx.rounded(.down)), -1), cx), j = min(max(Int(fz.rounded(.down)), -1), cz)
            return (i, j, fx - Float(i), fz - Float(j))
        }
        func fade(_ fx: Float, _ fz: Float) -> Float {
            var d = Float.infinity
            if sector.seams & 1 != 0 { d = min(d, fz * cell) }
            if sector.seams & 2 != 0 { d = min(d, (Float(cz) - fz) * cell) }
            if sector.seams & 4 != 0 { d = min(d, fx * cell) }
            if sector.seams & 8 != 0 { d = min(d, (Float(cx) - fx) * cell) }
            let t = min(max(d / seamFade, 0), 1)
            return t * t * (3 - 2 * t)
        }
        // The ground (without relief) at a place in sample units from the sector's first: the coarse triangle's plane
        // (diagonal from (i, j) to (i + 1, j + 1), as the coarse indices), smoothing toward the spline away from seams.
        func base(_ fx: Float, _ fz: Float) -> Float {
            let (i, j, u, v) = cellAt(fx, fz)
            let flat = u >= v ? at(i, j) + (at(i + 1, j) - at(i, j)) * u + (at(i + 1, j + 1) - at(i + 1, j)) * v
                              : at(i, j) + (at(i + 1, j + 1) - at(i, j + 1)) * u + (at(i, j + 1) - at(i, j)) * v
            let f = fade(fx, fz)
            guard f > 0 else { return flat }
            var rows = [Float](repeating: 0, count: 4)
            for r in 0..<4 { rows[r] = spline(at(i - 1, j - 1 + r), at(i, j - 1 + r), at(i + 1, j - 1 + r), at(i + 2, j - 1 + r), u) }
            let smooth = spline(rows[0], rows[1], rows[2], rows[3], v)
            return flat + (smooth - flat) * f
        }
        func bilinear<T: SIMD>(_ a: [T], _ i: Int, _ j: Int, _ u: Float, _ v: Float) -> T where T.Scalar == Float {
            let i0 = min(max(i, 0), cx), j0 = min(max(j, 0), cz), i1 = min(i0 + 1, cx), j1 = min(j0 + 1, cz)
            let uu = T(repeating: min(max(u, 0), 1)), vv = T(repeating: min(max(v, 0), 1))
            let top = a[j0 * (cx + 1) + i0] + (a[j0 * (cx + 1) + i1] - a[j0 * (cx + 1) + i0]) * uu
            let bottom = a[j1 * (cx + 1) + i0] + (a[j1 * (cx + 1) + i1] - a[j1 * (cx + 1) + i0]) * uu
            return top + (bottom - top) * vv
        }
        let origin = grid.place(sector.first.x, sector.first.y), metresPerSample = Double(grid.cell) * Double(step)
        // The ground with its relief on the fine grid and a ring of one vertex (for the normals).
        let nx = cx * k + 1, nz = cz * k + 1, rx = nx + 2
        var heights = [Float](repeating: 0, count: rx * (nz + 2))
        var weightsAt = [SIMD16<Float>](repeating: SIMD16<Float>(), count: nx * nz)
        let inv = 1 / Float(k)
        for b in -1...nz {
            for a in -1...nx {
                let fx = Float(a) * inv, fz = Float(b) * inv
                var y = base(fx, fz)
                let (i, j, u, v) = cellAt(min(max(fx, 0), Float(cx)), min(max(fz, 0), Float(cz)))
                let wt = bilinear(sampleWeights, i, j, u, v)
                if a >= 0, a < nx, b >= 0, b < nz { weightsAt[b * nx + a] = wt }
                if let relief = style.relief {
                    let f = fade(fx, fz)
                    if f > 0 {
                        let e = 0.5 * inv
                        let dx = base(fx + e, fz) - base(fx - e, fz), dz = base(fx, fz + e) - base(fx, fz - e)
                        let up = 1 / (1 + (dx * dx + dz * dz) / (cell * inv * cell * inv)).squareRoot()
                        y += f * relief(x: origin.x + Double(fx) * metresPerSample, z: origin.y + Double(fz) * metresPerSample, up: up, weights: wt)
                    }
                }
                heights[(b + 1) * rx + a + 1] = y
            }
        }
        @inline(__always) func hv(_ a: Int, _ b: Int) -> Float { heights[(b + 1) * rx + a + 1] }

        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], weights: [SIMD16<UInt8>] = []
        positions.reserveCapacity(sector.vertexCount); normals.reserveCapacity(sector.vertexCount)
        uvs.reserveCapacity(sector.vertexCount); weights.reserveCapacity(sector.vertexCount)
        var box = AABB()
        let fineCell = cell * inv
        let firstOffset = SIMD2(Float(sector.first.x - tileFirst.x), Float(sector.first.y - tileFirst.y)) * grid.cell
        for b in 0..<nz {
            for a in 0..<nx {
                let fx = Float(a) * inv, fz = Float(b) * inv
                let p = SIMD3(firstOffset.x + fx * cell, hv(a, b), firstOffset.y + fz * cell)
                positions.append(p)
                box.grow(p)
                let displaced = normalize(SIMD3(-(hv(a + 1, b) - hv(a - 1, b)) / (2 * fineCell), 1, -(hv(a, b + 1) - hv(a, b - 1)) / (2 * fineCell)))
                let (i, j, u, v) = cellAt(fx, fz)
                let coarse = normalize(bilinear(sampleNormals, i, j, u, v))
                normals.append(normalize(coarse + (displaced - coarse) * fade(fx, fz)))
                let wt = weightsAt[b * nx + a]
                var bytes = SIMD16<UInt8>()
                for l in 0..<16 { bytes[l] = UInt8(min(max(wt[l] * 255, 0), 255).rounded()) }
                weights.append(bytes)
                if style.tileLocal {
                    uvs.append(SIMD2(p.x, p.z) * style.uvScale)
                } else {
                    let q = origin + SIMD2(Double(fx), Double(fz)) * metresPerSample - style.uvOrigin
                    uvs.append(SIMD2(Float(q.x), Float(q.y)) * style.uvScale)
                }
            }
        }
        // Kinds: the coarse cell's (the base's, rock where the coarse cell is steep).
        var kinds: [UInt8]? = nil
        if s.base.kind(sector.first.x, sector.first.y, step: step) != nil {
            let table = s.base.kinds(sector.tile, step: step), tn = grid.tileCells / step
            let c0 = (sector.first &- tileFirst) / step
            var kk = [UInt8](repeating: 0, count: cx * cz)
            for j in 0..<cz {
                for i in 0..<cx {
                    let dx = (at(i + 1, j) + at(i + 1, j + 1) - at(i, j) - at(i, j + 1)) / (2 * cell)
                    let dz = (at(i, j + 1) + at(i + 1, j + 1) - at(i, j) - at(i + 1, j)) / (2 * cell)
                    let up = 1 / (1 + dx * dx + dz * dz).squareRoot()
                    kk[j * cx + i] = up < 0.8 ? style.rock
                        : table.map { $0[(c0.y + j) * tn + c0.x + i] } ?? s.base.kind(sector.first.x + i * step, sector.first.y + j * step, step: step) ?? 0
                }
            }
            kinds = kk
        }
        var indices: [UInt32] = []; indices.reserveCapacity(sector.indexCount)
        var materials: [UInt8] = []
        if kinds != nil { materials.reserveCapacity(sector.triangleCount) }
        let n1 = UInt32(nx)
        for b in 0..<(nz - 1) {
            for a in 0..<(nx - 1) {
                let q = UInt32(b) * n1 + UInt32(a), r = q + 1, c = q + n1, d = c + 1
                indices += [q, d, r, q, c, d]
                if let kinds { let kind = kinds[(b / k) * cx + a / k]; materials += [kind, kind] }
            }
        }
        // The skirts, as a coarse sector's, under the fine sides.
        let tileLast = tileFirst &+ grid.tileCells
        let qx = nx - 1, qz = nz - 1
        func skirt(_ count: Int, onTileSide: Bool, vertex: (Int) -> Int, kind: (Int) -> UInt8) {
            let drop: Float = style.skirts && onTileSide ? 2 * cell + 2 : 0
            let first = UInt32(positions.count)
            for q in 0...count {
                let vtx = vertex(q)
                positions.append(positions[vtx] - SIMD3(0, drop, 0))
                normals.append(normals[vtx])
                uvs.append(uvs[vtx])
                weights.append(weights[vtx])
            }
            if drop > 0 { for q in 0...count { box.grow(positions[Int(first) + q]) } }
            for q in 0..<count {
                let a = UInt32(vertex(q)), b = UInt32(vertex(q + 1)), c = first + UInt32(q), d = c + 1
                indices += [a, b, d, a, d, c]
                if kinds != nil { materials += [kind(q), kind(q)] }
            }
        }
        let kk = kinds ?? []
        skirt(qx, onTileSide: sector.first.y == tileFirst.y, vertex: { $0 }, kind: { kk.isEmpty ? 0 : kk[$0 / k] })
        skirt(qx, onTileSide: sector.last.y == tileLast.y, vertex: { qz * nx + $0 }, kind: { kk.isEmpty ? 0 : kk[(cz - 1) * cx + $0 / k] })
        skirt(qz, onTileSide: sector.first.x == tileFirst.x, vertex: { $0 * nx }, kind: { kk.isEmpty ? 0 : kk[($0 / k) * cx] })
        skirt(qz, onTileSide: sector.last.x == tileLast.x, vertex: { $0 * nx + qx }, kind: { kk.isEmpty ? 0 : kk[($0 / k) * cx + cx - 1] })
        return TerrainSectorMesh(sector: sector, positions: positions, normals: normals, uvs: uvs, indices: indices,
                                 materials: kinds == nil ? nil : materials, weights: weights, bounds: box)
    }

    /// As a scene borrows it (Scene.addMesh(borrowing:)).
    var borrowed: Scene.BorrowedMesh {
        Scene.BorrowedMesh(positions: .made(positions), normals: .made(normals), uvs: .made(uvs), indices: .made(indices),
                           materials: materials.map { .made($0) }, weights: .made(weights))
    }

    /// Its bytes as a mesh's buffer holds them (MeshBlock): positions, normals, UVs, indices, a material per triangle.
    var byteCount: Int { MeshBlock.length(vertices: positions.count, indices: indices.count, weights: true) }

    func write(into p: UnsafeMutableRawPointer) {
        var at = p
        func copy<T>(_ a: [T]) {
            a.withUnsafeBytes { at.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            at += a.count * MemoryLayout<T>.stride
        }
        copy(positions)
        copy(normals)
        copy(uvs)
        copy(indices)
        if let materials { copy(materials) } else { at.initializeMemory(as: UInt8.self, repeating: 0, count: indices.count / 3) }
        at = p + MeshBlock.weightsOffset(vertices: positions.count, indices: indices.count)
        copy(weights)
    }
}
