import SwiftUI

@main
struct MacgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var environment: AppEnvironment
    @State private var listVM: DownloadListViewModel
    @State private var settingsVM: SettingsViewModel

    init() {
        let env = AppEnvironment()
        _environment = State(initialValue: env)
        _listVM = State(initialValue: DownloadListViewModel(engine: env.engine))
        _settingsVM = State(initialValue: SettingsViewModel(environment: env, initial: env.settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(listVM: listVM, appEnvironment: environment)
                .frame(minWidth: 720, minHeight: 420)
                .task {
                    appDelegate.environment = environment
                    listVM.bootstrap()
                    environment.clipboardWatcher.onURLDetected = { url in
                        Task { @MainActor in
                            await environment.engine.add(
                                url: url,
                                destinationFolder: environment.settings.defaultDestination
                            )
                        }
                    }
                }
                .onOpenURL { url in
                    if url.scheme?.lowercased() == MacgetURLScheme.scheme {
                        if let target = MacgetURLScheme.extractDownloadURL(from: url) {
                            environment.enqueue(url: target)
                        }
                    } else if let valid = URLValidation.parsePlausibleHTTPURL(url.absoluteString) {
                        environment.enqueue(url: valid)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Macget") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    environment.updater.checkForUpdates()
                }
                .disabled(!environment.updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") {
                    NotificationCenter.default.post(name: .openAddDownload, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView(vm: settingsVM)
        }
    }
}

extension Notification.Name {
    static let openAddDownload = Notification.Name("Macget.openAddDownload")
}
