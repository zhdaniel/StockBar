import Foundation

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case quotes
    case icon
}

public struct Preferences: Codable {
    public var instruments: [Instrument] = Instrument.defaults
    public var pinnedID = Instrument.defaults[0].id
    public var preferredSource = "auto"
    public var allowFallback = true
    public var interval = 10
    public var showPrice = false // retained for migration from 0.1
    public var monochrome = false
    public var redIsUp = true
    public var rotate = false
    public var menuStyle: MenuBarStyle = .quotes
    public var menuLabel = "name"
    public var menuContent = "change"
    public var menuWidth = 180
    public var menuFontSize = 12
    public var rotationSeconds = 8
    public var compact = false
    public var showSource = true
    public var glassEnabled = true
    public var islandEnabled = false
    public var islandGap = 0
    public init() {}
    enum CodingKeys: String, CodingKey {
        case instruments, pinnedID, preferredSource, allowFallback, interval, showPrice, monochrome, redIsUp, rotate
        case islandEnabled, islandGap
        case menuStyle, menuLabel, menuContent, menuWidth, menuFontSize, rotationSeconds, compact, showSource, glassEnabled
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instruments = try c.decodeIfPresent([Instrument].self, forKey: .instruments) ?? instruments
        pinnedID = try c.decodeIfPresent(String.self, forKey: .pinnedID) ?? pinnedID
        preferredSource = try c.decodeIfPresent(String.self, forKey: .preferredSource) ?? preferredSource
        allowFallback = try c.decodeIfPresent(Bool.self, forKey: .allowFallback) ?? allowFallback
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? interval
        showPrice = try c.decodeIfPresent(Bool.self, forKey: .showPrice) ?? showPrice
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? monochrome
        redIsUp = try c.decodeIfPresent(Bool.self, forKey: .redIsUp) ?? redIsUp
        rotate = try c.decodeIfPresent(Bool.self, forKey: .rotate) ?? rotate
        menuStyle = (try c.decodeIfPresent(String.self, forKey: .menuStyle)).flatMap(MenuBarStyle.init(rawValue:)) ?? .quotes
        menuLabel = try c.decodeIfPresent(String.self, forKey: .menuLabel) ?? menuLabel
        menuContent = try c.decodeIfPresent(String.self, forKey: .menuContent) ?? (showPrice ? "both" : "change")
        menuWidth = try c.decodeIfPresent(Int.self, forKey: .menuWidth) ?? menuWidth
        menuFontSize = try c.decodeIfPresent(Int.self, forKey: .menuFontSize) ?? menuFontSize
        rotationSeconds = try c.decodeIfPresent(Int.self, forKey: .rotationSeconds) ?? rotationSeconds
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? compact
        showSource = try c.decodeIfPresent(Bool.self, forKey: .showSource) ?? showSource
        islandEnabled = try c.decodeIfPresent(Bool.self, forKey: .islandEnabled) ?? false
        islandGap = max(0, min(48, try c.decodeIfPresent(Int.self, forKey: .islandGap) ?? 0))
        glassEnabled = try c.decodeIfPresent(Bool.self, forKey: .glassEnabled) ?? glassEnabled
    }
}
