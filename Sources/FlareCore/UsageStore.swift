import Foundation

public struct UsageStat: Codable, Equatable, Sendable {
    public var count: Int
    public var lastUsed: Date

    public init(count: Int, lastUsed: Date) {
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// Remembers how often items are opened so frequently used ones rank higher ("frecency").
public final class UsageStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var stats: [String: UsageStat] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: UsageStat].self, from: data) {
            stats = decoded
        }
    }

    public func snapshot() -> [String: UsageStat] {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func record(_ id: String, date: Date = Date()) {
        lock.lock()
        var stat = stats[id] ?? UsageStat(count: 0, lastUsed: date)
        stat.count += 1
        stat.lastUsed = date
        stats[id] = stat
        let copy = stats
        lock.unlock()
        let url = self.url
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(copy) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func boost(_ stat: UsageStat?, now: Date = Date()) -> Double {
        guard let stat else { return 0 }
        var boost = min(log2(Double(stat.count) + 1) * 30, 150)
        let age = now.timeIntervalSince(stat.lastUsed)
        if age < 60 * 60 { boost += 30 } else if age < 24 * 60 * 60 { boost += 20 } else if age < 7 * 24 * 60 * 60 { boost += 10 }
        return boost
    }
}
