import Foundation
import Observation
import OSLog

/// Drives the one-time "turn on torrent support" sheet.
///
/// Torrents are opt-in behind an explicit acknowledgement rather than silently
/// enabled (the way media extraction is) for two reasons: BitTorrent *uploads*
/// on the user's connection and opens a listening port, and it needs aria2,
/// which MacGet installs rather than bundles — see `TorrentToolLocator`.
@MainActor
@Observable
final class TorrentSetupModel {

    enum Phase: Equatable {
        /// Explain what enabling torrents does; wait for confirmation.
        case acknowledge
        case installing
        case failed(message: String, command: String?)
    }

    private(set) var phase: Phase = .acknowledge
    private(set) var isPresented = false
    /// True when the user has already accepted the terms and only the aria2
    /// install is missing — the sheet then leads with the install.
    private(set) var alreadyAcknowledged = false

    private var continuation: (() -> Void)?
    private let log = Logger(subsystem: "com.macget", category: "TorrentSetup")

    func present(alreadyAcknowledged: Bool, then action: @escaping () -> Void) {
        guard !isPresented else {
            log.info("Torrent setup already on screen — ignoring the new request.")
            return
        }
        self.alreadyAcknowledged = alreadyAcknowledged
        self.continuation = action
        self.phase = .acknowledge
        self.isPresented = true
    }

    /// User accepted. Install aria2 if it isn't already present, then continue.
    func confirm() {
        guard case .acknowledge = phase else { return }
        if TorrentToolInstaller.isInstalled {
            finish()
            return
        }
        phase = .installing
        Task {
            do {
                _ = try await TorrentToolInstaller.shared.ensureAria2()
                finish()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let command = (error as? TorrentToolInstaller.InstallError)?.recoverySuggestionCommand
                phase = .failed(message: message, command: command)
            }
        }
    }

    /// Re-check after the user installed aria2 themselves from the failure state.
    func retry() {
        guard case .failed = phase else { return }
        if TorrentToolInstaller.isInstalled {
            finish()
        } else {
            phase = .acknowledge
            confirm()
        }
    }

    func cancel() {
        continuation = nil
        isPresented = false
        phase = .acknowledge
    }

    private func finish() {
        let action = continuation
        continuation = nil
        isPresented = false
        phase = .acknowledge
        action?()
    }
}
