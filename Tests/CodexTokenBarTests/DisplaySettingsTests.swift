import Foundation
import Testing
import TokenBarCore
@testable import CodexTokenBar

struct DisplaySettingsTests {
    @Test func startsWithDailyTokensAndDollarsEnabled() throws {
        try withSettings { settings, _ in
            #expect(settings.selectedPeriod == .daily)
            #expect(settings.showTokens)
            #expect(settings.showDollars)
            #expect(settings.canToggleTokens)
            #expect(settings.canToggleDollars)
        }
    }

    @Test func everyPeriodSelectionSurvivesReload() throws {
        try withSettings { settings, defaults in
            for period in UsagePeriod.allCases {
                settings.select(period)
                let reloaded = DisplaySettings(defaults: defaults)
                #expect(reloaded.selectedPeriod == period)
            }
        }
    }

    @Test func tokensOnlyPersistsAndCannotBeTurnedOff() throws {
        try withSettings { settings, defaults in
            let dollarsChanged = settings.toggleDollars()
            #expect(dollarsChanged)
            #expect(settings.showTokens)
            #expect(!settings.showDollars)
            #expect(!settings.canToggleTokens)
            let tokensChanged = settings.toggleTokens()
            #expect(!tokensChanged)
            let reloaded = DisplaySettings(defaults: defaults)
            #expect(reloaded.showTokens)
            #expect(!reloaded.showDollars)
            #expect(reloaded.canToggleDollars)
        }
    }

    @Test func dollarsOnlyPersistsAndCannotBeTurnedOff() throws {
        try withSettings { settings, defaults in
            let tokensChanged = settings.toggleTokens()
            #expect(tokensChanged)
            #expect(!settings.showTokens)
            #expect(settings.showDollars)
            #expect(!settings.canToggleDollars)
            let dollarsChanged = settings.toggleDollars()
            #expect(!dollarsChanged)
            let reloaded = DisplaySettings(defaults: defaults)
            #expect(!reloaded.showTokens)
            #expect(reloaded.showDollars)
            #expect(reloaded.canToggleTokens)
        }
    }

    @Test func canReenableBothFromEitherSingleDisplay() throws {
        try withSettings { settings, defaults in
            settings.toggleTokens()
            let tokensChanged = settings.toggleTokens()
            #expect(tokensChanged)
            settings.toggleDollars()
            let dollarsChanged = settings.toggleDollars()
            #expect(dollarsChanged)
            let reloaded = DisplaySettings(defaults: defaults)
            #expect(reloaded.showTokens)
            #expect(reloaded.showDollars)
        }
    }

    @Test func fourRowsUseTheSameDisplaySelectionAndExactLabels() throws {
        try withSettings { settings, _ in
            let labels: [UsagePeriod: String] = [.daily: "D", .weekly: "W", .monthly: "M", .overall: "O"]
            let menuLabels: [UsagePeriod: String] = [.daily: "Day", .weekly: "Week", .monthly: "Month", .overall: "Overall"]
            for period in UsagePeriod.allCases {
                #expect(settings.title(for: period, totals: fixture(period)) == "\(labels[period]!): 12.3M / $4.56")
                #expect(settings.title(for: period, totals: fixture(period), expanded: true) == "\(menuLabels[period]!): 12.3M / $4.56")
            }
            settings.toggleDollars()
            for period in UsagePeriod.allCases {
                #expect(settings.title(for: period, totals: fixture(period)) == "\(labels[period]!): 12.3M")
                #expect(settings.title(for: period, totals: fixture(period), expanded: true) == "\(menuLabels[period]!): 12.3M")
            }
            settings.toggleDollars()
            settings.toggleTokens()
            for period in UsagePeriod.allCases {
                #expect(settings.title(for: period, totals: fixture(period)) == "\(labels[period]!): $4.56")
                #expect(settings.title(for: period, totals: fixture(period), expanded: true) == "\(menuLabels[period]!): $4.56")
            }
        }
    }

    @Test func unknownPricesRemainVisibleWheneverDollarsAreVisible() throws {
        try withSettings { settings, _ in
            let value = fixture(.daily, unpriced: true)
            #expect(settings.title(for: .daily, totals: value) == "D: 12.3M / $4.56 + ?")
            #expect(settings.title(for: .daily, totals: value, expanded: true) == "Day: 12.3M / $4.56 + ?")
            settings.toggleTokens()
            #expect(settings.title(for: .daily, totals: value) == "D: $4.56 + ?")
            #expect(settings.title(for: .daily, totals: value, expanded: true) == "Day: $4.56 + ?")
            settings.toggleTokens()
            settings.toggleDollars()
            #expect(settings.title(for: .daily, totals: value) == "D: 12.3M")
            #expect(settings.title(for: .daily, totals: value, expanded: true) == "Day: 12.3M")
        }
    }

    @Test func loadingAndErrorPlaceholdersRespectSelection() throws {
        try withSettings { settings, _ in
            #expect(settings.placeholderTitle(for: .weekly, hasError: false) == "W: … / …")
            #expect(settings.placeholderTitle(for: .weekly, hasError: true) == "W: — / ?")
            settings.toggleTokens()
            #expect(settings.placeholderTitle(for: .monthly, hasError: true) == "M: ?")
            settings.toggleTokens()
            settings.toggleDollars()
            #expect(settings.placeholderTitle(for: .overall, hasError: false) == "O: …")
        }
    }

    @Test func menuPlaceholdersUseFullLabelsForEveryDisplaySelection() throws {
        try withSettings { settings, _ in
            let labels: [UsagePeriod: String] = [.daily: "Day", .weekly: "Week", .monthly: "Month", .overall: "Overall"]
            for period in UsagePeriod.allCases {
                #expect(settings.placeholderTitle(for: period, hasError: false, expanded: true) == "\(labels[period]!): … / …")
                #expect(settings.placeholderTitle(for: period, hasError: true, expanded: true) == "\(labels[period]!): — / ?")
            }
            settings.toggleTokens()
            for period in UsagePeriod.allCases {
                #expect(settings.placeholderTitle(for: period, hasError: false, expanded: true) == "\(labels[period]!): …")
                #expect(settings.placeholderTitle(for: period, hasError: true, expanded: true) == "\(labels[period]!): ?")
            }
            settings.toggleTokens()
            settings.toggleDollars()
            for period in UsagePeriod.allCases {
                #expect(settings.placeholderTitle(for: period, hasError: false, expanded: true) == "\(labels[period]!): …")
                #expect(settings.placeholderTitle(for: period, hasError: true, expanded: true) == "\(labels[period]!): —")
            }
        }
    }

    private func withSettings(_ body: (inout DisplaySettings, UserDefaults) throws -> Void) throws {
        let domain = "CodexTokenBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var settings = DisplaySettings(defaults: defaults)
        try body(&settings, defaults)
    }

    private func fixture(_ period: UsagePeriod, unpriced: Bool = false) -> PeriodReport {
        PeriodReport(period: period, totals: PeriodTotals(usage: TokenUsage(total: 12_300_000),
                                                          estimatedUSD: 4.56,
                                                          unpricedEvents: unpriced ? 2 : 0,
                                                          unpricedTokens: unpriced ? 100 : 0))
    }
}
