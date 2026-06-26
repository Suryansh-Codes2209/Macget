import Foundation

/// Maps a filename to a destination subfolder name when auto-sort is on, reusing
/// `FileTypeIcon.category(for:)` so the sort matches the icon shown in the list.
/// Pure and side-effect free for unit testing; the coordinator does the actual
/// directory creation + move.
enum CategoryFolder {
    /// The subfolder a file of this name should land in, or `nil` for uncategorized
    /// files (which stay in the destination root rather than an "Other" bucket).
    static func subfolder(for filename: String) -> String? {
        switch FileTypeIcon.category(for: filename) {
        case .video:           return "Movies"
        case .audio:           return "Music"
        case .image:           return "Pictures"
        case .archive:         return "Archives"
        case .pdf, .document:  return "Documents"
        case .code:            return "Code"
        case .app, .disk:      return "Apps"
        case .generic:         return nil
        }
    }
}
