import Foundation

/// Just enough bencode to answer one question: is this torrent private?
///
/// aria2 can't tell us. `aria2.tellStatus`'s `bittorrent` struct carries only
/// announceList / comment / creationDate / mode / info.name — there is no
/// `private` key at any depth — and aria2 won't apply the flag on our behalf
/// either: its docs say `private` disables DHT regardless of the setting, but
/// say nothing of the kind for `--bt-tracker`, because a supplied tracker is
/// treated as user intent it must honour.
///
/// This walks the structure rather than searching bytes, and that is the whole
/// point. `info.pieces` is raw concatenated SHA-1 digests — arbitrary binary
/// that will, given enough torrents, contain the literal bytes `7:privatei1e`.
/// A substring scan would mark such a torrent private and silently strip the
/// trackers it needed. Length prefixes let us skip payloads instead of reading
/// through them.
enum TorrentMetainfo {

    /// Bencode nests arbitrarily; a hostile file shouldn't blow the stack.
    private static let maxDepth = 64

    indirect enum Value {
        case integer(Int)
        case bytes([UInt8])
        case list([Value])
        case dictionary([String: Value])
    }

    /// True only when the metainfo's `info` dictionary carries `private = 1`.
    ///
    /// Malformed input, a missing key, and `private = 0` all read as public.
    /// Public is the safe default: a torrent wrongly treated as private loses
    /// its injected trackers with nothing in the UI to explain why.
    static func isPrivate(_ data: Data) -> Bool {
        guard case .dictionary(let root)? = parse(Array(data), at: 0, depth: 0)?.value,
              case .dictionary(let info)? = root["info"],
              case .integer(let flag)? = info["private"]
        else { return false }
        return flag == 1
    }

    // MARK: - Parsing

    static func parse(_ bytes: [UInt8], at index: Int, depth: Int) -> (value: Value, next: Int)? {
        guard depth <= maxDepth, index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "i"):
            return parseInteger(bytes, at: index)
        case UInt8(ascii: "l"):
            return parseList(bytes, at: index, depth: depth)
        case UInt8(ascii: "d"):
            return parseDictionary(bytes, at: index, depth: depth)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return parseBytes(bytes, at: index)
        default:
            return nil
        }
    }

    private static func parseInteger(_ bytes: [UInt8], at index: Int) -> (Value, Int)? {
        var cursor = index + 1
        var digits = ""
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        guard cursor < bytes.count, let value = Int(digits) else { return nil }
        return (.integer(value), cursor + 1)
    }

    /// The load-bearing case: the length prefix lets us jump over the payload
    /// instead of scanning it, so binary content can never be mistaken for
    /// structure.
    private static func parseBytes(_ bytes: [UInt8], at index: Int) -> (Value, Int)? {
        var cursor = index
        var digits = ""
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ":") {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        guard cursor < bytes.count, let length = Int(digits), length >= 0 else { return nil }
        let start = cursor + 1
        // A hostile length prefix can overflow rather than merely run past the end.
        let (end, overflowed) = start.addingReportingOverflow(length)
        guard !overflowed, end <= bytes.count else { return nil }
        return (.bytes(Array(bytes[start..<end])), end)
    }

    private static func parseList(_ bytes: [UInt8], at index: Int, depth: Int) -> (Value, Int)? {
        var cursor = index + 1
        var items: [Value] = []
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let (value, next) = parse(bytes, at: cursor, depth: depth + 1) else { return nil }
            items.append(value)
            cursor = next
        }
        guard cursor < bytes.count else { return nil }
        return (.list(items), cursor + 1)
    }

    private static func parseDictionary(_ bytes: [UInt8], at index: Int, depth: Int) -> (Value, Int)? {
        var cursor = index + 1
        var entries: [String: Value] = [:]
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let (keyValue, afterKey) = parseBytes(bytes, at: cursor),
                  case .bytes(let keyBytes) = keyValue,
                  let (value, afterValue) = parse(bytes, at: afterKey, depth: depth + 1)
            else { return nil }
            // Keys are conventionally UTF-8; a key that isn't is not one we look for.
            if let key = String(bytes: keyBytes, encoding: .utf8) {
                entries[key] = value
            }
            cursor = afterValue
        }
        guard cursor < bytes.count else { return nil }
        return (.dictionary(entries), cursor + 1)
    }
}
