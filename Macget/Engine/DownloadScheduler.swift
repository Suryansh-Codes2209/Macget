import Foundation

/// Pure scheduling order for the queue. Higher-priority downloads run first;
/// ties keep their existing (insertion) order — a stable sort. Kept side-effect
/// free so the ordering is unit-testable independent of the engine actor.
enum DownloadScheduler {
    /// `queued` must already be in insertion order. Returns it re-ordered with
    /// high-priority items first and equal-priority items left in place.
    static func order(_ queued: [Download]) -> [Download] {
        queued.enumerated()
            .sorted { a, b in
                if a.element.priority.rank != b.element.priority.rank {
                    return a.element.priority.rank > b.element.priority.rank
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}

/// Pure time-of-day "quiet hours" window. Downloads run only while the window is
/// open. All values are minutes-from-midnight (0...1439). Kept side-effect free so
/// the boundary/wrap-around logic is unit-testable independent of the engine clock.
enum DownloadWindow {
    /// True when `now` falls inside `[start, end)`. A window where `start == end`
    /// is treated as always open (no restriction). Windows that wrap past midnight
    /// (e.g. 22:00 → 06:00, start > end) are open when `now >= start` OR `now < end`.
    static func isOpen(now: Int, start: Int, end: Int) -> Bool {
        let n = ((now % 1440) + 1440) % 1440
        let s = ((start % 1440) + 1440) % 1440
        let e = ((end % 1440) + 1440) % 1440
        if s == e { return true }
        if s < e { return n >= s && n < e }
        return n >= s || n < e          // wraps past midnight
    }

    /// Minutes-from-midnight for "now" in the current calendar/timezone.
    static func minutesNow(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
