import AppKit
import Characters
import Effects
import EngineCore
import MetalKit
import Physics
import Plants
import QuartzCore
import simd

extension Renderer {
    // MARK: - Sky

    /// The sky texture, the cloud noise and the cloud-shadow map, allocated the first time the sky is used.
    private func ensureSkyTextures() -> Bool {
        if skyMap != nil { return true }
        let n = SkySettings.mapSize
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: n, mipmapped: true)
        d.textureType = .type2DArray
        d.arrayLength = 2
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        let m = SkySettings.shadowMapSize
        let ds = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: m, height: m, mipmapped: false)
        ds.usage = [.shaderRead, .shaderWrite]
        ds.storageMode = .private
        func volume(_ side: Int) -> MTLTextureDescriptor {
            let v = MTLTextureDescriptor()
            v.textureType = .type3D
            v.pixelFormat = .rgba8Unorm
            v.width = side; v.height = side; v.depth = side
            v.mipmapLevelCount = Int(log2(Double(side))) + 1   // the clouds read coarser levels for longer steps
            v.usage = [.shaderRead, .shaderWrite, .renderTarget]
            v.storageMode = .private
            return v
        }
        func lut(_ w: Int, _ h: Int) -> MTLTextureDescriptor {
            let l = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            l.usage = [.shaderRead, .shaderWrite]
            l.storageMode = .private
            return l
        }
        guard let sky = device.makeTexture(descriptor: d), let shadow = device.makeTexture(descriptor: ds),
              let shape = device.makeTexture(descriptor: volume(128)), let detail = device.makeTexture(descriptor: volume(32)),
              let tLUT = device.makeTexture(descriptor: lut(256, 64)), let msLUT = device.makeTexture(descriptor: lut(32, 32)),
              let mean = device.makeBuffer(length: 32, options: .storageModeShared) else {
            return false
        }
        memset(mean.contents(), 0, 32)
        transmittanceLUT = tLUT
        multiScatterLUT = msLUT
        skyMean = mean
        sky.label = "sky"; shadow.label = "cloud shadow"; shape.label = "cloud shape noise"; detail.label = "cloud detail noise"
        skyMap = sky
        cloudShadowMap = shadow
        cloudShape = shape
        cloudDetail = detail
        cloudNoiseReady = false
        return true
    }

    /// The environment image for `path` (loaded once, its sun cut out), as an equirectangular texture.
    private func skyImageFor(_ path: String, exposure: Float) -> (image: SkyImage, texture: MTLTexture)? {
        if let s = skyImage, s.path == path, s.exposure == exposure { return (s.image, s.texture) }
        if skyImageFailed == path { return nil }
        if benchmark != nil {
            // A benchmark loads it here, so its first frame has it.
            switch Result(catching: { try Renderer.loadSkyImage(device, path: path, exposure: exposure) }) {
            case .success(let loaded): skyImage = (path, exposure, loaded.image, loaded.texture)
            case .failure(let error):
                print("Sky image failed to load (\(path)): \(error)")
                skyImageFailed = path
            }
            return skyImage.map { ($0.image, $0.texture) }
        }
        // The app decodes it in the background (a 2K image takes a few hundred ms), one load at a time: until it is in,
        // the sky is the image at its last exposure, or the constant colour.
        if !skyImageLoading {
            skyImageLoading = true
            let device = device
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try Renderer.loadSkyImage(device, path: path, exposure: exposure) }
                self?.renderThread.perform {
                    guard let self else { return }
                    self.skyImageLoading = false
                    switch result {
                    case .success(let loaded):
                        self.skyImage = (path, exposure, loaded.image, loaded.texture)
                        self.skyRefreshed = nil   // a full bake with the new image
                    case .failure(let error):
                        print("Sky image failed to load (\(path)): \(error)")
                        self.skyImageFailed = path
                    }
                }
            }
        }
        if let s = skyImage, s.path == path { return (s.image, s.texture) }
        return nil
    }

    /// Decodes the image and uploads it. Any thread.
    private static func loadSkyImage(_ device: MTLDevice, path: String, exposure: Float) throws -> (image: SkyImage, texture: MTLTexture) {
        let image = try SkyImage.load(path: path, exposure: exposure)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: image.width, height: image.height,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture sky image") }
        texture.label = "sky image"
        image.pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 16)
        }
        let sun = image.sunDirection.map { String(format: "sun toward (%.3f, %.3f, %.3f), %.2f° across, irradiance %.2f", $0.x, $0.y, $0.z, 2 * image.sunAngularRadius * 180 / .pi, 0.2126 * image.sunIrradiance.x + 0.7152 * image.sunIrradiance.y + 0.0722 * image.sunIrradiance.z) } ?? "no sun"
        print("Sky image: \((path as NSString).lastPathComponent), \(image.width)×\(image.height), \(sun)")
        return (image, texture)
    }

    /// This frame's sky: the sun (from the atmosphere, or the image's), which also sets the scene's sun light (its
    /// colour, and with an image its direction), and the clouds. False for a constant sky (or an image that failed).
    package func updateSky(lights: UnsafeMutableBufferPointer<GPULight>) -> Bool {
        let sky = settings.sky
        guard sky.mode != .constant, ensureSkyTextures() else { return false }
        var image: SkyImage?
        if sky.mode == .image {
            guard let path = sky.imagePath, let loaded = skyImageFor(path, exposure: sky.imageExposure) else { return false }
            image = loaded.image
        }
        let sunIndex = scene.firstSun
        var sunDir = normalize(SIMD3<Float>(0.4, 0.5, -0.6)), sunRadius: Float = 0.27 * .pi / 180
        if let d = image?.sunDirection {
            sunDir = d
            sunRadius = image!.sunAngularRadius
        } else if let i = sunIndex {
            sunDir = normalize(SIMD3(lights[i].axis.x, lights[i].axis.y, lights[i].axis.z))
            sunRadius = lights[i].positionRadius.w
        }
        let sunGround: SIMD3<Float>
        var sunTop = Atmosphere.solarIrradiance, glow = SIMD3<Float>(0, 1, 0), glowTop = SIMD3<Float>(), stars: Float = 0
        if let image {
            sunGround = image.sunDirection == nil ? .zero : image.sunIrradiance
        } else if let heavens = scene.heavens {
            // The open world: the light is the sun, or the moon once the sun has set; the sun then still lights the
            // sky from under the horizon.
            var light = Atmosphere.solarIrradiance * heavens.adaptation * heavens.sunUp
            sunTop = Atmosphere.solarIrradiance * heavens.adaptation
            stars = heavens.stars
            if heavens.lightIsMoon {
                glow = heavens.sun
                if heavens.sunElevation > Heavens.twilightEnd { glowTop = sunTop }
                sunTop = Heavens.nightSkyIrradiance * heavens.moonlight
                light = Heavens.moonIrradiance * (heavens.moonlight * heavens.moonUp)
            }
            if atmosphereCache == nil || length(atmosphereCache!.sun - sunDir) > 1e-4 {
                atmosphereCache = (sunDir, Atmosphere.sunIrradiance(toward: sunDir))
            }
            sunGround = atmosphereCache!.ground / Atmosphere.solarIrradiance * light
        } else {
            if atmosphereCache == nil || length(atmosphereCache!.sun - sunDir) > 1e-4 {
                atmosphereCache = (sunDir, Atmosphere.sunIrradiance(toward: sunDir))
            }
            sunGround = atmosphereCache!.ground
        }
        if let i = sunIndex {
            lights[i].color = SIMD4(sunGround, lights[i].color.w)
            lights[i].axis = SIMD4(sunDir, 0)
            lights[i].positionRadius.w = sunRadius
        }
        let full = skyRefreshed == nil || skyRefreshed!.sky != sky || skyRefreshed!.scene != scene.serial
        skyRefreshed = (sky, scene.serial)
        let windAngle = sky.windDirection * .pi / 180
        let sphere = scene.sceneSphere
        var p = GPUSkyParams()
        p.sun = SIMD4(sunDir, sunRadius)
        p.sunTop = SIMD4(sunTop, 0)
        p.sunGround = SIMD4(sunGround, 0)
        p.glow = SIMD4(glow, stars)
        p.glowTop = SIMD4(glowTop, 0)
        p.cloudLayer = SIMD4(sky.cloudBase, sky.cloudBase + max(sky.cloudThickness, 100),
                             SkySettings.coverageRange.clamp(sky.coverage), SkySettings.densityRange.clamp(sky.density))
        p.cloudShape = SIMD4(max(sky.cloudScale, 100), sky.erosion, animTime, sky.shadowStrength)
        p.wind = SIMD4(SIMD3(cos(windAngle), 0, sin(windAngle)) * sky.windSpeed, full ? 1 : 0.5)
        p.shadowMap = SIMD4(sphere.x, sphere.z, max(1.2 * sphere.w, 150), 0)
        if let place = scene.worldPlace {
            // The open world: cloud shadows over everything in sight, the clouds where the world has them.
            p.shadowMap.z = 9 * World.tileSize
            p.place = SIMD4(Float(place.anchor.x), Float(place.anchor.y), camera.position.x, camera.position.z)
        }
        p.ground = SIMD4(SIMD3(repeating: 0.25), Atmosphere.observerAltitude)
        let clouds = sky.clouds && (image == nil || sky.cloudsOverImage)
        p.flags = SIMD4(image == nil ? GPUSkyParams.atmosphere : GPUSkyParams.image,
                        (sky.clouds ? GPUSkyParams.clouds : 0) | (clouds && sky.shadows ? GPUSkyParams.shadows : 0)
                            | (full ? GPUSkyParams.updateAll : 0) | (sky.cloudsOverImage ? GPUSkyParams.cloudsOverImage : 0),
                        frameIndex % 16, frameIndex)
        skyParams = p
        return true
    }

    /// The sky's part of the shading arguments (MSL SceneShading): its textures (stand-ins without a sky) and SkyParams.
    package func writeSkyArguments(slot: Int) {
        guard slot < shadingArgs.count else { return }
        let p = shadingArgs[slot].contents()
        let sky = skyActive ? skyMap ?? dummyArray! : dummyArray!, shadow = skyActive ? cloudShadowMap ?? dummy2D! : dummy2D!
        p.storeBytes(of: sky.gpuResourceID, toByteOffset: Renderer.shadingSkyOffset, as: MTLResourceID.self)
        p.storeBytes(of: shadow.gpuResourceID, toByteOffset: Renderer.shadingSkyOffset + 8, as: MTLResourceID.self)
        p.storeBytes(of: skyActive ? skyParams : GPUSkyParams(), toByteOffset: Renderer.shadingParamsOffset, as: GPUSkyParams.self)
    }

    /// The sky's passes, ahead of the frame's main encoder: the cloud noise and the atmosphere's tables (once), then
    /// this frame's sky texels, the cloud-shadow map and the sky texture's mips (encodeSkyTexels).
    package func encodeSky(_ passes: FrameEncoder) {
        guard let sky = skyMap, let shape = cloudShape, let detail = cloudDetail, let shadow = cloudShadowMap,
              let tLUT = transmittanceLUT, let msLUT = multiScatterLUT, let mean = skyMean,
              var enc = passes.compute("sky", serial: true) else { return }
        if !cloudNoiseReady {   // once: the cloud noise and the atmosphere's tables (the second reads the first)
            enc.setComputePipelineState(pipelines[.cloudNoise])
            enc.setTexture(shape, index: 0)
            enc.setTexture(detail, index: 1)
            enc.dispatchThreads(MTLSize(width: shape.width, height: shape.height, depth: shape.depth),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
            enc.setComputePipelineState(pipelines[.transmittanceLUT])
            enc.setTexture(tLUT, index: 0)
            dispatch(enc, .transmittanceLUT, width: tLUT.width, height: tLUT.height)
            enc.setComputePipelineState(pipelines[.multiScatterLUT])
            setTextures(enc, [tLUT, msLUT])
            dispatch(enc, .multiScatterLUT, width: msLUT.width, height: msLUT.height)
            passes.generateMipmaps([shape, detail], pass: "sky")
            cloudNoiseReady = true
            guard let next = passes.compute("sky", serial: true) else { return }
            enc = next
        }
        var p = skyParams
        // The clear sky's mean radiance (lights the clouds and the ground), then this frame's sky texels.
        enc.setComputePipelineState(pipelines[.skyMean])
        enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
        enc.setBuffer(mean, offset: 0, index: 1)
        setTextures(enc, [skyImage?.texture ?? dummy2D, tLUT, msLUT])
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.setComputePipelineState(pipelines[.sky])
        enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
        enc.setBuffer(mean, offset: 0, index: 1)
        setTextures(enc, [shape, detail, blueNoiseTexture, skyImage?.texture ?? dummy2D, sky, tLUT, msLUT])
        let part = p.flags.y & GPUSkyParams.updateAll != 0 ? 1 : 4   // this frame's texels: every one, or 1 in 4x4
        enc.dispatchThreads(MTLSize(width: sky.width / part, height: sky.height / part, depth: 2),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        if p.flags.y & GPUSkyParams.shadows != 0 {
            enc.setComputePipelineState(pipelines[.cloudShadow])
            enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
            setTextures(enc, [shape, detail, shadow])
            dispatch(enc, .cloudShadow, width: shadow.width, height: shadow.height)
        }
        passes.generateMipmaps([sky], pass: "sky")
    }

    /// Per slot: the lights, then the light table.
    package func createLightBuffers() throws {
        _ = scene.takeLightTrianglesDirty()   // written here as they are now
        lightTree = nil                       // the scene's lights: made again from them when the path tracer needs it
        lightTreeVersions = [Int](repeating: -1, count: Renderer.maxFramesInFlight)
        lightTrianglesPending = [Range<Int>?](repeating: nil, count: Renderer.maxFramesInFlight)
        for _ in 0..<Renderer.maxFramesInFlight {
            guard let lights = device.makeBuffer(length: max(scene.lights.count * MemoryLayout<GPULight>.stride + scene.lightTable.byteCount, 64),
                                                 options: .storageModeShared) else {
                throw RendererError.resourceCreation("per-frame buffers")
            }
            // The light table, after the lights: written once (but for the triangles of lights that go on and off
            // with the time of day: writeFrameData).
            var offset = scene.lights.count * MemoryLayout<GPULight>.stride
            scene.lightTable.entries.withUnsafeBytes { raw in
                if raw.count > 0 { lights.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
                offset += raw.count
            }
            scene.lightTable.triangles.withUnsafeBytes { raw in
                if raw.count > 0 { lights.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
            }
            lights.label = "lights"
            lightBuffers.append(lights)
        }
    }
}
