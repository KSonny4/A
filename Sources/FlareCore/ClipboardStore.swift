import Foundation
import CryptoKit

/// Unlimited clipboard history: no count limit, no size limit, no expiry.
///
/// Layout inside `directory`:
/// - `clipboard.sqlite` — items, representations, full-text search index
/// - `blobs/<sha256>` — representations larger than `inlineLimit`, content-addressed
public final class ClipboardStore: @unchecked Sendable {
    public static let inlineLimit = 256 * 1024

    public let directory: URL
    public let blobDirectory: URL
    private let db: SQLiteDB
    private let lock = NSRecursiveLock()
    public private(set) var usesFullTextIndex = false

    public init(directory: URL) throws {
        self.directory = directory
        blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        db = try SQLiteDB(path: directory.appendingPathComponent("clipboard.sqlite").path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        try db.exec("""
            CREATE TABLE IF NOT EXISTS items(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hash TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                preview TEXT NOT NULL,
                char_count INTEGER NOT NULL,
                byte_size INTEGER NOT NULL,
                source_bundle TEXT,
                source_name TEXT,
                meta TEXT,
                created_at REAL NOT NULL,
                last_copied_at REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1,
                pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_items_order ON items(pinned DESC, last_copied_at DESC);
            CREATE TABLE IF NOT EXISTS reps(
                item_id INTEGER NOT NULL,
                item_index INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                type TEXT NOT NULL,
                data BLOB,
                blob_file TEXT,
                size INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_reps_item ON reps(item_id);
            CREATE INDEX IF NOT EXISTS idx_reps_blob ON reps(blob_file);
            """)
        do {
            try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS clips_search USING fts5(search_text, tokenize='trigram')")
            usesFullTextIndex = true
        } catch {
            // SQLite without FTS5/trigram: fall back to a plain table scanned with LIKE.
            try db.exec("CREATE TABLE IF NOT EXISTS clips_search(rowid INTEGER PRIMARY KEY, search_text TEXT)")
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Writing

    public struct InsertResult: Equatable, Sendable {
        public var id: Int64
        public var isNew: Bool
    }

    @discardableResult
    public func insert(payload: ClipPayload, analysis: ClipAnalysis, sourceBundleID: String?, sourceAppName: String?,
                       date: Date = Date()) throws -> InsertResult {
        let hash = Self.sha256Hex(analysis.dedupeKey)
        return try locked {
            try db.transaction {
                let existingID: Int64? = try {
                    let stmt = try db.prepare("SELECT id FROM items WHERE hash = ?", [.text(hash)])
                    return try stmt.step() ? stmt.int64(0) : nil
                }()
                if let id = existingID {
                    try db.run("""
                        UPDATE items SET last_copied_at = ?, copy_count = copy_count + 1,
                            source_bundle = COALESCE(?, source_bundle), source_name = COALESCE(?, source_name)
                        WHERE id = ?
                        """, [.double(date.timeIntervalSince1970), Self.textOrNull(sourceBundleID),
                              Self.textOrNull(sourceAppName), .int(id)])
                    return InsertResult(id: id, isNew: false)
                }

                let metaJSON = (try? JSONEncoder().encode(analysis.meta)).map { String(decoding: $0, as: UTF8.self) }
                try db.run("""
                    INSERT INTO items(hash, kind, preview, char_count, byte_size, source_bundle, source_name, meta,
                                      created_at, last_copied_at, copy_count, pinned)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0)
                    """, [.text(hash), .text(analysis.kind.rawValue), .text(analysis.preview), .int(Int64(analysis.charCount)),
                          .int(Int64(payload.byteSize)), Self.textOrNull(sourceBundleID), Self.textOrNull(sourceAppName),
                          Self.textOrNull(metaJSON), .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)])
                let id = db.lastInsertRowID

                for (itemIndex, reps) in payload.items.enumerated() {
                    for (ord, rep) in reps.enumerated() {
                        if rep.data.count > Self.inlineLimit {
                            let name = try writeBlob(rep.data)
                            try db.run("INSERT INTO reps(item_id, item_index, ord, type, data, blob_file, size) VALUES(?, ?, ?, ?, NULL, ?, ?)",
                                       [.int(id), .int(Int64(itemIndex)), .int(Int64(ord)), .text(rep.type), .text(name), .int(Int64(rep.data.count))])
                        } else {
                            try db.run("INSERT INTO reps(item_id, item_index, ord, type, data, blob_file, size) VALUES(?, ?, ?, ?, ?, NULL, ?)",
                                       [.int(id), .int(Int64(itemIndex)), .int(Int64(ord)), .text(rep.type), .blob(rep.data), .int(Int64(rep.data.count))])
                        }
                    }
                }
                try db.run("INSERT INTO clips_search(rowid, search_text) VALUES(?, ?)", [.int(id), .text(analysis.searchText)])
                return InsertResult(id: id, isNew: true)
            }
        }
    }

    /// Moves an item to the top (used when it is pasted from history).
    public func touch(id: Int64, date: Date = Date()) throws {
        try locked {
            try db.run("UPDATE items SET last_copied_at = ?, copy_count = copy_count + 1 WHERE id = ?",
                       [.double(date.timeIntervalSince1970), .int(id)])
        }
    }

    public func setPinned(_ pinned: Bool, id: Int64) throws {
        try locked {
            try db.run("UPDATE items SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(id)])
        }
    }

    public func delete(id: Int64) throws {
        try locked {
            let blobs: [String] = try db.transaction {
                let stmt = try db.prepare("SELECT blob_file FROM reps WHERE item_id = ? AND blob_file IS NOT NULL", [.int(id)])
                var names: [String] = []
                while try stmt.step() { if let n = stmt.text(0) { names.append(n) } }
                try db.run("DELETE FROM reps WHERE item_id = ?", [.int(id)])
                try db.run("DELETE FROM clips_search WHERE rowid = ?", [.int(id)])
                try db.run("DELETE FROM items WHERE id = ?", [.int(id)])
                return names
            }
            removeUnreferencedBlobs(blobs)
        }
    }

    /// Deletes all history. Pinned items survive unless `includingPinned` is true.
    public func deleteAll(includingPinned: Bool = false) throws {
        try locked {
            let stmt = try db.prepare(includingPinned ? "SELECT id FROM items" : "SELECT id FROM items WHERE pinned = 0")
            var ids: [Int64] = []
            while try stmt.step() { ids.append(stmt.int64(0)) }
            for id in ids { try delete(id: id) }
            try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Reading

    private static let recordColumns = """
        id, kind, preview, char_count, byte_size, source_bundle, source_name, meta, created_at, last_copied_at, copy_count, pinned
        """

    /// Newest first, pinned on top. `query` is a case-insensitive substring search; multiple words must all match.
    public func fetch(query: String = "", kind: ClipKind? = nil, limit: Int = 100, offset: Int = 0) throws -> [ClipRecord] {
        var conditions: [String] = []
        var values: [SQLValue] = []
        if let kind {
            conditions.append("kind = ?")
            values.append(.text(kind.rawValue))
        }
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for word in words {
            if word.contains(where: { $0 == "%" || $0 == "_" || $0 == "\\" }) {
                conditions.append("id IN (SELECT rowid FROM clips_search WHERE instr(search_text, ?) > 0)")
                values.append(.text(word))
            } else {
                conditions.append("id IN (SELECT rowid FROM clips_search WHERE search_text LIKE ?)")
                values.append(.text("%\(word)%"))
            }
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT \(Self.recordColumns) FROM items \(whereClause) ORDER BY pinned DESC, last_copied_at DESC LIMIT ? OFFSET ?"
        values.append(.int(Int64(limit)))
        values.append(.int(Int64(offset)))
        return try locked {
            let stmt = try db.prepare(sql, values)
            var records: [ClipRecord] = []
            while try stmt.step() { records.append(Self.record(from: stmt)) }
            return records
        }
    }

    public func record(id: Int64) throws -> ClipRecord? {
        try locked {
            let stmt = try db.prepare("SELECT \(Self.recordColumns) FROM items WHERE id = ?", [.int(id)])
            return try stmt.step() ? Self.record(from: stmt) : nil
        }
    }

    public func payload(for id: Int64) throws -> ClipPayload {
        try locked {
            let stmt = try db.prepare("SELECT item_index, type, data, blob_file FROM reps WHERE item_id = ? ORDER BY item_index, ord", [.int(id)])
            var items: [[ClipRepresentation]] = []
            var currentIndex = -1
            while try stmt.step() {
                let index = stmt.int(0)
                let type = stmt.text(1) ?? ""
                let data: Data
                if let file = stmt.text(3) {
                    guard let d = try? Data(contentsOf: blobDirectory.appendingPathComponent(file), options: .mappedIfSafe) else { continue }
                    data = d
                } else {
                    data = stmt.blob(2) ?? Data()
                }
                if index != currentIndex {
                    items.append([])
                    currentIndex = index
                }
                items[items.count - 1].append(ClipRepresentation(type: type, data: data))
            }
            guard !items.isEmpty else { throw StoreError.notFound }
            return ClipPayload(items: items)
        }
    }

    /// Full plain text of a text/link/color item.
    public func fullText(for id: Int64) throws -> String? {
        guard let rep = try payload(for: id).firstData(ofTypes: [PasteboardMarkers.plainText, "NSStringPboardType", "public.utf16-plain-text"]) else { return nil }
        if rep.type == "public.utf16-plain-text" { return String(data: rep.data, encoding: .utf16) }
        return String(decoding: rep.data, as: UTF8.self)
    }

    public func imageData(for id: Int64) throws -> Data? {
        try payload(for: id).firstData(ofTypes: PasteboardMarkers.imageTypes)?.data
    }

    public func count() throws -> Int {
        try locked {
            let stmt = try db.prepare("SELECT COUNT(*) FROM items")
            return try stmt.step() ? stmt.int(0) : 0
        }
    }

    /// Bytes used on disk by the database and blobs.
    public func diskUsage() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = directory.appendingPathComponent("clipboard.sqlite" + suffix).path
            total += (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        if let files = try? fm.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    // MARK: - Helpers

    private static func record(from stmt: Statement) -> ClipRecord {
        let metaText = stmt.text(7)
        let meta = metaText.flatMap { try? JSONDecoder().decode(ClipMeta.self, from: Data($0.utf8)) } ?? ClipMeta()
        return ClipRecord(
            id: stmt.int64(0),
            kind: ClipKind(rawValue: stmt.text(1) ?? "") ?? .other,
            preview: stmt.text(2) ?? "",
            charCount: stmt.int(3),
            byteSize: stmt.int(4),
            sourceBundleID: stmt.text(5),
            sourceAppName: stmt.text(6),
            meta: meta,
            createdAt: Date(timeIntervalSince1970: stmt.double(8)),
            lastCopiedAt: Date(timeIntervalSince1970: stmt.double(9)),
            copyCount: stmt.int(10),
            pinned: stmt.int(11) != 0
        )
    }

    private func writeBlob(_ data: Data) throws -> String {
        let name = Self.sha256Hex(data)
        let url = blobDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    private func removeUnreferencedBlobs(_ names: [String]) {
        for name in Set(names) {
            guard let stmt = try? db.prepare("SELECT COUNT(*) FROM reps WHERE blob_file = ?", [.text(name)]),
                  (try? stmt.step()) == true, stmt.int(0) == 0 else { continue }
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name))
        }
    }

    private static func textOrNull(_ s: String?) -> SQLValue {
        s.map { .text($0) } ?? .null
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
