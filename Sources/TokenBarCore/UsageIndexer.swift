import Foundation
import Darwin

/// A serial, local-only JSONL index. The cache contains token/file metadata, never prompts.
public final class UsageIndexer {
    private let codexHomes: [URL]
    private let cacheURL: URL
    private let lock = NSLock()
    private var cache: IndexCache?
    private var cacheNeedsSave = true
    private let manager = FileManager.default
    private let parser = UsageParser()
    private lazy var cacheStore = UsageCacheStore<FileRecord>(url: cacheURL)
    private var dirtyPaths = Set<String>()
    private var normalizedEvents: [String: [UsageEvent]] = [:]
    private var aggregatedEvents: [UsageEvent]?
    private var eventsRevision: UInt64 = 0
    private var indexedSessions = 0
    private(set) var lastScanStatistics = ScanStatistics()
    static let maximumLineBytes = 16 * 1_024 * 1_024
    static let missingFileRetention: TimeInterval = 7 * 24 * 60 * 60

    struct ScanStatistics {
        var filesRead = 0
        var bytesRead = 0
        var eventIDsGenerated = 0
        var aggregationRebuilds = 0
    }

    public init(codexHomes: [URL], cacheURL: URL) {
        self.codexHomes = Array(Set(codexHomes.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
        self.cacheURL = cacheURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func scan(now: Date = Date(), progress: ((IndexProgress) -> Void)? = nil) throws -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !codexHomes.contains(where: { isInside(cacheURL, directory: $0) }) else {
            throw UsageReadError.invalidCacheLocation
        }
        var warnings: [String] = []
        lastScanStatistics = ScanStatistics()
        var working = loadCache(warnings: &warnings)
        // Give this scan sole ownership instead of copying the whole dictionary on mutation.
        cache = nil
        var discoveryComplete = true
        let urls = discover(warnings: &warnings, complete: &discoveryComplete)
        let paths = Set(urls.map(\.path))
        let absentPaths = working.files.keys.filter { !paths.contains($0) }.sorted()
        var missingByIdentity: [String: String] = [:]
        for path in absentPaths {
            if let record = working.files[path], missingByIdentity[record.identity] == nil {
                missingByIdentity[record.identity] = path
            }
        }
        progress?(IndexProgress(completed: 0, total: urls.count))
        var movedPaths = Set<String>()
        var changedEventPaths = Set<String>()
        for (index, url) in urls.enumerated() {
            let path = url.path
            do {
                let attributes = try fileAttributes(url)
                var previous = working.files[path]
                var movedPath: String?
                if previous == nil {
                    // Ordinary session -> archive moves retain device/inode and cursor.
                    if let path = missingByIdentity.removeValue(forKey: attributes.identity) {
                        previous = working.files[path]
                        movedPath = path
                    }
                }
                var result = try read(url, attributes: attributes, previous: previous)
                result.missingSince = nil
                if movedPath != nil || previous.map({ !result.hasSameCursor(as: $0) }) ?? true {
                    cacheNeedsSave = true
                    dirtyPaths.insert(path)
                    working.files[path] = result
                    if movedPath != nil || previous == nil || result.state.sessionID != previous?.state.sessionID ||
                        result.events != previous?.events {
                        changedEventPaths.insert(path)
                    }
                }
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
        for path in movedPaths {
            working.files.removeValue(forKey: path)
            normalizedEvents.removeValue(forKey: path)
            dirtyPaths.insert(path)
            changedEventPaths.insert(path)
        }
        for path in absentPaths where !movedPaths.contains(path) {
            if discoveryComplete && working.files[path]?.missingSince == nil {
                working.files[path]?.missingSince = now
                dirtyPaths.insert(path)
                cacheNeedsSave = true
            }
            if discoveryComplete, let missingSince = working.files[path]?.missingSince,
               now.timeIntervalSince(missingSince) >= Self.missingFileRetention {
                working.files.removeValue(forKey: path)
                normalizedEvents.removeValue(forKey: path)
                dirtyPaths.insert(path)
                changedEventPaths.insert(path)
                cacheNeedsSave = true
                continue
            }
            warnings.append("\(URL(fileURLWithPath: path).lastPathComponent): derzeit nicht gefunden; letzter guter Stand bleibt erhalten.")
        }
        if aggregatedEvents == nil || !changedEventPaths.isEmpty {
            aggregatedEvents = aggregate(working.files, changedPaths: changedEventPaths)
            indexedSessions = Set(working.files.map { $0.value.state.sessionID ?? "file:\(usageDigest($0.key))" }).count
            eventsRevision &+= 1
        }
        cache = working
        if cacheNeedsSave || !manager.fileExists(atPath: cacheURL.path) {
            do {
                try cacheStore.save(working.files, changedPaths: dirtyPaths)
                cacheNeedsSave = false
                dirtyPaths.removeAll(keepingCapacity: true)
            } catch {
                cacheNeedsSave = true
                warnings.append("Der lokale Nutzungs-Cache konnte nicht gespeichert werden; die Anzeige bleibt verfügbar.")
            }
        }
        if warnings.count > 24 {
            let omitted = warnings.count - 24
            warnings = Array(warnings.prefix(24)) + ["\(omitted) weitere Dateiwarnungen."]
        }
        return UsageSnapshot(events: aggregatedEvents ?? [], indexedSessions: indexedSessions, scannedFiles: urls.count,
                             warnings: warnings, scannedAt: now, eventsRevision: eventsRevision)
    }

    private struct IndexCache {
        var files: [String: FileRecord] = [:]
    }

    private struct FileRecord: Codable {
        var identity: String
        var observedSize: UInt64
        var modified: Date
        var changed: Date?
        var missingSince: Date?
        var offset: UInt64
        var prefixLength: Int
        var prefixDigest: String
        var anchorDigest: String
        var state: UsageParserState
        var events: [IndexedUsageEvent]
        var oversizedLines: Int

        func hasSameCursor(as other: FileRecord) -> Bool {
            identity == other.identity && observedSize == other.observedSize && modified == other.modified &&
                changed == other.changed && missingSince == other.missingSince &&
                offset == other.offset && prefixLength == other.prefixLength && prefixDigest == other.prefixDigest &&
                anchorDigest == other.anchorDigest
        }
    }

    private struct FileAttributes {
        var identity: String
        var size: UInt64
        var modified: Date
        var changed: Date
    }

    private func loadCache(warnings: inout [String]) -> IndexCache {
        if let cache { return cache }
        guard manager.fileExists(atPath: cacheURL.path) else { return IndexCache() }
        do {
            let loaded = IndexCache(files: try cacheStore.load() ?? [:])
            var filtered = loaded
            filtered.files = loaded.files.filter { entry in
                let url = URL(fileURLWithPath: entry.key).standardizedFileURL
                return codexHomes.contains { home in
                    isInside(url, directory: home.appendingPathComponent("sessions")) ||
                    isInside(url, directory: home.appendingPathComponent("archived_sessions"))
                }
            }
            cacheNeedsSave = cacheStore.needsMigration || filtered.files.count != loaded.files.count
            return filtered
        } catch {
            warnings.append("Der lokale Nutzungs-Cache ist nicht lesbar oder veraltet; JSONL-Dateien werden neu indexiert.")
            return IndexCache()
        }
    }

    private func discover(warnings: inout [String], complete: inout Bool) -> [URL] {
        var found = Set<String>()
        var discoveryWarnings: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let keySet = Set(keys)
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
                    complete = false
                    continue
                }
                for case let url as URL in enumerator {
                    do {
                        let values = try url.resourceValues(forKeys: keySet)
                        if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                        if values.isRegularFile == true && url.pathExtension.lowercased() == "jsonl" {
                            found.insert(url.standardizedFileURL.path)
                        }
                    } catch {
                        complete = false
                        warnings.append("\(url.lastPathComponent): Dateieigenschaften nicht lesbar.")
                    }
                }
            }
        }
        warnings.append(contentsOf: discoveryWarnings)
        if !discoveryWarnings.isEmpty { complete = false }
        if found.isEmpty { warnings.append("Keine lesbaren Codex-JSONL-Dateien in sessions oder archived_sessions gefunden.") }
        // Compare paths as strings; URL.path decoding inside the sort comparator
        // otherwise dominates idle scans over thousands of files.
        return found.sorted().map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private func fileAttributes(_ url: URL) throws -> FileAttributes {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard status == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw UsageReadError.changedDuringRead
        }
        func date(_ time: timespec) -> Date {
            // Match Foundation's reference epoch before adding fractions; converting
            // through Unix-epoch Double loses precision and invalidates legacy cursors.
            Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
                 + Double(time.tv_nsec) / 1_000_000_000)
        }
        return FileAttributes(identity: "\(info.st_dev):\(info.st_ino)", size: UInt64(info.st_size),
                              modified: date(info.st_mtimespec), changed: date(info.st_ctimespec))
    }

    private func read(_ url: URL, attributes: FileAttributes, previous: FileRecord?) throws -> FileRecord {
        if let previous, previous.identity == attributes.identity, previous.observedSize == attributes.size,
           previous.modified == attributes.modified, previous.changed == attributes.changed {
            return previous
        }
        lastScanStatistics.filesRead += 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var retained = previous
        if let old = retained {
            if old.identity != attributes.identity || attributes.size < old.observedSize ||
                old.offset > attributes.size || (attributes.size == old.observedSize &&
                    (attributes.modified != old.modified || (old.changed != nil && old.changed != attributes.changed))) {
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
            lastScanStatistics.bytesRead += chunk.count
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
                else if let event = try parser.parse(line, state: &record.state) { record.events.append(event) }
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
              !(after.size == attributes.size &&
                (after.modified != attributes.modified || after.changed != attributes.changed)) else {
            throw UsageReadError.changedDuringRead
        }
        record.observedSize = attributes.size
        record.modified = attributes.modified
        record.changed = attributes.changed
        record.prefixLength = Int(min(record.offset, 4_096))
        record.prefixDigest = usageDigest(try bytes(handle, from: 0, count: record.prefixLength))
        let anchorLength = Int(min(record.offset, 512))
        record.anchorDigest = usageDigest(try bytes(handle, from: record.offset - UInt64(anchorLength), count: anchorLength))
        return record
    }

    private func bytes(_ handle: FileHandle, from offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        lastScanStatistics.bytesRead += data.count
        guard data.count == count else { throw UsageReadError.changedDuringRead }
        return data
    }

    private func aggregate(_ files: [String: FileRecord], changedPaths: Set<String>) -> [UsageEvent] {
        lastScanStatistics.aggregationRebuilds += 1
        var result: [String: UsageEvent] = [:]
        for path in files.keys.sorted() {
            guard let record = files[path] else { continue }
            if normalizedEvents[path] == nil || changedPaths.contains(path) {
                let session = record.state.sessionID ?? "file:\(usageDigest(path))"
                normalizedEvents[path] = record.events.map { value in
                    lastScanStatistics.eventIDsGenerated += 1
                    return UsageEvent(id: usageDigest("\(session)|\(value.fingerprint)"),
                                      timestamp: value.timestamp, model: value.model, usage: value.usage)
                }
            }
            for event in normalizedEvents[path] ?? [] {
                if var existing = result[event.id] {
                    if existing.model == nil { existing.model = event.model; result[event.id] = existing }
                } else {
                    result[event.id] = event
                }
            }
        }
        return result.values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }

    private func isInside(_ url: URL, directory: URL) -> Bool {
        url.path == directory.path || url.path.hasPrefix(directory.path + "/")
    }
}
