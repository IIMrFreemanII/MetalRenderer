import AppKit
import QuartzCore

/// The loading overlay: a box in the render view's bottom-left corner that shows what loads in the background
/// (`LoadActivity`): each load's steps with their counts, the item they are on and a bar, then what streams in after a
/// scene is installed. It comes up when something has been loading for a moment, and fades out two seconds after
/// everything is done. A view over the render: the frames themselves never have it. P or the app menu hides it.
final class LoadingOverlay: NSView {
    private let activity: LoadActivity
    private let stack = NSStackView()
    private var rows: [Row] = []
    private var timer: Timer?
    private var busySince: Double?
    private var showing = false
    private var hiddenAt = -Double.infinity      // loads that ended before the box last went aren't shown again

    /// Something must have been loading this long before the box comes up (a variant compiled in 50 ms isn't news).
    static let showDelay = 0.3
    /// How long the box stays once everything is done, then how long it takes to fade.
    static let linger = 2.0, fade = 0.4
    static let width: CGFloat = 340

    /// On unless turned off with P (kept across launches).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "LoadingOverlay.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "LoadingOverlay.enabled") }
    }

    init(activity: LoadActivity) {
        self.activity = activity
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 11, bottom: 10, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: LoadingOverlay.width),
        ])
        isHidden = true
        alphaValue = 0
        activity.onChange = { [weak self] in
            DispatchQueue.main.async { self?.wake() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mouse and keys go to the render view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Puts it in `view`'s bottom-left corner and starts watching (a shader compile may already be running).
    func attach(to view: NSView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        wake()
    }

    /// P: hides it for good, or lets it come up again.
    func toggle() {
        LoadingOverlay.isEnabled.toggle()
        if LoadingOverlay.isEnabled { wake() } else { hide(animated: false) }
    }

    // MARK: Refresh

    /// Something started or ended: refresh ten times a second until the box has gone again.
    private func wake() {
        guard LoadingOverlay.isEnabled, timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)   // also while a menu is open or the window is resized
        self.timer = timer
        tick()
    }

    private func tick() {
        let snap = activity.snapshot()
        if !snap.isIdle { busySince = busySince ?? snap.now }
        let wanted = LoadingOverlay.isEnabled && (snap.jobs.contains { ($0.ended ?? .infinity) > hiddenAt } || !snap.streams.isEmpty)
        if !showing {
            // Up once something has been loading for a moment; nothing to do if it was over before that.
            if let since = busySince, wanted, !snap.isIdle, snap.now - since >= LoadingOverlay.showDelay {
                show()
            } else if snap.isIdle {
                busySince = nil
                stop()
                return
            }
        } else if let idle = snap.idleSince, snap.now - idle >= LoadingOverlay.linger {
            busySince = nil
            hide(animated: true)
            stop()
            return
        }
        if showing { update(snap) }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func show() {
        showing = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    private func hide(animated: Bool) {
        showing = false
        hiddenAt = CACurrentMediaTime()
        stop()
        guard animated else { alphaValue = 0; isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = LoadingOverlay.fade
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.showing == false { self?.isHidden = true }
        })
    }

    /// The rows for `snap`: per job a heading and its steps, then the streams.
    private func update(_ snap: LoadActivity.Snapshot) {
        var models: [Row.Model] = []
        for job in snap.jobs where (job.ended ?? .infinity) > hiddenAt {
            let running = job.ended == nil
            models.append(.heading(running ? job.heading + "…" : job.heading, LoadActivity.duration(job.seconds(now: snap.now)),
                                   failed: job.failed))
            for step in job.steps {
                let state: Row.State = step.ended == nil ? .running : job.failed && step.ended == job.ended ? .failed : .done
                models.append(.item(state: state, name: step.name, count: Row.count(step.done, step.total),
                                    time: LoadActivity.duration(step.seconds(now: snap.now)), detail: step.detail,
                                    progress: state == .running ? Row.progress(step.done, step.total) : nil))
            }
        }
        if !snap.streams.isEmpty {
            models.append(.heading("Streaming in", "", failed: false))
            for stream in snap.streams {
                models.append(.item(state: .streaming, name: stream.name, count: Row.count(stream.done, stream.total), time: "",
                                    detail: stream.detail, progress: Row.progress(stream.done, stream.total)))
            }
        }
        while rows.count < models.count {
            let row = Row()
            rows.append(row)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -22).isActive = true
        }
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= models.count
            if i < models.count { row.show(models[i]) }
        }
    }
}

/// A line of the overlay: a heading (what loads, how long so far), or a step or stream with its count, time, the item
/// it is on and a bar.
private final class Row: NSStackView {
    enum State { case running, done, failed, streaming }
    enum Model {
        case heading(String, String, failed: Bool)
        /// `progress`: 0...1, -1 for no count (a moving bar), nil for none.
        case item(state: State, name: String, count: String, time: String, detail: String, progress: Double?)
    }

    static func count(_ done: Int, _ total: Int) -> String { total > 0 ? "\(min(done, total))/\(total)" : "" }
    static func progress(_ done: Int, _ total: Int) -> Double { total > 0 ? min(Double(done) / Double(total), 1) : -1 }

    private let glyph = Row.label(size: 11, weight: .semibold)
    private let name = Row.label(size: 11, weight: .medium)
    private let count = Row.label(size: 11, weight: .regular)
    private let time = Row.label(size: 11, weight: .regular)
    private let detail = Row.label(size: 10, weight: .regular)
    private let bar = NSProgressIndicator()

    private static func label(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        glyph.alignment = .center
        glyph.widthAnchor.constraint(equalToConstant: 12).isActive = true
        count.textColor = NSColor(white: 0.75, alpha: 1)
        time.textColor = NSColor(white: 0.6, alpha: 1)
        time.alignment = .right
        for l in [glyph, count, time] { l.setContentCompressionResistancePriority(.required, for: .horizontal) }
        detail.textColor = NSColor(white: 0.65, alpha: 1)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [glyph, name, count, spacer, time])
        line.spacing = 6
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        let indented = NSStackView(views: [detail, bar])
        indented.orientation = .vertical
        indented.alignment = .leading
        indented.spacing = 2
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        addArrangedSubview(line)
        addArrangedSubview(indented)
        for v in [line, indented] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        bar.widthAnchor.constraint(equalTo: indented.widthAnchor, constant: -18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ model: Model) {
        switch model {
        case .heading(let title, let seconds, let failed):
            glyph.isHidden = true
            name.stringValue = title
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            name.textColor = failed ? .systemRed : .white
            count.stringValue = ""
            time.stringValue = seconds
            setDetail("", progress: nil)
        case .item(let state, let title, let n, let seconds, let text, let progress):
            glyph.isHidden = false
            switch state {
            case .running: (glyph.stringValue, glyph.textColor) = ("▸", .systemBlue)
            case .done: (glyph.stringValue, glyph.textColor) = ("✓", .systemGreen)
            case .failed: (glyph.stringValue, glyph.textColor) = ("✕", .systemRed)
            case .streaming: (glyph.stringValue, glyph.textColor) = ("↓", .systemTeal)
            }
            name.stringValue = title
            name.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            name.textColor = state == .done ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.95, alpha: 1)
            count.stringValue = n
            time.stringValue = seconds
            setDetail(state == .done ? "" : text, progress: progress)
        }
    }

    private func setDetail(_ text: String, progress: Double?) {
        detail.stringValue = text
        detail.isHidden = text.isEmpty
        bar.isHidden = progress == nil
        guard let progress else { bar.stopAnimation(nil); return }
        if progress < 0 {
            if !bar.isIndeterminate { bar.isIndeterminate = true }
            bar.startAnimation(nil)
        } else {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            bar.doubleValue = progress
        }
    }
}
