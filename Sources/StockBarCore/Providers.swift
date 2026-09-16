import Foundation
import CoreFoundation

public protocol HTTPTransport: Sendable { func data(from url: URL) async throws -> Data }
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }
    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw QuoteError.invalidResponse("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else { throw QuoteError.http(http.statusCode) }
        guard data.count <= 4_000_000 else { throw QuoteError.tooLarge }
        return data
    }
}

public struct TencentProvider: QuoteProvider {
    public let descriptor = ProviderDescriptor(id: "tencent", name: "腾讯行情", detail: "股票与场内 ETF 行情")
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    public func fetch(_ instruments: [Instrument]) async throws -> [String: Quote] {
        guard !instruments.isEmpty else { return [:] }
        let url = URL(string: "https://qt.gtimg.cn/q=" + instruments.map(\.id).joined(separator: ","))!
        let data = try await transport.data(from: url)
        return try Self.parse(data, instruments: instruments)
    }
    public static func decode(_ data: Data) throws -> String {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else { throw QuoteError.invalidResponse("GB18030") }
        return text
    }
    public static func parse(_ data: Data, instruments: [Instrument], now: Date = Date()) throws -> [String: Quote] {
        let text = try decode(data)
        let regex = try NSRegularExpression(pattern: #"v_([a-z0-9]+)="([^"\r\n]*)""#)
        let allowed = Set(instruments.map(\.id))
        var output: [String: Quote] = [:]
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let idRange = Range(m.range(at: 1), in: text), let bodyRange = Range(m.range(at: 2), in: text) else { continue }
            let id = String(text[idRange]), f = text[bodyRange].components(separatedBy: "~")
            guard allowed.contains(id), f.count > 32,
                  let price = QuoteNumber.parse(f[3]), price > 0,
                  let change = QuoteNumber.parse(f[31]), let percent = QuoteNumber.parse(f[32]),
                  let stamp = MarketClock.parseTencentTime(f[30]), stamp <= now.addingTimeInterval(300) else { continue }
            output[id] = Quote(instrumentID: id, name: f[1], price: price, change: change, changePercent: percent, quoteTime: stamp, receivedAt: now, sourceID: "tencent")
        }
        return output
    }
    public func search(_ query: String) async throws -> [Instrument] {
        var c = URLComponents(string: "https://smartbox.gtimg.cn/s3/")!
        c.queryItems = [URLQueryItem(name: "t", value: "all"), URLQueryItem(name: "q", value: query)]
        let data = try await transport.data(from: c.url!)
        return try Self.parseSearch(data)
    }
    public static func parseSearch(_ data: Data) throws -> [Instrument] {
        let text = try decode(data)
        guard let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last else { return [] }
        let wrapped = String(text[first...last])
        // Parse quoted JSON string to decode unicode escapes without evaluating JavaScript.
        guard let raw = try? JSONDecoder().decode(String.self, from: Data(wrapped.utf8)) else { return [] }
        var seen = Set<String>()
        return raw.components(separatedBy: "^").compactMap { row in
            let f = row.components(separatedBy: "~")
            guard f.count >= 3, let market = Market(rawValue: f[0]), let base = Instrument.fromCode(f[0] + f[1]), base.market == market else { return nil }
            let instrument = Instrument(market: market, code: f[1], name: f[2])
            guard seen.insert(instrument.id).inserted else { return nil }
            return instrument
        }
    }
}

public struct EastmoneyProvider: QuoteProvider {
    public let descriptor = ProviderDescriptor(id: "eastmoney", name: "东方财富", detail: "股票与场内 ETF 行情")
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    public func fetch(_ instruments: [Instrument]) async throws -> [String: Quote] {
        guard !instruments.isEmpty else { return [:] }
        var last: Error = QuoteError.empty
        for host in ["push2delay.eastmoney.com", "push2.eastmoney.com"] {
            try Task.checkCancellation()
            var c = URLComponents(string: "https://\(host)/api/qt/ulist.np/get")!
            c.queryItems = [URLQueryItem(name: "fltt", value: "2"), URLQueryItem(name: "fields", value: "f2,f3,f4,f12,f13,f14,f124"), URLQueryItem(name: "secids", value: instruments.map(\.eastmoneyID).joined(separator: ","))]
            do {
                let data = try await transport.data(from: c.url!)
                let result = try Self.parse(data, instruments: instruments)
                if !result.isEmpty { return result }
                last = QuoteError.empty
            } catch { if Task.isCancelled { throw CancellationError() }; last = error }
        }
        throw last
    }
    public static func parse(_ data: Data, instruments: [Instrument], now: Date = Date()) throws -> [String: Quote] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any], let rows = body["diff"] as? [[String: Any]] else { throw QuoteError.invalidResponse("缺少 data.diff") }
        let requested = Dictionary(uniqueKeysWithValues: instruments.map { ($0.eastmoneyID, $0) })
        var output: [String: Quote] = [:]
        func decimal(_ v: Any?) -> Decimal? {
            guard let v = v, !(v is NSNull) else { return nil }
            let string = String(describing: v)
            guard string != "-", let d = QuoteNumber.parse(string) else { return nil }
            return d
        }
        for row in rows {
            guard let market = row["f13"] as? Int, let code = row["f12"] as? String,
                  let instrument = requested["\(market).\(code)"], let name = row["f14"] as? String,
                  let price = decimal(row["f2"]), price > 0, let percent = decimal(row["f3"]),
                  let change = decimal(row["f4"]), let time = row["f124"] as? Double, time > 0 else { continue }
            let stamp = Date(timeIntervalSince1970: time)
            guard stamp <= now.addingTimeInterval(300) else { continue }
            output[instrument.id] = Quote(instrumentID: instrument.id, name: name, price: price, change: change, changePercent: percent, quoteTime: stamp, receivedAt: now, sourceID: "eastmoney")
        }
        return output
    }
    public func search(_ query: String) async throws -> [Instrument] {
        // A code lookup uses this provider's own quote endpoint, independent of Tencent search.
        guard let instrument = Instrument.fromCode(query) else { return [] }
        let result = try await fetch([instrument])
        guard let quote = result[instrument.id] else { return [] }
        return [Instrument(market: instrument.market, code: instrument.code, name: quote.name)]
    }
}

public struct ProviderRegistry: Sendable {
    public let providers: [any QuoteProvider]
    public init(_ providers: [any QuoteProvider]) {
        precondition(!providers.isEmpty, "Register at least one provider")
        precondition(Set(providers.map { $0.descriptor.id }).count == providers.count, "Provider IDs must be unique")
        self.providers = providers
    }
    public static func standard() -> ProviderRegistry { ProviderRegistry([TencentProvider(), EastmoneyProvider()]) }
    public var descriptors: [ProviderDescriptor] { providers.map(\.descriptor) }
}
