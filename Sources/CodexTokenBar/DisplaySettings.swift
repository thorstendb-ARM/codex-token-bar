import Foundation
import TokenBarCore

/// The user's menu selection, independent of AppKit and the indexing lifecycle.
struct DisplaySettings {
    // Keep the bundled app and the standalone --report command in the same domain.
    static let applicationDefaults: UserDefaults = {
        let applicationID = "de.thorsten-debuhr.CodexTokenBar"
        if Bundle.main.bundleIdentifier == applicationID { return .standard }
        return UserDefaults(suiteName: applicationID) ?? .standard
    }()
    private static let periodKey = "selectedPeriod"
    private static let tokensKey = "showTokens"
    private static let dollarsKey = "showDollars"
    private static let currentStartedAtKey = "currentStartedAt"

    private let defaults: UserDefaults
    private(set) var selectedPeriod: UsagePeriod
    private(set) var showTokens: Bool
    private(set) var showDollars: Bool
    private(set) var currentStartedAt: Date

    init(defaults: UserDefaults = applicationDefaults, now: Date = Date()) {
        self.defaults = defaults
        if let startedAt = Self.storedCurrentStartedAt(defaults: defaults) {
            currentStartedAt = startedAt
        } else {
            currentStartedAt = now
            defaults.set(now, forKey: Self.currentStartedAtKey)
        }
        selectedPeriod = defaults.string(forKey: Self.periodKey)
            .flatMap(UsagePeriod.init(rawValue:)) ?? .daily
        showTokens = defaults.object(forKey: Self.tokensKey) == nil || defaults.bool(forKey: Self.tokensKey)
        showDollars = defaults.object(forKey: Self.dollarsKey) == nil || defaults.bool(forKey: Self.dollarsKey)
        if !showTokens && !showDollars {
            showTokens = true
            defaults.set(true, forKey: Self.tokensKey)
        }
    }

    var canToggleTokens: Bool { !showTokens || showDollars }
    var canToggleDollars: Bool { !showDollars || showTokens }

    static func storedCurrentStartedAt(defaults: UserDefaults = applicationDefaults) -> Date? {
        defaults.object(forKey: currentStartedAtKey) as? Date
    }

    mutating func resetCurrent(now: Date = Date()) {
        currentStartedAt = now
        defaults.set(now, forKey: Self.currentStartedAtKey)
        select(.current)
    }

    mutating func select(_ period: UsagePeriod) {
        selectedPeriod = period
        defaults.set(period.rawValue, forKey: Self.periodKey)
    }

    @discardableResult
    mutating func toggleTokens() -> Bool {
        guard canToggleTokens else { return false }
        showTokens.toggle()
        defaults.set(showTokens, forKey: Self.tokensKey)
        return true
    }

    @discardableResult
    mutating func toggleDollars() -> Bool {
        guard canToggleDollars else { return false }
        showDollars.toggle()
        defaults.set(showDollars, forKey: Self.dollarsKey)
        return true
    }

    func title(for period: UsagePeriod, totals: PeriodReport, expanded: Bool = false) -> String {
        UsageFormatting.title(period: period, tokens: totals.totalTokens,
                              estimatedUSD: totals.estimatedUSD, unpricedEvents: totals.unpricedEvents,
                              showTokens: showTokens, showDollars: showDollars, expanded: expanded)
    }

    func placeholderTitle(for period: UsagePeriod, hasError: Bool, expanded: Bool = false) -> String {
        var values: [String] = []
        if showTokens { values.append(hasError ? "—" : "…") }
        if showDollars { values.append(hasError ? "?" : "…") }
        let label = expanded ? period.menuTitle : period.shortTitle
        return "\(label): \(values.joined(separator: " / "))"
    }
}
