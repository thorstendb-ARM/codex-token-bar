import Foundation

/// A serial, local-only JSONL index. The cache contains token/file metadata, never prompts.
public final class UsageIndexer {
    private let codexHomes: [URL]
    private let cacheURL: URL
    private let lock = NSLock()
    private var cache: IndexCache?
    private var cacheNeedsSave = true
    private let manager = FileManager.default
    static let maximumLineBytes = 16 * 1_024 * 1_024

    public init(codexHomes: [URL], cacheURL: URL) {
        self.codexHomes = Array(Set(codexHomes.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
        self.cacheURL = cacheURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func scan(progress: ((IndexProgress) -> Void)? = nil) throws -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !codexHomes.contains(where: { isInside(cacheURL, directory: $0) }) else {
            throw UsageReadError.invalidCacheLocation
        }
        var warnings: [String] = []
        var working = loadCache(warnings: &warnings)
        let urls = discover(warnings: &warnings)
        let paths = Set(urls.map(\.path))
        progress?(IndexProgress(completed: 0, total: urls.count))
        var movedPaths = Set<String>()
        for (index, url) in urls.enumerated() {
            do {
                let attributes = try fileAttributes(url)
                var previous = working.files[url.path]
                var movedPath: String?
                if previous == nil {
                    // Ordinary session -> archive moves retain device/inode and cursor.
                    if let moved = working.files.first(where: {
                        !paths.contains($0.key) && $0.value.identity == attributes.identity
                    }) {
                        previous = moved.value
                        movedPath = moved.key
                    }
                }
                let result = try read(url, attributes: attributes, previous: previous)
                if movedPath != nil || previous.map({ !result.hasSameCursor(as: $0) }) ?? true {
                    cacheNeedsSave = true
                }
                working.files[url.path] = result
                if let movedPath { movedPaths.insert(movedPath) }
                if result.oversizedLines > 0 {
                    warnings.append("\(url.lastPathComponent): \(result.oversizedLines) übergroße JSONL-Zeile(n) ausgelassen.")
                }
                if !result.state.ownHistoryStarted && result.state.inheritedTokenRecords > 0 {
                    warnings.append("\(url.lastPathComponent): Fork ohne erkennbaren Eigenstart; geerbte Token-Zähler nicht mitgezählt.")
                }
                if result.state.missingBaselineRecords > 0 {
                    warnings.append("\(url.lastPathComponent): erster Fork-Verbrauch ohne sichere Baseline/last_token_usage ausgelassen.")
                }
            } catch {
                warnings.append("\(url.lastPathComponent): nicht vollständig lesbar; letzter guter Stand bleibt erhalten, neuer Versuch beim nächsten Scan.")
            }
            progress?(IndexProgress(completed: index + 1, total: urls.count))
        }
        for path in movedPaths { working.files.removeValue(forKey: path) }
        for path in working.files.keys.sorted() where !paths.contains(path) {
            warnings.append("\(URL(fileURLWithPath: path).lastPathComponent): derzeit nicht gefunden; letzter guter Stand bleibt erhalten.")
        }
        let events = aggregate(working.files)
        let sessions = Set(working.files.map { $0.value.state.sessionID ?? "file:\(usageDigest($0.key))" })
        cache = working
        if cacheNeedsSave || !manager.fileExists(atPath: cacheURL.path) {
            do {
                try saveCache(working)
                cacheNeedsSave = false
            } catch {
                cacheNeedsSave = true
                warnings.append("Der lokale Nutzungs-Cache konnte nicht gespeichert werden; die Anzeige bleibt verfügbar.")
            }
        }
        if warnings.count > 24 {
            let omitted = warnings.count - 24
            warnings = Array(warnings.prefix(24)) + ["\(omitted) weitere Dateiwarnungen."]
        }
        return UsageSnapshot(events: events, indexedSessions: sessions.count, scannedFiles: urls.count,
                             warnings: warnings, scannedAt: Date())
    }

    private struct IndexCache: Codable {
        var version = 2
        var files: [String: FileRecord] = [:]
    }

    private struct FileRecord: Codable {
        var identity: String
        var observedSize: UInt64
        var modified: Date
        var offset: UInt64
        var prefixLength: Int
        var prefixDigest: String
        var anchorDigest: String
        var state: UsageParserState
        var events: [IndexedUsageEvent]
        var oversizedLines: Int

        func hasSameCursor(as other: FileRecord) -> Bool {
            identity == other.identity && observedSize == other.observedSize && modified == other.modified &&
                offset == other.offset && prefixLength == other.prefixLength && prefixDigest == other.prefixDigest &&
                anchorDigest == other.anchorDigest
        }
    }

    private struct FileAttributes {
        var identity: String
        var size: UInt64
        var modified: Date
    }

    private func loadCache(warnings: inout [String]) -> IndexCache {
        if let cache { return cache }
        guard manager.fileExists(atPath: cacheURL.path) else { return IndexCache() }
        do {
            let loaded = try JSONDecoder().decode(IndexCache.self, from: Data(contentsOf: cacheURL))
            guard loaded.version == 2 else { throw UsageReadError.malformedRecord }
            var filtered = loaded
            filtered.files = loaded.files.filter { entry in
                let url = URL(fileURLWithPath: entry.key).standardizedFileURL
                return codexHomes.contains { home in
                    isInside(url, directory: home.appendingPathComponent("sessions")) ||
                    isInside(url, directory: home.appendingPathComponent("archived_sessions"))
                }
            }
            cacheNeedsSave = filtered.files.count != loaded.files.count
            return filtered
        } catch {
            warnings.append("Der lokale Nutzungs-Cache ist nicht lesbar oder veraltet; JSONL-Dateien werden neu indexiert.")
            return IndexCache()
        }
    }

    private func discover(warnings: inout [String]) -> [URL] {
        var found = Set<URL>()
        var discoveryWarnings: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        for home in codexHomes {
            for name in ["sessions", "archived_sessions"] {
                let directory = home.appendingPathComponent(name, isDirectory: true)
                guard manager.fileExists(atPath: directory.path) else { continue }
                guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { url, _ in
                    discoveryWarnings.append("\(url.lastPathComponent): Verzeichnis nicht lesbar; bisherige Daten bleiben erhalten.")
                    return true
                }) else {
                    warnings.append("\(directory.path): Verzeichnis nicht lesbar.")
                    continue
                }
                for case let url as URL in enumerator {
                    do {
                        let values = try url.resourceValues(forKeys: Set(keys))
                        if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                        if values.isRegularFile == true && url.pathExtension.lowercased() == "jsonl" {
                            found.insert(url.standardizedFileURL)
                        }
                    } catch { warnings.append("\(url.lastPathComponent): Dateieigenschaften nicht lesbar.") }
                }
            }
        }
        warnings.append(contentsOf: discoveryWarnings)
        if found.isEmpty { warnings.append("Keine lesbaren Codex-JSONL-Dateien in sessions oder archived_sessions gefunden.") }
        return found.sorted { $0.path < $1.path }
    }

    private func fileAttributes(_ url: URL) throws -> FileAttributes {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { throw UsageReadError.changedDuringRead }
        return FileAttributes(identity: "\(device):\(inode)", size: size.uint64Value, modified: modified)
    }

    private func read(_ url: URL, attributes: FileAttributes, previous: FileRecord?) throws -> FileRecord {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var retained = previous
        if let old = retained {
            if old.identity != attributes.identity || attributes.size < old.observedSize ||
                old.offset > attributes.size || (attributes.size == old.observedSize && attributes.modified != old.modified) {
                retained = nil
            } else {
                let prefix = try bytes(handle, from: 0, count: old.prefixLength)
                let anchorLength = Int(min(old.offset, 512))
                let anchor = try bytes(handle, from: old.offset - UInt64(anchorLength), count: anchorLength)
                if usageDigest(prefix) != old.prefixDigest || usageDigest(anchor) != old.anchorDigest { retained = nil }
            }
        }
        var record = retained ?? FileRecord(identity: attributes.identity, observedSize: 0, modified: attributes.modified,
                                            offset: 0, prefixLength: 0, prefixDigest: "", anchorDigest: "",
                                            state: UsageParserState(), events: [], oversizedLines: 0)
        // EOF fragments are reread next time; only newline-terminated records commit.
        try handle.seek(toOffset: record.offset)
        var position = record.offset
        var line = Data()
        var oversized = false
        while position < attributes.size {
            let amount = Int(min(UInt64(64 * 1_024), attributes.size - position))
            guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                throw UsageReadError.changedDuringRead
            }
            func append(_ fragment: Data.SubSequence) {
                guard !oversized else { return }
                if line.count + fragment.count > Self.maximumLineBytes {
                    line.removeAll(keepingCapacity: false)
                    oversized = true
                } else { line.append(fragment) }
            }
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 10) {
                let fragment = chunk[start..<newline]
                append(fragment)
                position += UInt64(fragment.count + 1)
                if oversized { record.oversizedLines += 1 }
                else if let event = try UsageParser.parse(line, state: &record.state) { record.events.append(event) }
                record.offset = position
                line.removeAll(keepingCapacity: true)
                oversized = false
                start = chunk.index(after: newline)
            }
            let remainder = chunk[start...]
            append(remainder)
            position += UInt64(remainder.count)
        }
        let after = try fileAttributes(url)
        guard after.identity == attributes.identity, after.size >= attributes.size,
              !(after.size == attributes.size && after.modified != attributes.modified) else {
            throw UsageReadError.changedDuringRead
        }
        record.observedSize = attributes.size
        record.modified = attributes.modified
        record.prefixLength = Int(min(record.offset, 4_096))
        record.prefixDigest = usageDigest(try bytes(handle, from: 0, count: record.prefixLength))
        let anchorLength = Int(min(record.offset, 512))
        record.anchorDigest = usageDigest(try bytes(handle, from: record.offset - UInt64(anchorLength), count: anchorLength))
        return record
    }

    private func bytes(_ handle: FileHandle, from offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw UsageReadError.changedDuringRead }
        return data
    }

    private func aggregate(_ files: [String: FileRecord]) -> [UsageEvent] {
        var result: [String: UsageEvent] = [:]
        for path in files.keys.sorted() {
            guard let record = files[path] else { continue }
            let session = record.state.sessionID ?? "file:\(usageDigest(path))"
            for value in record.events {
                let id = usageDigest("\(session)|\(value.fingerprint)")
                if var existing = result[id] {
                    if existing.model == nil { existing.model = value.model; result[id] = existing }
                } else {
                    result[id] = UsageEvent(id: id, timestamp: value.timestamp, model: value.model, usage: value.usage)
                }
            }
        }
        return result.values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }

    private func saveCache(_ cache: IndexCache) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(cache)
        try data.write(to: cacheURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    private func isInside(_ url: URL, directory: URL) -> Bool {
        url.path == directory.path || url.path.hasPrefix(directory.path + "/")
    }
}
