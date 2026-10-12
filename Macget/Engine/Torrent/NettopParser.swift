import Foundation

struct NettopSocketSample: Equatable {
    /// The socket description, e.g. "tcp4 1.2.3.4:5<->6.7.8.9:10" — unique per connection.
    let key: String
    let interface: String
    /// Cumulative bytes received on this socket since it opened.
    let bytesIn: Int64
}

/// Parses `nettop -L 1 -x -n -p <pid> -J interface,bytes_in` CSV output.
///
/// aria2 reports speed per torrent but never which local interface the bytes
/// arrived on; macOS's per-socket statistics (what `nettop` shows) do, and work
/// without root for our own child process.
enum NettopParser {
    static func parse(_ csv: String) -> [NettopSocketSample] {
        csv.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // Header and per-process rows have an empty interface column.
            guard cols.count >= 3, !cols[0].isEmpty, !cols[1].isEmpty, let bytes = Int64(cols[2]) else { return nil }
            return NettopSocketSample(key: cols[0], interface: cols[1], bytesIn: bytes)
        }
    }

    /// Bytes received per interface between two samples. A socket new in
    /// `current` contributes everything it has received so far.
    static func delta(previous: [NettopSocketSample], current: [NettopSocketSample]) -> [String: Int64] {
        let before = Dictionary(previous.map { ($0.key, $0.bytesIn) }, uniquingKeysWith: max)
        var out: [String: Int64] = [:]
        for sample in current {
            let d = sample.bytesIn - (before[sample.key] ?? 0)
            if d > 0 { out[sample.interface, default: 0] += d }
        }
        return out
    }

    static func socketCounts(_ samples: [NettopSocketSample]) -> [String: Int] {
        samples.reduce(into: [:]) { $0[$1.interface, default: 0] += 1 }
    }
}
