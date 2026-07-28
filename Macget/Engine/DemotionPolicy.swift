import Foundation

/// Decides whether a burst of no-progress chunk attempts means *the host* is
/// hostile, as opposed to the local link being down.
///
/// The distinction matters because the answer is persisted. `HostCapStore`
/// remembers a demotion across launches, so blaming the host for a Wi-Fi drop
/// leaves a permanent cap on a server that did nothing wrong.
///
/// The discriminator is aggregate throughput. A host rejecting excess
/// connections RSTs *some* workers while continuing to serve the others at full
/// speed, so bytes keep moving. A network fault fails *every* worker at once and
/// throughput collapses to nothing. When nothing anywhere is moving, the retry
/// and backoff path is the right response and no cap should be learned.
enum DemotionPolicy {
    /// No-progress attempts within `windowSeconds` before we consider demoting.
    static let threshold = 4

    /// Sliding window the failures are counted over.
    static let windowSeconds: TimeInterval = 10

    /// Bytes-per-attempt below which an attempt counts as "no progress".
    static let progressCutoff: Int64 = 16 * 1024

    /// Aggregate throughput that has to be flowing for failures to be read as
    /// host hostility rather than a dead link. Matched to `progressCutoff` so a
    /// single healthy worker clears it and a dying trickle does not.
    static let healthyThroughputBytesPerSecond: Double = 16 * 1024

    /// - Parameters:
    ///   - failureCount: no-progress attempts inside the current window.
    ///   - throughputBytesPerSecond: aggregate speed over the download's rolling
    ///     window — the evidence that *some* connection is still being served.
    static func shouldDemote(
        failureCount: Int,
        throughputBytesPerSecond: Double,
        threshold: Int = threshold,
        healthyThroughput: Double = healthyThroughputBytesPerSecond
    ) -> Bool {
        guard failureCount >= threshold else { return false }
        return throughputBytesPerSecond >= healthyThroughput
    }
}
