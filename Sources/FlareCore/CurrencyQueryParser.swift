import Foundation

public struct CurrencyQuery: Equatable, Sendable {
    public var amount: Double
    public var from: String
    public var to: [String]
    /// True when the user typed a target currency ("100 usd to eur").
    public var hasExplicitTarget: Bool

    public init(amount: Double, from: String, to: [String], hasExplicitTarget: Bool) {
        self.amount = amount
        self.from = from
        self.to = to
        self.hasExplicitTarget = hasExplicitTarget
    }
}

/// Parses free-form conversion queries such as `100 usd to eur`, `€50 in czk`, `100eur`, `$20`, `1,5k gbp`.
public enum CurrencyQueryParser {
    static let connectors: Set<String> = ["to", "in", "into", "as", "=", ">", "->", "=>", "v", "na", "do"]

    static let aliases: [String: String] = [
        "$": "USD", "us$": "USD", "dollar": "USD", "dollars": "USD", "usd": "USD", "buck": "USD", "bucks": "USD",
        "€": "EUR", "euro": "EUR", "euros": "EUR", "eur": "EUR", "eura": "EUR", "eur.": "EUR",
        "£": "GBP", "pound": "GBP", "pounds": "GBP", "quid": "GBP",
        "¥": "JPY", "yen": "JPY", "円": "JPY",
        "元": "CNY", "yuan": "CNY", "rmb": "CNY",
        "₹": "INR", "rupee": "INR", "rupees": "INR",
        "₽": "RUB", "ruble": "RUB", "rubles": "RUB",
        "₩": "KRW", "won": "KRW",
        "₺": "TRY", "lira": "TRY",
        "₴": "UAH", "hryvnia": "UAH",
        "₪": "ILS", "shekel": "ILS",
        "฿": "THB", "baht": "THB",
        "₫": "VND", "dong": "VND",
        "₱": "PHP", "peso": "MXN", "pesos": "MXN",
        "r$": "BRL", "real": "BRL", "reais": "BRL",
        "c$": "CAD", "ca$": "CAD", "a$": "AUD", "au$": "AUD", "nz$": "NZD", "hk$": "HKD", "s$": "SGD",
        "kč": "CZK", "kc": "CZK", "korun": "CZK", "koruna": "CZK", "koruny": "CZK", "czk": "CZK",
        "zł": "PLN", "zl": "PLN", "zloty": "PLN", "złoty": "PLN",
        "ft": "HUF", "forint": "HUF",
        "fr": "CHF", "franc": "CHF", "francs": "CHF",
        "kr": "SEK",
        "lei": "RON", "leu": "RON",
    ]

    /// - Parameters:
    ///   - knownCodes: ISO codes we have rates for; nil accepts any 3-letter code.
    ///   - defaultTargets: used when the query has no explicit target.
    public static func parse(_ input: String, knownCodes: Set<String>? = nil, defaultTargets: [String]) -> CurrencyQuery? {
        var s = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for arrow in ["->", "=>", "→"] { s = s.replacingOccurrences(of: arrow, with: " to ") }

        // Split into: prefix (before first digit), number, rest.
        guard let firstDigit = s.firstIndex(where: { $0.isASCII && $0.isNumber }) else {
            return parseWithoutAmount(s, knownCodes: knownCodes)
        }
        let prefix = String(s[..<firstDigit]).trimmingCharacters(in: .whitespaces)
        var idx = firstDigit
        var numberText = ""
        while idx < s.endIndex {
            let ch = s[idx]
            if (ch.isASCII && ch.isNumber) || ch == "." || ch == "," || ch == "'" || ch == "\u{2019}" {
                numberText.append(ch)
            } else if ch == " " || ch == "\u{00A0}" || ch == "\u{202F}" {
                // Allow "1 000" style grouping only when followed by exactly three digits.
                let next = s.index(after: idx)
                let tail = s[next...].prefix(4)
                let digits = tail.prefix(while: { $0.isASCII && $0.isNumber })
                if digits.count == 3 && (tail.count == 3 || !(tail.last!.isASCII && tail.last!.isNumber)) {
                    idx = next
                    continue
                }
                break
            } else {
                break
            }
            idx = s.index(after: idx)
        }
        guard var amount = parseNumber(numberText) else { return nil }

        var rest = String(s[idx...])
        // Magnitude suffix: 10k, 2.5m
        if let first = rest.first, first == "k" || first == "m" {
            let after = rest.dropFirst()
            if after.isEmpty || after.first == " " {
                amount *= first == "k" ? 1_000 : 1_000_000
                rest = String(after)
            }
        }

        var tokens = rest.split(whereSeparator: { $0 == " " }).map(String.init)
        tokens.removeAll { connectors.contains($0) }

        var from: String?
        if !prefix.isEmpty {
            guard let code = resolve(prefix, knownCodes: knownCodes) else { return nil }
            from = code
        }
        if from == nil {
            guard !tokens.isEmpty, let code = resolve(tokens.removeFirst(), knownCodes: knownCodes) else { return nil }
            from = code
        }
        guard let fromCode = from else { return nil }

        var targets: [String] = []
        for token in tokens {
            guard let code = resolve(token, knownCodes: knownCodes) else { return nil }
            if !targets.contains(code) { targets.append(code) }
        }
        let explicit = !targets.isEmpty
        if !explicit {
            targets = unique(defaultTargets.map { $0.uppercased() }.filter { $0 != fromCode })
        }
        targets.removeAll { $0 == fromCode && !explicit }
        guard !targets.isEmpty else { return nil }
        return CurrencyQuery(amount: amount, from: fromCode, to: targets, hasExplicitTarget: explicit)
    }

    /// "usd to eur" → 1 USD → EUR
    private static func parseWithoutAmount(_ s: String, knownCodes: Set<String>?) -> CurrencyQuery? {
        var tokens = s.split(separator: " ").map(String.init)
        guard tokens.count >= 3, tokens.contains(where: { connectors.contains($0) }) else { return nil }
        tokens.removeAll { connectors.contains($0) }
        guard tokens.count == 2,
              let from = resolve(tokens[0], knownCodes: knownCodes),
              let to = resolve(tokens[1], knownCodes: knownCodes) else { return nil }
        return CurrencyQuery(amount: 1, from: from, to: [to], hasExplicitTarget: true)
    }

    public static func resolve(_ token: String, knownCodes: Set<String>?) -> String? {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:?!"))
        if let alias = aliases[t] {
            if let known = knownCodes, !known.contains(alias) { return nil }
            return alias
        }
        guard t.count == 3, t.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let code = t.uppercased()
        if let known = knownCodes { return known.contains(code) ? code : nil }
        return Locale.commonISOCurrencyCodes.contains(code) ? code : nil
    }

    /// Accepts "1,234.56", "1.234,56", "12,5", "1'000", "1000".
    public static func parseNumber(_ raw: String) -> Double? {
        var s = raw.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !s.isEmpty else { return nil }
        let dots = s.filter { $0 == "." }.count
        let commas = s.filter { $0 == "," }.count

        if dots > 0 && commas > 0 {
            let lastDot = s.lastIndex(of: ".")!
            let lastComma = s.lastIndex(of: ",")!
            if lastDot > lastComma {
                s = s.replacingOccurrences(of: ",", with: "")
            } else {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            }
        } else if commas > 0 {
            let afterLast = s[s.index(after: s.lastIndex(of: ",")!)...]
            if commas == 1 && afterLast.count != 3 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if dots > 1 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        return Double(s)
    }

    private static func unique(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }
}
