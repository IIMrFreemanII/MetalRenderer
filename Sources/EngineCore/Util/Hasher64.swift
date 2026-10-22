import Foundation
import simd

/// FNV-1a over what is added: a plan step's hash, and a seed that is the same on every launch (Swift's `Hasher` is
/// seeded per process).
package struct Hasher64 {
    package private(set) var value: UInt64 = 14_695_981_039_346_656_037
    package mutating func add(_ bytes: UnsafeRawBufferPointer) { for b in bytes { value = (value ^ UInt64(b)) &* 1_099_511_628_211 } }
    package mutating func add(_ v: UInt64) { withUnsafeBytes(of: v) { add($0) } }
    package mutating func add(_ v: Int) { add(UInt64(bitPattern: Int64(v))) }
    package mutating func add(_ v: Float) { add(UInt64(v.bitPattern)) }
    package mutating func add(_ v: Bool) { add(UInt64(v ? 1 : 0)) }
    package mutating func add(_ v: SIMD4<Float>) { withUnsafeBytes(of: v) { add($0) } }
    package mutating func add(_ s: String) {
        add(UInt64(s.utf8.count))
        for b in s.utf8 { value = (value ^ UInt64(b)) &* 1_099_511_628_211 }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(value: UInt64 = 14_695_981_039_346_656_037) {
        self.value = value
    }
}
