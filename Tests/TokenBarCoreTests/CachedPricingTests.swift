import Foundation
import Testing
@testable import TokenBarCore

struct CachedPricingTests {
    @Test func repeatedModelLookupPreservesPerEventRatesAndUnknownPrices() throws {
        let prices = try PriceBook.bundled()
        let names: [String?] = ["gpt-6-astra", "gpt-6-astra-2026-10-22", "unknown-proxy", nil]
        let usages = [
            TokenUsage(input: 100, cachedInput: 40, output: 10),
            TokenUsage(input: 300_000, cachedInput: 10_000, output: 10_000),
            TokenUsage(input: 100, cachedInput: 101, output: 10),
        ]
        var models: [String: PriceBook.Model?] = [:]
        for _ in 0..<3 {
            for name in names {
                for usage in usages {
                    let event = UsageEvent(id: UUID().uuidString, timestamp: Date(), model: name, usage: usage)
                    #expect(prices.estimate(event, cachedModels: &models) == prices.estimate(event))
                }
            }
        }
        // Missing models are retained too: the expensive failed lookup is not repeated.
        #expect(models.count == 3)
        #expect(models.keys.contains("unknown-proxy"))
        #expect(models["unknown-proxy"]! == nil)
    }
}
