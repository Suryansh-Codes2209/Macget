import Foundation
import OSLog

/// Writes (and removes) the Native Messaging host manifest that lets browser
/// extensions launch `MacgetCaptureHost`. One manifest per browser family, in
/// each browser's `NativeMessagingHosts` directory. The manifest's `path` points
/// at the host executable inside the app bundle and is re-stamped on every
/// install so it survives the user moving Macget.app.
enum NativeMessagingInstaller {
    private static let log = Logger(subsystem: "com.macget", category: "NativeMessaging")

    /// Native-messaging host name the extensions connect to.
    static let hostName = "com.suryansh.macget"

    /// Chromium extension IDs allowed to launch the host. Chromium requires
    /// explicit origins — no wildcards — so we list both:
    ///   • the unpacked-dev ID, pinned by the `key` in manifest.json, and
    ///   • the Chrome Web Store ID assigned to the published extension.
    static let chromiumExtensionIDs = [
        "knccbiljmilfmhfellkfbdmilpbdkgni",  // unpacked dev (manifest `key`)
        "ldmhmgglgemkoogpokfcgplbpfokcejl",  // Chrome Web Store (published)
    ]

    /// Firefox add-on id (from `browser_specific_settings.gecko.id`).
    static let firefoxExtensionID = "macget@suryansh"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var appSupport: URL { home.appendingPathComponent("Library/Application Support") }

    /// Chromium-family `NativeMessagingHosts` directories.
    private static var chromiumHostDirs: [URL] {
        [
            "Google/Chrome",
            "Google/Chrome Beta",
            "Google/Chrome Canary",
            "Microsoft Edge",
            "BraveSoftware/Brave-Browser",
            "Chromium",
        ].map { appSupport.appendingPathComponent($0).appendingPathComponent("NativeMessagingHosts") }
    }

    /// Firefox `NativeMessagingHosts` directory.
    private static var firefoxHostDir: URL {
        appSupport.appendingPathComponent("Mozilla/NativeMessagingHosts")
    }

    /// Absolute path to the host executable inside the running app bundle. Lives
    /// in `Contents/MacOS` alongside the main binary — the codesign-expected
    /// location for nested executables.
    static var hostExecutablePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/MacgetCaptureHost")
            .path
    }

    // MARK: - Public API

    static func install() {
        let path = hostExecutablePath
        guard FileManager.default.fileExists(atPath: path) else {
            log.error("Host executable missing at \(path); skipping manifest install.")
            return
        }
        for dir in chromiumHostDirs {
            write(manifest: chromiumManifest(path: path), to: dir)
        }
        write(manifest: firefoxManifest(path: path), to: firefoxHostDir)
    }

    static func uninstall() {
        for dir in chromiumHostDirs + [firefoxHostDir] {
            let file = dir.appendingPathComponent("\(hostName).json")
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Manifest builders

    private static func chromiumManifest(path: String) -> [String: Any] {
        [
            "name": hostName,
            "description": "Macget download capture host",
            "path": path,
            "type": "stdio",
            "allowed_origins": chromiumExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
    }

    private static func firefoxManifest(path: String) -> [String: Any] {
        [
            "name": hostName,
            "description": "Macget download capture host",
            "path": path,
            "type": "stdio",
            "allowed_extensions": [firefoxExtensionID],
        ]
    }

    private static func write(manifest: [String: Any], to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            let file = dir.appendingPathComponent("\(hostName).json")
            try data.write(to: file, options: .atomic)
        } catch {
            log.error("Failed writing native-messaging manifest to \(dir.path): \(error.localizedDescription)")
        }
    }
}
