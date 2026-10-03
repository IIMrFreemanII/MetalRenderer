import Foundation

/// "Copy as Env" in the settings panel: the `METALRENDERER_*` variables that reproduce the current settings in a fresh
/// launch (or in every setting of a benchmark run), listing only what differs from the defaults. Fog and sky are
/// compared with the scene's presets. Not covered: the camera pose, Freeze LOD, and where added models were placed
/// (`model=` puts them in front of the default camera).
enum EnvExport {
    static func string(for s: RenderSettings, defaults: RenderSettings) -> String {
        // What a fresh launch would have: the code's defaults (not this process's env-derived ones) and the scene's presets.
        var d = defaults
        d.directLight = .auto
        d.rayTracer = .custom
        d.specular = true
        d.textureBudgetMB = 1024
        d.virtualGeometry.enabled = true
        d.virtualGeometry.pixelError = 1
        d.virtualGeometry.poolMB = 768
        d.scene = SceneSettings()
        d.scene.kind = s.scene.kind
        d.scene.emissiveLights = true
        d.applySceneDefaults(from: defaults)   // the scene's GI method, light count, fog and sky

        var vars: [String] = []
        func group(_ name: String, _ build: (inout Keys) -> Void) {
            var k = Keys()
            build(&k)
            if !k.items.isEmpty { vars.append("\(name)=\"\(k.items.joined(separator: ","))\"") }
        }

        if s.directLight != d.directLight { vars.append("METALRENDERER_DIRECT=\(s.directLight)") }
        if s.rayTracer != d.rayTracer { vars.append("METALRENDERER_RT=\(s.rayTracer)") }
        if s.specular != d.specular { vars.append("METALRENDERER_SPECULAR=0") }
        if s.textureBudgetMB != d.textureBudgetMB { vars.append("METALRENDERER_TEXTURE_BUDGET=\(s.textureBudgetMB)") }
        let vg = s.virtualGeometry, dvg = d.virtualGeometry
        if vg.enabled != dvg.enabled { vars.append("METALRENDERER_VG=0") }
        if vg.pixelError != dvg.pixelError { vars.append("METALRENDERER_VG_TAU=\(number(vg.pixelError))") }
        if vg.poolMB != dvg.poolMB { vars.append("METALRENDERER_VG_POOL=\(vg.poolMB)") }
        if s.fog.enabled != d.fog.enabled || FogSettings.override != nil { vars.append("METALRENDERER_FOG=\(s.fog.enabled ? 1 : 0)") }
        if s.sky.mode != d.sky.mode || SkySettings.override != nil {
            vars.append("METALRENDERER_SKY=\(s.sky.mode == .image ? quoted(s.sky.imagePath ?? "") : "\(s.sky.mode)")")
        }

        group("METALRENDERER_SCENE") { k in
            k.items.append("\(s.scene.kind)")
            k.add("objects", s.scene.objects, d.scene.objects)
            k.add("lights", s.scene.lights, d.scene.lights)
            k.add("emissivelights", s.scene.emissiveLights, d.scene.emissiveLights)
            k.items += s.scene.extraModels.map { "model=\($0.path)" }
        }
        group("METALRENDERER_GI") { k in
            k.add("on", s.giEnabled, d.giEnabled)
            if s.giMode != d.giMode { k.items.append("mode=" + ["pt", "cascades", "restir"][s.giMode.rawValue]) }
            k.add("lightmaps", s.lightMaps, d.lightMaps)
            k.add("lightrays", s.manyLightRays, d.manyLightRays)
            k.add("lightreuse", s.manyLightReuse, d.manyLightReuse)
            k.add("bounces", s.bounces, d.bounces)
            k.add("spacing", s.cascades.probeSpacing, d.cascades.probeSpacing)
            k.add("cascades", s.cascades.cascades, d.cascades.cascades)
            k.add("b1", s.cascades.firstInterval, d.cascades.firstInterval)
            k.add("feedback", s.cascades.feedback, d.cascades.feedback)
            k.add("cdenoise", s.cascades.denoiseIndirect, d.cascades.denoiseIndirect)
            k.add("blue", s.blueNoise, d.blueNoise)
            k.add("scale", Float(s.renderScale), Float(d.renderScale))
            k.add("factor", Float(s.upscaleFactor), Float(d.upscaleFactor))
            if s.upscaler != d.upscaler { k.items.append("upscaler=" + ["metalfx", "spatial", "custom"][s.upscaler.rawValue]) }
            let t = s.taau, dt = d.taau
            k.add("taauhistory", t.maxHistory, dt.maxHistory)
            k.add("taauclip", t.clipWidth, dt.clipWidth)
            k.add("taaumotion", t.motionCut, dt.motionCut)
            k.add("taaucut", t.clipCut, dt.clipCut)
            k.add("taaukernel", t.kernelSharpness, dt.kernelSharpness)
            k.add("taaukernelmv", t.kernelSharpnessMoving, dt.kernelSharpnessMoving)
            k.add("taaudilate", t.dilationRadius, dt.dilationRadius)
            k.add("taaulanczos", t.lanczosHistory, dt.lanczosHistory)
            k.add("taaulzthresh", t.lanczosThreshold, dt.lanczosThreshold)
            k.add("taauedge", t.edgeMotionCut, dt.edgeMotionCut)
        }
        group("METALRENDERER_DENOISE") { k in
            let n = s.denoiser, dn = d.denoiser
            k.add("on", n.enabled, dn.enabled)
            k.add("passes", n.atrousPasses, dn.atrousPasses)
            k.add("tpasses", n.techniquePasses, dn.techniquePasses)
            k.add("sigma", n.luminanceSigma, dn.luminanceSigma)
            k.add("history", n.maxHistory, dn.maxHistory)
            k.add("antilag", n.antiLag, dn.antiLag)
            k.add("separate", n.separateSignals, dn.separateSignals)
            k.add("shadows", n.shadowDenoiser, dn.shadowDenoiser)
            k.add("spasses", n.shadowPasses, dn.shadowPasses)
            k.add("shistory", n.shadowHistory, dn.shadowHistory)
            k.add("sclamp", n.shadowClamp, dn.shadowClamp)
            k.add("ssigma", n.shadowSigma, dn.shadowSigma)
        }
        group("METALRENDERER_RESTIR") { k in
            let r = s.restir, dr = d.restir
            k.add("candidates", r.candidates, dr.candidates)
            k.add("chains", r.chains, dr.chains)
            k.add("temporal", r.temporal, dr.temporal)
            k.add("maxm", r.maxM, dr.maxM)
            k.add("spatial", r.spatialPasses, dr.spatialPasses)
            k.add("k", r.spatialSamples, dr.spatialSamples)
            k.add("radius", r.radius, dr.radius)
            k.add("vis", r.visibilityReuse, dr.visibilityReuse)
            k.add("split", r.splitVisibility, dr.splitVisibility)
            k.add("sigma", r.denoiseSigma, dr.denoiseSigma)
            k.add("passes", r.denoisePasses, dr.denoisePasses)
            k.add("history", r.denoiseHistory, dr.denoiseHistory)
            k.add("boost", r.varianceBoost, dr.varianceBoost)
            k.add("grid", r.grid.enabled, dr.grid.enabled)
            k.add("gcells", r.grid.cells, dr.grid.cells)
            k.add("glevels", r.grid.levels, dr.grid.levels)
            k.add("gsize", r.grid.cellSize, dr.grid.cellSize)
            k.add("gscale", r.grid.levelScale, dr.grid.levelScale)
            k.add("gslots", r.grid.slots, dr.grid.slots)
            k.add("gk", r.grid.candidates, dr.grid.candidates)
            k.add("gshare", r.grid.share, dr.grid.share)
        }
        group("METALRENDERER_RESTIR_GI") { k in
            let r = s.restirGI, dr = d.restirGI
            k.add("quarter", r.quarterBudget, dr.quarterBudget)
            k.add("bounces", r.bounces, dr.bounces)
            k.add("lightmaps", r.lightMaps, dr.lightMaps)
            k.add("feedback", r.feedback, dr.feedback)
            k.add("dfeedback", r.denoisedFeedback, dr.denoisedFeedback)
            k.add("fallback", r.feedbackFallback, dr.feedbackFallback)
            k.add("temporal", r.temporal, dr.temporal)
            k.add("maxm", r.maxM, dr.maxM)
            k.add("age", r.maxAge, dr.maxAge)
            k.add("spatial", r.spatialPasses, dr.spatialPasses)
            k.add("k", r.spatialSamples, dr.spatialSamples)
            k.add("unbiased", r.unbiased, dr.unbiased)
            k.add("radius", r.radius, dr.radius)
            k.add("dmin", r.minDistance, dr.minDistance)
            k.add("denoise", r.denoise, dr.denoise)
            k.add("sigma", r.denoiseSigma, dr.denoiseSigma)
            k.add("passes", r.denoisePasses, dr.denoisePasses)
            k.add("history", r.denoiseHistory, dr.denoiseHistory)
            k.add("boost", r.varianceBoost, dr.varianceBoost)
            k.add("antilag", r.antiLag, dr.antiLag)
        }
        group("METALRENDERER_FOG_SET") { k in
            let f = s.fog, df = d.fog
            k.add("density", f.density, df.density)
            k.add("falloff", f.heightFalloff, df.heightFalloff)
            k.add("base", f.baseHeight, df.baseHeight)
            k.add("g", f.anisotropy, df.anisotropy)
            k.add("ambient", f.ambient, df.ambient)
            k.add("noise", f.noise, df.noise)
            k.add("tile", f.noiseScale, df.noiseScale)
            k.add("far", f.maxDistance, df.maxDistance)
            k.add("volumes", f.volumes, df.volumes)
            k.add("reflections", f.reflections, df.reflections)
            k.add("albedo", f.albedo, df.albedo)
            k.add("wind", f.wind, df.wind)
        }
        group("METALRENDERER_SKY_SET") { k in
            let y = s.sky, dy = d.sky
            k.add("clouds", y.clouds, dy.clouds)
            k.add("coverage", y.coverage, dy.coverage)
            k.add("density", y.density, dy.density)
            k.add("base", y.cloudBase, dy.cloudBase)
            k.add("thickness", y.cloudThickness, dy.cloudThickness)
            k.add("scale", y.cloudScale, dy.cloudScale)
            k.add("erosion", y.erosion, dy.erosion)
            k.add("wind", y.windSpeed, dy.windSpeed)
            k.add("winddir", y.windDirection, dy.windDirection)
            k.add("shadows", y.shadows, dy.shadows)
            k.add("strength", y.shadowStrength, dy.shadowStrength)
            k.add("exposure", y.imageExposure, dy.imageExposure)
            k.add("over", y.cloudsOverImage, dy.cloudsOverImage)
        }
        group("METALRENDERER_VIEW") { k in
            k.add("exposure", s.exposure, d.exposure)
            if s.toneMap != d.toneMap { k.items.append("tonemap=\(s.toneMap)") }
            k.add("fov", s.fovDegrees, d.fovDegrees)
            k.add("speed", s.moveSpeed, d.moveSpeed)
            k.add("timescale", s.timeScale, d.timeScale)
            k.add("tod", s.timeOfDay, d.timeOfDay)
            k.add("view", s.viewMode, d.viewMode)
            k.add("paused", s.paused, d.paused)
        }
        return vars.joined(separator: " ")
    }

    /// `key=value` items of one variable, added only where the value differs from the default.
    struct Keys {
        var items: [String] = []
        mutating func add(_ key: String, _ v: Float, _ d: Float) { if v != d { items.append("\(key)=\(number(v))") } }
        mutating func add(_ key: String, _ v: Int, _ d: Int) { if v != d { items.append("\(key)=\(v)") } }
        mutating func add(_ key: String, _ v: Bool, _ d: Bool) { if v != d { items.append("\(key)=\(v ? 1 : 0)") } }
        mutating func add(_ key: String, _ v: SIMD3<Float>, _ d: SIMD3<Float>) {
            if v != d { items.append("\(key)=\(number(v.x)):\(number(v.y)):\(number(v.z))") }
        }
    }

    /// Shortest text that reads back as the same Float.
    static func number(_ v: Float) -> String {
        let text = "\(v)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
