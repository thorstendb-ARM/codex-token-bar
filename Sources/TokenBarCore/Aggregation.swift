import Foundation

public struct PeriodTotals: Codable, Sendable {
    public var usage: TokenUsage
    public var estimatedUSD: Double
    public var unpricedEvents: Int
    public var unpricedTokens: Int64

    public init(usage: TokenUsage = .zero, estimatedUSD: Double = 0,
                unpricedEvents: Int = 0, unpricedTokens: Int64 = 0) {
        self.usage = usage
        self.estimatedUSD = estimatedUSD
        self.unpricedEvents = unpricedEvents
        self.unpricedTokens = unpricedTokens
    }

    mutating func add(_ event: UsageEvent, cost: Double?) {
        usage.input += event.usage.input
        usage.cachedInput += event.usage.cachedInput
        usage.cacheWrite += event.usage.cacheWrite
        usage.output += event.usage.output
        usage.reasoningOutput += event.usage.reasoningOutput
        usage.total += event.usage.total
        if let cost = cost {
            estimatedUSD += cost
        } else {
            unpricedEvents += 1
            unpricedTokens += event.usage.total
        }
    }
}

public enum UsageAggregator {
    public static func summarize(_ snapshot: UsageSnapshot, prices: PriceBook,
                                 now: Date = Date(), calendar: Calendar = .current,
                                 currentStartedAt: Date? = nil)
        -> [UsagePeriod: PeriodTotals] {
        var result = Dictionary(uniqueKeysWithValues: UsagePeriod.allCases.map { ($0, PeriodTotals()) })
        let starts = UsagePeriod.allCases.map {
            ($0, $0.start(now: now, calendar: calendar, currentStartedAt: currentStartedAt))
        }
        // A copied/archived log must not increase the total.
        var seen = Set<String>()
        var cachedModels: [String: PriceBook.Model?] = [:]
        for event in snapshot.events where event.timestamp <= now && seen.insert(event.id).inserted {
            let cost = prices.estimate(event, cachedModels: &cachedModels)
            for (period, start) in starts {
                // An unstarted manual measurement must not behave like Overall.
                if period == .current && start == nil { continue }
                if let start = start, event.timestamp < start { continue }
                result[period]!.add(event, cost: cost)
            }
        }
        return result
    }
}
