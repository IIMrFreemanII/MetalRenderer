import Foundation

/// The shader source as the compiler gets it. `Shaders.metal` is the entry: it lists the pieces in `Shaders/` with
/// `#include "Shaders/X.metal"` lines, in the order they build on each other. The runtime compiler
/// (`makeLibrary(source:)`) has no include path, so the pieces are spliced in here, between `#line` markers that make
/// a compile error name the piece and the line in it. Read on every compile: R picks up a new piece without a rebuild.
enum ShaderSource {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The path in a line of the form `#include "path"` (a comment may follow); nil for anything else, `<...>` too.
    static func includePath(in line: Substring) -> String? {
        let text = line.drop { $0 == " " || $0 == "\t" }
        guard text.hasPrefix("#include") else { return nil }
        let rest = text.dropFirst("#include".count).drop { $0 == " " || $0 == "\t" }
        guard rest.first == "\"", let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(rest[rest.index(after: rest.startIndex)..<end])
    }

    /// The pieces `entry` includes, in order, as paths relative to its folder.
    static func pieces(of entry: URL) throws -> [String] {
        try String(contentsOf: entry, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap(includePath)
    }

    /// `entry` with every piece spliced in. Without `lineMarkers` the result is the plain text (for diffs and tests).
    static func load(_ entry: URL, lineMarkers: Bool = true) throws -> String {
        let folder = entry.deletingLastPathComponent(), name = entry.lastPathComponent
        var lines = try String(contentsOf: entry, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }   // the file's final newline
        var out = ""
        out.reserveCapacity(1 << 19)
        if lineMarkers { out += "#line 1 \"\(name)\"\n" }
        var seen = Set<String>()
        for (i, line) in lines.enumerated() {
            guard let path = includePath(in: line) else { out += line; out += "\n"; continue }
            let place = "\(name):\(i + 1)"
            guard seen.insert(path).inserted else { throw Failure(description: "\(place): \(path) is included twice") }
            guard let piece = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else {
                throw Failure(description: "\(place): \(path) not found")
            }
            try check(piece, path: path)
            if lineMarkers { out += "#line 1 \"\(path)\"\n" }
            out += piece
            if !piece.hasSuffix("\n") { out += "\n" }   // or the marker below would join the piece's last line
            if lineMarkers { out += "#line \(i + 2) \"\(name)\"\n" }   // #line numbers the line after it
        }
        return out
    }

    /// A piece stands on its own: no includes of its own (the entry lists them all, in order), and every `#if` it
    /// opens it closes, so no piece can switch another one off.
    private static func check(_ piece: String, path: String) throws {
        var depth = 0
        for (i, line) in piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = line.drop { $0 == " " || $0 == "\t" }
            guard text.first == "#" else { continue }
            if includePath(in: line) != nil {
                throw Failure(description: "\(path):\(i + 1): a piece cannot include another; list it in the entry file")
            }
            if text.hasPrefix("#if") { depth += 1 }
            if text.hasPrefix("#endif") {
                depth -= 1
                if depth < 0 { throw Failure(description: "\(path):\(i + 1): #endif without an #if in this piece") }
            }
        }
        if depth != 0 { throw Failure(description: "\(path): an #if is not closed in this piece") }
    }
}
