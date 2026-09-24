import Foundation
import TokenBarCore

struct PeriodReport: Encodable {
    let label: String
    let display: String
    let totalTokens: Int64
    let usage: TokenUsage
    let estimatedUSD: Double
    let unpricedEvents: Int
    let unpricedTokens: Int64

    init(period: UsagePeriod, totals: PeriodTotals) {
        label = period.shortTitle
        totalTokens = totals.usage.total
        usage = totals.usage
        estimatedUSD = totals.estimatedUSD
        unpricedEvents = totals.unpricedEvents
        unpricedTokens = totals.unpricedTokens
        display = UsageFormatting.title(period: period, tokens: totalTokens,
                                        estimatedUSD: estimatedUSD, unpricedEvents: unpricedEvents)
    }
}

struct UsageReport: Encodable {
    let scannedAt: Date
    let sources: [String]
    let indexedSessions: Int
    let scannedFiles: Int
    let currency = "USD"
    let pricingBasis = "Estimated cost at standard API prices; not account billing."
    let pricingAsOf: String
    let pricingSource: String
    let periods: [String: PeriodReport]
    let warnings: [String]
    let indexWarningCount: Int
}

/// Called only on the serial worker queue, or by the command-line entry point.
final class ReportBuilder {
    private let configuration: AppConfiguration
    private lazy var indexer = UsageIndexer(codexHomes: configuration.codexHomes, cacheURL: configuration.cacheURL)
    private var priceBook: PriceBook?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func scan(progress: ((IndexProgress) -> Void)? = nil) throws -> UsageReport {
        if priceBook == nil {
            priceBook = try PriceBook.bundled()
        }
        guard let priceBook else {
            throw ConfigurationError.message("Price data is unavailable.")
        }
        let snapshot = try indexer.scan(progress: progress)
        let totals = UsageAggregator.summarize(snapshot, prices: priceBook)
        var periods: [String: PeriodReport] = [:]
        for period in UsagePeriod.allCases {
            periods[period.rawValue] = PeriodReport(period: period, totals: totals[period] ?? PeriodTotals())
        }
        var warnings = snapshot.warnings
        if let overall = periods[UsagePeriod.overall.rawValue], overall.unpricedEvents > 0 {
            warnings.append("Missing model prices for \(overall.unpricedEvents) events (\(overall.unpricedTokens) tokens); estimated costs are incomplete.")
        }
        return UsageReport(scannedAt: snapshot.scannedAt, sources: configuration.codexHomes.map(\.path),
                           indexedSessions: snapshot.indexedSessions, scannedFiles: snapshot.scannedFiles,
                           pricingAsOf: priceBook.asOf, pricingSource: priceBook.source,
                           periods: periods, warnings: warnings, indexWarningCount: snapshot.warnings.count)
    }
}

enum UsageFormatting {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func title(period: UsagePeriod, tokens: Int64, estimatedUSD: Double, unpricedEvents: Int,
                      showTokens: Bool = true, showDollars: Bool = true, expanded: Bool = false) -> String {
        let unknown = unpricedEvents > 0 ? " + ?" : ""
        var values: [String] = []
        if showTokens { values.append(abbreviatedTokens(tokens)) }
        if showDollars { values.append("\(dollars(estimatedUSD))\(unknown)") }
        let label = expanded ? period.menuTitle : period.shortTitle
        return "\(label): \(values.joined(separator: " / "))"
    }

    static func abbreviatedTokens(_ tokens: Int64) -> String {
        let value = Double(tokens)
        let units: [(Double, String)] = [(1_000_000_000_000, "T"), (1_000_000_000, "B"),
                                         (1_000_000, "M"), (1_000, "K")]
        for (scale, suffix) in units where abs(value) >= scale {
            return String(format: "%.1f%@", locale: locale, value / scale, suffix)
        }
        return String(tokens)
    }

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", locale: locale, value)
    }
}
