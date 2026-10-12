import Foundation

/// One usable internet link — a physical interface that currently reaches the
/// internet. Identified by BSD name, which is what Network.framework, aria2 and
/// `nettop` all agree on.
struct NetworkLink: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case wiredEthernet, wifi, tethered, other
    }

    let id: String              // BSD name, e.g. "en0"
    let displayName: String     // "Wi-Fi", "iPhone USB", "Thunderbolt Ethernet"
    let kind: Kind
    /// Local IPv4 and global IPv6 addresses. Link-local addresses are excluded.
    let addresses: [String]
    let isDefaultRoute: Bool

    /// aria2's `--multiple-interface` binds by address; IPv4 is the reliable family.
    var ipv4Addresses: [String] { addresses.filter { !$0.contains(":") } }
}
