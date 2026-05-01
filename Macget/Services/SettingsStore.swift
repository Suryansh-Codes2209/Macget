import Foundation
import OSLog

/// Persists `AppSettings` as a JSON file in
/// `~/Library/Application Support/Macget/settings.json`. Synchronous since
/// settings change rarely and we don't need debouncing.
enum SettingsStore {
    private static let log = Logger(subsystem: "com.macget", category: "SettingsStore")

    static var fileURL: URL = {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Macget", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    static func load() -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppSettings() }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            log.error("Failed to load settings.json: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    static func save(_ settings: AppSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write settings.json: \(error.localizedDescription)")
        }
    }
}
