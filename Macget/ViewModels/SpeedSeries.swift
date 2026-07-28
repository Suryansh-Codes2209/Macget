import Foundation

/// A fixed-length rolling window of throughput samples.
///
/// Kept as a plain value type with no timers or observation of its own so the
/// windowing rules — capacity, peak, average — are testable without a running
/// engine. `InspectorModel` owns the clock; this owns the arithmetic.
struct SpeedSeries: Equatable {
    /// Samples oldest-first. Never longer than `capacity`.
    private(set) var samples: [Double] = []

    /// How many samples the window holds. At the inspector's 250 ms cadence,
    /// 120 samples is a 30-second window — long enough to show a stall or a
    /// ramp, short enough that the curve still moves visibly.
    let capacity: Int

    /// Wall-clock of the most recent `append`, or nil before the first one. The
    /// chart uses it to interpolate between samples so the curve scrolls
    /// continuously instead of stepping four times a second.
    private(set) var lastAppendedAt: Date?

    init(capacity: Int = 120) {
        self.capacity = max(2, capacity)
        samples.reserveCapacity(self.capacity)
    }

    mutating func append(_ value: Double, at date: Date = Date()) {
        samples.append(max(0, value))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        lastAppendedAt = date
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastAppendedAt = nil
    }

    var isEmpty: Bool { samples.isEmpty }

    /// Most recent sample, or 0 before any arrive.
    var current: Double { samples.last ?? 0 }

    var peak: Double { samples.max() ?? 0 }

    /// Mean over the window. Includes zero samples — a download that spent half
    /// the window stalled really did average half its moving speed.
    var average: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// Upper bound for the chart's y-axis. Headroom above the peak keeps the
    /// curve off the top edge, and the floor stops a flat-zero series from
    /// scaling noise up into a mountain range.
    func chartScale(minimum: Double = 64 * 1024) -> Double {
        max(peak * 1.15, minimum)
    }

    /// Samples with a 3-wide moving average applied, which takes the corners off
    /// the 250 ms sampling jitter without the overshoot a spline would add.
    var smoothed: [Double] {
        guard samples.count > 2 else { return samples }
        return samples.indices.map { i in
            let lo = Swift.max(0, i - 1)
            let hi = Swift.min(samples.count - 1, i + 1)
            return samples[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}
