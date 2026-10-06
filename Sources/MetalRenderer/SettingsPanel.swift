import AppKit
import UniformTypeIdentifiers

/// Floating panel with a control for every `RenderSettings` field (live stats are in the Debug window, DebugPanel).
/// It never becomes the key window, so WASD and the keyboard shortcuts keep working while it's open.
/// Keyboard changes show up here too: the renderer reports every settings change to its settings observers.
///
/// The rows come from `SettingsTable`: its sections are the panel's collapsible sections, and each `SettingSpec` with
/// a control becomes a row (`makeRow`), with the spec's condition (shown only for some modes), its "advanced" mark
/// (shown only with Show advanced) and what enables it. A few rows are more than one setting behind one control
/// (`customRow`).
final class SettingsPanel: NSObject {
    let panel: NSPanel
    private let renderer: RendererController
    private let upscaleSteps: [CGFloat]

    private let showAdvancedBox = NSButton(checkboxWithTitle: "Show advanced", target: nil, action: nil)
    private let copyEnv = NSButton(title: "Copy as Env", target: nil, action: nil)
    private let denoiserCaption = NSTextField(wrappingLabelWithString: "")

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
    // The controls' targets, and how each control shows the settings.
    private var actions: [Action] = []
    private var refreshers: [(RenderSettings) -> Void] = []
    // Panel state kept between launches (the render settings themselves are saved by SettingsStore).
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "panel.collapsed") ?? [])
    private var showAdvanced = UserDefaults.standard.bool(forKey: "panel.advanced")

    init(renderer: RendererController) {
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

        for (control, action) in [(showAdvancedBox, #selector(showAdvancedChanged)), (copyEnv, #selector(copyAsEnv))] {
            control.target = self
            control.action = action
        }
        denoiserCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        denoiserCaption.textColor = .secondaryLabelColor
        denoiserCaption.preferredMaxLayoutWidth = 330
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

        showAdvancedBox.state = showAdvanced ? .on : .off
        update(from: renderer.settings)
        resizeToFit()
        renderer.observeSettings { [weak self] in self?.update(from: $0) }
        renderer.observeTick { [weak self] in
            guard let self else { return }
            self.updateDenoiserCaption(self.renderer.settings)   // Auto's method follows the loaded scene's light count
        }
    }

    // MARK: - Rows

    /// Every row, top to bottom: `SettingsTable`'s sections and their specs.
    private func buildRows() {
        for section in SettingsTable.sections {
            self.section(section.title, advanced: section.advanced)
            for spec in section.rows {
                guard let views = makeRow(spec) else { continue }   // a setting with only an env name
                if let enabled = spec.enabled, views.count > 1, let control = views[1] as? NSControl {   // after the label
                    refreshers.append { control.isEnabled = enabled($0) }
                }
                add(views, advanced: spec.advanced || section.advanced, when: spec.visible)
            }
        }
        sectionOf = []
        var current = 0
        for r in rows.indices {
            if headerRows[r] != nil { current = r }
            sectionOf.append(current)
        }
    }

    /// The row for `spec`: its control, wired to the setting both ways.
    private func makeRow(_ spec: SettingSpec) -> [NSView]? {
        switch spec.control {
        case nil:
            return nil
        case .slider(let model):
            let slider = NSSlider(), value = NSTextField(labelWithString: "")
            styleValue(value)
            slider.minValue = model.range.lowerBound
            slider.maxValue = model.range.upperBound
            slider.numberOfTickMarks = model.ticks
            slider.allowsTickMarkValuesOnly = model.ticks > 0
            slider.isContinuous = model.live
            onChange(slider) { [unowned self] in
                let value = slider.doubleValue
                self.renderer.update { model.move(&$0, value) }
            }
            refreshers.append { s in
                slider.doubleValue = model.position(s)
                value.stringValue = model.text(s)
            }
            return [label(spec.title), slider, value]
        case .checkbox(let get, let set):
            let box = NSButton(checkboxWithTitle: spec.title, target: nil, action: nil)
            onChange(box) { [unowned self] in
                let on = box.state == .on
                self.renderer.update { set(&$0, on) }
            }
            refreshers.append { box.state = get($0) ? .on : .off }
            return [NSGridCell.emptyContentView, box]
        case .popup(let titles, let selected, let select):
            let popup = NSPopUpButton()
            popup.addItems(withTitles: titles)
            if let available = spec.available {   // what this GPU can't run stays listed, greyed out
                popup.autoenablesItems = false
                for (i, item) in popup.itemArray.enumerated() { item.isEnabled = available(i) }
            }
            onChange(popup) { [unowned self] in
                let index = popup.indexOfSelectedItem
                self.renderer.update { select(&$0, index) }
            }
            refreshers.append { popup.selectItem(at: selected($0)) }
            return [label(spec.title), popup]
        case .custom(let row):
            return customRow(row, title: spec.title)
        }
    }

    /// The rows that are more than one setting behind one control.
    private func customRow(_ row: SettingSpec.Custom, title: String) -> [NSView] {
        func popup(_ titles: [String], _ changed: @escaping (NSPopUpButton) -> Void) -> NSPopUpButton {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: titles)
            onChange(popup) { changed(popup) }
            return popup
        }
        switch row {
        case .scene:   // a new scene brings its own defaults and drops the models added to the old one
            let kinds = popup(SceneKind.allCases.map(\.title)) { [unowned self] popup in
                let kind = SceneKind(rawValue: popup.indexOfSelectedItem) ?? .cornell, defaults = self.renderer.defaultSettings
                guard kind != self.renderer.settings.scene.kind else { return }
                self.renderer.update { s in
                    guard kind != s.scene.kind else { return }
                    s.scene.kind = kind
                    s.scene.extraModels = []
                    s.applySceneDefaults(from: defaults)   // e.g. the night market's light count
                }
            }
            refreshers.append { kinds.selectItem(at: $0.scene.kind.rawValue) }
            return [label(title), kinds]
        case .showcaseModel:   // a model brings its look: its fog and lens
            let files = Scene.galleryFiles()
            let models = popup(files.map(Scene.showcaseName)) { [unowned self] popup in
                guard files.indices.contains(popup.indexOfSelectedItem) else { return }
                let name = Scene.showcaseName(files[popup.indexOfSelectedItem]), defaults = self.renderer.defaultSettings
                self.renderer.update { s in
                    guard Scene.showcaseFile(s.scene.showcase) != files[popup.indexOfSelectedItem] else { return }
                    s.scene.showcase = name
                    s.applySceneDefaults(from: defaults)
                }
            }
            refreshers.append { s in models.selectItem(at: Scene.showcaseFile(s.scene.showcase).flatMap(files.firstIndex) ?? -1) }
            return [label(title), models]
        case .clearModels:
            let button = NSButton(title: "Clear Added Models", target: nil, action: nil)
            onChange(button) { [unowned self] in self.renderer.update { $0.scene.extraModels = [] } }
            return [NSGridCell.emptyContentView, button]
        case .lightRays:   // shadow rays per light group and whether one ray's picks are reused: two settings
            let rays = popup(["1 per group (fastest)", "1 per group + reuse", "2 per group (least noise)"]) { [unowned self] popup in
                let choice = popup.indexOfSelectedItem, reuse = self.renderer.defaultSettings.manyLightReuse
                self.renderer.update {
                    $0.manyLightRays = choice == 2 ? 2 : 1
                    $0.manyLightReuse = choice == 1 ? reuse : 0
                }
            }
            refreshers.append { s in
                rays.selectItem(at: s.manyLightRays >= 2 ? 2 : s.manyLightReuse > 0 ? 1 : 0)
                rays.isEnabled = s.scene.lights > 4
            }
            return [label(title), rays]
        case .upscale:   // the factors this GPU's MetalFX supports
            let steps = upscaleSteps
            let factor = popup(steps.map { $0 == 0 ? "Off" : String(format: "%g×", $0) }) { [unowned self] popup in
                let factor = steps[popup.indexOfSelectedItem]
                self.renderer.update { $0.upscaleFactor = factor }
            }
            factor.isEnabled = steps.count > 1
            refreshers.append { factor.selectItem(at: steps.firstIndex(of: $0.upscaleFactor) ?? 0) }
            return [label(title), factor]
        case .skyMode:   // an image needs a file first
            let mode = popup(SkyMode.allCases.map(\.title)) { [unowned self] popup in
                let mode = SkyMode(rawValue: popup.indexOfSelectedItem) ?? .constant
                if mode == .image && self.renderer.settings.sky.imagePath == nil { self.chooseSkyImage() }
                else { self.renderer.update { $0.sky.mode = mode } }
            }
            refreshers.append { mode.selectItem(at: $0.sky.mode.rawValue) }
            return [label(title), mode]
        case .skyImage:
            let button = NSButton(title: "Choose Image…", target: nil, action: nil)
            onChange(button) { [unowned self] in self.chooseSkyImage() }
            refreshers.append { button.title = $0.sky.imagePath.map { "Image: " + ($0 as NSString).lastPathComponent } ?? "Choose Image…" }
            return [NSGridCell.emptyContentView, button]
        case .fogAlbedo:
            let well = NSColorWell(style: .minimal)
            onChange(well) { [unowned self] in
                guard let c = well.color.usingColorSpace(.sRGB) else { return }
                let round = { (v: CGFloat) in Float((v * 100).rounded() / 100) }
                let albedo: SIMD3<Float> = [round(c.redComponent), round(c.greenComponent), round(c.blueComponent)]
                self.renderer.update { $0.fog.albedo = albedo }
            }
            refreshers.append {
                let a = $0.fog.albedo
                well.color = NSColor(srgbRed: CGFloat(a.x), green: CGFloat(a.y), blue: CGFloat(a.z), alpha: 1)
            }
            return [label(title), well]
        case .denoiserCaption:
            return [denoiserCaption]
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

    /// The scroll view with the grid, and under it a footer that stays visible: buttons and toggles.
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
        footer = NSStackView(views: [buttons, showAdvancedBox])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 8, left: Self.inset.width, bottom: 10, right: Self.inset.width)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setHuggingPriority(.required, for: .vertical)
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
    }

    /// Which signals the Denoiser section's generic rows (passes, σ, history, anti-lag) filter, and which have their own
    /// filter (mirrors Renderer.planFrame and denoiseSignals).
    private func updateDenoiserCaption(_ s: RenderSettings) {
        let text: String
        if s.neuralDenoiser {
            text = "While upscaling (Rendering), the MetalFX denoiser denoises as it upscales: these are off."
        } else if !s.denoiser.enabled {
            text = "Off: the composite shows the raw samples."
        } else {
            let restir = renderer.status?.directMode == .restir, megaLights = renderer.status?.directMode == .megalights
            let shadow = s.denoiser.shadowDenoiser && !megaLights && (!restir || s.restir.splitVisibility)
            var generic: [String] = [], own: [String] = []
            let combined = s.giEnabled && s.giMode == .pathTraced && !s.denoiser.separateSignals && !shadow
            if restir { own.append("ReSTIR direct light (Direct light, advanced)") }
            else if megaLights { own.append("MegaLights direct light (Direct light, advanced)") }
            else if shadow { own.append("direct light: the shadow denoiser") }
            else { generic.append(combined ? "direct + indirect light, combined" : "direct light") }
            if s.giEnabled {
                switch s.giMode {
                case .pathTraced: if !combined { generic.append("indirect light") }
                case .radianceCascades: if s.cascades.denoiseIndirect { generic.append("cascade GI (1 pass)") }
                case .restirGI: if s.restirGI.denoise { own.append("ReSTIR GI (Global illumination, advanced)") }
                case .lumen: if s.lumen.denoiseIndirect { generic.append("Lumen GI (1 pass)") }
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

    // MARK: - Buttons

    @objc private func resetToDefaults() {
        let defaults = renderer.defaultSettings
        renderer.update { s in
            var reset = defaults
            reset.scene = s.scene   // render settings only; the loaded scene and API stay
            reset.api = s.api
            reset.applySceneDefaults(from: defaults)
            s = reset
        }
    }
    private func chooseSkyImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SkyImage.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an equirectangular HDR image (.hdr or .exr) for the sky"
        if panel.runModal() == .OK, let url = panel.url { renderer.addModels([url]) } else { update(from: renderer.settings) }
    }
    @objc private func showAdvancedChanged() {
        showAdvanced = showAdvancedBox.state == .on
        UserDefaults.standard.set(showAdvanced, forKey: "panel.advanced")
        applyVisibility(renderer.settings)
    }
    @objc private func copyAsEnv() {
        let env = SettingsEnv.export(renderer.settings, defaults: renderer.defaultSettings)
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

    /// A control's target.
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

    private func styleValue(_ value: NSTextField) {
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
    }

    private func label(_ text: String) -> NSView { NSTextField(labelWithString: text) }
}

extension SettingsPanel: NSWindowDelegate {
    /// Remembers a size the user dragged to. Dragging back to the full height of the rows returns to fitting them.
    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.contentRect(forFrameRect: panel.frame).size, fit = fittedSize
        userWidth = size.width > fit.width + 0.5 ? size.width : nil
        userHeight = size.height < fit.height - 0.5 ? size.height : nil
    }
}
