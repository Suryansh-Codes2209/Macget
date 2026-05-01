import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class SettingsViewModel {
    var settings: AppSettings

    private let engine: DownloadEngine

    init(engine: DownloadEngine, initial: AppSettings) {
        self.engine = engine
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

    /// Persist settings and tell the engine.
    func persistAndPropagate() {
        SettingsStore.save(settings)
        Task { await engine.updateSettings(settings) }
    }
}
