import Foundation

public struct ProviderHealth: Sendable {
    public var failureCount = 0
    public var cooldownUntil: Date?
    public var lastError: String?
    public var lastSuccess: Date?
    public init() {}
}
public struct FetchReport: Sendable {
    public let quotes: [String: Quote]
    public let errors: [String: String]
    public let health: [String: ProviderHealth]
    public let missingIDs: Set<String>
}

/// Owns source ordering, per-symbol fallback, and circuit breakers.
/// No provider-specific field names or URLs belong here.
public actor QuoteEngine {
    public let registry: ProviderRegistry
    private var health: [String: ProviderHealth] = [:]
    public init(registry: ProviderRegistry = .standard()) { self.registry = registry }
    private func ordered(preferred: String?) -> [any QuoteProvider] {
        guard let preferred = preferred else { return registry.providers }
        return registry.providers.filter { $0.descriptor.id == preferred } + registry.providers.filter { $0.descriptor.id != preferred }
    }
    public func resetCooldowns() { health = [:] }
    public func fetch(_ instruments: [Instrument], preferred: String? = nil, allowFallback: Bool = true, now: Date = Date()) async throws -> FetchReport {
        let unique = instruments.reduce(into: [Instrument]()) { list, instrument in if !list.contains(where: { $0.id == instrument.id }) { list.append(instrument) } }
        let providers = ordered(preferred: preferred)
        var output: [String: Quote] = [:], errors: [String: String] = [:]
        for provider in (allowFallback ? providers : Array(providers.prefix(1))) {
            try Task.checkCancellation()
            let pending = unique.filter { output[$0.id] == nil || MarketClock.isDelayed(output[$0.id]!, now: now) }
            if pending.isEmpty { break }
            let id = provider.descriptor.id
            var status = health[id] ?? ProviderHealth()
            if let until = status.cooldownUntil, until > now {
                errors[id] = "暂停重试至 \(Self.time(until))"; continue
            }
            do {
                let fetched = try await provider.fetch(pending)
                try Task.checkCancellation()
                let accepted = fetched.filter { key, q in
                    pending.contains(where: { $0.id == key }) && q.instrumentID == key && q.sourceID == id && q.price > 0 && !q.price.isNaN && !q.change.isNaN && !q.changePercent.isNaN && q.quoteTime <= now.addingTimeInterval(300)
                }
                guard !accepted.isEmpty else { throw QuoteError.empty }
                for (key, quote) in accepted {
                    if let prior = output[key], prior.quoteTime > quote.quoteTime { continue }
                    output[key] = quote
                }
                status.failureCount = 0; status.cooldownUntil = nil; status.lastSuccess = now
                let missing = pending.count - accepted.count
                status.lastError = missing > 0 ? "\(missing) 个标的未返回，将尝试其他来源" : nil
                if let error = status.lastError { errors[id] = error }
                health[id] = status
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                status.failureCount += 1
                status.lastError = error.localizedDescription
                if status.failureCount >= 2 {
                    status.cooldownUntil = now.addingTimeInterval(min(300, 30 * pow(2, Double(min(status.failureCount - 2, 4)))))
                }
                errors[id] = status.lastError; health[id] = status
            }
        }
        return FetchReport(quotes: output, errors: errors, health: health, missingIDs: Set(unique.map(\.id)).subtracting(output.keys))
    }
    public func search(_ query: String, preferred: String? = nil, allowFallback: Bool = true) async throws -> [Instrument] {
        let providers = ordered(preferred: preferred)
        var last: Error?
        for provider in (allowFallback ? providers : Array(providers.prefix(1))) {
            try Task.checkCancellation()
            do {
                let result = try await provider.search(query)
                if !result.isEmpty { return result }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                last = error
            }
        }
        if let last = last { throw last }
        return []
    }
    private static func time(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date) }
}
