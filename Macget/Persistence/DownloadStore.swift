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

    func load() -> [Download] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Download].self, from: data)
        } catch {
            log.error("Failed to load queue.json: \(error.localizedDescription)")
            return []
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

    /// Write any pending state immediately (used at app shutdown).
    func flushIfNeeded() async {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(pending)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write queue.json: \(error.localizedDescription)")
        }
    }
}
