import AppKit
import EngineCore
import MetalKit
import Physics
import Plants
import QuartzCore
import simd

/// All screen-sized textures. Recreated when the render resolution changes.
package final class RenderTargets {
    let width: Int
    let height: Int
    let normalDepth: [MTLTexture]   // [2], ping-ponged: current + previous frame. xyz = normal, w = view depth (half: ~0.1% depth error)
    let albedo: MTLTexture
    let emission: MTLTexture
    let motion: MTLTexture          // xy = pixel position in previous frame, z = expected previous depth, w = valid
    let direct: MTLTexture          // raw 1-spp direct lighting (albedo removed)
    let indirect: MTLTexture        // raw 1-spp indirect lighting (albedo removed), or a GI technique's result
    let surfacePos: MTLTexture      // xyz = world position, w = instance id + 1 (0 = sky or emitter: no GI)
    let geoNormal: MTLTexture       // geometric normal, oriented toward the camera
    let giDebug: MTLTexture         // debug visualisation written by cascade GI (view mode "GI debug")
    let geometryDebug: MTLTexture   // geometry debug views (view modes 8-13), written by geometryDebugKernel
    let visibility: MTLTexture      // per light group (rgba = groups 0...3): visibility of this frame's shadow ray(s)
    let blocker: MTLTexture         // per light group: penumbra half width of the occluded samples, 0 = visible
    let material: MTLTexture        // specular materials: rgb = F0, a = roughness
    let specular: MTLTexture        // raw 1-spp specular light (reflections), divided by the specular albedo
    let meshDirect: MTLTexture      // raw 1-spp direct light from emissive-mesh lights (albedo removed)
    let shadow: ShadowTargets       // shadow denoiser state
    /// Denoiser state for [0] direct + indirect light combined (or direct alone), [1] indirect light alone,
    /// [2] specular light and [3] mesh-light direct light (with the shadow denoiser).
    let denoise: [DenoiseTargets]
    // MetalFX inputs (written only while upscaling is on)
    static let upscaleColorFormat = MTLPixelFormat.rgba16Float
    static let upscaleDepthFormat = MTLPixelFormat.r32Float
    static let upscaleMotionFormat = MTLPixelFormat.rg16Float
    static let gBufferFormat = MTLPixelFormat.rgba16Float      // albedo, normalDepth, specularAlbedo
    static let roughnessFormat = MTLPixelFormat.r16Float
    let upscaleColor: MTLTexture    // tonemapped linear color at render resolution
    let deviceDepth: MTLTexture     // reversed-Z depth (near / viewDepth)
    let pixelMotion: MTLTexture     // previous pixel position - this pixel position, unjittered
    // More guides for MetalFX's denoising scaler (written by the composite while it is the upscaler)
    let specularAlbedo: MTLTexture  // what the surface reflects toward the camera, 0 where nothing is specular
    let roughness: MTLTexture

    package init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ format: MTLPixelFormat, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        normalDepth = [try make(.rgba16Float, "normalDepth0"), try make(.rgba16Float, "normalDepth1")]
        albedo = try make(.rgba16Float, "albedo")
        emission = try make(.rgba16Float, "emission")
        motion = try make(.rgba32Float, "motion")
        direct = try make(.rgba16Float, "direct")
        indirect = try make(.rgba16Float, "indirect")
        surfacePos = try make(.rgba32Float, "surfacePos")
        geoNormal = try make(.rgba16Float, "geoNormal")
        giDebug = try make(.rgba16Float, "giDebug")
        geometryDebug = try make(.rgba8Unorm, "geometryDebug")
        visibility = try make(.rgba8Unorm, "visibility")
        blocker = try make(.rgba16Float, "blocker")
        material = try make(.rgba16Float, "material")
        specular = try make(.rgba16Float, "specular")
        meshDirect = try make(.rgba16Float, "meshDirect")
        shadow = try ShadowTargets(device: device, width: width, height: height, make)
        denoise = [try DenoiseTargets(make, "direct"), try DenoiseTargets(make, "indirect"), try DenoiseTargets(make, "specular"),
                   try DenoiseTargets(make, "meshDirect")]
        upscaleColor = try make(RenderTargets.upscaleColorFormat, "upscaleColor")
        deviceDepth = try make(RenderTargets.upscaleDepthFormat, "deviceDepth")
        pixelMotion = try make(RenderTargets.upscaleMotionFormat, "pixelMotion")
        specularAlbedo = try make(RenderTargets.gBufferFormat, "specularAlbedo")
        roughness = try make(RenderTargets.roughnessFormat, "roughness")
    }
}

/// Textures the denoiser keeps for one lighting signal.
final class DenoiseTargets {
    let history: MTLTexture     // denoised illumination fed back into next frame's temporal pass
    // history, pingA and pingB hold rgb = illumination, a = luminance standard deviation.
    let pingA: MTLTexture
    let pingB: MTLTexture
    let moments: [MTLTexture]   // [2], ping-ponged. x = fast mean luminance, y = fast mean luminance^2, z = history length, w = slow mean luminance (anti-lag)

    package init(_ make: (MTLPixelFormat, String) throws -> MTLTexture, _ name: String) throws {
        // Half precision halves the a-trous filter's memory traffic. Alpha stores the standard deviation,
        // not the variance: variance (~luminance^2) overflows half (65504) near the lights.
        history = try make(.rgba16Float, "\(name) history")
        pingA = try make(.rgba16Float, "\(name) pingA")
        pingB = try make(.rgba16Float, "\(name) pingB")
        moments = [try make(.rgba32Float, "\(name) moments0"), try make(.rgba32Float, "\(name) moments1")]
    }

    /// The a-trous filter's ping-pong: pass `i` reads `src` and writes `dst`. Pass 0 writes into `history`, which
    /// feeds the next frame's temporal pass.
    func atrousPass(_ i: Int) -> (src: MTLTexture, dst: MTLTexture) {
        switch i {
        case 0: return (pingA, history)
        case 1: return (history, pingB)
        default: return i % 2 == 0 ? (pingB, pingA) : (pingA, pingB)
        }
    }
}

/// Textures the shadow denoiser keeps (visibility per light in rgba).
final class ShadowTargets {
    let history: MTLTexture     // filtered visibility fed back into next frame's temporal pass
    let pingA: MTLTexture
    let pingB: MTLTexture
    let meta: [MTLTexture]      // [2], ping-ponged. z = history length
    let penumbra: MTLTexture    // per light: penumbra half-width in pixels
    let tiles: MTLTexture       // per 8x8 tile: 1 = fully lit / shadowed everywhere, nothing to filter
    // More than 4 lights with light reuse: per group, last frame's light pick (manyLightsKernel), ping-ponged.
    let reservoir: [MTLTexture]         // [2] rgba32Uint: light index | confidence M << 16
    let reservoirWeight: [MTLTexture]   // [2] rgba32Float: the pick's contribution weight W

    package init(device: MTLDevice, width: Int, height: Int, _ make: (MTLPixelFormat, String) throws -> MTLTexture) throws {
        history = try make(.rgba16Float, "shadow history")
        pingA = try make(.rgba16Float, "shadow pingA")
        pingB = try make(.rgba16Float, "shadow pingB")
        meta = [try make(.rgba16Float, "shadow meta0"), try make(.rgba16Float, "shadow meta1")]
        penumbra = try make(.rgba16Float, "shadow penumbra")
        reservoir = [try make(.rgba32Uint, "light reservoir0"), try make(.rgba32Uint, "light reservoir1")]
        reservoirWeight = [try make(.rgba32Float, "light reservoir weight0"), try make(.rgba32Float, "light reservoir weight1")]
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: (width + 7) / 8,
                                                         height: (height + 7) / 8, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let tiles = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture shadow tiles") }
        tiles.label = "shadow tiles"
        self.tiles = tiles
    }
}

/// The volumetric fog's froxel grid: 8x8 traced pixels per froxel, `slices` exponential depth slices.
package final class FogTargets {
    let renderWidth: Int, renderHeight: Int
    let columns: Int, rows: Int, slices: Int
    let scatter: [MTLTexture]     // [2], ping-ponged: rgb = in-scattered light per metre, a = extinction (fogInjectKernel)
    let integrated: MTLTexture    // rgb = in-scatter from the camera to each slice's far side, a = transmittance

    package init(device: MTLDevice, renderWidth: Int, renderHeight: Int, slices: Int) throws {
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        let columns = (renderWidth + 7) / 8, rows = (renderHeight + 7) / 8
        self.columns = columns
        self.rows = rows
        self.slices = slices
        func make(_ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = .rgba16Float
            d.width = columns; d.height = rows; d.depth = slices
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        scatter = [try make("fog scatter0"), try make("fog scatter1")]
        integrated = try make("fog integrated")
    }
}

/// Temporal AA without upscaling (Post.metal taaResolveKernel), at the traced resolution: the composite's light, and
/// the resolved light of this frame and the last, by FramePlan.cur.
package final class TAATargets {
    let width: Int, height: Int
    let input: MTLTexture
    let history: [MTLTexture]

    package init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        input = try make("taa input")
        history = [try make("taa history0"), try make("taa history1")]
    }
}

/// The lens and the finish (Shaders/Post.metal), at the output resolution.
package final class PostTargets {
    let width: Int, height: Int
    let color: MTLTexture       // the composite's light, when MetalFX doesn't upscale it (FLAG_POST)
    let dof: MTLTexture         // after the depth of field
    let down: [MTLTexture]      // bloom's halvings, from half the output size...
    let up: [MTLTexture]        // ...and the way back up: up[i] = down[i] + up[i + 1] filtered (one fewer)
    let focus: MTLBuffer        // the autofocus distance, eased from frame to frame (0 = none yet)

    package init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ label: String, _ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        color = try make("post color", width, height)
        dof = try make("post dof", width, height)
        var down: [MTLTexture] = [], (w, h) = (width, height)
        while down.count < PostSettings.bloomLevels && min(w, h) >= 16 {
            (w, h) = ((w + 1) / 2, (h + 1) / 2)
            down.append(try make("bloom down\(down.count)", w, h))
        }
        self.down = down
        up = try down.dropLast().enumerated().map { try make("bloom up\($0.offset)", $0.element.width, $0.element.height) }
        guard let focus = device.makeBuffer(length: 16, options: .storageModeShared) else { throw RendererError.resourceCreation("focus buffer") }
        memset(focus.contents(), 0, 16)
        self.focus = focus
    }
}

/// ReSTIR DI's per-pixel state (Shaders/RestirDI.metal).
package final class RestirTargets {
    let width: Int, height: Int, chains: Int
    let reservoir: [MTLTexture]   // [2] rgba32Uint arrays (element, uv, W, M | flags; a slice per chain), ping-ponged
    let temporal: MTLTexture      // restirTemporalKernel's reservoirs
    let spatial: MTLTexture       // between two spatial passes
    let specular: MTLTexture      // direct specular light (rgba16F), which the reflection pass adds

    package init(device: MTLDevice, width: Int, height: Int, chains: Int) throws {
        self.width = width
        self.height = height
        self.chains = chains
        func make(_ label: String, _ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            if format == .rgba32Uint { d.textureType = .type2DArray; d.arrayLength = chains }
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        reservoir = [try make("restir reservoir0", .rgba32Uint), try make("restir reservoir1", .rgba32Uint)]
        temporal = try make("restir temporal", .rgba32Uint)
        spatial = try make("restir spatial", .rgba32Uint)
        specular = try make("restir specular", .rgba16Float)
    }
}

/// ReSTIR GI's per-pixel state (Shaders/RestirGI.metal). A reservoir is two textures: rgba32F (x_s, W) and rgba32Uint
/// (normal, light, M | age | flags).
package final class RestirGITargets {
    let width: Int, height: Int
    let reservoir: [(a: MTLTexture, b: MTLTexture)]   // [2], ping-ponged: the final reservoirs, next frame's history
    let temporal: (a: MTLTexture, b: MTLTexture)      // restirGITemporalKernel's reservoirs
    let spatial: (a: MTLTexture, b: MTLTexture)       // the initial samples, then between two spatial passes
    let feedback: [MTLTexture]                        // [2] rgba16F, ping-ponged: the raw indirect light (multi-bounce)
    let ambient: [MTLBuffer]                          // [2], ping-ponged: the mean indirect light (rgb sums, count)

    package init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ label: String, _ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        func pair(_ label: String) throws -> (a: MTLTexture, b: MTLTexture) {
            (try make("\(label) a", .rgba32Float), try make("\(label) b", .rgba32Uint))
        }
        reservoir = [try pair("restir gi reservoir0"), try pair("restir gi reservoir1")]
        temporal = try pair("restir gi temporal")
        spatial = try pair("restir gi spatial")
        feedback = [try make("restir gi feedback0", .rgba16Float), try make("restir gi feedback1", .rgba16Float)]
        ambient = try (0..<2).map { _ in
            guard let b = device.makeBuffer(length: 16, options: .storageModePrivate) else {
                throw RendererError.resourceCreation("restir gi ambient")
            }
            return b
        }
    }
}
