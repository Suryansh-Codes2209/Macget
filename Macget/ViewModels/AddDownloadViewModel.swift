import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class AddDownloadViewModel {
    var urlString: String = ""
    var destinationFolder: URL
    var threadCount: Int
    var startImmediately: Bool = true
    /// Optional expected checksum (e.g. `sha256=…`, `md5=…`, or a bare hex digest).
    var checksumText: String = ""

    private let environment: AppEnvironment
    private let defaultFolder: URL
    private let defaultThreads: Int

    init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.defaultFolder = settings.defaultDestination
        self.destinationFolder = settings.defaultDestination
        self.defaultThreads = settings.defaultThreadCount
        self.threadCount = settings.defaultThreadCount
    }

    /// What the sheet would submit, or nil while the field isn't yet something
    /// MacGet can download. Accepts magnets and `.torrent` files as well as
    /// http(s) — `AppEnvironment.add(url:)` routes each to the right engine, and
    /// an http-only check here left the Add button dead for a pasted magnet.
    private var parsedURL: URL? {
        URLValidation.parseAcceptableDownloadURL(urlString)
    }

    var isValid: Bool { parsedURL != nil }

    func reset() {
        urlString = ""
        destinationFolder = defaultFolder
        threadCount = defaultThreads
        startImmediately = true
        checksumText = ""
    }

    /// True when the checksum field is empty (fine) or parses to a valid digest.
    /// A non-empty, unparseable value is flagged so the user can fix a typo.
    var checksumIsAcceptable: Bool {
        checksumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ChecksumSpec.parse(userInput: checksumText) != nil
    }

    func prefillFromClipboard() {
        // A copied magnet prefills too. Unlike `ClipboardWatcher`, this only fills
        // the field — the user still has to press Add, so nothing starts
        // uploading behind their back.
        if let s = NSPasteboard.general.string(forType: .string),
           let url = URLValidation.parseAcceptableDownloadURL(s) {
            urlString = url.absoluteString
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationFolder
        if panel.runModal() == .OK, let url = panel.url {
            destinationFolder = url
        }
    }

    /// Returns true if the URL was accepted. The caller should then dismiss the sheet.
    /// Video URLs are routed to the quality picker by `environment.add`; the
    /// filename/threads/checksum fields below apply only to plain HTTP downloads.
    func submit() async -> Bool {
        guard let url = parsedURL else { return false }
        let suggested = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let safe = FilenameResolver.sanitize(suggested)

        environment.add(
            url: url,
            destinationFolder: destinationFolder,
            filename: safe,
            threadCount: threadCount,
            startImmediately: startImmediately,
            checksum: ChecksumSpec.parse(userInput: checksumText)
        )
        return true
    }
}
