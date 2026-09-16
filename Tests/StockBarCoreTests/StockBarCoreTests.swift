import XCTest
@testable import StockBarCore

private let testNow = MarketClock.parseTencentTime("20260916111100")!
private let sample = Instrument.defaults[0]
private func quote(_ instrument: Instrument = sample, source: String, stamp: Date = testNow) -> Quote {
    Quote(instrumentID: instrument.id, name: instrument.name, price: Decimal(string: "4.532")!, change: Decimal(string: "0.009")!, changePercent: Decimal(string: "0.20")!, quoteTime: stamp, receivedAt: testNow, sourceID: source)
}
private actor StubProvider: QuoteProvider {
    nonisolated let descriptor: ProviderDescriptor
    let values: [String: Quote]
    let failing: Bool
    private var calls = 0
    private var requested: [[String]] = []
    init(_ id: String, values: [String: Quote] = [:], failing: Bool = false) {
        descriptor = ProviderDescriptor(id: id, name: id, detail: "test"); self.values = values; self.failing = failing
    }
    func fetch(_ instruments: [Instrument]) async throws -> [String: Quote] {
        calls += 1; requested.append(instruments.map(\.id))
        if failing { throw QuoteError.http(503) }
        return values.filter { instruments.map(\.id).contains($0.key) }
    }
    func search(_ query: String) async throws -> [Instrument] { [] }
    func count() -> Int { calls }
    func requests() -> [[String]] { requested }
}

final class ParsingTests: XCTestCase {
    func fixture(_ name: String, _ ext: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!) }
    func testTencentGBKBatchAndPrecision() throws {
        let result = try TencentProvider.parse(fixture("tencent", "txt"), instruments: Instrument.defaults, now: testNow)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result["sh600519"]?.name, "贵州茅台")
        XCTAssertEqual(result["sh510300"]?.price, Decimal(string: "4.532"))
        XCTAssertEqual(result["sh510300"]?.change, Decimal(string: "0.009"))
        XCTAssertEqual(result["sh600519"]?.quoteTime, MarketClock.parseTencentTime("20260916111051"))
        XCTAssertNil(result["hk00700"])
    }
    func testTencentMalformedAndUnknownDoNotBecomeZero() throws {
        let data = Data(#"v_sh510300="1~broken~510300~0";v_pv_none_match="1";"#.utf8)
        XCTAssertTrue(try TencentProvider.parse(data, instruments: [sample], now: testNow).isEmpty)
    }
    func testTencentUnicodeSearch() throws {
        let result = try TencentProvider.parseSearch(fixture("search", "txt"))
        XCTAssertEqual(result, [Instrument(market: .sh, code: "600519", name: "贵州茅台")])
    }
    func testEastmoneyNumbersAndMapping() throws {
        let result = try EastmoneyProvider.parse(fixture("eastmoney", "json"), instruments: Instrument.defaults, now: testNow)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result["sh510300"]?.price, Decimal(string: "4.532"))
        XCTAssertEqual(result["sz000001"]?.changePercent, Decimal(string: "-1.86"))
        XCTAssertEqual(result["sh510300"]?.sourceID, "eastmoney")
    }
    func testEastmoneyMissingPriceRejected() throws {
        let json = #"{"data":{"diff":[{"f2":"-","f3":1,"f4":1,"f12":"510300","f13":1,"f14":"ETF","f124":1789528252}]}}"#
        XCTAssertTrue(try EastmoneyProvider.parse(Data(json.utf8), instruments: [sample], now: testNow).isEmpty)
        XCTAssertThrowsError(try EastmoneyProvider.parse(Data(#"{"data":null}"#.utf8), instruments: [sample], now: testNow))
    }
    func testRejectsNumericPrefixesAndNonfiniteFields() {
        XCTAssertNil(QuoteNumber.parse("12oops"))
        XCTAssertNil(QuoteNumber.parse("NaN"))
        XCTAssertNil(QuoteNumber.parse("Infinity"))
        XCTAssertEqual(QuoteNumber.parse("-0.009"), Decimal(string: "-0.009"))
    }
    func testInstrumentValidation() {
        XCTAssertEqual(Instrument.fromCode("510300")?.id, "sh510300")
        XCTAssertEqual(Instrument.fromCode("sz000001")?.eastmoneyID, "0.000001")
        XCTAssertNil(Instrument.fromCode("sh000001")) // Not silently changed into a different instrument.
        XCTAssertNil(Instrument.fromCode("00700"))
        XCTAssertNil(Instrument.fromCode("AAPL"))
        XCTAssertNil(Instrument.fromCode("１２３４５６"))
    }
    func testSessionAndOldQuote() {
        XCTAssertTrue(MarketClock.isLikelySession(testNow))
        XCTAssertFalse(MarketClock.isLikelySession(MarketClock.parseTencentTime("20260916120000")!))
        XCTAssertFalse(MarketClock.isLikelySession(MarketClock.parseTencentTime("20260919110000")!))
        XCTAssertTrue(MarketClock.isDelayed(quote(source: "a", stamp: testNow.addingTimeInterval(-900)), now: testNow))
        XCTAssertFalse(MarketClock.isDelayed(quote(source: "a"), now: testNow))
    }
}

final class FailoverTests: XCTestCase {
    func testFailureFallsBackAndCircuitRecovers() async throws {
        let a = StubProvider("a", failing: true), b = StubProvider("b", values: [sample.id: quote(source: "b")])
        let engine = QuoteEngine(registry: ProviderRegistry([a,b]))
        let first = try await engine.fetch([sample], now: testNow)
        XCTAssertEqual(first.quotes[sample.id]?.sourceID, "b")
        XCTAssertNotNil(first.errors["a"])
        _ = try await engine.fetch([sample], now: testNow.addingTimeInterval(1))
        let third = try await engine.fetch([sample], now: testNow.addingTimeInterval(2))
        let calls = await a.count()
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(third.health["a"]?.cooldownUntil)
        _ = try await engine.fetch([sample], now: testNow.addingTimeInterval(32))
        let recoveredCalls = await a.count()
        XCTAssertEqual(recoveredCalls, 3)
    }
    func testPartialResponseOnlyRetriesMissingSymbol() async throws {
        let second = Instrument.defaults[1]
        let a = StubProvider("a", values: [sample.id: quote(source: "a")])
        let b = StubProvider("b", values: [second.id: quote(second, source: "b")])
        let report = try await QuoteEngine(registry: ProviderRegistry([a,b])).fetch([sample,second], now: testNow)
        XCTAssertEqual(report.quotes.count, 2)
        let requests = await b.requests()
        XCTAssertEqual(requests, [[second.id]])
        XCTAssertTrue(report.missingIDs.isEmpty)
    }
    func testManualSourceWithoutFallbackNeverCallsOtherSource() async throws {
        let a = StubProvider("a", values: [sample.id: quote(source: "a")]), b = StubProvider("b", failing: true)
        let result = try await QuoteEngine(registry: ProviderRegistry([a,b])).fetch([sample], preferred: "b", allowFallback: false, now: testNow)
        XCTAssertTrue(result.quotes.isEmpty)
        XCTAssertEqual(result.missingIDs, [sample.id])
        let calls = await a.count()
        XCTAssertEqual(calls, 0)
    }
    func testDelayedPrimaryTriesBackupAndKeepsNewest() async throws {
        let old = quote(source: "a", stamp: testNow.addingTimeInterval(-900))
        let a = StubProvider("a", values: [sample.id: old]), b = StubProvider("b", values: [sample.id: quote(source: "b")])
        let report = try await QuoteEngine(registry: ProviderRegistry([a,b])).fetch([sample], now: testNow)
        XCTAssertEqual(report.quotes[sample.id]?.sourceID, "b")
        let older = StubProvider("c", values: [sample.id: quote(source: "c", stamp: testNow.addingTimeInterval(-1200))])
        let noRegression = try await QuoteEngine(registry: ProviderRegistry([a,older])).fetch([sample], now: testNow)
        XCTAssertEqual(noRegression.quotes[sample.id], old)
    }
    func testPreferredProviderGoesFirstAndDoesNotPollUnusedBackup() async throws {
        let a = StubProvider("a"), b = StubProvider("b", values: [sample.id: quote(source: "b")])
        let report = try await QuoteEngine(registry: ProviderRegistry([a,b])).fetch([sample, sample], preferred: "b", now: testNow)
        XCTAssertEqual(report.quotes.count, 1)
        let calls = await a.count(), requests = await b.requests()
        XCTAssertEqual(calls, 0); XCTAssertEqual(requests, [[sample.id]])
    }
}

private actor HostFallbackTransport: HTTPTransport {
    private var hosts: [String] = []
    let response: Data
    init(response: Data) { self.response = response }
    func data(from url: URL) async throws -> Data {
        hosts.append(url.host ?? "")
        if url.host == "push2delay.eastmoney.com" { throw QuoteError.http(503) }
        return response
    }
    func requestedHosts() -> [String] { hosts }
}
private struct CancelProvider: QuoteProvider {
    let descriptor = ProviderDescriptor(id: "cancel", name: "cancel", detail: "test")
    func fetch(_ instruments: [Instrument]) async throws -> [String: Quote] { throw CancellationError() }
    func search(_ query: String) async throws -> [Instrument] { throw CancellationError() }
}
final class TransportTests: XCTestCase {
    func testEastmoneyUsesAlternateHostAfterFailure() async throws {
        // Test uses a current timestamp since the live provider validates future timestamps.
        let row: [String: Any] = ["f2":4.532,"f3":0.20,"f4":0.009,"f12":"510300","f13":1,"f14":"ETF","f124":Date().timeIntervalSince1970]
        let data = try JSONSerialization.data(withJSONObject: ["data":["diff":[row]]])
        let transport = HostFallbackTransport(response: data)
        let result = try await EastmoneyProvider(transport: transport).fetch([sample])
        XCTAssertEqual(result[sample.id]?.price, Decimal(string: "4.532"))
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["push2delay.eastmoney.com", "push2.eastmoney.com"])
    }
    func testCancellationDoesNotStartFallback() async throws {
        let backup = StubProvider("backup", values: [sample.id: quote(source: "backup")])
        do {
            _ = try await QuoteEngine(registry: ProviderRegistry([CancelProvider(), backup])).fetch([sample], now: testNow)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let calls = await backup.count()
        XCTAssertEqual(calls, 0)
    }
}

final class PreferencesTests: XCTestCase {
    func testOldSettingsMigrateWithoutLosingWatchlist() throws {
        let old = #"{"instruments":[{"market":"sz","code":"159915","name":"我的ETF"}],"pinnedID":"sz159915","preferredSource":"eastmoney","showPrice":true}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertEqual(p.instruments.first?.name, "我的ETF")
        XCTAssertEqual(p.pinnedID, "sz159915")
        XCTAssertEqual(p.preferredSource, "eastmoney")
        XCTAssertEqual(p.menuContent, "both")
        XCTAssertEqual(p.menuWidth, 180)
        XCTAssertTrue(p.allowFallback)
        XCTAssertTrue(p.glassEnabled)
        XCTAssertEqual(p.menuStyle, .quotes)
    }
    func testUnknownMenuStyleRetainsOtherPreferences() throws {
        let data = Data(#"{"menuStyle":"future-style","rotate":true,"rotationSeconds":15}"#.utf8)
        let p = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(p.menuStyle, .quotes)
        XCTAssertTrue(p.rotate)
        XCTAssertEqual(p.rotationSeconds, 15)
    }
    func testSettingsRoundTrip() throws {
        var p = Preferences()
        p.menuLabel = "code"; p.menuContent = "price"; p.menuWidth = 120; p.menuFontSize = 13
        p.glassEnabled = false
        p.menuStyle = .icon
        p.compact = true; p.rotationSeconds = 15; p.rotate = true; p.showSource = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.menuLabel, "code"); XCTAssertEqual(decoded.menuContent, "price")
        XCTAssertEqual(decoded.menuWidth, 120); XCTAssertEqual(decoded.menuFontSize, 13)
        XCTAssertTrue(decoded.compact); XCTAssertTrue(decoded.rotate); XCTAssertFalse(decoded.showSource)
        XCTAssertFalse(decoded.glassEnabled)
        XCTAssertEqual(decoded.menuStyle, .icon)
        XCTAssertEqual(decoded.rotationSeconds, 15); XCTAssertEqual(decoded.instruments, p.instruments)
    }
}
