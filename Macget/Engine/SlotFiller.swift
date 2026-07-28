import Foundation

/// What a free worker slot should do next.
enum SlotAction: Equatable {
    /// Take the identified outstanding piece (work-stealing).
    case spawn(UUID)
    /// Nothing outstanding — halve the largest in-flight piece and run both
    /// halves (IDM's in-half division rule).
    case split(ChunkSplitDecision)
    /// Slot stays idle: at the cap, nothing left, or nothing worth splitting.
    case none
}

/// Pure decision logic for filling a free worker slot, used by
/// `DownloadCoordinator.fillIdleSlots`.
///
/// Stealing is preferred over splitting because stealing is free — an
/// outstanding piece has no worker to cancel. Splitting costs a reconnect, so it
/// is the fallback for the endgame, when every remaining piece is already
/// assigned and a finished worker would otherwise idle while one slow connection
/// drains the tail.
enum SlotFiller {
    /// Ceiling on how far splitting may grow the piece array.
    ///
    /// Splits append, and `collapseChunksForCompletion` only runs at the very
    /// end, so the array stays at its high-water mark through the whole tail. At
    /// this bound that is ~66 KB of JSON per in-flight download against a
    /// debounced 500 ms write — affordable, but it should be bounded rather than
    /// growing with however long the tail lasts.
    static let maxPieces = ChunkPlanner.maxPieces * 2

    static func nextAction(
        chunks: [Chunk],
        assigned: Set<UUID>,
        cap: Int,
        minimumSplitBytes: Int64 = ChunkSplitter.defaultMinimumSplitBytes,
        maxPieces: Int = maxPieces
    ) -> SlotAction {
        guard assigned.count < cap else { return .none }

        if let next = chunks.first(where: { !$0.isComplete && !assigned.contains($0.id) }) {
            return .spawn(next.id)
        }

        guard chunks.count < maxPieces else { return .none }
        guard let decision = ChunkSplitter.nextSplit(
            chunks: chunks,
            minimumSplitBytes: minimumSplitBytes
        ) else { return .none }

        return .split(decision)
    }
}
