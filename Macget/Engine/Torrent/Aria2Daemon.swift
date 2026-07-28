import Foundation
import OSLog

/// Owns the single `aria2c` process MacGet drives for all torrents.
///
/// One daemon serves every torrent — aria2 handles concurrency internally, and
/// MacGet's own `maxConcurrentDownloads` gate lives in `DownloadEngine`. The
/// process is started lazily on the first torrent and shut down when the last
/// one goes inactive, so users who never touch torrents never spawn it.
///
/// Security posture: RPC binds to loopback on an ephemeral port with a fresh
/// 256-bit secret per launch, and `--rpc-listen-all=false` keeps it off every
/// other interface.
actor Aria2Daemon {
    static let shared = Aria2Daemon()

    private var process: Process?
    private var client: Aria2RPCClient?
    private var startTask: Task<Aria2RPCClient, Error>?
    private let log = Logger(subsystem: "com.macget", category: "Aria2Daemon")

    /// Options applied at launch and refreshed via `changeGlobalOption`.
    private var currentOptions: TorrentEngineOptions = .init()

    enum DaemonError: Error, LocalizedError {
        case toolMissing
        case launchFailed(String)
        case didNotBecomeReady

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "aria2 isn't installed. Turn on torrent support in Settings to install it."
            case .launchFailed(let detail):
                return "Could not start the torrent engine: \(detail)"
            case .didNotBecomeReady:
                return "The torrent engine started but never became reachable."
            }
        }
    }

    // MARK: - Lifecycle

    /// Returns a ready RPC client, starting the daemon if needed. Concurrent
    /// callers share one startup.
    func client(options: TorrentEngineOptions) async throws -> Aria2RPCClient {
        currentOptions = options
        if let client, isRunning { return client }
        if let startTask { return try await startTask.value }

        let task = Task { try await start(options: options) }
        startTask = task
        defer { startTask = nil }
        let started = try await task.value
        client = started
        return started
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    private func start(options: TorrentEngineOptions) async throws -> Aria2RPCClient {
        guard let executable = TorrentToolLocator.locate() else { throw DaemonError.toolMissing }

        let port = try Self.freePort()
        let secret = Self.makeSecret()

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(port: port, secret: secret, options: options)
        process.standardOutput = FileHandle.nullDevice
        // aria2 is chatty on stderr; discard rather than filling the pipe buffer
        // (a full pipe with no reader would block the process).
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DaemonError.launchFailed(error.localizedDescription)
        }
        self.process = process

        let client = Aria2RPCClient(port: port, secret: secret)
        try await Self.waitUntilReady(client, process: process)
        log.info("aria2c started on 127.0.0.1:\(port, privacy: .public) (pid \(process.processIdentifier))")
        return client
    }

    /// Poll `aria2.getVersion` until the RPC server accepts connections. aria2
    /// binds the port a beat after `run()` returns, so the first calls fail.
    private static func waitUntilReady(_ client: Aria2RPCClient, process: Process) async throws {
        for attempt in 0..<40 {   // ~4s at 100ms
            guard process.isRunning else { throw DaemonError.launchFailed("aria2c exited during startup") }
            if (try? await client.ping()) != nil { return }
            try? await Task.sleep(for: .milliseconds(attempt < 10 ? 50 : 100))
        }
        throw DaemonError.didNotBecomeReady
    }

    /// Push changed settings to a live daemon. Options that can only be set at
    /// launch (ports) are recorded and take effect on the next start.
    func applyOptions(_ options: TorrentEngineOptions) async {
        currentOptions = options
        guard let client, isRunning else { return }
        try? await client.changeGlobalOption(options.mutableGlobalOptions)
    }

    /// Ask aria2 to exit and wait for it. Called from the app-termination path —
    /// killing it instead would lose the session file and in-flight piece state.
    func shutdown() async {
        startTask?.cancel()
        if let client, isRunning {
            try? await client.shutdown()
        }
        guard let process else {
            self.client = nil
            return
        }
        // Give it a moment to persist its session, then insist.
        for _ in 0..<30 where process.isRunning {   // ~3s
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            log.error("aria2c did not exit on request; terminating")
            process.terminate()
        }
        self.process = nil
        self.client = nil
    }

    // MARK: - Launch configuration

    /// Launch arguments.
    ///
    /// Note what's deliberately **absent**: `--save-session` / `--input-file`.
    /// aria2 can persist and restore its own queue, but MacGet already owns the
    /// queue in `queue.json` and re-adds each torrent on launch. Letting aria2
    /// restore too means the same info hash is registered twice, and aria2 fails
    /// the second one outright ("InfoHash … is already registered"), which is
    /// exactly what a resumed torrent would look like. One source of truth.
    ///
    /// Resume still works: `--continue=true` plus the `.aria2` control file aria2
    /// keeps beside the partial data is what actually restores piece state, and
    /// `--bt-save-metadata` means a magnet doesn't have to re-fetch metadata.
    static func arguments(
        port: Int,
        secret: String,
        options: TorrentEngineOptions
    ) -> [String] {
        var args = [
            "--enable-rpc=true",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            // Loopback only. Never expose the control channel to the network.
            "--rpc-listen-all=false",
            "--rpc-allow-origin-all=false",
            "--daemon=false",
            "--continue=true",
            "--check-integrity=true",
            // Keeps metadata beside the data so a resumed magnet doesn't have to
            // re-fetch it over BEP-9.
            "--bt-save-metadata=true",
            // A .torrent added by MacGet must not auto-spawn a second download.
            "--follow-torrent=mem",
            // A range, not a single port: if another torrent client (or a stale
            // aria2) already holds the preferred port, a single value makes aria2
            // fail outright with "Errors occurred while binding port". aria2's own
            // default is a range for exactly this reason.
            "--listen-port=\(Self.portRange(from: options.listenPort))",
            "--seed-ratio=\(options.seedRatio)",
            "--seed-time=\(options.seedMinutes)",
            "--enable-dht=\(options.dhtEnabled)",
            "--bt-enable-lpd=true",
            "--enable-peer-exchange=true",
        ]
        if options.dhtEnabled {
            args.append("--dht-listen-port=\(Self.portRange(from: options.listenPort))")
        }
        for (key, value) in options.mutableGlobalOptions.sorted(by: { $0.key < $1.key }) {
            args.append("--\(key)=\(value)")
        }
        return args
    }

    /// Ten consecutive ports starting at the user's preference, clamped to the
    /// valid range. aria2 tries each until one binds.
    static func portRange(from start: Int, span: Int = 9) -> String {
        let low = max(1024, min(65535, start))
        let high = min(65535, low + span)
        return low == high ? "\(low)" : "\(low)-\(high)"
    }

    /// 256 bits of entropy, regenerated every launch so a leaked secret dies with
    /// the process.
    static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Ask the kernel for an unused TCP port by binding port 0 and reading back
    /// the assignment. Racy in principle, fine in practice, and far better than
    /// hardcoding 6800 (which collides with any other aria2 on the machine).
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.launchFailed("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw DaemonError.launchFailed("bind() failed") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw DaemonError.launchFailed("getsockname() failed") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

/// The subset of `AppSettings` the torrent engine cares about, so the daemon
/// doesn't depend on the whole settings struct.
struct TorrentEngineOptions: Sendable, Equatable {
    var seedRatio: Double = 1.0
    var seedMinutes: Int = 60
    var listenPort: Int = 6881
    var dhtEnabled: Bool = true
    var maxUploadBytesPerSec: Int?
    var maxDownloadBytesPerSec: Int?

    /// Options that can be changed on a running daemon via `changeGlobalOption`.
    /// Ports and session paths are launch-only and deliberately absent.
    var mutableGlobalOptions: [String: String] {
        [
            "max-overall-upload-limit": String(maxUploadBytesPerSec ?? 0),
            "max-overall-download-limit": String(maxDownloadBytesPerSec ?? 0),
        ]
    }

    init(
        seedRatio: Double = 1.0,
        seedMinutes: Int = 60,
        listenPort: Int = 6881,
        dhtEnabled: Bool = true,
        maxUploadBytesPerSec: Int? = nil,
        maxDownloadBytesPerSec: Int? = nil
    ) {
        self.seedRatio = seedRatio
        self.seedMinutes = seedMinutes
        self.listenPort = listenPort
        self.dhtEnabled = dhtEnabled
        self.maxUploadBytesPerSec = maxUploadBytesPerSec
        self.maxDownloadBytesPerSec = maxDownloadBytesPerSec
    }

    init(settings: AppSettings) {
        self.init(
            seedRatio: settings.torrentSeedRatio,
            seedMinutes: settings.torrentSeedMinutes,
            listenPort: settings.torrentListenPort,
            dhtEnabled: settings.torrentDHTEnabled,
            maxUploadBytesPerSec: settings.torrentMaxUploadBytesPerSec,
            maxDownloadBytesPerSec: settings.globalSpeedLimitBytesPerSec
        )
    }
}
