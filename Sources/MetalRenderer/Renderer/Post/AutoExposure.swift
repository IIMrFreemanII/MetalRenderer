import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import Metal
import Physics
import Plants

/// Auto exposure (PostSettings.autoExposure): the tone-map pass adds one pixel in 8 x 8 of the frame's light to a
/// histogram of its log2 luminance (Shaders/Output.metal meterExposure); a few frames on, when its frame is done, the
/// histogram's middle (the mean between its 40th and 92nd percentiles, so the sky and the deepest shade don't pull)
/// sets the exposure that puts it at middle grey, which the exposure eases toward (an eye's, by the clock's step: a
/// benchmark's fixed one gives the same pictures every run). Ring of histograms, one per frame in flight and one more.
package final class AutoExposure {
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

    // The default (the above is the classic look's, PostSettings.classic), Unreal's: the mean between the 10th and 90th
    // percentiles goes to middle grey plus its default bias of one stop, 0.36 (a uniform frame in 5.8 settles there). It
    // moves in stops a second, 3 closing down and 1 opening up, easing over the last 1.5 stops. Its limits are its
    // EV100 -10...20, with its units the same as here: 1 = 1 cd/m2, a sun of 1 = 1 lux (the shading is colour x cos / pi).
    static let filmLow: Float = 0.1, filmHigh: Float = 0.9, filmKey: Float = 0.36
    static let filmClose: Float = 3, filmOpen: Float = 1, filmEase: Float = 1.5
    static let filmLimits: ClosedRange<Float> = -21.6...8.4

    private let buffers: [MTLBuffer]
    private var frame = 0
    private var exposure: Float = 1
    private var settled = false
    /// Histograms still to come from frames before the reset: not measured, or the new scene would start from the old one's.
    private var stale = 0

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
        stale = buffers.count
    }

    /// Once a frame, before it is encoded: the oldest histogram (its frame is done) read and cleared for this frame,
    /// and the exposure scale (times the manual exposure) to use. `dt`: the clock's step since the last frame.
    func next(dt: Float = 1.0 / 60, classic: Bool = false) -> Float {
        frame += 1
        let b = current, h = b.contents().bindMemory(to: UInt32.self, capacity: AutoExposure.bins)
        var counts = [Float](repeating: 0, count: AutoExposure.bins)
        for i in 0..<AutoExposure.bins { counts[i] = Float(h[i]) }
        memset(b.contents(), 0, AutoExposure.bins * 4)
        if stale > 0 {
            stale -= 1
            return exposure
        }
        let total = counts.reduce(0, +)
        guard total >= 16 else { return exposure }
        let lo = total * (classic ? 0.4 : AutoExposure.filmLow), hi = total * (classic ? 0.92 : AutoExposure.filmHigh)
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
        guard classic else {
            let target = AutoExposure.filmLimits.clamp(log2(AutoExposure.filmKey) - sum / weight)
            if settled {
                let now = log2(exposure), away = target - now, far = abs(away)
                let stops = (away < 0 ? AutoExposure.filmClose : AutoExposure.filmOpen) * max(dt, 0)
                let move = far > AutoExposure.filmEase ? stops : far * (1 - exp(-stops / AutoExposure.filmEase))
                exposure = exp2(now + (away < 0 ? -1 : 1) * min(move, far))
            } else {
                exposure = exp2(target)
            }
            settled = true
            return exposure
        }
        var target = log2(AutoExposure.key) - sum / weight
        if target > AutoExposure.fullLimit { target = AutoExposure.fullLimit + (target - AutoExposure.fullLimit) * 0.5 }
        target = min(max(target, -6), AutoExposure.limit)
        let share = 1 - pow(1 - (target < log2(exposure) ? AutoExposure.easeDown : AutoExposure.ease), max(dt, 0) * 60)
        exposure = settled ? exp2(log2(exposure) + (target - log2(exposure)) * share) : exp2(target)
        settled = true
        return exposure
    }
}
