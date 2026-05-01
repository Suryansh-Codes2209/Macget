import Foundation

enum FilenameResolver {
    /// If `<folder>/<preferredName>` is free, returns it. Otherwise appends
    /// " (2)", " (3)", … before the extension until a unique name is found.
    static func uniqueURL(in folder: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let url = folder.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: url.path) { return url }

        let ext = (preferredName as NSString).pathExtension
        let stem = (preferredName as NSString).deletingPathExtension

        var n = 2
        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem) (\(n))"
            } else {
                candidateName = "\(stem) (\(n)).\(ext)"
            }
            let candidate = folder.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
            if n > 9999 { return candidate }     // give up looping
        }
    }

    /// Strips path separators and unsafe chars from a candidate name.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0000}")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "download" : trimmed
    }
}
