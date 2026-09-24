import Foundation
import Testing
@testable import TokenBarCore

struct PricingTests {
    private func event(_ usage: TokenUsage, model: String? = "gpt-6-astra") -> UsageEvent {
        UsageEvent(id: "test", timestamp: Date(), model: model, usage: usage)
    }

    @Test func cachedAndReasoningTokensAreNotDoubleCounted() throws {
        let usage = TokenUsage(input: 100_000, cachedInput: 60_000, cacheWrite: 30_000,
                               output: 2_000, reasoningOutput: 1_500)
        let cost = try PriceBook.bundled().estimate(event(usage))
        #expect(abs(cost! - (0.1 + 0.06 + 0.375 + 0.1)) < 0.000000001)
        #expect(usage.total == 102_000)
    }

    @Test func longContextTierAppliesPerEventNotPeriodTotal() throws {
        let prices = try PriceBook.bundled()
        #expect(abs(prices.estimate(event(TokenUsage(input: 272_000)))! - 2.72) < 0.000000001)
        #expect(abs(prices.estimate(event(TokenUsage(input: 272_001)))! - 5.44002) < 0.000000001)
    }

    @Test func oldModelsWithoutSeparateWritePriceUseNormalInput() throws {
        let prices = try PriceBook.bundled()
        #expect(abs(prices.estimate(event(TokenUsage(input: 100, cacheWrite: 100), model: "gpt-5.4"))!
                    - 0.00025) < 0.000000001)
    }

    @Test func explicitSnapshotOverridesFamilyAndUnknownStaysUnknown() throws {
        let prices = try PriceBook.bundled()
        #expect(abs(prices.estimate(event(TokenUsage(input: 100), model: "gpt-4o-2024-05-13"))!
                    - 0.0005) < 0.000000001)
        #expect(prices.estimate(event(.zero, model: "gpt-6-astra-2026-09-24")) != nil)
        #expect(prices.estimate(event(.zero, model: "gpt-6-astra-private")) == nil)
        #expect(prices.estimate(event(.zero, model: nil)) == nil)
    }

    @Test func malformedCountersAreNotGivenMisleadingPrices() throws {
        let prices = try PriceBook.bundled()
        #expect(prices.estimate(event(TokenUsage(input: 100, cachedInput: 101))) == nil)
        #expect(prices.estimate(event(TokenUsage(input: 100, cachedInput: 60, cacheWrite: 60))) == nil)
        #expect(prices.estimate(event(TokenUsage(input: -1))) == nil)
    }
}
