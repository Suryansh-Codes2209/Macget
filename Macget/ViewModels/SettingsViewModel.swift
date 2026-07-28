import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class SettingsViewModel {
    var settings: AppSettings

    private let environment: AppEnvironment

    /// Shared with the main window so the acknowledgement flow is the same
    /// wherever torrents get switched on.
    var torrentSetup: TorrentSetupModel { environment.torrentSetup }

    init(environment: AppEnvironment, initial: AppSettings) {
        self.environment = environment
        self.settings = initial
    }

    func chooseDefaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.defaultDestination
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultDestination = url
            persistAndPropagate()
        }
    }

    /// Persist settings and propagate them everywhere: the store, the engine,
    /// the clipboard watcher, and the browser-capture inbox + native-messaging
    /// manifests. Routing through AppEnvironment (rather than the engine alone)
    /// is what makes toggles like auto-capture take effect immediately instead
    /// of only after the next launch.
    func persistAndPropagate() {
        environment.updateSettings(settings)
    }
}
