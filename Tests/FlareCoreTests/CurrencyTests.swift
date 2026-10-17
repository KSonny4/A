import XCTest
@testable import FlareCore

final class CurrencyTests: XCTestCase {
    private let defaults = ["CZK", "USD", "EUR"]

    private func parse(_ s: String) -> CurrencyQuery? {
        CurrencyQueryParser.parse(s, knownCodes: nil, defaultTargets: defaults)
    }

    func testExplicitConversion() {
        XCTAssertEqual(parse("100 usd to eur"), CurrencyQuery(amount: 100, from: "USD", to: ["EUR"], hasExplicitTarget: true))
        XCTAssertEqual(parse("100 USD in EUR")?.to, ["EUR"])
        XCTAssertEqual(parse("100usd eur")?.to, ["EUR"])
        XCTAssertEqual(parse("100 usd = eur")?.to, ["EUR"])
        XCTAssertEqual(parse("100 usd -> eur")?.to, ["EUR"])
    }

    func testSymbols() {
        XCTAssertEqual(parse("€50 to czk"), CurrencyQuery(amount: 50, from: "EUR", to: ["CZK"], hasExplicitTarget: true))
        XCTAssertEqual(parse("$20")?.from, "USD")
        XCTAssertEqual(parse("50€")?.from, "EUR")
        XCTAssertEqual(parse("250 kč to eur")?.from, "CZK")
        XCTAssertEqual(parse("£10 in usd")?.from, "GBP")
    }

    func testDefaultTargets() {
        let q = parse("20 eur")
        XCTAssertEqual(q?.from, "EUR")
        XCTAssertEqual(q?.to, ["CZK", "USD"])
        XCTAssertEqual(q?.hasExplicitTarget, false)
    }

    func testNumberFormats() {
        XCTAssertEqual(parse("1,234.56 usd to eur")?.amount, 1234.56)
        XCTAssertEqual(parse("1.234,56 eur to usd")?.amount, 1234.56)
        XCTAssertEqual(parse("12,5 eur to usd")?.amount, 12.5)
        XCTAssertEqual(parse("1 000 czk to eur")?.amount, 1000)
        XCTAssertEqual(parse("10k usd to eur")?.amount, 10_000)
        XCTAssertEqual(parse("1.5m usd to eur")?.amount, 1_500_000)
    }

    func testWithoutAmount() {
        XCTAssertEqual(parse("usd to eur"), CurrencyQuery(amount: 1, from: "USD", to: ["EUR"], hasExplicitTarget: true))
    }

    func testRejectsNonCurrencyQueries() {
        XCTAssertNil(parse("100"))
        XCTAssertNil(parse("2023 report"))
        XCTAssertNil(parse("1password"))
        XCTAssertNil(parse("safari"))
        XCTAssertNil(parse("invoice 12 final"))
        XCTAssertNil(CurrencyQueryParser.parse("100 usd to xyz", knownCodes: ["USD", "EUR"], defaultTargets: defaults))
    }

    func testConversionMath() {
        let table = RateTable(base: "USD", rates: ["EUR": 0.5, "CZK": 20], fetchedAt: Date())
        XCTAssertEqual(table.convert(10, from: "USD", to: "EUR"), 5)
        XCTAssertEqual(table.convert(10, from: "EUR", to: "CZK"), 400)
        XCTAssertEqual(table.convert(10, from: "EUR", to: "USD"), 20)
        XCTAssertNil(table.convert(10, from: "EUR", to: "JPY"))
    }

    func testParsesProviderResponse() throws {
        let json = """
        {"result":"success","base_code":"USD","time_last_update_unix":1700000000,"rates":{"USD":1,"EUR":0.92,"CZK":22.9}}
        """
        let table = try XCTUnwrap(CurrencyService.parseResponse(Data(json.utf8)))
        XCTAssertEqual(table.base, "USD")
        XCTAssertEqual(table.rates["CZK"], 22.9)
        XCTAssertEqual(table.providerUpdatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(CurrencyService.parseResponse(Data(#"{"result":"error","base_code":"USD","rates":{}}"#.utf8)))
    }

    func testServiceUsesCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("rates.json")
        let table = RateTable(base: "USD", rates: ["EUR": 0.5], fetchedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(table).write(to: cache)

        let service = CurrencyService(cacheURL: cache)
        XCTAssertFalse(service.needsRefresh)
        let result = service.convert(CurrencyQuery(amount: 4, from: "USD", to: ["EUR"], hasExplicitTarget: true))
        XCTAssertEqual(result.first?.result, 2)
    }

    func testFormatting() {
        XCTAssertEqual(CurrencyFormat.plain(1234.5), "1234.5")
        XCTAssertEqual(CurrencyFormat.plain(0.000123456), "0.000123")
    }
}
