import AppKit
import MetalKit
import SwiftUI
import simd

/// The cone tree in 3D (ConeTreeLayout's places), drawn with Metal: each node a disc facing the camera, sized and coloured
/// as in the 2D graph, nearer ones in front; the tree's links and the references as lines (dashed by kind); a faint disc
/// under each level. It turns slowly until it is touched; a drag turns it, scroll pans, pinch zooms (the canvas's pan and
/// zoom), a click selects, a double-click opens. Names over it for what is selected, hovered and the biggest near ones.
struct ConeTreeView: View {
    @ObservedObject var model: ProjectGraphModel
    @StateObject private var orbit = ConeOrbit()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ConeMetalView(model: model, orbit: orbit)
                Canvas { ctx, size in labels(&ctx, size) }
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(drag(geo.size))
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    model.hover = p
                    let id = pick(p, geo.size).map { model.visible.nodes[$0].id }
                    if id != model.hovered { model.hovered = id }
                }
            }
            .onAppear { model.canvasSize = geo.size; model.canvasOrigin = geo.frame(in: .global).origin; orbit.start() }
            .onDisappear { orbit.stop() }
            .onChange(of: geo.frame(in: .global)) { f in model.canvasSize = f.size; model.canvasOrigin = f.origin }
        }
        .background(GraphColors.canvas)
    }

    /// Where shown node `k` is on the view, and how big (points); nil behind the camera.
    private func project(_ size: CGSize) -> [(p: CGPoint, r: CGFloat, depth: Float)?] {
        let cam = orbit.camera(model, aspect: Float(size.width / max(size.height, 1)))
        return model.cone.indices.map { k in
            let v = cam.view * SIMD4(model.cone[k], 1)
            guard v.z < -0.1 else { return nil }
            let c = cam.projection * v
            let ndc = SIMD2(c.x, c.y) / c.w
            let r = CGFloat(model.radii.indices.contains(k) ? model.radii[k] : 6) * CGFloat(cam.projection[1][1] / -v.z) * size.height / 2
            return (CGPoint(x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height), r, -v.z)
        }
    }

    private func pick(_ at: CGPoint, _ size: CGSize) -> Int? {
        var best: (k: Int, d: CGFloat)?
        for (k, s) in project(size).enumerated() {
            guard let s else { continue }
            let d = hypot(s.p.x - at.x, s.p.y - at.y)
            if d < max(s.r, 6) + 2, best.map({ d < $0.d }) ?? true { best = (k, d) }
        }
        return best?.k
    }

    private func labels(_ ctx: inout GraphicsContext, _ size: CGSize) {
        _ = orbit.tick   // redraw while it turns
        let shown = project(size)
        var candidates: [(k: Int, r: CGFloat)] = []
        for (k, s) in shown.enumerated() {
            guard let s, model.visible.nodes.indices.contains(k) else { continue }
            let id = model.visible.nodes[k].id
            if model.selection.contains(id) || id == model.hovered || s.r > 9 { candidates.append((k, model.selection.contains(id) || id == model.hovered ? 1e6 : s.r)) }
        }
        for (k, _) in candidates.sorted(by: { $0.r > $1.r }).prefix(160) {
            guard let s = shown[k] else { continue }
            let id = model.visible.nodes[k].id
            var name = model.name(id)
            if name.count > 26 { name = String(name.prefix(24)) + "…" }
            let selected = model.selection.contains(id)
            ctx.draw(Text(name).font(.system(size: selected ? 12 : 10.5, weight: selected ? .semibold : .regular)).foregroundColor(GraphColors.text),
                     at: CGPoint(x: s.p.x, y: s.p.y + s.r + 8))
        }
    }

    @State private var dragging: (start: SIMD2<Float>, moved: Bool)?
    @State private var lastClick: (id: String, at: Date)?

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                model.focusCanvas?()
                orbit.touched = true
                if dragging == nil { dragging = (SIMD2(orbit.yaw, orbit.pitch), false) }
                guard let d = dragging, hypot(g.translation.width, g.translation.height) > 3 else { return }
                dragging = (d.start, true)
                orbit.yaw = d.start.x - Float(g.translation.width) * 0.008
                orbit.pitch = min(max(d.start.y + Float(g.translation.height) * 0.006, -1.45), 1.45)
            }
            .onEnded { g in
                defer { dragging = nil }
                guard dragging?.moved != true else { return }
                guard let k = pick(g.location, size) else { model.clearSelection(); return }
                let id = model.visible.nodes[k].id
                if let last = lastClick, last.id == id, Date().timeIntervalSince(last.at) < 0.35 {
                    lastClick = nil
                    model.activate(id)
                } else {
                    lastClick = (id, Date())
                    model.click(id, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
                }
            }
    }
}

/// The 3D view's camera: turning about the tree's middle, `model.zoom` nearer, `model.pan` moving it across the view.
final class ConeOrbit: ObservableObject {
    @Published var yaw: Float = 0.6
    @Published var pitch: Float = 0.45
    @Published private(set) var tick = 0
    /// Turns by itself until someone drags it.
    var touched = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.touched { self.yaw += 0.004 }
            self.tick &+= 1
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    struct Matrices {
        var view: float4x4
        var projection: float4x4
        var eye: SIMD3<Float>
    }

    func camera(_ model: ProjectGraphModel, aspect: Float) -> Matrices {
        var lo = SIMD3<Float>(repeating: 0), hi = SIMD3<Float>(repeating: 0)
        if let first = model.cone.first {
            lo = first; hi = first
            for p in model.cone { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        }
        let centre = (lo + hi) / 2, radius = max(length(hi - lo) / 2, 100)
        let distance = radius * 2.4 / Float(max(model.zoom, 0.03))
        let dir = SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        let eye = centre + dir * distance
        var view = ConeOrbit.lookAt(eye, centre)
        // The canvas's pan (points from its middle) moves the picture across.
        let shift = SIMD2(Float(model.pan.x - model.canvasSize.width / 2), Float(model.pan.y - model.canvasSize.height / 2))
        let perPoint = distance * 2 * tan(0.5 * 0.9) / Float(max(model.canvasSize.height, 1))
        view = float4x4(translationBy: SIMD3(shift.x * perPoint, -shift.y * perPoint, 0)) * view
        let projection = ConeOrbit.perspective(fovY: 0.9, aspect: aspect, near: max(distance * 0.01, 1), far: distance * 6)
        return Matrices(view: view, projection: projection, eye: eye)
    }

    static func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> float4x4 {
        let f = normalize(target - eye), s = normalize(cross(f, [0, 1, 0])), u = cross(s, f)
        return float4x4(SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                        SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return float4x4(SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0))
    }
}

extension float4x4 {
    package init(translationBy t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
}

private struct ConeMetalView: NSViewRepresentable {
    @ObservedObject var model: ProjectGraphModel
    @ObservedObject var orbit: ConeOrbit

    func makeCoordinator() -> ConeTreeRenderer? {
        guard let device = model.host.metalDevice ?? MTLCreateSystemDefaultDevice() else { return nil }
        return ConeTreeRenderer(device: device)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.colorPixelFormat = ConeTreeRenderer.colorFormat
        view.depthStencilPixelFormat = ConeTreeRenderer.depthFormat
        view.sampleCount = ConeTreeRenderer.samples
        view.clearColor = MTLClearColor(red: 0.105, green: 0.11, blue: 0.122, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        context.coordinator?.source = { [weak model, weak orbit] in
            guard let model, let orbit else { return nil }
            return ConeTreeRenderer.Scene(model, orbit: orbit)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Draws the cone tree (ConeTreeView's): the discs instanced, the lines as a list. Its shaders are its own, compiled
/// from source here.
final class ConeTreeRenderer: NSObject, MTKViewDelegate {
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float
    static let samples = 4

    /// What a frame draws.
    struct Scene {
        /// MSL Disc and LineVertex: all float4s, so both sides lay them out alike.
        struct Disc {
            var positionRadius: SIMD4<Float>
            var color: SIMD4<Float>
            var ring: SIMD4<Float>
            package init(position: SIMD3<Float>, radius: Float, color: SIMD4<Float>, ring: SIMD4<Float>) {
                positionRadius = SIMD4(position, radius)
                self.color = color
                self.ring = ring
            }
        }
        struct Vertex {
            var positionAlong: SIMD4<Float>
            var color: SIMD4<Float>
            var dash: SIMD4<Float>
            package init(position: SIMD3<Float>, along: Float, color: SIMD4<Float>, dash: SIMD2<Float>) {
                positionAlong = SIMD4(position, along)
                self.color = color
                self.dash = SIMD4(dash.x, dash.y, 0, 0)
            }
        }
        var discs: [Disc] = []
        var lines: [Vertex] = []
        var levels: [Disc] = []
        var view = matrix_identity_float4x4
        var projection = matrix_identity_float4x4

        package init(discs: [Disc], lines: [Vertex], levels: [Disc], view: float4x4, projection: float4x4) {
            (self.discs, self.lines, self.levels, self.view, self.projection) = (discs, lines, levels, view, projection)
        }

        package init(_ model: ProjectGraphModel, orbit: ConeOrbit, aspect: Float? = nil) {
            let v = model.visible, pos = model.cone, radii = model.radii
            guard pos.count == v.nodes.count, radii.count == v.nodes.count else { return }
            let cam = orbit.camera(model, aspect: aspect ?? Float(model.canvasSize.width / max(model.canvasSize.height, 1)))
            view = cam.view
            projection = cam.projection
            func rgba(_ c: Color, _ a: Float = 1) -> SIMD4<Float> {
                let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
                return SIMD4(Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent), a)
            }
            var focusLit: Set<Int> = []
            if let f = model.focus, let k = v.index[f] {
                focusLit = [k]
                for e in v.edges where e.a == k || e.b == k { focusLit.insert(e.a); focusLit.insert(e.b) }
                focusLit.formUnion(v.children[k])
                if v.nodes[k].parent >= 0 { focusLit.insert(v.nodes[k].parent) }
            }
            for (k, n) in v.nodes.enumerated() {
                let node = model.graph.nodes[n.node]
                let kind: ProjectGraph.Kind = n.member != nil ? .member : node.kind
                var color = rgba(ProjectGraphStyle.color(kind, asset: node.asset?.kind))
                if node.hidden || (!focusLit.isEmpty && !focusLit.contains(k)) { color.w = 0.35 }
                let selected = model.selection.contains(n.id)
                discs.append(Disc(position: pos[k], radius: radii[k], color: color,
                                  ring: selected ? rgba(GraphColors.selected) : n.id == model.hovered ? SIMD4(1, 1, 1, 0.9) : .zero))
                if n.parent >= 0 {
                    let c = rgba(ProjectGraphStyle.color(.child), focusLit.contains(k) && focusLit.contains(n.parent) ? 0.7 : 0.3)
                    lines.append(Vertex(position: pos[n.parent], along: 0, color: c, dash: .zero))
                    lines.append(Vertex(position: pos[k], along: 0, color: c, dash: .zero))
                }
            }
            for e in v.edges where model.edgeKinds.contains(e.kind) && e.kind != .child {
                let lit = focusLit.contains(e.a) && focusLit.contains(e.b)
                let c = rgba(ProjectGraphStyle.color(e.kind), focusLit.isEmpty ? 0.6 : lit ? 1 : 0.18)
                let pattern = ProjectGraphStyle.dash(e.kind)
                let dash = pattern.isEmpty ? SIMD2<Float>.zero : SIMD2(Float(pattern[0] + pattern[1]) * 2.5, Float(pattern[0]) * 2.5)
                let length = simd_distance(pos[e.a], pos[e.b])
                lines.append(Vertex(position: pos[e.a], along: 0, color: c, dash: dash))
                lines.append(Vertex(position: pos[e.b], along: length, color: c, dash: dash))
            }
            // A faint disc under each level: where its nodes are.
            var byLevel: [Float: (lo: SIMD2<Float>, hi: SIMD2<Float>)] = [:]
            for p in pos {
                let xz = SIMD2(p.x, p.z)
                byLevel[p.y] = byLevel[p.y].map { (simd_min($0.lo, xz), simd_max($0.hi, xz)) } ?? (xz, xz)
            }
            for (y, b) in byLevel where b.hi != b.lo {
                let c = (b.lo + b.hi) / 2
                levels.append(Disc(position: SIMD3(c.x, y - 2, c.y), radius: length(b.hi - b.lo) / 2 + 30, color: SIMD4(1, 1, 1, 0.025), ring: .zero))
            }
        }
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue?
    private var discPipeline: MTLRenderPipelineState?
    private var levelPipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var depthOn: MTLDepthStencilState?
    private var depthRead: MTLDepthStencilState?
    var source: (() -> Scene?)?

    package init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()
        super.init()
        do {
            let library = try device.makeLibrary(source: ConeTreeRenderer.shaders, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = ConeTreeRenderer.colorFormat
                d.depthAttachmentPixelFormat = ConeTreeRenderer.depthFormat
                d.rasterSampleCount = ConeTreeRenderer.samples
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .sourceAlpha
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            discPipeline = try pipeline("coneDiscVertex", "coneDiscFragment", blend: true)
            levelPipeline = try pipeline("coneLevelVertex", "coneLevelFragment", blend: true)
            linePipeline = try pipeline("coneLineVertex", "coneLineFragment", blend: true)
        } catch {
            print("Project Graph: the cone view's shaders don't compile: \(error)")
        }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        depthOn = device.makeDepthStencilState(descriptor: d)
        d.isDepthWriteEnabled = false
        d.depthCompareFunction = .lessEqual
        depthRead = device.makeDepthStencilState(descriptor: d)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let scene = source?(), let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue?.makeCommandBuffer() else { return }
        encode(scene, pass: pass, buffer: buffer, size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)))
        buffer.present(drawable)
        buffer.commit()
    }

    /// `scene` into `pass` (a view's, or an offscreen texture's: the tests' pictures).
    func encode(_ scene: Scene, pass: MTLRenderPassDescriptor, buffer: MTLCommandBuffer, size: SIMD2<Float>) {
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = (scene.projection * scene.view, scene.view, scene.projection, SIMD4(size.x, size.y, 0, 0))
        if let levelPipeline, !scene.levels.isEmpty {
            enc.setRenderPipelineState(levelPipeline)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 1)
            scene.levels.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.levels.count)
        }
        if let linePipeline, !scene.lines.isEmpty, let lines = device.makeBuffer(bytes: scene.lines,
                                                                                  length: scene.lines.count * MemoryLayout<Scene.Vertex>.stride) {
            enc.setRenderPipelineState(linePipeline)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBuffer(lines, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: scene.lines.count)
        }
        if let discPipeline, !scene.discs.isEmpty, let discs = device.makeBuffer(bytes: scene.discs,
                                                                                 length: scene.discs.count * MemoryLayout<Scene.Disc>.stride) {
            enc.setRenderPipelineState(discPipeline)
            enc.setDepthStencilState(depthOn)
            enc.setVertexBuffer(discs, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.discs.count)
        }
        enc.endEncoding()
    }

    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Disc { float4 positionRadius; float4 color; float4 ring; };
    struct LineVertex { float4 positionAlong; float4 color; float4 dash; };
    struct Uniforms { float4x4 viewProjection; float4x4 view; float4x4 projection; float4 size; };

    struct DiscOut { float4 position [[position]]; float2 uv; float4 color; float4 ring; float rim; };

    vertex DiscOut coneDiscVertex(uint v [[vertex_id]], uint i [[instance_id]], const device Disc *discs [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
        Disc d = discs[i];
        float2 corner = float2(v & 1 ? 1.0 : -1.0, v & 2 ? 1.0 : -1.0);
        // Facing the camera: the corner in view space, a little bigger for the selection's ring.
        float grow = d.ring.w > 0 ? 1.35 : 1.0;
        float4 p = u.view * float4(d.positionRadius.xyz, 1);
        p.xy += corner * d.positionRadius.w * grow;
        DiscOut o;
        o.position = u.projection * p;
        o.uv = corner * grow;
        o.color = d.color;
        o.ring = d.ring;
        o.rim = grow;
        return o;
    }

    fragment float4 coneDiscFragment(DiscOut in [[stage_in]]) {
        float r = length(in.uv);
        if (r > in.rim) discard_fragment();
        if (r > 1.0) return in.ring;
        // A little shading: brighter to the top left, a darker edge.
        float shade = 0.82 + 0.18 * saturate(1.0 - length(in.uv - float2(-0.35, 0.35)));
        float edge = smoothstep(0.86, 1.0, r);
        return float4(in.color.rgb * shade * (1.0 - 0.35 * edge), in.color.a);
    }

    vertex DiscOut coneLevelVertex(uint v [[vertex_id]], uint i [[instance_id]], const device Disc *discs [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
        Disc d = discs[i];
        float2 corner = float2(v & 1 ? 1.0 : -1.0, v & 2 ? 1.0 : -1.0);
        float3 p = d.positionRadius.xyz + float3(corner.x, 0, corner.y) * d.positionRadius.w;
        DiscOut o;
        o.position = u.viewProjection * float4(p, 1);
        o.uv = corner;
        o.color = d.color;
        o.ring = 0;
        o.rim = 1;
        return o;
    }

    fragment float4 coneLevelFragment(DiscOut in [[stage_in]]) {
        float r = length(in.uv);
        if (r > 1.0) discard_fragment();
        return float4(in.color.rgb, in.color.a * (1.0 - r * r) + (r > 0.985 ? 0.05 : 0.0));
    }

    struct LineOut { float4 position [[position]]; float4 color; float along; float2 dash; };

    vertex LineOut coneLineVertex(uint v [[vertex_id]], const device LineVertex *lines [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        LineVertex l = lines[v];
        LineOut o;
        o.position = u.viewProjection * float4(l.positionAlong.xyz, 1);
        o.color = l.color;
        o.along = l.positionAlong.w;
        o.dash = l.dash.xy;
        return o;
    }

    fragment float4 coneLineFragment(LineOut in [[stage_in]]) {
        if (in.dash.x > 0 && fmod(in.along, in.dash.x) > in.dash.y) discard_fragment();
        return in.color;
    }
    """
}
