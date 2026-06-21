import Foundation
import UniformTypeIdentifiers

enum FilenameResolver {
    /// If `<folder>/<preferredName>` is free, returns it. Otherwise appends
    /// " (2)", " (3)", … before the extension until a unique name is found.
    static func uniqueURL(in folder: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let preferredName = truncatedToByteLimit(preferredName)
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

    /// If `name` has no extension, infers one from `mimeType` (e.g.
    /// `application/pdf` → `.pdf`). Returns `name` unchanged when it already has
    /// an extension or no MIME mapping exists. Used after the probe so files
    /// from signed/CDN URLs (no extension in the path) still get a sensible one.
    static func ensuringExtension(_ name: String, mimeType: String?) -> String {
        guard (name as NSString).pathExtension.isEmpty else { return name }
        guard let mimeType else { return name }
        // Strip any parameters: "text/plain; charset=utf-8" → "text/plain".
        let bare = mimeType.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? mimeType
        guard let ext = UTType(mimeType: bare)?.preferredFilenameExtension, !ext.isEmpty else {
            return name
        }
        return "\(name).\(ext)"
    }

    /// Truncates a filename to stay within the 255-byte limit APFS (and most
    /// filesystems) impose per path component, preserving the extension and
    /// NFC-normalizing first (decomposed Unicode otherwise inflates the byte
    /// count and can mismatch on lookup). Trims whole Characters so a multibyte
    /// grapheme is never cut mid-sequence.
    static func truncatedToByteLimit(_ name: String, limit: Int = 255) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping  // NFC
        guard normalized.utf8.count > limit else { return normalized }

        let ns = normalized as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let extBytes = ext.isEmpty ? 0 : ext.utf8.count + 1  // +1 for the dot
        let budget = max(1, limit - extBytes)

        var truncatedStem = stem
        while truncatedStem.utf8.count > budget, !truncatedStem.isEmpty {
            truncatedStem.removeLast()
        }
        if truncatedStem.isEmpty { truncatedStem = String(stem.prefix(1)) }
        return ext.isEmpty ? truncatedStem : "\(truncatedStem).\(ext)"
    }

    /// Strips path separators and unsafe chars from a candidate name.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0000}")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "download" : trimmed
    }
}
