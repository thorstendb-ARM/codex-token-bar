import Foundation
import Testing
import TokenBarCore
@testable import CodexTokenBar

struct CommandLineTests {
    @Test func reportUsesExplicitHomesAndCacheInsteadOfEnvironment() throws {
        let configuration = try AppConfiguration.parse([
            "--report", "--codex-home", "/tmp/token-home-a", "--codex-home", "/tmp/token-home-b",
            "--cache", "/tmp/token-cache.json"
        ], environment: ["CODEX_HOME": "/tmp/ignored-home"])
        #expect(configuration.reportOnly)
        #expect(configuration.codexHomes.map(\.path) == ["/tmp/token-home-a", "/tmp/token-home-b"])
        #expect(configuration.cacheURL.path == "/tmp/token-cache.json")
    }

    @Test func usesCodexHomeEnvironmentWhenNoOverrideIsPresent() throws {
        let configuration = try AppConfiguration.parse([], environment: ["CODEX_HOME": "/tmp/environment-home"])
        #expect(configuration.codexHomes.map(\.path) == ["/tmp/environment-home"])
        #expect(!configuration.reportOnly)
    }

    @Test func rejectsUnknownArgumentsAndMissingPaths() {
        #expect(throws: ConfigurationError.self) { try AppConfiguration.parse(["--surprise"], environment: [:]) }
        #expect(throws: ConfigurationError.self) { try AppConfiguration.parse(["--cache"], environment: [:]) }
        #expect(throws: ConfigurationError.self) { try AppConfiguration.parse(["--codex-home", "--report"], environment: [:]) }
    }

    @Test func reportEncodesAllFourTotalsAndUnpricedWarning() throws {
        let periods = Dictionary(uniqueKeysWithValues: UsagePeriod.allCases.map { period in
            (period.rawValue, PeriodReport(period: period,
                totals: PeriodTotals(usage: TokenUsage(total: 12_300_000), estimatedUSD: 4.56,
                                     unpricedEvents: 1, unpricedTokens: 20)))
        })
        let report = UsageReport(scannedAt: Date(timeIntervalSince1970: 0), sources: ["/tmp/codex"],
                                 indexedSessions: 1, scannedFiles: 2,
                                 pricingAsOf: "2026-09-24", pricingSource: "https://openai.com/api/pricing/",
                                 periods: periods,
                                 warnings: ["Missing model prices."], indexWarningCount: 0)
        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["currency"] as? String == "USD")
        #expect(json["pricingAsOf"] as? String == "2026-09-24")
        #expect(json["pricingSource"] as? String == "https://openai.com/api/pricing/")
        #expect(json["warnings"] as? [String] == ["Missing model prices."])
        let values = try #require(json["periods"] as? [String: [String: Any]])
        #expect(Set(values.keys) == Set(["daily", "weekly", "monthly", "overall"]))
        for period in UsagePeriod.allCases {
            #expect(values[period.rawValue]?["totalTokens"] as? Int64 == 12_300_000)
            #expect(values[period.rawValue]?["estimatedUSD"] as? Double == 4.56)
            #expect(values[period.rawValue]?["unpricedEvents"] as? Int == 1)
            #expect(values[period.rawValue]?["display"] as? String == "\(period.shortTitle): 12.3M / $4.56 + ?")
        }
    }
}
