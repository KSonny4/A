import Foundation

/// A candidate string pre-processed for fast repeated matching.
public struct FuzzyTarget: Sendable {
    public let original: String
    let chars: [UInt32]
    let wordStarts: [Bool]

    public init(_ string: String) {
        original = string
        let folded = FuzzyMatcher.fold(string)
        chars = folded.unicodeScalars.map(\.value)

        var starts = [Bool](repeating: false, count: chars.count)
        let originalScalars = Array(string.unicodeScalars)
        let caseInfoUsable = originalScalars.count == chars.count
        for i in chars.indices {
            if i == 0 {
                starts[i] = true
                continue
            }
            let prev = chars[i - 1]
            let cur = chars[i]
            if !FuzzyMatcher.isAlnum(prev) && FuzzyMatcher.isAlnum(cur) {
                starts[i] = true
            } else if FuzzyMatcher.isDigit(cur) && !FuzzyMatcher.isDigit(prev) {
                starts[i] = true
            } else if caseInfoUsable {
                let p = originalScalars[i - 1].properties
                let c = originalScalars[i].properties
                if p.isLowercase && c.isUppercase { starts[i] = true }
            }
        }
        wordStarts = starts
    }
}

/// A user query pre-processed for matching.
public struct FuzzyQuery: Sendable {
    public let raw: String
    let chars: [UInt32]
    let compact: [UInt32]
    let tokens: [[UInt32]]

    public init(_ string: String) {
        raw = string
        let folded = FuzzyMatcher.fold(string.trimmingCharacters(in: .whitespacesAndNewlines))
        chars = folded.unicodeScalars.map(\.value)
        compact = chars.filter { $0 != 32 }
        tokens = folded.split(separator: " ").map { $0.unicodeScalars.map(\.value) }
    }

    public var isEmpty: Bool { chars.isEmpty }
}

/// Raycast-style ranking: exact > prefix > word prefixes > acronym > substring > subsequence.
public enum FuzzyMatcher {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    static func isAlnum(_ v: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(v) else { return false }
        return scalar.properties.isAlphabetic || isDigit(v)
    }

    static func isDigit(_ v: UInt32) -> Bool { v >= 48 && v <= 57 }

    public static func score(_ query: String, _ candidate: String) -> Double? {
        score(FuzzyQuery(query), FuzzyTarget(candidate))
    }

    /// Returns nil when the candidate does not match at all. Higher is better.
    public static func score(_ q: FuzzyQuery, _ t: FuzzyTarget) -> Double? {
        if q.isEmpty { return 0 }
        let c = t.chars
        let qc = q.chars
        guard !c.isEmpty else { return nil }
        let lengthPenalty = min(Double(c.count) * 0.3, 30)

        if c == qc { return 1000 }
        if hasPrefix(c, qc, at: 0) { return 900 - lengthPenalty }

        if tokensMatchWordPrefixes(q.tokens, t) {
            return 800 - lengthPenalty
        }

        if q.compact.count >= 2 {
            let acronym = zip(c, t.wordStarts).compactMap { $1 && isAlnum($0) ? $0 : nil }
            if hasPrefix(acronym, q.compact, at: 0) {
                return 760 - lengthPenalty
            }
        }

        if let pos = indexOf(qc, in: c) {
            let atWordStart = t.wordStarts[pos]
            return (atWordStart ? 720 : 620) - min(Double(pos), 50) - lengthPenalty
        }

        return subsequenceScore(q.compact, t).map { $0 - lengthPenalty }
    }

    private static func hasPrefix(_ c: [UInt32], _ p: [UInt32], at start: Int) -> Bool {
        guard start + p.count <= c.count else { return false }
        for i in 0..<p.count where c[start + i] != p[i] { return false }
        return true
    }

    private static func indexOf(_ needle: [UInt32], in hay: [UInt32]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first && hasPrefix(hay, needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func tokensMatchWordPrefixes(_ tokens: [[UInt32]], _ t: FuzzyTarget) -> Bool {
        guard !tokens.isEmpty else { return false }
        var searchFrom = 0
        for token in tokens {
            var found = false
            var i = searchFrom
            while i < t.chars.count {
                if t.wordStarts[i] && hasPrefix(t.chars, token, at: i) {
                    found = true
                    searchFrom = i + token.count
                    break
                }
                i += 1
            }
            if !found { return false }
        }
        return true
    }

    private static func subsequenceScore(_ q: [UInt32], _ t: FuzzyTarget) -> Double? {
        guard !q.isEmpty else { return nil }
        let c = t.chars
        var qi = 0
        var score = 300.0
        var lastMatch = -2
        var firstMatch = -1
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            if firstMatch < 0 { firstMatch = i }
            if t.wordStarts[i] { score += 12 }
            if i == lastMatch + 1 { score += 6 } else if lastMatch >= 0 { score -= min(Double(i - lastMatch), 10) * 0.8 }
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if firstMatch > 0 && !t.wordStarts[firstMatch] { score -= 25 }
        return max(score, 1)
    }
}
