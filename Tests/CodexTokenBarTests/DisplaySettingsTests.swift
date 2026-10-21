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

    @Test func currentStartsOnceAndSurvivesReloadAcrossCalendarPeriods() throws {
        try withDefaults { defaults, _ in
            let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
            let initial = DisplaySettings(defaults: defaults, now: startedAt)
            #expect(initial.currentStartedAt == startedAt)
            #expect(DisplaySettings.storedCurrentStartedAt(defaults: defaults) == startedAt)

            let nextMonth = startedAt.addingTimeInterval(40 * 24 * 60 * 60)
            let reloaded = DisplaySettings(defaults: defaults, now: nextMonth)
            #expect(reloaded.currentStartedAt == startedAt)
            #expect(DisplaySettings.storedCurrentStartedAt(defaults: defaults) == startedAt)
        }
    }

    @Test func resetCurrentPersistsLatestStartAndSelectsCurrentWithoutChangingDisplay() throws {
        try withSettings { settings, defaults in
            settings.select(.weekly)
            settings.toggleDollars()
            let firstReset = settings.currentStartedAt.addingTimeInterval(10)
            settings.resetCurrent(now: firstReset)
            #expect(settings.currentStartedAt == firstReset)
            #expect(settings.selectedPeriod == .current)
            #expect(settings.showTokens)
            #expect(!settings.showDollars)

            let latestReset = firstReset.addingTimeInterval(1)
            settings.resetCurrent(now: latestReset)
            let reloaded = DisplaySettings(defaults: defaults, now: latestReset.addingTimeInterval(100))
            #expect(reloaded.currentStartedAt == latestReset)
            #expect(reloaded.selectedPeriod == .current)
            #expect(reloaded.showTokens)
            #expect(!reloaded.showDollars)
        }
    }

    @Test func reportReadDoesNotStartMeasurementOrChangeStoredPreferences() throws {
        try withDefaults { defaults, domain in
            defaults.set("weekly", forKey: "selectedPeriod")
            let before = defaults.persistentDomain(forName: domain) ?? [:]
            #expect(DisplaySettings.storedCurrentStartedAt(defaults: defaults) == nil)
            #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: before))

            let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
            _ = DisplaySettings(defaults: defaults, now: startedAt)
            let initialized = defaults.persistentDomain(forName: domain) ?? [:]
            #expect(DisplaySettings.storedCurrentStartedAt(defaults: defaults) == startedAt)
            #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: initialized))
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

    @Test func fiveRowsStartWithCurrentAndUseTheSameDisplaySelectionAndExactLabels() throws {
        try withSettings { settings, _ in
            #expect(UsagePeriod.allCases == [.current, .daily, .weekly, .monthly, .overall])
            let labels: [UsagePeriod: String] = [.current: "C", .daily: "D", .weekly: "W", .monthly: "M", .overall: "O"]
            let menuLabels: [UsagePeriod: String] = [.current: "Current", .daily: "Day", .weekly: "Week", .monthly: "Month", .overall: "Overall"]
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
            let labels: [UsagePeriod: String] = [.current: "Current", .daily: "Day", .weekly: "Week", .monthly: "Month", .overall: "Overall"]
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
        try withDefaults { defaults, _ in
            var settings = DisplaySettings(defaults: defaults, now: Date(timeIntervalSince1970: 1_790_000_000))
            try body(&settings, defaults)
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let domain = "CodexTokenBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, domain)
    }

    private func fixture(_ period: UsagePeriod, unpriced: Bool = false) -> PeriodReport {
        PeriodReport(period: period, totals: PeriodTotals(usage: TokenUsage(total: 12_300_000),
                                                          estimatedUSD: 4.56,
                                                          unpricedEvents: unpriced ? 2 : 0,
                                                          unpricedTokens: unpriced ? 100 : 0))
    }
}
