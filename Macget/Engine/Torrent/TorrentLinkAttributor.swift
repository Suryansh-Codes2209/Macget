import Foundation

/// Estimates how much of each torrent arrives over each network link.
///
/// One aria2 process serves every torrent, so per-interface bytes are only known
/// for the process as a whole. They are split across active torrents in
/// proportion to aria2's own per-torrent speeds: exact with one torrent running,
/// an estimate (flagged, shown with "≈") with several.
actor TorrentLinkAttributor {
    static let shared = TorrentLinkAttributor()

    /// Speeds older than this are treated as stopped torrents.
    static let speedFreshness: TimeInterval = 3

    private let sampler: @Sendable (Int32) async -> String?
    private let pidProvider: @Sendable () async -> Int32?

    private var previous: [NettopSocketSample]?
    private var previousAt: Date?
    private var linkRates: [String: Double] = [:]
    private var sockets: [String: Int] = [:]
    private var speeds: [UUID: (speed: Double, at: Date)] = [:]
    private var cumulative: [UUID: [String: Int64]] = [:]
    private(set) var isAvailable = true
    private var samplingTask: Task<Void, Never>?
    private var lastRequestAt = Date.distantPast
    /// Off in tests, which drive `sampleNow()` themselves so a background loop
    /// can't consume their canned `nettop` output.
    private let autoSample: Bool

    init(
        sampler: @escaping @Sendable (Int32) async -> String? = TorrentLinkAttributor.runNettop,
        pidProvider: @escaping @Sendable () async -> Int32? = { await Aria2Daemon.shared.processIdentifier },
        autoSample: Bool = true
    ) {
        self.sampler = sampler
        self.pidProvider = pidProvider
        self.autoSample = autoSample
    }

    /// Called from each torrent's poll. Starts sampling on first use and lets it
    /// lapse when nobody has asked for a few seconds.
    func linkStats(for id: UUID, speed: Double, links: [NetworkLink], now: Date = Date()) -> [LinkStat] {
        speeds[id] = (speed, now)
        lastRequestAt = now
        ensureSampling()
        return Self.apportion(id: id, speeds: freshSpeeds(now), linkRates: linkRates, links: links,
                              available: isAvailable, cumulative: cumulative[id] ?? [:], sockets: sockets)
    }

    static func apportion(
        id: UUID,
        speeds: [UUID: Double],
        linkRates: [String: Double],
        links: [NetworkLink],
        available: Bool,
        cumulative: [String: Int64],
        sockets: [String: Int]
    ) -> [LinkStat] {
        guard available, links.count >= 2, !linkRates.isEmpty else { return [] }
        let total = speeds.values.reduce(0, +)
        guard total > 0, let mine = speeds[id] else { return [] }
        let share = mine / total
        let isEstimate = speeds.values.filter { $0 > 0 }.count > 1
        return links.map { link in
            LinkStat(
                linkID: link.id, displayName: link.displayName, kind: link.kind,
                speedBytesPerSec: (linkRates[link.id] ?? 0) * share,
                bytesThisSession: cumulative[link.id] ?? 0,
                activeConnections: isEstimate ? 0 : (sockets[link.id] ?? 0),
                status: .active,
                isEstimate: isEstimate
            )
        }
    }

    /// One sample. Internal so tests can drive it without the timer.
    func sampleNow() async {
        guard let pid = await pidProvider() else {
            previous = nil
            linkRates = [:]
            return
        }
        guard let csv = await sampler(pid) else {
            isAvailable = false
            return
        }
        let current = NettopParser.parse(csv)
        let now = Date()
        if let previous, let previousAt {
            let dt = max(now.timeIntervalSince(previousAt), 0.1)
            let delta = NettopParser.delta(previous: previous, current: current)
            linkRates = delta.mapValues { Double($0) / dt }
            let fresh = freshSpeeds(now)
            let total = fresh.values.reduce(0, +)
            if total > 0 {
                for (id, speed) in fresh {
                    let share = speed / total
                    for (link, bytes) in delta {
                        cumulative[id, default: [:]][link, default: 0] += Int64(Double(bytes) * share)
                    }
                }
            }
        }
        previous = current
        previousAt = now
        sockets = NettopParser.socketCounts(current)
        isAvailable = true
    }

    private func freshSpeeds(_ now: Date) -> [UUID: Double] {
        speeds.filter { now.timeIntervalSince($0.value.at) <= Self.speedFreshness }.mapValues(\.speed)
    }

    private func ensureSampling() {
        guard autoSample, samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.isIdle() { await self.stopSampling(); return }
                await self.sampleNow()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func isIdle() -> Bool { Date().timeIntervalSince(lastRequestAt) > 5 }

    private func stopSampling() {
        samplingTask = nil
        previous = nil
        linkRates = [:]
    }

    /// `nettop` one-shot sample of a single process's sockets.
    static let runNettop: @Sendable (Int32) async -> String? = { pid in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                process.arguments = ["-L", "1", "-x", "-n", "-p", String(pid), "-J", "interface,bytes_in"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    // A hung nettop must not wedge sampling: kill it after 5s, which
                    // closes the pipe and unblocks the read below.
                    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: killer)
                    defer { killer.cancel() }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
