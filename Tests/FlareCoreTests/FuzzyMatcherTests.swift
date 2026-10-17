import XCTest
@testable import FlareCore

final class FuzzyMatcherTests: XCTestCase {
    private func rank(_ query: String, _ candidates: [String]) -> [String] {
        let entries = candidates.map { SearchEntry(id: $0, kind: .application, title: $0) }
        return SearchEngine.rank(entries, query: query, limit: 10).map(\.entry.title)
    }

    func testPrefixBeatsSubstring() {
        XCTAssertEqual(rank("saf", ["Microsoft Safety", "Safari", "Preview"]).first, "Safari")
    }

    func testAcronymMatches() {
        XCTAssertNotNil(FuzzyMatcher.score("vsc", "Visual Studio Code"))
        XCTAssertEqual(rank("vsc", ["Visual Studio Code", "Voice Memos", "VLC"]).first, "Visual Studio Code")
    }

    func testWordPrefixes() {
        XCTAssertEqual(rank("code", ["Xcode", "Visual Studio Code"]).first, "Visual Studio Code")
        XCTAssertEqual(rank("sys set", ["System Information", "System Settings"]).first, "System Settings")
    }

    func testDiacriticsAndCaseAreIgnored() {
        XCTAssertNotNil(FuzzyMatcher.score("prilohy", "Přílohy.pdf"))
        XCTAssertNotNil(FuzzyMatcher.score("FACTURA", "factura-2024.pdf"))
    }

    func testNoMatch() {
        XCTAssertNil(FuzzyMatcher.score("xyz", "Safari"))
    }

    func testExactBeatsEverything() {
        XCTAssertEqual(rank("notes", ["Notes Archive", "Notes", "Sticky Notes"]).first, "Notes")
    }

    func testCamelCaseWordStarts() {
        XCTAssertEqual(rank("tp", ["TablePlus", "Terminal", "Tips"]).first, "TablePlus")
    }

    func testUsageBoostReordersTies() {
        let entries = ["Telegram", "Terminal"].map { SearchEntry(id: $0, kind: .application, title: $0) }
        let usage = ["Terminal": UsageStat(count: 20, lastUsed: Date())]
        XCTAssertEqual(SearchEngine.rank(entries, query: "te", usage: usage, limit: 2).first?.entry.title, "Terminal")
    }

    func testKeywordsAreSearchable() {
        let entry = SearchEntry(id: "settings", kind: .application, title: "Nastavení systému", keywords: ["System Settings"])
        XCTAssertEqual(SearchEngine.rank([entry], query: "settings", limit: 1).count, 1)
    }

    func testSuggestionsUseUsage() {
        let entries = ["A", "B", "C"].map { SearchEntry(id: $0, kind: .application, title: $0) }
        let usage = ["B": UsageStat(count: 5, lastUsed: Date()), "C": UsageStat(count: 1, lastUsed: Date().addingTimeInterval(-86_400 * 30))]
        XCTAssertEqual(SearchEngine.suggestions(entries, usage: usage, limit: 5).map(\.title), ["B", "C"])
    }
}
