import AppKit

/// The day bar: at the bottom of the render view in the scenes with a day (DayClock), the time of day as a clock, the
/// day's times to switch to (Dawn, Noon, Sunset, Night), a play button that lets the day run or holds it, and a slider
/// over the clock's hours. A picked time holds the day (`RenderSettings.dayHeld`); the rest of the scene goes on
/// moving. A view over the render: the frames themselves never have it. Z or the app menu hides it.
final class DayBar: NSView {
    /// A time picked; the slider moved to an hour; play (true: let the day run) or pause (hold it where it is).
    var onPreset: ((DayPreset) -> Void)?
    var onHour: ((Float) -> Void)?
    var onPlay: ((Bool) -> Void)?

    static let width: CGFloat = 400

    /// On unless turned off with Z (kept across launches).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "DayBar.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "DayBar.enabled") }
    }

    private let icon = NSImageView()
    private let time = NSTextField(labelWithString: "")
    private let presets = NSSegmentedControl(labels: DayPreset.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let play = NSButton()
    private let slider = NSSlider()

    private var clock: DayClock?
    private var held = false, paused = false
    /// The hour the renderer last told while the day ran.
    private var runningHour: Float?
    private var sceneKind: SceneKind?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: DayBar.width, height: 64))
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = NSColor(white: 0.92, alpha: 1)
        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        time.textColor = NSColor(white: 0.95, alpha: 1)
        time.widthAnchor.constraint(equalToConstant: 48).isActive = true
        presets.controlSize = .small
        presets.segmentStyle = .rounded
        presets.target = self
        presets.action = #selector(picked)
        play.bezelStyle = .texturedRounded
        play.controlSize = .small
        play.imagePosition = .imageOnly
        play.target = self
        play.action = #selector(playPressed)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)

        let top = NSStackView(views: [icon, time, presets, play])
        top.orientation = .horizontal
        top.spacing = 8
        top.alignment = .centerY
        let stack = NSStackView(views: [top, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 11, bottom: 9, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -22),
            widthAnchor.constraint(equalToConstant: DayBar.width),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Puts it at the bottom of `view`, in the middle.
    func attach(to view: NSView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    /// Z: hides it for good, or shows it again.
    func toggle() {
        DayBar.isEnabled.toggle()
        refresh()
    }

    /// The settings changed: the scene, whether the day is held and where.
    func show(_ s: RenderSettings) {
        if s.scene.kind != sceneKind {
            sceneKind = s.scene.kind
            clock = DayClock.of(s.scene.kind)
            runningHour = nil
        }
        held = s.dayHeld
        paused = s.paused
        if let hour = s.heldHour { runningHour = hour }
        refresh()
    }

    /// The renderer's day clock moved (while the day runs).
    func show(dayTime: Float) {
        guard !held, let hour = clock?.hour(dayTime: dayTime) else { return }
        runningHour = hour
        refresh()
    }

    private func refresh() {
        guard let clock, DayBar.isEnabled else { isHidden = true; return }
        isHidden = false
        let hour = clock.runs ? runningHour : nil
        time.stringValue = clock.runs ? hour.map(DayClock.label) ?? "--:--" : "Night"
        let night = clock.isNight(hour: hour)
        icon.image = NSImage(systemSymbolName: night ? "moon.stars.fill" : "sun.max.fill", accessibilityDescription: night ? "Night" : "Day")
        for p in DayPreset.allCases { presets.setEnabled(clock.offers(p), forSegment: p.rawValue) }
        // The time picked shows while the day is held there.
        if let p = held || !clock.runs ? clock.preset(at: hour) : nil {
            presets.selectedSegment = p.rawValue
        } else {
            presets.selectedSegment = -1
        }
        let running = clock.runs && !held && !paused
        play.image = NSImage(systemSymbolName: running ? "pause.fill" : "play.fill", accessibilityDescription: running ? "Hold the day" : "Let the day run")
        play.toolTip = running ? "Hold the time of day" : "Let the day run"
        play.isEnabled = clock.runs
        slider.minValue = Double(clock.hours.lowerBound)
        slider.maxValue = Double(clock.hours.upperBound)
        slider.isEnabled = clock.runs
        if let hour { slider.doubleValue = Double(hour) }
    }

    @objc private func picked() {
        guard let p = DayPreset(rawValue: presets.selectedSegment) else { return }
        onPreset?(p)
    }

    /// To the minute: five of them a step.
    @objc private func slid() {
        onHour?(Float((slider.doubleValue * 12).rounded() / 12))
    }

    @objc private func playPressed() {
        onPlay?(held || paused)
    }

    /// Only the controls take the mouse; the box around them is the render view's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit is NSStackView ? nil : hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
