import Foundation

/// A fixed, auditable API-equivalent estimate, not an account bill.
public struct PriceBook: Codable, Sendable {
    public struct Rates: Codable, Sendable {
        public var input: Double
        public var cachedInput: Double?
        public var cacheWrite: Double?
        public var output: Double
    }

    public struct Model: Codable, Sendable {
        public var standard: Rates
        public var longContext: Rates?
        public var longContextThreshold: Int64?
    }

    public var asOf: String
    public var source: String
    public var models: [String: Model]
    public var aliases: [String: String]

    public static func bundled() throws -> PriceBook {
        // The packaged .app uses the conventional Resources directory. SwiftPM
        // uses its generated bundle while running the executable or tests.
        let resource = Bundle.main.url(forResource: "prices", withExtension: "json")
            ?? Bundle.module.url(forResource: "prices", withExtension: "json")
        guard let url = resource else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(PriceBook.self, from: Data(contentsOf: url))
    }

    public func estimate(_ event: UsageEvent) -> Double? {
        guard let name = event.model, let model = model(named: name) else { return nil }
        return estimate(event, model: model)
    }

    /// Resolve each distinct model only once during a history summary, including
    /// unknown proxy names that would otherwise repeat the snapshot-name regex.
    func estimate(_ event: UsageEvent, cachedModels: inout [String: Model?]) -> Double? {
        guard let name = event.model else { return nil }
        let resolved: Model?
        if let cached = cachedModels[name] {
            resolved = cached
        } else {
            resolved = model(named: name)
            // updateValue retains a cached nil instead of removing the dictionary entry.
            cachedModels.updateValue(resolved, forKey: name)
        }
        guard let resolved else { return nil }
        return estimate(event, model: resolved)
    }

    private func estimate(_ event: UsageEvent, model: Model) -> Double? {
        let usage = event.usage
        guard usage.input >= 0, usage.output >= 0, usage.cachedInput >= 0,
              usage.cacheWrite >= 0, usage.cachedInput <= usage.input,
              usage.cacheWrite <= usage.input - usage.cachedInput else { return nil }
        let rates: Rates
        if let threshold = model.longContextThreshold, usage.input > threshold,
           let long = model.longContext {
            rates = long
        } else {
            rates = model.standard
        }
        // Models without a cache-write tariff charge normal input; reasoning
        // is already included in output, just as cached tokens are in input.
        let regular = usage.input - usage.cachedInput - usage.cacheWrite
        return (Double(regular) * rates.input
            + Double(usage.cachedInput) * (rates.cachedInput ?? rates.input)
            + Double(usage.cacheWrite) * (rates.cacheWrite ?? rates.input)
            + Double(usage.output) * rates.output) / 1_000_000
    }

    private func model(named name: String) -> Model? {
        if let exact = models[aliases[name] ?? name] { return exact }
        // Only recognize dated snapshots of known model IDs, never fuzzy family
        // matches: e.g. a new proxy model must not silently inherit a price.
        guard name.range(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                         options: .regularExpression) != nil else { return nil }
        let base = String(name.dropLast(11))
        return models[aliases[base] ?? base]
    }
}
