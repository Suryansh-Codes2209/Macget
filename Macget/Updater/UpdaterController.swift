import Foundation
import SwiftUI
import AppKit

#if canImport(Sparkle)
import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` so SwiftUI can drive it.
/// Once you've added the Sparkle SPM dependency, this gives you a working
/// "Check for Updates" menu command.
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater = true → Sparkle starts its scheduled-check timer.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}

#else

/// Fallback stub used when Sparkle isn't yet linked into the project. Lets the
/// app build before you've added the SPM dependency. Remove this branch once
/// Sparkle is wired up.
@MainActor
final class UpdaterController {
    init() {}

    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Updates not configured"
        alert.informativeText = "Add the Sparkle SPM dependency to enable in-app updates. See README."
        alert.runModal()
    }

    var canCheckForUpdates: Bool { false }
}

#endif
