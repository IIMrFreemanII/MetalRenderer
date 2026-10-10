import MetalKit
import SwiftUI
import simd

/// The Material Designer's two views of a bake: the 2D view (a node's image, tiled or not, one channel or all, its
/// exposure) and the 3D preview (the graph's material on a sphere, cube, cylinder or plane, lit by a key light and a sky,
/// with parallax and opacity; drag to turn it). Small forward renderers of their own (not the path tracer: the
/// material workshop is that), drawn when what they show changes.
enum MatPreviewShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct View2D { float4 params; uint4 mode; };   // params: tiles, exposure, zoom, aspect; mode: channel, grey
    struct V2 { float4 position [[position]]; float2 uv; };

    vertex V2 matView2DVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        V2 o;
        o.position = float4(p * 2.0 - 1.0, 0, 1);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 matView2DFragment(V2 in [[stage_in]], texture2d<float> image [[texture(0)]], constant View2D& v [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::repeat);
        float2 uv = (in.uv - 0.5) * float2(v.params.w, 1.0) / v.params.z * v.params.x + 0.5 * v.params.x;
        bool inside = v.params.x > 1.0 || all(uv >= 0.0 && uv <= 1.0);
        float2 cell = floor(in.position.xy / 8.0);
        float3 checker = fmod(cell.x + cell.y, 2.0) == 0.0 ? float3(0.16) : float3(0.22);
        if (!inside) return float4(checker * 0.6, 1);
        float4 c = image.sample(s, uv);
        if (v.mode.y != 0) c = float4(c.rrr, 1);
        switch (v.mode.x) {
            case 1: c = float4(c.rrr, 1); break;
            case 2: c = float4(c.ggg, 1); break;
            case 3: c = float4(c.bbb, 1); break;
            case 4: c = float4(c.aaa, 1); break;
            default: break;
        }
        float3 rgb = c.rgb * v.params.y;
        return float4(mix(checker, rgb, saturate(c.a)), 1);
    }

    struct Vertex3D { float3 position; float3 normal; float4 tangent; float2 uv; };
    struct View3D {
        float4x4 viewProj;
        float4 eye;          // xyz; w = parallax depth
        float4 light;        // xyz toward the key light; w = its strength
        float4 surface;      // x = UV scale, y = cutoff, z = AO strength, w = emissive intensity
        uint4 has;           // base, orm, normal, emissive | height, opacity, normal strength (bits), -
    };
    struct V3 { float4 position [[position]]; float3 world; float3 normal; float4 tangent; float2 uv; };

    vertex V3 matView3DVertex(uint id [[vertex_id]], device const Vertex3D* vs [[buffer(0)]], constant View3D& v [[buffer(1)]]) {
        Vertex3D x = vs[id];
        V3 o;
        o.position = v.viewProj * float4(x.position, 1);
        o.world = x.position;
        o.normal = x.normal;
        o.tangent = x.tangent;
        o.uv = x.uv;
        return o;
    }

    inline float3 linearOf(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

    inline float3 sky(float3 d) {
        float t = saturate(d.y * 0.5 + 0.5);
        return mix(float3(0.06, 0.055, 0.05), mix(float3(0.35, 0.37, 0.4), float3(0.55, 0.65, 0.85), saturate(d.y)), smoothstep(0.35, 0.55, t));
    }

    fragment float4 matView3DFragment(V3 in [[stage_in]], constant View3D& v [[buffer(1)]],
                                      texture2d<float> base [[texture(0)]], texture2d<float> orm [[texture(1)]],
                                      texture2d<float> nmap [[texture(2)]], texture2d<float> emis [[texture(3)]],
                                      texture2d<float> height [[texture(4)]], texture2d<float> opacity [[texture(5)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
        float3 N = normalize(in.normal), T = normalize(in.tangent.xyz - N * dot(N, in.tangent.xyz));
        float3 B = cross(N, T) * in.tangent.w;
        float3 V = normalize(v.eye.xyz - in.world);
        float2 uv = in.uv * v.surface.x;
        if (v.has.y & 1u && v.eye.w > 0.0) {   // parallax: as the renderer's (Surface.metal parallaxUV)
            float3 t = float3(dot(V, T), dot(V, B), max(dot(V, N), 0.08));
            int steps = int(mix(32.0, 8.0, saturate(t.z)));
            float layer = 1.0 / float(steps);
            float2 shift = t.xy / t.z * v.eye.w * layer;
            float2 at = uv;
            float d = 0, h = height.sample(s, at).r, ph = h, pd = 0;
            for (int i = 0; i < steps && d < 1.0 - h; ++i) { ph = h; pd = d; at -= shift; d += layer; h = height.sample(s, at).r; }
            float after = (1.0 - h) - d, before = (1.0 - ph) - pd;
            uv = mix(at, at + shift, saturate(after / min(after - before, -1e-6)));
        }
        if (v.has.y & 2u && opacity.sample(s, uv).r < v.surface.y) discard_fragment();
        float3 albedo = v.has.x & 1u ? linearOf(base.sample(s, uv).rgb) : float3(0.5);
        float3 m = v.has.x & 2u ? orm.sample(s, uv).rgb : float3(1, 0.5, 0);
        float ao = mix(1.0, m.r, v.surface.z), rough = max(m.g, 0.04), metal = m.b;
        if (v.has.x & 4u) {
            float3 t = nmap.sample(s, uv).xyz * 2.0 - 1.0;   // the renderer's convention: +Y along +V
            t.xy *= as_type<float>(v.has.z);
            N = normalize(T * t.x + B * t.y + N * max(t.z, 1e-3));
        }
        float3 L = normalize(v.light.xyz), H = normalize(L + V);
        float NoL = saturate(dot(N, L)), NoV = max(dot(N, V), 1e-3), NoH = saturate(dot(N, H)), VoH = saturate(dot(V, H));
        float a = rough * rough, a2 = a * a;
        float D = a2 / (3.14159 * pow(NoH * NoH * (a2 - 1.0) + 1.0, 2.0));
        float k = a * 0.5, G = NoV / (NoV * (1 - k) + k) * NoL / (NoL * (1 - k) + k + 1e-4);
        float3 F0 = mix(float3(0.04), albedo, metal);
        float3 F = F0 + (1.0 - F0) * pow(1.0 - VoH, 5.0);
        float3 spec = D * G * F / max(4.0 * NoV * NoL, 1e-3);
        float3 diffuse = albedo * (1.0 - metal) / 3.14159;
        float3 color = (diffuse + spec) * NoL * v.light.w;
        float3 R = reflect(-V, N);
        float3 Fv = F0 + (max(float3(1.0 - rough), F0) - F0) * pow(1.0 - NoV, 5.0);
        color += (albedo * (1.0 - metal) * sky(N) + Fv * sky(R) * (1.0 - rough * 0.7)) * ao;
        if (v.has.x & 8u) color += linearOf(emis.sample(s, uv).rgb) * v.surface.w;
        color = color / (1.0 + color);   // tone map
        return float4(pow(color, 1.0 / 2.2), 1);
    }
    """

    static func library(_ device: MTLDevice) -> MTLLibrary? {
        if let l = libraries[ObjectIdentifier(device)] { return l }
        let l = try? device.makeLibrary(source: source, options: nil)
        libraries[ObjectIdentifier(device)] = l
        return l
    }
    private static var libraries: [ObjectIdentifier: MTLLibrary] = [:]
}

// MARK: - 2D view

struct Mat2DSettings: Equatable {
    var tiles: Float = 1
    var channel = 0      // all, R, G, B, A
    var exposure: Float = 1
    var zoom: Float = 1
}

struct Mat2DView: NSViewRepresentable {
    let device: MTLDevice
    let texture: MTLTexture?
    let grey: Bool
    let settings: Mat2DSettings

    func makeCoordinator() -> Renderer2D { Renderer2D(device) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.texture = texture
        context.coordinator.grey = grey
        context.coordinator.settings = settings
        v.setNeedsDisplay(v.bounds)
    }

    final class Renderer2D: NSObject, MTKViewDelegate {
        let queue: MTLCommandQueue?
        let state: MTLRenderPipelineState?
        var texture: MTLTexture?
        var grey = false
        var settings = Mat2DSettings()

        init(_ device: MTLDevice) {
            queue = device.makeCommandQueue()
            let d = MTLRenderPipelineDescriptor()
            let lib = MatPreviewShaders.library(device)
            d.vertexFunction = lib?.makeFunction(name: "matView2DVertex")
            d.fragmentFunction = lib?.makeFunction(name: "matView2DFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            state = try? device.makeRenderPipelineState(descriptor: d)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let state, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let cb = queue?.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            if let texture {
                enc.setRenderPipelineState(state)
                let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
                var p = (SIMD4<Float>(settings.tiles, settings.exposure, settings.zoom, aspect), SIMD4<UInt32>(UInt32(settings.channel), grey ? 1 : 0, 0, 0))
                enc.setFragmentBytes(&p, length: 32, index: 0)
                enc.setFragmentTexture(texture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}

// MARK: - 3D preview

enum MatPreviewShape: String, CaseIterable {
    case sphere, cube, cylinder, plane
    var title: String { rawValue.capitalized }
}

struct Mat3DView: NSViewRepresentable {
    let device: MTLDevice
    let outputs: MatOutputs?
    let shape: MatPreviewShape
    let turn: SIMD2<Float>

    func makeCoordinator() -> Renderer3D { Renderer3D(device) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.sampleCount = 4
        v.clearColor = MTLClearColor(red: 0.12, green: 0.125, blue: 0.135, alpha: 1)
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.outputs = outputs
        context.coordinator.shape = shape
        context.coordinator.turn = turn
        v.setNeedsDisplay(v.bounds)
    }

    final class Renderer3D: NSObject, MTKViewDelegate {
        let device: MTLDevice
        let queue: MTLCommandQueue?
        let state: MTLRenderPipelineState?
        let depth: MTLDepthStencilState?
        var outputs: MatOutputs?
        var shape = MatPreviewShape.sphere
        var turn = SIMD2<Float>(0.6, 0.35)
        private var meshes: [MatPreviewShape: (buffer: MTLBuffer, count: Int)] = [:]
        private let blank: MTLTexture?

        init(_ device: MTLDevice) {
            self.device = device
            queue = device.makeCommandQueue()
            let lib = MatPreviewShaders.library(device)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib?.makeFunction(name: "matView3DVertex")
            d.fragmentFunction = lib?.makeFunction(name: "matView3DFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = 4
            state = try? device.makeRenderPipelineState(descriptor: d)
            let ds = MTLDepthStencilDescriptor()
            ds.depthCompareFunction = .less
            ds.isDepthWriteEnabled = true
            depth = device.makeDepthStencilState(descriptor: ds)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            blank = device.makeTexture(descriptor: td)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let state, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let cb = queue?.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass),
                  let mesh = mesh(shape) else { return }
            enc.setRenderPipelineState(state)
            enc.setDepthStencilState(depth)
            let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let dist: Float = shape == .plane ? 2.6 : 3.2
            let eye = SIMD3<Float>(cos(turn.y) * sin(turn.x), sin(turn.y), cos(turn.y) * cos(turn.x)) * dist
            let view4 = MatPreview.lookAt(eye, .zero, [0, 1, 0])
            let proj = MatPreview.perspective(fovy: 0.7, aspect: aspect, near: 0.05, far: 50)
            let o = outputs, s = o?.surface ?? MatSurface()
            func bit(_ t: MTLTexture?, _ b: UInt32) -> UInt32 { t != nil ? b : 0 }
            var u = (proj * view4, SIMD4<Float>(eye, o?.height != nil ? s.heightDepth : 0), SIMD4<Float>(normalize(SIMD3<Float>(-0.5, 0.8, 0.6)), 3),
                     SIMD4<Float>(s.uvScale, s.alphaCutoff, o?.orm != nil ? s.aoStrength : 0, s.emissiveIntensity),
                     SIMD4<UInt32>(bit(o?.baseColor, 1) | bit(o?.orm, 2) | bit(o?.normal, 4) | bit(o?.emissive, 8),
                                   bit(o?.height, 1) | bit(o?.opacity, 2), s.normalStrength.bitPattern, 0))
            enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
            for (i, t) in [o?.baseColor, o?.orm, o?.normal, o?.emissive, o?.height, o?.opacity].enumerated() {
                enc.setFragmentTexture(t ?? blank, index: i)
            }
            enc.setCullMode(shape == .plane ? .none : .back)
            enc.setFrontFacing(.counterClockwise)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }

        /// A shape's triangles (positions, normals, tangents with their handedness, UVs), as the workshop's.
        private func mesh(_ shape: MatPreviewShape) -> (buffer: MTLBuffer, count: Int)? {
            if let m = meshes[shape] { return m }
            let (g, uvs): (MeshGeometry, [SIMD2<Float>])
            switch shape {
            case .sphere: (g, uvs) = (Scene.uvSphere(rings: 32, segments: 64), Scene.uvSphereUVs(rings: 32, segments: 64))
            case .cube:
                var b = MeshBuilder()
                Scene.tiledBox(&b, half: 0.75)
                (g, uvs) = (b.geometry, b.uvs)
            case .cylinder:
                let (cg, cu) = Scene.uvCylinder(radius: 0.7, height: 1.6, segments: 64)
                (g, uvs) = ((cg.positions.map { $0 - [0, 0.8, 0] }, cg.normals, cg.indices), cu)
            case .plane:
                (g, uvs) = (([[-1, 0, -1], [1, 0, -1], [1, 0, 1], [-1, 0, 1]], [[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]], [0, 2, 1, 0, 3, 2]),
                            [[0, 0], [2, 0], [2, 2], [0, 2]])
            }
            let tangents = MatPreview.tangents(g, uvs)
            var verts: [Float] = []
            for i in g.indices {
                let k = Int(i), p = g.positions[k], n = g.normals[k], t = tangents[k], uv = uvs[k]
                verts += [p.x, p.y, p.z, 0, n.x, n.y, n.z, 0, t.x, t.y, t.z, t.w, uv.x, uv.y, 0, 0]
            }
            guard let buffer = device.makeBuffer(bytes: verts, length: verts.count * 4) else { return nil }
            meshes[shape] = (buffer, g.indices.count)
            return meshes[shape]
        }
    }
}

enum MatPreview {
    static func lookAt(_ eye: SIMD3<Float>, _ at: SIMD3<Float>, _ up: SIMD3<Float>) -> float4x4 {
        let f = normalize(at - eye), s = normalize(cross(f, up)), u = cross(s, f)
        return float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                  SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
    }

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovy / 2), x = y / aspect, z = far / (near - far)
        return float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// Per vertex: the direction of +U along the surface, and w the handedness that makes cross(N, T) × w point
    /// along +V (as the renderer's frame from the triangles' UVs).
    static func tangents(_ g: MeshGeometry, _ uvs: [SIMD2<Float>]) -> [SIMD4<Float>] {
        var t = [SIMD3<Float>](repeating: .zero, count: g.positions.count), b = t
        for k in stride(from: 0, to: g.indices.count, by: 3) {
            let i0 = Int(g.indices[k]), i1 = Int(g.indices[k + 1]), i2 = Int(g.indices[k + 2])
            let e1 = g.positions[i1] - g.positions[i0], e2 = g.positions[i2] - g.positions[i0]
            let d1 = uvs[i1] - uvs[i0], d2 = uvs[i2] - uvs[i0]
            let det = d1.x * d2.y - d1.y * d2.x
            guard abs(det) > 1e-12 else { continue }
            let tt = (e1 * d2.y - e2 * d1.y) / det, bb = (e2 * d1.x - e1 * d2.x) / det
            for i in [i0, i1, i2] { t[i] += tt; b[i] += bb }
        }
        return g.positions.indices.map { i in
            let n = g.normals[i]
            var tt = t[i] - n * dot(n, t[i])
            if length_squared(tt) < 1e-12 { tt = abs(n.y) < 0.9 ? cross([0, 1, 0], n) : cross([1, 0, 0], n) }
            tt = normalize(tt)
            let w: Float = dot(cross(n, tt), b[i]) < 0 ? -1 : 1
            return SIMD4(tt, w)
        }
    }
}
