import AppKit
import SwiftUI
import os

/// Hooks termination so we can tell the engine to stop workers cleanly and
/// flush the persisted queue before the process exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment? {
        didSet { flushPendingURLs() }
    }

    /// Owns the menu bar item. Held here because it must outlive any window.
    private var statusBar: StatusBarController?

    /// URLs that arrived before the SwiftUI scene handed over the environment.
    ///
    /// A cold launch *from* a magnet click delivers the URL before
    /// `ContentView`'s `.task` runs, so without this buffer the one click that
    /// launched the app is exactly the click that gets dropped.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Macget launched")
        if let env = environment {
            NSApp.servicesProvider = env.servicesProvider
            NSUpdateDynamicServices()
        }
        openExtensionStoreOnFirstLaunch()
    }

    /// On the very first launch ever, open the companion browser extension's
    /// Chrome Web Store page so the user can install it right away. A persisted
    /// flag guarantees this happens exactly once.
    private func openExtensionStoreOnFirstLaunch() {
        let key = "Macget.didOpenExtensionStoreOnFirstLaunch"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        guard let url = URL(string: "https://chromewebstore.google.com/detail/ldmhmgglgemkoogpokfcgplbpfokcejl") else { return }
        Log.app.info("First launch: opening browser extension store page")
        NSWorkspace.shared.open(url)
    }

    /// The **single** owner of every URL the OS hands MacGet — a magnet click, a
    /// Dock drop, `macget://`.
    ///
    /// `MacgetApp` deliberately has no `.onOpenURL`: with both in place one click
    /// was enqueued twice, and the second add came back from aria2 as "This
    /// torrent is already in the queue", leaving a phantom failed row next to the
    /// real download. The SwiftUI modifier also spawns a *new* window to deliver
    /// the URL, which is why a magnet opened a second MacGet window instead of
    /// using the one already on screen.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard environment != nil else {
            pendingURLs.append(contentsOf: urls)
            Log.app.info("Buffered \(urls.count) URL(s) opened before launch finished")
            return
        }
        urls.forEach(handle)
    }

    private func flushPendingURLs() {
        guard environment != nil, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(handle)
    }

    private func handle(_ url: URL) {
        guard let env = environment else { return }
        Log.app.info("Opening URL with scheme \(url.scheme ?? "none", privacy: .public)")
        if url.scheme?.lowercased() == "macget" {
            if let extracted = MacgetURLScheme.extractDownloadURL(from: url) {
                env.enqueue(url: extracted)
            }
        } else if let valid = URLValidation.parseAcceptableDownloadURL(url.absoluteString) {
            env.enqueue(url: valid)
        } else {
            Log.app.error("Ignoring unusable URL passed to MacGet")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let env = environment else { return .terminateNow }
        Task {
            await env.engine.suspendAllForShutdown()
            await env.store.flushIfNeeded()
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Standard macOS: keep running in the dock when the window is closed.
        false
    }

    /// Let AppKit rebuild the window when the app is reopened with none on
    /// screen — from the Dock icon, or from the menu bar item's "Open MacGet".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    /// Attach the menu bar item. Called from the scene once `listVM` exists, so
    /// the controller has something to observe.
    func installStatusBar(listVM: DownloadListViewModel) {
        guard statusBar == nil else { return }
        statusBar = StatusBarController(listVM: listVM)
    }
}
