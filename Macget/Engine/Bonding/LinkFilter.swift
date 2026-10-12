import Foundation

/// Pure rules for which interfaces count as internet links and how to name them.
enum LinkFilter {
    /// Virtual, tunnel and peer-to-peer interfaces. VPN tunnels (`utun`, `ipsec`)
    /// are excluded deliberately: they ride on top of a physical link, so
    /// "bonding" a VPN with its own carrier would double-count one link.
    static let excludedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "nan"]

    static func isCandidate(bsdName: String) -> Bool {
        !excludedPrefixes.contains { bsdName.hasPrefix($0) }
    }

    /// Network.framework's interface type, decoupled so tests needn't build an `NWInterface`.
    enum InterfaceType: Sendable {
        case wifi, wiredEthernet, cellular, other
    }

    /// A USB-tethered phone presents as wired Ethernet; only its localized name
    /// ("iPhone USB") distinguishes it, and that's the distinction the user cares
    /// about because it is the one on a data plan.
    static func classify(type: InterfaceType, displayName: String) -> NetworkLink.Kind {
        let lower = displayName.lowercased()
        let tetherHints = ["iphone", "ipad", "android", "rndis", "tether"]
        if type == .cellular || tetherHints.contains(where: lower.contains) {
            return .tethered
        }
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        case .cellular, .other: return .other
        }
    }

    /// Lower is preferred when a thread budget is too small for every link.
    static func rank(_ kind: NetworkLink.Kind) -> Int {
        switch kind {
        case .wiredEthernet: return 0
        case .wifi: return 1
        case .tethered: return 2
        case .other: return 3
        }
    }

    static func sorted(_ links: [NetworkLink]) -> [NetworkLink] {
        links.sorted {
            if $0.isDefaultRoute != $1.isDefaultRoute { return $0.isDefaultRoute }
            return (rank($0.kind), $0.id) < (rank($1.kind), $1.id)
        }
    }
}
