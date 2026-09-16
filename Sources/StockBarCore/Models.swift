import Foundation

public enum Market: String, Codable, Sendable { case sh, sz }

public struct Instrument: Identifiable, Codable, Hashable, Sendable {
    public let market: Market
    public let code: String
    public var name: String
    public var id: String { market.rawValue + code }
    public var eastmoneyID: String { "\(market == .sh ? 1 : 0).\(code)" }
    public var isETF: Bool { code.hasPrefix("5") || code.hasPrefix("15") || code.hasPrefix("16") }
    public init(market: Market, code: String, name: String) { self.market = market; self.code = code; self.name = name }
    public static func fromCode(_ input: String) -> Instrument? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = text.hasPrefix("sh") || text.hasPrefix("sz") ? String(text.dropFirst(2)) : text
        guard code.count == 6, code.allSatisfy(\.isNumber), code.allSatisfy({ $0.isASCII }) else { return nil }
        let market: Market
        if code.hasPrefix("6") || code.hasPrefix("5") { market = .sh }
        else if code.hasPrefix("0") || code.hasPrefix("3") || code.hasPrefix("15") || code.hasPrefix("16") { market = .sz }
        else { return nil }
        if text.hasPrefix("sh") && market != .sh || text.hasPrefix("sz") && market != .sz { return nil }
        return Instrument(market: market, code: code, name: code)
    }
    public static let defaults = [Instrument(market: .sh, code: "510300", name: "沪深300ETF"), Instrument(market: .sh, code: "600519", name: "贵州茅台"), Instrument(market: .sz, code: "000001", name: "平安银行")]
}

public struct Quote: Codable, Equatable, Sendable {
    public let instrumentID: String
    public let name: String
    public let price: Decimal
    public let change: Decimal
    public let changePercent: Decimal
    public let quoteTime: Date
    public let receivedAt: Date
    public let sourceID: String
    public init(instrumentID: String, name: String, price: Decimal, change: Decimal, changePercent: Decimal, quoteTime: Date, receivedAt: Date, sourceID: String) {
        self.instrumentID = instrumentID; self.name = name; self.price = price; self.change = change
        self.changePercent = changePercent; self.quoteTime = quoteTime; self.receivedAt = receivedAt; self.sourceID = sourceID
    }
}

public struct ProviderDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String) { self.id = id; self.name = name; self.detail = detail }
}

/// Implement this protocol and register an instance in ProviderRegistry to add a source.
/// Provider-specific identifiers, encodings, and field names never enter the UI.
public protocol QuoteProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func fetch(_ instruments: [Instrument]) async throws -> [String: Quote]
    func search(_ query: String) async throws -> [Instrument]
}

public enum QuoteError: Error, LocalizedError, Sendable {
    case invalidResponse(String), http(Int), empty, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let text): return "行情格式错误：\(text)"
        case .http(let status): return "服务返回 HTTP \(status)"
        case .empty: return "没有返回可用行情"
        case .tooLarge: return "响应超过大小限制"
        }
    }
}

public enum MarketClock {
    public static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    /// Weekday/time estimate, deliberately not a holiday calendar.
    public static func isLikelySession(_ date: Date) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let day = c.weekday, (2...6).contains(day) else { return false }
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (555...690).contains(minute) || (780...900).contains(minute)
    }
    public static func isDelayed(_ quote: Quote, now: Date) -> Bool {
        // A fresh HTTP response can still contain old market data.
        isLikelySession(now) && now.timeIntervalSince(quote.quoteTime) > 120
    }
    public static func parseTencentTime(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        f.dateFormat = "yyyyMMddHHmmss"; f.isLenient = false
        guard value.count == 14 else { return nil }
        return f.date(from: value)
    }
}

// Decimal(string:) accepts numeric prefixes; require a complete finite numeric field.
enum QuoteNumber {
    static func parse(_ text: String) -> Decimal? {
        guard text.count <= 64, text.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
}
