import SwiftUI

@main
struct MacgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var environment: AppEnvironment
    @State private var listVM: DownloadListViewModel
    @State private var settingsVM: SettingsViewModel
    @State private var inspector: InspectorModel

    init() {
        let env = AppEnvironment()
        let list = DownloadListViewModel(engine: env.engine)
        _environment = State(initialValue: env)
        _listVM = State(initialValue: list)
        _settingsVM = State(initialValue: SettingsViewModel(environment: env, initial: env.settings))
        _inspector = State(initialValue: InspectorModel(engine: env.engine, list: list))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(listVM: listVM, appEnvironment: environment, mediaPick: environment.mediaPick, authPrompt: environment.authPrompt, inspector: inspector)
                .frame(minWidth: 720, minHeight: 420)
                .task {
                    appDelegate.environment = environment
                    listVM.bootstrap()
                    appDelegate.installStatusBar(listVM: listVM)
                    environment.clipboardWatcher.onURLDetected = { url in
                        Task { @MainActor in
                            environment.add(url: url)
                        }
                    }
                }
                // Claim every external event for the window that already exists,
                // so a magnet click reuses it instead of opening a second one.
                //
                // The matching scene-level `.handlesExternalEvents(matching:)` is
                // deliberately absent: an empty set there suppresses window
                // creation at *cold* launch too, and since the environment is
                // wired up in `ContentView`'s `.task`, a windowless launch never
                // wires anything up and the magnet that started the app is lost.
                //
                // Incoming URLs are handled entirely by
                // `AppDelegate.application(_:open:)`. There is deliberately no
                // `.onOpenURL` here — with both in place each magnet was enqueued
                // twice, and the loser came back as "already in the queue".
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
