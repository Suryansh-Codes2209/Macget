import Foundation
import OSLog

/// One learned cap, with the time it was learned.
///
/// The timestamp is what makes the cap forgettable. Without it a single
/// demotion — including one caused by a local network drop rather than the host
/// — held that host down permanently, with no expiry and no reset path.
struct CapRecord: Codable, Equatable {
    let cap: Int
    let recordedAt: Date
}

/// Persists per-host parallelism caps learned from the engine's adaptive
/// demotion. Saved as `~/Library/Application Support/Macget/host_caps.json`.
///
/// When a download against host H gets demoted to N workers because the server
/// rejects more, we remember that. Future downloads from H start at min(user,
/// learned). Caps ratchet *downward* within the retention window: a host that's
/// hostile now is usually still hostile in an hour, but never more permissive.
///
/// Records expire after `retention`. Forgetting outright rather than relaxing
/// gradually is deliberate — re-learning is cheap. If the host really is still
/// hostile, one demotion event costs about a second of the next download; if it
/// isn't, the user gets full speed back without having to know this cache
/// exists. The direction of the ratchet was right; its permanence wasn't.
actor HostCapStore {
    static let shared = HostCapStore()

    /// How long a learned cap stays in force. Long enough not to re-probe a
    /// genuinely hostile host on every download, short enough that a server
    /// configuration change heals within a week.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var caps: [String: CapRecord] = [:]
    private var loaded = false
    private var debounceTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.macget", category: "HostCapStore")

    init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
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
        guard let record = caps[host] else { return nil }
        guard !isExpired(record) else {
            caps.removeValue(forKey: host)
            scheduleSave()
            return nil
        }
        return record.cap
    }

    /// Records a learned cap for `host`. Only stores if it's a *tighter* limit
    /// than an unexpired existing one — so a single permissive run doesn't undo
    /// a prior demotion. An expired record is replaced outright.
    func recordCap(_ cap: Int, for host: String) {
        loadIfNeeded()
        if let existing = caps[host], !isExpired(existing), existing.cap <= cap { return }
        caps[host] = CapRecord(cap: cap, recordedAt: now())
        log.info("Host cap learned: \(host) → \(cap)")
        scheduleSave()
    }

    /// Forget any learned cap for a host (used by tests / reset UI).
    func clear(host: String) {
        loadIfNeeded()
        caps.removeValue(forKey: host)
        scheduleSave()
    }

    /// Forget every learned cap. Backs the "Reset learned connection limits"
    /// button in Settings ▸ Network.
    func clearAll() {
        loadIfNeeded()
        caps.removeAll()
        log.info("All learned host caps cleared.")
        scheduleSave()
    }

    /// How many hosts currently have an unexpired learned cap, so the reset
    /// button can say what it would actually do.
    func learnedHostCount() -> Int {
        loadIfNeeded()
        return caps.values.filter { !isExpired($0) }.count
    }

    private func isExpired(_ record: CapRecord) -> Bool {
        now().timeIntervalSince(record.recordedAt) > Self.retention
    }

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([String: CapRecord].self, from: data) {
                caps = decoded
            } else {
                // Pre-expiry format was a bare [host: cap] map. Stamp those with
                // the load time so previously-permanent caps — including any
                // mislearned from a network blip — age out a retention window
                // after the upgrade instead of persisting forever.
                let legacy = try decoder.decode([String: Int].self, from: data)
                let stamp = now()
                caps = legacy.mapValues { CapRecord(cap: $0, recordedAt: stamp) }
                log.info("Migrated \(legacy.count) legacy host cap(s) to timestamped records.")
                scheduleSave()
            }
            let expired = caps.filter { isExpired($0.value) }
            if !expired.isEmpty {
                expired.keys.forEach { caps.removeValue(forKey: $0) }
                scheduleSave()
            }
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

    /// Writes immediately, bypassing the debounce. Tests and the reset action
    /// need the file on disk without waiting out the 500 ms window.
    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        flushIfNeeded()
    }

    private func flushIfNeeded() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(caps)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write host_caps.json: \(error.localizedDescription)")
        }
    }
}
