import Foundation

/// Rolling-window byte-rate meter. Sample with `record(totalBytes:)` periodically
/// (~every 250ms). `currentSpeed()` returns bytes-per-second over the last
/// `windowSeconds` of samples. ETA is computed against a known total.
actor SpeedMeter {
    private struct Sample {
        let date: Date
        let totalBytes: Int64
    }

    private var samples: [Sample] = []
    private let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = 3.0) {
        self.windowSeconds = windowSeconds
    }

    func record(totalBytes: Int64, at date: Date = Date()) {
        samples.append(Sample(date: date, totalBytes: totalBytes))
        let cutoff = date.addingTimeInterval(-windowSeconds * 2)
        if samples.count > 4 && samples.first!.date < cutoff {
            samples.removeAll { $0.date < cutoff }
        }
    }

    /// Bytes per second over the most recent `windowSeconds`. Returns 0 when
    /// the meter has fewer than 2 useful samples.
    func currentSpeed(now: Date = Date()) -> Double {
        guard let newest = samples.last else { return 0 }
        let cutoff = now.addingTimeInterval(-windowSeconds)
        // Find oldest sample within the window.
        guard let oldest = samples.first(where: { $0.date >= cutoff }) ?? samples.first else { return 0 }
        let dt = newest.date.timeIntervalSince(oldest.date)
        guard dt > 0.05 else { return 0 }
        let db = Double(newest.totalBytes - oldest.totalBytes)
        return max(0, db / dt)
    }

    /// Estimated seconds remaining. Returns nil when speed too low to estimate.
    func eta(totalBytes: Int64, now: Date = Date()) -> TimeInterval? {
        let speed = currentSpeed(now: now)
        guard speed > 1024 else { return nil }   // < 1 KB/s → no ETA
        guard let newest = samples.last else { return nil }
        let remaining = max(0, totalBytes - newest.totalBytes)
        return Double(remaining) / speed
    }

    func reset() {
        samples.removeAll()
    }
}
