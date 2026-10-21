import Foundation
import Testing
import TokenBarCore
@testable import CodexTokenBar

struct CurrentMeasurementTests {
    @Test func repeatedReportResetClearsOnlyCurrentAndPreservesMetadata() throws {
        let originalStart = Date(timeIntervalSince1970: 1_790_000_000)
        let periods = Dictionary(uniqueKeysWithValues: UsagePeriod.allCases.enumerated().map { index, period in
            (period.rawValue, PeriodReport(period: period, totals: PeriodTotals(
                usage: TokenUsage(input: Int64(100 + index), cachedInput: 20, cacheWrite: 5,
                                  output: 30, reasoningOutput: 10),
                estimatedUSD: Double(index + 1), unpricedEvents: 2, unpricedTokens: 50)))
        })
        let original = UsageReport(scannedAt: originalStart.addingTimeInterval(10),
                                   currentStartedAt: originalStart, sources: ["/tmp/synthetic-codex"],
                                   indexedSessions: 3, scannedFiles: 4,
                                   pricingAsOf: "2026-09-24", pricingSource: "https://openai.com/api/pricing/",
                                   periods: periods, warnings: ["Synthetic warning"], indexWarningCount: 1)
        var report = original
        for resetAt in [originalStart.addingTimeInterval(20), originalStart.addingTimeInterval(21)] {
            report.resetCurrent(startedAt: resetAt)
            #expect(report.currentStartedAt == resetAt)
            let current = try #require(report.periods[UsagePeriod.current.rawValue])
            #expect(current.usage == .zero)
            #expect(current.totalTokens == 0)
            #expect(current.estimatedUSD == 0)
            #expect(current.unpricedEvents == 0)
            #expect(current.unpricedTokens == 0)
            #expect(current.display == "C: 0 / $0.00")
            for period in UsagePeriod.allCases where period != .current {
                #expect(try encoded(report.periods[period.rawValue]) == encoded(original.periods[period.rawValue]))
            }
            #expect(report.scannedAt == original.scannedAt)
            #expect(report.sources == original.sources)
            #expect(report.indexedSessions == original.indexedSessions)
            #expect(report.scannedFiles == original.scannedFiles)
            #expect(report.currency == original.currency)
            #expect(report.pricingBasis == original.pricingBasis)
            #expect(report.pricingAsOf == original.pricingAsOf)
            #expect(report.pricingSource == original.pricingSource)
            #expect(report.warnings == original.warnings)
            #expect(report.indexWarningCount == original.indexWarningCount)
        }
    }

    @Test func measurementCountsOnlyNewCumulativeDeltasAndIgnoresLateOldHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CurrentMeasurementTests-\(UUID().uuidString)", isDirectory: true)
        let home = directory.appendingPathComponent("codex", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AppConfiguration(codexHomes: [home], cacheURL: directory.appendingPathComponent("cache/index.json"),
                                             reportOnly: true, showHelp: false)
        let startedAt = Date().addingTimeInterval(-100)
        let session = sessions.appendingPathComponent("measurement.jsonl")
        try writeSession(id: "measurement", records: [
            try token(input: 100, output: 20, at: startedAt.addingTimeInterval(-10)),
            try token(input: 140, output: 30, at: startedAt.addingTimeInterval(10))
        ], to: session)
        let builder = ReportBuilder(configuration: configuration)
        let initial = try builder.scan(currentStartedAt: startedAt)
        #expect(initial.currentStartedAt == startedAt)
        #expect(initial.periods["current"]?.totalTokens == 50)
        #expect(initial.periods["current"]?.usage.input == 40)
        #expect(initial.periods["current"]?.usage.output == 10)
        #expect(initial.periods["overall"]?.totalTokens == 170)
        #expect(initial.warnings.isEmpty)

        try writeSession(id: "late-history", records: [
            try token(input: 50, output: 10, at: startedAt.addingTimeInterval(-5))
        ], to: sessions.appendingPathComponent("late-history.jsonl"))
        let withLateHistory = try builder.scan(currentStartedAt: startedAt)
        #expect(withLateHistory.periods["current"]?.totalTokens == 50)
        #expect(withLateHistory.periods["overall"]?.totalTokens == 230)
        let restarted = try ReportBuilder(configuration: configuration).scan(currentStartedAt: startedAt)
        #expect(restarted.periods["current"]?.totalTokens == 50)

        let nextStart = startedAt.addingTimeInterval(20)
        let reset = try builder.scan(currentStartedAt: nextStart)
        #expect(reset.periods["current"]?.totalTokens == 0)
        #expect(reset.periods["overall"]?.totalTokens == 230)
        let handle = try FileHandle(forWritingTo: session)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try token(input: 150, output: 32,
                                                    at: startedAt.addingTimeInterval(30)) + "\n").utf8))
        let nextMeasurement = try builder.scan(currentStartedAt: nextStart)
        #expect(nextMeasurement.periods["current"]?.totalTokens == 12)
        #expect(nextMeasurement.periods["overall"]?.totalTokens == 242)

        let withoutStart = try builder.scan()
        #expect(withoutStart.currentStartedAt == nil)
        #expect(withoutStart.periods["current"]?.totalTokens == 0)
        #expect(withoutStart.periods["overall"]?.totalTokens == 242)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func writeSession(id: String, records: [String], to url: URL) throws {
        let metadata = try json(["type": "session_meta", "payload": ["id": id, "model": "gpt-6-astra"]])
        try Data(([metadata] + records).joined(separator: "\n").appending("\n").utf8).write(to: url)
    }

    private func token(input: Int, output: Int, at timestamp: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try json(["type": "event_msg", "timestamp": formatter.string(from: timestamp), "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "output_tokens": output]]
        ]])
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
