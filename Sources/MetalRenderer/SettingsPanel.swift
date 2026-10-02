import AppKit
import UniformTypeIdentifiers

/// Floating panel with a control for every `RenderSettings` field, plus live resolution / fps / GPU time.
/// It never becomes the key window, so WASD and the keyboard shortcuts keep working while it's open.
/// Keyboard changes show up here too: the renderer reports every settings change through `onSettingsChanged`.
///
/// Rows sit in collapsible sections; each row may have a condition (shown only for some modes) and may be "advanced"
/// (shown only with Show advanced). The older rows have a property and an action each; the advanced ones are built
/// by the bind helpers at the end (`floatRow`, `intRow`, `checkRow`, `popupRow`), which pair a control with a key path.
final class SettingsPanel: NSObject {
    let panel: NSPanel
    private let renderer: Renderer
    private let upscaleSteps: [CGFloat]

    private let stats = NSTextField(labelWithString: "")
    private let passTimes = NSTextField(labelWithString: "")   // GPU pass timings, when profiling
    private let profile = NSButton(checkboxWithTitle: "GPU pass timings", target: nil, action: nil)
    private let showAdvancedBox = NSButton(checkboxWithTitle: "Show advanced", target: nil, action: nil)
    private let copyEnv = NSButton(title: "Copy as Env", target: nil, action: nil)
    private let denoiserCaption = NSTextField(wrappingLabelWithString: "")
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
    private let fogAlbedo = NSColorWell(style: .minimal)
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
    private let clearModels = NSButton(title: "Clear Added Models", target: nil, action: nil)

    private var grid: NSGridView!
    private var footer: NSStackView!
    private var userWidth: CGFloat?                // content size the user dragged the panel to; nil = fit the content
    private var userHeight: CGFloat?
    // Rows, as built by `add`: their condition, whether they're advanced, and their section's header row.
    private var rows: [[NSView]] = []
    private var rowCondition: [Int: (RenderSettings) -> Bool] = [:]
    private var advancedRows = Set<Int>()
    private var headerRows: [Int: SectionHeader] = [:]
    private var sectionOf: [Int] = []
    // Controls built by the bind helpers: their targets, and how each shows the settings.
    private var actions: [Action] = []
    private var refreshers: [(RenderSettings) -> Void] = []
    // Panel state kept between launches (the render settings themselves are saved by SettingsStore).
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "panel.collapsed") ?? [])
    private var showAdvanced = UserDefaults.standard.bool(forKey: "panel.advanced")

    init(renderer: Renderer) {
        self.renderer = renderer
        upscaleSteps = renderer.upscaleSteps
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Render Settings"
        panel.delegate = self
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
                              (rgiFeedback, #selector(rgiFeedbackChanged)), (clearModels, #selector(clearModelsChanged)),
                              (fogAlbedo, #selector(fogAlbedoChanged)), (showAdvancedBox, #selector(showAdvancedChanged)),
                              (profile, #selector(profileChanged)), (copyEnv, #selector(copyAsEnv))] as [(NSControl, Selector)] {
            box.target = self
            box.action = action
        }
        for label in [stats, passTimes] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        passTimes.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        passTimes.usesSingleLineMode = false
        passTimes.maximumNumberOfLines = 0
        denoiserCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        denoiserCaption.textColor = .secondaryLabelColor
        denoiserCaption.preferredMaxLayoutWidth = 330
        for value in [vgErrorValue, objectsValue, lightsValue, renderScaleValue, bouncesValue, rgiBouncesValue, passesValue, shadowPassesValue, sigmaValue, historyValue, antiLagValue,
                      cascadeCountValue, firstIntervalValue, fogDensityValue, fogFalloffValue,
                      fogAnisotropyValue, fogAmbientValue, fogNoiseValue, fogDistanceValue, coverageValue, cloudDensityValue,
                      cloudHeightValue, windValue] {
            styleValue(value)
        }
        buildRows()

        let grid = NSGridView(views: rows)
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = rows.filter { $0.count > 1 }.map { $0[0].fittingSize.width }.max() ?? 0
        grid.column(at: 2).width = 64
        // Sliders take any width the panel is dragged to; popups and checkboxes keep their own.
        for row in rows where row.count > 1 {
            guard let slider = row[1] as? NSSlider, let cell = grid.cell(for: slider) else { continue }
            cell.xPlacement = .fill
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
            slider.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        for (row, views) in rows.enumerated() where views.count == 1 {   // section headers and captions span the grid
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 3), verticalRange: NSRange(location: row, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
            if headerRows[row] != nil && row > 0 { grid.row(at: row).topPadding = 8 }
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = makeContent(grid: grid)

        profile.isHidden = !renderer.passProfilingSupported
        showAdvancedBox.state = showAdvanced ? .on : .off
        update(from: renderer.settings)
        resizeToFit()
        renderer.onSettingsChanged = { [weak self] in self?.update(from: $0) }
        renderer.onStats = { [weak self] in
            guard let self else { return }
            self.stats.stringValue = $0
            self.updateDenoiserCaption(self.renderer.settings)   // Auto's method follows the loaded scene's light count
        }
        renderer.onPassTimes = { [weak self] in self?.showPassTimes($0) }
    }

    // MARK: - Rows

    /// Every row, top to bottom. `add(_:advanced:when:)` records a row's condition; `section` starts a collapsible section.
    private func buildRows() {
        let isRestir: (RenderSettings) -> Bool = { $0.directLight == .restir || $0.directLight == .auto }
        let isRestirGI: (RenderSettings) -> Bool = { $0.giMode == .restirGI }
        let hasClouds: (RenderSettings) -> Bool = { $0.sky.mode != .constant }

        section("Scene")
        add([label("Scene"), sceneKind])
        add([label("Objects"), objects, objectsValue], when: { $0.scene.kind == .stress })
        add([label("Lights"), lights, lightsValue], when: { $0.scene.kind.hasLightCount })
        add([label("Ray tracing"), rayTracer])
        add([NSGridCell.emptyContentView, virtualGeometry])
        add([label("Geometry error"), vgError, vgErrorValue])
        add([NSGridCell.emptyContentView, freezeLOD])
        add([NSGridCell.emptyContentView, specular])
        add([NSGridCell.emptyContentView, emissiveLights])
        add([NSGridCell.emptyContentView, clearModels], when: { !$0.scene.extraModels.isEmpty })

        section("Camera and time")
        add(floatRow("Exposure", \.exposure, RenderSettings.exposureRange, step: 0.1) { String(format: "%+.1f EV", $0) })
        add(popupRow("Tone map", \.toneMap, ToneMap.allCases.map { ($0.title, $0) }))
        add(floatRow("Field of view", \.fovDegrees, RenderSettings.fovRange, step: 1) { String(format: "%.0f°", $0) })
        add(floatRow("Move speed", \.moveSpeed, RenderSettings.moveSpeedRange, step: 0.5, log: true) { String(format: "%g m/s", $0) })
        add([NSGridCell.emptyContentView, paused])
        add(floatRow("Time scale", \.timeScale, RenderSettings.timeScaleRange, step: 0.05) { String(format: "%.2f×", $0) })
        add(floatRow("Time of day", \.timeOfDay, 0...1, step: 0.01) { String(format: "%.0f%%", $0 * 100) },
            when: { $0.scene.kind.dayCycle != nil })

        section("Direct light")
        add([label("Method"), directLight])
        add([label("Shadow rays"), lightRays], when: { $0.directLight == .grouped })
        add(intRow("Pick reuse", \.manyLightReuse, RenderSettings.manyLightReuseRange) { $0 == 0 ? "off" : "\($0) fr" },
            advanced: true, when: { $0.directLight == .grouped && $0.manyLightRays < 2 })
        add([label("Candidates"), restirCandidates], when: isRestir)
        add([label("Spatial reuse"), restirSpatial], when: isRestir)
        add([NSGridCell.emptyContentView, restirTemporal], when: isRestir)
        add([NSGridCell.emptyContentView, restirVisibility], when: isRestir)
        add(intRow("Chains", \.restir.chains, RestirSettings.chainRange), advanced: true, when: isRestir)
        add(floatRow("Max M", \.restir.maxM, RestirSettings.maxMRange, step: 1, log: true) { String(format: "%.0f", $0) },
            advanced: true, when: isRestir)
        add(intRow("Neighbours", \.restir.spatialSamples, RestirSettings.spatialSampleRange), advanced: true,
            when: { isRestir($0) && $0.restir.spatialPasses > 0 })
        add(floatRow("Radius", \.restir.radius, RestirSettings.radiusRange, step: 1) { String(format: "%.0f px", $0) },
            advanced: true, when: { isRestir($0) && $0.restir.spatialPasses > 0 })
        add(checkRow("Split visibility (shadow denoiser)", \.restir.splitVisibility), advanced: true, when: isRestir)
        add(intRow("Filter passes", \.restir.denoisePasses, DenoiserSettings.passRange), advanced: true, when: isRestir)
        add(floatRow("Edge tolerance (σ)", \.restir.denoiseSigma, DenoiserSettings.luminanceSigmaRange, step: 0.05) { String(format: "%.2f", $0) },
            advanced: true, when: isRestir)
        add(floatRow("History length", \.restir.denoiseHistory, DenoiserSettings.maxHistoryRange, step: 1) { String(format: "%.0f fr", $0) },
            advanced: true, when: isRestir)
        add(floatRow("Variance boost", \.restir.varianceBoost, DenoiserSettings.varianceBoostRange, step: 0.25) { String(format: "%.2f×", $0) },
            advanced: true, when: isRestir)

        section("Rendering")
        add([label("Render scale"), renderScale, renderScaleValue])
        add([label("MetalFX upscaling"), upscale])
        add([label("Upscaler"), upscalerKind])
        let taau: (RenderSettings) -> Bool = { $0.upscaler == .custom && $0.upscaleFactor > 1 }
        add(floatRow("TAAU history", \.taau.maxHistory, UpscalerSettings.maxHistoryRange, step: 0.5) { String(format: "%g fr", $0) },
            advanced: true, when: taau)
        add(floatRow("Colour clip", \.taau.clipWidth, UpscalerSettings.clipWidthRange, step: 0.05) { String(format: "%.2f σ", $0) },
            advanced: true, when: taau)
        add(floatRow("Sharpness", \.taau.kernelSharpness, UpscalerSettings.sharpnessRange, step: 0.25) { String(format: "%.2f", $0) },
            advanced: true, when: taau)
        add(floatRow("Sharpness, moving", \.taau.kernelSharpnessMoving, UpscalerSettings.sharpnessRange, step: 0.25) { String(format: "%.2f", $0) },
            advanced: true, when: taau)
        add(floatRow("Motion cut", \.taau.motionCut, UpscalerSettings.motionCutRange, step: 0.1) { String(format: "%.1f", $0) },
            advanced: true, when: taau)
        add(floatRow("Edge motion cut", \.taau.edgeMotionCut, UpscalerSettings.edgeMotionCutRange, step: 0.5) { String(format: "%.1f", $0) },
            advanced: true, when: taau)
        add(floatRow("Clip cut", \.taau.clipCut, UpscalerSettings.clipCutRange, step: 1) { String(format: "%.0f", $0) },
            advanced: true, when: taau)
        add(floatRow("Edge dilation", \.taau.dilationRadius, UpscalerSettings.dilationRange, step: 0.01) { $0 == 0 ? "3×3" : String(format: "%.2f px", $0) },
            advanced: true, when: taau)
        add(checkRow("Lanczos history", \.taau.lanczosHistory), advanced: true, when: taau)
        add(floatRow("Lanczos threshold", \.taau.lanczosThreshold, UpscalerSettings.lanczosThresholdRange, step: 0.005) { String(format: "%.3f", $0) },
            advanced: true, when: { taau($0) && $0.taau.lanczosHistory })
        add([NSGridCell.emptyContentView, blueNoise])
        add([label("View"), viewMode])

        section("Global illumination")
        add([NSGridCell.emptyContentView, gi])
        add([label("Method"), giMode])
        add([label("Bounces"), bounces, bouncesValue], when: { $0.giMode == .pathTraced })
        add([NSGridCell.emptyContentView, lightMaps], when: { $0.giMode == .pathTraced })
        add([label("Probe spacing"), probeSpacing], when: { $0.giMode == .radianceCascades })
        add([label("Cascades"), cascadeCount, cascadeCountValue], when: { $0.giMode == .radianceCascades })
        add([label("First interval"), firstInterval, firstIntervalValue], when: { $0.giMode == .radianceCascades })
        add([NSGridCell.emptyContentView, cascadeBounce], when: { $0.giMode == .radianceCascades })
        add([NSGridCell.emptyContentView, cascadeDenoise], when: { $0.giMode == .radianceCascades })
        add([label("Rays"), rgiRays], when: isRestirGI)
        add([label("Bounces"), rgiBounces, rgiBouncesValue], when: isRestirGI)
        add([NSGridCell.emptyContentView, rgiFeedback], when: isRestirGI)
        add([NSGridCell.emptyContentView, rgiTemporal], when: isRestirGI)
        add([label("Spatial reuse"), rgiSpatial], when: isRestirGI)
        add([NSGridCell.emptyContentView, rgiUnbiased], when: isRestirGI)
        add(checkRow("Light bounces from light maps", \.restirGI.lightMaps), advanced: true, when: isRestirGI)
        add(checkRow("Multi-bounce from denoised light", \.restirGI.denoisedFeedback), advanced: true,
            when: { isRestirGI($0) && $0.restirGI.feedback })
        add(checkRow("Multi-bounce off screen (mean)", \.restirGI.feedbackFallback), advanced: true,
            when: { isRestirGI($0) && $0.restirGI.feedback })
        add(floatRow("Max M", \.restirGI.maxM, RestirGISettings.maxMRange, step: 1, log: true) { String(format: "%.0f", $0) },
            advanced: true, when: isRestirGI)
        add(intRow("Max age", \.restirGI.maxAge, RestirGISettings.maxAgeRange) { "\($0) fr" }, advanced: true, when: isRestirGI)
        add(intRow("Neighbours", \.restirGI.spatialSamples, RestirGISettings.spatialSampleRange), advanced: true,
            when: { isRestirGI($0) && $0.restirGI.spatialPasses > 0 })
        add(floatRow("Radius", \.restirGI.radius, RestirGISettings.radiusRange, step: 1) { String(format: "%.0f px", $0) },
            advanced: true, when: { isRestirGI($0) && $0.restirGI.spatialPasses > 0 })
        add(floatRow("Min distance", \.restirGI.minDistance, RestirGISettings.minDistanceRange, step: 0.001, log: true) { String(format: "%.3f m", $0) },
            advanced: true, when: isRestirGI)
        add(checkRow("Denoise ReSTIR GI", \.restirGI.denoise), advanced: true, when: isRestirGI)
        let rgiDenoise: (RenderSettings) -> Bool = { isRestirGI($0) && $0.restirGI.denoise }
        add(intRow("Filter passes", \.restirGI.denoisePasses, DenoiserSettings.passRange), advanced: true, when: rgiDenoise)
        add(floatRow("Edge tolerance (σ)", \.restirGI.denoiseSigma, DenoiserSettings.luminanceSigmaRange, step: 0.05) { String(format: "%.2f", $0) },
            advanced: true, when: rgiDenoise)
        add(floatRow("History length", \.restirGI.denoiseHistory, DenoiserSettings.maxHistoryRange, step: 1) { String(format: "%.0f fr", $0) },
            advanced: true, when: rgiDenoise)
        add(floatRow("Variance boost", \.restirGI.varianceBoost, DenoiserSettings.varianceBoostRange, step: 0.25) { String(format: "%.2f×", $0) },
            advanced: true, when: rgiDenoise)
        add(floatRow("Anti-lag", \.restirGI.antiLag, DenoiserSettings.antiLagRange, step: 0.1) { $0 == 0 ? "off" : String(format: "%.1f", $0) },
            advanced: true, when: rgiDenoise)

        section("Fog")
        let fogOn: (RenderSettings) -> Bool = { $0.fog.enabled }
        add([NSGridCell.emptyContentView, fog])
        add([label("Density"), fogDensity, fogDensityValue], when: fogOn)
        add([label("Height falloff"), fogFalloff, fogFalloffValue], when: fogOn)
        add([label("Forward scattering"), fogAnisotropy, fogAnisotropyValue], when: fogOn)
        add([label("Ambient light"), fogAmbient, fogAmbientValue], when: fogOn)
        add([label("Noise"), fogNoise, fogNoiseValue], when: fogOn)
        add([label("Distance"), fogDistance, fogDistanceValue], when: fogOn)
        add([NSGridCell.emptyContentView, fogVolumes], when: fogOn)
        add([NSGridCell.emptyContentView, fogReflections], when: fogOn)
        add(floatRow("Base height", \.fog.baseHeight, FogSettings.baseHeightRange, step: 0.25) { String(format: "%.2f m", $0) },
            advanced: true, when: fogOn)
        add(floatRow("Noise tile", \.fog.noiseScale, FogSettings.noiseScaleRange, step: 0.5) { String(format: "%.1f m", $0) },
            advanced: true, when: fogOn)
        add(floatRow("Wind", \.fog.windSpeed, FogSettings.windSpeedRange, step: 0.05) { String(format: "%.2f m/s", $0) },
            advanced: true, when: fogOn)
        add(floatRow("Wind direction", \.fog.windDirection, -180...180, step: 5) { String(format: "%.0f°", $0) },
            advanced: true, when: fogOn)
        add([label("Albedo"), fogAlbedo], advanced: true, when: fogOn)

        section("Sky")
        add([label("Sky"), skyMode])
        add([NSGridCell.emptyContentView, skyImageButton], when: { $0.sky.mode == .image })
        add(floatRow("Image exposure", \.sky.imageExposure, RenderSettings.exposureRange, step: 0.1) { String(format: "%+.1f EV", $0) },
            advanced: true, when: { $0.sky.mode == .image })
        add([NSGridCell.emptyContentView, clouds], when: hasClouds)
        add([label("Coverage"), coverage, coverageValue], when: hasClouds)
        add([label("Cloud density"), cloudDensity, cloudDensityValue], when: hasClouds)
        add([label("Cloud height"), cloudHeight, cloudHeightValue], when: hasClouds)
        add([label("Wind"), wind, windValue], when: hasClouds)
        add([NSGridCell.emptyContentView, cloudShadows], when: hasClouds)
        add(floatRow("Cloud thickness", \.sky.cloudThickness, SkySettings.cloudThicknessRange, step: 50) { String(format: "%.0f m", $0) },
            advanced: true, when: hasClouds)
        add(floatRow("Cloud size", \.sky.cloudScale, SkySettings.cloudScaleRange, step: 100, log: true) { String(format: "%.0f m", $0) },
            advanced: true, when: hasClouds)
        add(floatRow("Erosion", \.sky.erosion, 0...1, step: 0.01) { String(format: "%.2f", $0) }, advanced: true, when: hasClouds)
        add(floatRow("Wind direction", \.sky.windDirection, 0...360, step: 5) { String(format: "%.0f°", $0) },
            advanced: true, when: hasClouds)
        add(floatRow("Shadow strength", \.sky.shadowStrength, 0...1, step: 0.05) { String(format: "%.2f", $0) },
            advanced: true, when: { hasClouds($0) && $0.sky.shadows })

        section("Denoiser")
        add([denoiserCaption])
        add([NSGridCell.emptyContentView, denoise])
        add([NSGridCell.emptyContentView, shadowDenoiser])
        add([label("Shadow passes"), shadowPasses, shadowPassesValue])
        let shadowsOn: (RenderSettings) -> Bool = { $0.denoiser.enabled && $0.denoiser.shadowDenoiser }
        add(floatRow("Shadow history", \.denoiser.shadowHistory, DenoiserSettings.maxHistoryRange, step: 1) { String(format: "%.0f fr", $0) },
            advanced: true, when: shadowsOn)
        add(floatRow("Shadow clamp", \.denoiser.shadowClamp, DenoiserSettings.shadowClampRange, step: 0.05) { String(format: "%.2f σ", $0) },
            advanced: true, when: shadowsOn)
        add(floatRow("Shadow edges (σ)", \.denoiser.shadowSigma, DenoiserSettings.shadowSigmaRange, step: 0.25) { String(format: "%.2f", $0) },
            advanced: true, when: shadowsOn)
        add([NSGridCell.emptyContentView, separate])
        add([label("Filter passes"), passes, passesValue])
        add([label("Edge tolerance (σ)"), sigma, sigmaValue])
        add([label("History length"), history, historyValue])
        add([label("Anti-lag"), antiLag, antiLagValue])

        section("Memory", advanced: true)
        add(popupRow("Geometry pool", \.virtualGeometry.poolMB, VirtualGeometrySettings.poolOptions.map { ("\($0) MB", $0) }),
            advanced: true)
        add(popupRow("Texture budget", \.textureBudgetMB, RenderSettings.textureBudgetOptions.map { ("\($0) MB", $0) }),
            advanced: true)

        sectionOf = []
        var current = 0
        for r in rows.indices {
            if headerRows[r] != nil { current = r }
            sectionOf.append(current)
        }
    }

    private func add(_ row: [NSView], advanced: Bool = false, when condition: ((RenderSettings) -> Bool)? = nil) {
        if let condition { rowCondition[rows.count] = condition }
        if advanced { advancedRows.insert(rows.count) }
        rows.append(row)
    }

    private func section(_ title: String, advanced: Bool = false) {
        let header = SectionHeader(title: title, expanded: !collapsed.contains(title))
        header.onToggle = { [unowned self] expanded in
            if expanded { self.collapsed.remove(title) } else { self.collapsed.insert(title) }
            UserDefaults.standard.set(Array(self.collapsed).sorted(), forKey: "panel.collapsed")
            self.applyVisibility(self.renderer.settings)
        }
        headerRows[rows.count] = header
        add([header], advanced: advanced)
    }

    /// Hides rows whose condition fails, advanced rows (unless shown), and the rows of collapsed sections.
    private func applyVisibility(_ s: RenderSettings) {
        var changed = false
        for r in rows.indices {
            let header = sectionOf[r]
            let folded = header != r && headerRows[header].map { !$0.expanded } ?? false
            let hidden = folded || (advancedRows.contains(r) && !showAdvanced) || !(rowCondition[r]?(s) ?? true)
            if grid.row(at: r).isHidden != hidden {
                grid.row(at: r).isHidden = hidden
                changed = true
            }
        }
        if changed { resizeToFit() }
    }

    /// The scroll view with the grid, and under it a footer that stays visible: buttons, stats and pass timings.
    private func makeContent(grid: NSGridView) -> NSView {
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let buttons = NSStackView(views: [reset, copyEnv])
        let toggles = NSStackView(views: [showAdvancedBox, profile])
        toggles.spacing = 16
        footer = NSStackView(views: [buttons, toggles, stats, passTimes])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 8, left: Self.inset.width, bottom: 10, right: Self.inset.width)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setHuggingPriority(.required, for: .vertical)
        passTimes.isHidden = true
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for v in [scroll, separator, footer!] as [NSView] { container.addSubview(v) }
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset.width),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset.width),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset.height),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.inset.height),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Shows the panel beside `window`, or inside its top-right corner if the screen has no room.
    func show(nextTo window: NSWindow) {
        let frame = window.frame, size = panel.frame.size
        let visible = window.screen?.visibleFrame ?? frame
        var origin = NSPoint(x: frame.maxX + 8, y: frame.maxY - size.height)
        if origin.x + size.width > visible.maxX { origin.x = frame.maxX - size.width - 12; origin.y -= 28 }
        origin.y = max(origin.y, visible.minY)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible { panel.orderOut(nil) } else { show(nextTo: window) }
    }

    private static let inset = NSSize(width: 16, height: 14)   // margin around the grid

    /// Size of the visible rows plus the margins and the footer.
    private var fittedSize: NSSize {
        let g = grid.fittingSize, f = footer.fittingSize
        return NSSize(width: max(g.width + 2 * Self.inset.width, f.width), height: g.height + 2 * Self.inset.height + 1 + f.height)
    }

    /// Fits the panel to its visible rows, keeping its top edge in place. A size the user dragged to wins,
    /// except that the panel never gets taller than its rows (or the screen) or narrower than the grid.
    private func resizeToFit() {
        let fit = fittedSize
        let titleBar = panel.frame.height - panel.contentRect(forFrameRect: panel.frame).height
        let screenHeight = ((panel.screen ?? NSScreen.main)?.visibleFrame.height ?? fit.height + titleBar) - titleBar
        panel.contentMinSize = NSSize(width: fit.width, height: min(200, fit.height))
        panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: fit.height)
        let size = NSSize(width: max(fit.width, userWidth ?? 0), height: min(fit.height, userHeight ?? screenHeight))
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    // MARK: - Settings -> controls

    private func update(from s: RenderSettings) {
        applyVisibility(s)
        for refresh in refreshers { refresh(s) }
        updateDenoiserCaption(s)
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
        fogAlbedo.color = NSColor(srgbRed: CGFloat(f.albedo.x), green: CGFloat(f.albedo.y), blue: CGFloat(f.albedo.z), alpha: 1)
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

    /// Which signals the Denoiser section's generic rows (passes, σ, history, anti-lag) filter, and which have their own
    /// filter (mirrors the signal setup in Renderer.encodeFrame).
    private func updateDenoiserCaption(_ s: RenderSettings) {
        let text: String
        if !s.denoiser.enabled {
            text = "Off: the composite shows the raw samples."
        } else {
            let restir = renderer.directModeInUse == .restir
            let shadow = s.denoiser.shadowDenoiser && (!restir || s.restir.splitVisibility)
            var generic: [String] = [], own: [String] = []
            let combined = s.giEnabled && s.giMode == .pathTraced && !s.denoiser.separateSignals && !shadow
            if restir { own.append("ReSTIR direct light (Direct light, advanced)") }
            else if shadow { own.append("direct light: the shadow denoiser") }
            else { generic.append(combined ? "direct + indirect light, combined" : "direct light") }
            if s.giEnabled {
                switch s.giMode {
                case .pathTraced: if !combined { generic.append("indirect light") }
                case .radianceCascades: if s.cascades.denoiseIndirect { generic.append("cascade GI (1 pass)") }
                case .restirGI: if s.restirGI.denoise { own.append("ReSTIR GI (Global illumination, advanced)") }
                }
            }
            var lines = ["Passes, σ, history and anti-lag filter: " + (generic.isEmpty ? "nothing in this mode." : generic.joined(separator: ", ") + ".")]
            if !own.isEmpty { lines.append("Own filters: " + own.joined(separator: "; ") + ".") }
            text = lines.joined(separator: "\n")
        }
        if denoiserCaption.stringValue != text {
            denoiserCaption.stringValue = text
            resizeToFit()
        }
    }

    private func showPassTimes(_ times: [(name: String, ms: Double)]) {
        guard profile.state == .on else { return }
        let total = times.reduce(0) { $0 + $1.ms }
        let width = max(times.map(\.name.count).max() ?? 0, 5)
        let lines = times.map { $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + String(format: " %6.2f ms", $0.ms) }
        passTimes.stringValue = (lines + ["total".padding(toLength: width, withPad: " ", startingAt: 0) + String(format: " %6.2f ms", total)])
            .joined(separator: "\n")
        if passTimes.isHidden { passTimes.isHidden = false; resizeToFit() }
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
    @objc private func clearModelsChanged() { renderer.settings.scene.extraModels = [] }
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
    @objc private func fogAlbedoChanged() {
        guard let c = fogAlbedo.color.usingColorSpace(.sRGB) else { return }
        let round = { (v: CGFloat) in Float((v * 100).rounded() / 100) }
        renderer.settings.fog.albedo = [round(c.redComponent), round(c.greenComponent), round(c.blueComponent)]
    }
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
    @objc private func showAdvancedChanged() {
        showAdvanced = showAdvancedBox.state == .on
        UserDefaults.standard.set(showAdvanced, forKey: "panel.advanced")
        applyVisibility(renderer.settings)
    }
    @objc private func profileChanged() {
        renderer.profilePasses = profile.state == .on
        if profile.state == .off && !passTimes.isHidden { passTimes.isHidden = true; resizeToFit() }
    }
    @objc private func copyAsEnv() {
        let env = EnvExport.string(for: renderer.settings, defaults: renderer.defaultSettings)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env, forType: .string)
        print("Copied: \(env)")
        copyEnv.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyEnv.title = "Copy as Env" }
    }

    // MARK: - Helpers

    /// A section title with a disclosure triangle; clicking either folds the section.
    private final class SectionHeader: NSStackView {
        private let disclosure = NSButton()
        var onToggle: ((Bool) -> Void)?
        var expanded: Bool { disclosure.state == .on }

        init(title: String, expanded: Bool) {
            super.init(frame: .zero)
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.onOff)
            disclosure.title = ""
            disclosure.state = expanded ? .on : .off
            disclosure.target = self
            disclosure.action = #selector(toggled)
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
            orientation = .horizontal
            spacing = 4
            addArrangedSubview(disclosure)
            addArrangedSubview(label)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func clicked() { disclosure.state = expanded ? .off : .on; toggled() }
        @objc private func toggled() { onToggle?(expanded) }
    }

    /// Scroll document view that keeps its rows pinned to the top as the panel grows or shrinks.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Target for a control built by a bind helper.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private func onChange(_ control: NSControl, _ run: @escaping () -> Void) {
        let action = Action(run)
        actions.append(action)
        control.target = action
        control.action = #selector(Action.fire)
    }

    /// [label, slider, value] for a Float setting, rounded to `step`; `log` spaces the slider logarithmically.
    private func floatRow(_ title: String, _ key: WritableKeyPath<RenderSettings, Float>, _ range: ClosedRange<Float>,
                          step: Float, log: Bool = false, format: @escaping (Float) -> String) -> [NSView] {
        let slider = NSSlider(), value = NSTextField(labelWithString: "")
        styleValue(value)
        let position = { (v: Float) in Double(log ? log2(v) : v) }
        slider.minValue = position(range.lowerBound)
        slider.maxValue = position(range.upperBound)
        slider.isContinuous = true
        onChange(slider) { [unowned self] in
            let v = log ? pow(2, Float(slider.doubleValue)) : Float(slider.doubleValue)
            self.renderer.settings[keyPath: key] = range.clamp((v / step).rounded() * step)
        }
        refreshers.append { s in
            slider.doubleValue = position(range.clamp(s[keyPath: key]))
            value.stringValue = format(s[keyPath: key])
        }
        return [label(title), slider, value]
    }

    /// [label, slider, value] for an Int setting (tick marks for short ranges).
    private func intRow(_ title: String, _ key: WritableKeyPath<RenderSettings, Int>, _ range: ClosedRange<Int>,
                        format: @escaping (Int) -> String = { "\($0)" }) -> [NSView] {
        let slider = NSSlider(), value = NSTextField(labelWithString: "")
        styleValue(value)
        configureSlider(slider, CGFloat(range.lowerBound)...CGFloat(range.upperBound), ticks: range.count <= 16 ? range.count : 0, nil)
        onChange(slider) { [unowned self] in self.renderer.settings[keyPath: key] = range.clamp(Int(slider.doubleValue.rounded())) }
        refreshers.append { s in
            slider.integerValue = s[keyPath: key]
            value.stringValue = format(s[keyPath: key])
        }
        return [label(title), slider, value]
    }

    /// [empty, checkbox] for a Bool setting.
    private func checkRow(_ title: String, _ key: WritableKeyPath<RenderSettings, Bool>) -> [NSView] {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        onChange(box) { [unowned self] in self.renderer.settings[keyPath: key] = box.state == .on }
        refreshers.append { s in box.state = s[keyPath: key] ? .on : .off }
        return [NSGridCell.emptyContentView, box]
    }

    /// [label, popup] choosing among `options` (title, value).
    private func popupRow<T: Equatable>(_ title: String, _ key: WritableKeyPath<RenderSettings, T>, _ options: [(String, T)]) -> [NSView] {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options.map(\.0))
        onChange(popup) { [unowned self] in self.renderer.settings[keyPath: key] = options[popup.indexOfSelectedItem].1 }
        refreshers.append { s in popup.selectItem(at: options.firstIndex { $0.1 == s[keyPath: key] } ?? -1) }
        return [label(title), popup]
    }

    private func styleValue(_ value: NSTextField) {
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
    }

    private func label(_ text: String) -> NSView { NSTextField(labelWithString: text) }

    private func cg(_ r: ClosedRange<Float>) -> ClosedRange<CGFloat> { CGFloat(r.lowerBound)...CGFloat(r.upperBound) }

    private func configureSlider(_ slider: NSSlider, _ range: ClosedRange<CGFloat>, ticks: Int, _ action: Selector?) {
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.numberOfTickMarks = ticks
        slider.allowsTickMarkValuesOnly = ticks > 0
        slider.isContinuous = true
        slider.target = self
        slider.action = action
    }
}

extension SettingsPanel: NSWindowDelegate {
    /// Remembers a size the user dragged to. Dragging back to the full height of the rows returns to fitting them.
    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.contentRect(forFrameRect: panel.frame).size, fit = fittedSize
        userWidth = size.width > fit.width + 0.5 ? size.width : nil
        userHeight = size.height < fit.height - 0.5 ? size.height : nil
    }
}
