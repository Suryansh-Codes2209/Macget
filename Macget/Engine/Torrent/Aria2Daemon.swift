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
        process.arguments = Self.arguments(
            port: port,
            secret: secret,
            options: options,
            ipv6DHTAddress: Self.globalUnicastIPv6Address()
        )
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

    /// This host's first global unicast IPv6 address, or nil if it has none.
    ///
    /// `--enable-dht6` is inert without `--dht-listen-addr6`, which aria2
    /// documents as requiring "a global unicast IPv6 address of the host" — not
    /// a range, and not something MacGet can hardcode.
    ///
    /// Temporary/privacy addresses are deliberately *not* filtered out:
    /// distinguishing them needs a `SIOCGIFAFLAG_IN6` ioctl, and a temporary
    /// address binds DHT just as well as a stable one.
    static func globalUnicastIPv6Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let raw = interface.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET6) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var address = UnsafeRawPointer(raw)
                .assumingMemoryBound(to: sockaddr_in6.self).pointee

            // Global unicast is 2000::/3. This single mask also excludes
            // link-local (fe80::/10), unique-local (fc00::/7) and multicast
            // (ff00::/8) — none of which aria2 can bind DHT to.
            guard address.sin6_addr.__u6_addr.__u6_addr8.0 & 0xe0 == 0x20 else { continue }

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { continue }
            return String(cString: buffer)
        }
        return nil
    }

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
        options: TorrentEngineOptions,
        ipv6DHTAddress: String? = nil
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
            // aria2's defaults are tuned for a much slower era.
            //
            // `--bt-request-peer-speed-limit` is the consequential one: aria2
            // stops looking for more peers once a torrent exceeds it. The
            // default is 50K, which caps discovery at dial-up speed — but 10M
            // is only ~80 Mbps, so it reproduced the same defect on any
            // gigabit link. 100M is above any consumer connection, so aria2
            // keeps hunting until the pipe is genuinely full. It is a
            // discovery ceiling, not a bandwidth cap: a slow link never
            // reaches it either way, so raising it costs nothing there.
            "--bt-max-peers=\(options.maxPeers)",
            "--bt-request-peer-speed-limit=100M",
            // Prefer an obfuscated handshake always. Plaintext peers are still
            // accepted at this level, so it costs no peers — it just stops the
            // BitTorrent handshake being a free signature for DPI.
            "--bt-min-crypto-level=arc4",
            "--disk-cache=128M",
            // Safe here because --file-allocation=falloc below preallocates the
            // file; aria2's documented mmap failure mode is unallocated space.
            "--enable-mmap=true",
            // A finished-but-seeding torrent stops counting against
            // --max-concurrent-downloads, so it can't block a queued one.
            "--bt-detach-seed-only=true",
            // APFS supports fallocate, so the file is reserved without writing
            // zeroes across it first.
            "--file-allocation=falloc",
            // A tracker that hasn't answered in 30s isn't going to.
            "--bt-tracker-connect-timeout=30",
            "--bt-tracker-timeout=30",
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
            // One port covers IPv4 DHT, IPv6 DHT and UDP trackers. There is no
            // `--dht-listen-port6`; aria2 rejects it and never starts.
            args.append("--dht-listen-port=\(Self.portRange(from: options.listenPort))")
            if let ipv6DHTAddress {
                args.append("--enable-dht6=true")
                args.append("--dht-listen-addr6=\(ipv6DHTAddress)")
            }
        }
        // Opt-in, not always-on. aria2 hashes every piece as it arrives, so
        // transfer corruption is caught regardless; this re-verifies data
        // already on disk, which only guards against damage done *outside*
        // aria2 — and costs a full re-read of the partial file at every resume.
        // On a 25 GB torrent that is gigabytes of disk I/O on every launch.
        if options.verifyOnResume {
            args.append("--check-integrity=true")
        }
        // Opt-in: this drops every peer that won't encrypt, so it trades peers
        // for invisibility. Worth it only where an ISP is actively shaping.
        if options.requireEncryption {
            args.append("--bt-require-crypto=true")
            args.append("--bt-force-encryption=true")
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
    /// Maximum peer connections per torrent, from `AppSettings.torrentMaxPeers`.
    /// aria2's own default is 55, which leaves a healthy swarm underused.
    var maxPeers: Int = 200
    /// Refuse peers that won't encrypt. Defeats ISP BitTorrent shaping, at the
    /// cost of dropping every peer that only speaks plaintext.
    var requireEncryption: Bool = false
    /// aria2's own default is 5. MacGet's engine allows up to 16 concurrent
    /// downloads, so leaving aria2 at 5 silently queued the rest.
    var maxConcurrentDownloads: Int = 5
    /// Re-hash data already on disk when a torrent resumes. Off by default —
    /// see `Aria2Daemon.arguments` for why.
    var verifyOnResume: Bool = false

    /// Options that can be changed on a running daemon via `changeGlobalOption`.
    /// Ports and session paths are launch-only and deliberately absent.
    var mutableGlobalOptions: [String: String] {
        [
            "max-overall-upload-limit": String(maxUploadBytesPerSec ?? 0),
            "max-overall-download-limit": String(maxDownloadBytesPerSec ?? 0),
            "max-concurrent-downloads": String(maxConcurrentDownloads),
        ]
    }

    init(
        seedRatio: Double = 1.0,
        seedMinutes: Int = 60,
        listenPort: Int = 6881,
        dhtEnabled: Bool = true,
        maxUploadBytesPerSec: Int? = nil,
        maxDownloadBytesPerSec: Int? = nil,
        maxPeers: Int = 200,
        requireEncryption: Bool = false,
        maxConcurrentDownloads: Int = 5,
        verifyOnResume: Bool = false
    ) {
        self.seedRatio = seedRatio
        self.seedMinutes = seedMinutes
        self.listenPort = listenPort
        self.dhtEnabled = dhtEnabled
        self.maxUploadBytesPerSec = maxUploadBytesPerSec
        self.maxDownloadBytesPerSec = maxDownloadBytesPerSec
        self.maxPeers = max(1, min(500, maxPeers))
        self.requireEncryption = requireEncryption
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.verifyOnResume = verifyOnResume
    }

    init(settings: AppSettings) {
        self.init(
            seedRatio: settings.torrentSeedRatio,
            seedMinutes: settings.torrentSeedMinutes,
            listenPort: settings.torrentListenPort,
            dhtEnabled: settings.torrentDHTEnabled,
            maxUploadBytesPerSec: settings.torrentMaxUploadBytesPerSec,
            maxDownloadBytesPerSec: settings.globalSpeedLimitBytesPerSec,
            maxPeers: settings.torrentMaxPeers,
            requireEncryption: settings.torrentRequireEncryption,
            maxConcurrentDownloads: settings.maxConcurrentDownloads,
            verifyOnResume: settings.torrentVerifyOnResume
        )
    }
}
