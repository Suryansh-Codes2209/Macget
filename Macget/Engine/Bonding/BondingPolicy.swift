import Foundation
import CFNetwork

/// How many worker slots one link gets within a download.
struct LinkQuota: Equatable, Sendable {
    let linkID: String
    /// The default-route link. Its slots run on URLSession, not the pinned transport.
    let isDefault: Bool
    let slots: Int
}

/// Pure decisions about splitting a download's workers across links.
///
/// There is no speed weighting on purpose: pieces are stolen by whichever worker
/// finishes first, so a faster link already ends up carrying more of the file.
enum BondingPolicy {
    /// One connection per link can't hide a reconnect, so a link that can't get
    /// two isn't worth the complexity of using.
    static let minimumSlotsPerLink = 2

    /// Links the user allowed and the server hasn't rejected. Empty when bonding is off.
    static func activeLinks(_ links: [NetworkLink], settings: BondingSettings, excluded: Set<String>) -> [NetworkLink] {
        guard settings.enabled else { return [] }
        return links.filter { settings.isLinkEnabled($0.id) && !excluded.contains($0.id) }
    }

    /// `links` must already be in preference order (`LinkFilter.sorted`). Returns
    /// an empty array whenever bonding wouldn't apply, which callers read as
    /// "run exactly as today".
    static func quotas(links: [NetworkLink], threadCount: Int) -> [LinkQuota] {
        let threads = max(1, min(Download.maxThreadCount, threadCount))
        let fit = min(links.count, threads / minimumSlotsPerLink)
        guard fit >= 2 else { return [] }
        let chosen = Array(links.prefix(fit))
        let base = threads / fit
        let remainder = threads % fit
        return chosen.enumerated().map { index, link in
            LinkQuota(linkID: link.id, isDefault: link.isDefaultRoute, slots: base + (index < remainder ? 1 : 0))
        }
    }

    /// The quota with the most free slots; ties go to the earlier (preferred) link.
    static func nextLink(quotas: [LinkQuota], occupied: [String: Int]) -> LinkQuota? {
        var best: (quota: LinkQuota, free: Int)?
        for q in quotas {
            let free = q.slots - (occupied[q.linkID] ?? 0)
            guard free > 0 else { continue }
            if best == nil || free > best!.free { best = (q, free) }
        }
        return best?.quota
    }

    /// IPv4 addresses for aria2's `--multiple-interface`, or empty when torrents
    /// shouldn't bond.
    static func torrentAddresses(links: [NetworkLink], settings: BondingSettings) -> [String] {
        let active = activeLinks(links, settings: settings, excluded: [])
        let withAddress = active.filter { !$0.ipv4Addresses.isEmpty }
        guard withAddress.count >= 2 else { return [] }
        return withAddress.compactMap { $0.ipv4Addresses.first }
    }
}

/// Counts connection failures per pinned link. Repeated failures in a short
/// window mean the link itself is unusable for this download, so it is dropped
/// rather than spending exponential backoff on a piece another link could take.
struct LinkStrikes {
    static let threshold = 3
    static let window: TimeInterval = 30

    private var history: [String: [Date]] = [:]

    /// Returns true when this strike pushes the link over the threshold.
    mutating func record(_ linkID: String, at date: Date = Date()) -> Bool {
        var list = history[linkID, default: []].filter { date.timeIntervalSince($0) <= Self.window }
        list.append(date)
        history[linkID] = list
        return list.count >= Self.threshold
    }
}

/// Whether a download can use pinned connections at all. The pinned transport
/// speaks plain HTTP/1.1 and has no proxy support, so any proxy means "default
/// link only" rather than silently bypassing the user's proxy on the other links.
enum BondingEligibility {
    static func isEligible(url: URL, supportsRange: Bool, appProxyConfigured: Bool, systemProxyActive: Bool) -> Bool {
        guard supportsRange, !appProxyConfigured, !systemProxyActive else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    static func systemProxyActive(for url: URL) -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]]
        else { return false }
        return proxies.contains { ($0[kCFProxyTypeKey as String] as? String) != (kCFProxyTypeNone as String) }
    }
}
