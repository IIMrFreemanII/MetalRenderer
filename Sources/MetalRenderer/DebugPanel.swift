import AppKit

/// What the Debug window shows, as of the last stats tick (Renderer.debugInfo).
struct DebugInfo {
    enum VirtualGeometry {
        case off
        /// Per-instance BLAS over each instance's cut (VirtualBLAS, the default).
        case blas(meshes: Int, instances: Int, sourceTriangles: Int, triangles: Int, clusters: Int, megabytes: Double,
                  rebuilds: Int, lastBuildMs: Double, lastRefineMs: Double, lastCutMs: Double, skipped: Int, builder: String, busy: Bool)
        /// One tree over the frame's cut of clusters, streamed into a pool (VirtualGeometry, METALRENDERER_VG_MODE=clusters).
        case clusters(meshes: Int, instances: Int, clusters: Int, groups: Int, selected: Int, capacity: Int, overflow: Bool,
                      residentGroups: Int, residentMB: Double, poolMB: Int, pending: Int, loadedThisFrame: Int)
    }

    var stats = ""
    var cpuMs = 0.0                     // the CPU's frame interval, averaged
    var encodeMs = 0.0                  // the CPU's own work per frame (simulation, uploads, encoding), averaged
    var sceneTitle = ""
    var instances = 0, virtualInstances = 0, triangles = 0
    var analyticLights = 0, meshLights = 0, suns = 0
    var lightTable = false, lightTableEntries = 0
    var directMode = "", giMode = "", rayTracer = ""
    var customTracer = false
    var vg = VirtualGeometry.off
    var vgPixelError: Float = 1
    var vgFrozen = false
    var textures: (residentMB: Double, budgetMB: Int, levelsMapped: Int, uploadedMB: Double)?
    var allocatedMB = 0.0, workingSetMB = 0.0
    var traversal: (stats: TraversalStats, frames: Int)?
}

/// Floating panel with live debug data: a frame-time graph, GPU pass timings, the scene, virtual geometry, texture
/// streaming, memory and the custom tracer's traversal counters. Like the settings panel it never becomes key, so
/// the keyboard keeps driving the renderer. I or Cmd-I shows or hides it.
final class DebugPanel: NSObject {
    let panel: NSPanel
    private let renderer: Renderer

    private let stats = NSTextField(wrappingLabelWithString: "")
    private let graph = FrameGraphView()
    private let profile = NSButton(checkboxWithTitle: "GPU pass timings (disables pass overlap)", target: nil, action: nil)
    private let passTimes = NSTextField(labelWithString: "")
    private let debugView = NSPopUpButton()
    private let freezeLOD = NSButton(checkboxWithTitle: "Freeze LOD (L)", target: nil, action: nil)
    private let counters = NSButton(checkboxWithTitle: "Traversal counters (recompiles shaders)", target: nil, action: nil)
    private let frame = Section("Frame")
    private let passes = Section("GPU passes")
    private let scene = Section("Scene")
    private let vg = Section("Virtual geometry")
    private let textures = Section("Texture streaming")
    private let memory = Section("Memory")
    private let traversal = Section("Ray traversal (custom tracer)")
    /// The debug views offered here: Final, then the geometry views (RenderSettings.geometryViews).
    private let debugViewModes = [0] + Array(RenderSettings.geometryViews)
    private var lastRebuilds: (count: Int, time: CFTimeInterval)?
    private var rebuildRate = 0.0

    private static let visibleKey = "debug.visible"
    /// Shown at the last launch (the window comes back where it was).
    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(renderer: Renderer) {
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
        debugView.addItems(withTitles: debugViewModes.map { RenderSettings.viewModes[$0] })
        profile.isHidden = !renderer.passProfilingSupported
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 96).isActive = true

        frame.add(stats)
        frame.add(graph)
        passes.add(profile)
        passes.add(passTimes)
        let controls = NSStackView(views: [label("Debug view"), debugView, freezeLOD])
        controls.spacing = 6
        vg.add(controls)
        traversal.add(counters)

        let stack = NSStackView(views: [frame, passes, scene, vg, textures, memory, traversal])
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
        renderer.profilePasses = active && profile.state == .on
        if active { refresh() }
    }

    // MARK: - Updates

    private func update(from s: RenderSettings) {
        debugView.selectItem(at: debugViewModes.firstIndex(of: s.viewMode) ?? -1)
        if debugViewModes.firstIndex(of: s.viewMode) == nil { debugView.setTitle(RenderSettings.viewModes[s.viewMode]) }
        freezeLOD.state = s.virtualGeometry.freeze ? .on : .off
    }

    private func refresh() {
        guard panel.isVisible else { return }
        let d = renderer.debugInfo()
        stats.stringValue = d.stats + String(format: " — CPU %.1f ms (encode %.2f)", d.cpuMs, d.encodeMs)

        let lights = [(d.analyticLights, "analytic"), (d.meshLights, "mesh"), (d.suns, d.suns == 1 ? "sun" : "suns")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        scene.set([
            ("Scene", d.sceneTitle, nil),
            ("Instances", d.virtualInstances > 0 ? "\(d.instances) (\(d.virtualInstances) virtual)" : "\(d.instances)", nil),
            ("Triangles", Self.count(d.triangles) + (d.virtualInstances > 0 ? " (without virtual)" : ""), nil),
            ("Lights", lights.isEmpty ? "none" : lights.joined(separator: ", "), nil),
            ("Light table", d.lightTable ? "on, \(Self.count(d.lightTableEntries)) entries" : "off (256 lights or fewer)", nil),
            ("Direct light", d.directMode, nil),
            ("GI", d.giMode, nil),
            ("Ray tracer", d.rayTracer, nil),
        ])

        var vgRows: [(String, String, NSColor?)] = []
        switch d.vg {
        case .off:
            lastRebuilds = nil
        case let .blas(meshes, instances, source, triangles, clusters, megabytes, rebuilds, lastBuildMs, lastRefineMs, lastCutMs, skipped, builder, busy):
            let now = CACurrentMediaTime()
            if let last = lastRebuilds, now > last.time { rebuildRate = Double(rebuilds - last.count) / (now - last.time) }
            lastRebuilds = (rebuilds, now)
            vgRows = [
                ("Mode", "per-instance BLAS (\(builder))", nil),
                ("Meshes", "\(meshes) in \(instances) instances", nil),
                ("Traced triangles", Self.count(triangles), nil),
                ("Finest level", Self.count(source) + (source > 0 ? String(format: " (cut is %.2g%%)", 100 * Double(triangles) / Double(source)) : ""), nil),
                ("Clusters in cut", Self.count(clusters), nil),
                ("BLAS memory", String(format: "%.1f MB", megabytes), nil),
                ("Rebuilds", String(format: "%d total, %.1f/s", rebuilds, rebuildRate), nil),
                ("Last cut", String(format: "%.1f ms, %d of %d instances unchanged", lastCutMs, skipped, instances), nil),
                ("Last build", String(format: "%.1f ms", lastBuildMs) + (busy ? ", building" : ""), nil),
                ("Last refine", builder == "hybrid" ? String(format: "%.0f ms (SAH, in the background)", lastRefineMs) : "—", nil),
            ]
        case let .clusters(meshes, instances, clusters, groups, selected, capacity, overflow, residentGroups, residentMB, poolMB, pending, loaded):
            vgRows = [
                ("Mode", "cluster tree (streamed pool)", nil),
                ("Meshes", "\(meshes) in \(instances) instances", nil),
                ("Clusters drawn", "\(Self.count(selected)) of \(Self.count(capacity))" + (overflow ? ", capacity reached" : ""),
                 overflow ? .systemRed : nil),
                ("Clusters total", "\(Self.count(clusters)) in \(Self.count(groups)) groups", nil),
                ("Groups resident", "\(Self.count(residentGroups)) of \(Self.count(groups))", nil),
                ("Pool", String(format: "%.0f of %d MB", residentMB, poolMB), residentMB > 0.95 * Double(poolMB) ? .systemOrange : nil),
                ("Requests waiting", "\(pending)", nil),
                ("Loaded this frame", "\(loaded) groups", nil),
            ]
        }
        if !vgRows.isEmpty {
            vgRows += [("Pixel error", String(format: "%g px", d.vgPixelError), nil),
                       ("LOD", d.vgFrozen ? "frozen" : "follows the camera", d.vgFrozen ? .systemOrange : nil)]
        }
        vg.set(vgRows)
        vg.isHidden = vgRows.isEmpty

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

        traversal.isHidden = !d.customTracer
        counters.state = renderer.traversalCounters ? .on : .off
        if renderer.traversalCounters, let t = d.traversal, t.stats.rays > 0 {
            let s = t.stats
            traversal.set([
                ("Rays per frame", Self.count(Int(s.rays) / max(t.frames, 1)), nil),
                ("Top nodes", String(format: "%.1f per ray", s.perRay(1))
                    + (s.counts[6] > 0 ? String(format: " (%.1f in cluster trees)", s.perRay(6)) : ""), nil),
                ("Bottom nodes", String(format: "%.1f per ray", s.perRay(2)), nil),
                ("Instance entries", String(format: "%.2f per ray", s.perRay(3)), nil),
                ("Cluster entries", String(format: "%.2f per ray", s.perRay(4)), nil),
                ("Triangle tests", String(format: "%.1f per ray", s.perRay(5)), nil),
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

    /// 1234 -> "1,234"; millions as "12.3M".
    private static func count(_ n: Int) -> String {
        if n >= 10_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        return n.formatted(.number)
    }

    // MARK: - Controls

    @objc private func profileChanged() {
        renderer.profilePasses = profile.state == .on && panel.isVisible
        if profile.state == .off { passTimes.isHidden = true; passTimes.stringValue = "" }
    }
    @objc private func freezeLODChanged() { renderer.settings.virtualGeometry.freeze = freezeLOD.state == .on }
    @objc private func debugViewChanged() {
        guard debugView.indexOfSelectedItem >= 0 else { return }
        renderer.settings.viewMode = debugViewModes[debugView.indexOfSelectedItem]
    }
    @objc private func countersChanged() {
        counters.isEnabled = false
        counters.title = "Compiling shaders…"   // in the background: the view keeps drawing
        renderer.setTraversalCounters(counters.state == .on) { [self] in
            counters.title = "Traversal counters (recompiles shaders)"
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

        init(_ title: String) {
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
        required init?(coder: NSCoder) { fatalError() }

        /// Adds a view between the title and the rows.
        func add(_ view: NSView) {
            insertArrangedSubview(view, at: arrangedSubviews.count - 1)
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
            if view is FrameGraphView || view is NSTextField { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
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
