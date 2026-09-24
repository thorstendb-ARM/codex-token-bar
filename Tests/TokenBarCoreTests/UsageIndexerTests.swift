import Foundation
import Testing
@testable import TokenBarCore

@Suite
final class UsageIndexerTests {
    private var directory: URL!
    private var home: URL!
    private var cacheURL: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBarTests-\(UUID().uuidString)")
        home = directory.appendingPathComponent("codex")
        cacheURL = directory.appendingPathComponent("cache/index.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
    }

    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func testCumulativeDuplicatesDeltasAndSubsetCounters() throws {
        try write("one", lines: [meta("one", model: "gpt-test"),
            token(100, 20, cached: 80, reasoning: 10),
            token(100, 20, cached: 80, reasoning: 10, second: 1),
            token(150, 30, cached: 100, reasoning: 15, second: 2)])
        let snapshot = try indexer().scan()
        #expect(snapshot.events.count == 2)
        #expect(snapshot.events.map(\.usage.total) == [120, 60])
        #expect(snapshot.events.map(\.usage.cachedInput) == [80, 20])
        #expect(snapshot.events.map(\.usage.reasoningOutput) == [10, 5])
        #expect(snapshot.events.map(\.model) == ["gpt-test", "gpt-test"])
        #expect(snapshot.warnings.isEmpty)
    }

    @Test func testResetAndModelChanges() throws {
        try write("one", lines: [meta("one", model: "model-a"), token(100, 20),
            context("model-b"), token(10, 2, second: 1),
            token(30, 6, second: 2, model: "model-c")])
        let events = try indexer().scan().events
        #expect(events.map(\.usage.total) == [120, 12, 24])
        #expect(events.map(\.model) == ["model-a", "model-b", "model-c"])
    }

    @Test func testLastOnlyAndIgnoredOtherRecords() throws {
        let last = token(10, 2, lastOnly: true)
        try write("one", lines: [meta("one"), last, last,
            #"{"type":"token_usage_record","timestamp":"2026-09-24T10:00:00Z","usage":{"total_tokens":9999}}"#,
            #"{"type":"response_item","payload":{"content":"NEVER_STORE_THIS_PROMPT"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#])
        let snapshot = try indexer().scan()
        #expect(snapshot.events.map(\.usage.total) == [12])
        let cache = try String(contentsOf: cacheURL)
        #expect(!(cache.contains("NEVER_STORE_THIS_PROMPT")))
        #expect(!(cache.contains("content")))
    }

    @Test func testLastOnlyBetweenCumulativeRecordsIsNotCountedTwice() throws {
        let last = token(10, 2, second: 1, lastOnly: true)
        let file = try write("one", lines: [meta("one"), token(100, 20), last, last])
        #expect(try indexer().scan().events.map(\.usage.total) == [120, 12])
        try append(token(120, 24, second: 2) + "\n", to: file)
        #expect(try indexer().scan().events.map(\.usage.total) == [120, 12, 12])
    }

    @Test func testLastOnlyBeforeInitialCumulativeRecordIsAccountedFor() throws {
        try write("one", lines: [meta("one"), token(10, 2, lastOnly: true), token(20, 4, second: 1)])
        #expect(try indexer().scan().events.map(\.usage.total) == [12, 12])
    }

    @Test func testAppendAndPersistedCursor() throws {
        let file = try write("one", lines: [meta("one"), token(100, 20)])
        let initial = try indexer().scan()
        try append(token(140, 30, second: 1) + "\n", to: file)
        let resumed = try indexer().scan()
        #expect(initial.events.count == 1)
        #expect(resumed.events.map(\.usage.total) == [120, 50])
        #expect(try indexer().scan().events == resumed.events)
    }

    @Test func testUnchangedScanDoesNotRewriteCacheButAppendPersists() throws {
        let file = try write("one", lines: [meta("one"), token(100, 20)])
        let scanner = indexer()
        let original = try scanner.scan()
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: cacheURL.path)
        #expect(try scanner.scan().events == original.events)
        #expect(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date == sentinel)
        #expect(try indexer().scan().events == original.events)
        #expect(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date == sentinel)
        try append(token(150, 30, second: 1) + "\n", to: file)
        #expect(try scanner.scan().events.map(\.usage.total) == [120, 60])
        #expect(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date != sentinel)
        #expect(try indexer().scan().events.map(\.usage.total) == [120, 60])
    }

    @Test func testFailedCacheSaveIsRetriedWithoutSourceChanges() throws {
        try write("one", lines: [meta("one"), token(100, 20)])
        let blockedDirectory = cacheURL.deletingLastPathComponent()
        try Data("block-directory-creation".utf8).write(to: blockedDirectory)
        let scanner = indexer()
        let first = try scanner.scan()
        #expect(first.events.map(\.usage.total) == [120])
        #expect(first.warnings.contains { $0.contains("nicht gespeichert") })
        try FileManager.default.removeItem(at: blockedDirectory)
        let retried = try scanner.scan()
        #expect(retried.events == first.events)
        #expect(retried.warnings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(try indexer().scan().events == first.events)
    }

    @Test func testOlderCacheVersionForcesFullRescan() throws {
        try write("one", lines: [meta("one"), token(100, 20)])
        let original = try indexer().scan()
        var oldCache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        oldCache["version"] = 1
        var files = try #require(oldCache["files"] as? [String: [String: Any]])
        let path = try #require(files.keys.first)
        files[path]?["events"] = []
        oldCache["files"] = files
        try JSONSerialization.data(withJSONObject: oldCache).write(to: cacheURL)
        let rebuilt = try indexer().scan()
        #expect(rebuilt.events == original.events)
        #expect(rebuilt.warnings.contains { $0.contains("neu indexiert") })
        let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        #expect(current["version"] as? Int == 2)
    }

    @Test func testPartialEOFIsRereadWithoutDoubleCounting() throws {
        let file = try write("one", lines: [meta("one"), token(100, 20)])
        let scanner = indexer()
        _ = try scanner.scan()
        let next = token(150, 30, second: 1)
        let split = next.index(next.startIndex, offsetBy: next.count / 2)
        try append(String(next[..<split]), to: file)
        #expect(try scanner.scan().events.map(\.usage.total) == [120])
        try append(String(next[split...]) + "\n", to: file)
        #expect(try scanner.scan().events.map(\.usage.total) == [120, 60])
    }

    @Test func testTruncationAndAtomicReplacementRescan() throws {
        let file = try write("one", lines: [meta("one"), token(100, 20), token(200, 40, second: 1)])
        let scanner = indexer()
        #expect(try scanner.scan().events.count == 2)
        try Data((meta("one") + "\n" + token(5, 1) + "\n").utf8).write(to: file)
        #expect(try scanner.scan().events.map(\.usage.total) == [6])
        try Data((meta("replacement") + "\n" + token(10, 2) + "\n").utf8).write(to: file, options: .atomic)
        #expect(try scanner.scan().events.map(\.usage.total) == [12])
    }

    @Test func testMalformedAppendRetainsGoodSnapshotAndRetries() throws {
        let file = try write("one", lines: [meta("one"), token(100, 20)])
        let scanner = indexer()
        let initial = try scanner.scan()
        try append("{BROKEN_SECRET_PROMPT}\n", to: file)
        let failed = try scanner.scan()
        #expect(failed.events == initial.events)
        #expect(!(failed.warnings.isEmpty))
        #expect(!(failed.warnings.joined().contains("BROKEN_SECRET_PROMPT")))
        try Data((meta("one") + "\n" + token(100, 20) + "\n" + token(150, 30, second: 1) + "\n").utf8).write(to: file, options: .atomic)
        let repaired = try scanner.scan()
        #expect(repaired.events.map(\.usage.total) == [120, 60])
        #expect(repaired.warnings.isEmpty)
    }

    @Test func testArchiveMoveAndCopyDoNotDoubleCount() throws {
        let file = try write("one", lines: [meta("one"), token(100, 20)])
        let scanner = indexer()
        let initial = try scanner.scan()
        let archived = home.appendingPathComponent("archived_sessions/one.jsonl")
        try FileManager.default.moveItem(at: file, to: archived)
        let moved = try scanner.scan()
        #expect(moved.events == initial.events)
        #expect(moved.indexedSessions == 1)
        #expect(moved.warnings.isEmpty)
        try FileManager.default.copyItem(at: archived, to: file)
        #expect(try scanner.scan().events == initial.events)
    }

    @Test func testForkDuplicateAndIndependentIdenticalUsage() throws {
        try write("parent", lines: [meta("parent"), token(100, 20)])
        try write("child", lines: [meta("child", fork: "parent"), token(100, 20), settings("child"), token(120, 24, second: 1)])
        try write("independent", lines: [meta("independent"), token(100, 20)])
        let snapshot = try indexer().scan()
        #expect(snapshot.events.count == 3)
        #expect(snapshot.events.reduce(Int64(0)) { $0 + $1.usage.total } == 264)
        #expect(snapshot.indexedSessions == 3)
    }

    @Test func testFirstMetadataWinsOverInheritedParentMetadata() throws {
        try write("child", lines: [meta("child", fork: "parent"), meta("parent"), settings("child"), token(10, 2)])
        try write("parent", lines: [meta("parent"), token(5, 1)])
        #expect(try indexer().scan().indexedSessions == 2)
    }

    @Test func testChildIDWinsOverRootSessionID() throws {
        let metadata = json(["type": "session_meta", "payload": ["id": "child", "session_id": "root", "forked_from_id": "root"]])
        try write("child", lines: [metadata, settings("child"), token(10, 2)])
        try write("root", lines: [meta("root"), token(10, 2)])
        let snapshot = try indexer().scan()
        #expect(snapshot.indexedSessions == 2)
        #expect(snapshot.events.map(\.usage.total) == [12, 12])
    }

    @Test func testForkWithRetimedInheritedEventsUsesBaselineNotTheirTimestamps() throws {
        try write("child", lines: [meta("child", fork: "parent"), token(100, 20),
            settings("parent"), token(150, 30, second: 1), settings("child"), token(170, 35, second: 2)])
        #expect(try indexer().scan().events.map(\.usage.total) == [25])
    }

    @Test func testForkWithoutCopiedBaselineCountsLastNotHugeInitialTotal() throws {
        let raw = json(["type": "event_msg", "timestamp": "2026-09-24T10:00:00Z", "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": 1_000_000, "output_tokens": 20_000],
                                            "last_token_usage": ["input_tokens": 10, "output_tokens": 2]]]])
        try write("child", lines: [meta("child", fork: "parent"), settings("child"), raw])
        #expect(try indexer().scan().events.map(\.usage.total) == [12])
    }

    @Test func testLegacyTaskMarkerUsesIntegerSecondsAndIgnoresUnreliableOrdinal() throws {
        let created = "2026-09-24T10:00:00.126Z"
        let seconds = ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z")!.timeIntervalSince1970
        let metadata = json(["type": "session_meta", "payload": ["id": "child", "timestamp": created,
            "subagent_history_start_ordinal": 99_999] as [String: Any]])
        let inheritedTask = json(["type": "event_msg", "payload": ["type": "task_started", "started_at": seconds - 60]])
        let ownTask = json(["type": "event_msg", "payload": ["type": "task_started", "started_at": seconds]])
        try write("child", lines: [metadata, inheritedTask, token(100, 20), ownTask, token(110, 22, second: 1)])
        #expect(try indexer().scan().events.map(\.usage.total) == [12])
    }

    @Test func testUnresolvedForkIsNotSilentlyCounted() throws {
        try write("child", lines: [meta("child", fork: "parent"), token(100, 20)])
        let snapshot = try indexer().scan()
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.warnings.contains(where: { $0.contains("Fork") }))
    }

    @Test func testInheritedModelDoesNotLeakIntoChildAndSettingsCanIdentifyModel() throws {
        try write("child", lines: [meta("child", fork: "parent"), context("parent-model"),
            token(100, 20), settings("child"), token(110, 22, second: 1)])
        let settingsWithModel = json(["type": "event_msg", "payload": ["type": "thread_settings_applied",
            "thread_id": "other", "thread_settings": ["model": "child-model"]] as [String: Any]])
        try write("other", lines: [meta("other", fork: "parent"), context("parent-model"),
            settingsWithModel, token(10, 2, second: 2)])
        let events = try indexer().scan().events
        #expect(events.first?.model == nil)
        #expect(events.last?.model == "child-model")
    }

    @Test func testEventDatesDoNotComeFromFileModificationDate() throws {
        let file = try write("one", lines: [meta("one"), token(10, 2)])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        let event = try #require(indexer().scan().events.first)
        #expect(event.timestamp == ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
    }

    @Test func testMissingFileRetainsHistoryAndWarns() throws {
        let file = try write("one", lines: [meta("one"), token(10, 2)])
        let scanner = indexer()
        let original = try scanner.scan()
        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("temporarily-away.jsonl"))
        let missing = try scanner.scan()
        #expect(missing.events == original.events)
        #expect(!(missing.warnings.isEmpty))
    }

    @Test func testCacheInsideCodexIsRejectedBeforeWriting() throws {
        let unsafe = home.appendingPathComponent("forbidden.json")
        #expect(throws: (any Error).self) { try UsageIndexer(codexHomes: [home], cacheURL: unsafe).scan() }
        #expect(!(FileManager.default.fileExists(atPath: unsafe.path)))
    }

    @Test func testInvalidCountersAreNotAccepted() throws {
        try write("bad", lines: [meta("bad"), token(-1, 2)])
        let snapshot = try indexer().scan()
        #expect(snapshot.events.isEmpty)
        #expect(!(snapshot.warnings.isEmpty))
    }

    @Test func testOversizedConversationLineIsBoundedAndNotPersisted() throws {
        let huge = #"{"type":"response_item","payload":{"content":""# + String(repeating: "x", count: UsageIndexer.maximumLineBytes + 1) + #""}}"#
        try write("one", lines: [meta("one"), huge, token(10, 2)])
        let result = try indexer().scan()
        #expect(result.events.map(\.usage.total) == [12])
        #expect(!(result.warnings.isEmpty))
        #expect(try Data(contentsOf: cacheURL).count < 10_000)
    }

    @Test func testLargeValidConversationLineBelowLimitIsParsedWithoutWarning() throws {
        let large = #"{"type":"response_item","payload":{"content":""# + String(repeating: "x", count: 4 * 1_024 * 1_024) + #""}}"#
        try write("one", lines: [meta("one"), large, token(10, 2)])
        let result = try indexer().scan()
        #expect(result.events.map(\.usage.total) == [12])
        #expect(result.warnings.isEmpty)
        #expect(try Data(contentsOf: cacheURL).count < 10_000)
    }

    private func indexer() -> UsageIndexer { UsageIndexer(codexHomes: [home], cacheURL: cacheURL) }

    @discardableResult
    private func write(_ name: String, lines: [String]) throws -> URL {
        let url = home.appendingPathComponent("sessions/\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func meta(_ id: String, model: String? = nil, fork: String? = nil) -> String {
        var payload: [String: Any] = ["id": id, "base_instructions": "NEVER_STORE_THIS_INSTRUCTION"]
        if let model { payload["model"] = model }
        if let fork { payload["forked_from_id"] = fork }
        return json(["type": "session_meta", "payload": payload])
    }

    private func context(_ model: String) -> String {
        json(["type": "turn_context", "payload": ["model": model]])
    }

    private func settings(_ id: String) -> String {
        json(["type": "event_msg", "payload": ["type": "thread_settings_applied", "thread_id": id]])
    }

    private func token(_ input: Int, _ output: Int, cached: Int = 0, reasoning: Int = 0,
                       second: Int = 0, model: String? = nil, lastOnly: Bool = false) -> String {
        let usage = ["input_tokens": input, "output_tokens": output, "total_tokens": input + output,
                     "cached_input_tokens": cached, "reasoning_output_tokens": reasoning]
        var info: [String: Any] = ["last_token_usage": usage]
        if !lastOnly { info["total_token_usage"] = usage }
        if let model { info["model"] = model }
        return json(["type": "event_msg", "timestamp": String(format: "2026-09-24T10:00:%02dZ", second),
                     "payload": ["type": "token_count", "info": info]])
    }

    private func json(_ value: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}
