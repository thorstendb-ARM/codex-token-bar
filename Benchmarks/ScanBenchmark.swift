import Darwin
import Foundation
import TokenBarCore

/// Uses only the original ReportBuilder API so the same fixture can compare checkouts.
@main
struct ScanBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count <= 2,
              let sessions = Int(arguments.first ?? "2000"), sessions > 0,
              let events = Int(arguments.dropFirst().first ?? "100"), events > 0,
              Int64(sessions) <= (Int64.max / 12 - 1) / Int64(events) else {
            throw ConfigurationError.message("Expected positive session and event counts (defaults: 2000 100).")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("CodexTokenBarBenchmark-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        let home = directory.appendingPathComponent("codex", isDirectory: true)
        let logs = home.appendingPathComponent("sessions", isDirectory: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        let records = (1...events).map(tokenLine).joined()
        for session in 0..<sessions {
            let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"benchmark-session-\(session)\",\"model\":\"gpt-6-astra\"}}\n"
            try Data((metadata + records).utf8).write(to: logs.appendingPathComponent("session-\(session).jsonl"))
        }

        let builder = ReportBuilder(configuration: AppConfiguration(
            codexHomes: [home], cacheURL: directory.appendingPathComponent("cache/index.json"),
            reportOnly: true, showHelp: false))
        let total = Int64(sessions) * Int64(events) * 12
        print("Synthetic history: \(sessions) sessions, \(sessions * events) events, \(total) tokens")
        try measure("cold", builder: builder, expectedTokens: total)
        for index in 1...3 {
            try measure("idle \(index)", builder: builder, expectedTokens: total)
        }

        let handle = try FileHandle(forWritingTo: logs.appendingPathComponent("session-0.jsonl"))
        do {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(tokenLine(events + 1).utf8))
        }
        try measure("append", builder: builder, expectedTokens: total + 12)
        try measure("idle after append", builder: builder, expectedTokens: total + 12)
    }

    private static func tokenLine(_ count: Int) -> String {
        "{\"type\":\"event_msg\",\"timestamp\":\"2020-01-01T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(count * 10),\"output_tokens\":\(count * 2)}}}}\n"
    }

    private static func measure(_ label: String, builder: ReportBuilder, expectedTokens: Int64) throws {
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = clock()
        let report = try builder.scan()
        let cpuMilliseconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1_000
        let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - wallStart) * 1_000
        guard report.periods["overall"]?.totalTokens == expectedTokens, report.indexWarningCount == 0 else {
            throw ConfigurationError.message("\(label): totals or index warnings failed validation.")
        }
        print(label.padding(toLength: 18, withPad: " ", startingAt: 0)
            + String(format: "wall %10.3f ms   CPU %10.3f ms", locale: Locale(identifier: "en_US_POSIX"),
                     wallMilliseconds, cpuMilliseconds))
    }
}
