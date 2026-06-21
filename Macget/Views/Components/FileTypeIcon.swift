import Foundation
import UniformTypeIdentifiers

/// Maps a filename to an SF Symbol + a coarse category, so the download list can
/// show a "smart" icon (video, audio, image, archive, doc, …) instead of a
/// generic file. Pure and UI-free (returns a symbol *name* and a `Category`) so
/// the mapping is unit-testable; the view picks the tint from the category.
enum FileTypeIcon {
    enum Category: Equatable {
        case video, audio, image, archive, pdf, document, code, app, disk, generic
    }

    static func category(for filename: String) -> Category {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .generic }

        // Fast-path extensions that UTType either misclassifies for our purposes
        // or doesn't know on every macOS version.
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst":
            return .archive
        case "dmg", "iso":
            return .disk
        case "pkg", "app", "mpkg":
            return .app
        case "js", "ts", "swift", "py", "rb", "go", "rs", "c", "cpp", "h",
             "java", "kt", "sh", "json", "xml", "yml", "yaml", "html", "css":
            return .code
        default:
            break
        }

        guard let type = UTType(filenameExtension: ext) else { return .generic }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .diskImage) { return .disk }
        if type.conforms(to: .sourceCode) { return .code }
        if type.conforms(to: .application) { return .app }
        if type.conforms(to: .text) { return .document }
        return .generic
    }

    static func symbolName(for filename: String) -> String {
        switch category(for: filename) {
        case .video:    return "film"
        case .audio:    return "music.note"
        case .image:    return "photo"
        case .archive:  return "doc.zipper"
        case .pdf:      return "doc.richtext"
        case .document: return "doc.text"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .app:      return "app.badge"
        case .disk:     return "internaldrive"
        case .generic:  return "doc"
        }
    }
}
