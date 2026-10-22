import Foundation

/// One number of a definition (a plant's, a building's, a character's), described once: its title, range, step and
/// how it is shown, and how far a mutation may move it. The editors' rows, Mutate (PlantMutate.swift) and the tests are
/// all built from these tables, in the spirit of SettingsTable.
package struct PlantParam<Root> {
    package let title: String
    package let range: ClosedRange<Double>
    package let step: Double                    // 1: a whole number
    package let digits: Int                     // shown with this many decimals
    package let unit: String
    /// The most a mutation moves it, as a share of its range (0: never).
    package let mutation: Double
    package let get: (Root) -> Double
    package let set: (inout Root, Double) -> Void

    package var isInteger: Bool { step == 1 && digits == 0 }

    package func text(_ v: Double) -> String { String(format: "%.\(digits)f", v) + (unit.isEmpty ? "" : " \(unit)") }

    /// `v` stepped and clamped into the range.
    package func clamp(_ v: Double) -> Double {
        let stepped = step > 0 ? (v / step).rounded() * step : v
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    package static func float(_ title: String, _ path: WritableKeyPath<Root, Float>, _ range: ClosedRange<Double>, step: Double = 0,
                      digits: Int = 2, unit: String = "", mutation: Double = 0.12) -> PlantParam {
        PlantParam(title: title, range: range, step: step, digits: digits, unit: unit, mutation: mutation,
                   get: { Double($0[keyPath: path]) }, set: { $0[keyPath: path] = Float($1) })
    }

    package static func int(_ title: String, _ path: WritableKeyPath<Root, Int>, _ range: ClosedRange<Int>, mutation: Double = 0.12) -> PlantParam {
        PlantParam(title: title, range: Double(range.lowerBound)...Double(range.upperBound), step: 1, digits: 0, unit: "",
                   mutation: mutation, get: { Double($0[keyPath: path]) }, set: { $0[keyPath: path] = Int($1.rounded()) })
    }

    package static func double(_ title: String, _ path: WritableKeyPath<Root, Double>, _ range: ClosedRange<Double>, digits: Int = 1,
                       unit: String = "", mutation: Double = 0) -> PlantParam {
        PlantParam(title: title, range: range, step: 0, digits: digits, unit: unit, mutation: mutation,
                   get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 })
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(title: String, range: ClosedRange<Double>, step: Double, digits: Int, unit: String, mutation: Double, get: @escaping (Root) -> Double, set: @escaping (inout Root, Double) -> Void) {
        self.title = title
        self.range = range
        self.step = step
        self.digits = digits
        self.unit = unit
        self.mutation = mutation
        self.get = get
        self.set = set
    }
}
