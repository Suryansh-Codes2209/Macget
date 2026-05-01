import Foundation

/// Single dependency container for the app. Built once in `MacgetApp.init` and
/// passed down to views.
@MainActor
final class AppEnvironment {
    let store: DownloadStore
    let engine: DownloadEngine
    let updater: UpdaterController
    let clipboardWatcher: ClipboardWatcher
    let servicesProvider: DownloadServicesProvider
    var settings: AppSettings

    init() {
        let store = DownloadStore()
        let initialSettings = SettingsStore.load()
        self.store = store
        self.settings = initialSettings
        let engine = DownloadEngine(store: store, settings: initialSettings)
        self.engine = engine
        self.updater = UpdaterController()
        self.clipboardWatcher = ClipboardWatcher()
        self.clipboardWatcher.setEnabled(initialSettings.clipboardWatchEnabled)
        // Capture settings via a closure so the provider always uses the latest destination.
        self.servicesProvider = DownloadServicesProvider { [weak engine] url in
            guard let engine else { return }
            let dest = SettingsStore.load().defaultDestination
            Task { await engine.add(url: url, destinationFolder: dest) }
        }
    }

    /// Enqueue a URL coming from any external entry point (NSServices, macget://,
    /// drag-drop, Dock-icon drop). Always uses the latest persisted default destination.
    func enqueue(url: URL) {
        let dest = settings.defaultDestination
        Task { await engine.add(url: url, destinationFolder: dest) }
    }

    func updateSettings(_ newSettings: AppSettings) {
        self.settings = newSettings
        SettingsStore.save(newSettings)
        Task { await engine.updateSettings(newSettings) }
        clipboardWatcher.setEnabled(newSettings.clipboardWatchEnabled)
    }
}
