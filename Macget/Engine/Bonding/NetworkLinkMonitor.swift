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
/// order (first = default route). Each candidate then gets its own
/// `NWPathMonitor(requiredInterfaceType:)`, because the whole-machine path being
/// satisfied says nothing about whether *this* interface reaches anything — a
/// tethered phone with no signal is still "plugged in".
///
/// Changes are debounced so a tether that drops for a second doesn't churn
/// every download's workers or restart the aria2 daemon.
actor NetworkLinkMonitor: LinkProvider {
    static let shared = NetworkLinkMonitor()
    static let debounce: Duration = .seconds(2)

    private let queue = DispatchQueue(label: "com.macget.link-monitor")
    private let log = Logger(subsystem: "com.macget", category: "Links")

    private var mainMonitor: NWPathMonitor?
    private var perInterface: [String: NWPathMonitor] = [:]
    private var interfaces: [String: NWInterface] = [:]
    private var satisfied: Set<String> = []
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
        for iface in candidates where perInterface[iface.name] == nil {
            interfaces[iface.name] = iface
            let name = iface.name
            let monitor = NWPathMonitor(requiredInterfaceType: iface.type)
            monitor.pathUpdateHandler = { [weak self] (p: NWPath) in
                // `requiredInterfaceType` is the finest scope this SDK offers (there is
                // no per-interface initializer), so also require this interface to be
                // among the path's candidates.
                let ok = p.status == .satisfied && p.availableInterfaces.contains { $0.name == name }
                Task { await self?.handleInterfacePath(name: name, satisfied: ok) }
            }
            monitor.start(queue: queue)
            perInterface[name] = monitor
        }
        for (name, monitor) in perInterface where !names.contains(name) {
            monitor.cancel()
            perInterface[name] = nil
            interfaces[name] = nil
            satisfied.remove(name)
        }
        scheduleRepublish()
    }

    private func handleInterfacePath(name: String, satisfied ok: Bool) {
        if ok { satisfied.insert(name) } else { satisfied.remove(name) }
        scheduleRepublish()
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
