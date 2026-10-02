import AppKit
import UniformTypeIdentifiers

/// Floating panel with a control for every `RenderSettings` field, plus live resolution / fps / GPU time.
/// It never becomes the key window, so WASD and the keyboard shortcuts keep working while it's open.
/// Keyboard changes show up here too: the renderer reports every settings change through `onSettingsChanged`.
final class SettingsPanel: NSObject {
    let panel: NSPanel
    private let renderer: Renderer
    private let upscaleSteps: [CGFloat]

    private let stats = NSTextField(labelWithString: "")
    private let sceneKind = NSPopUpButton()
    private let rayTracer = NSPopUpButton()
    private let virtualGeometry = NSButton(checkboxWithTitle: "Virtual geometry (LOD)", target: nil, action: nil)
    private let freezeLOD = NSButton(checkboxWithTitle: "Freeze LOD (L)", target: nil, action: nil)
    private let specular = NSButton(checkboxWithTitle: "Specular (glTF PBR)", target: nil, action: nil)
    private let emissiveLights = NSButton(checkboxWithTitle: "Emissive surfaces are lights", target: nil, action: nil)
    private let vgError = NSSlider()               // log2 of the allowed error in traced pixels
    private let vgErrorValue = NSTextField(labelWithString: "")
    private let objects = NSSlider()
    private let objectsValue = NSTextField(labelWithString: "")
    private let lights = NSSlider()            // log2 of the light count
    private let lightsValue = NSTextField(labelWithString: "")
    private let lightRays = NSPopUpButton()    // shadow rays per light group (more than 4 lights)
    // Direct light
    private let directLight = NSPopUpButton()
    private let restirCandidates = NSPopUpButton()
    private let restirSpatial = NSPopUpButton()
    private let restirTemporal = NSButton(checkboxWithTitle: "Temporal reuse", target: nil, action: nil)
    private let restirVisibility = NSButton(checkboxWithTitle: "Visibility reuse", target: nil, action: nil)
    private static let candidateOptions = [4, 8, 16, 32]
    private let renderScale = NSSlider()
    private let renderScaleValue = NSTextField(labelWithString: "")
    private let upscale = NSPopUpButton()
    private let upscalerKind = NSPopUpButton()
    private let gi = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let bounces = NSSlider()
    private let bouncesValue = NSTextField(labelWithString: "")
    private let blueNoise = NSButton(checkboxWithTitle: "Blue-noise sampling", target: nil, action: nil)
    private let paused = NSButton(checkboxWithTitle: "Pause animation", target: nil, action: nil)
    private let viewMode = NSPopUpButton()
    private let denoise = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let separate = NSButton(checkboxWithTitle: "Separate direct / indirect", target: nil, action: nil)
    private let shadowDenoiser = NSButton(checkboxWithTitle: "Shadow denoiser (direct light)", target: nil, action: nil)
    private let shadowPasses = NSSlider()
    private let shadowPassesValue = NSTextField(labelWithString: "")
    private let passes = NSSlider()
    private let passesValue = NSTextField(labelWithString: "")
    private let sigma = NSSlider()
    private let sigmaValue = NSTextField(labelWithString: "")
    private let history = NSSlider()
    private let historyValue = NSTextField(labelWithString: "")
    private let antiLag = NSSlider()
    private let antiLagValue = NSTextField(labelWithString: "")
    // Global illumination
    private let giMode = NSPopUpButton()
    private let lightMaps = NSButton(checkboxWithTitle: "Light bounces from light maps", target: nil, action: nil)
    private let probeSpacing = NSPopUpButton()
    private let cascadeCount = NSSlider()
    private let cascadeCountValue = NSTextField(labelWithString: "")
    private let firstInterval = NSSlider()
    private let firstIntervalValue = NSTextField(labelWithString: "")
    private let cascadeBounce = NSButton(checkboxWithTitle: "Multi-bounce", target: nil, action: nil)
    private let cascadeDenoise = NSButton(checkboxWithTitle: "Denoise cascade GI", target: nil, action: nil)
    private let rgiRays = NSPopUpButton()
    private let rgiBounces = NSSlider()
    private let rgiBouncesValue = NSTextField(labelWithString: "")
    private let rgiSpatial = NSPopUpButton()
    private let rgiTemporal = NSButton(checkboxWithTitle: "Temporal reuse", target: nil, action: nil)
    private let rgiUnbiased = NSButton(checkboxWithTitle: "Unbiased spatial reuse", target: nil, action: nil)
    private let rgiFeedback = NSButton(checkboxWithTitle: "Multi-bounce", target: nil, action: nil)
    // Fog
    private let fog = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let fogDensity = NSSlider()            // log10 of the density
    private let fogDensityValue = NSTextField(labelWithString: "")
    private let fogFalloff = NSSlider()
    private let fogFalloffValue = NSTextField(labelWithString: "")
    private let fogAnisotropy = NSSlider()
    private let fogAnisotropyValue = NSTextField(labelWithString: "")
    private let fogAmbient = NSSlider()
    private let fogAmbientValue = NSTextField(labelWithString: "")
    private let fogNoise = NSSlider()
    private let fogNoiseValue = NSTextField(labelWithString: "")
    private let fogDistance = NSSlider()
    private let fogDistanceValue = NSTextField(labelWithString: "")
    private let fogVolumes = NSButton(checkboxWithTitle: "Local fog volumes", target: nil, action: nil)
    private let fogReflections = NSButton(checkboxWithTitle: "Fog in reflections", target: nil, action: nil)
    // Sky
    private let skyMode = NSPopUpButton()
    private let clouds = NSButton(checkboxWithTitle: "Clouds", target: nil, action: nil)
    private let coverage = NSSlider()
    private let coverageValue = NSTextField(labelWithString: "")
    private let cloudDensity = NSSlider()
    private let cloudDensityValue = NSTextField(labelWithString: "")
    private let cloudHeight = NSSlider()
    private let cloudHeightValue = NSTextField(labelWithString: "")
    private let wind = NSSlider()
    private let windValue = NSTextField(labelWithString: "")
    private let cloudShadows = NSButton(checkboxWithTitle: "Cloud shadows", target: nil, action: nil)
    private let skyImageButton = NSButton(title: "Choose Image…", target: nil, action: nil)
    private var grid: NSGridView!
    private var modeRows: [GIMode: [Int]] = [:]   // grid rows shown only in that GI mode
    private var stressRows: [Int] = []             // grid rows shown only for the stress scene
    private var lightCountRows: [Int] = []         // grid rows shown only for scenes with a light count (stress, market)
    private var groupedRows: [Int] = []            // grid rows shown only for the grouped direct light
    private var restirRows: [Int] = []             // grid rows shown only for ReSTIR (or Auto)
    private var fogRows: [Int] = []                // grid rows shown only while fog is on
    private var cloudRows: [Int] = []              // grid rows shown only with an atmosphere or image sky
    private var imageRows: [Int] = []              // grid rows shown only with an image sky

    init(renderer: Renderer) {
        self.renderer = renderer
        upscaleSteps = renderer.upscaleSteps
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Render Settings"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true   // sliders and checkboxes don't need key status
        panel.hidesOnDeactivate = true

        configureSlider(renderScale, RenderSettings.renderScaleRange, ticks: 15, #selector(renderScaleChanged))
        configureSlider(bounces, CGFloat(RenderSettings.bounceRange.lowerBound)...CGFloat(RenderSettings.bounceRange.upperBound),
                        ticks: RenderSettings.bounceRange.count, #selector(bouncesChanged))
        configureSlider(passes, CGFloat(DenoiserSettings.passRange.lowerBound)...CGFloat(DenoiserSettings.passRange.upperBound),
                        ticks: DenoiserSettings.passRange.count, #selector(passesChanged))
        configureSlider(shadowPasses, CGFloat(DenoiserSettings.passRange.lowerBound)...CGFloat(DenoiserSettings.passRange.upperBound),
                        ticks: DenoiserSettings.passRange.count, #selector(shadowPassesChanged))
        configureSlider(sigma, cg(DenoiserSettings.luminanceSigmaRange), ticks: 0, #selector(sigmaChanged))
        configureSlider(history, cg(DenoiserSettings.maxHistoryRange), ticks: 0, #selector(historyChanged))
        configureSlider(antiLag, cg(DenoiserSettings.antiLagRange), ticks: 0, #selector(antiLagChanged))
        configureSlider(cascadeCount, CGFloat(CascadeSettings.cascadeRange.lowerBound)...CGFloat(CascadeSettings.cascadeRange.upperBound),
                        ticks: CascadeSettings.cascadeRange.count, #selector(cascadeCountChanged))
        configureSlider(firstInterval, cg(CascadeSettings.firstIntervalRange), ticks: 0, #selector(firstIntervalChanged))
        configureSlider(rgiBounces, CGFloat(RenderSettings.bounceRange.lowerBound)...CGFloat(RenderSettings.bounceRange.upperBound),
                        ticks: RenderSettings.bounceRange.count, #selector(rgiBouncesChanged))
        configureSlider(fogDensity, log10(CGFloat(FogSettings.densityRange.lowerBound))...log10(CGFloat(FogSettings.densityRange.upperBound)),
                        ticks: 0, #selector(fogDensityChanged))
        configureSlider(fogFalloff, cg(FogSettings.falloffRange), ticks: 0, #selector(fogFalloffChanged))
        configureSlider(fogAnisotropy, cg(FogSettings.anisotropyRange), ticks: 0, #selector(fogAnisotropyChanged))
        configureSlider(fogAmbient, cg(FogSettings.ambientRange), ticks: 0, #selector(fogAmbientChanged))
        configureSlider(fogNoise, cg(FogSettings.noiseRange), ticks: 0, #selector(fogNoiseChanged))
        configureSlider(fogDistance, cg(FogSettings.distanceRange), ticks: 0, #selector(fogDistanceChanged))
        configureSlider(coverage, cg(SkySettings.coverageRange), ticks: 0, #selector(coverageChanged))
        configureSlider(cloudDensity, cg(SkySettings.densityRange), ticks: 0, #selector(cloudDensityChanged))
        configureSlider(cloudHeight, cg(SkySettings.cloudBaseRange), ticks: 0, #selector(cloudHeightChanged))
        configureSlider(wind, cg(SkySettings.windRange), ticks: 0, #selector(windChanged))
        // Scene sizes rebuild the scene, so they apply when the slider is released.
        configureSlider(objects, CGFloat(SceneSettings.objectRange.lowerBound)...CGFloat(SceneSettings.objectRange.upperBound),
                        ticks: 0, #selector(objectsChanged))
        configureSlider(lights, 0...log2(CGFloat(SceneSettings.lightRange.upperBound)),
                        ticks: Int(log2(Double(SceneSettings.lightRange.upperBound))) + 1, #selector(lightsChanged))
        objects.isContinuous = false
        lights.isContinuous = false
        configureSlider(vgError, log2(CGFloat(VirtualGeometrySettings.pixelErrorRange.lowerBound))...log2(CGFloat(VirtualGeometrySettings.pixelErrorRange.upperBound)),
                        ticks: 0, #selector(vgErrorChanged))
        for (popup, titles, action) in [
            (giMode, GIMode.allCases.map(\.title), #selector(giModeChanged)),
            (sceneKind, SceneKind.allCases.map(\.title), #selector(sceneKindChanged)),
            (rayTracer, RayTracerKind.allCases.map(\.title), #selector(rayTracerChanged)),
            (lightRays, ["1 per group (fastest)", "1 per group + reuse", "2 per group (least noise)"], #selector(lightRaysChanged)),
            (upscalerKind, UpscalerKind.allCases.map(\.title), #selector(upscalerKindChanged)),
            (probeSpacing, CascadeSettings.spacingOptions.map { "\($0) px" }, #selector(probeSpacingChanged)),
            (skyMode, SkyMode.allCases.map(\.title), #selector(skyModeChanged)),
            (directLight, DirectLightMode.allCases.map { $0 == .auto ? "Auto (ReSTIR above 256 lights)" : $0.title }, #selector(directLightChanged)),
            (restirCandidates, SettingsPanel.candidateOptions.map { "\($0) per pixel" }, #selector(restirCandidatesChanged)),
            (restirSpatial, ["Off", "1 pass", "2 passes"], #selector(restirSpatialChanged)),
            (rgiRays, ["1 per pixel", "1 per 2×2 pixels"], #selector(rgiRaysChanged)),
            (rgiSpatial, ["Off", "1 pass", "2 passes"], #selector(rgiSpatialChanged)),
        ] as [(NSPopUpButton, [String], Selector)] {
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = action
        }

        upscale.addItems(withTitles: upscaleSteps.map { $0 == 0 ? "Off" : String(format: "%g×", $0) })
        upscale.target = self
        upscale.action = #selector(upscaleChanged)
        upscale.isEnabled = upscaleSteps.count > 1
        viewMode.addItems(withTitles: RenderSettings.viewModes)
        viewMode.target = self
        viewMode.action = #selector(viewModeChanged)
        for (box, action) in [(gi, #selector(giChanged)), (blueNoise, #selector(blueNoiseChanged)),
                              (paused, #selector(pausedChanged)), (denoise, #selector(denoiseChanged)),
                              (separate, #selector(separateChanged)), (lightMaps, #selector(lightMapsChanged)),
                              (cascadeBounce, #selector(cascadeBounceChanged)), (cascadeDenoise, #selector(cascadeDenoiseChanged)),
                              (shadowDenoiser, #selector(shadowDenoiserChanged)), (virtualGeometry, #selector(virtualGeometryChanged)),
                              (freezeLOD, #selector(freezeLODChanged)),
                              (specular, #selector(specularChanged)), (emissiveLights, #selector(emissiveLightsChanged)),
                              (fog, #selector(fogChanged)), (fogVolumes, #selector(fogVolumesChanged)),
                              (fogReflections, #selector(fogReflectionsChanged)), (clouds, #selector(cloudsChanged)),
                              (cloudShadows, #selector(cloudShadowsChanged)), (skyImageButton, #selector(chooseSkyImage)),
                              (restirTemporal, #selector(restirTemporalChanged)), (restirVisibility, #selector(restirVisibilityChanged)),
                              (rgiTemporal, #selector(rgiTemporalChanged)), (rgiUnbiased, #selector(rgiUnbiasedChanged)),
                              (rgiFeedback, #selector(rgiFeedbackChanged))] {
            box.target = self
            box.action = action
        }
        stats.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        stats.textColor = .secondaryLabelColor
        for value in [vgErrorValue, objectsValue, lightsValue, renderScaleValue, bouncesValue, rgiBouncesValue, passesValue, shadowPassesValue, sigmaValue, historyValue, antiLagValue,
                      cascadeCountValue, firstIntervalValue, fogDensityValue, fogFalloffValue,
                      fogAnisotropyValue, fogAmbientValue, fogNoiseValue, fogDistanceValue, coverageValue, cloudDensityValue,
                      cloudHeightValue, windValue] {
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.alignment = .right
        }

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let rows: [[NSView]] = [
            [header("Scene")],
            [label("Scene"), sceneKind],
            [label("Objects"), objects, objectsValue],                       // stress
            [label("Lights"), lights, lightsValue],                          // stress, market
            [label("Ray tracing"), rayTracer],
            [NSGridCell.emptyContentView, virtualGeometry],
            [label("Geometry error"), vgError, vgErrorValue],
            [NSGridCell.emptyContentView, freezeLOD],
            [NSGridCell.emptyContentView, specular],
            [NSGridCell.emptyContentView, emissiveLights],
            [header("Direct light")],
            [label("Method"), directLight],
            [label("Shadow rays"), lightRays],                               // grouped
            [label("Candidates"), restirCandidates],                         // ReSTIR
            [label("Spatial reuse"), restirSpatial],                         // ReSTIR
            [NSGridCell.emptyContentView, restirTemporal],                   // ReSTIR
            [NSGridCell.emptyContentView, restirVisibility],                 // ReSTIR
            [header("Rendering")],
            [label("Render scale"), renderScale, renderScaleValue],
            [label("MetalFX upscaling"), upscale],
            [label("Upscaler"), upscalerKind],
            [NSGridCell.emptyContentView, blueNoise],
            [NSGridCell.emptyContentView, paused],
            [label("View"), viewMode],
            [header("Global illumination")],
            [NSGridCell.emptyContentView, gi],
            [label("Method"), giMode],
            [label("Bounces"), bounces, bouncesValue],                       // path traced
            [NSGridCell.emptyContentView, lightMaps],                        // path traced
            [label("Probe spacing"), probeSpacing],                          // cascades
            [label("Cascades"), cascadeCount, cascadeCountValue],            // cascades
            [label("First interval"), firstInterval, firstIntervalValue],    // cascades
            [NSGridCell.emptyContentView, cascadeBounce],                    // cascades
            [NSGridCell.emptyContentView, cascadeDenoise],                   // cascades
            [label("Rays"), rgiRays],                                        // ReSTIR GI
            [label("Bounces"), rgiBounces, rgiBouncesValue],                 // ReSTIR GI
            [NSGridCell.emptyContentView, rgiFeedback],                      // ReSTIR GI
            [NSGridCell.emptyContentView, rgiTemporal],                      // ReSTIR GI
            [label("Spatial reuse"), rgiSpatial],                            // ReSTIR GI
            [NSGridCell.emptyContentView, rgiUnbiased],                      // ReSTIR GI
            [header("Fog")],
            [NSGridCell.emptyContentView, fog],
            [label("Density"), fogDensity, fogDensityValue],
            [label("Height falloff"), fogFalloff, fogFalloffValue],
            [label("Forward scattering"), fogAnisotropy, fogAnisotropyValue],
            [label("Ambient light"), fogAmbient, fogAmbientValue],
            [label("Noise"), fogNoise, fogNoiseValue],
            [label("Distance"), fogDistance, fogDistanceValue],
            [NSGridCell.emptyContentView, fogVolumes],
            [NSGridCell.emptyContentView, fogReflections],
            [header("Sky")],
            [label("Sky"), skyMode],
            [NSGridCell.emptyContentView, skyImageButton],
            [NSGridCell.emptyContentView, clouds],
            [label("Coverage"), coverage, coverageValue],
            [label("Cloud density"), cloudDensity, cloudDensityValue],
            [label("Cloud height"), cloudHeight, cloudHeightValue],
            [label("Wind"), wind, windValue],
            [NSGridCell.emptyContentView, cloudShadows],
            [header("Denoiser")],
            [NSGridCell.emptyContentView, denoise],
            [NSGridCell.emptyContentView, shadowDenoiser],
            [label("Shadow passes"), shadowPasses, shadowPassesValue],
            [NSGridCell.emptyContentView, separate],
            [label("Filter passes"), passes, passesValue],
            [label("Edge tolerance (σ)"), sigma, sigmaValue],
            [label("History length"), history, historyValue],
            [label("Anti-lag"), antiLag, antiLagValue],
            [NSGridCell.emptyContentView, reset],
            [stats],
        ]
        func rowsOf(_ views: [NSView]) -> [Int] { views.compactMap { v in rows.firstIndex { $0.contains(v) } } }
        stressRows = rowsOf([objects])
        lightCountRows = rowsOf([lights])
        groupedRows = rowsOf([lightRays])
        restirRows = rowsOf([restirCandidates, restirSpatial, restirTemporal, restirVisibility])
        fogRows = rowsOf([fogDensity, fogFalloff, fogAnisotropy, fogAmbient, fogNoise, fogDistance, fogVolumes, fogReflections])
        cloudRows = rowsOf([clouds, coverage, cloudDensity, cloudHeight, wind, cloudShadows])
        imageRows = rowsOf([skyImageButton])
        modeRows = [.pathTraced: rowsOf([bounces, lightMaps]),
                    .radianceCascades: rowsOf([probeSpacing, cascadeCount, firstInterval, cascadeBounce, cascadeDenoise]),
                    .restirGI: rowsOf([rgiRays, rgiBounces, rgiFeedback, rgiTemporal, rgiSpatial, rgiUnbiased])]
        let grid = NSGridView(views: rows)
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 170
        grid.column(at: 2).width = 64
        for row in 0..<grid.numberOfRows where grid.cell(atColumnIndex: 0, rowIndex: row).contentView is HeaderLabel
                                               || grid.cell(atColumnIndex: 0, rowIndex: row).contentView === stats {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 3), verticalRange: NSRange(location: row, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
            if row > 0 { grid.row(at: row).topPadding = 8 }
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)

        update(from: renderer.settings)
        resizeToFit()
        renderer.onSettingsChanged = { [weak self] in self?.update(from: $0) }
        renderer.onStats = { [weak self] in self?.stats.stringValue = $0 }
    }

    /// Shows the panel beside `window`, or inside its top-right corner if the screen has no room.
    func show(nextTo window: NSWindow) {
        let frame = window.frame, size = panel.frame.size
        let visible = window.screen?.visibleFrame ?? frame
        var origin = NSPoint(x: frame.maxX + 8, y: frame.maxY - size.height)
        if origin.x + size.width > visible.maxX { origin.x = frame.maxX - size.width - 12; origin.y -= 28 }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible { panel.orderOut(nil) } else { show(nextTo: window) }
    }

    /// Fits the panel to its visible rows, keeping its top edge in place.
    private func resizeToFit() {
        guard let content = panel.contentView else { return }
        let top = panel.frame.maxY
        panel.setContentSize(content.fittingSize)
        if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    // MARK: - Settings -> controls

    private func update(from s: RenderSettings) {
        var layoutChanged = false
        for (mode, rowIndices) in modeRows {
            for r in rowIndices where grid.row(at: r).isHidden != (mode != s.giMode) {
                grid.row(at: r).isHidden = mode != s.giMode
                layoutChanged = true
            }
        }
        for (rows, shown) in [(stressRows, s.scene.kind == .stress), (lightCountRows, s.scene.kind.hasLightCount),
                              (groupedRows, s.directLight == .grouped), (restirRows, s.directLight == .restir || s.directLight == .auto)] {
            for r in rows where grid.row(at: r).isHidden != !shown {
                grid.row(at: r).isHidden = !shown
                layoutChanged = true
            }
        }
        for r in fogRows where grid.row(at: r).isHidden != !s.fog.enabled {
            grid.row(at: r).isHidden = !s.fog.enabled
            layoutChanged = true
        }
        for (rows, shown) in [(cloudRows, s.sky.mode != .constant), (imageRows, s.sky.mode == .image)] {
            for r in rows where grid.row(at: r).isHidden != !shown {
                grid.row(at: r).isHidden = !shown
                layoutChanged = true
            }
        }
        if layoutChanged { resizeToFit() }
        sceneKind.selectItem(at: s.scene.kind.rawValue)
        rayTracer.selectItem(at: s.rayTracer.rawValue)
        virtualGeometry.state = s.virtualGeometry.enabled ? .on : .off
        specular.state = s.specular ? .on : .off
        virtualGeometry.isEnabled = s.rayTracer == .custom   // Metal would need its acceleration structures rebuilt per cut
        vgError.doubleValue = Double(log2(s.virtualGeometry.pixelError))
        vgErrorValue.stringValue = String(format: "%.2g px", s.virtualGeometry.pixelError)
        vgError.isEnabled = s.rayTracer == .custom && s.virtualGeometry.enabled
        freezeLOD.state = s.virtualGeometry.freeze ? .on : .off
        emissiveLights.state = s.scene.emissiveLights ? .on : .off
        freezeLOD.isEnabled = vgError.isEnabled
        objects.integerValue = s.scene.objects
        objectsValue.stringValue = "\(s.scene.objects)"
        lights.doubleValue = log2(Double(max(s.scene.lights, 1)))
        lightsValue.stringValue = "\(s.scene.lights)"
        lightRays.selectItem(at: s.manyLightRays >= 2 ? 2 : s.manyLightReuse > 0 ? 1 : 0)
        directLight.selectItem(at: s.directLight.rawValue)
        restirCandidates.selectItem(at: SettingsPanel.candidateOptions.firstIndex { $0 >= s.restir.candidates } ?? 1)
        restirSpatial.selectItem(at: RestirSettings.spatialPassRange.clamp(s.restir.spatialPasses))
        restirTemporal.state = s.restir.temporal ? .on : .off
        restirVisibility.state = s.restir.visibilityReuse ? .on : .off
        lightRays.isEnabled = s.scene.lights > 4
        giMode.selectItem(at: s.giMode.rawValue)
        lightMaps.state = s.lightMaps ? .on : .off
        let c = s.cascades
        probeSpacing.selectItem(at: CascadeSettings.spacingOptions.firstIndex(of: c.probeSpacing) ?? 1)
        cascadeCount.integerValue = c.cascades
        cascadeCountValue.stringValue = "\(c.cascades)"
        firstInterval.doubleValue = Double(c.firstInterval)
        firstIntervalValue.stringValue = String(format: "%.2f m", c.firstInterval)
        cascadeBounce.state = c.feedback ? .on : .off
        cascadeDenoise.state = c.denoiseIndirect ? .on : .off
        let rg = s.restirGI
        rgiRays.selectItem(at: rg.quarterBudget ? 1 : 0)
        rgiBounces.integerValue = rg.bounces
        rgiBouncesValue.stringValue = "\(rg.bounces)"
        rgiFeedback.state = rg.feedback ? .on : .off
        rgiTemporal.state = rg.temporal ? .on : .off
        rgiSpatial.selectItem(at: RestirGISettings.spatialPassRange.clamp(rg.spatialPasses))
        rgiUnbiased.state = rg.unbiased ? .on : .off
        rgiUnbiased.isEnabled = s.giEnabled && rg.spatialPasses > 0
        for control in [giMode, lightMaps, probeSpacing, cascadeCount, firstInterval, cascadeBounce, cascadeDenoise,
                        rgiRays, rgiBounces, rgiFeedback, rgiTemporal, rgiSpatial] as [NSControl] {
            control.isEnabled = s.giEnabled
        }

        let f = s.fog
        fog.state = f.enabled ? .on : .off
        fogDensity.doubleValue = Double(log10(FogSettings.densityRange.clamp(f.density)))
        fogDensityValue.stringValue = String(format: "%.3g /m", f.density)
        fogFalloff.doubleValue = Double(f.heightFalloff)
        fogFalloffValue.stringValue = String(format: "%.2f /m", f.heightFalloff)
        fogAnisotropy.doubleValue = Double(f.anisotropy)
        fogAnisotropyValue.stringValue = String(format: "%.2f", f.anisotropy)
        fogAmbient.doubleValue = Double(f.ambient)
        fogAmbientValue.stringValue = String(format: "%.2f", f.ambient)
        fogNoise.doubleValue = Double(f.noise)
        fogNoiseValue.stringValue = String(format: "%.2f", f.noise)
        fogDistance.doubleValue = Double(f.maxDistance)
        fogDistanceValue.stringValue = String(format: "%.0f m", f.maxDistance)
        fogVolumes.state = f.volumes ? .on : .off
        fogReflections.state = f.reflections ? .on : .off
        let sky = s.sky
        skyMode.selectItem(at: sky.mode.rawValue)
        clouds.state = (sky.mode == .image ? sky.cloudsOverImage : sky.clouds) ? .on : .off   // over an image: in front of it
        coverage.doubleValue = Double(sky.coverage)
        coverageValue.stringValue = String(format: "%.2f", sky.coverage)
        cloudDensity.doubleValue = Double(sky.density)
        cloudDensityValue.stringValue = String(format: "%.3f /m", sky.density)
        cloudHeight.doubleValue = Double(sky.cloudBase)
        cloudHeightValue.stringValue = String(format: "%.0f m", sky.cloudBase)
        wind.doubleValue = Double(sky.windSpeed)
        windValue.stringValue = String(format: "%.0f m/s", sky.windSpeed)
        cloudShadows.state = sky.shadows ? .on : .off
        skyImageButton.title = sky.imagePath.map { "Image: " + ($0 as NSString).lastPathComponent } ?? "Choose Image…"
        for control in [coverage, cloudDensity, cloudHeight, wind, cloudShadows] as [NSControl] {
            control.isEnabled = sky.mode == .image ? sky.cloudsOverImage : sky.clouds
        }

        renderScale.doubleValue = Double(s.renderScale)
        renderScaleValue.stringValue = String(format: "%.3g×", s.renderScale)
        upscale.selectItem(at: upscaleSteps.firstIndex(of: s.upscaleFactor) ?? 0)
        upscalerKind.selectItem(at: s.upscaler.rawValue)
        upscalerKind.isEnabled = upscaleSteps.count > 1 && s.upscaleFactor > 1
        gi.state = s.giEnabled ? .on : .off
        bounces.integerValue = s.bounces
        bouncesValue.stringValue = "\(s.bounces)"
        bounces.isEnabled = s.giEnabled
        blueNoise.state = s.blueNoise ? .on : .off
        paused.state = s.paused ? .on : .off
        viewMode.selectItem(at: s.viewMode)

        let d = s.denoiser
        denoise.state = d.enabled ? .on : .off
        separate.state = d.separateSignals ? .on : .off
        passes.integerValue = d.passes(for: s.giMode)   // the slider edits the count of the selected GI method
        passesValue.stringValue = "\(d.passes(for: s.giMode))"
        sigma.doubleValue = Double(d.luminanceSigma)
        sigmaValue.stringValue = String(format: "%.2f", d.luminanceSigma)
        history.doubleValue = Double(d.maxHistory)
        historyValue.stringValue = String(format: "%.0f fr", d.maxHistory)
        antiLag.doubleValue = Double(d.antiLag)
        antiLagValue.stringValue = d.antiLag == 0 ? "off" : String(format: "%.1f", d.antiLag)
        shadowDenoiser.state = d.shadowDenoiser ? .on : .off
        shadowPasses.integerValue = d.shadowPasses
        shadowPassesValue.stringValue = "\(d.shadowPasses)"
        for control in [separate, passes, sigma, history, antiLag, shadowDenoiser] as [NSControl] { control.isEnabled = d.enabled }
        shadowPasses.isEnabled = d.enabled && d.shadowDenoiser
    }

    // MARK: - Controls -> settings

    @objc private func renderScaleChanged() {
        let step = RenderSettings.renderScaleStep
        renderer.settings.renderScale = (CGFloat(renderScale.doubleValue) / step).rounded() * step
    }
    @objc private func upscaleChanged() { renderer.settings.upscaleFactor = upscaleSteps[upscale.indexOfSelectedItem] }
    @objc private func upscalerKindChanged() {
        renderer.settings.upscaler = UpscalerKind(rawValue: upscalerKind.indexOfSelectedItem) ?? .metalFX
    }
    @objc private func giChanged() { renderer.settings.giEnabled = gi.state == .on }
    @objc private func bouncesChanged() { renderer.settings.bounces = Int(bounces.doubleValue.rounded()) }
    @objc private func blueNoiseChanged() { renderer.settings.blueNoise = blueNoise.state == .on }
    @objc private func pausedChanged() { renderer.settings.paused = paused.state == .on }
    @objc private func viewModeChanged() { renderer.settings.viewMode = viewMode.indexOfSelectedItem }
    @objc private func denoiseChanged() { renderer.settings.denoiser.enabled = denoise.state == .on }
    @objc private func separateChanged() { renderer.settings.denoiser.separateSignals = separate.state == .on }
    @objc private func passesChanged() {
        let n = Int(passes.doubleValue.rounded())
        if renderer.settings.giMode == .pathTraced { renderer.settings.denoiser.atrousPasses = n }
        else { renderer.settings.denoiser.techniquePasses = n }
    }
    @objc private func shadowDenoiserChanged() { renderer.settings.denoiser.shadowDenoiser = shadowDenoiser.state == .on }
    @objc private func shadowPassesChanged() { renderer.settings.denoiser.shadowPasses = Int(shadowPasses.doubleValue.rounded()) }
    @objc private func sigmaChanged() { renderer.settings.denoiser.luminanceSigma = Float((sigma.doubleValue * 20).rounded() / 20) }
    @objc private func historyChanged() { renderer.settings.denoiser.maxHistory = Float(history.doubleValue.rounded()) }
    @objc private func antiLagChanged() { renderer.settings.denoiser.antiLag = Float((antiLag.doubleValue * 10).rounded() / 10) }
    @objc private func resetToDefaults() {
        var s = renderer.defaultSettings
        s.scene = renderer.settings.scene   // render settings only; the loaded scene and tracer stay
        s.rayTracer = renderer.settings.rayTracer
        s.applySceneDefaults(from: renderer.defaultSettings)
        renderer.settings = s
    }
    @objc private func specularChanged() { renderer.settings.specular = specular.state == .on }
    @objc private func emissiveLightsChanged() { renderer.settings.scene.emissiveLights = emissiveLights.state == .on }
    @objc private func freezeLODChanged() { renderer.settings.virtualGeometry.freeze = freezeLOD.state == .on }
    @objc private func virtualGeometryChanged() { renderer.settings.virtualGeometry.enabled = virtualGeometry.state == .on }
    @objc private func vgErrorChanged() {
        renderer.settings.virtualGeometry.pixelError = Float((pow(2, vgError.doubleValue) * 4).rounded() / 4)
    }
    @objc private func rayTracerChanged() {
        renderer.settings.rayTracer = RayTracerKind(rawValue: rayTracer.indexOfSelectedItem) ?? .custom
    }
    @objc private func sceneKindChanged() {
        var s = renderer.settings
        s.scene.kind = SceneKind(rawValue: sceneKind.indexOfSelectedItem) ?? .cornell
        guard s.scene.kind != renderer.settings.scene.kind else { return }
        s.scene.extraModels = []   // opened / dropped models belong to the scene they were added to
        s.applySceneDefaults(from: renderer.defaultSettings)   // e.g. the night market's light count
        renderer.settings = s
    }
    @objc private func objectsChanged() { renderer.settings.scene.objects = Int((objects.doubleValue / 50).rounded()) * 50 }
    @objc private func lightRaysChanged() {
        let choice = lightRays.indexOfSelectedItem   // 0: 1 ray, 1: 1 ray + reuse, 2: 2 rays
        renderer.settings.manyLightRays = choice == 2 ? 2 : 1
        renderer.settings.manyLightReuse = choice == 1 ? renderer.defaultSettings.manyLightReuse : 0
    }
    @objc private func directLightChanged() {
        renderer.settings.directLight = DirectLightMode(rawValue: directLight.indexOfSelectedItem) ?? .auto
    }
    @objc private func restirCandidatesChanged() {
        renderer.settings.restir.candidates = SettingsPanel.candidateOptions[restirCandidates.indexOfSelectedItem]
    }
    @objc private func restirSpatialChanged() { renderer.settings.restir.spatialPasses = restirSpatial.indexOfSelectedItem }
    @objc private func restirTemporalChanged() { renderer.settings.restir.temporal = restirTemporal.state == .on }
    @objc private func restirVisibilityChanged() { renderer.settings.restir.visibilityReuse = restirVisibility.state == .on }
    @objc private func lightsChanged() { renderer.settings.scene.lights = 1 << Int(lights.doubleValue.rounded()) }
    @objc private func giModeChanged() { renderer.settings.giMode = GIMode(rawValue: giMode.indexOfSelectedItem) ?? .pathTraced }
    @objc private func lightMapsChanged() { renderer.settings.lightMaps = lightMaps.state == .on }
    @objc private func probeSpacingChanged() { renderer.settings.cascades.probeSpacing = CascadeSettings.spacingOptions[probeSpacing.indexOfSelectedItem] }
    @objc private func cascadeCountChanged() { renderer.settings.cascades.cascades = Int(cascadeCount.doubleValue.rounded()) }
    @objc private func firstIntervalChanged() { renderer.settings.cascades.firstInterval = Float((firstInterval.doubleValue * 20).rounded() / 20) }
    @objc private func cascadeBounceChanged() { renderer.settings.cascades.feedback = cascadeBounce.state == .on }
    @objc private func cascadeDenoiseChanged() { renderer.settings.cascades.denoiseIndirect = cascadeDenoise.state == .on }
    @objc private func rgiRaysChanged() { renderer.settings.restirGI.quarterBudget = rgiRays.indexOfSelectedItem == 1 }
    @objc private func rgiBouncesChanged() { renderer.settings.restirGI.bounces = Int(rgiBounces.doubleValue.rounded()) }
    @objc private func rgiFeedbackChanged() { renderer.settings.restirGI.feedback = rgiFeedback.state == .on }
    @objc private func rgiTemporalChanged() { renderer.settings.restirGI.temporal = rgiTemporal.state == .on }
    @objc private func rgiSpatialChanged() { renderer.settings.restirGI.spatialPasses = rgiSpatial.indexOfSelectedItem }
    @objc private func rgiUnbiasedChanged() { renderer.settings.restirGI.unbiased = rgiUnbiased.state == .on }
    @objc private func fogChanged() { renderer.settings.fog.enabled = fog.state == .on }
    @objc private func fogDensityChanged() {
        let d = pow(10, fogDensity.doubleValue)   // two significant digits
        let scale = pow(10, floor(log10(d)) - 1)
        renderer.settings.fog.density = Float((d / scale).rounded() * scale)
    }
    @objc private func fogFalloffChanged() { renderer.settings.fog.heightFalloff = Float((fogFalloff.doubleValue * 100).rounded() / 100) }
    @objc private func fogAnisotropyChanged() { renderer.settings.fog.anisotropy = Float((fogAnisotropy.doubleValue * 20).rounded() / 20) }
    @objc private func fogAmbientChanged() { renderer.settings.fog.ambient = Float((fogAmbient.doubleValue * 20).rounded() / 20) }
    @objc private func fogNoiseChanged() { renderer.settings.fog.noise = Float((fogNoise.doubleValue * 20).rounded() / 20) }
    @objc private func fogDistanceChanged() { renderer.settings.fog.maxDistance = Float((fogDistance.doubleValue / 5).rounded() * 5) }
    @objc private func fogVolumesChanged() { renderer.settings.fog.volumes = fogVolumes.state == .on }
    @objc private func fogReflectionsChanged() { renderer.settings.fog.reflections = fogReflections.state == .on }
    @objc private func skyModeChanged() {
        let mode = SkyMode(rawValue: skyMode.indexOfSelectedItem) ?? .constant
        if mode == .image && renderer.settings.sky.imagePath == nil { chooseSkyImage(); return }
        renderer.settings.sky.mode = mode
    }
    @objc private func chooseSkyImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SkyImage.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an equirectangular HDR image (.hdr or .exr) for the sky"
        if panel.runModal() == .OK, let url = panel.url { renderer.addModels([url]) } else { update(from: renderer.settings) }
    }
    @objc private func cloudsChanged() {
        if renderer.settings.sky.mode == .image { renderer.settings.sky.cloudsOverImage = clouds.state == .on }
        else { renderer.settings.sky.clouds = clouds.state == .on }
    }
    @objc private func coverageChanged() { renderer.settings.sky.coverage = Float((coverage.doubleValue * 100).rounded() / 100) }
    @objc private func cloudDensityChanged() { renderer.settings.sky.density = Float((cloudDensity.doubleValue * 1000).rounded() / 1000) }
    @objc private func cloudHeightChanged() { renderer.settings.sky.cloudBase = Float((cloudHeight.doubleValue / 50).rounded() * 50) }
    @objc private func windChanged() { renderer.settings.sky.windSpeed = Float(wind.doubleValue.rounded()) }
    @objc private func cloudShadowsChanged() { renderer.settings.sky.shadows = cloudShadows.state == .on }

    // MARK: - Helpers

    private final class HeaderLabel: NSTextField {}

    private func header(_ text: String) -> NSView {
        let h = HeaderLabel(labelWithString: text)
        h.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return h
    }

    private func label(_ text: String) -> NSView { NSTextField(labelWithString: text) }

    private func cg(_ r: ClosedRange<Float>) -> ClosedRange<CGFloat> { CGFloat(r.lowerBound)...CGFloat(r.upperBound) }

    private func configureSlider(_ slider: NSSlider, _ range: ClosedRange<CGFloat>, ticks: Int, _ action: Selector) {
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.numberOfTickMarks = ticks
        slider.allowsTickMarkValuesOnly = ticks > 0
        slider.isContinuous = true
        slider.target = self
        slider.action = action
    }
}
