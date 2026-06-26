import Foundation
import OSLog

/// Persists the download queue as a single JSON file in
/// `~/Library/Application Support/Macget/queue.json`. All access is async and
/// serialized via the actor.
actor DownloadStore {
    private let fileURL: URL
    private let log = Logger(subsystem: "com.macget", category: "DownloadStore")
    private var debounceTask: Task<Void, Never>?
    private var pendingWrite: [Download]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let appSupport = (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            let dir = appSupport.appendingPathComponent("Macget", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("queue.json")
        }
    }

    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    func load() -> [Download] {
        if let primary = decodeQueue(at: fileURL) { return primary }
        // The atomic write prevents torn files, so a primary that exists but won't
        // decode means bad *content* (a botched upgrade/edit). Fall back to the
        // last-known-good backup before giving up.
        if FileManager.default.fileExists(atPath: fileURL.path),
           let backup = decodeQueue(at: backupURL) {
            log.warning("queue.json failed to decode — recovered \(backup.count) item(s) from queue.json.bak.")
            return backup
        }
        return []
    }

    private func decodeQueue(at url: URL) -> [Download]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Download].self, from: data)
        } catch {
            log.error("Failed to decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    /// Replaces the persisted queue. Writes are debounced 500ms to coalesce
    /// rapid updates from progress reporting.
    func saveAll(_ downloads: [Download]) {
        pendingWrite = downloads
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.flushIfNeeded()
        }
    }

    /// Upsert one download into the persisted queue. Reads-modifies-writes the
    /// whole file. For our queue size this is fine.
    func upsert(_ download: Download) {
        var current = load()
        if let i = current.firstIndex(where: { $0.id == download.id }) {
            current[i] = download
        } else {
            current.append(download)
        }
        saveAll(current)
    }

    func delete(_ id: UUID) {
        var current = load()
        current.removeAll { $0.id == id }
        saveAll(current)
    }

    /// Replace the whole persisted queue and flush right away (no debounce). Used
    /// for manual reordering so the new order survives even if a debounced
    /// progress write would otherwise read a stale on-disk order in between.
    func replaceAllImmediately(_ downloads: [Download]) async {
        pendingWrite = downloads
        debounceTask?.cancel()
        debounceTask = nil
        await flushIfNeeded()
    }

    /// Write any pending state immediately (used at app shutdown).
    func flushIfNeeded() async {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(pending)
            // Snapshot the current good file as a backup before overwriting, so a
            // future bad write/upgrade can be recovered from queue.json.bak.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write queue.json: \(error.localizedDescription)")
        }
    }
}
