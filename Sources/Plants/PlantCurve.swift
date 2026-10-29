import EngineCore
import Foundation
import simd

extension Foliage {
    /// A value along something, x from 0 (its start) to 1 (its end): a shoot's priority ramps by how far up toward
    /// its target height a bud is, a leaf's size along its stem. A line or a taper is a preset; dragging one in the
    /// editor turns it into points (`editable`).
    package enum Curve: Equatable {
        case linear(Float, Float)       // a + (b - a) x
        case taper(Float)               // 1 - t x
        case points([SIMD2<Float>])     // through these (x ascending, from 0 to 1), monotone between them

        /// At x (0...1).
        package func value(_ x: Float) -> Float {
            switch self {
            case .linear(let a, let b): return a + (b - a) * x
            case .taper(let t): return 1 - t * x
            case .points(let p): return Curve.interpolate(p, x)
            }
        }

        /// At the start: `a` itself for a line.
        package var start: Float {
            switch self {
            case .linear(let a, _): return a
            default: return value(0)
            }
        }

        /// At the end: `b` itself for a line (what a stem's tip leaf is scaled by).
        package var end: Float {
            switch self {
            case .linear(_, let b): return b
            case .points(let p): return p.last?.y ?? 0
            default: return value(1)
            }
        }

        package var isPoints: Bool { if case .points = self { return true }; return false }

        /// The same curve as points, to drag (a line or a taper: its two ends).
        package func editable() -> Curve {
            switch self {
            case .points: return self
            case .linear, .taper: return .points([SIMD2(0, value(0)), SIMD2(1, value(1))])
            }
        }

        /// Monotone cubic Hermite (Fritsch-Carlson) through the points: no overshoot past them. Flat beyond the ends.
        package static func interpolate(_ p: [SIMD2<Float>], _ x: Float) -> Float {
            guard let first = p.first else { return 0 }
            guard p.count > 1 else { return first.y }
            if x <= first.x { return first.y }
            if x >= p[p.count - 1].x { return p[p.count - 1].y }
            var k = 0
            while k < p.count - 2 && x > p[k + 1].x { k += 1 }
            func slope(_ i: Int) -> Float {
                let h = p[i + 1].x - p[i].x
                return h > 1e-6 ? (p[i + 1].y - p[i].y) / h : 0
            }
            func tangent(_ i: Int) -> Float {
                if i == 0 { return slope(0) }
                if i == p.count - 1 { return slope(p.count - 2) }
                let a = slope(i - 1), b = slope(i)
                guard a * b > 0 else { return 0 }   // a peak or a valley: flat there
                return 2 * a * b / (a + b)           // the harmonic mean keeps it monotone
            }
            let h = p[k + 1].x - p[k].x
            guard h > 1e-6 else { return p[k + 1].y }
            let t = (x - p[k].x) / h, t2 = t * t, t3 = t2 * t
            let m0 = tangent(k) * h, m1 = tangent(k + 1) * h
            return (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * m1
        }
    }
}

/// As JSON: `{"linear": [a, b]}`, `{"taper": t}` or `{"points": [[x, y], ...]}`.
extension Foliage.Curve: Codable {
    private enum Key: String, CodingKey { case linear, taper, points }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let ab = try c.decodeIfPresent([Float].self, forKey: .linear), ab.count == 2 {
            self = .linear(ab[0], ab[1])
        } else if let t = try c.decodeIfPresent(Float.self, forKey: .taper) {
            self = .taper(t)
        } else if let p = try c.decodeIfPresent([SIMD2<Float>].self, forKey: .points) {
            self = .points(p)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a curve"))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .linear(let a, let b): try c.encode([a, b], forKey: .linear)
        case .taper(let t): try c.encode(t, forKey: .taper)
        case .points(let p): try c.encode(p, forKey: .points)
        }
    }
}
