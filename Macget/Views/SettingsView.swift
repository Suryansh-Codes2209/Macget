import SwiftUI

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel
    @State private var mediaToolStatus: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            downloadsTab
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            networkTab
                .tabItem { Label("Network", systemImage: "network") }
            CatalogSettingsView()
                .tabItem { Label("Catalogs", systemImage: "books.vertical") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
        .onChange(of: vm.settings) { _, _ in vm.persistAndPropagate() }
    }

    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Default folder")
                    Spacer()
                    Text(vm.settings.defaultDestination.path)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { vm.chooseDefaultFolder() }
                }
                Toggle("Resume in-progress downloads on launch", isOn: $vm.settings.resumeOnLaunch)
                Toggle("Notify when a download completes", isOn: $vm.settings.completionNotificationsEnabled)
            }
            Section {
                Toggle("Auto-capture downloads from the browser extension",
                       isOn: $vm.settings.browserCaptureEnabled)
                Toggle("Auto-add http(s) URLs copied to the clipboard",
                       isOn: $vm.settings.clipboardWatchEnabled)
            } header: {
                Text("Browser integration")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("With the Macget browser extension installed, turning on auto-capture lets downloads you start in Chrome, Edge, Brave, or Firefox be handed straight to Macget (cookies included, so logged-in downloads work). Install the extension from the `BrowserExtension/` folder.")
                    Text("No extension? Macget still picks up downloads several ways:")
                    Text("• Right-click a link → **Services → Download with Macget** (enable once in System Settings → Keyboard → Keyboard Shortcuts → Services).")
                    Text("• Drag a URL from the address bar onto the Macget window.")
                    Text("• Use the URL scheme: `macget://download?url=<encoded-link>` works in any browser via a bookmarklet.")
                    Text("• Toggle clipboard watching above for hands-off auto-add when you copy a link.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Download videos (YouTube & other sites)",
                       isOn: $vm.settings.mediaExtractionEnabled)
                if vm.settings.mediaExtractionEnabled {
                    HStack(spacing: 6) {
                        Text("Media tools:")
                        Text(mediaToolStatus ?? "Checking…")
                            .foregroundStyle(mediaToolStatus?.hasPrefix("yt-dlp not found") == true ? .red : .secondary)
                    }
                    .font(.caption)

                    Toggle("Download subtitles", isOn: $vm.settings.mediaWriteSubtitles)
                    if vm.settings.mediaWriteSubtitles {
                        HStack {
                            Text("Subtitle languages")
                            TextField("en", text: $vm.settings.mediaSubtitleLanguages)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            Text("e.g. en, en,es, all")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Embed metadata (title, uploader, date)", isOn: $vm.settings.mediaEmbedMetadata)
                    Toggle("Save thumbnail / cover art", isOn: $vm.settings.mediaWriteThumbnail)
                }
            } header: {
                Text("Video downloads")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Uses **yt-dlp** (and **ffmpeg** for merging), bundled with Macget, to download video from the page you're watching via the extension's in-page button. A system copy on your PATH is used instead when present.")
                    Text("Only download content you're authorized to — e.g. your own uploads, Creative Commons, or where the site permits. Downloading from many sites (including YouTube) may violate their Terms of Service; you are responsible for your use.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .task(id: vm.settings.mediaExtractionEnabled) {
            guard vm.settings.mediaExtractionEnabled else { return }
            mediaToolStatus = nil
            let tools = await Task.detached { MediaToolLocator.locate(force: true) }.value
            if let tools {
                let ff = tools.ffmpegDir == nil ? " — ffmpeg missing (merging unavailable)" : ""
                mediaToolStatus = "found (\(tools.source.rawValue))\(ff)"
            } else {
                mediaToolStatus = "yt-dlp not found — run `brew install yt-dlp ffmpeg`"
            }
        }
    }

    private var downloadsTab: some View {
        Form {
            Section {
                Stepper(
                    "Default threads per download: \(vm.settings.defaultThreadCount)",
                    value: $vm.settings.defaultThreadCount,
                    in: 1...Download.maxThreadCount
                )
                Stepper(
                    "Max simultaneous downloads: \(vm.settings.maxConcurrentDownloads)",
                    value: $vm.settings.maxConcurrentDownloads,
                    in: 1...Download.maxThreadCount
                )
                Toggle("Start downloads automatically when added", isOn: $vm.settings.startDownloadsAutomatically)
                Toggle("Sort completed downloads into folders by type", isOn: $vm.settings.autoSortByType)
            } footer: {
                Text("Each download splits the file into N parallel HTTP-Range requests when the server supports it. Macget starts conservatively and adds connections only while they speed the download up. More threads = faster on cooperative servers, but some servers throttle if you open too many connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Limit total download speed", isOn: Binding(
                    get: { vm.settings.globalSpeedLimitBytesPerSec != nil },
                    set: { on in
                        vm.settings.globalSpeedLimitBytesPerSec = on
                            ? (vm.settings.globalSpeedLimitBytesPerSec ?? 1024 * 1024)
                            : nil
                    }
                ))
                if vm.settings.globalSpeedLimitBytesPerSec != nil {
                    HStack {
                        Text("Max speed")
                        Spacer()
                        TextField("KB/s", value: Binding(
                            get: { Double(vm.settings.globalSpeedLimitBytesPerSec ?? 0) / 1024.0 },
                            set: { vm.settings.globalSpeedLimitBytesPerSec = $0 > 0 ? Int($0 * 1024) : nil }
                        ), format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Bandwidth")
            } footer: {
                Text("Caps the combined speed of all active downloads. Leave off for full speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Only download during scheduled hours", isOn: $vm.settings.scheduleEnabled)
                if vm.settings.scheduleEnabled {
                    DatePicker("From", selection: timeBinding(\.scheduleStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: timeBinding(\.scheduleEndMinutes), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Outside this window, active downloads pause and resume automatically when it reopens. A window that crosses midnight (e.g. 10 PM–6 AM) is supported. Set both times equal for no restriction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    /// Bridges an `AppSettings` minutes-from-midnight field to a `DatePicker`.
    private func timeBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let mins = vm.settings[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                vm.settings[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var networkTab: some View {
        Form {
            Section {
                Stepper(
                    "Request timeout: \(vm.settings.requestTimeoutSeconds)s",
                    value: $vm.settings.requestTimeoutSeconds,
                    in: 5...300,
                    step: 5
                )
                Stepper(
                    "Retry attempts per chunk: \(vm.settings.maxRetriesPerChunk)",
                    value: $vm.settings.maxRetriesPerChunk,
                    in: 1...10
                )
            } header: {
                Text("Timeouts & retries")
            } footer: {
                Text("Request timeout is how long a stalled connection waits before it's retried. Retry attempts are per chunk before Macget backs off the connection count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use an HTTP proxy", isOn: Binding(
                    get: { vm.settings.proxyHost != nil },
                    set: { on in
                        if on {
                            vm.settings.proxyHost = vm.settings.proxyHost ?? "127.0.0.1"
                            vm.settings.proxyPort = vm.settings.proxyPort ?? 8080
                        } else {
                            vm.settings.proxyHost = nil
                            vm.settings.proxyPort = nil
                        }
                    }
                ))
                if vm.settings.proxyHost != nil {
                    HStack {
                        Text("Host")
                        TextField("127.0.0.1", text: Binding(
                            get: { vm.settings.proxyHost ?? "" },
                            set: { vm.settings.proxyHost = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Port")
                        TextField("8080", value: Binding(
                            get: { vm.settings.proxyPort ?? 0 },
                            set: { vm.settings.proxyPort = (1...65535).contains($0) ? $0 : nil }
                        ), format: .number.grouping(.never))
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Text("Proxy")
            } footer: {
                Text("Routes HTTP and HTTPS downloads through the proxy. Changes apply to downloads started afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Macget")
                .font(.title2.weight(.semibold))
            if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Version \(v)")
                    .foregroundStyle(.secondary)
            }
            Text("Free, open-source download manager.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
