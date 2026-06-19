import Foundation
import Observation

/// Drives the per-download video quality picker sheet. AppEnvironment fills it in
/// when a media capture arrives: present → probe formats → user picks → download.
@MainActor
@Observable
final class MediaPickModel {
    struct Session {
        let pageURL: URL
        let title: String?
        var state: State
    }

    enum State: Equatable {
        case probing
        case ready([MediaPickOption])
        case failed(String)
    }

    var session: Session?

    /// Set by AppEnvironment for the active session: called with the chosen option.
    var onPick: ((MediaPickOption) -> Void)?

    var isPresented: Bool { session != nil }

    func present(pageURL: URL, title: String?) {
        session = Session(pageURL: pageURL, title: title, state: .probing)
    }

    func setReady(_ options: [MediaPickOption]) {
        guard session != nil else { return }
        session?.state = options.isEmpty
            ? .failed("No downloadable video or audio formats were found for this page.")
            : .ready(options)
    }

    func setFailed(_ message: String) {
        guard session != nil else { return }
        session?.state = .failed(message)
    }

    func pick(_ option: MediaPickOption) {
        onPick?(option)
        session = nil
        onPick = nil
    }

    func cancel() {
        session = nil
        onPick = nil
    }
}
