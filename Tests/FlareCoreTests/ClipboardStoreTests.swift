import XCTest
@testable import FlareCore

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flare-tests-\(UUID().uuidString)")
        store = try ClipboardStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func textPayload(_ s: String) -> (ClipPayload, ClipAnalysis) {
        let payload = ClipPayload(items: [[ClipRepresentation(type: PasteboardMarkers.plainText, data: Data(s.utf8))]])
        return (payload, ClipAnalyzer.analyze(payload: payload, string: s, fileURLs: []))
    }

    @discardableResult
    private func insertText(_ s: String, date: Date = Date()) throws -> ClipboardStore.InsertResult {
        let (payload, analysis) = textPayload(s)
        return try store.insert(payload: payload, analysis: analysis, sourceBundleID: "com.apple.Safari", sourceAppName: "Safari", date: date)
    }

    func testInsertAndFetchNewestFirst() throws {
        try insertText("first", date: Date(timeIntervalSince1970: 1))
        try insertText("second", date: Date(timeIntervalSince1970: 2))
        let records = try store.fetch()
        XCTAssertEqual(records.map(\.preview), ["second", "first"])
        XCTAssertEqual(records.first?.sourceAppName, "Safari")
        XCTAssertEqual(records.first?.kind, .text)
    }

    func testDuplicateBumpsInsteadOfDuplicating() throws {
        let a = try insertText("hello", date: Date(timeIntervalSince1970: 1))
        try insertText("other", date: Date(timeIntervalSince1970: 2))
        let b = try insertText("hello", date: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(a.id, b.id)
        XCTAssertFalse(b.isNew)
        let records = try store.fetch()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.preview, "hello")
        XCTAssertEqual(records.first?.copyCount, 2)
    }

    func testSearchIsCaseInsensitiveSubstringAndMultiWord() throws {
        try insertText("The Quick Brown Fox")
        try insertText("lazy dog")
        try insertText("100% sure_thing")
        XCTAssertEqual(try store.fetch(query: "quick").count, 1)
        XCTAssertEqual(try store.fetch(query: "ROWN").count, 1)
        XCTAssertEqual(try store.fetch(query: "fox quick").count, 1)
        XCTAssertEqual(try store.fetch(query: "do").count, 1)
        XCTAssertEqual(try store.fetch(query: "100%").count, 1)
        XCTAssertEqual(try store.fetch(query: "sure_t").count, 1)
        XCTAssertEqual(try store.fetch(query: "missing").count, 0)
    }

    func testHugeTextRoundTripsAndUsesBlobFile() throws {
        let line = String(repeating: "abcdefghij", count: 100) + "\n"
        let huge = String(repeating: line, count: 50_000) + "needle-at-the-end"
        XCTAssertGreaterThan(huge.utf8.count, 50_000_000)
        let result = try insertText(huge)
        XCTAssertEqual(try store.fullText(for: result.id), huge)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: store.blobDirectory.path)
        XCTAssertEqual(blobs.count, 1)
        let record = try XCTUnwrap(store.record(id: result.id))
        XCTAssertEqual(record.preview.count, ClipAnalyzer.previewLength)
    }

    func testManyItemsWithPaging() throws {
        for i in 0..<10_000 {
            try insertText("item \(i)", date: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(try store.count(), 10_000)
        let page1 = try store.fetch(limit: 100, offset: 0)
        let page2 = try store.fetch(limit: 100, offset: 100)
        XCTAssertEqual(page1.first?.preview, "item 9999")
        XCTAssertEqual(page2.first?.preview, "item 9899")
        XCTAssertEqual(try store.fetch(query: "item 42", limit: 1000).count, 299) // every number containing "42"
    }

    func testPinnedStayOnTop() throws {
        let old = try insertText("old", date: Date(timeIntervalSince1970: 1))
        try insertText("new", date: Date(timeIntervalSince1970: 2))
        try store.setPinned(true, id: old.id)
        XCTAssertEqual(try store.fetch().map(\.preview), ["old", "new"])
    }

    func testDeleteRemovesBlobsAndSearchRows() throws {
        let big = String(repeating: "x", count: ClipboardStore.inlineLimit + 10)
        let result = try insertText(big)
        try store.delete(id: result.id)
        XCTAssertEqual(try store.count(), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.blobDirectory.path).count, 0)
        XCTAssertEqual(try store.fetch(query: "xxx").count, 0)
    }

    func testDeleteAllKeepsPinned() throws {
        let keep = try insertText("keep")
        try insertText("drop")
        try store.setPinned(true, id: keep.id)
        try store.deleteAll()
        XCTAssertEqual(try store.fetch().map(\.preview), ["keep"])
    }

    func testMultiItemPayloadRoundTrip() throws {
        let payload = ClipPayload(items: [
            [ClipRepresentation(type: "public.file-url", data: Data("file:///tmp/a.txt".utf8)),
             ClipRepresentation(type: PasteboardMarkers.plainText, data: Data("a.txt".utf8))],
            [ClipRepresentation(type: "public.file-url", data: Data("file:///tmp/b.txt".utf8))],
        ])
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        let analysis = ClipAnalyzer.analyze(payload: payload, string: "a.txt", fileURLs: urls)
        XCTAssertEqual(analysis.kind, .file)
        let result = try store.insert(payload: payload, analysis: analysis, sourceBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(try store.payload(for: result.id), payload)
        let record = try XCTUnwrap(store.record(id: result.id))
        XCTAssertEqual(record.title, "a.txt and 1 more")
        XCTAssertEqual(try store.fetch(query: "b.txt").count, 1)
    }

    func testPersistsAcrossReopen() throws {
        try insertText("persisted")
        store = nil
        store = try ClipboardStore(directory: directory)
        XCTAssertEqual(try store.fetch().first?.preview, "persisted")
    }
}

final class ClipAnalyzerTests: XCTestCase {
    private func kind(_ s: String) -> ClipKind {
        let payload = ClipPayload(items: [[ClipRepresentation(type: PasteboardMarkers.plainText, data: Data(s.utf8))]])
        return ClipAnalyzer.analyze(payload: payload, string: s, fileURLs: []).kind
    }

    func testClassification() {
        XCTAssertEqual(kind("hello world"), .text)
        XCTAssertEqual(kind("https://raycast.com/pro"), .link)
        XCTAssertEqual(kind("  https://example.com  "), .link)
        XCTAssertEqual(kind("https://example.com is great"), .text)
        XCTAssertEqual(kind("#FF6363"), .color)
        XCTAssertEqual(kind("#abc"), .color)
        XCTAssertEqual(kind("#hashtag"), .text)
    }

    func testImageAndOther() {
        let png = ClipPayload(items: [[ClipRepresentation(type: "public.png", data: Data([1, 2, 3]))]])
        XCTAssertEqual(ClipAnalyzer.analyze(payload: png, string: nil, fileURLs: []).kind, .image)
        let custom = ClipPayload(items: [[ClipRepresentation(type: "com.example.custom", data: Data([9]))]])
        XCTAssertEqual(ClipAnalyzer.analyze(payload: custom, string: nil, fileURLs: []).kind, .other)
    }

    func testWordCount() {
        XCTAssertEqual(ClipAnalyzer.wordCount("one two  three\nfour"), 4)
        XCTAssertEqual(ClipAnalyzer.wordCount("   "), 0)
    }

    func testRecordTitleUsesFirstNonEmptyLine() {
        let record = ClipRecord(id: 1, kind: .text, preview: "\n\n   first line  \nsecond", charCount: 0, byteSize: 0,
                                sourceBundleID: nil, sourceAppName: nil, meta: ClipMeta(), createdAt: Date(),
                                lastCopiedAt: Date(), copyCount: 1, pinned: false)
        XCTAssertEqual(record.title, "first line")
    }
}
