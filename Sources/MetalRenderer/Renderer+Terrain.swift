import Foundation
import Metal
import QuartzCore
import simd

/// What the Terrain Editor's window shows of the renderer's side (sent when it changes, on the render thread).
struct TerrainStatus: Equatable {
    /// The scene's terrain (its document's name), if its ground is one.
    var terrain: String?
    /// Sculpt mode: the main view's left drags are the brush's.
    var active = false
    /// The brush as the renderer has it ([ ] change it in the view).
    var brush = TerrainBrush()
    /// Under the cursor: the world's place, its height and slope (degrees).
    var hover: SIMD3<Double>?
    var slope: Float = 0
    /// Strokes kept for undo since the last status (their ids, in order).
    var strokes: [Int] = []
    /// Sectors waiting to be meshed again, and the last frame's work: sectors built, milliseconds of the CPU's part.
    var pending = 0
    var built = 0
    var cpuMs: Double = 0
    /// The field's revision (the map draws again when it changes).
    var revision = 0
    /// A long job (a generator's run, erosion) under way: what it is and how far it has gone (0...1).
    var job: String?
    var progress: Float = 0
    /// Where the camera is (the world's) and which way it looks (yaw): the map shows it.
    var camera = SIMD3<Double>.zero
    var yaw: Float = 0
    var message = ""
}

/// The Terrain Editor's state in the renderer: sculpt mode, the brush, the stroke under way, which revision of the
/// field each sector's buffer holds, and the strokes kept for undo.
final class TerrainGPU {
    var active = false
    var brush = TerrainBrush()
    var stroke: TerrainStroke?
    var record = TerrainUndoRecord()
    /// The cursor (0...1 across and down), the pen's pressure, and the ground under the cursor (the world's).
    var hover: SIMD2<Float>?
    var pressure: Float = 1
    var hoverHit: SIMD3<Double>?
    var hoverNormal = SIMD3<Float>(0, 1, 0)
    /// Dabs to put on the field this frame; when the stroke last dabbed (the airbrush keeps on where it is held).
    var pendingDabs: [TerrainDab] = []
    var lastDab: CFTimeInterval = 0
    /// Per sector's mesh name: the buffer it is in and the field's revision it holds.
    var built: [String: (block: ObjectIdentifier, revision: Int)] = [:]
    /// The field's revision when the sectors were last looked at, and whether some waited (the budget).
    var checked = -1
    var backlog = false
    /// Per frame slot: where the sectors' new bytes are put for the GPU to copy.
    var staging: [MTLBuffer?] = []
    /// The strokes kept for undo, by id (at most `undoBudget` bytes), and those not yet reported.
    var records: [Int: TerrainUndoRecord] = [:]
    var order: [Int] = []
    var nextRecord = 1
    var unreported: [Int] = []
    static let undoBudget = 512 << 20
    var statusSent: TerrainStatus?
    var message = ""
    var lastBuilt = 0
    var lastCPU: Double = 0
    /// The document's version the scene's terrain was last brought up to (its layers: TerrainDocuments.version).
    var documentVersion = -1
    /// The long job under way (one at a time), its progress, and whether it was asked to stop.
    var job: String?
    var progress: Float = 0
    var cancelJob = false
    /// The last stroke's path over the ground (the world's x, z): a river's line.
    var lastStroke: [SIMD2<Double>] = []
    /// Sectors a frame meshes and builds at most: `METALRENDERER_TERRAIN_BUDGET` (6: about 5 ms on an M1 Max).
    static let budget = ProcessInfo.processInfo.environment["METALRENDERER_TERRAIN_BUDGET"].flatMap(Int.init).map { min(max($0, 1), TerrainBuild.perFrame) } ?? 6
    /// `METALRENDERER_TERRAIN_LOG=1`: what each frame's terrain work did.
    static let log = ProcessInfo.processInfo.environment["METALRENDERER_TERRAIN_LOG"] == "1"

    /// A new scene: its sectors' buffers are the ones it was built with (each with the revision it was made at), unless
    /// it kept a buffer of the last scene's, which holds what that one had.
    func sceneChanged(_ scene: Scene, blocks: [MeshBlock?]) {
        stroke = nil
        pendingDabs = []
        hoverHit = nil
        checked = -1
        backlog = true
        var next: [String: (block: ObjectIdentifier, revision: Int)] = [:]
        for p in scene.terrain?.parts ?? [] {
            guard p.mesh < blocks.count, let block = blocks[p.mesh] else { continue }
            let id = ObjectIdentifier(block)
            if let old = built[p.name], old.block == id { next[p.name] = old } else { next[p.name] = (id, p.revision) }
        }
        built = next
        statusSent = nil
    }
}

/// A frame's terrain work for the GPU (Renderer.encodeTerrain): bytes to copy into sectors' buffers, the meshes whose
/// structures are built again over them, and their instances (the raster's bounds, the virtual shadow maps' pages).
struct TerrainFrameWork {
    var copies: [BufferCopy] = []
    var meshes: [Int] = []
    var instances: [Int] = []
    var bounds: [(mesh: Int, box: AABB)] = []
}

/// A copy from one buffer into another, in a frame (FrameEncoder.copyBuffers).
struct BufferCopy {
    let source: MTLBuffer
    let sourceOffset: Int
    let destination: MTLBuffer
    let destinationOffset: Int
    let size: Int
}

extension Renderer {
    // MARK: - Sculpt mode

    /// Sculpt mode on (left drags in the main view are the brush's) or off.
    func setTerrainMode(_ on: Bool) {
        terrain.active = on && scene.terrain != nil
        terrain.stroke = nil
        terrain.message = scene.terrain == nil && on ? "This scene's ground isn't a terrain" : ""
        reportTerrain()
    }

    func setTerrainBrush(_ brush: TerrainBrush) {
        terrain.brush = brush
    }

    /// A press in sculpt mode: a stroke begins where the cursor meets the ground. False: not sculpt mode, or Option is
    /// held (the camera's), or the cursor isn't on the ground.
    /// `invert` (Control held): the brush's opposite (raise lowers, paint erases, protect frees); `smooth` (Shift held):
    /// the smooth brush, of the same size.
    func terrainMouseDown(at cursor: SIMD2<Float>, pressure: Float, option: Bool, invert: Bool = false, smooth: Bool = false) -> Bool {
        guard terrain.active, !option, scene.terrain != nil else { return false }
        terrain.hover = cursor
        terrain.pressure = pressure
        updateTerrainHover()
        guard let hit = terrain.hoverHit else { return true }
        let p = SIMD2(hit.x, hit.z)
        var brush = terrain.brush
        if smooth { brush.tool = .smooth }
        if invert {
            switch brush.tool {
            case .raise: brush.tool = .lower
            case .lower: brush.tool = .raise
            case .paint: brush.tool = .erase
            case .erase: brush.tool = .paint
            case .protect: brush.tool = .unprotect
            case .unprotect: brush.tool = .protect
            default: break
            }
        }
        var stroke = TerrainStroke(brush: brush, start: p, height: Float(hit.y))
        terrain.record = TerrainUndoRecord(title: brush.tool.title)
        if !brush.tool.actsOnRelease { terrain.pendingDabs += stroke.begin(pressure: pressure) }
        _ = stroke.move(to: p, height: Float(hit.y), pressure: pressure)
        terrain.stroke = stroke
        terrain.lastDab = CACurrentMediaTime()
        return true
    }

    func terrainMouseDragged(at cursor: SIMD2<Float>, pressure: Float) -> Bool {
        guard terrain.active, terrain.stroke != nil else { return false }
        terrain.hover = cursor
        terrain.pressure = pressure
        updateTerrainHover()
        guard let hit = terrain.hoverHit, var stroke = terrain.stroke else { return true }
        let dabs = stroke.move(to: SIMD2(hit.x, hit.z), height: Float(hit.y), pressure: pressure)
        if !stroke.brush.tool.actsOnRelease { terrain.pendingDabs += dabs }
        if !dabs.isEmpty { terrain.lastDab = CACurrentMediaTime() }
        terrain.stroke = stroke
        return true
    }

    func terrainMouseUp() -> Bool {
        guard terrain.active, let stroke = terrain.stroke else { return false }
        if stroke.brush.tool.actsOnRelease, let t = scene.terrain {
            var record = terrain.record
            t.field.edit { s in
                TerrainSculpt.ramp(&s, from: stroke.start, stroke.startHeight, to: stroke.last, stroke.lastHeight, brush: stroke.brush,
                                   record: &record)
            }
            terrain.record = record
        }
        applyTerrainDabs()
        finishTerrainStroke()
        return true
    }

    /// The cursor over the view (no button): the ring follows it.
    func terrainMouseMoved(at cursor: SIMD2<Float>) {
        guard terrain.active else { return }
        terrain.hover = cursor
        updateTerrainHover()
    }

    /// The brush larger (`step` > 0) or smaller; with `strength`, stronger or weaker.
    func resizeTerrainBrush(_ step: Int, strength: Bool) {
        if strength {
            terrain.brush.strength = min(max(terrain.brush.strength + (step > 0 ? 0.05 : -0.05), 0.01), 1)
        } else {
            terrain.brush.radius = min(max(terrain.brush.radius * (step > 0 ? 1.15 : 1 / 1.15), 0.5), 2000)
        }
        reportTerrain()
    }

    /// What is under the cursor: where its ray meets the terrain as it is now.
    func updateTerrainHover() {
        guard let t = scene.terrain, let c = terrain.hover else { terrain.hoverHit = nil; return }
        let s = t.field.snapshot(), o = t.world(camera.position)
        guard let hit = s.raycast(origin: o, direction: cursorRayForPainter(c)) else {
            if TerrainGPU.log { print("Terrain: no ground under the cursor \(c) from \(o) along \(cursorRayForPainter(c)), ground there \(s.height(x: o.x, z: o.z))") }
            terrain.hoverHit = nil
            return
        }
        terrain.hoverHit = hit.point
        terrain.hoverNormal = s.normal(x: hit.point.x, z: hit.point.z)
    }

    /// The stroke's dabs (and while it is held still, the airbrush's), onto the field.
    func applyTerrainDabs() {
        guard let t = scene.terrain, var stroke = terrain.stroke else { return }
        let now = CACurrentMediaTime()
        // Held still: the airbrush, at its rate (not a ramp, which acts once).
        if terrain.pendingDabs.isEmpty, !stroke.brush.tool.actsOnRelease, now - terrain.lastDab > 1 / max(Double(stroke.brush.airbrush), 0.1),
           let hit = terrain.hoverHit {
            terrain.pendingDabs.append(TerrainDab(center: SIMD2(hit.x, hit.z), amount: stroke.brush.pressure ? terrain.pressure : 1))
            terrain.lastDab = now
        }
        guard !terrain.pendingDabs.isEmpty else { return }
        let dabs = terrain.pendingDabs, brush = stroke.brush
        terrain.pendingDabs = []
        var record = terrain.record
        t.field.edit { s in
            var touched = Set<SIMD2<Int>>()
            for d in dabs {
                switch brush.tool {
                case .protect, .unprotect:
                    touched.formUnion(TerrainSculpt.protect(&s, brush: brush, dab: d, on: brush.tool == .protect, record: &record))
                case .paint, .erase:
                    touched.formUnion(TerrainPaint.dab(&s, brush: brush, dab: d, layers: TerrainDocuments.shared.document(t.name)?.layers,
                                                       record: &record))
                case .erode, .crumble, .stamp:
                    touched.formUnion(TerrainErosion.brush(&s, brush: brush, dab: d, document: TerrainDocuments.shared.document(t.name),
                                                           record: &record))
                default:
                    touched.formUnion(TerrainSculpt.dab(&s, brush: brush, dab: d, stroke: stroke, record: &record))
                }
            }
            return touched
        }
        terrain.record = record
        stroke.lastHeight = Float(terrain.hoverHit?.y ?? Double(stroke.lastHeight))
        terrain.stroke = stroke
    }

    /// The stroke done: what it changed is kept for undo, and what stands on it follows it.
    func finishTerrainStroke() {
        if let s = terrain.stroke, s.path.count > 1 { terrain.lastStroke = s.path }
        defer { terrain.stroke = nil; terrain.record = TerrainUndoRecord() }
        guard let t = scene.terrain, !terrain.record.before.isEmpty else { return }
        var record = terrain.record
        let s = t.field.snapshot()
        for tile in record.before.keys { record.after[tile] = .some(s.tiles[tile]) }
        keepTerrainRecord(record)
        terrainMoved(Set(record.before.keys))
    }

    /// The ground of these tiles changed (a stroke, an undo, a job): the scatter rules' things there placed again and
    /// what stands on it moved with it; the open world's trees (its tiles' groups) made again with the scene.
    func terrainMoved(_ tiles: Set<SIMD2<Int>>) {
        guard let t = scene.terrain, !tiles.isEmpty else { return }
        let grid = t.field.grid
        let corners = tiles.flatMap { [grid.corner($0), grid.corner($0 &+ 1)] }
        let lo = corners.reduce(SIMD2(Double.infinity, .infinity), simd_min), hi = corners.reduce(SIMD2(-Double.infinity, -.infinity), simd_max)
        scene.rescatter(lo: lo, hi: hi)
        if scene.worldPlace != nil { settings.scene.terrainKey = UUID().uuidString }
        // Lumen's distance fields of the sectors there (their triangles as they are now, in the background).
        if lumenTracesFields {
            let s = t.field.snapshot()
            let parts = t.parts.filter { p in tiles.contains { max(abs($0.x - p.sector.tile.x), abs($0.y - p.sector.tile.y)) <= 1 } }
            rebakeLumenFields(parts.map { p in
                let m = TerrainSectorMesh(s, sector: p.sector, style: t.meshStyle)
                return (p.mesh, m.positions, m.indices)
            })
        }
    }

    /// A change kept for undo (a stroke, a generator's run, an import): its id goes to the window's undo manager.
    func keepTerrainRecord(_ record: TerrainUndoRecord) {
        let id = terrain.nextRecord
        terrain.nextRecord += 1
        terrain.records[id] = record
        terrain.order.append(id)
        terrain.unreported.append(id)
        var bytes = terrain.records.values.reduce(0) { $0 + $1.bytes }
        while bytes > TerrainGPU.undoBudget, terrain.order.count > 1 {
            let oldest = terrain.order.removeFirst()
            bytes -= terrain.records[oldest]?.bytes ?? 0
            terrain.records[oldest] = nil
        }
        reportTerrain()
    }

    /// Undo (`undo`) or redo change `id`.
    func undoTerrain(_ id: Int, undo: Bool) {
        guard let t = scene.terrain, let record = terrain.records[id] else { return }
        t.field.restore(undo ? record.before : record.after)
        terrainMoved(Set(record.before.keys))
    }

    // MARK: - A frame's work

    /// The sectors the field's edits changed since their buffers were written: meshed again (as many as the budget
    /// allows, the nearest the brush first), their bytes staged for the GPU to copy over the old. Their structures are
    /// built again by the caller (Renderer.encodeTerrain).
    func prepareTerrainFrame(slot: Int, buffers: SceneBuffers) -> TerrainFrameWork? {
        guard let t = scene.terrain else { return nil }
        applyTerrainDabs()
        adoptTerrainDocument(t)
        let field = t.field, revision = field.revision
        guard revision != terrain.checked || terrain.backlog else { return nil }
        let start = CACurrentMediaTime()
        let s = field.snapshot()
        var dirty: [(part: Int, revision: Int)] = []
        for (k, p) in t.parts.enumerated() {
            let r = s.revision(around: p.sector)
            if terrain.built[p.name]?.revision != r { dirty.append((k, r)) }
        }
        terrain.checked = revision
        guard !dirty.isEmpty else { terrain.backlog = false; return nil }
        // Nearest the brush (or the camera) first.
        let focus = terrain.hoverHit.map { SIMD2($0.x, $0.z) } ?? SIMD2(t.world(camera.position).x, t.world(camera.position).z)
        let grid = field.grid
        func distance(_ k: Int) -> Double {
            let sector = t.parts[k].sector
            let c = grid.place(sector.first.x + sector.cells.x * sector.step / 2, sector.first.y + sector.cells.y * sector.step / 2)
            return simd_distance(c, focus)
        }
        dirty.sort { distance($0.part) < distance($1.part) }
        let chosen = Array(dirty.prefix(TerrainGPU.budget))
        terrain.backlog = dirty.count > chosen.count
        var meshes = [TerrainSectorMesh?](repeating: nil, count: chosen.count)
        meshes.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: chosen.count) { k in
                out[k] = TerrainSectorMesh(s, sector: t.parts[chosen[k].part].sector, style: t.meshStyle)
            }
        }
        // Their bytes, one after another in the slot's staging buffer.
        let sizes = meshes.map { ($0?.byteCount ?? 0 + 255) & ~255 }, total = sizes.reduce(0, +)
        while terrain.staging.count <= slot { terrain.staging.append(nil) }
        if (terrain.staging[slot]?.length ?? 0) < total {
            terrain.staging[slot] = device.makeBuffer(length: max(total, 1 << 20), options: .storageModeShared)
            terrain.staging[slot]?.label = "terrain staging \(slot)"
        }
        guard let staging = terrain.staging[slot] else { return nil }
        var work = TerrainFrameWork(), offset = 0
        for (k, c) in chosen.enumerated() {
            let part = t.parts[c.part]
            guard let m = meshes[k], part.mesh < buffers.blocks.count, let block = buffers.blocks[part.mesh],
                  m.byteCount <= block.geometry.length else { continue }
            m.write(into: staging.contents() + offset)
            work.copies.append(BufferCopy(source: staging, sourceOffset: offset, destination: block.geometry, destinationOffset: 0, size: m.byteCount))
            work.meshes.append(part.mesh)
            work.instances.append(part.instance)
            work.bounds.append((part.mesh, m.bounds))
            terrain.built[part.name] = (ObjectIdentifier(block), c.revision)
            offset += sizes[k]
        }
        // The colliders of the sectors meshed again: their heights; the bodies woken (the ground moved under them).
        if let physics = scene.physics, !t.colliders.isEmpty {
            var moved = false
            for c in chosen {
                guard let k = t.colliders[c.part] else { continue }
                physics.updateHeightfield(k, heights: t.colliderHeights(t.parts[c.part], s).heights)
                moved = true
            }
            if moved {
                physics.wakeAll()
                physicsGPUForTerrain?.refreshStatics(physics)
            }
        }
        terrain.lastBuilt = work.meshes.count
        terrain.lastCPU = (CACurrentMediaTime() - start) * 1000
        if TerrainGPU.log {
            print(String(format: "Terrain: %d of %d sectors meshed again, %.2f ms on the CPU", work.meshes.count, dirty.count, terrain.lastCPU))
        }
        reportTerrain()
        return work
    }

    /// The document's edits (its layers' rules, colours, sizes) into the scene: the sectors' weights made again, the
    /// layer table and the plain layers' materials rewritten. (A layer's Material Designer graph changed makes the
    /// scene again: TerrainModel.)
    func adoptTerrainDocument(_ t: SceneTerrain) {
        let version = TerrainDocuments.shared.version(t.name)
        guard version != terrain.documentVersion else { return }
        let first = terrain.documentVersion < 0
        terrain.documentVersion = version
        // Its water's looks, as they are now (a look's edit doesn't make the scene again).
        // (The document's bodies come first; the scene's own water after them keeps its looks.)
        if let doc = TerrainDocuments.shared.document(t.name), let w = scene.water, w.bodyLooks.count == doc.water.count + t.generatedWater.count {
            var changed = false
            for (k, body) in doc.water.enumerated() {
                guard let l = w.bodyLooks[k], l < w.looks.count, w.looks[l] != body.appearance else { continue }
                w.looks[l] = body.appearance
                changed = true
            }
            if changed { water?.setLooks(w.looks) }
        }
        guard !first, let doc = TerrainDocuments.shared.document(t.name), doc.layers != t.meshStyle.layers else { return }
        t.meshStyle.layers = doc.layers
        for (name, b) in terrain.built { terrain.built[name] = (b.block, -1) }   // every sector meshed again
        terrain.backlog = true
        if t.table >= 0, t.table + TerrainTile.layers <= scene.proceduralParams.count {
            let table = SceneTerrain.table(doc.layers, firstLayer: t.firstLayer, offset: t.offset)
            scene.proceduralParams.replaceSubrange(t.table..<(t.table + table.count), with: table)
            scene.proceduralParamsVersion += 1
        }
        for l in 1..<min(doc.layers.count, TerrainTile.layers) where doc.layers[l].material.isEmpty && doc.layers[l].builtIn == nil {
            var m = scene.materials[t.firstLayer + l - 1]
            m.albedo = SIMD4(doc.layers[l].color / FoliageTextures.mean, 0)
            m.emission.w = doc.layers[l].roughness
            scene.setMaterial(t.firstLayer + l - 1, m)
        }
    }

    /// A stroke through places of the world (x, z): the 2D map's, a script's.
    func terrainStrokeWorld(_ points: [SIMD2<Double>]) {
        guard let t = scene.terrain, let first = points.first else { return }
        let s = t.field.snapshot()
        var stroke = TerrainStroke(brush: terrain.brush, start: first, height: s.height(x: first.x, z: first.y))
        terrain.record = TerrainUndoRecord(title: terrain.brush.tool.title)
        if !terrain.brush.tool.actsOnRelease { terrain.pendingDabs += stroke.begin(pressure: 1) }
        for p in points.dropFirst() {
            let dabs = stroke.move(to: p, height: s.height(x: p.x, z: p.y), pressure: 1)
            if !terrain.brush.tool.actsOnRelease { terrain.pendingDabs += dabs }
        }
        let wasActive = terrain.active
        terrain.active = true
        terrain.stroke = stroke
        terrain.lastDab = CACurrentMediaTime()
        let last = points.last!
        terrain.hoverHit = SIMD3(last.x, Double(s.height(x: last.x, z: last.y)), last.y)
        _ = terrainMouseUp()
        terrain.active = wasActive
    }

    /// The camera over a place of the world (x, z), looking down at it from `height` metres over the ground.
    func flyTerrainCamera(to p: SIMD2<Double>, height: Float = 60) {
        guard let t = scene.terrain else { return }
        let ground = Float(t.field.snapshot().height(x: p.x, z: p.y))
        let target = t.scene(SIMD3(p.x, Double(ground), p.y))
        let back = SIMD3<Float>(sin(camera.yaw), 0, -cos(camera.yaw)) * height * 0.9
        camera.position = target - back + SIMD3(0, height, 0)
        let d = simd_normalize(target - camera.position)
        camera.pitch = asin(d.y)
        camera.yaw = atan2(d.x, -d.z)
        reportTerrain()
    }

    /// Heights from a picture over the region (TerrainIO), kept for undo.
    func importTerrainHeights(_ picture: (values: [Float], width: Int, height: Int, float: Bool), region: TerrainIO.Region,
                              mode: TerrainIO.ImportMode) {
        guard let t = scene.terrain else { return }
        var record = TerrainUndoRecord(title: "Import heightmap")
        t.field.edit { s in TerrainIO.importHeights(&s, picture: picture, region: region, mode: mode, record: &record) }
        finishTerrainRecord(record, t)
    }

    /// Layer weights from pictures over the region, kept for undo.
    func importTerrainWeights(_ pictures: [(bytes: [UInt8], width: Int, height: Int)?], region: TerrainIO.Region) {
        guard let t = scene.terrain else { return }
        var record = TerrainUndoRecord(title: "Import splat maps")
        t.field.edit { s in TerrainIO.importWeights(&s, pictures: pictures, region: region, record: &record) }
        finishTerrainRecord(record, t)
    }

    /// A change made outside a stroke (an import, a generator's run): its tiles as they now are, and kept for undo.
    func finishTerrainRecord(_ record: TerrainUndoRecord, _ t: SceneTerrain) {
        guard !record.before.isEmpty else { return }
        var record = record
        let s = t.field.snapshot()
        for tile in record.before.keys { record.after[tile] = .some(s.tiles[tile]) }
        keepTerrainRecord(record)
        terrainMoved(Set(record.before.keys))
    }

    // MARK: - Long jobs: the generator, erosion

    /// The document's generator over a region: the heights it makes replace (or are added to) the ground's, faded
    /// into the ground around the region over `border` metres. Off the render thread; kept for undo.
    func runTerrainGenerator(region: TerrainIO.Region, border: Float) {
        guard let t = scene.terrain, let doc = TerrainDocuments.shared.document(t.name) else { return }
        let stack = doc.generator, grid = t.field.grid
        runTerrainJob("Generate", region: region, border: border) { heights, size, progress in
            var made = [Float](repeating: 0, count: heights.count)
            made.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: size.y) { j in
                    for i in 0..<size.x {
                        let p = grid.place(region.lo.x + i, region.lo.y + j)
                        out[j * size.x + i] = TerrainGenerator.height(stack, x: p.x, z: p.y, ground: heights[j * size.x + i])
                    }
                }
            }
            let passes = stack.nodes.filter { $0.enabled && $0.kind == .smooth }.reduce(0) { $0 + max(Int($1.amount * 10), 1) }
            _ = progress(1)
            return passes > 0 ? TerrainGenerator.smooth(made, size.x, size.y, passes: passes) : made
        }
    }

    /// Erosion over a region, as the document's settings say. Off the render thread; kept for undo.
    func runTerrainErosion(region: TerrainIO.Region, kind: TerrainErosion.Kind, border: Float) {
        guard let t = scene.terrain, let doc = TerrainDocuments.shared.document(t.name) else { return }
        let settings = doc.erosion, cell = t.field.grid.cell
        runTerrainJob("Erode (\(kind.title.lowercased()))", region: region, border: border) { heights, size, progress in
            TerrainErosion.erode(heights: heights, size: size, cell: cell, kind: kind, settings: settings, progress: progress)
        }
    }

    /// A long job: the region's heights read now, `work` run off the render thread (told the share done; false from it
    /// stops), its heights written back on the render thread (faded over `border` metres inside the region's edge).
    /// Benchmarks wait for it.
    func runTerrainJob(_ title: String, region: TerrainIO.Region, border: Float,
                       work: @escaping ([Float], SIMD2<Int>, @escaping (Float) -> Bool) -> [Float]?) {
        guard let t = scene.terrain, terrain.job == nil else { return }
        let heights = t.field.snapshot().heights(from: region.lo, count: region.size, step: 1), field = t.field
        terrain.job = title
        terrain.progress = 0
        terrain.cancelJob = false
        reportTerrain()
        let finish: ([Float]?) -> Void = { [weak self] made in
            guard let self else { return }
            self.terrain.job = nil
            self.terrain.progress = 0
            if let made, let t = self.scene.terrain, t.field === field {
                var record = TerrainUndoRecord(title: title)
                t.field.edit { s in TerrainErosion.write(&s, made: made, lo: region.lo, hi: region.hi, border: border, record: &record) }
                self.finishTerrainRecord(record, t)
            }
            self.reportTerrain()
        }
        if benchmark != nil {
            finish(work(heights, region.size) { _ in true })
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var last: Float = 0
            let made = work(heights, region.size) { p in
                if p - last > 0.02 {
                    last = p
                    self?.perform { r in r.terrain.progress = p; r.reportTerrain() }
                }
                return !(self?.terrain.cancelJob ?? true)
            }
            self?.perform { _ in finish(made) }
        }
    }

    func cancelTerrainJob() { terrain.cancelJob = true }

    /// A river's bed carved along its line: as deep as it says under the ground, never climbing from its source to
    /// its mouth, its banks sloping out to its width and fading into the ground beyond. Kept for undo.
    func carveTerrainRiver(_ river: WaterBody) {
        guard let t = scene.terrain, river.points.count > 1 else { return }
        // Its bed from the ground as it is before the carving, kept with it in the document: its surface (the
        // ribbon, the water map) keeps to it afterwards, and carving it again digs no deeper.
        var carved = river
        carved.bed = TerrainWater.bed(t.field.snapshot(), river: river)
        carved.bedPoints = river.points
        if var d = TerrainDocuments.shared.document(t.name),
           let k = d.water.firstIndex(where: { $0.kind == .river && $0.points == river.points && $0.name == river.name }), d.water[k].bed != carved.bed {
            d.water[k].bed = carved.bed
            d.water[k].bedPoints = carved.bedPoints
            TerrainDocuments.shared.update(d)
        }
        var record = TerrainUndoRecord(title: "Carve river")
        t.field.edit { s in TerrainWater.carve(&s, river: carved, record: &record) }
        finishTerrainRecord(record, t)
    }

    // MARK: - The ring

    /// The brush's ring on the ground under the cursor: a circle of its radius following the ground, an inner one where
    /// its edge starts to fade; red while it takes away.
    func terrainRingSegments() -> [VFXGizmos.Segment] {
        guard terrain.active, let hit = terrain.hoverHit, let t = scene.terrain else { return [] }
        let s = t.field.snapshot(), b = terrain.brush
        let take = b.tool == .lower || b.tool == .erase || b.tool == .unprotect
        let colour: SIMD4<Float> = take ? [1, 0.4, 0.3, 1] : b.tool.paints ? [0.5, 0.9, 1, 1] : [1, 1, 1, 1]
        var out: [VFXGizmos.Segment] = []
        func ring(_ radius: Float, _ steps: Int, dashed: Bool, _ c: SIMD4<Float>) {
            var points: [SIMD3<Float>] = []
            for i in 0...steps {
                let a = Double(i) / Double(steps) * 2 * .pi
                let x = hit.x + cos(a) * Double(radius), z = hit.z + sin(a) * Double(radius)
                points.append(t.scene(SIMD3(x, Double(s.height(x: x, z: z)) + Double(max(radius * 0.01, 0.05)), z)))
            }
            for i in 0..<steps where !dashed || i % 2 == 0 {
                out.append(VFXGizmos.Segment(a: SIMD4(points[i], 1), b: SIMD4(points[i + 1], 1), color: c))
            }
        }
        ring(b.radius, 64, dashed: false, colour)
        ring(b.radius * max(b.hardness, 0.05), 32, dashed: true, colour * 0.6)
        // The point itself, and up its normal.
        let p = t.scene(hit)
        out.append(VFXGizmos.Segment(a: SIMD4(p, 1), b: SIMD4(p + terrain.hoverNormal * max(b.radius * 0.25, 0.5), 1), color: colour))
        return out
    }

    // MARK: - Status

    func reportTerrain() {
        var st = TerrainStatus()
        st.terrain = scene.terrain?.name
        st.active = terrain.active
        st.brush = terrain.brush
        st.hover = terrain.hoverHit
        st.slope = acos(min(max(terrain.hoverNormal.y, -1), 1)) * 180 / .pi
        st.strokes = terrain.unreported
        st.pending = terrain.backlog ? 1 : 0
        st.built = terrain.lastBuilt
        st.cpuMs = terrain.lastCPU
        st.revision = scene.terrain?.field.revision ?? 0
        st.job = terrain.job
        st.progress = (terrain.progress * 50).rounded() / 50
        if let t = scene.terrain {
            st.camera = (t.world(camera.position) / 4).rounded(.toNearestOrAwayFromZero) * 4   // (a status a few metres apart)
            st.yaw = (camera.yaw * 16).rounded() / 16
        }
        st.message = terrain.message
        guard st != terrain.statusSent else { return }
        terrain.unreported = []
        terrain.message = ""
        terrain.statusSent = st
        onTerrain?(st)
    }
}

/// A step of a scripted terrain edit (benchmarks: Benchmark.Config.Event.terrain): sculpt mode, the brush, a stroke
/// through points of the view (0...1 across and down) or of the world (x, z), a frame's wait, undo or redo of the last
/// change.
enum TerrainStep {
    case mode(Bool)
    case brush(TerrainBrush)
    case stroke([SIMD2<Float>])
    case strokeWorld([SIMD2<Double>])
    case undo
    case redo
    case wait(Int)
    /// The document's generator, or erosion, over the whole terrain (a finite one), with a border to fade over.
    case generate(GeneratorStack)
    case erode(TerrainErosion.Kind, ErosionSettings)
    case document((inout TerrainDocument) -> Void)
    /// The document's river `n` carved; the scene made again (its water's surfaces).
    case carveRiver(Int)
    case rebuild
    /// Prints how far the scattered things that show stand from where their rule puts them on the ground now.
    case checkScatter
    /// Prints the bodies' lowest points against the ground under them (deepest in it, highest over it).
    case checkBodies
}

extension Renderer {
    /// The next step of a benchmark's terrain script: settings until a stroke, which waits for its frame.
    func runTerrainScript() {
        if terrainScriptWait > 0 { terrainScriptWait -= 1; return }
        while !terrainScript.isEmpty {
            let step = terrainScript.removeFirst()
            switch step {
            case .mode(let on): setTerrainMode(on)
            case .brush(let b): setTerrainBrush(b)
            case .stroke(let points):
                guard let first = points.first else { continue }
                _ = terrainMouseDown(at: first, pressure: 1, option: false)
                for p in points.dropFirst() { _ = terrainMouseDragged(at: p, pressure: 1) }
                _ = terrainMouseUp()
                return
            case .strokeWorld(let points):
                guard let t = scene.terrain, let first = points.first else { continue }
                let s = t.field.snapshot()
                var stroke = TerrainStroke(brush: terrain.brush, start: first, height: s.height(x: first.x, z: first.y))
                terrain.record = TerrainUndoRecord(title: terrain.brush.tool.title)
                terrain.stroke = stroke
                if !terrain.brush.tool.actsOnRelease { terrain.pendingDabs += stroke.begin(pressure: 1) }
                for p in points.dropFirst() {
                    let dabs = stroke.move(to: p, height: s.height(x: p.x, z: p.y), pressure: 1)
                    if !terrain.brush.tool.actsOnRelease { terrain.pendingDabs += dabs }
                }
                terrain.stroke = stroke
                terrain.lastDab = CACurrentMediaTime()
                terrain.hoverHit = SIMD3(points.last!.x, Double(s.height(x: points.last!.x, z: points.last!.y)), points.last!.y)
                _ = terrainMouseUp()
                return
            case .undo:
                if let id = terrain.order.last(where: { !terrainUndone.contains($0) }) {
                    undoTerrain(id, undo: true)
                    terrainUndone.insert(id)
                }
                return
            case .redo:
                if let id = terrain.order.first(where: { terrainUndone.contains($0) }) {
                    undoTerrain(id, undo: false)
                    terrainUndone.remove(id)
                }
                return
            case .wait(let frames):
                terrainScriptWait = max(frames - 1, 0)
                return
            case .generate(let stack):
                guard let t = scene.terrain, var d = TerrainDocuments.shared.document(t.name),
                      let region = TerrainIO.Region.of(t.field.grid, tiles: []) else { continue }
                d.generator = stack
                TerrainDocuments.shared.update(d)
                runTerrainGenerator(region: region, border: 0)
                return
            case .erode(let kind, let settings):
                guard let t = scene.terrain, var d = TerrainDocuments.shared.document(t.name),
                      let region = TerrainIO.Region.of(t.field.grid, tiles: []) else { continue }
                d.erosion = settings
                TerrainDocuments.shared.update(d)
                runTerrainErosion(region: region, kind: kind, border: 0)
                return
            case .document(let change):
                guard let t = scene.terrain, var d = TerrainDocuments.shared.document(t.name) else { continue }
                change(&d)
                TerrainDocuments.shared.update(d)
            case .carveRiver(let n):
                guard let t = scene.terrain, let d = TerrainDocuments.shared.document(t.name), d.water.indices.contains(n) else { continue }
                carveTerrainRiver(d.water[n])
                return
            case .rebuild:
                settings.scene.terrainKey = UUID().uuidString
                return
            case .checkBodies:
                guard let t = scene.terrain, let physics = scene.physics else { continue }
                let s = t.field.snapshot()
                var deepest: Float = 0, highest: Float = -.infinity, resting = 0
                for b in physics.bodies.indices {
                    let i = Int(physics.bodies[b].info.z)
                    guard scene.instances.indices.contains(i) else { continue }
                    let inst = scene.instances[i], box = AABB(lo: scene.localBounds(of: inst).0, hi: scene.localBounds(of: inst).1).transformed(inst.transform)
                    let c = (box.lo + box.hi) / 2, w = t.world(c)
                    let gap = box.lo.y - s.height(x: w.x, z: w.z)
                    deepest = min(deepest, gap)
                    highest = max(highest, gap)
                    if gap < 0.3 { resting += 1 }
                }
                print(String(format: "Terrain bodies: %d of %d on the ground, deepest %.3f m into it, highest %.3f m over it", resting,
                             physics.bodies.count, deepest, highest))
            case .checkScatter:
                guard let t = scene.terrain, let sc = t.scatter else { continue }
                let s = t.field.snapshot()
                var shown = 0, worst: Float = 0
                for slot in sc.slots {
                    guard let i = slot.instances.first, scene.instances[i].transform.columns.0.x > 1e-3 || scene.instances[i].transform.columns.0.z > 1e-3
                    else { continue }
                    let c = slot.candidate, rule = sc.rules[c.rule]
                    let want = s.height(x: c.x, z: c.z) - rule.sink * c.size
                    let has = (scene.instances[i] .transform * slot.relative[0].inverse).columns.3.y
                    worst = max(worst, abs(has - want))
                    shown += 1
                }
                let anchored = sc.anchors.map { a -> Float in
                    abs(scene.instances[a.instance].transform.columns.3.y - (s.height(x: a.place.x, z: a.place.y) + a.lift))
                }.max() ?? 0
                print(String(format: "Terrain scatter: %d of %d shown, %.4f m off the ground at most; %d anchored, %.4f m off",
                             shown, sc.slots.count, worst, sc.anchors.count, anchored))
            }
        }
    }
}
