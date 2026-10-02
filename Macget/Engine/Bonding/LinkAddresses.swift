import Foundation
import Darwin

/// Local addresses per BSD interface name, via `getifaddrs`.
enum LinkAddresses {
    static func byInterface() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var out: [String: [String]] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET
                ? MemoryLayout<sockaddr_in>.size
                : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("lo") {
                out[name, default: []].append(String(cString: host))
                continue
            }
            if let addr = normalize(String(cString: host)) {
                out[name, default: []].append(addr)
            }
        }
        return out
    }

    /// Strips a `%scope` suffix and drops link-local addresses, which can't reach
    /// the internet and would only confuse aria2's interface binding.
    static func normalize(_ raw: String) -> String? {
        let addr = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        if addr.lowercased().hasPrefix("fe80") || addr.hasPrefix("169.254.") { return nil }
        return addr
    }
}
