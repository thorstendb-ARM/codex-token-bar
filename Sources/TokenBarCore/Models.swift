import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheWrite: Int64
    public var output: Int64
    public var reasoningOutput: Int64
    public var total: Int64

    public init(input: Int64 = 0, cachedInput: Int64 = 0, cacheWrite: Int64 = 0,
                output: Int64 = 0, reasoningOutput: Int64 = 0, total: Int64? = nil) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total ?? (input + output)
    }

    public static let zero = TokenUsage()
}

public struct UsageEvent: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var model: String?
    public var usage: TokenUsage

    public init(id: String, timestamp: Date, model: String?, usage: TokenUsage) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.usage = usage
    }
}

public struct IndexProgress: Sendable {
    public var completed: Int
    public var total: Int
    public init(completed: Int, total: Int) { self.completed = completed; self.total = total }
}

public struct UsageSnapshot: Sendable {
    public var events: [UsageEvent]
    public var indexedSessions: Int
    public var scannedFiles: Int
    public var warnings: [String]
    public var scannedAt: Date
    /// Stable for unchanged events within one indexer; nil for external snapshots.
    public var eventsRevision: UInt64?

    public init(events: [UsageEvent], indexedSessions: Int, scannedFiles: Int,
                warnings: [String] = [], scannedAt: Date = Date(), eventsRevision: UInt64? = nil) {
        self.events = events
        self.indexedSessions = indexedSessions
        self.scannedFiles = scannedFiles
        self.warnings = warnings
        self.scannedAt = scannedAt
        self.eventsRevision = eventsRevision
    }
}

public enum UsagePeriod: String, CaseIterable, Codable, Sendable {
    case current, daily, weekly, monthly, overall

    public var title: String {
        switch self {
        case .current: return "Seit Beginn der manuellen Messung"
        case .daily: return "Heute"
        case .weekly: return "Diese Woche (ab Montag)"
        case .monthly: return "Dieser Monat"
        case .overall: return "Insgesamt"
        }
    }

    public var shortTitle: String {
        switch self {
        case .current: return "C"
        case .daily: return "D"
        case .weekly: return "W"
        case .monthly: return "M"
        case .overall: return "O"
        }
    }

    public var menuTitle: String {
        switch self {
        case .current: return "Current"
        case .daily: return "Day"
        case .weekly: return "Week"
        case .monthly: return "Month"
        case .overall: return "Overall"
        }
    }

    public func start(now: Date, calendar: Calendar = .current,
                      currentStartedAt: Date? = nil) -> Date? {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        switch self {
        case .current: return currentStartedAt
        case .daily: return calendar.startOfDay(for: now)
        case .weekly: return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .monthly: return calendar.dateInterval(of: .month, for: now)?.start
        case .overall: return nil
        }
    }
}
