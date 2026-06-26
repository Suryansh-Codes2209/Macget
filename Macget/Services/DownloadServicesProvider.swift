import AppKit
import Foundation

/// Backs the "Download with Macget" entry in the system Services menu.
/// Wired up by `NSApp.servicesProvider = …` in `AppEnvironment`.
@MainActor
final class DownloadServicesProvider: NSObject {
    /// Assigned by `AppEnvironment` after it finishes initializing, so the handler
    /// can capture `self` (mirrors `CaptureInbox.onCapture`).
    var onURL: ((URL) -> Void)?

    override init() {
        super.init()
    }

    /// Selector name must match `NSServices.NSMessage` in Info.plist.
    @objc func downloadURLFromService(
        _ pboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let candidate = pboard.string(forType: .URL)
            ?? pboard.string(forType: .string)
            ?? ""
        guard let url = URLValidation.parsePlausibleHTTPURL(candidate) else {
            errorPointer?.pointee = "Macget: not a valid http(s) URL." as NSString
            return
        }
        onURL?(url)
    }
}
