import Foundation
import OSLog

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
    /// Drives the per-download video quality picker sheet.
    let mediaPick = MediaPickModel()
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
        applyExtensionBridgeState(for: initialSettings)
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
        let dest = settings.defaultDestination
        let headers = request.requestHeaders

        // Media (video) captures go to the yt-dlp extractor, gated behind the
        // (off-by-default) setting. `url` carries the page URL for media payloads.
        if (request.kind ?? .file) == .media {
            guard settings.mediaExtractionEnabled else {
                Log.app.info("Ignored a media capture — 'Download videos' is off in Settings.")
                return
            }
            guard let pageURL = URLValidation.parsePlausibleHTTPURL(request.pageURL ?? request.url) else { return }
            startMediaPick(pageURL: pageURL, title: request.title, headers: headers.isEmpty ? nil : headers)
            return
        }

        guard let url = URLValidation.parsePlausibleHTTPURL(request.url) else {
            return
        }
        let filename = request.filename.map(FilenameResolver.sanitize)
        Task {
            await engine.add(
                url: url,
                destinationFolder: dest,
                filename: filename,
                requestHeaders: headers.isEmpty ? nil : headers
            )
        }
    }

    /// Present the quality picker for a captured video: probe formats, then on a
    /// user pick enqueue the media download with the chosen yt-dlp selector.
    private func startMediaPick(pageURL: URL, title: String?, headers: [String: String]?) {
        mediaPick.onPick = { [weak self] option in
            guard let self else { return }
            let dest = self.settings.defaultDestination
            Task {
                await self.engine.addMedia(
                    pageURL: pageURL,
                    destinationFolder: dest,
                    title: title,
                    formatSelector: option.selector,
                    requestHeaders: headers
                )
            }
        }
        mediaPick.present(pageURL: pageURL, title: title)

        Task { @MainActor in
            switch await self.probeMedia(pageURL: pageURL, headers: headers) {
            case .success(let info):
                self.mediaPick.setReady(info.pickerOptions)
            case .failure(let error):
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.mediaPick.setFailed(msg)
            }
        }
    }

    /// Resolve tools (fetching Deno for YouTube if needed) and probe the page for
    /// available formats.
    private func probeMedia(pageURL: URL, headers: [String: String]?) async -> Result<MediaInfo, Error> {
        guard var tools = MediaToolLocator.locate() else {
            return .failure(MediaError.toolsUnavailable)
        }
        if tools.deno == nil, MediaExtractionJob.needsJSRuntime(pageURL),
           let deno = try? await MediaToolInstaller.shared.ensureDeno() {
            tools = MediaTools(ytDlp: tools.ytDlp, ffmpegDir: tools.ffmpegDir, deno: deno, source: tools.source)
        }
        do {
            let info = try await YtDlpRunner(tools: tools).probe(pageURL: pageURL, headers: headers)
            return .success(info)
        } catch {
            return .failure(error)
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        let bridgeChanged = extensionBridgeNeeded(newSettings) != extensionBridgeNeeded(settings)
        self.settings = newSettings
        SettingsStore.save(newSettings)
        Task { await engine.updateSettings(newSettings) }
        clipboardWatcher.setEnabled(newSettings.clipboardWatchEnabled)
        if bridgeChanged {
            applyExtensionBridgeState(for: newSettings)
        }
    }

    /// The extension talks to Macget through one native-messaging host + inbox
    /// watcher, shared by file capture AND media (video) captures. Either feature
    /// being on means the bridge must be running.
    private func extensionBridgeNeeded(_ s: AppSettings) -> Bool {
        s.browserCaptureEnabled || s.mediaExtractionEnabled
    }

    /// Start/stop inbox watching and install/remove the native-messaging host
    /// manifests to match whether any extension feature needs them.
    private func applyExtensionBridgeState(for settings: AppSettings) {
        let enabled = extensionBridgeNeeded(settings)
        captureInbox.setEnabled(enabled)
        if enabled {
            NativeMessagingInstaller.install()
        } else {
            NativeMessagingInstaller.uninstall()
        }
    }
}
