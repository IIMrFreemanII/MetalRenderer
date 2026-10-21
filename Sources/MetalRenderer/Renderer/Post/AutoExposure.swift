import Metal

/// Auto exposure (PostSettings.autoExposure): the tone-map pass adds one pixel in 8 x 8 of the frame's light to a
/// histogram of its log2 luminance (Shaders/Output.metal meterExposure); a few frames on, when its frame is done, the
/// histogram's middle (the mean between its 40th and 92nd percentiles, so the sky and the deepest shade don't pull)
/// sets the exposure that puts it at middle grey, which the exposure eases toward (an eye's, by the clock's step: a
/// benchmark's fixed one gives the same pictures every run). Ring of histograms, one per frame in flight and one more.
final class AutoExposure {
    static let bins = 64, logMin: Float = -14, logMax: Float = 10
    /// What the histogram's middle is exposed to (middle grey, a little under for a camera's look).
    static let key: Float = 0.16
    /// The share of the way to the target exposure a 60th of a second goes, as the exposure opens up (a darker view):
    /// half-way in 0.14 s. It closes down (a brighter view) twice as fast, so a sunlit room doesn't flash white. By the
    /// clock, not by the frame: at the window's 14 fps a per-frame share took 3 s to settle, and blew rooms out on the way.
    static let ease: Float = 0.08, easeDown: Float = 0.153
    /// The most the exposure opens up: 2^6 at middle grey's pace, then half as fast to 2^8 (a storeroom lit only
    /// through its door reads as a dim room, not a black one; darker still stays dark).
    static let fullLimit: Float = 6, limit: Float = 8

    private let buffers: [MTLBuffer]
    private var frame = 0
    private var exposure: Float = 1
    private var settled = false

    package init(device: MTLDevice, framesInFlight: Int) {
        buffers = (0...framesInFlight).map { _ in
            let b = device.makeBuffer(length: AutoExposure.bins * 4, options: .storageModeShared)!
            memset(b.contents(), 0, AutoExposure.bins * 4)
            b.label = "exposure histogram"
            return b
        }
    }

    /// The histogram this frame adds to.
    var current: MTLBuffer { buffers[frame % buffers.count] }
    /// The one the next frame reads first (tests).
    func peekNext() -> MTLBuffer { buffers[(frame + 1) % buffers.count] }

    /// Back to as it was (the meter off, or another scene): the next measure is taken at once.
    func reset() {
        settled = false
        exposure = 1
    }

    /// Once a frame, before it is encoded: the oldest histogram (its frame is done) read and cleared for this frame,
    /// and the exposure scale (times the manual exposure) to use. `dt`: the clock's step since the last frame.
    func next(dt: Float = 1.0 / 60) -> Float {
        frame += 1
        let b = current, h = b.contents().bindMemory(to: UInt32.self, capacity: AutoExposure.bins)
        var counts = [Float](repeating: 0, count: AutoExposure.bins)
        for i in 0..<AutoExposure.bins { counts[i] = Float(h[i]) }
        memset(b.contents(), 0, AutoExposure.bins * 4)
        let total = counts.reduce(0, +)
        guard total >= 16 else { return exposure }
        let lo = total * 0.4, hi = total * 0.92
        var seen: Float = 0, sum: Float = 0, weight: Float = 0
        let step = (AutoExposure.logMax - AutoExposure.logMin) / Float(AutoExposure.bins)
        for i in 0..<AutoExposure.bins {
            let a = max(seen, lo), z = min(seen + counts[i], hi)
            if z > a {
                sum += (z - a) * (AutoExposure.logMin + (Float(i) + 0.5) * step)
                weight += z - a
            }
            seen += counts[i]
        }
        guard weight > 0 else { return exposure }
        // (The light was measured before the exposure: the target is absolute.)
        var target = log2(AutoExposure.key) - sum / weight
        if target > AutoExposure.fullLimit { target = AutoExposure.fullLimit + (target - AutoExposure.fullLimit) * 0.5 }
        target = min(max(target, -6), AutoExposure.limit)
        let share = 1 - pow(1 - (target < log2(exposure) ? AutoExposure.easeDown : AutoExposure.ease), max(dt, 0) * 60)
        exposure = settled ? exp2(log2(exposure) + (target - log2(exposure)) * share) : exp2(target)
        settled = true
        return exposure
    }
}
