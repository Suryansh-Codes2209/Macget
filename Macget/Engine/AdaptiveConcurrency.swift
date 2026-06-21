import Foundation

/// Pure decision logic for speed-aware connection scaling (aria2-style). The
/// coordinator starts a download conservatively and probes upward — adding one
/// connection at a time and keeping it only when aggregate throughput actually
/// improved. Kept side-effect-free so the keep/drop rule is unit-testable.
enum AdaptiveConcurrency {
    /// Connection count a fresh download starts at before probing upward. Gentle
    /// on servers and avoids a burst of connections that a host might rate-limit
    /// before we've learned anything about it.
    static let initialWorkers = 4

    /// Minimum fractional speed gain required to justify keeping an added
    /// connection. Below this the extra connection isn't paying for itself
    /// (server- or path-bound), so we settle and stop probing.
    static let improvementThreshold = 0.15  // +15%

    /// Whether the connection added since `speedBefore` was measured earned its
    /// keep. With no baseline yet (`speedBefore <= 0`) we keep probing.
    static func didImprove(speedBefore: Double, speedAfter: Double, threshold: Double = improvementThreshold) -> Bool {
        guard speedBefore > 0 else { return true }
        return (speedAfter - speedBefore) / speedBefore >= threshold
    }
}
