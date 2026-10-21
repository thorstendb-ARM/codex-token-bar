import Foundation
import Testing
@testable import TokenBarCore

struct AggregationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func event(_ id: String, at time: String, model: String? = "gpt-6-astra",
                       usage: TokenUsage = TokenUsage(input: 100, output: 10)) -> UsageEvent {
        UsageEvent(id: id, timestamp: date(time), model: model, usage: usage)
    }

    @Test func localDayWeekMonthAndOverallBoundaries() throws {
        let now = date("2026-09-24T13:00:00Z")
        let events = [
            event("old", at: "2026-08-31T21:59:59Z"),
            event("month", at: "2026-08-31T22:00:00Z"),
            event("sunday", at: "2026-09-20T21:59:59Z"),
            event("monday", at: "2026-09-20T22:00:00Z"),
            event("yesterday", at: "2026-09-23T21:59:59Z"),
            event("today", at: "2026-09-23T22:00:00Z"),
            event("now", at: "2026-09-24T13:00:00Z"),
            event("future", at: "2026-09-24T13:00:01Z"),
        ]
        let totals = UsageAggregator.summarize(
            UsageSnapshot(events: events, indexedSessions: 1, scannedFiles: 1),
            prices: try .bundled(), now: now, calendar: calendar)
        #expect(totals[.daily]?.usage.total == 220)
        #expect(totals[.weekly]?.usage.total == 440)
        #expect(totals[.monthly]?.usage.total == 660)
        #expect(totals[.overall]?.usage.total == 770)
        #expect(totals[.current]?.usage == .zero)
        #expect(totals[.current]?.estimatedUSD == 0)
        #expect(totals[.current]?.unpricedEvents == 0)
    }

    @Test func mondayWeekAtYearBoundaryAndDST() {
        #expect(UsagePeriod.weekly.start(now: date("2027-01-01T12:00:00Z"), calendar: calendar)
                == date("2026-12-27T23:00:00Z"))
        // Daylight-saving time ends on this Sunday: day starts with summer time.
        #expect(UsagePeriod.daily.start(now: date("2026-10-25T15:00:00Z"), calendar: calendar)
                == date("2026-10-24T22:00:00Z"))
    }

    @Test func duplicateIDsCountOnceButIndependentSessionsCount() throws {
        let first = event("parent:1", at: "2026-09-24T12:00:00Z")
        let child = event("child:1", at: "2026-09-24T12:00:00Z")
        let result = UsageAggregator.summarize(
            UsageSnapshot(events: [first, first, child], indexedSessions: 2, scannedFiles: 3),
            prices: try .bundled(), now: date("2026-09-24T13:00:00Z"), calendar: calendar,
            currentStartedAt: date("2026-09-24T12:00:00Z"))
        #expect(result[.daily]?.usage.total == 220)
        #expect(result[.current]?.usage.total == 220)
    }

    @Test func unknownModelKeepsTokensButReportsUnpricedCost() throws {
        let known = event("known", at: "2026-09-24T12:00:00Z")
        let unknown = event("unknown", at: "2026-09-24T12:00:00Z", model: "private-model")
        let result = UsageAggregator.summarize(
            UsageSnapshot(events: [known, unknown], indexedSessions: 1, scannedFiles: 1),
            prices: try .bundled(), now: date("2026-09-24T13:00:00Z"), calendar: calendar,
            currentStartedAt: date("2026-09-24T12:00:00Z"))
        #expect(result[.daily]?.usage.total == 220)
        #expect(result[.daily]?.unpricedTokens == 110)
        #expect(result[.daily]?.unpricedEvents == 1)
        #expect(abs(result[.daily]!.estimatedUSD - 0.0015) < 0.00000001)
        #expect(result[.current]?.usage.total == 220)
        #expect(result[.current]?.unpricedTokens == 110)
        #expect(result[.current]?.unpricedEvents == 1)
        #expect(abs(result[.current]!.estimatedUSD - 0.0015) < 0.00000001)
    }

    @Test func currentIncludesResetAndNowButExcludesOlderAndFutureEvents() throws {
        let start = date("2026-09-24T12:00:00Z")
        let now = date("2026-09-24T13:00:00Z")
        let snapshot = UsageSnapshot(events: [
            event("before", at: "2026-09-24T11:59:59Z"),
            event("reset", at: "2026-09-24T12:00:00Z"),
            event("after", at: "2026-09-24T12:30:00Z"),
            event("now", at: "2026-09-24T13:00:00Z"),
            event("future", at: "2026-09-24T13:00:01Z"),
        ], indexedSessions: 1, scannedFiles: 1)
        let prices = try PriceBook.bundled()
        let beforeReset = UsageAggregator.summarize(snapshot, prices: prices, now: now,
            calendar: calendar, currentStartedAt: start)
        let afterReset = UsageAggregator.summarize(snapshot, prices: prices, now: now,
            calendar: calendar, currentStartedAt: now)

        #expect(beforeReset[.current]?.usage.total == 330)
        #expect(afterReset[.current]?.usage.total == 110)
        for period in [UsagePeriod.daily, .weekly, .monthly, .overall] {
            #expect(beforeReset[period]?.usage.total == 440)
            #expect(afterReset[period]?.usage == beforeReset[period]?.usage)
            #expect(afterReset[period]?.estimatedUSD == beforeReset[period]?.estimatedUSD)
        }
    }

    @Test func currentContinuesAcrossDaysWeeksMonthsAndDaylightSavingTime() throws {
        let start = date("2026-09-30T21:00:00Z")
        let now = date("2026-11-02T12:00:00Z")
        let snapshot = UsageSnapshot(events: [
            event("before", at: "2026-09-30T20:59:59Z"),
            event("reset", at: "2026-09-30T21:00:00Z"),
            event("october", at: "2026-10-01T12:00:00Z"),
            event("summer-time", at: "2026-10-25T00:30:00Z"),
            event("winter-time", at: "2026-10-25T01:30:00Z"),
            event("sunday", at: "2026-11-01T12:00:00Z"),
            event("now", at: "2026-11-02T12:00:00Z"),
        ], indexedSessions: 1, scannedFiles: 1)
        let totals = UsageAggregator.summarize(snapshot, prices: try .bundled(), now: now,
            calendar: calendar, currentStartedAt: start)

        #expect(UsagePeriod.current.start(now: now, calendar: calendar,
            currentStartedAt: start) == start)
        #expect(totals[.current]?.usage.total == 660)
        #expect(totals[.daily]?.usage.total == 110)
        #expect(totals[.weekly]?.usage.total == 110)
        #expect(totals[.monthly]?.usage.total == 220)
        #expect(totals[.overall]?.usage.total == 770)
    }

    @Test func currentUsesAbsoluteResetTimeDuringRepeatedLocalHour() throws {
        let snapshot = UsageSnapshot(events: [
            event("before-reset", at: "2026-10-25T00:30:00Z"),
            event("after-reset", at: "2026-10-25T01:30:00Z"),
        ], indexedSessions: 1, scannedFiles: 1)
        // Both events occur at 02:30 locally; the reset is at 02:15 after the clock change.
        let totals = UsageAggregator.summarize(snapshot, prices: try .bundled(),
            now: date("2026-10-25T02:00:00Z"), calendar: calendar,
            currentStartedAt: date("2026-10-25T01:15:00Z"))

        #expect(totals[.current]?.usage.total == 110)
        #expect(totals[.daily]?.usage.total == 220)
    }

    @Test func currentWithoutStartOrWithFutureStartRemainsZero() throws {
        let now = date("2026-09-24T13:00:00Z")
        let snapshot = UsageSnapshot(events: [
            event("known", at: "2026-09-24T12:00:00Z"),
            event("unknown", at: "2026-09-24T12:00:00Z", model: nil),
            event("future", at: "2026-09-24T14:00:00Z"),
        ], indexedSessions: 1, scannedFiles: 1)
        let starts: [Date?] = [nil, date("2026-09-24T14:00:00Z")]
        for start in starts {
            let totals = UsageAggregator.summarize(snapshot, prices: try .bundled(), now: now,
                calendar: calendar, currentStartedAt: start)
            #expect(totals[.current]?.usage == .zero)
            #expect(totals[.current]?.estimatedUSD == 0)
            #expect(totals[.current]?.unpricedEvents == 0)
            #expect(totals[.current]?.unpricedTokens == 0)
            #expect(totals[.overall]?.usage.total == 220)
        }
    }

    @Test func emptySnapshot() throws {
        let result = UsageAggregator.summarize(
            UsageSnapshot(events: [], indexedSessions: 0, scannedFiles: 0), prices: try .bundled())
        #expect(result.count == 5)
        for total in result.values {
            #expect(total.usage.total == 0)
            #expect(total.estimatedUSD == 0)
        }
    }

    @Test func requiredPeriodLabels() {
        #expect(UsagePeriod.allCases.map(\.shortTitle) == ["C", "D", "W", "M", "O"])
        #expect(UsagePeriod.allCases.map(\.menuTitle) == ["Current", "Day", "Week", "Month", "Overall"])
    }
}
