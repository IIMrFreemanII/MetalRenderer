import Foundation
import simd

/// An error with a message: a material graph's (a loop, a missing subgraph, a file of a newer format), a file's.
package struct MatError: Error, CustomStringConvertible {
    package let description: String
    package init(_ d: String) { description = d }
}
