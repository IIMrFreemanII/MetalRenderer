import EngineCore
import Foundation
import simd

/// How a curve goes from a key to the next: held, a straight line, eased (both ends, the start, the end), or a cubic
/// through the keys' slopes (Houdini's bezier with its auto slopes, the default).
package enum ProcInterpolation: String, Codable, CaseIterable {
    case constant, linear, ease, easeIn, easeOut, spline

    package var title: String {
        switch self {
        case .constant: "Constant"
        case .linear: "Linear"
        case .ease: "Ease"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .spline: "Spline"
        }
    }
}

/// What a curve does before its first key and after its last: holds the key's value, repeats the keys, repeats them
/// each time offset by their change, or goes on along its end slope.
package enum ProcExtrapolation: String, Codable, CaseIterable {
    case hold, cycle, cycleOffset, linear

    package var title: String {
        switch self {
        case .hold: "Hold"
        case .cycle: "Cycle"
        case .cycleOffset: "Cycle with Offset"
        case .linear: "Linear"
        }
    }
}

/// A key: the channel's value at a frame, how the curve goes on to the next key, and its slopes (in, out: value per
/// frame; nil: automatic).
package struct ProcKey: Codable, Equatable {
    package var frame: Float
    package var value: Float
    package var interpolation: ProcInterpolation = .spline
    package var slopes: SIMD2<Float>?

    package init(frame: Float, value: Float, interpolation: ProcInterpolation = .spline, slopes: SIMD2<Float>? = nil) {
        self.frame = frame
        self.value = value
        self.interpolation = interpolation
        self.slopes = slopes
    }

    private enum Key: String, CodingKey { case frame, value, interpolation, slopes }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        frame = try c.decode(Float.self, forKey: .frame)
        value = try c.decode(Float.self, forKey: .value)
        interpolation = try c.decodeIfPresent(ProcInterpolation.self, forKey: .interpolation) ?? .spline
        slopes = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .slopes)
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(frame, forKey: .frame)
        try c.encode(value, forKey: .value)
        if interpolation != .spline { try c.encode(interpolation, forKey: .interpolation) }
        if let slopes { try c.encode(slopes, forKey: .slopes) }
    }
}

/// A keyframed channel: its keys by frame, and what it does outside them. A channel with one is cooked from its value
/// at the frame (ProcExprContext.value(ofChannel:)).
package struct ProcCurve: Codable, Equatable {
    /// Sorted by frame, one a frame.
    package private(set) var keys: [ProcKey] = []
    package var before = ProcExtrapolation.hold
    package var after = ProcExtrapolation.hold

    package init(_ keys: [ProcKey] = [], before: ProcExtrapolation = .hold, after: ProcExtrapolation = .hold) {
        self.before = before
        self.after = after
        for k in keys { insert(k) }
    }

    private enum Key: String, CodingKey { case keys, before, after }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        self.init(try c.decode([ProcKey].self, forKey: .keys),
                  before: try c.decodeIfPresent(ProcExtrapolation.self, forKey: .before) ?? .hold,
                  after: try c.decodeIfPresent(ProcExtrapolation.self, forKey: .after) ?? .hold)
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(keys, forKey: .keys)
        if before != .hold { try c.encode(before, forKey: .before) }
        if after != .hold { try c.encode(after, forKey: .after) }
    }

    // MARK: Edits

    /// The key on `frame` (within half a hundredth of one), if there is one.
    package func index(at frame: Float) -> Int? { keys.firstIndex { abs($0.frame - frame) < 0.005 } }

    /// Puts key `k` in, replacing one on its frame.
    package mutating func insert(_ k: ProcKey) {
        if let i = index(at: k.frame) { keys[i] = k; return }
        keys.insert(k, at: keys.firstIndex { $0.frame > k.frame } ?? keys.count)
    }

    /// A key of `value` on `frame`: the key there given the value (its interpolation and slopes kept), else a new one
    /// with the interpolation of the key before it.
    package mutating func set(_ frame: Float, _ value: Float) {
        if let i = index(at: frame) { keys[i].value = value; return }
        let previous = keys.last { $0.frame < frame }
        insert(ProcKey(frame: frame, value: value, interpolation: previous?.interpolation ?? .spline))
    }

    package mutating func remove(at frame: Float) {
        if let i = index(at: frame) { keys.remove(at: i) }
    }

    /// Key `i` changed (its frame moved): sorted again. A key moved onto another's frame replaces it.
    package mutating func update(_ i: Int, _ body: (inout ProcKey) -> Void) {
        var k = keys.remove(at: i)
        body(&k)
        insert(k)
    }

    // MARK: Values

    /// The channel's value at `frame`.
    package func value(at frame: Float) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if keys.count == 1 { return first.value }
        let span = last.frame - first.frame
        if frame < first.frame {
            switch before {
            case .hold: return first.value
            case .linear: return first.value + (frame - first.frame) * slopes(0).x
            case .cycle, .cycleOffset:
                let n = ((first.frame - frame) / span).rounded(.up)
                return value(at: frame + n * span) - (before == .cycleOffset ? n * (last.value - first.value) : 0)
            }
        }
        if frame > last.frame {
            switch after {
            case .hold: return last.value
            case .linear: return last.value + (frame - last.frame) * slopes(keys.count - 1).y
            case .cycle, .cycleOffset:
                let n = ((frame - last.frame) / span).rounded(.up)
                return value(at: frame - n * span) + (after == .cycleOffset ? n * (last.value - first.value) : 0)
            }
        }
        // The segment `frame` is in.
        var i = 0
        while i + 2 < keys.count, keys[i + 1].frame <= frame { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let h = b.frame - a.frame
        guard h > 0 else { return b.value }
        let s = (frame - a.frame) / h
        switch a.interpolation {
        case .constant: return s < 1 ? a.value : b.value
        case .linear: return a.value + (b.value - a.value) * s
        case .ease: return a.value + (b.value - a.value) * s * s * (3 - 2 * s)
        case .easeIn: return a.value + (b.value - a.value) * s * s
        case .easeOut: return a.value + (b.value - a.value) * (1 - (1 - s) * (1 - s))
        case .spline:
            let m0 = slopes(i).y, m1 = slopes(i + 1).x
            let s2 = s * s, s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * a.value + (s3 - 2 * s2 + s) * h * m0 + (-2 * s3 + 3 * s2) * b.value + (s3 - s2) * h * m1
        }
    }

    /// Key `i`'s slopes in effect (in, out; value per frame): its own, else automatic ones. Automatic: Catmull-Rom's,
    /// flat at a peak or a dip and limited so the curve doesn't overshoot its keys; at an end, flat when the curve holds
    /// past it, else the end segment's slope.
    package func slopes(_ i: Int) -> SIMD2<Float> {
        if let s = keys[i].slopes { return s }
        guard keys.count > 1 else { return .zero }
        func d(_ j: Int) -> Float {
            let h = keys[j + 1].frame - keys[j].frame
            return h > 0 ? (keys[j + 1].value - keys[j].value) / h : 0
        }
        if i == 0 { return SIMD2(repeating: before == .hold ? 0 : d(0)) }
        if i == keys.count - 1 { return SIMD2(repeating: after == .hold ? 0 : d(i - 1)) }
        let d0 = d(i - 1), d1 = d(i)
        guard d0 * d1 > 0 else { return .zero }
        let m = (keys[i + 1].value - keys[i - 1].value) / (keys[i + 1].frame - keys[i - 1].frame)
        let limit = 3 * min(abs(d0), abs(d1))
        return SIMD2(repeating: max(-limit, min(limit, m)))
    }

    /// Adds the whole curve to a cook key (`chf()` reads it at any frame).
    package func hash(into h: inout Hasher64) {
        h.add(keys.count)
        for k in keys {
            h.add(SIMD4(k.frame, k.value, k.slopes?.x ?? .nan, k.slopes?.y ?? .nan))
            h.add(k.interpolation.rawValue)
        }
        h.add(before.rawValue)
        h.add(after.rawValue)
    }

    /// The frames the keys span (nil: no keys).
    package var span: ClosedRange<Float>? { keys.first.map { $0.frame...keys[keys.count - 1].frame } }

    /// Does the channel's value change from frame to frame?
    package var animates: Bool { keys.contains { $0.value != keys[0].value } }
}
