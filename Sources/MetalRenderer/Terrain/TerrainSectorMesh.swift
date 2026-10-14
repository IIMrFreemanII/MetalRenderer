import Foundation
import simd

/// How a terrain's ground is meshed in a scene: where its UVs come from, how deep the skirts under tile sides hang,
/// and which ground material steep cells take.
struct TerrainMeshStyle {
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

    init(_ s: TerrainSnapshot, sector: TerrainSector, style: TerrainMeshStyle) {
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
