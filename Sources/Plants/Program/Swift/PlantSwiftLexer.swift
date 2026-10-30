import Foundation

/// A plant file's Swift as tokens: what PlantSwiftParser needs of it. Strings of every form and nested comments are one
/// token each; each token knows where it is, so that whatever isn't understood can be kept as it is written.
struct PlantToken: Equatable {
    enum Kind: Equatable {
        case identifier             // also `$0`
        case number
        case string
        case punctuation            // one character, or `...`, `?.`, `->`
        case comment                // `//` to the end of the line, or `/* */`
        case newline
    }

    let kind: Kind
    let text: String
    let start: Int                  // into the source's UTF-8
    let end: Int
}

enum PlantSwiftLexer {
    static func tokens(_ source: String) -> [PlantToken] {
        let s = Array(source.utf8)
        var out: [PlantToken] = []
        var i = 0
        func text(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF8.self) }
        func at(_ j: Int) -> UInt8 { j < s.count ? s[j] : 0 }
        func isIdentStart(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 128 }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func ch(_ c: Character) -> UInt8 { c.asciiValue! }

        /// Past a string that starts at `j` (its opening quotes, `#`s before them if raw).
        func skipString(_ start: Int) -> Int {
            var j = start, hashes = 0
            while at(j) == ch("#") { hashes += 1; j += 1 }
            let triple = at(j) == ch("\"") && at(j + 1) == ch("\"") && at(j + 2) == ch("\"")
            j += triple ? 3 : 1
            func closes(_ k: Int) -> Bool {
                guard at(k) == ch("\"") else { return false }
                if triple && !(at(k + 1) == ch("\"") && at(k + 2) == ch("\"")) { return false }
                let after = k + (triple ? 3 : 1)
                for h in 0..<hashes where at(after + h) != ch("#") { return false }
                return true
            }
            while j < s.count {
                if !triple && s[j] == 10 { return j }          // (unterminated: to the line's end)
                if s[j] == ch("\\") {
                    var k = j + 1, h = 0
                    while h < hashes && at(k) == ch("#") { h += 1; k += 1 }
                    if h == hashes {
                        if at(k) == ch("(") {
                            // An interpolation: balanced, with whatever strings are inside.
                            var depth = 1
                            k += 1
                            while k < s.count && depth > 0 {
                                if at(k) == ch("\"") || (at(k) == ch("#") && at(k + 1) == ch("\"")) { k = skipString(k); continue }
                                if at(k) == ch("(") { depth += 1 } else if at(k) == ch(")") { depth -= 1 }
                                k += 1
                            }
                            j = k
                        } else {
                            j = k + 1
                        }
                        continue
                    }
                }
                if closes(j) { return j + (triple ? 3 : 1) + hashes }
                j += 1
            }
            return j
        }

        while i < s.count {
            let c = s[i]
            let start = i
            if c == 10 {
                i += 1
                out.append(PlantToken(kind: .newline, text: "\n", start: start, end: i))
            } else if c == 32 || c == 9 || c == 13 {
                i += 1
            } else if c == ch("/") && at(i + 1) == ch("/") {
                while i < s.count && s[i] != 10 { i += 1 }
                var end = i
                while end > start && (s[end - 1] == 32 || s[end - 1] == 9 || s[end - 1] == 13) { end -= 1 }
                out.append(PlantToken(kind: .comment, text: text(start, end), start: start, end: end))
            } else if c == ch("/") && at(i + 1) == ch("*") {
                var depth = 1
                i += 2
                while i < s.count && depth > 0 {
                    if s[i] == ch("/") && at(i + 1) == ch("*") { depth += 1; i += 2 }
                    else if s[i] == ch("*") && at(i + 1) == ch("/") { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                out.append(PlantToken(kind: .comment, text: text(start, i), start: start, end: i))
            } else if c == ch("\"") || (c == ch("#") && (at(i + 1) == ch("\"") || at(i + 1) == ch("#"))) {
                i = skipString(i)
                out.append(PlantToken(kind: .string, text: text(start, i), start: start, end: i))
            } else if isDigit(c) || (c == ch(".") && isDigit(at(i + 1)) && (out.last?.kind != .identifier)) {
                i += 1
                while i < s.count {
                    let d = s[i]
                    if isDigit(d) || isIdentStart(d) && d != 36 {
                        // (`e` and a sign in an exponent, hex digits, `_`.)
                        let exponent = (d == ch("e") || d == ch("E")) && !text(start, i).hasPrefix("0x")
                        i += 1
                        if exponent && (at(i) == ch("-") || at(i) == ch("+")) { i += 1 }
                    } else if d == ch(".") && isDigit(at(i + 1)) {
                        i += 1
                    } else {
                        break
                    }
                }
                out.append(PlantToken(kind: .number, text: text(start, i), start: start, end: i))
            } else if isIdentStart(c) {
                i += 1
                while i < s.count && (isIdentStart(s[i]) || isDigit(s[i])) { i += 1 }
                out.append(PlantToken(kind: .identifier, text: text(start, i), start: start, end: i))
            } else {
                var n = 1
                if c == ch(".") && at(i + 1) == ch(".") && at(i + 2) == ch(".") { n = 3 }
                else if c == ch("?") && at(i + 1) == ch(".") && !isDigit(at(i + 2)) { n = 2 }
                else if c == ch("-") && at(i + 1) == ch(">") { n = 2 }
                else if c >= 128 { n = 1 }
                i += n
                out.append(PlantToken(kind: .punctuation, text: text(start, i), start: start, end: i))
            }
        }
        return out
    }
}
