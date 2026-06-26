import AppKit
import SwiftUI
import os

/// Hooks termination so we can tell the engine to stop workers cleanly and
/// flush the persisted queue before the process exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?

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

    /// Handle URLs dropped on the Dock icon or opened via the macget:// scheme.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let env = environment else { return }
        for url in urls {
            if url.scheme?.lowercased() == "macget" {
                if let extracted = MacgetURLScheme.extractDownloadURL(from: url) {
                    env.enqueue(url: extracted)
                }
            } else if let valid = URLValidation.parsePlausibleHTTPURL(url.absoluteString) {
                env.enqueue(url: valid)
            }
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
}
