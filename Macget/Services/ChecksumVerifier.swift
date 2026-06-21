import Foundation
import CryptoKit

/// Hash algorithms we can verify a finished download against.
enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha256
    case md5
}

enum ChecksumError: Error, LocalizedError {
    case mismatch(expected: String, actual: String, algorithm: ChecksumAlgorithm)

    var errorDescription: String? {
        switch self {
        case .mismatch(let e, let a, let alg):
            return "Checksum mismatch (\(alg.rawValue)): expected \(e), computed \(a)."
        }
    }
}

/// A parsed expected-checksum specification (algorithm + hex digest).
struct ChecksumSpec: Equatable, Sendable {
    let algorithm: ChecksumAlgorithm
    let hex: String

    /// Extracts a checksum from a URL fragment of the form `#sha256=<hex>` or
    /// `#md5=<hex>` (also accepts `sha-256`). Returns `nil` when absent or the
    /// digest length doesn't match the algorithm. The fragment is never sent to
    /// the server (URLSession drops it), so it's a safe sidecar for the hash.
    static func parse(fragment: String?) -> ChecksumSpec? {
        guard let frag = fragment?.trimmingCharacters(in: .whitespaces), !frag.isEmpty else { return nil }
        // Allow multiple `;`-separated params; pick the first checksum we recognize.
        for part in frag.components(separatedBy: CharacterSet(charactersIn: ";&")) {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased().replacingOccurrences(of: "-", with: "")
            let value = kv[1].trimmingCharacters(in: .whitespaces).lowercased()
            let alg: ChecksumAlgorithm?
            switch key {
            case "sha256": alg = .sha256
            case "md5": alg = .md5
            default: alg = nil
            }
            guard let algorithm = alg, isValidHex(value, for: algorithm) else { continue }
            return ChecksumSpec(algorithm: algorithm, hex: value)
        }
        return nil
    }

    /// Parses free-form user input from the Add sheet. Accepts the same
    /// `algo=hex` forms as `parse(fragment:)`, or a bare hex digest whose length
    /// implies the algorithm (64 → SHA-256, 32 → MD5). Returns `nil` for blank
    /// or unrecognizable input.
    static func parse(userInput: String?) -> ChecksumSpec? {
        guard let raw = userInput?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let spec = parse(fragment: raw) { return spec }
        let hex = raw.lowercased()
        if isValidHex(hex, for: .sha256) { return ChecksumSpec(algorithm: .sha256, hex: hex) }
        if isValidHex(hex, for: .md5) { return ChecksumSpec(algorithm: .md5, hex: hex) }
        return nil
    }

    private static func isValidHex(_ s: String, for algorithm: ChecksumAlgorithm) -> Bool {
        let expectedLen = algorithm == .sha256 ? 64 : 32
        guard s.count == expectedLen else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }
}

enum ChecksumVerifier {
    /// Read block size — stream the file so a multi-GB download isn't loaded
    /// into memory to hash it.
    static let blockSize = 1 << 20  // 1 MB

    /// Computes the lowercase hex digest of the file at `url`.
    static func hexDigest(of url: URL, algorithm: ChecksumAlgorithm) throws -> String {
        switch algorithm {
        case .sha256:
            var h = SHA256()
            return try streamDigest(of: url, into: &h)
        case .md5:
            var h = Insecure.MD5()
            return try streamDigest(of: url, into: &h)
        }
    }

    private static func streamDigest<H: HashFunction>(of url: URL, into hasher: inout H) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: blockSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws `ChecksumError.mismatch` when the file's digest doesn't match
    /// `expectedHex`. No-op (success) when no expected checksum is supplied.
    static func verify(fileAt url: URL, expectedHex: String?, algorithm: ChecksumAlgorithm?) throws {
        guard
            let algorithm,
            let expected = expectedHex?.trimmingCharacters(in: .whitespaces).lowercased(),
            !expected.isEmpty
        else { return }
        let actual = try hexDigest(of: url, algorithm: algorithm)
        guard actual == expected else {
            throw ChecksumError.mismatch(expected: expected, actual: actual, algorithm: algorithm)
        }
    }
}
