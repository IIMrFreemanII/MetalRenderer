extension Array {
    /// The element at `i`, or nil past the ends.
    package subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
