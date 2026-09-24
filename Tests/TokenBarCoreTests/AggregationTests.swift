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
            prices: try .bundled(), now: date("2026-09-24T13:00:00Z"), calendar: calendar)
        #expect(result[.daily]?.usage.total == 220)
    }

    @Test func unknownModelKeepsTokensButReportsUnpricedCost() throws {
        let known = event("known", at: "2026-09-24T12:00:00Z")
        let unknown = event("unknown", at: "2026-09-24T12:00:00Z", model: "private-model")
        let result = UsageAggregator.summarize(
            UsageSnapshot(events: [known, unknown], indexedSessions: 1, scannedFiles: 1),
            prices: try .bundled(), now: date("2026-09-24T13:00:00Z"), calendar: calendar)
        #expect(result[.daily]?.usage.total == 220)
        #expect(result[.daily]?.unpricedTokens == 110)
        #expect(result[.daily]?.unpricedEvents == 1)
        #expect(abs(result[.daily]!.estimatedUSD - 0.0015) < 0.00000001)
    }

    @Test func emptySnapshot() throws {
        let result = UsageAggregator.summarize(
            UsageSnapshot(events: [], indexedSessions: 0, scannedFiles: 0), prices: try .bundled())
        #expect(result.count == 4)
        for total in result.values {
            #expect(total.usage.total == 0)
            #expect(total.estimatedUSD == 0)
        }
    }

    @Test func requiredPeriodLabels() {
        #expect(UsagePeriod.allCases.map(\.shortTitle) == ["D", "W", "M", "O"])
    }
}
