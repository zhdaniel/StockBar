import AppKit
import SwiftUI
import ServiceManagement
import StockBarCore

struct SavedState: Codable { var preferences: Preferences; var quotes: [String: Quote] }

@MainActor final class AppStore: ObservableObject {
    @Published var preferences = Preferences()
    @Published var quotes: [String: Quote] = [:]
    @Published var health: [String: ProviderHealth] = [:]
    @Published var fetchErrors: [String: String] = [:]
    @Published var missingIDs = Set<String>()
    @Published var refreshing = false
    @Published var lastAttempt: Date?
    @Published var storageError: String?
    @Published var searchText = ""
    @Published var searchResults: [Instrument] = []
    @Published var searchMessage: String?
    @Published var searching = false
    @Published var loginMessage: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var panelVisible = false
    @Published var sleeping = false
    @Published var rotationIndex = 0
    @Published var supportVisible = false
    @Published var selectedPage = 0
    @Published var paused = false
    let registry = ProviderRegistry.standard()
    private let engine: QuoteEngine
    private var scheduler: Task<Void, Never>?
    private var activeFetch: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var failureStreak = 0
    private var lastRefreshStart: Date = .distantPast
    private var lastRotation = Date()
    private var generation = 0
    private var pendingRefresh = false
    private let stateURL: URL
    var changed: (() -> Void)?

    init() {
        engine = QuoteEngine(registry: registry)
        stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StockBar/state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                preferences = saved.preferences
                var seen = Set<String>()
                preferences.instruments = preferences.instruments.filter { Instrument.fromCode($0.id) != nil && seen.insert($0.id).inserted }.prefix(50).map { $0 }
                preferences.interval = max(10, min(60, preferences.interval))
                preferences.menuWidth = max(120, min(240, preferences.menuWidth))
                preferences.menuFontSize = max(11, min(13, preferences.menuFontSize))
                preferences.rotationSeconds = max(5, min(30, preferences.rotationSeconds))
                if preferences.preferredSource != "auto" && !registry.descriptors.contains(where: { $0.id == preferences.preferredSource }) { preferences.preferredSource = "auto" }
                quotes = saved.quotes.filter { seen.contains($0.key) }
            } catch { storageError = "无法读取上次配置；当前使用默认列表。\(error.localizedDescription)" }
        }
        repairPinned()
        // Persisted values are cache, not evidence of a successful request in this process.
        missingIDs = Set(preferences.instruments.map(\.id))
    }
    var rotatesMenuQuotes: Bool { preferences.menuStyle == .quotes && preferences.rotate }
    var displayedInstrument: Instrument? {
        if rotatesMenuQuotes, !preferences.instruments.isEmpty { return preferences.instruments[rotationIndex % preferences.instruments.count] }
        return preferences.instruments.first(where: { $0.id == preferences.pinnedID }) ?? preferences.instruments.first
    }
    var preferred: String? { preferences.preferredSource == "auto" ? nil : preferences.preferredSource }
    var effectiveFallback: Bool { preferences.preferredSource == "auto" || preferences.allowFallback }
    func start() {
        refresh(force: true)
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { break }
                self.tick()
            }
        }
    }
    private func tick() {
        guard !sleeping else { return }
        let now = Date()
        if rotatesMenuQuotes && now.timeIntervalSince(lastRotation) >= Double(preferences.rotationSeconds) {
            rotationIndex += 1; lastRotation = now; changed?()
        }
        let base = MarketClock.isLikelySession(now) ? preferences.interval : 300
        let wait = Double(max(base, min(300, preferences.interval * (1 << min(failureStreak, 5)))))
        if !paused && (now.timeIntervalSince(lastRefreshStart) >= wait || (pendingRefresh && now.timeIntervalSince(lastRefreshStart) >= 5)) { refresh() }
        changed?()
    }
    func refresh(force: Bool = false) {
        guard !sleeping, !preferences.instruments.isEmpty else { return }
        guard activeFetch == nil else { pendingRefresh = true; return }
        // Manual refresh also observes a floor to avoid accidental request storms.
        guard force || Date().timeIntervalSince(lastRefreshStart) >= 5 else { pendingRefresh = true; return }
        pendingRefresh = false
        let instruments = panelVisible || rotatesMenuQuotes ? preferences.instruments : displayedInstrument.map { [$0] } ?? []
        let preferred = self.preferred, fallback = effectiveFallback, epoch = generation
        refreshing = true; lastRefreshStart = Date(); lastAttempt = lastRefreshStart
        activeFetch = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing = false; self.activeFetch = nil; self.changed?() }
            do {
                let report = try await engine.fetch(instruments, preferred: preferred, allowFallback: fallback)
                guard !Task.isCancelled, epoch == generation else { return }
                for (id, quote) in report.quotes where preferences.instruments.contains(where: { $0.id == id }) {
                    if let old = quotes[id], old.quoteTime > quote.quoteTime { continue }
                    quotes[id] = quote
                }
                let attempted = Set(instruments.map(\.id))
                missingIDs.subtract(attempted); missingIDs.formUnion(report.missingIDs.intersection(Set(preferences.instruments.map(\.id))))
                health = report.health; fetchErrors = report.errors
                failureStreak = report.quotes.isEmpty ? failureStreak + 1 : 0
                save()
            } catch {
                if !Task.isCancelled { fetchErrors = ["network": error.localizedDescription]; missingIDs.formUnion(instruments.map(\.id)); failureStreak += 1 }
            }
        }
    }
    func setPanelVisible(_ value: Bool) { panelVisible = value; if value { refresh() } }
    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { activeFetch?.cancel() }
        else { lastRefreshStart = .distantPast; refresh() }
    }
    func preferenceChanged(sourceChanged: Bool = false) {
        if sourceChanged {
            generation += 1
            // Let any in-flight operation finish/cancel before scheduling the new policy.
            activeFetch?.cancel()
            failureStreak = 0; lastRefreshStart = .distantPast
            Task { await engine.resetCooldowns() }
        }
        repairPinned(); save(); changed?()
    }
    private func repairPinned() {
        if !preferences.instruments.contains(where: { $0.id == preferences.pinnedID }) { preferences.pinnedID = preferences.instruments.first?.id ?? "" }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedState(preferences: preferences, quotes: quotes))
            try data.write(to: stateURL, options: .atomic)
            storageError = nil
        } catch { storageError = "保存失败：\(error.localizedDescription)" }
    }
    func add(_ instrument: Instrument) {
        guard !preferences.instruments.contains(where: { $0.id == instrument.id }), preferences.instruments.count < 50 else { return }
        preferences.instruments.append(instrument); missingIDs.insert(instrument.id)
        preferenceChanged(); searchText = ""; searchResults = []; searchMessage = nil; refresh()
    }
    func remove(_ id: String) {
        preferences.instruments.removeAll { $0.id == id }; quotes.removeValue(forKey: id); missingIDs.remove(id)
        preferenceChanged()
    }
    func pin(_ id: String) { preferences.pinnedID = id; preferences.rotate = false; preferenceChanged(); refresh() }
    func moveOne(_ id: String, offset: Int) {
        guard let index = preferences.instruments.firstIndex(where: { $0.id == id }) else { return }
        let next = index + offset
        guard preferences.instruments.indices.contains(next) else { return }
        preferences.instruments.swapAt(index, next); preferenceChanged()
    }
    func restoreAppearance() {
        preferences.menuStyle = .quotes
        preferences.menuLabel = "name"; preferences.menuContent = "change"; preferences.menuWidth = 180
        preferences.menuFontSize = 12; preferences.rotationSeconds = 8; preferences.compact = false
        preferences.glassEnabled = true
        preferences.showSource = true; preferences.monochrome = false; preferences.redIsUp = true; preferences.rotate = false
        preferenceChanged()
    }
    var menuTitle: String {
        guard let instrument = displayedInstrument else { return "StockBar" }
        return menuTitle(for: instrument)
    }
    func menuTitle(for instrument: Instrument) -> String {
        let quote = quotes[instrument.id]
        let fullName = instrument.name == instrument.code ? (quote?.name ?? instrument.name) : instrument.name
        var label = preferences.menuLabel == "none" ? "" : preferences.menuLabel == "code" ? instrument.code : String(fullName.prefix(8))
        let value: String
        if let quote {
            switch preferences.menuContent {
            case "price": value = price(quote, instrument: instrument)
            case "both": value = price(quote, instrument: instrument) + " " + percent(quote)
            default: value = percent(quote)
            }
        } else { value = "—" }
        let suffix = quote.map { isOld($0) ? " ·" : "" } ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(preferences.menuFontSize), weight: .medium)
        var shortened = false
        func composed() -> String { (label.isEmpty ? "" : label + (shortened ? "… " : " ")) + value + suffix }
        // Preserve numbers; never leave a misleading one-character instrument label.
        while !label.isEmpty && (composed() as NSString).size(withAttributes: [.font: font]).width > CGFloat(preferences.menuWidth - 16) {
            label.removeLast(); shortened = true
            if label.count < 2 { label = "" }
        }
        return composed()
    }
    func move(_ source: IndexSet, to destination: Int) { preferences.instruments.move(fromOffsets: source, toOffset: destination); preferenceChanged() }
    func search() {
        searchTask?.cancel(); searchResults = []; searchMessage = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                let result = try await engine.search(query, preferred: preferred, allowFallback: effectiveFallback)
                guard !Task.isCancelled else { return }
                searchResults = result
                searchMessage = result.isEmpty ? "没有找到 A 股或场内 ETF。也可输入六位代码；东方财富目前仅支持代码搜索。" : nil
            } catch {
                guard !Task.isCancelled else { return }
                searchMessage = "搜索失败：\(error.localizedDescription)。可输入六位代码稍后重试。"
            }
            searching = false
        }
    }
    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 StockBar。" : nil
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; loginMessage = error.localizedDescription }
    }
    func shutdown() { scheduler?.cancel(); activeFetch?.cancel(); searchTask?.cancel() }
    func sourceName(_ id: String) -> String { registry.descriptors.first(where: { $0.id == id })?.name ?? id }
    func isOld(_ quote: Quote) -> Bool {
        missingIDs.contains(quote.instrumentID) || MarketClock.isDelayed(quote, now: Date()) || Date().timeIntervalSince(quote.receivedAt) > (MarketClock.isLikelySession(Date()) ? 120 : 900)
    }
    func color(_ quote: Quote) -> Color {
        if preferences.monochrome || quote.changePercent == 0 { return .primary }
        return (quote.changePercent > 0) == preferences.redIsUp ? Color(red: 0.87, green: 0.24, blue: 0.27) : Color(red: 0.05, green: 0.57, blue: 0.40)
    }
    func price(_ quote: Quote, instrument: Instrument) -> String { format(quote.price, decimals: instrument.isETF ? 3 : 2) }
    func percent(_ quote: Quote) -> String { (quote.changePercent > 0 ? "+" : "") + format(quote.changePercent, decimals: 2) + "%" }
    func format(_ number: Decimal, decimals: Int) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals
        return f.string(from: NSDecimalNumber(decimal: number)) ?? "—"
    }
    func time(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = MarketClock.calendar.timeZone; f.dateFormat = MarketClock.calendar.isDate(date, inSameDayAs: Date()) ? "HH:mm:ss" : "MM-dd HH:mm"
        return f.string(from: date)
    }
}
