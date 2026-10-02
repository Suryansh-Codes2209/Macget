import Foundation
import Network
import OSLog
import SystemConfiguration

/// Every usable link, plus whether the Mac is online at all.
struct LinkSnapshot: Sendable, Equatable {
    let links: [NetworkLink]
    let isOnline: Bool
}

/// Something that can say which links are usable right now. The coordinator
/// depends on this, not on the monitor, so tests can inject a fixed set.
protocol LinkProvider: Sendable {
    func usableLinks() async -> [NetworkLink]
}

/// Watches the machine's network interfaces and publishes the ones that reach
/// the internet.
///
/// One whole-machine `NWPathMonitor` lists candidate interfaces in preference
/// order (first = default route). Each candidate is then probed directly: a TCP
/// connection to `captive.apple.com:80` forced onto that interface. Neither the
/// whole-machine path nor a type-scoped monitor can say whether *this*
/// interface reaches anything — a tethered phone with no signal is still
/// "plugged in", and a dead USB tether is typed `wiredEthernet` beside a
/// working Ethernet port. Candidates are re-probed on every main-path change
/// and every 30 s.
///
/// Changes are debounced so a tether that drops for a second doesn't churn
/// every download's workers or restart the aria2 daemon.
actor NetworkLinkMonitor: LinkProvider {
    static let shared = NetworkLinkMonitor()
    static let debounce: Duration = .seconds(2)
    static let probeInterval: Duration = .seconds(30)

    private let queue = DispatchQueue(label: "com.macget.link-monitor")
    private let log = Logger(subsystem: "com.macget", category: "Links")

    private var mainMonitor: NWPathMonitor?
    private var probes: [String: Task<Void, Never>] = [:]
    private var probeLoop: Task<Void, Never>?
    private var interfaces: [String: NWInterface] = [:]
    private var satisfied: Set<String> = []
    /// Consecutive failed probes per interface, for `LinkProbeHysteresis`.
    private var failureStreaks: [String: Int] = [:]
    private var defaultID: String?
    private var online = true
    private var published = LinkSnapshot(links: [], isOnline: true)
    private var subscribers: [UUID: AsyncStream<LinkSnapshot>.Continuation] = [:]
    private var debounceTask: Task<Void, Never>?

    func start() {
        guard mainMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.handleMainPath(path) }
        }
        monitor.start(queue: queue)
        mainMonitor = monitor
        probeLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.probeInterval)
                guard !Task.isCancelled else { return }
                await self?.probeAll()
            }
        }
    }

    func usableLinks() -> [NetworkLink] { published.links }

    func interface(for id: String) -> NWInterface? { interfaces[id] }

    /// Current snapshot immediately, then every debounced change.
    func updates() -> AsyncStream<LinkSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(published)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func handleMainPath(_ path: NWPath) {
        online = path.status == .satisfied
        let candidates = path.availableInterfaces.filter { LinkFilter.isCandidate(bsdName: $0.name) }
        defaultID = candidates.first?.name

        let names = Set(candidates.map(\.name))
        for iface in candidates { interfaces[iface.name] = iface }
        for name in interfaces.keys where !names.contains(name) {
            probes[name]?.cancel()
            probes[name] = nil
            interfaces[name] = nil
            satisfied.remove(name)
            failureStreaks[name] = nil
        }
        probeAll()
        scheduleRepublish()
    }

    /// Probes every candidate that isn't already being probed.
    private func probeAll() {
        for (name, iface) in interfaces where probes[name] == nil {
            probes[name] = Task { [weak self] in
                let ok = await Self.probe(iface)
                await self?.finishProbe(name: name, reachable: ok)
            }
        }
    }

    private func finishProbe(name: String, reachable ok: Bool) {
        probes[name] = nil
        // A late result for an interface that has since gone away must not resurrect it.
        guard interfaces[name] != nil else { return }
        let was = satisfied.contains(name)
        let next = LinkProbeHysteresis.next(wasSatisfied: was, probeSucceeded: ok,
                                            failureStreak: failureStreaks[name] ?? 0)
        failureStreaks[name] = next.failureStreak == 0 ? nil : next.failureStreak
        if next.satisfied { satisfied.insert(name) } else { satisfied.remove(name) }
        if next.satisfied != was { scheduleRepublish() }
    }

    /// Longest a probe may take before it counts as failed. The TCP connect
    /// timeout doesn't bound a connection stuck in `.preparing` (e.g. waiting on
    /// DNS), and a probe that never resolves blocks every later re-probe.
    static let probeBackstop: Duration = .seconds(8)

    /// True if a TCP connection to captive.apple.com:80 becomes ready on `iface`.
    private static func probe(_ iface: NWInterface) async -> Bool {
        let params = NWParameters.tcp
        params.requiredInterface = iface
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
        }
        let connection = NWConnection(host: "captive.apple.com", port: 80, using: params)
        let gate = ProbeGate()
        let backstop = Task {
            try? await Task.sleep(for: Self.probeBackstop)
            guard !Task.isCancelled else { return }
            gate.finish(false)
        }
        defer { backstop.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gate.install(continuation, connection: connection)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(true)
                    case .failed, .waiting, .cancelled: gate.finish(false)
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "com.macget.link-probe"))
            }
        } onCancel: {
            gate.finish(false)
        }
    }

    /// Resumes the probe's continuation exactly once and cancels the connection.
    private final class ProbeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var connection: NWConnection?
        private var done = false

        func install(_ c: CheckedContinuation<Bool, Never>, connection: NWConnection) {
            lock.lock()
            if done {
                lock.unlock()
                connection.cancel()
                c.resume(returning: false)
                return
            }
            continuation = c
            self.connection = connection
            lock.unlock()
        }

        func finish(_ result: Bool) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let c = continuation
            let conn = connection
            continuation = nil
            connection = nil
            lock.unlock()
            conn?.stateUpdateHandler = nil
            conn?.cancel()
            c?.resume(returning: result)
        }
    }

    private func scheduleRepublish() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.republish()
        }
    }

    private func republish() {
        let names = Self.localizedNames()
        let addresses = LinkAddresses.byInterface()
        let links = satisfied.compactMap { id -> NetworkLink? in
            guard let iface = interfaces[id] else { return nil }
            let display = names[id] ?? id
            return NetworkLink(
                id: id,
                displayName: display,
                kind: LinkFilter.classify(type: Self.interfaceType(iface.type), displayName: display),
                addresses: addresses[id] ?? [],
                isDefaultRoute: id == defaultID
            )
        }
        let snapshot = LinkSnapshot(links: LinkFilter.sorted(links), isOnline: online)
        guard snapshot != published else { return }
        published = snapshot
        log.info("Usable links: \(snapshot.links.map(\.id).joined(separator: ","), privacy: .public) online=\(snapshot.isOnline)")
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private static func interfaceType(_ type: NWInterface.InterfaceType) -> LinkFilter.InterfaceType {
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        case .cellular: return .cellular
        default: return .other
        }
    }

    /// "Wi-Fi", "iPhone USB", "Thunderbolt Ethernet" — what System Settings shows.
    private static func localizedNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var out: [String: String] = [:]
        for iface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                out[bsd] = name
            }
        }
        return out
    }
}

/// Whether a probed interface counts as usable. A link that is up stays up
/// through one failed probe: a saturated tether can miss a 5 s connect, and
/// dropping it restarts aria2 twice and kills every pinned worker on it — far
/// costlier than carrying a dead link for one more 30 s probe cycle. A link
/// that is down comes up on its first success.
enum LinkProbeHysteresis {
    static let failuresToDrop = 2

    static func next(wasSatisfied: Bool, probeSucceeded: Bool, failureStreak: Int)
        -> (satisfied: Bool, failureStreak: Int) {
        if probeSucceeded { return (true, 0) }
        let streak = failureStreak + 1
        guard wasSatisfied else { return (false, streak) }
        return (streak < failuresToDrop, streak)
    }
}
