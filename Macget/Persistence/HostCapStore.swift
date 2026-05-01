import Foundation
import OSLog

/// Persists per-host parallelism caps learned from the engine's adaptive
/// demotion. Saved as `~/Library/Application Support/Macget/host_caps.json`.
///
/// When a download against host H gets demoted to N workers because the server
/// rejects more, we remember that. Future downloads from H start at min(user,
/// learned). Caps only ratchet *downward*: a host that's hostile today is
/// usually hostile tomorrow, but never more permissive.
actor HostCapStore {
    static let shared = HostCapStore()

    private let fileURL: URL
    private var caps: [String: Int] = [:]
    private var loaded = false
    private var debounceTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.macget", category: "HostCapStore")

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
            self.fileURL = dir.appendingPathComponent("host_caps.json")
        }
    }

    func cap(for host: String) -> Int? {
        loadIfNeeded()
        return caps[host]
    }

    /// Records a learned cap for `host`. Only stores if it's a *tighter* limit
    /// than what we already have — so a single permissive run doesn't undo a
    /// prior demotion.
    func recordCap(_ cap: Int, for host: String) {
        loadIfNeeded()
        if let existing = caps[host], existing <= cap { return }
        caps[host] = cap
        log.info("Host cap learned: \(host) → \(cap)")
        scheduleSave()
    }

    /// Forget any learned cap for a host (used by tests / reset UI).
    func clear(host: String) {
        loadIfNeeded()
        caps.removeValue(forKey: host)
        scheduleSave()
    }

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            caps = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            log.error("Failed to load host_caps.json: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(caps)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write host_caps.json: \(error.localizedDescription)")
        }
    }
}
