import Foundation

/// The heading a download sits under when the list is grouped by kind.
///
/// Deliberately the same buckets — and the same *names* — as `CategoryFolder`,
/// which is what auto-sort uses for destination subfolders. A file that lands in
/// the "Music" folder on disk appears under the "Music" heading in the list, so
/// the two features can never disagree about what a file is.
///
/// Pure and UI-free (it returns a symbol *name*, not an image) so the mapping is
/// unit-testable; the view supplies the tint.
enum DownloadCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case movies = "Movies"
    case music = "Music"
    case pictures = "Pictures"
    case documents = "Documents"
    case archives = "Archives"
    case code = "Code"
    case apps = "Apps"
    case other = "Other"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Declaration order is section order. `other` is last on purpose — an
    /// unclassified file is the least interesting thing in the list.
    static var displayOrder: [DownloadCategory] { allCases }

    var symbol: String {
        switch self {
        case .movies:    return "film"
        case .music:     return "music.note"
        case .pictures:  return "photo"
        case .documents: return "doc.text"
        case .archives:  return "doc.zipper"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .apps:      return "app.badge"
        case .other:     return "doc"
        }
    }

    // MARK: - Collapsed-folder persistence

    /// Decode the set of *collapsed* folders from its `@AppStorage` string.
    ///
    /// Collapsed rather than expanded is the deliberate choice: `@AppStorage`
    /// starts empty, and an empty *collapsed* set means every folder is open. If
    /// this stored the expanded set instead, a first launch — and every launch
    /// after a new category first appears — would show nothing but shut folders.
    ///
    /// Unrecognized raw values are dropped rather than preserved, so a category
    /// removed in a later version can't resurrect as a phantom entry.
    static func decodeCollapsed(_ raw: String) -> Set<DownloadCategory> {
        Set(raw.split(separator: ",").compactMap { DownloadCategory(rawValue: String($0)) })
    }

    /// Encode in `displayOrder` so the stored string is stable — a `Set`'s own
    /// iteration order varies per launch and would rewrite the preference (and
    /// churn any diff of it) on every toggle.
    static func encodeCollapsed(_ collapsed: Set<DownloadCategory>) -> String {
        displayOrder.filter(collapsed.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The category a file of this name belongs to. Mirrors
    /// `CategoryFolder.subfolder(for:)`, with `.generic` — which stays in the
    /// destination root rather than getting an "Other" folder — surfacing here
    /// as `.other`, because a list still has to put the row somewhere.
    static func of(filename: String) -> DownloadCategory {
        switch FileTypeIcon.category(for: filename) {
        case .video:           return .movies
        case .audio:           return .music
        case .image:           return .pictures
        case .pdf, .document:  return .documents
        case .archive:         return .archives
        case .code:            return .code
        case .app, .disk:      return .apps
        case .generic:         return .other
        }
    }
}
