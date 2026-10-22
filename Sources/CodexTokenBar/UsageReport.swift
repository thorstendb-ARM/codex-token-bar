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
    private(set) var currentStartedAt: Date?
    let sources: [String]
    let indexedSessions: Int
    let scannedFiles: Int
    let currency = "USD"
    let pricingBasis = "Estimated cost at standard API prices; not account billing."
    let pricingAsOf: String
    let pricingSource: String
    private(set) var periods: [String: PeriodReport]
    let warnings: [String]
    let indexWarningCount: Int

    /// Clear only the manual measurement while waiting for a scan with the new start.
    mutating func resetCurrent(startedAt: Date) {
        currentStartedAt = startedAt
        periods[UsagePeriod.current.rawValue] = PeriodReport(period: .current, totals: PeriodTotals())
    }
}

/// Called only on the serial worker queue, or by the command-line entry point.
final class ReportBuilder {
    private let configuration: AppConfiguration
    private lazy var indexer = UsageIndexer(codexHomes: configuration.codexHomes, cacheURL: configuration.cacheURL)
    private var periodCache: PeriodReportCache?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func scan(currentStartedAt: Date? = nil, progress: ((IndexProgress) -> Void)? = nil) throws -> UsageReport {
        if periodCache == nil {
            periodCache = PeriodReportCache(prices: try PriceBook.bundled())
        }
        guard let periodCache else {
            throw ConfigurationError.message("Price data is unavailable.")
        }
        let snapshot = try indexer.scan(progress: progress)
        let periods = periodCache.reports(for: snapshot, currentStartedAt: currentStartedAt)
        var warnings = snapshot.warnings
        if let overall = periods[UsagePeriod.overall.rawValue], overall.unpricedEvents > 0 {
            warnings.append("Missing model prices for \(overall.unpricedEvents) events (\(overall.unpricedTokens) tokens); estimated costs are incomplete.")
        }
        return UsageReport(scannedAt: snapshot.scannedAt, currentStartedAt: currentStartedAt,
                           sources: configuration.codexHomes.map(\.path),
                           indexedSessions: snapshot.indexedSessions, scannedFiles: snapshot.scannedFiles,
                           pricingAsOf: periodCache.prices.asOf, pricingSource: periodCache.prices.source,
                           periods: periods, warnings: warnings, indexWarningCount: snapshot.warnings.count)
    }
}

/// A stable index revision needs no history traversal until a reporting boundary changes.
final class PeriodReportCache {
    let prices: PriceBook
    private struct Key: Equatable {
        let revision: UInt64
        let starts: [Date?]
    }
    private var key: Key?
    private var periods: [String: PeriodReport] = [:]
    private var validFrom = Date.distantFuture
    private var nextFutureEvent: Date?

    init(prices: PriceBook) {
        self.prices = prices
    }

    func reports(for snapshot: UsageSnapshot, currentStartedAt: Date? = nil,
                 calendar: Calendar = .current) -> [String: PeriodReport] {
        let now = snapshot.scannedAt
        let nextKey = snapshot.eventsRevision.map { revision in
            Key(revision: revision, starts: UsagePeriod.allCases.map {
                $0.start(now: now, calendar: calendar, currentStartedAt: currentStartedAt)
            })
        }
        if let nextKey, nextKey == key, now >= validFrom,
           nextFutureEvent.map({ now < $0 }) ?? true {
            return periods
        }

        let totals = UsageAggregator.summarize(snapshot, prices: prices, now: now,
                                               calendar: calendar, currentStartedAt: currentStartedAt)
        periods = Dictionary(uniqueKeysWithValues: UsagePeriod.allCases.map {
            ($0.rawValue, PeriodReport(period: $0, totals: totals[$0] ?? PeriodTotals()))
        })
        key = nextKey
        validFrom = now
        // Future-dated records become eligible without any file changing; clock rollback
        // and day/week/month/current changes must also invalidate the cached totals.
        nextFutureEvent = snapshot.events.lazy.map(\.timestamp).filter { $0 > now }.min()
        return periods
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
