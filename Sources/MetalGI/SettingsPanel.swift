import AppKit

/// Floating panel with a control for every `RenderSettings` field, plus live resolution / fps / GPU time.
/// It never becomes the key window, so WASD and the keyboard shortcuts keep working while it's open.
/// Keyboard changes show up here too: the renderer reports every settings change through `onSettingsChanged`.
final class SettingsPanel: NSObject {
    let panel: NSPanel
    private let renderer: Renderer
    private let upscaleSteps: [CGFloat]

    private let stats = NSTextField(labelWithString: "")
    private let sceneKind = NSPopUpButton()
    private let objects = NSSlider()
    private let objectsValue = NSTextField(labelWithString: "")
    private let lights = NSSlider()            // log2 of the light count
    private let lightsValue = NSTextField(labelWithString: "")
    private let lightRays = NSPopUpButton()    // shadow rays per light group (more than 4 lights)
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
    private let surfelRays = NSPopUpButton()
    private let maxSurfels = NSPopUpButton()
    private let surfelSize = NSSlider()
    private let surfelSizeValue = NSTextField(labelWithString: "")
    private let surfelHistory = NSSlider()
    private let surfelHistoryValue = NSTextField(labelWithString: "")
    private let surfelDenoise = NSButton(checkboxWithTitle: "Denoise surfel GI", target: nil, action: nil)
    private let probeSpacing = NSPopUpButton()
    private let cascadeCount = NSSlider()
    private let cascadeCountValue = NSTextField(labelWithString: "")
    private let firstInterval = NSSlider()
    private let firstIntervalValue = NSTextField(labelWithString: "")
    private let cascadeBounce = NSButton(checkboxWithTitle: "Multi-bounce", target: nil, action: nil)
    private let cascadeDenoise = NSButton(checkboxWithTitle: "Denoise cascade GI", target: nil, action: nil)
    private static let surfelRayOptions = [4, 8, 16, 32]
    private var grid: NSGridView!
    private var modeRows: [GIMode: [Int]] = [:]   // grid rows shown only in that GI mode
    private var stressRows: [Int] = []             // grid rows shown only for the stress scene

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
        configureSlider(surfelSize, 4...16, ticks: 13, #selector(surfelSizeChanged))
        configureSlider(surfelHistory, 8...128, ticks: 0, #selector(surfelHistoryChanged))
        configureSlider(cascadeCount, CGFloat(CascadeSettings.cascadeRange.lowerBound)...CGFloat(CascadeSettings.cascadeRange.upperBound),
                        ticks: CascadeSettings.cascadeRange.count, #selector(cascadeCountChanged))
        configureSlider(firstInterval, cg(CascadeSettings.firstIntervalRange), ticks: 0, #selector(firstIntervalChanged))
        // Scene sizes rebuild the scene, so they apply when the slider is released.
        configureSlider(objects, CGFloat(SceneSettings.objectRange.lowerBound)...CGFloat(SceneSettings.objectRange.upperBound),
                        ticks: 0, #selector(objectsChanged))
        configureSlider(lights, 0...log2(CGFloat(SceneSettings.lightRange.upperBound)),
                        ticks: Int(log2(Double(SceneSettings.lightRange.upperBound))) + 1, #selector(lightsChanged))
        objects.isContinuous = false
        lights.isContinuous = false
        for (popup, titles, action) in [
            (giMode, GIMode.allCases.map(\.title), #selector(giModeChanged)),
            (sceneKind, SceneKind.allCases.map(\.title), #selector(sceneKindChanged)),
            (lightRays, ["1 per group (fastest)", "1 per group + reuse", "2 per group (least noise)"], #selector(lightRaysChanged)),
            (upscalerKind, UpscalerKind.allCases.map(\.title), #selector(upscalerKindChanged)),
            (surfelRays, SettingsPanel.surfelRayOptions.map { "\($0) rays" }, #selector(surfelRaysChanged)),
            (maxSurfels, SurfelSettings.maxSurfelsOptions.map { "\($0 / 1024)k" }, #selector(maxSurfelsChanged)),
            (probeSpacing, CascadeSettings.spacingOptions.map { "\($0) px" }, #selector(probeSpacingChanged)),
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
                              (surfelDenoise, #selector(surfelDenoiseChanged)), (cascadeBounce, #selector(cascadeBounceChanged)),
                              (cascadeDenoise, #selector(cascadeDenoiseChanged)),
                              (shadowDenoiser, #selector(shadowDenoiserChanged))] {
            box.target = self
            box.action = action
        }
        stats.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        stats.textColor = .secondaryLabelColor
        for value in [objectsValue, lightsValue, renderScaleValue, bouncesValue, passesValue, shadowPassesValue, sigmaValue, historyValue, antiLagValue,
                      surfelSizeValue, surfelHistoryValue, cascadeCountValue, firstIntervalValue] {
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.alignment = .right
        }

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let rows: [[NSView]] = [
            [header("Scene")],
            [label("Scene"), sceneKind],
            [label("Objects"), objects, objectsValue],                       // stress
            [label("Lights"), lights, lightsValue],                          // stress
            [label("Shadow rays"), lightRays],                               // stress
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
            [label("Rays per surfel"), surfelRays],                          // surfels
            [label("Max surfels"), maxSurfels],                              // surfels
            [label("Surfel size"), surfelSize, surfelSizeValue],             // surfels
            [label("Surfel history"), surfelHistory, surfelHistoryValue],    // surfels
            [NSGridCell.emptyContentView, surfelDenoise],                    // surfels
            [label("Probe spacing"), probeSpacing],                          // cascades
            [label("Cascades"), cascadeCount, cascadeCountValue],            // cascades
            [label("First interval"), firstInterval, firstIntervalValue],    // cascades
            [NSGridCell.emptyContentView, cascadeBounce],                    // cascades
            [NSGridCell.emptyContentView, cascadeDenoise],                   // cascades
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
        stressRows = rowsOf([objects, lights, lightRays])
        modeRows = [.pathTraced: rowsOf([bounces, lightMaps]),
                    .surfels: rowsOf([surfelRays, maxSurfels, surfelSize, surfelHistory, surfelDenoise]),
                    .radianceCascades: rowsOf([probeSpacing, cascadeCount, firstInterval, cascadeBounce, cascadeDenoise])]
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
        for r in stressRows where grid.row(at: r).isHidden != (s.scene.kind != .stress) {
            grid.row(at: r).isHidden = s.scene.kind != .stress
            layoutChanged = true
        }
        if layoutChanged { resizeToFit() }
        sceneKind.selectItem(at: s.scene.kind.rawValue)
        objects.integerValue = s.scene.objects
        objectsValue.stringValue = "\(s.scene.objects)"
        lights.doubleValue = log2(Double(max(s.scene.lights, 1)))
        lightsValue.stringValue = "\(s.scene.lights)"
        lightRays.selectItem(at: s.manyLightRays >= 2 ? 2 : s.manyLightReuse > 0 ? 1 : 0)
        lightRays.isEnabled = s.scene.lights > 4
        giMode.selectItem(at: s.giMode.rawValue)
        lightMaps.state = s.lightMaps ? .on : .off
        let sf = s.surfels
        surfelRays.selectItem(at: SettingsPanel.surfelRayOptions.firstIndex { $0 >= sf.raysPerSurfel } ?? 2)
        maxSurfels.selectItem(at: SurfelSettings.maxSurfelsOptions.firstIndex(of: sf.maxSurfels) ?? 2)
        surfelSize.doubleValue = Double(sf.radiusPixels)
        surfelSizeValue.stringValue = String(format: "%.0f px", sf.radiusPixels)
        surfelHistory.doubleValue = Double(sf.maxHistory)
        surfelHistoryValue.stringValue = String(format: "%.0f fr", sf.maxHistory)
        surfelDenoise.state = sf.denoiseIndirect ? .on : .off
        let c = s.cascades
        probeSpacing.selectItem(at: CascadeSettings.spacingOptions.firstIndex(of: c.probeSpacing) ?? 1)
        cascadeCount.integerValue = c.cascades
        cascadeCountValue.stringValue = "\(c.cascades)"
        firstInterval.doubleValue = Double(c.firstInterval)
        firstIntervalValue.stringValue = String(format: "%.2f m", c.firstInterval)
        cascadeBounce.state = c.feedback ? .on : .off
        cascadeDenoise.state = c.denoiseIndirect ? .on : .off
        for control in [giMode, lightMaps, surfelRays, maxSurfels, surfelSize, surfelHistory, surfelDenoise, probeSpacing,
                        cascadeCount, firstInterval, cascadeBounce, cascadeDenoise] as [NSControl] {
            control.isEnabled = s.giEnabled
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
        s.scene = renderer.settings.scene   // render settings only; the loaded scene stays
        s.applySceneDefaults(from: renderer.defaultSettings)
        renderer.settings = s
    }
    @objc private func sceneKindChanged() {
        var s = renderer.settings
        s.scene.kind = SceneKind(rawValue: sceneKind.indexOfSelectedItem) ?? .cornell
        guard s.scene.kind != renderer.settings.scene.kind else { return }
        s.applySceneDefaults(from: renderer.defaultSettings)   // e.g. surfels for the stress hall
        renderer.settings = s
    }
    @objc private func objectsChanged() { renderer.settings.scene.objects = Int((objects.doubleValue / 50).rounded()) * 50 }
    @objc private func lightRaysChanged() {
        let choice = lightRays.indexOfSelectedItem   // 0: 1 ray, 1: 1 ray + reuse, 2: 2 rays
        renderer.settings.manyLightRays = choice == 2 ? 2 : 1
        renderer.settings.manyLightReuse = choice == 1 ? renderer.defaultSettings.manyLightReuse : 0
    }
    @objc private func lightsChanged() { renderer.settings.scene.lights = 1 << Int(lights.doubleValue.rounded()) }
    @objc private func giModeChanged() { renderer.settings.giMode = GIMode(rawValue: giMode.indexOfSelectedItem) ?? .pathTraced }
    @objc private func lightMapsChanged() { renderer.settings.lightMaps = lightMaps.state == .on }
    @objc private func surfelRaysChanged() { renderer.settings.surfels.raysPerSurfel = SettingsPanel.surfelRayOptions[surfelRays.indexOfSelectedItem] }
    @objc private func maxSurfelsChanged() { renderer.settings.surfels.maxSurfels = SurfelSettings.maxSurfelsOptions[maxSurfels.indexOfSelectedItem] }
    @objc private func surfelSizeChanged() { renderer.settings.surfels.radiusPixels = Float(surfelSize.doubleValue.rounded()) }
    @objc private func surfelHistoryChanged() { renderer.settings.surfels.maxHistory = Float(surfelHistory.doubleValue.rounded()) }
    @objc private func surfelDenoiseChanged() { renderer.settings.surfels.denoiseIndirect = surfelDenoise.state == .on }
    @objc private func probeSpacingChanged() { renderer.settings.cascades.probeSpacing = CascadeSettings.spacingOptions[probeSpacing.indexOfSelectedItem] }
    @objc private func cascadeCountChanged() { renderer.settings.cascades.cascades = Int(cascadeCount.doubleValue.rounded()) }
    @objc private func firstIntervalChanged() { renderer.settings.cascades.firstInterval = Float((firstInterval.doubleValue * 20).rounded() / 20) }
    @objc private func cascadeBounceChanged() { renderer.settings.cascades.feedback = cascadeBounce.state == .on }
    @objc private func cascadeDenoiseChanged() { renderer.settings.cascades.denoiseIndirect = cascadeDenoise.state == .on }

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
