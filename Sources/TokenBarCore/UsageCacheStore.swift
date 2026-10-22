import Darwin
import Foundation

/// Immutable record shards keep an append from rewriting the entire usage history.
/// The manifest is the commit point; unreferenced managed files can always be removed.
final class UsageCacheStore<Record: Codable> {
    private struct Version: Decodable { let version: Int }
    private struct Legacy: Decodable { let files: [String: Record] }
    private struct Manifest: Codable, Equatable {
        var version = 3
        var files: [String: String]
    }

    private let cacheURL: URL
    private let recordsURL: URL
    private let manager = FileManager.default
    private var committed: Manifest?
    private var pendingChanges = Set<String>()
    private(set) var needsMigration = false

    init(url: URL) {
        cacheURL = url
        recordsURL = URL(fileURLWithPath: url.path + ".records", isDirectory: true)
    }

    func load() throws -> [String: Record]? {
        committed = nil
        pendingChanges.removeAll()
        needsMigration = false
        try validateFileType(at: recordsURL, expected: S_IFDIR, allowMissing: true)
        guard manager.fileExists(atPath: cacheURL.path) else { return nil }
        return try withLock {
            try validateFileType(at: recordsURL, expected: S_IFDIR, allowMissing: true)
            guard manager.fileExists(atPath: cacheURL.path) else { return nil }
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            switch try decoder.decode(Version.self, from: data).version {
            case 2:
                let legacy = try decoder.decode(Legacy.self, from: data)
                needsMigration = true
                removeUnreferencedFiles(keeping: [])
                return legacy.files
            case 3:
                let manifest = try decodeManifest(data)
                var files: [String: Record] = [:]
                files.reserveCapacity(manifest.files.count)
                for (path, name) in manifest.files {
                    let url = recordsURL.appendingPathComponent(name)
                    try validateFileType(at: url, expected: S_IFREG)
                    files[path] = try decoder.decode(Record.self,
                        from: Data(contentsOf: url))
                }
                committed = manifest
                removeUnreferencedFiles(keeping: Set(manifest.files.values))
                return files
            default:
                throw UsageReadError.malformedRecord
            }
        }
    }

    func save(_ files: [String: Record], changedPaths: Set<String>) throws {
        // A failed write must still be retried if the next scan has no new changes.
        pendingChanges.formUnion(changedPaths)
        try manager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try withLock {
            try validateFileType(at: recordsURL, expected: S_IFDIR, allowMissing: true)
            try manager.createDirectory(at: recordsURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try validateFileType(at: recordsURL, expected: S_IFDIR)
            // Another process may have used the same cache path and retired our shards.
            let onDisk = (try? Data(contentsOf: cacheURL)).flatMap { try? decodeManifest($0) }
            let reusable = committed != nil && onDisk == committed
            var manifest = reusable ? committed! : Manifest(files: [:])
            manifest.files = manifest.files.filter { files[$0.key] != nil }
            let pathsToWrite = files.keys.filter {
                !reusable || pendingChanges.contains($0) || manifest.files[$0] == nil
            }.sorted()
            var staged: [URL] = []
            do {
                let encoder = JSONEncoder()
                for path in pathsToWrite {
                    let name = UUID().uuidString + ".json"
                    let url = recordsURL.appendingPathComponent(name)
                    try writeAtomically(encoder.encode(files[path]!), to: url)
                    staged.append(url)
                    manifest.files[path] = name
                }
                if manifest != onDisk {
                    try writeAtomically(encoder.encode(manifest), to: cacheURL)
                }
            } catch {
                for url in staged { try? manager.removeItem(at: url) }
                throw error
            }
            committed = manifest
            pendingChanges.removeAll()
            needsMigration = false
            removeUnreferencedFiles(keeping: Set(manifest.files.values))
        }
    }

    private func decodeManifest(_ data: Data) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 3, manifest.files.values.allSatisfy(isManagedFilename) else {
            throw UsageReadError.malformedRecord
        }
        return manifest
    }

    private func isManagedFilename(_ name: String) -> Bool {
        guard name.utf8.count == 41, name.hasSuffix(".json"),
              let uuid = UUID(uuidString: String(name.dropLast(5))) else { return false }
        return uuid.uuidString.lowercased() + ".json" == name.lowercased()
    }

    private func validateFileType(at url: URL, expected: mode_t, allowMissing: Bool = false) throws {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else {
            if allowMissing && errno == ENOENT { return }
            throw posixError()
        }
        guard attributes.st_mode & S_IFMT == expected else { throw UsageReadError.invalidCacheLocation }
    }

    private func removeUnreferencedFiles(keeping names: Set<String>) {
        // Never follow a replacement shard-directory symlink while cleaning up.
        do { try validateFileType(at: recordsURL, expected: S_IFDIR) }
        catch { return }
        let retainedNames = Set(names.map { $0.lowercased() })
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let urls = try? manager.contentsOfDirectory(at: recordsURL,
                                                         includingPropertiesForKeys: Array(keys)) else { return }
        for url in urls where isManagedFilename(url.lastPathComponent) && !retainedNames.contains(url.lastPathComponent.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            try? manager.removeItem(at: url)
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        // Staging files use managed names too, so a crash cannot accumulate temp files.
        let temporary = recordsURL.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        // Serialize readers/GC and writers across the menu app and --report processes.
        let descriptor = open(cacheURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
