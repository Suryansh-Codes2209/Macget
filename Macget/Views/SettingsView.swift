import SwiftUI

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            downloadsTab
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
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
        }
        .padding(20)
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
            } footer: {
                Text("Each download splits the file into N parallel HTTP-Range requests when the server supports it. More threads = faster on cooperative servers, but some servers throttle if you open too many connections.")
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
