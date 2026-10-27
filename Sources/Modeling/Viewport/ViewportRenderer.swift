import EngineCore
import Foundation
import Metal
import simd

/// How the viewport shades (the header's four buttons and their popover), as Blender's.
package struct ViewportShading: Equatable {
    package enum Mode: String, CaseIterable, Codable { case wireframe, solid, matcap, rendered }
    package enum ColorMode: String, CaseIterable, Codable { case material, object, single, random }
    package var mode: Mode = .solid
    package var colorMode: ColorMode = .material
    package var singleColor = SIMD3<Float>(0.8, 0.8, 0.8)
    package var matcap = 0
    package var xray = false
    package var xrayAlpha: Float = 0.5
    package var backfaceCulling = false
    package var showOutline = true
    package var faceOrientation = false
    package init() {}
}

/// What the overlay shows (the Overlays popover).
package struct ViewportOverlays: Equatable {
    package var enabled = true
    package var grid = true
    package var axes = true
    package var wireframe = false
    package var faceDots = true
    package var showCursor = true
    package var statistics = false
    package init() {}
}

/// One object to draw this frame.
package struct ViewportObjectDraw {
    package var mesh: ViewportMesh
    package var transform: float4x4
    package var color: SIMD3<Float>
    package var materialColors: [SIMD4<Float>]
    package var selected = false
    package var active = false
    /// Edit mode's overlays: the cage's edges, vertices (vertex mode) and face dots (face mode).
    package var edit = false
    package var selectMode: SelectMode = .vertex
    /// Sculpt mode: show mask and face sets.
    package var sculpt = false
    /// Drawn as its wires only, light grey, and never picked: a procedural network's template node, shown beside what
    /// it displays.
    package var template = false
    package var objectID: UInt32 = 0

    package init(mesh: ViewportMesh, transform: float4x4, color: SIMD3<Float>, materialColors: [SIMD4<Float>]) {
        self.mesh = mesh
        self.transform = transform
        self.color = color
        self.materialColors = materialColors
    }
}

/// A frame of the viewport.
package struct ViewportFrame {
    package var camera = ViewportCamera()
    package var size = SIMD2<Int>(800, 600)   // pixels
    package var pixelScale: Float = 2
    package var shading = ViewportShading()
    package var overlays = ViewportOverlays()
    package var objects: [ViewportObjectDraw] = []
    package var lines: [OverlayLine] = []
    package var cursor = SIMD3<Float>.zero
    package init() {}
}

/// The theme: Blender's default dark theme's viewport colours (sRGB hex, made linear).
package enum ViewportTheme {
    package static let background = linearColor(0x393939)
    package static let wire = linearColor(0x000000)
    package static let wireEdit = linearColor(0x000000)
    package static let objectSelected = linearColor(0xF15800)
    package static let objectActive = linearColor(0xFFAA40)
    package static let edgeSelect = linearColor(0xFFA000)
    package static let vertexSelect = linearColor(0xFF7A00)
    package static let active = linearColor(0xFFFFFF)
    package static let seam = linearColor(0xDB2512)
    package static let sharp = linearColor(0x00FFFF)
    package static let crease = linearColor(0xCC0099)
    package static let vertex = linearColor(0x000000)
    package static let faceDot = linearColor(0xFF8500)
}

/// The viewport's renderer: the meshes shaded, the floor grid, the selection outline, edit mode's cage, overlay lines;
/// and the picking pass that says what is under the cursor. Its own pipelines on the window's device; it draws only
/// when asked (nothing changes, nothing is drawn).
package final class ViewportRenderer {
    package let device: MTLDevice
    package static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    package static let depthFormat = MTLPixelFormat.depth32Float
    package static let sampleCount = 4

    private var grid: MTLRenderPipelineState
    private var mesh: MTLRenderPipelineState
    private var meshBlend: MTLRenderPipelineState
    private var objectID: MTLRenderPipelineState
    private var faceID: MTLRenderPipelineState
    private var outline: MTLRenderPipelineState
    private var edge: MTLRenderPipelineState
    private var point: MTLRenderPipelineState
    private var overlayLine: MTLRenderPipelineState
    private var edgeID: MTLRenderPipelineState
    private var pointID: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthTest: MTLDepthStencilState
    private let depthNone: MTLDepthStencilState
    private let matcaps: MTLTexture
    private var targets: (size: SIMD2<Int>, msaaColor: MTLTexture, depth: MTLTexture, ids: MTLTexture, idDepth: MTLTexture)?

    package enum Failure: Error, CustomStringConvertible {
        case shaders(String)
        package var description: String { if case .shaders(let s) = self { return s }; return "" }
    }

    /// The shaders' source: read from the package (so an edit shows when the window opens again).
    package static func shaderSource() throws -> String {
        try ShaderSource.load(SourceTree.packageRoot.appendingPathComponent("Sources/Modeling/Shaders/Viewport.metal"))
    }

    package init(device: MTLDevice) throws {
        validateViewportLayouts()
        self.device = device
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: try ViewportRenderer.shaderSource(), options: nil) } catch {
            throw Failure.shaders("\(error)")
        }
        func fn(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw Failure.shaders("no \(name)") }
            return f
        }
        func pipe(_ v: String, _ f: String, color: MTLPixelFormat = ViewportRenderer.colorFormat, samples: Int = ViewportRenderer.sampleCount, blend: Bool = false,
                  depth: Bool = true) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(v)
            d.fragmentFunction = try fn(f)
            d.colorAttachments[0].pixelFormat = color
            if blend {
                // Premultiplied alpha.
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if depth { d.depthAttachmentPixelFormat = ViewportRenderer.depthFormat }
            d.rasterSampleCount = samples
            return try device.makeRenderPipelineState(descriptor: d)
        }
        grid = try pipe("fullscreenVertex", "gridFragment", blend: true)
        mesh = try pipe("meshVertex", "meshFragment")
        meshBlend = try pipe("meshVertex", "meshFragment", blend: true)
        objectID = try pipe("meshVertex", "objectIDFragment", color: .r32Uint, samples: 1)
        faceID = try pipe("meshVertex", "faceIDFragment", color: .r32Uint, samples: 1)
        outline = try pipe("fullscreenVertex", "outlineFragment", blend: true)
        edge = try pipe("editEdgeVertex", "lineFragment", blend: true)
        point = try pipe("editPointVertex", "pointFragment", blend: true)
        overlayLine = try pipe("overlayLineVertex", "lineFragment", blend: true)
        edgeID = try pipe("edgeIDVertex", "lineIDFragment", color: .r32Uint, samples: 1)
        pointID = try pipe("pointIDVertex", "pointIDFragment", color: .r32Uint, samples: 1)
        func depthState(compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depthState(compare: .greater, write: true)
        depthTest = depthState(compare: .greaterEqual, write: false)
        depthNone = depthState(compare: .always, write: false)
        guard let m = MatCaps.texture(device) else { throw Failure.shaders("matcap texture") }
        matcaps = m
    }

    private func ensureTargets(_ size: SIMD2<Int>) -> (msaaColor: MTLTexture, depth: MTLTexture, ids: MTLTexture, idDepth: MTLTexture) {
        if let t = targets, t.size == size { return (t.msaaColor, t.depth, t.ids, t.idDepth) }
        func tex(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, memoryless: Bool) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, size.x), height: max(1, size.y), mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = memoryless ? .memoryless : .private
            return device.makeTexture(descriptor: d)!
        }
        let c = tex(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget, memoryless: true)
        let dp = tex(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget, memoryless: true)
        let ids = tex(.r32Uint, samples: 1, usage: [.renderTarget, .shaderRead], memoryless: false)
        let idd = tex(Self.depthFormat, samples: 1, usage: .renderTarget, memoryless: true)
        targets = (size, c, dp, ids, idd)
        return (c, dp, ids, idd)
    }

    private func uniforms(_ f: ViewportFrame) -> ViewUniforms {
        let aspect = Float(f.size.x) / Float(max(f.size.y, 1))
        let vp = f.camera.viewProjection(aspect: aspect)
        var u = ViewUniforms()
        u.viewProj = vp
        u.view = f.camera.viewMatrix
        u.invViewProj = vp.inverse
        u.eye = SIMD4(f.camera.eye, f.camera.orthographic ? 1 : 0)
        u.viewDir = SIMD4(f.camera.forward, Float(f.camera.gridPlane))
        u.viewport = SIMD2(Float(f.size.x), Float(f.size.y))
        u.pixelScale = f.pixelScale
        u.gridScale = 1
        u.background = ViewportTheme.background
        // Orthographic: 0.2% of the view's distance, in depth (the projection maps distance + 2 far to 0…1).
        if f.camera.orthographic { u.background.w = 0.002 * f.camera.distance / (f.camera.distance + 2 * f.camera.far) }
        u.flags = SIMD4(f.overlays.enabled && f.overlays.grid ? 1 : 0, f.overlays.enabled && f.overlays.axes ? 1 : 0, f.shading.xray ? 1 : 0, 0)
        return u
    }

    private func objectUniforms(_ o: ViewportObjectDraw, _ f: ViewportFrame, index: Int) -> ObjectUniforms {
        var u = ObjectUniforms()
        u.model = o.transform
        let m3 = float3x3(SIMD3(o.transform.columns.0.x, o.transform.columns.0.y, o.transform.columns.0.z),
                          SIMD3(o.transform.columns.1.x, o.transform.columns.1.y, o.transform.columns.1.z),
                          SIMD3(o.transform.columns.2.x, o.transform.columns.2.y, o.transform.columns.2.z)).inverse.transpose
        u.normalMatrix = float4x4(columns: (SIMD4(m3.columns.0, 0), SIMD4(m3.columns.1, 0), SIMD4(m3.columns.2, 0), SIMD4(0, 0, 0, 1)))
        let s = f.shading
        var color = o.color
        switch s.colorMode {
        case .single: color = s.singleColor
        case .random:
            var h = UInt32(truncatingIfNeeded: o.objectID &* 2654435761)
            h ^= h >> 15
            color = SIMD3(Float(h & 255), Float((h >> 8) & 255), Float((h >> 16) & 255)) / 255 * 0.6 + 0.3
        default: break
        }
        let alpha: Float = s.xray ? s.xrayAlpha : 1
        u.color = SIMD4(color, alpha)
        u.wire = o.selected ? (o.active ? ViewportTheme.objectActive : ViewportTheme.objectSelected) : ViewportTheme.wire
        u.shading = s.mode == .matcap ? 1 : 0
        u.matcap = UInt32(s.matcap)
        u.objectID = UInt32(index)
        var flags: UInt32 = 0
        if o.selected { flags |= ObjectUniforms.Flag.selected }
        if o.active { flags |= ObjectUniforms.Flag.active }
        if o.edit { flags |= ObjectUniforms.Flag.edit }
        if o.sculpt { flags |= ObjectUniforms.Flag.sculpt }
        if s.colorMode == .material && !o.materialColors.isEmpty { flags |= ObjectUniforms.Flag.materialColors }
        if s.backfaceCulling { flags |= ObjectUniforms.Flag.backfaceCull }
        if s.faceOrientation && f.overlays.enabled { flags |= ObjectUniforms.Flag.faceOrientation }
        u.flags = flags
        return u
    }

    private static let themeColors: [SIMD4<Float>] = [
        ViewportTheme.wireEdit, ViewportTheme.edgeSelect, ViewportTheme.seam, ViewportTheme.sharp, ViewportTheme.crease, ViewportTheme.active,
    ]
    private static let pointTheme: [SIMD4<Float>] = [
        ViewportTheme.vertex, ViewportTheme.vertexSelect, ViewportTheme.seam, ViewportTheme.sharp, ViewportTheme.crease, ViewportTheme.active,
    ]
    private static let dotTheme: [SIMD4<Float>] = [
        ViewportTheme.vertex, ViewportTheme.faceDot, ViewportTheme.seam, ViewportTheme.sharp, ViewportTheme.crease, ViewportTheme.active,
    ]

    private func drawFaces(_ enc: MTLRenderCommandEncoder, _ o: ViewportObjectDraw, uniforms u: inout ObjectUniforms, view: inout ViewUniforms) {
        guard !o.template, let v = o.mesh.vertices, let ix = o.mesh.indices, o.mesh.indexCount > 0 else { return }
        enc.setVertexBuffer(v, offset: 0, index: 0)
        enc.setVertexBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
        enc.setFragmentBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 1)
        enc.setFragmentBuffer(o.mesh.faceFlags ?? zeros, offset: 0, index: 2)
        enc.setFragmentBuffer(o.mesh.triangleFace ?? zeros, offset: 0, index: 3)
        enc.setFragmentBuffer(o.mesh.triangleMaterial ?? zeros, offset: 0, index: 4)
        var colors = o.materialColors.isEmpty ? [SIMD4<Float>(0.8, 0.8, 0.8, 1)] : o.materialColors
        colors.withUnsafeMutableBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 5) }
        enc.setFragmentTexture(matcaps, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: o.mesh.indexCount, indexType: .uint32, indexBuffer: ix, indexBufferOffset: 0)
    }

    private lazy var zeros: MTLBuffer = device.makeBuffer(length: 256, options: .storageModeShared)!

    /// Draws the frame into `target` (the drawable's texture, or an offscreen one of `colorFormat`).
    package func encode(_ f: ViewportFrame, target: MTLTexture, into cb: MTLCommandBuffer) {
        let (msaa, depth, ids, idDepth) = ensureTargets(f.size)
        var u = uniforms(f)
        let wireframe = f.shading.mode == .wireframe
        let outlines = f.overlays.enabled && f.shading.showOutline && f.objects.contains { $0.selected && !$0.edit && !$0.sculpt }

        // The objects' ids: the selection outline reads them.
        if outlines {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = ids
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = idDepth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .dontCare
            if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                enc.setRenderPipelineState(objectID)
                enc.setDepthStencilState(depthWrite)
                for (i, o) in f.objects.enumerated() {
                    var ou = objectUniforms(o, f, index: i)
                    drawFaces(enc, o, uniforms: &ou, view: &u)
                }
                enc.endEncoding()
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        let bg = ViewportTheme.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(f.size.x), height: Double(f.size.y), znear: 0, zfar: 1))

        // Faces: opaque, or blended without writing depth in x-ray (then the far side shows through).
        if !wireframe {
            enc.setRenderPipelineState(f.shading.xray ? meshBlend : mesh)
            enc.setDepthStencilState(f.shading.xray ? depthTest : depthWrite)
            enc.setCullMode(.none)
            for (i, o) in f.objects.enumerated() {
                var ou = objectUniforms(o, f, index: i)
                drawFaces(enc, o, uniforms: &ou, view: &u)
            }
        }

        // The grid, under the meshes (depth tested, not written).
        if f.overlays.enabled && (f.overlays.grid || f.overlays.axes) {
            enc.setRenderPipelineState(grid)
            enc.setDepthStencilState(depthTest)
            enc.setFragmentBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // The selected objects' outline.
        if outlines {
            var selected = [UInt8](repeating: 0, count: max(1, f.objects.count))
            for (i, o) in f.objects.enumerated() where o.selected && !o.edit { selected[i] = o.active ? 2 : 1 }
            enc.setRenderPipelineState(outline)
            enc.setDepthStencilState(depthNone)
            enc.setFragmentTexture(ids, index: 0)
            selected.withUnsafeMutableBytes { enc.setFragmentBytes($0.baseAddress!, length: max(16, $0.count), index: 0) }
            enc.setFragmentBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // Wires: every object's in wireframe mode or with the wireframe overlay; edit mode's cage with its flags.
        enc.setRenderPipelineState(edge)
        enc.setDepthStencilState(f.shading.xray || wireframe ? depthNone : depthTest)
        var theme = Self.themeColors
        for (i, o) in f.objects.enumerated() {
            let showWire = o.edit || o.template || wireframe || (f.overlays.enabled && f.overlays.wireframe)
            guard showWire, let edges = o.mesh.edges, let positions = o.mesh.cagePositions, o.mesh.edgeCount > 0 else { continue }
            var ou = objectUniforms(o, f, index: i)
            if !o.edit && !wireframe { ou.wire = SIMD4(0, 0, 0, 0.35) }
            if !o.edit && wireframe && !o.selected { ou.wire = linearColor(0x101010) }
            if o.template { ou.wire = SIMD4(0.55, 0.55, 0.6, 0.7) }
            enc.setVertexBuffer(edges, offset: 0, index: 0)
            enc.setVertexBuffer(positions, offset: 0, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 2)
            enc.setVertexBytes(&ou, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            theme.withUnsafeMutableBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: o.mesh.edgeCount)
        }

        // Vertices (vertex mode) and face dots (face mode) of the edited object.
        enc.setRenderPipelineState(point)
        for (i, o) in f.objects.enumerated() where o.edit {
            var ou = objectUniforms(o, f, index: i)
            enc.setVertexBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 2)
            enc.setVertexBytes(&ou, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            if o.selectMode == .vertex, let p = o.mesh.cagePositions, let fl = o.mesh.vertexFlags, o.mesh.cageVertexCount > 0 {
                var pt = Self.pointTheme
                var size: Float = 4
                enc.setVertexBuffer(p, offset: 0, index: 0)
                enc.setVertexBuffer(fl, offset: 0, index: 1)
                pt.withUnsafeMutableBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
                enc.setVertexBytes(&size, length: 4, index: 5)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: o.mesh.cageVertexCount)
            }
            if o.selectMode == .face && f.overlays.faceDots, let p = o.mesh.faceCenters, let fl = o.mesh.faceDotFlags, o.mesh.cageFaceCount > 0 {
                var dt = Self.dotTheme
                var size: Float = 4
                enc.setVertexBuffer(p, offset: 0, index: 0)
                enc.setVertexBuffer(fl, offset: 0, index: 1)
                dt.withUnsafeMutableBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
                enc.setVertexBytes(&size, length: 4, index: 5)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: o.mesh.cageFaceCount)
            }
        }

        // Overlay lines: the 3D cursor, constraint axes, brush rings.
        var lines = f.lines
        if f.overlays.enabled && f.overlays.showCursor { lines += cursorLines(f) }
        if !lines.isEmpty {
            enc.setRenderPipelineState(overlayLine)
            enc.setDepthStencilState(depthNone)
            let buffer = lines.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
        }
        enc.endEncoding()
    }

    /// The 3D cursor: Blender's red and white ring with its cross, a constant size on screen.
    private func cursorLines(_ f: ViewportFrame) -> [OverlayLine] {
        let c = f.cursor, cam = f.camera
        let size = SIMD2(Float(f.size.x), Float(f.size.y)) / f.pixelScale
        guard let p = cam.project(c, size: size) else { return [] }
        let k = cam.metresPerPoint(depth: max(p.z, cam.near), viewHeight: size.y)
        let r = 10 * k, cross = 18 * k
        var out: [OverlayLine] = []
        let n = 16
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
            let p0 = c + (cam.right * cos(a0) + cam.up * sin(a0)) * r, p1 = c + (cam.right * cos(a1) + cam.up * sin(a1)) * r
            out.append(OverlayLine(p0, p1, color: i % 2 == 0 ? linearColor(0xFF0000) : linearColor(0xFFFFFF), width: 1.5))
        }
        for d in [cam.right, cam.up] {
            out.append(OverlayLine(c + d * r * 0.5, c + d * cross, color: linearColor(0x000000), width: 1))
            out.append(OverlayLine(c - d * r * 0.5, c - d * cross, color: linearColor(0x000000), width: 1))
        }
        return out
    }

    // MARK: Picking

    /// What is under each pixel of a square of `radius` round `point` (pixels, top left): object ids (object mode:
    /// object + 1), or in edit mode the kind (1 face, 2 edge, 3 vertex, 4 face dot) << 28 | index + 1, the nearest
    /// first. Runs a pass of its own and waits for it.
    package func pick(_ f: ViewportFrame, at point: SIMD2<Int>, radius: Int, edit: Bool) -> [(id: UInt32, distance: Float)] {
        guard let queue = commandQueue, let cb = queue.makeCommandBuffer() else { return [] }
        let (_, _, ids, _) = ensureTargets(f.size)
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: f.size.x, height: f.size.y, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        let depth = device.makeTexture(descriptor: depthDesc)!
        encodePickPass(f, ids: ids, depth: depth, edit: edit, into: cb)
        let x0 = max(0, point.x - radius), y0 = max(0, point.y - radius)
        let x1 = min(f.size.x, point.x + radius + 1), y1 = min(f.size.y, point.y + radius + 1)
        guard x1 > x0, y1 > y0 else { return [] }
        let w = x1 - x0, h = y1 - y0
        let out = device.makeBuffer(length: w * h * 4, options: .storageModeShared)!
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: ids, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: out, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        let p = out.contents().bindMemory(to: UInt32.self, capacity: w * h)
        var best: [UInt32: Float] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let id = p[y * w + x]
                guard id != 0 else { continue }
                let d = simd_length(SIMD2(Float(x0 + x - point.x), Float(y0 + y - point.y)))
                if d <= Float(radius) { best[id] = min(best[id] ?? .infinity, d) }
            }
        }
        return best.map { ($0.key, $0.value) }.sorted { $0.distance < $1.distance }
    }

    /// Every id drawn inside a rectangle of pixels (top left origin): what box select keeps. One pass, waited for.
    package func pickRegion(_ f: ViewportFrame, x: Int, y: Int, width: Int, height: Int, edit: Bool) -> Set<UInt32> {
        guard let queue = commandQueue, let cb = queue.makeCommandBuffer() else { return [] }
        let (_, _, ids, _) = ensureTargets(f.size)
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: f.size.x, height: f.size.y, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        let depth = device.makeTexture(descriptor: depthDesc)!
        encodePickPass(f, ids: ids, depth: depth, edit: edit, into: cb)
        let x0 = max(0, x), y0 = max(0, y), x1 = min(f.size.x, x + width), y1 = min(f.size.y, y + height)
        guard x1 > x0, y1 > y0 else { return [] }
        let w = x1 - x0, h = y1 - y0
        let out = device.makeBuffer(length: w * h * 4, options: .storageModeShared)!
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: ids, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: out, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        let p = out.contents().bindMemory(to: UInt32.self, capacity: w * h)
        var found = Set<UInt32>()
        for i in 0..<(w * h) where p[i] != 0 { found.insert(p[i]) }
        return found
    }

    package lazy var commandQueue: MTLCommandQueue? = device.makeCommandQueue()

    /// The ids pass: faces (with depth), then the edit cage's edges and points over them.
    package func encodePickPass(_ f: ViewportFrame, ids: MTLTexture, depth: MTLTexture, edit: Bool, into cb: MTLCommandBuffer) {
        var u = uniforms(f)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = ids
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor()
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setDepthStencilState(depthWrite)
        for (i, o) in f.objects.enumerated() {
            // In edit mode only the edited object's faces count (the others still hide it).
            enc.setRenderPipelineState(edit && o.edit ? faceID : objectID)
            var ou = objectUniforms(o, f, index: i)
            if edit && !o.edit { ou.objectID = 0x0FFF_FFFE }   // not pickable, but in front of what it hides
            if f.shading.xray && edit && !o.edit { continue }
            drawFaces(enc, o, uniforms: &ou, view: &u)
        }
        if edit {
            enc.setDepthStencilState(f.shading.xray ? depthNone : depthTest)
            for (i, o) in f.objects.enumerated() where o.edit {
                var ou = objectUniforms(o, f, index: i)
                if let e = o.mesh.edges, let p = o.mesh.cagePositions, o.mesh.edgeCount > 0, o.selectMode != .face || f.shading.xray {
                    enc.setRenderPipelineState(edgeID)
                    enc.setVertexBuffer(e, offset: 0, index: 0)
                    enc.setVertexBuffer(p, offset: 0, index: 1)
                    enc.setVertexBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 2)
                    enc.setVertexBytes(&ou, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: o.mesh.edgeCount)
                }
                enc.setRenderPipelineState(pointID)
                enc.setVertexBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 2)
                enc.setVertexBytes(&ou, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
                if o.selectMode == .vertex, let p = o.mesh.cagePositions, let fl = o.mesh.vertexFlags, o.mesh.cageVertexCount > 0 {
                    var kind: UInt32 = 3
                    enc.setVertexBuffer(p, offset: 0, index: 0)
                    enc.setVertexBuffer(fl, offset: 0, index: 1)
                    enc.setVertexBytes(&kind, length: 4, index: 5)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: o.mesh.cageVertexCount)
                }
                if o.selectMode == .face, let p = o.mesh.faceCenters, let fl = o.mesh.faceDotFlags, o.mesh.cageFaceCount > 0 {
                    var kind: UInt32 = 4
                    enc.setVertexBuffer(p, offset: 0, index: 0)
                    enc.setVertexBuffer(fl, offset: 0, index: 1)
                    enc.setVertexBytes(&kind, length: 4, index: 5)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: o.mesh.cageFaceCount)
                }
            }
        }
        enc.endEncoding()
    }
}
