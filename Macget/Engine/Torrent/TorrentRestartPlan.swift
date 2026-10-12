import Foundation

/// Which torrent jobs survive an aria2 restart. Pure so it can be tested
/// without a daemon.
enum TorrentRestartPlan {
    /// Downloading and queued torrents are restarted; every other job (paused,
    /// seeding/completed, failed) is dropped — a paused one is re-added by
    /// `resume`, and a restart must never silently resume it.
    static func plan(_ items: [(UUID, DownloadStatus)]) -> (restart: [UUID], drop: [UUID]) {
        var restart: [UUID] = []
        var drop: [UUID] = []
        for (id, status) in items {
            if status == .downloading || status == .queued {
                restart.append(id)
            } else {
                drop.append(id)
            }
        }
        return (restart, drop)
    }

    /// Re-checked for each torrent at the moment it would be restarted. The plan
    /// is computed before the multi-second daemon shutdown, and a user who paused
    /// (or cancelled) a torrent in that window must not see it come back running.
    static func shouldStartNow(currentStatus: DownloadStatus?, shuttingDown: Bool) -> Bool {
        guard !shuttingDown, let currentStatus else { return false }
        return currentStatus == .downloading || currentStatus == .queued
    }

    /// Link order isn't meaningful to aria2, so reordering is not a change.
    static func sameAddressSet(_ a: [String], _ b: [String]) -> Bool {
        Set(a) == Set(b)
    }
}
