import Foundation

/// Single dependency container for the app. Built once in `MacgetApp.init` and
/// passed down to views.
@MainActor
final class AppEnvironment {
    let store: DownloadStore
    let engine: DownloadEngine
    let updater: UpdaterController
    let clipboardWatcher: ClipboardWatcher
    let captureInbox: CaptureInbox
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
        self.captureInbox = CaptureInbox()
        // Capture settings via a closure so the provider always uses the latest destination.
        self.servicesProvider = DownloadServicesProvider { [weak engine] url in
            guard let engine else { return }
            let dest = SettingsStore.load().defaultDestination
            Task { await engine.add(url: url, destinationFolder: dest) }
        }
        self.captureInbox.onCapture = { [weak self] request in
            self?.enqueueCaptured(request)
        }
        applyBrowserCaptureState(initialSettings.browserCaptureEnabled)
    }

    /// Enqueue a URL coming from any external entry point (NSServices, macget://,
    /// drag-drop, Dock-icon drop). Always uses the latest persisted default destination.
    func enqueue(url: URL) {
        let dest = settings.defaultDestination
        Task { await engine.add(url: url, destinationFolder: dest) }
    }

    /// Enqueue a download captured from a browser extension, carrying its request
    /// headers (Cookie / Referer / User-Agent) so authenticated downloads work.
    func enqueueCaptured(_ request: CaptureRequest) {
        guard let url = URLValidation.parsePlausibleHTTPURL(request.url) else {
            return
        }
        let dest = settings.defaultDestination
        let filename = request.filename.map(FilenameResolver.sanitize)
        let headers = request.requestHeaders
        Task {
            await engine.add(
                url: url,
                destinationFolder: dest,
                filename: filename,
                requestHeaders: headers.isEmpty ? nil : headers
            )
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        let captureChanged = newSettings.browserCaptureEnabled != settings.browserCaptureEnabled
        self.settings = newSettings
        SettingsStore.save(newSettings)
        Task { await engine.updateSettings(newSettings) }
        clipboardWatcher.setEnabled(newSettings.clipboardWatchEnabled)
        if captureChanged {
            applyBrowserCaptureState(newSettings.browserCaptureEnabled)
        }
    }

    /// Start/stop inbox watching and install/remove the native-messaging host
    /// manifests to match the setting.
    private func applyBrowserCaptureState(_ enabled: Bool) {
        captureInbox.setEnabled(enabled)
        if enabled {
            NativeMessagingInstaller.install()
        } else {
            NativeMessagingInstaller.uninstall()
        }
    }
}
