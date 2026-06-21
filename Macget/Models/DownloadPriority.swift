import Foundation

/// Queue priority. The scheduler picks higher-priority queued downloads first;
/// ties fall back to insertion order. Persisted on `Download`; defaults to
/// `.normal` for older queue.json entries that predate the field.
enum DownloadPriority: String, Codable, Sendable, CaseIterable {
    case high
    case normal
    case low

    /// Higher number = scheduled sooner. Used purely for ordering.
    var rank: Int {
        switch self {
        case .high:   return 2
        case .normal: return 1
        case .low:    return 0
        }
    }

    var displayName: String {
        switch self {
        case .high:   return "High"
        case .normal: return "Normal"
        case .low:    return "Low"
        }
    }
}
