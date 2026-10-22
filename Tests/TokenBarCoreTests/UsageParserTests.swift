import Foundation
import Testing
@testable import TokenBarCore

@Suite
struct UsageParserTests {
    @Test func digestKeepsExistingLowercaseSHA256Encoding() {
        #expect(usageDigest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(usageDigest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(usageDigest(Data("abc".utf8)) == usageDigest("abc"))
    }

    @Test func timestampsAndFingerprintsRemainCacheCompatible() throws {
        let parser = UsageParser()
        let cases: [(String, TimeInterval, String)] = [
            ("2026-09-24T10:00:00Z", 1_790_244_000,
             "299690b441c720bd7d8d48c73493dca60cc66a3ee2baaa58fddeabc3fd95b42b"),
            ("2026-09-24T12:00:00+02:00", 1_790_244_000,
             "299690b441c720bd7d8d48c73493dca60cc66a3ee2baaa58fddeabc3fd95b42b"),
            ("2026-09-24T10:00:00.123Z", 1_790_244_000.123,
             "cea638314251e7ad4f36bcdc1c1bd6875d549e7cd1ff4f5a821d801073ea39f4"),
            ("2026-09-24T12:00:00.123+02:00", 1_790_244_000.123,
             "cea638314251e7ad4f36bcdc1c1bd6875d549e7cd1ff4f5a821d801073ea39f4"),
        ]
        for (timestamp, seconds, fingerprint) in cases {
            var state = UsageParserState()
            let event = try #require(parser.parse(token(timestamp), state: &state))
            #expect(event.timestamp == Date(timeIntervalSince1970: seconds))
            #expect(event.fingerprint == fingerprint)
            #expect(event.usage == TokenUsage(input: 100, cachedInput: 80, cacheWrite: 3,
                                             output: 20, reasoningOutput: 10, total: 120))
        }
    }

    @Test func unknownRecordsDoNotValidateUnusedPayloadFields() throws {
        let parser = UsageParser()
        let lines = [
            " \t\r",
            #"{"type":"response_item","timestamp":123,"payload":false}"#,
            #"{"type":"event_msg","payload":{"type":"unrelated","info":false}}"#,
            #"{"type":null,"payload":{"model":123}}"#,
            #"{}"#,
        ]
        var state = UsageParserState()
        for line in lines {
            #expect(try parser.parse(Data(line.utf8), state: &state) == nil)
        }
        #expect(!state.hasMetadata)
    }

    @Test func recognizedEnvelopesStillValidateTheirFieldTypes() {
        let parser = UsageParser()
        let malformed = [
            #"{"type":"turn_context","timestamp":123,"payload":{}}"#,
            #"{"type":"event_msg","timestamp":123,"payload":{"type":"unrelated"}}"#,
            #"{"type":"event_msg","payload":null}"#,
            #"{"type":"event_msg","payload":{"type":123}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","started_at":"123"}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"other","thread_settings":{"model":123}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":false}}"#,
            #"{"type":"response_item","payload":{"content":}}"#,
        ]
        for line in malformed {
            var state = UsageParserState()
            #expect(throws: UsageReadError.self) {
                try parser.parse(Data(line.utf8), state: &state)
            }
        }
    }

    @Test func repeatedMetadataIsIgnoredAndDecoderCanSwitchSessions() throws {
        let parser = UsageParser()
        var child = UsageParserState()
        _ = try parser.parse(Data(#"{"type":"session_meta","payload":{"id":"child","forked_from_id":"parent"}}"#.utf8), state: &child)
        _ = try parser.parse(Data(#"{"type":"session_meta","timestamp":123,"payload":false}"#.utf8), state: &child)
        #expect(child.sessionID == "child")
        #expect(child.hasInheritedHistory)
        #expect(!child.ownHistoryStarted)

        var independent = UsageParserState()
        _ = try parser.parse(Data(#"{"type":"session_meta","payload":{"id":"independent"}}"#.utf8), state: &independent)
        #expect(independent.sessionID == "independent")
        #expect(independent.ownHistoryStarted)
        #expect(!independent.hasInheritedHistory)
    }

    @Test func missingUsageDoesNotRequireAValidTimestamp() throws {
        let parser = UsageParser()
        var state = UsageParserState()
        for info in ["null", "{}"] {
            let line = #"{"type":"event_msg","timestamp":"invalid","payload":{"type":"token_count","info":\#(info)}}"#
            #expect(try parser.parse(Data(line.utf8), state: &state) == nil)
        }
        #expect(throws: UsageReadError.self) {
            try parser.parse(token("invalid"), state: &state)
        }
    }

    @Test func persistedLastOnlyFingerprintStillSuppressesDuplicates() throws {
        let parser = UsageParser()
        let line = token("2026-09-24T10:00:00Z", lastOnly: true)
        var state = UsageParserState()
        let event = try #require(parser.parse(line, state: &state))
        #expect(event.fingerprint == "566b3083306f52fe33d8eada75ad25dedd8686c14598f68c534115e6c71fd656")
        var restored = try JSONDecoder().decode(UsageParserState.self, from: JSONEncoder().encode(state))
        #expect(try parser.parse(line, state: &restored) == nil)
        #expect(restored.pendingLastOnly == event.usage)
    }

    private func token(_ timestamp: String, lastOnly: Bool = false) -> Data {
        let counterKey = lastOnly ? "last_token_usage" : "total_token_usage"
        return Data(#"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"\#(counterKey)":{"input_tokens":100,"cached_input_tokens":80,"cache_write_input_tokens":3,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}"#.utf8)
    }
}
