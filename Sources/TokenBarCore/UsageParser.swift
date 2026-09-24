import CryptoKit
import Foundation

// Narrow decoders intentionally never retain conversation or instruction fields.
struct UsageParserState: Codable {
    var hasMetadata = false
    var sessionID: String?
    var forkedFromID: String?
    var createdAt: Date?
    var hasInheritedHistory = false
    var ownHistoryStarted = true
    var inheritedTokenRecords = 0
    var missingBaselineRecords = 0
    var model: String?
    var previousTotal: TokenUsage?
    var pendingLastOnly = TokenUsage.zero
    var lastOnlyFingerprints: Set<String> = []
}

struct IndexedUsageEvent: Codable {
    var fingerprint: String
    var timestamp: Date
    var model: String?
    var usage: TokenUsage
}

enum UsageReadError: Error {
    case malformedRecord
    case changedDuringRead
    case invalidCacheLocation
}

enum UsageParser {
    private struct Header: Decodable { let type: String? }
    private struct Envelope<P: Decodable>: Decodable {
        let timestamp: String?
        let payload: P
    }
    private struct Metadata: Decodable {
        let id: String?
        let session_id: String?
        let forked_from_id: String?
        let subagent_history_start_ordinal: Int?
        let timestamp: String?
        let model: String?
    }
    private struct Context: Decodable { let model: String? }
    private struct EventHeader: Decodable { let type: String? }
    private struct SettingsMarker: Decodable {
        let thread_id: String?
        let thread_settings: Context?
    }
    private struct TaskMarker: Decodable { let started_at: Double? }
    private struct TokenPayload: Decodable {
        let type: String?
        let model: String?
        let info: TokenInfo?
    }
    private struct TokenInfo: Decodable {
        let model: String?
        let total_token_usage: Counters?
        let last_token_usage: Counters?
    }
    private struct Counters: Decodable {
        let input_tokens: Int64?
        let cached_input_tokens: Int64?
        let cache_write_input_tokens: Int64?
        let output_tokens: Int64?
        let reasoning_output_tokens: Int64?
        let total_tokens: Int64?

        func usage() throws -> TokenUsage {
            let input = input_tokens ?? 0
            let output = output_tokens ?? 0
            let sum = input.addingReportingOverflow(output)
            guard !sum.overflow else { throw UsageReadError.malformedRecord }
            let result = TokenUsage(input: input, cachedInput: cached_input_tokens ?? 0,
                                    cacheWrite: cache_write_input_tokens ?? 0, output: output,
                                    reasoningOutput: reasoning_output_tokens ?? 0,
                                    total: total_tokens ?? sum.partialValue)
            guard values(result).allSatisfy({ $0 >= 0 }) else { throw UsageReadError.malformedRecord }
            return result
        }
    }

    static func parse(_ line: Data, state: inout UsageParserState) throws -> IndexedUsageEvent? {
        if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { return nil }
        let decoder = JSONDecoder()
        do {
            let header = try decoder.decode(Header.self, from: line)
            switch header.type {
            case "session_meta":
                guard !state.hasMetadata else { return nil }
                let record = try decoder.decode(Envelope<Metadata>.self, from: line)
                let metadata = record.payload
                state.hasMetadata = true
                state.sessionID = identifier(metadata.id) ?? identifier(metadata.session_id) ?? state.sessionID
                state.forkedFromID = identifier(metadata.forked_from_id) ?? state.forkedFromID
                state.createdAt = (metadata.timestamp ?? record.timestamp).flatMap(date)
                state.hasInheritedHistory = state.forkedFromID != nil || metadata.subagent_history_start_ordinal != nil
                state.ownHistoryStarted = !state.hasInheritedHistory
                state.model = identifier(metadata.model) ?? state.model
                return nil
            case "turn_context":
                let record = try decoder.decode(Envelope<Context>.self, from: line)
                state.model = identifier(record.payload.model) ?? state.model
                return nil
            case "event_msg":
                let event = try decoder.decode(Envelope<EventHeader>.self, from: line)
                if event.payload.type == "thread_settings_applied" {
                    let marker = try decoder.decode(Envelope<SettingsMarker>.self, from: line)
                    if let id = marker.payload.thread_id, id == state.sessionID {
                        if !state.ownHistoryStarted { state.model = nil }
                        state.ownHistoryStarted = true
                        state.model = identifier(marker.payload.thread_settings?.model) ?? state.model
                    }
                    return nil
                }
                if event.payload.type == "task_started" {
                    let marker = try decoder.decode(Envelope<TaskMarker>.self, from: line)
                    // Older logs use integer Unix seconds even though metadata has fractions.
                    // Ordinals in migrated histories may point at EOF, so never blindly skip them.
                    if let started = marker.payload.started_at, let created = state.createdAt,
                       started >= floor(created.timeIntervalSince1970) {
                        if !state.ownHistoryStarted { state.model = nil }
                        state.ownHistoryStarted = true
                    }
                    return nil
                }
                guard event.payload.type == "token_count" else { return nil }
                let record = try decoder.decode(Envelope<TokenPayload>.self, from: line)
                guard let info = record.payload.info else { return nil }
                guard let rawUsage = info.total_token_usage ?? info.last_token_usage else { return nil }
                guard let timestampText = record.timestamp, let timestamp = date(timestampText) else {
                    throw UsageReadError.malformedRecord
                }
                let current = try rawUsage.usage()
                let last = try info.last_token_usage?.usage()
                let hasTotal = info.total_token_usage != nil
                let snapshot = values(current).map(String.init).joined(separator: ",")
                let fingerprint = usageDigest("\(timestamp.timeIntervalSince1970)|\(hasTotal ? "total" : "last")|\(snapshot)")
                if !hasTotal && !state.lastOnlyFingerprints.insert(fingerprint).inserted { return nil }
                var delta = current
                if hasTotal, let previous = state.previousTotal {
                    // Primary decreases start a new epoch. Auxiliary cache/reasoning
                    // counters may decrease independently; clamp their deltas to zero.
                    let reset = current.total < previous.total || current.input < previous.input || current.output < previous.output
                    if reset {
                        delta = last ?? current
                        state.pendingLastOnly = .zero
                    } else {
                        let cumulativeDelta = subtract(current, previous)
                        delta = subtract(cumulativeDelta, state.pendingLastOnly)
                        state.pendingLastOnly = subtract(state.pendingLastOnly, cumulativeDelta)
                    }
                } else if hasTotal && state.hasInheritedHistory {
                    // A fork can start with an inherited cumulative baseline that is not
                    // represented by any copied token record. Only the last call is new.
                    if let last { delta = last; state.pendingLastOnly = .zero }
                    else {
                        state.previousTotal = current
                        if state.ownHistoryStarted { state.missingBaselineRecords += 1 }
                        else { state.inheritedTokenRecords += 1 }
                        return nil
                    }
                } else if hasTotal {
                    delta = subtract(current, state.pendingLastOnly)
                    state.pendingLastOnly = subtract(state.pendingLastOnly, current)
                }
                if !hasTotal { state.pendingLastOnly = add(state.pendingLastOnly, current) }
                if hasTotal { state.previousTotal = current }
                let model = identifier(info.model) ?? identifier(record.payload.model) ?? state.model
                if let model { state.model = model }
                guard state.ownHistoryStarted else {
                    state.inheritedTokenRecords += 1
                    return nil
                }
                guard values(delta).contains(where: { $0 > 0 }) else { return nil }
                return IndexedUsageEvent(fingerprint: fingerprint, timestamp: timestamp, model: model, usage: delta)
            default:
                return nil
            }
        } catch {
            // DecodingError descriptions may contain source text; never surface them.
            throw UsageReadError.malformedRecord
        }
    }

    private static func identifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
              }) else { return nil }
        return value
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func subtract(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(0, a.input - b.input), cachedInput: max(0, a.cachedInput - b.cachedInput),
                   cacheWrite: max(0, a.cacheWrite - b.cacheWrite), output: max(0, a.output - b.output),
                   reasoningOutput: max(0, a.reasoningOutput - b.reasoningOutput), total: max(0, a.total - b.total))
    }

    private static func add(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        func sum(_ a: Int64, _ b: Int64) -> Int64 {
            let result = a.addingReportingOverflow(b)
            return result.overflow ? Int64.max : result.partialValue
        }
        return TokenUsage(input: sum(a.input, b.input), cachedInput: sum(a.cachedInput, b.cachedInput),
                          cacheWrite: sum(a.cacheWrite, b.cacheWrite), output: sum(a.output, b.output),
                          reasoningOutput: sum(a.reasoningOutput, b.reasoningOutput), total: sum(a.total, b.total))
    }

    private static func values(_ value: TokenUsage) -> [Int64] {
        [value.input, value.cachedInput, value.cacheWrite, value.output, value.reasoningOutput, value.total]
    }
}

func usageDigest(_ value: String) -> String { usageDigest(Data(value.utf8)) }

func usageDigest(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
}
