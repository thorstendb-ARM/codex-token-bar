import Foundation
import Testing
@testable import TokenBarCore

@Suite
final class UsageCacheStoreTests {
    private struct Record: Codable, Equatable {
        let value: Int
        var failEncoding = false

        enum CodingKeys: String, CodingKey { case value }

        init(_ value: Int, failEncoding: Bool = false) {
            self.value = value
            self.failEncoding = failEncoding
        }

        func encode(to encoder: Encoder) throws {
            if failEncoding { throw CocoaError(.fileWriteUnknown) }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
        }
    }

    private struct Manifest: Codable {
        var version = 3
        var files: [String: String]
    }

    private struct Legacy: Encodable {
        let version = 2
        let files: [String: Record]
    }

    private let directory: URL
    private let cacheURL: URL
    private let recordsURL: URL
    private let manager = FileManager.default

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UsageCacheStoreTests-\(UUID().uuidString)")
        cacheURL = directory.appendingPathComponent("index.json")
        recordsURL = URL(fileURLWithPath: cacheURL.path + ".records", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? manager.removeItem(at: directory) }

    @Test func missingCacheReturnsNil() throws {
        let store = makeStore()
        #expect(try store.load() == nil)
        #expect(!store.needsMigration)
    }

    @Test func legacyCacheMigratesWithoutRequiringChangedPaths() throws {
        let files = ["a": Record(1), "b": Record(2)]
        try JSONEncoder().encode(Legacy(files: files)).write(to: cacheURL)
        let store = makeStore()
        #expect(try store.load() == files)
        #expect(store.needsMigration)
        try store.save(files, changedPaths: [])
        #expect(!store.needsMigration)
        #expect(try manifest().version == 3)
        #expect(try shardNames().count == 2)
        #expect(try makeStore().load() == files)
        for url in [cacheURL] + (try shardNames()).map({ recordsURL.appendingPathComponent($0) }) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func onlyChangedRecordsAreRewrittenAndOldGenerationsAreRemoved() throws {
        let store = makeStore()
        try store.save(["a": Record(1), "b": Record(2)], changedPaths: [])
        let original = try manifest()
        let a = try #require(original.files["a"])
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try manager.setAttributes([.modificationDate: sentinel], ofItemAtPath: recordsURL.appendingPathComponent(a).path)

        for value in 3...7 {
            try store.save(["a": Record(1), "b": Record(value)], changedPaths: ["b"])
            let current = try manifest()
            #expect(current.files["a"] == original.files["a"])
            #expect(current.files["b"] != original.files["b"])
            #expect(try shardNames() == Set(current.files.values))
        }
        let attributes = try manager.attributesOfItem(atPath: recordsURL.appendingPathComponent(a).path)
        #expect(attributes[.modificationDate] as? Date == sentinel)
        #expect(try makeStore().load() == ["a": Record(1), "b": Record(7)])
    }

    @Test func unchangedSavePreservesManifestAndShards() throws {
        let store = makeStore()
        let files = ["a": Record(1)]
        try store.save(files, changedPaths: [])
        let original = try Data(contentsOf: cacheURL)
        let names = try shardNames()
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try manager.setAttributes([.modificationDate: sentinel], ofItemAtPath: cacheURL.path)
        try store.save(files, changedPaths: [])
        #expect(try Data(contentsOf: cacheURL) == original)
        #expect(try shardNames() == names)
        #expect(try manager.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date == sentinel)
    }

    @Test func failedSavePreservesCommitCleansStagingAndRetriesChanges() throws {
        let store = makeStore()
        let original = ["a": Record(1), "b": Record(2)]
        try store.save(original, changedPaths: [])
        let manifestData = try Data(contentsOf: cacheURL)
        let names = try shardNames()
        for _ in 0..<3 {
            // The sorted "a" shard is already written when encoding "b" fails.
            #expect(throws: (any Error).self) {
                try store.save(["a": Record(10), "b": Record(20, failEncoding: true)], changedPaths: ["a", "b"])
            }
            #expect(try Data(contentsOf: cacheURL) == manifestData)
            #expect(try shardNames() == names)
            #expect(try makeStore().load() == original)
        }
        let updated = ["a": Record(10), "b": Record(20)]
        try store.save(updated, changedPaths: [])
        #expect(try makeStore().load() == updated)
        #expect(try shardNames().count == 2)
    }

    @Test func removedRecordsAndTheirShardsAreRetired() throws {
        let store = makeStore()
        try store.save(["a": Record(1), "b": Record(2)], changedPaths: [])
        try store.save(["b": Record(2)], changedPaths: [])
        #expect(try makeStore().load() == ["b": Record(2)])
        #expect(try shardNames() == Set(manifest().files.values))
        try store.save([:], changedPaths: [])
        #expect(try makeStore().load() == [:])
        #expect(try shardNames().isEmpty)
    }

    @Test func successfulLoadCleansInterruptedWritesButKeepsUnrelatedFiles() throws {
        let store = makeStore()
        try store.save(["a": Record(1)], changedPaths: [])
        let orphan = recordsURL.appendingPathComponent(UUID().uuidString + ".json")
        let unrelated = recordsURL.appendingPathComponent("notes.json")
        let unrelatedDirectory = recordsURL.appendingPathComponent(UUID().uuidString + ".json", isDirectory: true)
        try Data("interrupted write".utf8).write(to: orphan)
        try Data("unrelated".utf8).write(to: unrelated)
        try manager.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)
        #expect(try makeStore().load() == ["a": Record(1)])
        #expect(!manager.fileExists(atPath: orphan.path))
        #expect(manager.fileExists(atPath: unrelated.path))
        #expect(manager.fileExists(atPath: unrelatedDirectory.path))
    }

    @Test func corruptShardFailsWithoutGarbageCollectingAndSaveRebuilds() throws {
        let store = makeStore()
        try store.save(["a": Record(1)], changedPaths: [])
        let name = try #require(manifest().files["a"])
        try Data("corrupt".utf8).write(to: recordsURL.appendingPathComponent(name))
        let orphan = recordsURL.appendingPathComponent(UUID().uuidString + ".json")
        try Data("interrupted".utf8).write(to: orphan)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(manager.fileExists(atPath: orphan.path))
        try store.save(["a": Record(2)], changedPaths: [])
        #expect(try makeStore().load() == ["a": Record(2)])
        #expect(try shardNames().count == 1)
    }

    @Test func malformedManifestAndUnsafeShardNamesAreRejected() throws {
        let outside = directory.appendingPathComponent("outside.json")
        try JSONEncoder().encode(Record(123)).write(to: outside)
        let invalidNames = ["../outside.json", outside.path, "ordinary.json", "../" + UUID().uuidString + ".json",
                            UUID().uuidString + ".json/extra"]
        for name in invalidNames {
            try JSONEncoder().encode(Manifest(files: ["a": name])).write(to: cacheURL)
            #expect(throws: (any Error).self) { try makeStore().load() }
            #expect(manager.fileExists(atPath: outside.path))
        }
        try Data("invalid JSON".utf8).write(to: cacheURL)
        #expect(throws: (any Error).self) { try makeStore().load() }
        try JSONEncoder().encode(Manifest(version: 99, files: [:])).write(to: cacheURL)
        #expect(throws: (any Error).self) { try makeStore().load() }
    }

    @Test func symlinkShardDirectoryCannotWriteOrCleanOutsideTheCache() throws {
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        let unrelated = outside.appendingPathComponent(UUID().uuidString + ".json")
        let content = Data("unrelated file".utf8)
        try content.write(to: unrelated)
        try manager.createSymbolicLink(at: recordsURL, withDestinationURL: outside)

        let store = makeStore()
        #expect(throws: UsageReadError.self) { try store.load() }
        #expect(throws: UsageReadError.self) { try store.save(["a": Record(1)], changedPaths: []) }
        #expect(!manager.fileExists(atPath: cacheURL.path))
        for data in [try JSONEncoder().encode(Legacy(files: [:])),
                     try JSONEncoder().encode(Manifest(files: [:]))] {
            try data.write(to: cacheURL)
            #expect(throws: UsageReadError.self) { try store.load() }
            #expect(throws: UsageReadError.self) { try store.save(["a": Record(1)], changedPaths: []) }
            #expect(try Data(contentsOf: cacheURL) == data)
            #expect(try Data(contentsOf: unrelated) == content)
            #expect(try manager.contentsOfDirectory(atPath: outside.path) == [unrelated.lastPathComponent])
        }
    }

    @Test func referencedShardSymlinkIsRejectedWithoutReadingItsTarget() throws {
        let store = makeStore()
        try store.save(["a": Record(1)], changedPaths: [])
        let shard = recordsURL.appendingPathComponent(try #require(manifest().files["a"]))
        let outside = directory.appendingPathComponent("outside.json")
        let content = try JSONEncoder().encode(Record(999))
        try content.write(to: outside)
        try manager.removeItem(at: shard)
        try manager.createSymbolicLink(at: shard, withDestinationURL: outside)

        #expect(throws: UsageReadError.self) { try makeStore().load() }
        #expect(try Data(contentsOf: outside) == content)
        #expect(try manager.destinationOfSymbolicLink(atPath: shard.path) == outside.path)
    }

    @Test func missingManifestRewritesAllRecordsAndCleansOldShards() throws {
        let store = makeStore()
        try store.save(["a": Record(1), "b": Record(2)], changedPaths: [])
        let oldNames = try shardNames()
        try manager.removeItem(at: cacheURL)
        let files = ["a": Record(3), "b": Record(2)]
        try store.save(files, changedPaths: ["a"])
        #expect(try makeStore().load() == files)
        #expect(try shardNames().isDisjoint(with: oldNames))
        #expect(try shardNames().count == 2)
    }

    @Test func separateStoresCanReuseTheCachePathWithoutDanglingShards() throws {
        let first = makeStore()
        try first.save(["a": Record(1)], changedPaths: [])
        let second = makeStore()
        #expect(try second.load() == ["a": Record(1)])
        try second.save(["b": Record(2)], changedPaths: ["b"])
        // The first store's in-memory shard names were retired by the second store.
        try first.save(["a": Record(3)], changedPaths: [])
        #expect(try makeStore().load() == ["a": Record(3)])
        #expect(try shardNames().count == 1)
    }

    private func makeStore() -> UsageCacheStore<Record> { UsageCacheStore(url: cacheURL) }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: cacheURL))
    }

    private func shardNames() throws -> Set<String> {
        Set(try manager.contentsOfDirectory(atPath: recordsURL.path))
    }
}
