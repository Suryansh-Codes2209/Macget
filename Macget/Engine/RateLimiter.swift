import Foundation

/// Token-bucket bandwidth limiter shared across all active downloads. Workers
/// call `consume(_:)` after each write; when the aggregate rate would exceed the
/// configured ceiling the call suspends just long enough to stay under it. A nil
/// / non-positive limit means unlimited (zero overhead — `consume` returns
/// immediately). The bucket holds at most one second's worth of tokens so a
/// brief idle period can't bank an unbounded burst.
actor RateLimiter {
    private var bytesPerSecond: Int?
    private var availableTokens: Double
    private var lastRefill: Date

    init(bytesPerSecond: Int? = nil, now: Date = Date()) {
        let normalized = RateLimiter.normalize(bytesPerSecond)
        self.bytesPerSecond = normalized
        self.availableTokens = Double(normalized ?? 0)
        self.lastRefill = now
    }

    func setLimit(_ bytesPerSecond: Int?) {
        self.bytesPerSecond = RateLimiter.normalize(bytesPerSecond)
        if self.bytesPerSecond == nil { availableTokens = 0 }
    }

    /// Suspends until `count` bytes are permitted under the current limit.
    /// No-op when unlimited.
    func consume(_ count: Int, now: Date = Date()) async {
        guard let rate = bytesPerSecond, rate > 0, count > 0 else { return }
        refill(rate: rate, now: now)
        availableTokens -= Double(count)
        if availableTokens < 0 {
            let seconds = -availableTokens / Double(rate)
            // Cap a single wait so one oversized write can't stall for minutes.
            let nanos = UInt64(min(seconds, 5.0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
    }

    private func refill(rate: Int, now: Date) {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        lastRefill = now
        let burstCap = Double(rate)
        availableTokens = min(burstCap, availableTokens + elapsed * Double(rate))
    }

    private static func normalize(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return v
    }

    /// Pure helper (no clock, no sleep) so the throttle math is unit-testable:
    /// given current tokens, the rate, a requested byte count, and seconds
    /// elapsed since the last refill, returns the wait (seconds) before the
    /// request may proceed. `0` means no wait.
    static func delaySeconds(tokens: Double, rate: Int, requested: Int, elapsed: TimeInterval) -> TimeInterval {
        guard rate > 0 else { return 0 }
        let burstCap = Double(rate)
        let refilled = min(burstCap, tokens + max(0, elapsed) * Double(rate))
        let after = refilled - Double(requested)
        return after >= 0 ? 0 : (-after / Double(rate))
    }
}
