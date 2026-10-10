import CoreGraphics
import Foundation
import Metal
import MetalKit
import simd

/// How a click paints in paint mode: a stroke of the brush, or a fill of the triangles it names.
enum PaintTool: String, Codable, CaseIterable, Identifiable {
    case brush, fillObject, fillIsland, fillPolygon, fillMaterial
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brush: return "Brush"
        case .fillObject: return "Fill object"
        case .fillIsland: return "Fill UV island"
        case .fillPolygon: return "Fill polygon"
        case .fillMaterial: return "Fill material"
        }
    }
}

/// What the painter's window shows of the renderer's side (sent with every change, on the main thread).
struct PainterStatus: Equatable {
    struct Object: Equatable {
        var index: Int
        var instance: Int
        var document: String
        var resolution: Int
        var triangles: Int
        var charts: Int
        var ownUVs: Bool
        var baked: Bool
    }
    var objects: [Object] = []
    var active: Int?
    /// Strokes kept for undo since the last status (their ids, in order).
    var strokes: [Int] = []
    /// The active object's layout (its corners' UVs, 3 a triangle; at most 60k triangles of it), for the 2D view.
    var wireframe: [SIMD2<Float>] = []
    var message = ""
}

/// The Material Painter's state in the renderer: per painted object of the scene (Scene.painted, by its index there)
/// its session (PainterSession: texture set, layers, strokes), the brush's stamps and stencil, and paint mode (which
/// object the main view paints, with what).
final class PainterGPU {
    var sessions: [Int: PainterSession] = [:]
    /// The sessions whose texture sets are in their slots, and the document version their materials' values follow.
    var installed: [Int: Int] = [:]
    let stamps = PaintStamps()
    var stencil: (key: String, texture: MTLTexture)?
    /// Paint mode: the painted object (its index in Scene.painted) the main view paints, the layer and what of it,
    /// the brush, the tool; the stroke under way's dabs.
    var active: Int?
    var layer: UUID?
    var target = PaintTarget.channels([.color, .roughness, .metallic])
    var brush = PaintBrush()
    var tool = PaintTool.brush
    var strokeDabs: PaintStrokeDabs?
    var orbitDrag = false
    /// Where the cursor is (0...1 across and down) and the pen's pressure; what is under it (the object's own
    /// triangles, as it was made: its bind pose).
    var hover: SIMD2<Float>?
    var pressure: Float = 1
    var hoverHit: (position: SIMD3<Float>, normal: SIMD3<Float>, triangle: Int)?
    /// The view's size in points (a brush's size is in them).
    var viewPoints = SIMD2<Float>(1280, 800)
    /// Something painted this frame (the reference picture starts over).
    var changed = false
    /// The strokes kept for undo, by id, and those not yet reported.
    var records: [Int: (session: Int, record: PainterSession.UndoRecord)] = [:]
    var nextRecord = 1
    var unreported: [Int] = []
    var statusSent: PainterStatus?
    var message = ""
    /// The objects' meshes (bind pose, their own space), for the cursor's rays and the fills.
    var meshes: [Int: PaintMesh] = [:]
    /// The sets exported (METALRENDERER_PAINTER_EXPORT).
    var exported: Set<Int> = []

    func sceneChanged() {
        sessions = [:]
        installed = [:]
        strokeDabs = nil
        hoverHit = nil
        active = nil
        records = [:]
        unreported = []
        meshes = [:]
        statusSent = nil
        exported = []
    }
}

extension Renderer {
    /// The scene's painted objects: a session each (its texel map made now), its texture set given its slots once,
    /// and its document as the painter has it (a new version: composited again).
    func updatePainted() {
        guard !scene.painted.isEmpty else { return }
        let docs = PaintDocuments.shared
        for (k, object) in scene.painted.enumerated() {
            let doc = docs.document(object.document)
            if painter.sessions[k] == nil {
                guard let s = PainterSession(device: device, object: object, document: doc) else { continue }
                let args = s.objectArgs(transform: scene.instances[object.instance].transform, scene: scene)
                let first = object.firstTriangle, count = Int(scene.meshes[object.mesh].indexCount) / 3
                let offsets = (0..<count).map { t -> UInt8 in first + t < scene.triangleMaterials.count ? scene.triangleMaterials[first + t] : 0 }
                do {
                    try s.prepare(queue: queue, args: args, indices: sceneBuffers.indices, positions: sceneBuffers.positions,
                                  normals: sceneBuffers.normals, offsets: offsets)
                } catch {
                    print("Painter: \(object.document) isn't painted: \(error)")
                    continue
                }
                PainterPixels.load(s, document: doc)
                painter.sessions[k] = s
                painter.meshes[k] = PaintMesh(scene: scene, mesh: object.mesh)
            }
            guard let s = painter.sessions[k] else { continue }
            s.sync(doc, version: docs.version(object.document))
            if s.document.layers.contains(where: { $0.mask?.generator != nil }) && s.bake == nil, let mesh = painter.meshes[k] {
                bakePainted(k, s, mesh)
            }
            regenerateMasks(s)
            if painter.installed[k] != s.documentVersion {
                installPainted(k, s)
                painter.installed[k] = s.documentVersion
            }
            // METALRENDERER_PAINTER_EXPORT=<folder>: each set as it first is, into the folder (and the texel map's charts).
            if let folder = Renderer.painterExport, s.composited, !painter.exported.contains(k) {
                painter.exported.insert(k)
                let name = "\(PaintDocument.slug(object.document))-\(scene.settings.painterWorkshop.subject.rawValue)-\(k)"
                try? PainterPixels.export(s, to: URL(fileURLWithPath: folder), name: name, format: .png8, device: device, queue: queue)
            }
        }
        reportPainter()
    }

    static let painterExport = ProcessInfo.processInfo.environment["METALRENDERER_PAINTER_EXPORT"]

    /// Painted object `k`'s texture set in its slots, and its materials' values as its document says.
    private func installPainted(_ k: Int, _ s: PainterSession) {
        let object = scene.painted[k], d = s.document
        let slots = object.slots
        installTexture(srgbView(s.base), slot: slots[ProcSlot.baseColor.rawValue])
        installTexture(s.orm, slot: slots[ProcSlot.orm.rawValue])
        installTexture(s.normal, slot: slots[ProcSlot.normal.rawValue])
        installTexture(srgbView(s.emissive), slot: slots[ProcSlot.emissive.rawValue])
        installTexture(s.height, slot: slots[ProcSlot.height.rawValue])
        installTexture(s.opacity, slot: slots[ProcSlot.opacity.rawValue])
        let texelsPerMetre = object.atlas.texelsPerMetre > 0 ? object.atlas.texelsPerMetre : Float(s.size)
        for (i, m) in object.materials.enumerated() {
            var mat = scene.materials[m]
            mat.textures = SIMD4(slots[ProcSlot.baseColor.rawValue], slots[ProcSlot.orm.rawValue], slots[ProcSlot.normal.rawValue],
                                 object.emissive ? slots[ProcSlot.emissive.rawValue] : .max)
            mat.albedo = SIMD4(1, 1, 1, 1)
            mat.emission = SIMD4(object.emissive ? SIMD3(repeating: d.emissiveIntensity) : .zero, 1)
            mat.params = SIMD4(1, d.normalStrength, 0, object.originals[i].params.w)
            scene.setMaterial(m, mat)
            var e = scene.materialExtras[m] ?? GPUMaterialExtra()
            // Parallax in UV units: the height's metres over the set's (texels per metre / its side).
            let parallax = d.parallax ? 2 * d.heightDepth * texelsPerMetre / Float(s.size) : 0
            e.textures.x = parallax > 0 ? slots[ProcSlot.height.rawValue] : .max
            e.textures.y = object.opacity ? slots[ProcSlot.opacity.rawValue] : .max
            e.surface = SIMD4(parallax, 1, d.alphaCutoff, s.occlusion != nil ? d.aoStrength : 0)
            if scene.materialExtras[m] != e {
                scene.materialExtras[m] = e
                scene.extrasVersion += 1
            }
        }
    }

    /// This frame's painting: each session's strokes, undo, composite (Paint.metal), ahead of the frame's shading.
    func encodePainting(passes: FrameEncoder) {
        guard !painter.sessions.isEmpty, let targets = renderTargetsForPainter else { return }
        let catalog = MaterialCatalog.resolve(scene.settings.materials)
        for (k, s) in painter.sessions {
            let object = scene.painted[k]
            let transform = scene.instances[object.instance].transform
            let painting = painter.active == k
            s.mirror = painting ? UInt32(painter.brush.symmetry.rawValue) : 0
            let view = painting ? paintView(targets: targets) : nil
            let busy = !s.dirty.isEmpty || !s.pendingDabs.isEmpty || s.pendingFill != nil || !s.pendingUndo.isEmpty
            s.encode(passes, scene: scene, transform: transform, sceneTextures: materialTexturesForPainter, indices: sceneBuffers.indices,
                     positions: sceneBuffers.positions, normals: sceneBuffers.normals, uvs: sceneBuffers.uvs, view: view,
                     surfacePos: targets.surfacePos, stamps: painter.stamps.array(device), stencil: painterStencil(),
                     catalog: catalog, now: benchmark != nil)
            if busy { painter.changed = true }
        }
        if painter.changed {
            painter.changed = false
            resetReferenceForPainting()
        }
    }

    /// The view the dabs are drawn in: the camera's projection onto the render's pixels (unjittered), and how far a
    /// texel's point may be from what the render shows at its pixel (a few pixels' width, per metre of depth).
    private func paintView(targets: RenderTargets) -> PaintDabArgs {
        let w = Float(targets.width), h = Float(targets.height)
        let t = tan(camera.fovY / 2), aspect = w / max(h, 1)
        let r = camera.right / (t * aspect), u = camera.up / t, f = camera.forward
        let p = camera.position
        var v = PaintDabArgs()
        v.viewProjection = float4x4(rows: [SIMD4(r, -dot(r, p)), SIMD4(u, -dot(u, p)), SIMD4(0, 0, 0, 0), SIMD4(f, -dot(f, p))])
        v.camera = SIMD4(p, 0)
        v.screen = SIMD2(w, h)
        v.tolerance = max(6 * 2 * t / max(h, 1), 0.002)
        v.stencilFrame = painter.brush.stencil.frame(screen: v.screen)
        return v
    }

    /// The stencil's picture (a file, or a graph's base colour), made once per what it names.
    private func painterStencil() -> MTLTexture? {
        let st = painter.brush.stencil
        guard st.enabled, !st.image.isEmpty else { return nil }
        if let s = painter.stencil, s.key == st.image { return s.texture }
        var made: MTLTexture?
        if st.image.hasPrefix("graph:") {
            let name = String(st.image.dropFirst(6))
            let catalog = MaterialCatalog.resolve(scene.settings.materials)
            if let g = catalog.graph(name) {
                let bake = MaterialBake.shared(device)
                let key = MaterialBake.key(g, catalog: catalog)
                made = (bake.baked(key) ?? bake.bakeNow(g, key: key, catalog: catalog))?.baseColor
            }
        } else {
            made = try? MTKTextureLoader(device: device).newTexture(URL: URL(fileURLWithPath: st.image), options: [.SRGB: false])
        }
        guard let made else { return nil }
        painter.stencil = (st.image, made)
        return made
    }

    // MARK: - Bakes and generated masks

    /// The object's mesh maps (PaintBake), now (they take a moment: the window says so).
    private func bakePainted(_ k: Int, _ s: PainterSession, _ mesh: PaintMesh) {
        guard let map = s.texelMap else { return }
        let start = CACurrentMediaTime()
        s.bake = PaintBake(mesh: mesh, map: map, size: s.size, device: device, queue: queue)
        s.occlusion = s.bake?.occlusion
        s.invalidate()
        painter.installed[k] = nil   // its occlusion's strength
        print(String(format: "Painter: %@'s mesh maps baked in %.0f ms (%d px, %d rays)", s.object.document, (CACurrentMediaTime() - start) * 1000,
                     s.size, PaintBake.rays))
    }

    /// Each layer's generated mask, made again when its generator changed (a graph mask: the graph baked with the
    /// object's mesh maps as its inputs).
    private func regenerateMasks(_ s: PainterSession) {
        guard let bake = s.bake, let map = s.texelMap else { return }
        for layer in s.document.layers {
            guard let g = layer.mask?.generator, let t = s.layers[layer.id], t.generatedFrom != g else { continue }
            if t.generated == nil {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: s.size, height: s.size, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                t.generated = device.makeTexture(descriptor: d)
            }
            guard let out = t.generated else { continue }
            var graph: MTLTexture?
            if g.kind == .graph, !g.graph.isEmpty {
                let catalog = MaterialCatalog.resolve(scene.settings.materials)
                graph = PaintMeshMaps.bake(graph: g.graph, catalog: catalog, maps: bake, size: s.size, device: device)
            }
            bake.generate(g, into: out, map: map, graph: graph, queue: queue, device: device)
            t.generatedFrom = g
            s.invalidate()
        }
    }

    // MARK: - Paint mode

    /// Paint mode on painted object `index` (nil: off): the camera orbits it, left drags paint it.
    func setPaintMode(_ index: Int?) {
        painter.active = index.flatMap { scene.painted.indices.contains($0) ? $0 : nil }
        painter.strokeDabs = nil
        if let k = painter.active {
            let object = scene.painted[k]
            let (lo, hi) = scene.meshBounds(object.mesh)
            let t = scene.instances[object.instance].transform
            let c = t * SIMD4((lo + hi) / 2, 1)
            let centre = SIMD3(c.x, c.y, c.z)
            orbitForPainter = (centre, max(simd_distance(camera.position, centre), 0.5))
            lookAtForPainter(centre)
            // A deforming object (a character's pose slot): its tiles measured as it stands now (dabs are culled by them).
            if scene.instances[object.instance].deforms, let s = painter.sessions[k] {
                try? s.measureTiles(queue: queue, args: s.objectArgs(transform: t, scene: scene), indices: sceneBuffers.indices,
                                    positions: sceneBuffers.positions, normals: sceneBuffers.normals)
            }
        }
        reportPainter()
    }

    /// The brush, the layer it paints and what of it, the tool (the painter's window's, as they change).
    func setPainterBrush(_ brush: PaintBrush, layer: UUID?, target: PaintTarget, tool: PaintTool) {
        painter.brush = brush
        painter.layer = layer
        painter.target = target
        painter.tool = tool
    }

    /// A press in paint mode: a stroke begins (or a fill is made) on the active object, or (right button, Option) the
    /// camera turns about it. False: not paint mode.
    func paintMouseDown(at cursor: SIMD2<Float>, pressure: Float, orbit: Bool) -> Bool {
        guard let k = painter.active, let s = painter.sessions[k] else { return false }
        painter.hover = cursor
        painter.pressure = pressure
        if orbit { painter.orbitDrag = true; return true }
        guard let layer = painter.layer ?? s.document.layers.last(where: { $0.kind == .paint })?.id else {
            painter.message = "Add a paint layer to paint on"
            reportPainter()
            return true
        }
        let b = painter.brush
        let paintTarget: PaintTarget
        if case .channels = painter.target, s.document.layers.first(where: { $0.id == layer })?.kind != .paint {
            paintTarget = .mask   // a fill layer is painted through its mask
        } else {
            paintTarget = painter.target
        }
        switch painter.tool {
        case .brush:
            s.beginStroke(layer: layer, target: paintTarget, values: b.values, erase: b.eraser, stencil: b.stencil.enabled)
            var dabs = PaintStrokeDabs(brush: b, scale: renderPixelsPerPoint)
            s.pendingDabs += dabs.move(to: cursor * renderSizeForPainter, pressure: pressure)
            painter.strokeDabs = dabs
        default:
            guard let hit = painterRay(cursor, k) else { return true }
            s.beginStroke(layer: layer, target: paintTarget, values: b.values, erase: b.eraser, stencil: false)
            s.pendingFill = fillSelection(k, from: hit.triangle)
            s.endStroke()
        }
        return true
    }

    func paintMouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>, pressure: Float) -> Bool {
        guard let k = painter.active, let s = painter.sessions[k] else { return false }
        painter.hover = cursor
        painter.pressure = pressure
        if painter.orbitDrag {
            camera.yaw += dx * 0.004
            camera.pitch = min(max(camera.pitch - dy * 0.004, -1.5), 1.5)
            placeOrbitForPainter()
            return true
        }
        if var dabs = painter.strokeDabs {
            s.pendingDabs += dabs.move(to: cursor * renderSizeForPainter, pressure: pressure)
            painter.strokeDabs = dabs
        }
        updateHover(k)
        return true
    }

    func paintMouseUp() -> Bool {
        guard let k = painter.active, let s = painter.sessions[k] else { return false }
        painter.orbitDrag = false
        if painter.strokeDabs != nil {
            s.endStroke()
            painter.strokeDabs = nil
        }
        return true
    }

    /// The cursor over the view (no button): the brush's ring follows it.
    func paintMouseMoved(at cursor: SIMD2<Float>) {
        guard let k = painter.active else { return }
        painter.hover = cursor
        updateHover(k)
    }

    /// The brush larger (`step` > 0) or smaller.
    func resizeBrush(_ step: Int) {
        painter.brush.size = min(max(painter.brush.size * (step > 0 ? 1.15 : 1 / 1.15), 1), 1000)
        reportPainter()
    }

    private func updateHover(_ k: Int) {
        guard let c = painter.hover, let hit = painterRay(c, k) else { painter.hoverHit = nil; return }
        painter.hoverHit = hit
    }

    /// The ray through `cursor` against object `k`'s triangles (as it was made, moved where its instance is): the
    /// nearest hit's world point, normal and triangle.
    func painterRay(_ cursor: SIMD2<Float>, _ k: Int) -> (position: SIMD3<Float>, normal: SIMD3<Float>, triangle: Int)? {
        guard let mesh = painter.meshes[k] else { return nil }
        let object = scene.painted[k]
        let t = scene.instances[object.instance].transform, inv = t.inverse
        let dir = cursorRayForPainter(cursor)
        let o4 = inv * SIMD4(camera.position, 1), d4 = inv * SIMD4(dir, 0)
        let o = SIMD3(o4.x, o4.y, o4.z), d = SIMD3(d4.x, d4.y, d4.z)
        var best: (Float, Int) = (.infinity, -1)
        for tri in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.corners(tri)
            let p0 = mesh.positions[a], e1 = mesh.positions[b] - p0, e2 = mesh.positions[c] - p0
            let pv = simd_cross(d, e2), det = simd_dot(e1, pv)
            guard abs(det) > 1e-12 else { continue }
            let inv = 1 / det, tv = o - p0
            let u = simd_dot(tv, pv) * inv
            guard u >= 0, u <= 1 else { continue }
            let qv = simd_cross(tv, e1), v = simd_dot(d, qv) * inv
            guard v >= 0, u + v <= 1 else { continue }
            let dist = simd_dot(e2, qv) * inv
            if dist > 1e-5 && dist < best.0 { best = (dist, tri) }
        }
        guard best.1 >= 0 else { return nil }
        let (a, b, c) = mesh.corners(best.1)
        let n = simd_normalize(simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a]))
        let p = o + d * best.0
        let wp = t * SIMD4(p, 1), wn = t.inverse.transpose * SIMD4(n, 0)
        return (SIMD3(wp.x, wp.y, wp.z), simd_normalize(SIMD3(wn.x, wn.y, wn.z)), best.1)
    }

    /// The triangles a fill paints, from the one clicked: all of them, its UV island, its polygon (the triangles
    /// joined to it that lie in its plane), or those of its material.
    private func fillSelection(_ k: Int, from tri: Int) -> [UInt8] {
        let object = scene.painted[k]
        let n = object.atlas.chartOfTriangle.count
        var out = [UInt8](repeating: 0, count: n)
        switch painter.tool {
        case .fillObject, .brush:
            out = [UInt8](repeating: 1, count: n)
        case .fillIsland:
            let chart = object.atlas.chartOfTriangle[tri]
            for t in 0..<n where object.atlas.chartOfTriangle[t] == chart { out[t] = 1 }
        case .fillMaterial:
            let first = object.firstTriangle
            let m = first + tri < scene.triangleMaterials.count ? scene.triangleMaterials[first + tri] : 0
            for t in 0..<n where (first + t < scene.triangleMaterials.count ? scene.triangleMaterials[first + t] : 0) == m { out[t] = 1 }
        case .fillPolygon:
            guard let mesh = painter.meshes[k] else { break }
            let (weld, _) = mesh.welded()
            let adj = mesh.adjacency(weld)
            func normal(_ t: Int) -> SIMD3<Float> {
                let (a, b, c) = mesh.corners(t)
                let cr = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
                return simd_length(cr) > 0 ? simd_normalize(cr) : .zero
            }
            let n0 = normal(tri)
            var stack = [tri]
            out[tri] = 1
            while let t = stack.popLast() {
                for j in Int(adj.start[t])..<Int(adj.start[t + 1]) {
                    let u = Int(adj.next[j])
                    if out[u] == 0 && simd_dot(normal(u), n0) > 0.996 { out[u] = 1; stack.append(u) }
                }
            }
        }
        return out
    }

    /// The brush's ring where the cursor meets the active object: a circle of its size on the surface's plane.
    func painterRingSegments() -> [VFXGizmos.Segment] {
        guard let hit = painter.hoverHit, painter.active != nil, let targets = renderTargetsForPainter else { return [] }
        let depth = max(simd_dot(hit.position - camera.position, camera.forward), 0.01)
        let pixels = painter.brush.size * renderPixelsPerPoint
        let radius = pixels * 2 * tan(camera.fovY / 2) * depth / Float(max(targets.height, 1))
        let n = hit.normal
        let tAxis = simd_normalize(abs(n.y) < 0.9 ? simd_cross(n, [0, 1, 0]) : simd_cross(n, [1, 0, 0])), bAxis = simd_cross(n, tAxis)
        let colour = painter.brush.eraser ? SIMD4<Float>(1, 0.4, 0.3, 1) : SIMD4<Float>(1, 1, 1, 1)
        var out: [VFXGizmos.Segment] = []
        let steps = 48
        for i in 0..<steps {
            let a0 = Float(i) / Float(steps) * 2 * .pi, a1 = Float(i + 1) / Float(steps) * 2 * .pi
            let p0 = hit.position + n * radius * 0.02 + (tAxis * cos(a0) + bAxis * sin(a0)) * radius
            let p1 = hit.position + n * radius * 0.02 + (tAxis * cos(a1) + bAxis * sin(a1)) * radius
            out.append(VFXGizmos.Segment(a: SIMD4(p0, 1), b: SIMD4(p1, 1), color: colour))
        }
        // The hardness: an inner ring.
        let inner = radius * max(painter.brush.hardness, 0.05)
        for i in stride(from: 0, to: steps, by: 2) {
            let a0 = Float(i) / Float(steps) * 2 * .pi, a1 = Float(i + 1) / Float(steps) * 2 * .pi
            out.append(VFXGizmos.Segment(a: SIMD4(hit.position + (tAxis * cos(a0) + bAxis * sin(a0)) * inner, 1),
                                         b: SIMD4(hit.position + (tAxis * cos(a1) + bAxis * sin(a1)) * inner, 1), color: colour * 0.6))
        }
        return out
    }

    // MARK: - Undo, saving, export, pictures

    /// Strokes kept since the last report get ids (the window's undo manager registers them).
    private func collectStrokes() {
        for (k, s) in painter.sessions {
            s.onStrokeRecorded = { [weak painter] record in
                guard let painter else { return }
                let id = painter.nextRecord
                painter.nextRecord += 1
                painter.records[id] = (k, record)
                painter.unreported.append(id)
            }
        }
    }

    /// Undo (`undo`) or redo stroke `id`.
    func undoPaintStroke(_ id: Int, undo: Bool) {
        guard let (k, record) = painter.records[id], let s = painter.sessions[k] else { return }
        s.undo(record, undo: undo)
    }

    /// Saves painted object `k`'s pixels into its document's package (the document's JSON is the window's to write).
    func savePainted(_ k: Int) -> String? {
        guard let s = painter.sessions[k], let package = PainterStore.package(s.document.name) else { return "nothing to save" }
        do {
            try PainterPixels.save(s, to: package, device: device, queue: queue)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Exports painted object `k`'s texture set (and its mesh as GLB, unwrapped) into `folder`.
    func exportPainted(_ k: Int, to folder: URL, format: MatExport.Format) -> String? {
        guard let s = painter.sessions[k], let mesh = painter.meshes[k] else { return "nothing to export" }
        do {
            let name = PaintDocument.slug(s.document.name)
            try PainterPixels.export(s, to: folder, name: name, format: format, device: device, queue: queue)
            try GLBWriter.write(mesh, corners: s.object.atlas.corners, name: name, to: folder.appendingPathComponent(name + ".glb"))
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// A channel of painted object `k`'s texture set (or a layer's channel), `side` squared, as a picture.
    func painterPicture(_ k: Int, output: String, layer: UUID? = nil, side: Int) -> CGImage? {
        guard let s = painter.sessions[k] else { return nil }
        let t: MTLTexture?
        if let layer {
            let lt = s.layers[layer]
            t = lt?.channels[.color] ?? lt?.channels.values.first ?? lt?.mask ?? lt?.generated
        } else {
            switch output {
            case "orm": t = s.orm
            case "normal": t = s.normal
            case "height": t = s.height
            case "emissive": t = s.emissive
            case "opacity": t = s.opacity
            case "occlusion": t = s.bake?.occlusion
            case "curvature": t = s.bake?.curvature
            case "thickness": t = s.bake?.thickness
            default: t = s.base
            }
        }
        guard let t else { return nil }
        return PainterPixels.picture(t, side: side, device: device, queue: queue)
    }

    /// The window's view of the painter: the painted objects, the active one, new strokes (sent when it changed).
    func reportPainter() {
        collectStrokes()
        var st = PainterStatus()
        st.objects = scene.painted.enumerated().map { k, o in
            PainterStatus.Object(index: k, instance: o.instance, document: o.document, resolution: o.resolution,
                                 triangles: o.atlas.chartOfTriangle.count, charts: o.atlas.chartCount, ownUVs: o.atlas.own,
                                 baked: painter.sessions[k]?.bake != nil)
        }
        st.active = painter.active
        st.strokes = painter.unreported
        st.message = painter.message
        if let k = painter.active ?? (scene.painted.isEmpty ? nil : 0) {
            let corners = scene.painted[k].atlas.corners
            st.wireframe = corners.count <= 180_000 ? corners : []
        }
        guard st != painter.statusSent else { return }
        painter.unreported = []
        painter.message = ""
        painter.statusSent = st
        onPainter?(st)
    }
}

/// A step of a scripted painting (benchmarks: Benchmark.Config.Event.paint): paint mode on, the brush and what it
/// paints (the document's layer by index, its mask or its channels), a stroke through points (0...1 across and down
/// the view), a fill where a point meets the object, or nothing for a frame.
enum PainterStep {
    case mode(Int?)
    case brush(PaintBrush, layer: Int, mask: Bool, tool: PaintTool)
    case stroke([SIMD2<Float>])
    case fill(SIMD2<Float>)
    case wait
}

extension Renderer {
    /// The next step of a benchmark's painting: settings until a stroke or a fill, which waits for its frame.
    func runPainterScript() {
        while !painterScript.isEmpty {
            let step = painterScript.removeFirst()
            switch step {
            case .mode(let k):
                painter.active = k.flatMap { scene.painted.indices.contains($0) ? $0 : nil }
                if let a = painter.active, painter.meshes[a] == nil { painter.meshes[a] = PaintMesh(scene: scene, mesh: scene.painted[a].mesh) }
            case .brush(let b, let layer, let mask, let tool):
                let id = painter.active.flatMap { painter.sessions[$0] }.flatMap { s in s.document.layers.indices.contains(layer) ? s.document.layers[layer].id : nil }
                setPainterBrush(b, layer: id, target: mask ? .mask : .channels(b.channels), tool: tool)
            case .stroke(let points):
                guard let first = points.first else { continue }
                _ = paintMouseDown(at: first, pressure: 1, orbit: false)
                for p in points.dropFirst() { _ = paintMouseDragged(dx: 0, dy: 0, at: p, pressure: 1) }
                _ = paintMouseUp()
                return
            case .fill(let p):
                _ = paintMouseDown(at: p, pressure: 1, orbit: false)
                _ = paintMouseUp()
                return
            case .wait:
                return
            }
        }
    }
}
