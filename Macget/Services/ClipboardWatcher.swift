import Foundation
import AppKit

/// Polls `NSPasteboard.general` once per second; whenever the change-count
/// advances and the new contents are a plausible URL, fires `onURLDetected`.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var enabled: Bool = false
    var onURLDetected: ((URL) -> Void)?

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            lastChangeCount = NSPasteboard.general.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc

        guard let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard let url = parsePlausibleURL(str) else { return }
        onURLDetected?(url)
    }

    private func parsePlausibleURL(_ str: String) -> URL? {
        URLValidation.parsePlausibleHTTPURL(str)
    }
}

/// Shared HTTP/HTTPS URL validation reused by ClipboardWatcher, NSServices,
/// the macget:// URL scheme handler, and drag-and-drop.
enum URLValidation {
    static func parsePlausibleHTTPURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 2048 else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        guard url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Everything a *user-initiated* entry point may hand to
    /// `AppEnvironment.add(url:)` — the Add sheet, an OS URL open, a Dock drop.
    ///
    /// Deliberately wider than `parsePlausibleHTTPURL`: `Info.plist` registers
    /// MacGet as a `magnet:` handler, so clicking a magnet on a torrent site
    /// launches the app with that URL. Validating it as http meant the launch
    /// succeeded and the link was then silently discarded — the app opened and
    /// nothing else happened. Local `.torrent` files are the same story from
    /// Finder. `add(url:)` already routes all three kinds; this is just the gate
    /// in front of it.
    ///
    /// Not used by `ClipboardWatcher`: copying a magnet must not start a torrent
    /// on its own, since a torrent also uploads and opens a listening port.
    static func parseAcceptableDownloadURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "magnet":
            // A real magnet carries a long `tr` list, routinely past the 2048-char
            // http cap, so it gets its own (generous) bound. The info hash is the
            // whole payload — without a usable `xt` there is no torrent to add.
            guard trimmed.count < 16_384, MagnetLink.parse(url) != nil else { return nil }
            return url
        case "file":
            // Only metainfo. Any other local file is not a download.
            return url.pathExtension.lowercased() == "torrent" ? url : nil
        default:
            return parsePlausibleHTTPURL(trimmed)
        }
    }
}
