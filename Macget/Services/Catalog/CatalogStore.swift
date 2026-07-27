import Foundation
import OSLog

/// Persists the user's catalog list to
/// `~/Library/Application Support/Macget/catalogs.json`, alongside `queue.json`
/// and `settings.json`.
///
/// Only *user-added* catalogs and *disabled* built-in IDs are written. Built-ins
/// themselves come from `CatalogSource.builtIns` at load time, so shipping a new
/// built-in catalog (or fixing a feed URL) reaches existing installs instead of
/// being pinned by a stale file.
enum CatalogStore {
    private static let log = Logger(subsystem: "com.macget", category: "CatalogStore")

    /// Built-ins carry their own default enabled state (Standard Ebooks ships off
    /// because its feed is donor-gated), so a single "disabled" list isn't enough
    /// — we track both directions and let the built-in's default apply when the
    /// user has expressed no preference.
    private struct Payload: Codable {
        var custom: [CatalogSource] = []
        var disabledBuiltInIDs: [UUID] = []
        var enabledBuiltInIDs: [UUID] = []

        private enum CodingKeys: String, CodingKey {
            case custom, disabledBuiltInIDs, enabledBuiltInIDs
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            custom = try c.decodeIfPresent([CatalogSource].self, forKey: .custom) ?? []
            disabledBuiltInIDs = try c.decodeIfPresent([UUID].self, forKey: .disabledBuiltInIDs) ?? []
            enabledBuiltInIDs = try c.decodeIfPresent([UUID].self, forKey: .enabledBuiltInIDs) ?? []
        }

        init(custom: [CatalogSource], disabledBuiltInIDs: [UUID], enabledBuiltInIDs: [UUID]) {
            self.custom = custom
            self.disabledBuiltInIDs = disabledBuiltInIDs
            self.enabledBuiltInIDs = enabledBuiltInIDs
        }
    }

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
        return dir.appendingPathComponent("catalogs.json")
    }()

    /// All catalogs: built-ins (with their saved enabled state) followed by
    /// user-added ones, in the order the user added them.
    static func load() -> [CatalogSource] {
        let payload = loadPayload()
        let disabled = Set(payload.disabledBuiltInIDs)
        let enabled = Set(payload.enabledBuiltInIDs)
        let builtIns = CatalogSource.builtIns.map { builtIn -> CatalogSource in
            var copy = builtIn
            if disabled.contains(builtIn.id) {
                copy.isEnabled = false
            } else if enabled.contains(builtIn.id) {
                copy.isEnabled = true
            }   // else: keep the built-in's shipped default
            return copy
        }
        // Defensive: a hand-edited file could mark a custom entry as built-in and
        // make it undeletable in the UI.
        let custom = payload.custom.map { source -> CatalogSource in
            var copy = source
            copy.isBuiltIn = false
            return copy
        }
        return builtIns + custom
    }

    static func save(_ sources: [CatalogSource]) {
        let payload = Payload(
            custom: sources.filter { !$0.isBuiltIn },
            disabledBuiltInIDs: sources.filter { $0.isBuiltIn && !$0.isEnabled }.map(\.id),
            enabledBuiltInIDs: sources.filter { $0.isBuiltIn && $0.isEnabled }.map(\.id)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write catalogs.json: \(error.localizedDescription)")
        }
    }

    private static func loadPayload() -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Payload() }
        do {
            return try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
        } catch {
            log.error("Failed to load catalogs.json: \(error.localizedDescription)")
            return Payload()
        }
    }

    // MARK: - Validation

    enum AddError: Error, LocalizedError {
        case notAURL
        case notHTTP
        case duplicate(name: String)

        var errorDescription: String? {
            switch self {
            case .notAURL:            return "That isn't a valid URL."
            case .notHTTP:            return "Catalog feeds must be http:// or https:// URLs."
            case .duplicate(let name): return "That feed is already in your list as \"\(name)\"."
            }
        }
    }

    /// Validate a user-typed feed URL against the existing list. Returns the
    /// source to append on success.
    static func makeCustomSource(
        name: String,
        urlString: String,
        existing: [CatalogSource]
    ) throws -> CatalogSource {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else { throw AddError.notAURL }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AddError.notHTTP
        }
        if let clash = existing.first(where: { $0.feedURL.absoluteString == url.absoluteString }) {
            throw AddError.duplicate(name: clash.name)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? (url.host ?? "Catalog") : trimmedName
        return CatalogSource(name: resolvedName, feedURL: url, isBuiltIn: false, isEnabled: true)
    }
}
