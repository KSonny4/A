import Foundation

/// Something the launcher can find: an app, a file/folder in Downloads, or a built-in command.
public struct SearchEntry: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case application, file, folder, command
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let path: String?
    public let date: Date?
    let targets: [FuzzyTarget]

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, path: String? = nil,
                date: Date? = nil, keywords: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.date = date
        var seen = Set<String>()
        targets = ([title] + keywords)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .map(FuzzyTarget.init)
    }
}

public struct ScoredEntry: Sendable {
    public let entry: SearchEntry
    public let score: Double
}

public enum SearchEngine {
    /// Ranks entries for `query`. Keywords (aliases) score slightly below the title.
    public static func rank(_ entries: [SearchEntry], query: String, usage: [String: UsageStat] = [:],
                            now: Date = Date(), limit: Int) -> [ScoredEntry] {
        let q = FuzzyQuery(query)
        guard !q.isEmpty else { return [] }
        var scored: [ScoredEntry] = []
        scored.reserveCapacity(64)
        for entry in entries {
            var best: Double?
            for (i, target) in entry.targets.enumerated() {
                guard let s = FuzzyMatcher.score(q, target) else { continue }
                let adjusted = i == 0 ? s : s - 15
                if best == nil || adjusted > best! { best = adjusted }
            }
            guard var score = best else { continue }
            // Long-path subsequence matches on files are noisy; require a decent match for files.
            if entry.kind == .file || entry.kind == .folder {
                if score < 400 && q.compact.count < 3 { continue }
                if let date = entry.date {
                    let age = now.timeIntervalSince(date)
                    if age < 24 * 60 * 60 { score += 15 } else if age < 7 * 24 * 60 * 60 { score += 8 }
                }
            }
            score += UsageStore.boost(usage[entry.id], now: now)
            scored.append(ScoredEntry(entry: entry, score: score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.title.localizedStandardCompare(b.entry.title) == .orderedAscending
        }
        return Array(scored.prefix(limit))
    }

    /// Most used entries for the empty-query "Suggestions" section.
    public static func suggestions(_ entries: [SearchEntry], usage: [String: UsageStat], now: Date = Date(), limit: Int) -> [SearchEntry] {
        guard !usage.isEmpty else { return [] }
        var seen = Set<String>()
        return entries
            .compactMap { entry -> (SearchEntry, Double)? in
                guard let stat = usage[entry.id], seen.insert(entry.id).inserted else { return nil }
                return (entry, UsageStore.boost(stat, now: now))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}
