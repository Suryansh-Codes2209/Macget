import Foundation

enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        self == .downloading
    }

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    var displayName: String {
        switch self {
        case .queued:      return "Queued"
        case .downloading: return "Downloading"
        case .paused:      return "Paused"
        case .completed:   return "Completed"
        case .failed:      return "Failed"
        case .cancelled:   return "Cancelled"
        }
    }
}
