import Foundation
import Observation
import AppKit

/// Whatever owns the app's settings — `AppEnvironment` in the app. A protocol
/// only so the sync between it and `SettingsViewModel` is testable: the
/// environment itself can't be built in a test.
@MainActor
protocol SettingsHost: AnyObject {
    var settings: AppSettings { get }
    /// Called after *every* settings change, including ones the host makes on
    /// its own (switching torrents or media extraction on during an add).
    var onSettingsChanged: ((AppSettings) -> Void)? { get set }
    var torrentSetup: TorrentSetupModel { get }
    func updateSettings(_ newSettings: AppSettings)
}

@MainActor
@Observable
final class SettingsViewModel {
    var settings: AppSettings

    @ObservationIgnored private let environment: SettingsHost

    /// Shared with the main window so the acknowledgement flow is the same
    /// wherever torrents get switched on.
    var torrentSetup: TorrentSetupModel { environment.torrentSetup }

    convenience init(environment: AppEnvironment, initial: AppSettings) {
        self.init(host: environment, initial: initial)
    }

    /// There is exactly one of these per app, so it claims the host's change
    /// callback. Mirroring host writes is what stops a later save — from the
    /// Settings window or the toolbar popover — from writing back a stale copy
    /// and silently switching torrents or media extraction off again.
    init(host: SettingsHost, initial: AppSettings) {
        self.environment = host
        self.settings = initial
        host.onSettingsChanged = { [weak self] latest in
            // Our own saves echo back unchanged; skipping them keeps
            // SettingsView's `.onChange(of: vm.settings)` from re-saving.
            guard let self, self.settings != latest else { return }
            self.settings = latest
        }
    }

    /// Apply one change on top of the host's current settings and save. For
    /// writers outside the Settings window (the toolbar's Connections popover).
    func edit(_ change: (inout AppSettings) -> Void) {
        var next = environment.settings
        change(&next)
        settings = next
        persistAndPropagate()
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
