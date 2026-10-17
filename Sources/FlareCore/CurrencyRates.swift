import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exchange rates relative to a base currency.
public struct RateTable: Codable, Equatable, Sendable {
    public var base: String
    public var rates: [String: Double]
    public var fetchedAt: Date
    public var providerUpdatedAt: Date?

    public init(base: String, rates: [String: Double], fetchedAt: Date, providerUpdatedAt: Date? = nil) {
        self.base = base
        self.rates = rates
        self.fetchedAt = fetchedAt
        self.providerUpdatedAt = providerUpdatedAt
    }

    public var codes: Set<String> { Set(rates.keys).union([base]) }

    public func rate(_ code: String) -> Double? {
        code == base ? 1 : rates[code]
    }

    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let f = rate(from), let t = rate(to), f > 0 else { return nil }
        return amount / f * t
    }
}

public struct CurrencyConversion: Equatable, Sendable, Identifiable {
    public var id: String { "\(from)-\(to)" }
    public var amount: Double
    public var from: String
    public var result: Double
    public var to: String
}

public enum CurrencyFormat {
    public static func amount(_ value: Double, code: String? = nil) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        let magnitude = abs(value)
        if magnitude >= 1 || magnitude == 0 {
            f.minimumFractionDigits = magnitude.rounded() == magnitude ? 0 : 2
            f.maximumFractionDigits = 2
        } else {
            f.minimumFractionDigits = 2
            f.maximumSignificantDigits = 4
            f.usesSignificantDigits = true
        }
        let s = f.string(from: NSNumber(value: value)) ?? String(value)
        return code.map { "\(s) \($0)" } ?? s
    }

    /// Plain machine-friendly number for copying ("1234.56").
    public static func plain(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = abs(value) >= 1 ? 2 : 6
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func name(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }
}

/// Fetches rates from open.er-api.com (free, no key, ~160 currencies), caching them on disk.
public final class CurrencyService: @unchecked Sendable {
    public static let endpoint = URL(string: "https://open.er-api.com/v6/latest/USD")!
    public static let maxAge: TimeInterval = 12 * 60 * 60

    private let cacheURL: URL
    private let lock = NSLock()
    private var _table: RateTable?
    private var inFlight = false
    private let session: URLSession

    public init(cacheURL: URL, session: URLSession = .shared) {
        self.cacheURL = cacheURL
        self.session = session
        if let data = try? Data(contentsOf: cacheURL),
           let table = try? Self.decoder.decode(RateTable.self, from: data) {
            _table = table
        }
    }

    public var table: RateTable? {
        lock.lock(); defer { lock.unlock() }
        return _table
    }

    public var needsRefresh: Bool {
        guard let t = table else { return true }
        return Date().timeIntervalSince(t.fetchedAt) > Self.maxAge
    }

    public func convert(_ query: CurrencyQuery) -> [CurrencyConversion] {
        guard let table else { return [] }
        return query.to.compactMap { target in
            table.convert(query.amount, from: query.from, to: target).map {
                CurrencyConversion(amount: query.amount, from: query.from, result: $0, to: target)
            }
        }
    }

    public func refreshIfNeeded(force: Bool = false, completion: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        let stale = _table.map { Date().timeIntervalSince($0.fetchedAt) > Self.maxAge } ?? true
        guard (force || stale), !inFlight else {
            lock.unlock()
            completion?(false)
            return
        }
        inFlight = true
        lock.unlock()

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var updated = false
            if let data, let table = Self.parseResponse(data) {
                self.lock.lock()
                self._table = table
                self.lock.unlock()
                if let encoded = try? Self.encoder.encode(table) {
                    try? FileManager.default.createDirectory(at: self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? encoded.write(to: self.cacheURL, options: .atomic)
                }
                updated = true
            }
            self.lock.lock()
            self.inFlight = false
            self.lock.unlock()
            completion?(updated)
        }.resume()
    }

    /// Parses an open.er-api.com style payload.
    public static func parseResponse(_ data: Data, now: Date = Date()) -> RateTable? {
        struct Response: Decodable {
            let result: String?
            let base_code: String
            let time_last_update_unix: Double?
            let rates: [String: Double]
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              r.result == nil || r.result == "success",
              !r.rates.isEmpty else { return nil }
        return RateTable(
            base: r.base_code,
            rates: r.rates,
            fetchedAt: now,
            providerUpdatedAt: r.time_last_update_unix.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}
