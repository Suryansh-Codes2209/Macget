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
}
