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
    /// Drives the credential prompt for password-protected downloads.
    let authPrompt = AuthPromptModel()
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
        self.servicesProvider = DownloadServicesProvider()
        // Self-capturing handlers are assigned after the stored-property phase so
        // they can reference `self` (which is fully initialized by this point).
        self.servicesProvider.onURL = { [weak self] url in
            self?.add(url: url)
        }
        self.captureInbox.onCapture = { [weak self] request in
            self?.enqueueCaptured(request)
        }
        // Route the engine's credential requests to the prompt sheet.
        let engineRef = engine
        Task {
            await engineRef.setAuthHandler { [weak self] id, host in
                await self?.presentAuthPrompt(downloadID: id, host: host)
            }
        }
        applyExtensionBridgeState(for: initialSettings)
    }

    /// Show the username/password sheet for a download that returned 401/407. On
    /// submit, store the credential (Keychain if "remember", else session-only)
    /// and resume the download so it retries with the credential.
    private func presentAuthPrompt(downloadID: UUID, host: String) {
        guard !authPrompt.isPresented else { return }
        authPrompt.onSubmit = { user, password, remember in
            if remember {
                CredentialStore.shared.save(host: host, user: user, password: password)
            } else {
                CredentialStore.shared.saveSession(host: host, user: user, password: password)
            }
            Task { await self.engine.resume(downloadID) }
        }
        authPrompt.present(
            downloadID: downloadID,
            host: host,
            suggestedUser: CredentialStore.shared.username(forHost: host) ?? ""
        )
    }

    /// Single media-aware entry point for every "a user gave us a URL" path
    /// (Add sheet, clipboard, drag-drop, Services, `macget://`). Video URLs open
    /// the quality picker; everything else becomes a normal HTTP file download.
    /// HTTP-file parameters (filename/threads/checksum) are ignored for media —
    /// yt-dlp owns chunking and naming there.
    func add(url: URL,
             destinationFolder: URL? = nil,
             filename: String? = nil,
             threadCount: Int? = nil,
             startImmediately: Bool? = nil,
             requestHeaders: [String: String]? = nil,
             checksum: ChecksumSpec? = nil,
             title: String? = nil) {
        let dest = destinationFolder ?? settings.defaultDestination
        if MediaURLClassifier.isMediaURL(url) {
            enableMediaExtractionIfNeeded()
            startMediaPick(pageURL: url, destinationFolder: dest, title: title, headers: requestHeaders)
            return
        }
        Task {
            await engine.add(
                url: url,
                destinationFolder: dest,
                filename: filename,
                threadCount: threadCount,
                startImmediately: startImmediately,
                requestHeaders: requestHeaders,
                checksum: checksum
            )
        }
    }

    /// Enqueue a URL coming from any external entry point (NSServices, macget://,
    /// drag-drop, Dock-icon drop). Always uses the latest persisted default destination.
    func enqueue(url: URL) {
        add(url: url)
    }

    // MARK: - Book catalogs

    /// Built on first use so users who never open the browser never construct an
    /// OPDS client — and so browse position survives closing and reopening the sheet.
    private var bookBrowserModel: BookBrowserModel?

    func bookBrowser() -> BookBrowserModel {
        if let existing = bookBrowserModel {
            // Settings may have added/removed catalogs since the sheet last closed.
            existing.refreshSources()
            return existing
        }
        let model = BookBrowserModel { [weak self] entry, link in
            self?.addBook(entry: entry, link: link)
        }
        bookBrowserModel = model
        return model
    }

    /// Enqueue a book chosen in the catalog browser.
    ///
    /// Goes straight to `engine.add` rather than through `add(url:)`: the media
    /// classifier is for pages that *might* be video, and a catalog acquisition
    /// link is already a known book file. The filename is ours because catalogs
    /// routinely serve `2701.epub` or `download?id=84`.
    func addBook(entry: CatalogEntry, link: AcquisitionLink) {
        let filename = BookFilename.make(
            title: entry.title,
            authors: entry.authors,
            format: link.format
        )
        let dest = settings.defaultDestination
        Task {
            await engine.add(
                url: link.url,
                destinationFolder: dest,
                filename: filename,
                userSpecifiedFilename: true
            )
        }
    }

    /// "Download videos" is off by default. When a recognized video URL is added
    /// directly, silently turn it on (decided behavior) so the picker can proceed.
    /// Note: this also starts the shared extension bridge via `updateSettings`.
    private func enableMediaExtractionIfNeeded() {
        guard !settings.mediaExtractionEnabled else { return }
        var updated = settings
        updated.mediaExtractionEnabled = true
        updateSettings(updated)
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
        // Route through `add` so a video link captured as a plain file is still
        // caught by the classifier and sent to the picker.
        add(
            url: url,
            destinationFolder: dest,
            filename: request.filename.map(FilenameResolver.sanitize),
            requestHeaders: headers.isEmpty ? nil : headers,
            title: request.title
        )
    }

    /// Present the quality picker for a video: probe formats, then on a user pick
    /// enqueue the media download with the chosen yt-dlp selector. `destinationFolder`
    /// lets the Add sheet's chosen folder win over the default.
    func startMediaPick(pageURL: URL,
                        destinationFolder: URL? = nil,
                        title: String?,
                        headers: [String: String]?) {
        // The picker holds a single session; ignore a second media URL while one
        // is already on screen (v1 limitation).
        guard !mediaPick.isPresented else {
            Log.app.info("A quality picker is already open — ignoring the new media URL.")
            return
        }
        let dest = destinationFolder ?? settings.defaultDestination
        mediaPick.onPick = { [weak self] option in
            guard let self else { return }
            // Read the resolved title synchronously — `pick()` nils the session
            // right after invoking this closure. Falls back to the original title.
            let resolvedTitle = self.mediaPick.session?.title ?? title
            Task {
                await self.engine.addMedia(
                    pageURL: pageURL,
                    destinationFolder: dest,
                    title: resolvedTitle,
                    formatSelector: option.selector,
                    requestHeaders: headers
                )
            }
        }
        // Playlist confirm: fan out one media download per selected entry, all at
        // the same generic quality (per-entry probing would be too slow).
        mediaPick.onPickPlaylist = { [weak self] entries, quality in
            guard let self else { return }
            for entry in entries {
                guard let entryURL = entry.resolvedURL(relativeTo: pageURL) else { continue }
                let entryTitle = entry.title
                Task {
                    await self.engine.addMedia(
                        pageURL: entryURL,
                        destinationFolder: dest,
                        title: entryTitle,
                        formatSelector: quality.selector,
                        requestHeaders: headers
                    )
                }
            }
        }
        mediaPick.present(pageURL: pageURL, title: title)

        let isPlaylist = MediaURLClassifier.isLikelyPlaylist(pageURL)
        Task { @MainActor in
            if isPlaylist {
                switch await self.probePlaylistEntries(pageURL: pageURL, headers: headers) {
                case .success(let entries):
                    self.mediaPick.setPlaylist(entries, title: nil)
                case .failure(let error):
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.mediaPick.setFailed(msg)
                }
            } else {
                switch await self.probeMedia(pageURL: pageURL, headers: headers) {
                case .success(let info):
                    self.mediaPick.setReady(info.pickerOptions, title: info.title)
                case .failure(let error):
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.mediaPick.setFailed(msg)
                }
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

    /// Resolve tools and list a playlist's entries (flat, no per-video probing).
    private func probePlaylistEntries(pageURL: URL, headers: [String: String]?) async -> Result<[PlaylistEntry], Error> {
        guard var tools = MediaToolLocator.locate() else {
            return .failure(MediaError.toolsUnavailable)
        }
        if tools.deno == nil, MediaExtractionJob.needsJSRuntime(pageURL),
           let deno = try? await MediaToolInstaller.shared.ensureDeno() {
            tools = MediaTools(ytDlp: tools.ytDlp, ffmpegDir: tools.ffmpegDir, deno: deno, source: tools.source)
        }
        do {
            let entries = try await YtDlpRunner(tools: tools).probePlaylist(pageURL: pageURL, headers: headers)
            return .success(entries)
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
