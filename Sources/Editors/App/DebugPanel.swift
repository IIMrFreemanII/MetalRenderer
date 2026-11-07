import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants

/// Floating panel with live debug data: a frame-time graph, GPU pass timings, the scene, virtual geometry, texture
/// streaming, memory and the ray queries' counters. Like the settings panel it never becomes key, so
/// the keyboard keeps driving the renderer. I or Cmd-I shows or hides it.
final class DebugPanel: NSObject {
    let panel: NSPanel
    private let renderer: RendererController

    private let stats = NSTextField(wrappingLabelWithString: "")
    private let graph = FrameGraphView()
    private let profile = NSButton(checkboxWithTitle: "GPU pass timings (disables pass overlap)", target: nil, action: nil)
    private let passTimes = NSTextField(labelWithString: "")
    private let debugView = NSPopUpButton()
    private let freezeLOD = NSButton(checkboxWithTitle: "Freeze LOD (L)", target: nil, action: nil)
    private let viewNote = NSTextField(wrappingLabelWithString: "")
    private let counters = NSButton(checkboxWithTitle: "Ray query counters (recompiles shaders, slower)", target: nil, action: nil)
    // Virtual geometry
    private let vgGraph = VGGraphView()
    private let vgProbe = NSTextField(wrappingLabelWithString: "")
    private let vgResidency = NSTextField(wrappingLabelWithString: "")
    private let vgTable = VGInstanceTable()
    private let vgTau = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let vgTauValue = NSTextField(labelWithString: "")
    private let vgRecut = NSButton(title: "Force re-cut", target: nil, action: nil)
    private let vgWait = NSButton(checkboxWithTitle: "Wait rule", target: nil, action: nil)
    private let vgShare = NSSlider(value: 0.1, minValue: Double(DebugPanel.shareRange.lowerBound), maxValue: Double(DebugPanel.shareRange.upperBound),
                                   target: nil, action: nil)
    private let vgShareValue = NSTextField(labelWithString: "")
    private let vgPasses = NSStepper()
    private let vgPassesValue = NSTextField(labelWithString: "")
    private let vgView = NSPopUpButton()
    private var vgViewModes: [Int] = []
    private let vgBooth = NSPopUpButton()
    private var shownBookmarks: [SceneBookmark] = []
    private let vgCount = NSTextField(string: "")
    private let vgCountStepper = NSStepper()
    private let vgEvict = NSButton(title: "Evict cache", target: nil, action: nil)
    private var vgLabControls: [NSView] = []
    private let frame = Section("Frame")
    private let view = Section("View")
    private let passes = Section("GPU passes")
    private let scene = Section("Scene")
    private let vg = Section("Virtual geometry")
    private let textures = Section("Texture streaming")
    private let memory = Section("Memory")
    private let traversal = Section("Ray queries")
    private var lastRebuilds: (count: Int, time: CFTimeInterval)?
    private var rebuildRate = 0.0

    // The VG controls' ranges (the instance field's count: the VG lab's settings.scene.objects).
    private static let tauRange = VirtualGeometrySettings.pixelErrorRange
    private static let shareRange = VirtualGeometrySettings.waitShareRange
    private static let passesRange = VirtualGeometrySettings.waitPassesRange
    private static let objectsRange = 1...SceneSettings.objectRange.upperBound

    private static let visibleKey = "debug.visible"
    /// Shown at the last launch (the window comes back where it was).
    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    package init(renderer: RendererController) {
        self.renderer = renderer
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 820),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Debug"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.contentMinSize = NSSize(width: 280, height: 200)

        let small = NSFont.smallSystemFontSize
        stats.font = .monospacedDigitSystemFont(ofSize: small, weight: .regular)
        stats.textColor = .secondaryLabelColor
        passTimes.font = .monospacedSystemFont(ofSize: small, weight: .regular)
        passTimes.textColor = .secondaryLabelColor
        passTimes.maximumNumberOfLines = 0
        passTimes.isHidden = true
        for (control, action) in [(profile, #selector(profileChanged)), (freezeLOD, #selector(freezeLODChanged)),
                                  (counters, #selector(countersChanged)), (debugView, #selector(debugViewChanged))]
            as [(NSControl, Selector)] {
            control.target = self
            control.action = action
            control.controlSize = .small
            control.font = .systemFont(ofSize: small)
        }
        debugView.addItems(withTitles: RenderSettings.viewModes)
        viewNote.font = .systemFont(ofSize: small)
        viewNote.textColor = .secondaryLabelColor
        viewNote.isHidden = true
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 96).isActive = true

        frame.add(stats)
        frame.add(graph)
        passes.add(profile)
        passes.add(passTimes)
        let controls = NSStackView(views: [label("Debug view"), debugView, freezeLOD])
        controls.spacing = 6
        view.add(controls)
        view.add(viewNote)
        traversal.add(counters)
        buildVGControls()

        let stack = NSStackView(views: [frame, view, passes, scene, vg, textures, memory, traversal])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in stack.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        panel.contentView = scroll

        renderer.observeTick { [weak self] in self?.refresh() }
        renderer.observeSettings { [weak self] in self?.update(from: $0) }
        renderer.onPassTimes = { [weak self] in self?.showPassTimes($0) }
        update(from: renderer.settings)
        refresh()
    }

    // MARK: - Showing

    /// Below the settings panel when it's open and there's room, else left of the main window.
    func show(nextTo window: NSWindow, below other: NSWindow?) {
        let size = panel.frame.size
        let visible = window.screen?.visibleFrame ?? window.frame
        var origin: NSPoint
        if let other, other.isVisible, other.frame.minY - 8 - size.height >= visible.minY {
            origin = NSPoint(x: other.frame.minX, y: other.frame.minY - 8 - size.height)
        } else {
            origin = NSPoint(x: window.frame.minX - size.width - 8, y: window.frame.maxY - size.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        setActive(true)
    }

    func toggle(nextTo window: NSWindow, below other: NSWindow?) {
        if panel.isVisible { panel.orderOut(nil); setActive(false) } else { show(nextTo: window, below: other) }
    }

    /// Per-frame graph samples and pass profiling run only while the window is open.
    private func setActive(_ active: Bool) {
        UserDefaults.standard.set(active, forKey: DebugPanel.visibleKey)
        renderer.onFrameTime = active ? { [weak self] cpu, gpu in self?.graph.add(cpu: cpu, gpu: gpu) } : nil
        renderer.debugActive = active
        renderer.profilePasses = active && profile.state == .on
        if active { refresh() }
    }

    // MARK: - Updates

    private func update(from s: RenderSettings) {
        debugView.selectItem(at: s.viewMode)
        freezeLOD.state = s.virtualGeometry.freeze ? .on : .off
        updateVGControls(from: s)
    }

    private func refresh() {
        guard panel.isVisible else { return }
        let d = renderer.debugInfo
        stats.stringValue = d.stats + String(format: " — CPU %.1f ms (encode %.2f)", d.cpuMs, d.encodeMs)
        freezeLOD.isEnabled = d.lodFreezes
        viewNote.stringValue = d.viewNote ?? ""
        viewNote.isHidden = d.viewNote == nil

        let lights = [(d.analyticLights, "analytic"), (d.meshLights, "mesh"), (d.suns, d.suns == 1 ? "sun" : "suns")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        scene.set([
            ("Scene", d.sceneTitle, nil),
            ("Instances", d.virtualInstances > 0 ? "\(d.instances) (\(d.virtualInstances) virtual)" : "\(d.instances)", nil),
            ("Triangles", d.virtualInstances == 0 ? Self.count(d.triangles)
                : d.vg.triangles > 0 ? "\(Self.count(d.triangles + d.vg.triangles)) (\(Self.count(d.vg.triangles)) virtual)"
                : Self.count(d.triangles) + " (virtual not drawn)", nil),
            ("Lights", lights.isEmpty ? "none" : lights.joined(separator: ", "), nil),
            ("Light table", d.lightTable ? "on, \(Self.count(d.lightTableEntries)) entries" : "off (256 lights or fewer)", nil),
            ("Direct light", d.directMode, nil),
            ("GI", d.giMode, nil),
        ])

        var vgRows: [(String, String, NSColor?)] = []
        switch d.vg {
        case .off:
            lastRebuilds = nil
        case let .blas(meshes, instances, source, triangles, clusters, megabytes, rebuilds, lastBuildMs, lastCutMs, skipped, busy):
            let now = CACurrentMediaTime()
            if let last = lastRebuilds, now > last.time { rebuildRate = Double(rebuilds - last.count) / (now - last.time) }
            lastRebuilds = (rebuilds, now)
            vgRows = [
                ("Mode", "per-instance BLAS", nil),
                ("Meshes", "\(meshes) in \(instances) instances", nil),
                ("Traced triangles", Self.count(triangles), nil),
                ("Finest level", Self.finest(source, cut: triangles), nil),
                ("Clusters in cut", Self.count(clusters), nil),
                ("BLAS memory", String(format: "%.1f MB", megabytes), nil),
                ("Rebuilds", String(format: "%d total, %.1f/s", rebuilds, rebuildRate), nil),
                ("Last cut", String(format: "%.1f ms, %d of %d instances unchanged", lastCutMs, skipped, instances), nil),
                ("Last build", String(format: "%.1f ms", lastBuildMs) + (busy ? ", building" : ""), nil),
            ]
        }
        if !vgRows.isEmpty {
            vgRows += [("Pixel error", String(format: "%g px", d.vgPixelError), nil),
                       ("LOD", d.vgFrozen ? "frozen" : "follows the camera", d.vgFrozen ? .systemOrange : nil)]
        }
        vg.set(vgRows)
        vg.isHidden = vgRows.isEmpty
        if let report = d.vgReport { showVG(report) }

        if let t = d.textures {
            textures.set([
                ("Resident", String(format: "%.0f of %d MB", t.residentMB, t.budgetMB), nil),
                ("Levels mapped", "\(t.levelsMapped)", nil),
                ("Uploaded", String(format: "%.0f MB in total", t.uploadedMB), nil),
            ])
        }
        textures.isHidden = d.textures == nil

        memory.set([
            ("GPU allocated", String(format: "%.0f MB", d.allocatedMB), nil),
            ("Working set limit", String(format: "%.0f MB", d.workingSetMB), nil),
        ])

        counters.state = renderer.traversalCounters ? .on : .off
        if renderer.traversalCounters, let t = d.traversal, t.stats.rays > 0 {
            let s = t.stats
            traversal.set([
                ("Rays per frame", Self.count(Int(s.rays) / max(t.frames, 1)), nil),
                ("Triangle candidates", String(format: "%.1f per ray", s.perRay(1)), nil),
                ("Box candidates", String(format: "%.2f per ray", s.perRay(2)), nil),
            ])
        } else {
            traversal.set(renderer.traversalCounters ? [("", "waiting for frames…", nil)] : [])
        }
    }

    private func showPassTimes(_ times: [(name: String, ms: Double)]) {
        guard profile.state == .on, panel.isVisible else { return }
        let total = times.reduce(0) { $0 + $1.ms }
        let width = max(times.map(\.name.count).max() ?? 0, 5)
        let lines = times.map { $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + String(format: " %6.2f ms", $0.ms) }
        passTimes.stringValue = (lines + ["total".padding(toLength: width, withPad: " ", startingAt: 0) + String(format: " %6.2f ms", total)])
            .joined(separator: "\n")
        passTimes.isHidden = false
    }

    /// Triangles at the finest level, and the share of them the cut traces.
    private static func finest(_ source: Int, cut: Int) -> String {
        count(source) + (source > 0 ? String(format: " (cut is %.2g%%)", 100 * Double(cut) / Double(source)) : "")
    }

    /// 1234 -> "1,234"; millions as "12.3M".
    private static func count(_ n: Int) -> String {
        if n >= 10_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        return n.formatted(.number)
    }

    // MARK: - Virtual geometry

    private func buildVGControls() {
        let small = NSFont.smallSystemFontSize
        for field in [vgProbe, vgResidency] {
            field.font = .monospacedSystemFont(ofSize: small, weight: .regular)
            field.textColor = .secondaryLabelColor
        }
        for field in [vgTauValue, vgShareValue, vgPassesValue] {
            field.font = .monospacedDigitSystemFont(ofSize: small, weight: .regular)
        }
        vgGraph.translatesAutoresizingMaskIntoConstraints = false
        vgGraph.heightAnchor.constraint(equalToConstant: 96).isActive = true
        vgTable.translatesAutoresizingMaskIntoConstraints = false
        vgTable.heightAnchor.constraint(equalToConstant: 190).isActive = true
        vgTau.minValue = 0
        vgTau.maxValue = 1
        vgPasses.minValue = Double(Self.passesRange.lowerBound)
        vgPasses.maxValue = Double(Self.passesRange.upperBound)
        vgCountStepper.minValue = Double(Self.objectsRange.lowerBound)
        vgCountStepper.maxValue = Double(Self.objectsRange.upperBound)
        vgCount.alignment = .right
        vgCount.formatter = {
            let f = NumberFormatter()
            f.minimum = NSNumber(value: Self.objectsRange.lowerBound)
            f.maximum = NSNumber(value: Self.objectsRange.upperBound)
            f.allowsFloats = false
            return f
        }()
        vgCount.widthAnchor.constraint(equalToConstant: 56).isActive = true
        for (control, action) in [(vgTau, #selector(vgTauChanged)), (vgRecut, #selector(vgRecutPressed)),
                                  (vgWait, #selector(vgWaitChanged)), (vgShare, #selector(vgShareChanged)),
                                  (vgPasses, #selector(vgPassesChanged)), (vgView, #selector(vgViewChanged)),
                                  (vgBooth, #selector(vgBoothChanged)), (vgCount, #selector(vgCountEntered)),
                                  (vgCountStepper, #selector(vgCountStepped)), (vgEvict, #selector(vgEvictPressed))]
            as [(NSControl, Selector)] {
            control.target = self
            control.action = action
            control.controlSize = .small
            if !(control is NSSlider || control is NSStepper) { control.font = .systemFont(ofSize: small) }
        }
        vgViewModes = [0] + Array(RenderSettings.geometryViews) + Array(RenderSettings.vgViews)
        vgView.addItems(withTitles: vgViewModes.map { RenderSettings.viewModes[$0] })
        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.spacing = 6
            return s
        }
        let tauRow = row([label("Geometry error"), vgTau, vgTauValue])
        let waitRow = row([vgWait, vgShare, vgShareValue])
        let passesRow = row([label("Wait passes"), vgPassesValue, vgPasses])
        let viewRow = row([label("View"), vgView, vgRecut])
        let boothRow = row([label("Booth"), vgBooth])
        let countRow = row([label("Instances"), vgCount, vgCountStepper, vgEvict])
        for r in [tauRow, waitRow] { vgTau.widthAnchor.constraint(equalToConstant: 120).isActive = true; _ = r }
        vgShare.widthAnchor.constraint(equalToConstant: 100).isActive = true
        vgLabControls = [boothRow, countRow]
        for v in [vgGraph, vgProbe, vgResidency, vgTable, tauRow, waitRow, passesRow, viewRow, boothRow, countRow] { vg.add(v) }
    }

    private func updateVGControls(from s: RenderSettings) {
        let g = s.virtualGeometry
        vgTau.doubleValue = Self.tauSlider(g.pixelError)
        vgTauValue.stringValue = String(format: "%.2g px", g.pixelError)
        vgWait.state = g.waitRule ? .on : .off
        vgShare.doubleValue = Double(g.waitShare)
        vgShare.isEnabled = g.waitRule
        vgShareValue.stringValue = String(format: "%.0f%%", g.waitShare * 100)
        vgPasses.integerValue = g.waitPasses
        vgPasses.isEnabled = g.waitRule
        vgPassesValue.stringValue = "\(g.waitPasses)"
        vgView.selectItem(at: vgViewModes.firstIndex(of: s.viewMode) ?? -1)
        let lab = s.scene.kind.name == "vglab"
        for v in vgLabControls { v.isHidden = !lab }
        if lab, vgCount.currentEditor() == nil {
            vgCount.integerValue = s.scene.objects
            vgCountStepper.integerValue = s.scene.objects
        }
        let bookmarks = lab ? s.scene.kind.definition.bookmarks : []
        if bookmarks != shownBookmarks {
            shownBookmarks = bookmarks
            vgBooth.removeAllItems()
            var group: String?
            for b in bookmarks {
                if b.group != group {
                    group = b.group
                    vgBooth.menu?.addItem(NSMenuItem.sectionHeader(title: b.group))
                }
                let item = NSMenuItem(title: b.name, action: nil, keyEquivalent: "")
                item.representedObject = b.name
                vgBooth.menu?.addItem(item)
            }
            vgBooth.selectItem(at: -1)
        }
    }

    private static func tauSlider(_ v: Float) -> Double {
        let lo = Double(tauRange.lowerBound), hi = Double(tauRange.upperBound)
        return log(min(max(Double(v), lo), hi) / lo) / log(hi / lo)
    }

    private func showVG(_ r: VGReport) {
        vgGraph.set(r.history)
        if let p = r.probe {
            func px(_ v: Float) -> String { v.isFinite ? String(format: "%.2f px", v) : "none" }
            vgProbe.stringValue = "probe: instance \(p.ids.x), cluster \(p.ids.y), group \(p.ids.z), level \(p.ids.w)\n"
                + "error \(px(p.errors.x)) own, \(px(p.errors.y)) parent, tau \(String(format: "%g", r.pixelError)) px\n"
                + String(format: "distance %.2f m", p.errors.z) + (p.errors.w > 0.5 ? ", back face" : "")
        } else {
            vgProbe.stringValue = "aim at virtual geometry with a geometry view on"
        }
        let cold = zip(r.meshNames, r.residency).filter { $0.1 < 0.995 }
            .map { String(format: "%@ %.0f%%", $0.0, $0.1 * 100) }
        vgResidency.stringValue = cold.isEmpty ? "" : "cache resident: " + cold.joined(separator: ", ")
        vgResidency.isHidden = cold.isEmpty
        vgTable.show(r.rows)
    }

    @objc private func vgTauChanged() {
        let lo = Double(Self.tauRange.lowerBound), hi = Double(Self.tauRange.upperBound)
        let v = Float(lo * pow(hi / lo, vgTau.doubleValue))
        renderer.update { $0.virtualGeometry.pixelError = v }
    }
    @objc private func vgRecutPressed() { renderer.vgForceRecut() }
    @objc private func vgWaitChanged() {
        let on = vgWait.state == .on
        renderer.update { $0.virtualGeometry.waitRule = on }
    }
    @objc private func vgShareChanged() {
        let v = Float(vgShare.doubleValue)
        renderer.update { $0.virtualGeometry.waitShare = v }
    }
    @objc private func vgPassesChanged() {
        let v = vgPasses.integerValue
        renderer.update { $0.virtualGeometry.waitPasses = v }
    }
    @objc private func vgViewChanged() {
        let i = vgView.indexOfSelectedItem
        guard vgViewModes.indices.contains(i) else { return }
        let mode = vgViewModes[i]
        renderer.update { $0.viewMode = mode }
    }
    @objc private func vgBoothChanged() {
        guard let name = vgBooth.selectedItem?.representedObject as? String else { return }
        renderer.goToBookmark(name)
        vgBooth.selectItem(at: -1)
    }
    /// Enter in the field: the lab is rebuilt with that many instances.
    @objc private func vgCountEntered() {
        let n = min(max(vgCount.integerValue, Self.objectsRange.lowerBound), Self.objectsRange.upperBound)
        vgCount.integerValue = n
        vgCountStepper.integerValue = n
        renderer.update { $0.scene.objects = n }
    }
    @objc private func vgCountStepped() {
        vgCount.integerValue = vgCountStepper.integerValue   // applied on Enter: each change rebuilds the scene
    }
    @objc private func vgEvictPressed() { renderer.vgEvict() }

    // MARK: - Controls

    @objc private func profileChanged() {
        renderer.profilePasses = profile.state == .on && panel.isVisible
        if profile.state == .off { passTimes.isHidden = true; passTimes.stringValue = "" }
    }
    @objc private func freezeLODChanged() {
        let freeze = freezeLOD.state == .on
        renderer.update { $0.virtualGeometry.freeze = freeze }
    }
    @objc private func debugViewChanged() {
        guard debugView.indexOfSelectedItem >= 0 else { return }
        let mode = debugView.indexOfSelectedItem
        renderer.update { $0.viewMode = mode }
    }
    @objc private func countersChanged() {
        counters.isEnabled = false
        counters.title = "Compiling shaders…"   // in the background: the view keeps drawing
        renderer.setTraversalCounters(counters.state == .on) { [self] in
            counters.title = "Ray query counters (recompiles shaders, slower)"
            counters.isEnabled = true
            refresh()
        }
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return l
    }

    // MARK: - Views

    /// A titled group of label / value rows (both monospaced digits), plus any extra views above the rows.
    private final class Section: NSStackView {
        private let grid = NSGridView()
        private var labels: [String] = []
        static let labelWidth: CGFloat = 112

        package init(_ title: String) {
            super.init(frame: .zero)
            orientation = .vertical
            alignment = .leading
            spacing = 6
            let header = NSTextField(labelWithString: title)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            addArrangedSubview(header)
            grid.rowSpacing = 3
            grid.columnSpacing = 10
            addArrangedSubview(grid)
        }
        package required init?(coder: NSCoder) { fatalError() }

        /// Adds a view between the title and the rows.
        func add(_ view: NSView) {
            insertArrangedSubview(view, at: arrangedSubviews.count - 1)
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
            if view is FrameGraphView || view is VGGraphView || view is NSTextField || view is VGInstanceTable { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }

        /// Shows `rows` (label, value, colour); the grid is rebuilt only when the labels change.
        func set(_ rows: [(String, String, NSColor?)]) {
            if rows.map(\.0) != labels {
                labels = rows.map(\.0)
                while grid.numberOfRows > 0 {   // removeRow leaves the row's views in the grid
                    for c in 0..<grid.numberOfColumns { grid.cell(atColumnIndex: c, rowIndex: 0).contentView?.removeFromSuperview() }
                    grid.removeRow(at: 0)
                }
                for row in rows {
                    let name = NSTextField(labelWithString: row.0)
                    name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                    name.textColor = .secondaryLabelColor
                    let value = NSTextField(labelWithString: "")
                    value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                    value.lineBreakMode = .byTruncatingTail
                    value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    grid.addRow(with: [name, value])
                }
                if grid.numberOfColumns > 0 {   // the same label width in every section, so the values line up
                    grid.column(at: 0).xPlacement = .trailing
                    grid.column(at: 0).width = Section.labelWidth
                }
                grid.isHidden = rows.isEmpty
            }
            for (i, row) in rows.enumerated() {
                guard let value = grid.cell(atColumnIndex: 1, rowIndex: i).contentView as? NSTextField else { continue }
                if value.stringValue != row.1 { value.stringValue = row.1 }
                value.textColor = row.2 ?? .labelColor
            }
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

extension DebugPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { setActive(false) }
}

/// The last 300 frames' CPU frame interval and GPU time, autoscaled, with 60 and 30 fps guides.
final class FrameGraphView: NSView {
    private static let capacity = 300
    private var cpu = [Double](repeating: 0, count: capacity)
    private var gpu = [Double](repeating: 0, count: capacity)
    private var next = 0, filled = 0

    func add(cpu c: Double, gpu g: Double) {
        cpu[next] = c
        gpu[next] = g
        next = (next + 1) % Self.capacity
        filled = min(filled + 1, Self.capacity)
        needsDisplay = true
    }

    /// Sample `i` frames back from the oldest kept one (0 = oldest).
    private func sample(_ values: [Double], _ i: Int) -> Double {
        values[(next - filled + i + Self.capacity) % Self.capacity]
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        guard filled > 1 else { return }

        let recentCPU = (0..<filled).map { sample(cpu, $0) }, recentGPU = (0..<filled).map { sample(gpu, $0) }
        let peak = max(recentCPU.max() ?? 0, recentGPU.max() ?? 0)
        let top = [20.0, 40, 80, 160, 320, 1000].first { $0 >= peak * 1.1 } ?? peak * 1.1
        let plot = r.insetBy(dx: 4, dy: 4)
        func y(_ ms: Double) -> CGFloat { plot.minY + CGFloat(min(ms / top, 1)) * plot.height }
        func x(_ i: Int) -> CGFloat { plot.minX + CGFloat(i) / CGFloat(Self.capacity - 1) * plot.width }

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        for guide in [1000.0 / 60, 1000.0 / 30] where guide < top {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y(guide)))
            path.line(to: NSPoint(x: plot.maxX, y: y(guide)))
            path.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            (String(format: "%.1f", guide) as NSString).draw(at: NSPoint(x: plot.maxX - 24, y: y(guide) + 1), withAttributes: attrs)
        }
        let offset = Self.capacity - filled   // newest at the right edge
        for (values, color) in [(recentCPU, NSColor.systemOrange.withAlphaComponent(0.75)), (recentGPU, NSColor.systemBlue)] {
            let path = NSBezierPath()
            for (i, v) in values.enumerated() {
                let p = NSPoint(x: x(offset + i), y: y(v))
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineWidth = 1.25
            color.setStroke()
            path.stroke()
        }

        func legend(_ name: String, _ values: [Double]) -> String {
            String(format: "%@ %.1f ms (avg %.1f, max %.1f)", name, values.last ?? 0, values.reduce(0, +) / Double(values.count), values.max() ?? 0)
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        (legend("GPU", recentGPU) as NSString).draw(at: NSPoint(x: plot.minX + 2, y: plot.maxY - 12),
                                                   withAttributes: [.font: font, .foregroundColor: NSColor.systemBlue])
        (legend("CPU", recentCPU) as NSString).draw(at: NSPoint(x: plot.minX + 2, y: plot.maxY - 25),
                                                   withAttributes: [.font: font, .foregroundColor: NSColor.systemOrange])
        (String(format: "scale %.0f ms", top) as NSString).draw(at: NSPoint(x: plot.maxX - 58, y: plot.minY + 1), withAttributes: attrs)
    }
}
