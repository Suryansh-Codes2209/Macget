import Foundation
import Observation

/// Drives the per-download video quality picker sheet. AppEnvironment fills it in
/// when a media capture arrives: present → probe formats → user picks → download.
@MainActor
@Observable
final class MediaPickModel {
    struct Session {
        let pageURL: URL
        var title: String?
        var state: State
    }

    enum State: Equatable {
        case probing
        case ready([MediaPickOption])        // single video: choose a quality
        case playlist([PlaylistEntry])       // playlist: choose entries + one generic quality
        case failed(String)
    }

    var session: Session?

    /// Set by AppEnvironment for the active session: called with the chosen option.
    var onPick: ((MediaPickOption) -> Void)?
    /// Called for a playlist with the chosen entries and a single generic quality.
    var onPickPlaylist: (([PlaylistEntry], MediaPlaylistQuality) -> Void)?

    var isPresented: Bool { session != nil }

    func present(pageURL: URL, title: String?) {
        session = Session(pageURL: pageURL, title: title, state: .probing)
    }

    func setReady(_ options: [MediaPickOption], title: String?) {
        guard session != nil else { return }
        // Adopt the probed title so the download row shows the real video name
        // immediately. Guard non-empty so a blank probe title doesn't clobber an
        // initial (e.g. extension-supplied) title.
        if let title, !title.isEmpty {
            session?.title = title
        }
        session?.state = options.isEmpty
            ? .failed("No downloadable video or audio formats were found for this page.")
            : .ready(options)
    }

    func setPlaylist(_ entries: [PlaylistEntry], title: String?) {
        guard session != nil else { return }
        if let title, !title.isEmpty { session?.title = title }
        session?.state = entries.isEmpty
            ? .failed("This playlist appears to be empty or could not be read.")
            : .playlist(entries)
    }

    func setFailed(_ message: String) {
        guard session != nil else { return }
        session?.state = .failed(message)
    }

    func pick(_ option: MediaPickOption) {
        onPick?(option)
        reset()
    }

    func pickPlaylist(_ entries: [PlaylistEntry], quality: MediaPlaylistQuality) {
        onPickPlaylist?(entries, quality)
        reset()
    }

    func cancel() {
        reset()
    }

    private func reset() {
        session = nil
        onPick = nil
        onPickPlaylist = nil
    }
}
