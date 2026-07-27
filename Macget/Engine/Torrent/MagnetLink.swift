import Foundation

/// A parsed `magnet:` URI.
///
/// Pure value type with no networking — aria2 does the actual work of turning a
/// magnet into a download. MacGet parses it only to show a sensible name and
/// info hash in the queue before metadata arrives over BEP-9.
struct MagnetLink: Sendable, Equatable {
    /// Lowercase 40-character hex BitTorrent info hash (v1).
    let infoHash: String
    /// `dn` — the suggested display name. Absent in plenty of real magnets.
    var displayName: String?
    /// `tr` — announce URLs.
    var trackers: [String] = []
    /// `xl` — exact length in bytes, when the magnet declares one.
    var exactLength: Int64?

    /// A name to show in the queue until aria2 reports the real torrent name.
    var provisionalName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return "Torrent \(infoHash.prefix(8))"
    }

    // MARK: - Parsing

    static func parse(_ string: String) -> MagnetLink? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return parse(url)
    }

    static func parse(_ url: URL) -> MagnetLink? {
        guard url.scheme?.lowercased() == "magnet" else { return nil }
        // A magnet's parameters live in the "query" of an opaque URL, so build
        // components from the string rather than relying on `url.query`.
        guard let components = URLComponents(string: url.absoluteString),
              let items = components.queryItems else { return nil }

        var hash: String?
        var displayName: String?
        var trackers: [String] = []
        var exactLength: Int64?

        for item in items {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name.lowercased() {
            case "xt", "xt.1":
                // Only BitTorrent v1 info hashes are usable here; other `xt`
                // namespaces (ed2k, sha1, btmh) are ignored.
                if hash == nil, let parsed = normalizeInfoHash(from: value) { hash = parsed }
            case "dn":
                if displayName == nil { displayName = value.replacingOccurrences(of: "+", with: " ") }
            case "tr":
                trackers.append(value)
            case "xl":
                exactLength = Int64(value)
            default:
                break
            }
        }

        guard let infoHash = hash else { return nil }
        return MagnetLink(
            infoHash: infoHash,
            displayName: displayName,
            trackers: trackers,
            exactLength: exactLength
        )
    }

    /// Accepts `urn:btih:<40 hex>` or `urn:btih:<32 base32>` and returns lowercase
    /// hex. Base32 is legal and still appears in the wild, so rejecting it would
    /// silently fail on real magnets.
    static func normalizeInfoHash(from xt: String) -> String? {
        let prefix = "urn:btih:"
        let lowered = xt.lowercased()
        guard lowered.hasPrefix(prefix) else { return nil }
        let raw = String(xt.dropFirst(prefix.count))

        if raw.count == 40, raw.allSatisfy(\.isHexDigit) {
            return raw.lowercased()
        }
        if raw.count == 32, let bytes = base32Decode(raw), bytes.count == 20 {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    /// RFC 4648 base32 (no padding needed — a 32-char string is exactly 20 bytes).
    private static func base32Decode(_ input: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() { lookup[character] = UInt8(index) }

        var bits = 0
        var accumulator: UInt32 = 0
        var output: [UInt8] = []
        for character in input.uppercased() {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        return output
    }
}
