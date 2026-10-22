import Foundation
import Testing
import TokenBarCore
@testable import CodexTokenBar

struct ReportCachingTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func event(_ id: String, at value: String, model: String? = "gpt-6-astra") -> UsageEvent {
        UsageEvent(id: id, timestamp: date(value), model: model, usage: TokenUsage(input: 100, output: 10))
    }

    @Test func stableRevisionStillUpdatesDayWeekMonthAndTimeZone() throws {
        let cache = PeriodReportCache(prices: try .bundled())
        var snapshot = UsageSnapshot(events: [
            event("september", at: "2026-09-30T21:59:00Z"),
            event("october", at: "2026-10-01T12:00:00Z"),
            event("sunday", at: "2026-10-04T21:59:00Z"),
        ], indexedSessions: 1, scannedFiles: 1, eventsRevision: 1)
        snapshot.scannedAt = date("2026-10-04T21:59:30Z")
        let before = cache.reports(for: snapshot, calendar: calendar)
        #expect(before["daily"]?.totalTokens == 110)
        #expect(before["weekly"]?.totalTokens == 330)
        #expect(before["monthly"]?.totalTokens == 220)

        snapshot.scannedAt = date("2026-10-04T22:00:00Z")
        let monday = cache.reports(for: snapshot, calendar: calendar)
        #expect(monday["daily"]?.totalTokens == 0)
        #expect(monday["weekly"]?.totalTokens == 0)
        #expect(monday["monthly"]?.totalTokens == 220)
        #expect(monday["overall"]?.totalTokens == 330)

        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let movedTimeZone = cache.reports(for: snapshot, calendar: utc)
        #expect(movedTimeZone["daily"]?.totalTokens == 110)
        #expect(movedTimeZone["weekly"]?.totalTokens == 330)

        snapshot.scannedAt = date("2026-10-31T23:00:00Z")
        let november = cache.reports(for: snapshot, calendar: calendar)
        #expect(november["monthly"]?.totalTokens == 0)
        #expect(november["overall"]?.totalTokens == 330)
    }

    @Test func futureRecordsBecomeEligibleWithoutChangingRevisionAndClockRollbackRemovesThem() throws {
        let cache = PeriodReportCache(prices: try .bundled())
        var snapshot = UsageSnapshot(events: [
            event("past", at: "2026-10-22T12:00:00Z"),
            event("future", at: "2026-10-22T12:00:20Z", model: "unknown-model"),
        ], indexedSessions: 1, scannedFiles: 1, eventsRevision: 1)
        for (time, tokens, unpriced) in [
            ("2026-10-22T12:00:10Z", Int64(110), 0),
            ("2026-10-22T12:00:19Z", Int64(110), 0),
            ("2026-10-22T12:00:20Z", Int64(220), 1),
            ("2026-10-22T12:00:21Z", Int64(220), 1),
            ("2026-10-22T12:00:19Z", Int64(110), 0),
        ] {
            snapshot.scannedAt = date(time)
            let report = cache.reports(for: snapshot, calendar: calendar)
            #expect(report["overall"]?.totalTokens == tokens)
            #expect(report["overall"]?.unpricedEvents == unpriced)
        }
    }

    @Test func currentResetAndAbsentRevisionCannotReturnStaleTotals() throws {
        let cache = PeriodReportCache(prices: try .bundled())
        var snapshot = UsageSnapshot(events: [
            event("first", at: "2026-10-22T12:00:00Z"),
            event("second", at: "2026-10-22T12:00:20Z"),
        ], indexedSessions: 1, scannedFiles: 1,
           scannedAt: date("2026-10-22T13:00:00Z"), eventsRevision: 1)
        let initial = cache.reports(for: snapshot, currentStartedAt: date("2026-10-22T12:00:00Z"), calendar: calendar)
        #expect(initial["current"]?.totalTokens == 220)
        let reset = cache.reports(for: snapshot, currentStartedAt: date("2026-10-22T12:00:20Z"), calendar: calendar)
        #expect(reset["current"]?.totalTokens == 110)
        #expect(reset["overall"]?.totalTokens == 220)
        #expect(cache.reports(for: snapshot, calendar: calendar)["current"]?.totalTokens == 0)

        snapshot.events.append(event("third", at: "2026-10-22T12:01:00Z"))
        snapshot.eventsRevision = 2
        #expect(cache.reports(for: snapshot, calendar: calendar)["overall"]?.totalTokens == 330)
        snapshot.eventsRevision = nil
        #expect(cache.reports(for: snapshot, calendar: calendar)["overall"]?.totalTokens == 330)
        snapshot.events.append(event("fourth", at: "2026-10-22T12:02:00Z"))
        #expect(cache.reports(for: snapshot, calendar: calendar)["overall"]?.totalTokens == 440)
    }
}
