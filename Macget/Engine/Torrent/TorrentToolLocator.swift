import Foundation
import OSLog

/// Finds `aria2c`, the BitTorrent engine MacGet drives over JSON-RPC.
///
/// Unlike `yt-dlp`/`ffmpeg`, aria2 is **not** bundled in the DMG. There is no
/// static macOS build to vendor — every distribution links against `openssl@3`,
/// `libssh2`, `c-ares`, `sqlite`, and `gettext`, so shipping it would mean
/// re-pathing and notarizing five dylibs. Instead MacGet locates a system copy
/// and offers to install one, the same shape as the on-demand Deno fetch in
/// `MediaToolInstaller`.
///
/// A pleasant side effect: MacGet never redistributes aria2, so its GPL carries
/// no obligation here.
enum TorrentToolLocator {
    private static let log = Logger(subsystem: "com.macget", category: "TorrentTools")

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: URL??   // outer nil = not computed

    /// Cached lookup. Pass `force` after an install to recompute.
    static func locate(force: Bool = false) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if !force, let cached { return cached }
        let result = resolve(in: defaultDirectories())
        cached = .some(result)
        return result
    }

    /// Pure resolution over an explicit directory list — unit-testable.
    static func resolve(in directories: [URL], fileManager: FileManager = .default) -> URL? {
        for dir in directories {
            let candidate = dir.appendingPathComponent("aria2c")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Writable directory an installed copy can live in, mirroring
    /// `MediaToolLocator.appSupportBinDirectory`.
    static var appSupportBinDirectory: URL {
        MediaToolLocator.appSupportBinDirectory
    }

    private static func defaultDirectories() -> [URL] {
        var dirs: [URL] = [appSupportBinDirectory]
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("bin", isDirectory: true))
        }
        // Finder-launched apps inherit a minimal PATH, so probe explicit locations
        // rather than trusting `$PATH` — same reasoning as `MediaToolLocator`.
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            dirs.append(URL(fileURLWithPath: p, isDirectory: true))
        }
        if let shellDir = loginShellToolDirectory() {
            dirs.append(shellDir)
        }
        return dirs
    }

    /// `zsh -lc 'command -v aria2c'` → its parent directory, for non-standard installs.
    private static func loginShellToolDirectory() -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v aria2c 2>/dev/null | head -1"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// Location of a Homebrew binary, if Homebrew is installed.
    static func homebrewExecutable(fileManager: FileManager = .default) -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

/// Installs `aria2c` on demand via Homebrew.
///
/// Homebrew is used rather than downloading a binary ourselves because aria2's
/// dylib dependencies need a package manager to resolve — see
/// `TorrentToolLocator` for why bundling isn't viable.
actor TorrentToolInstaller {
    static let shared = TorrentToolInstaller()

    private var inFlight: Task<URL, Error>?
    private let log = Logger(subsystem: "com.macget", category: "TorrentTools")

    enum InstallError: Error, LocalizedError {
        case homebrewMissing
        case installFailed(status: Int32, output: String)
        case notFoundAfterInstall

        var errorDescription: String? {
            switch self {
            case .homebrewMissing:
                return "Torrent support needs aria2. Install it with Homebrew (brew install aria2), then try again."
            case .installFailed(let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = detail.isEmpty ? "" : " \(String(detail.suffix(300)))"
                return "Installing aria2 failed (exit \(status)).\(tail)"
            case .notFoundAfterInstall:
                return "aria2 reported success but aria2c still isn't on disk."
            }
        }

        /// A command the user can paste, shown alongside the error.
        var recoverySuggestionCommand: String? {
            switch self {
            case .homebrewMissing, .installFailed, .notFoundAfterInstall:
                return "brew install aria2"
            }
        }
    }

    /// Returns a runnable `aria2c`, installing it once if needed. Concurrent
    /// callers share a single in-flight install.
    func ensureAria2() async throws -> URL {
        if let existing = TorrentToolLocator.locate() { return existing }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await Self.install() }
        inFlight = task
        defer { inFlight = nil }
        let url = try await task.value
        log.info("aria2c available at \(url.path, privacy: .public)")
        return url
    }

    /// True when aria2 is already present — lets Settings show state without
    /// kicking off an install.
    nonisolated static var isInstalled: Bool {
        TorrentToolLocator.locate() != nil
    }

    private static func install() async throws -> URL {
        guard let brew = TorrentToolLocator.homebrewExecutable() else {
            throw InstallError.homebrewMissing
        }

        let process = Process()
        process.executableURL = brew
        process.arguments = ["install", "aria2"]
        // Homebrew refuses to run with a stale/interactive environment in some
        // setups; a non-interactive marker keeps it from prompting.
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NONINTERACTIVE"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw InstallError.installFailed(status: process.terminationStatus, output: output)
        }
        guard let url = TorrentToolLocator.locate(force: true) else {
            throw InstallError.notFoundAfterInstall
        }
        return url
    }
}
