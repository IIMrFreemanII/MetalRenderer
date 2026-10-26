import Foundation
import simd

/// A node family: the Tab menu's sections, and the colour the network view tints its nodes with.
package enum ProcFamily: String, CaseIterable {
    case generate, transform, polygon, attribute, group, scatter, curve, flow

    package var title: String {
        switch self {
        case .generate: "Generate"
        case .transform: "Transform & Combine"
        case .polygon: "Polygon"
        case .attribute: "Attribute"
        case .group: "Group"
        case .scatter: "Scatter & Copy"
        case .curve: "Curve"
        case .flow: "Utility"
        }
    }

    /// The node body's tint (Houdini's shades: neutral greys tinted per family).
    package var color: SIMD3<Float> {
        switch self {
        case .generate: [0.58, 0.64, 0.72]
        case .transform: [0.62, 0.62, 0.62]
        case .polygon: [0.55, 0.68, 0.58]
        case .attribute: [0.73, 0.66, 0.52]
        case .group: [0.70, 0.58, 0.66]
        case .scatter: [0.52, 0.66, 0.70]
        case .curve: [0.66, 0.70, 0.52]
        case .flow: [0.50, 0.50, 0.52]
        }
    }
}

/// One parameter of a node kind: its name (the key in `ProcNode.params`), title, default, how the parameter pane
/// edits it, the folder (tab) it is in, and when it shows.
package struct ProcParamSpec {
    package enum UI: Equatable {
        /// A slider over a span (a typed value may leave it).
        case number(ClosedRange<Float>)
        case integer(ClosedRange<Int>)
        case toggle
        /// A row of 2, 3 or 4 fields (the value's kind says how many).
        case vector
        case color
        /// One of a list of names (the value is the name).
        case menu([String])
        case text
        /// A group field: a pattern over the class named (nil: the one the node's `grouptype` / `class` says).
        case group(AttributeClass?)
        /// An attribute name of a class (nil: as for a group).
        case attribute(AttributeClass?)
        /// Swift code (a wrangle's).
        case code
        /// An asset or object the node reads (`mesh:<slug>`, `object:<name>`).
        case file
        /// A list of points.
        case points
        case ramp
    }

    /// Shown only while parameter `param` has one of `values` (its string form).
    package struct Condition {
        package var param: String
        package var values: [String]
    }

    package var name: String
    package var title: String
    package var value: ProcParam
    package var ui: UI
    package var folder = ""
    package var help = ""
    package var shown: Condition?

    package init(_ name: String, _ title: String, _ value: ProcParam, _ ui: UI, folder: String = "", help: String = "",
                 when shown: Condition? = nil) {
        self.name = name
        self.title = title
        self.value = value
        self.ui = ui
        self.folder = folder
        self.help = help
        self.shown = shown
    }

    // Short makers for the spec table.
    static func float(_ n: String, _ t: String, _ v: Float, _ span: ClosedRange<Float> = 0...1, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .float(v), .number(span), folder: folder, when: when)
    }
    static func int(_ n: String, _ t: String, _ v: Int, _ span: ClosedRange<Int> = 0...10, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .int(v), .integer(span), folder: folder, when: when)
    }
    static func bool(_ n: String, _ t: String, _ v: Bool, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .bool(v), .toggle, folder: folder, when: when)
    }
    static func vec2(_ n: String, _ t: String, _ v: SIMD2<Float>, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .vec2(v), .vector, folder: folder, when: when)
    }
    static func vec3(_ n: String, _ t: String, _ v: SIMD3<Float>, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .vec3(v), .vector, folder: folder, when: when)
    }
    static func vec4(_ n: String, _ t: String, _ v: SIMD4<Float>, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .vec4(v), .vector, folder: folder, when: when)
    }
    static func color(_ n: String, _ t: String, _ v: SIMD3<Float>, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .vec3(v), .color, folder: folder, when: when)
    }
    static func menu(_ n: String, _ t: String, _ items: [String], _ v: String? = nil, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .string(v ?? items[0]), .menu(items), folder: folder, when: when)
    }
    static func text(_ n: String, _ t: String, _ v: String = "", folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .string(v), .text, folder: folder, when: when)
    }
    static func group(_ n: String = "group", _ t: String = "Group", _ c: AttributeClass? = nil, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .string(""), .group(c), folder: folder, when: when)
    }
    static func attribute(_ n: String, _ t: String, _ v: String, _ c: AttributeClass? = nil, folder: String = "", when: Condition? = nil) -> Self {
        Self(n, t, .string(v), .attribute(c), folder: folder, when: when)
    }
    static func classes(_ n: String = "class", _ t: String = "Class", _ v: AttributeClass = .point,
                        _ allowed: [AttributeClass] = AttributeClass.allCases) -> Self {
        Self(n, t, .string(v.rawValue), .menu(allowed.map(\.rawValue)))
    }
}

/// What a node kind is: its title and family, the name new nodes get (`box` → `box1`), its icon (an SF Symbol), its
/// inputs (their labels; a multi-input node takes any number on its one), its parameters and a line on what it does.
package struct ProcNodeSpec {
    package var title: String
    package var family: ProcFamily
    package var baseName: String
    package var symbol: String
    package var inputs: [String]
    package var multiInput = false
    package var params: [ProcParamSpec]
    package var summary: String

    package init(_ title: String, _ family: ProcFamily, _ baseName: String, symbol: String, inputs: [String] = [],
                 multiInput: Bool = false, params: [ProcParamSpec] = [], _ summary: String) {
        self.title = title
        self.family = family
        self.baseName = baseName
        self.symbol = symbol
        self.inputs = inputs
        self.multiInput = multiInput
        self.params = params
        self.summary = summary
    }

    package func param(_ name: String) -> ProcParamSpec? { params.first { $0.name == name } }

    /// The folders the parameters are in, in order ("" for those in none, first).
    package var folders: [String] {
        var out: [String] = []
        for p in params where !out.contains(p.folder) { out.append(p.folder) }
        return out
    }
}
