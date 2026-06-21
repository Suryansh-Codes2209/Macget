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
