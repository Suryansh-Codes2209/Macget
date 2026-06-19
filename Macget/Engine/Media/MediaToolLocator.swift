import Foundation

/// Resolved paths to the external media tools.
struct MediaTools: Sendable, Equatable {
    let ytDlp: URL
    /// Directory containing `ffmpeg`/`ffprobe` for yt-dlp's `--ffmpeg-location`,
    /// or nil if not found (yt-dlp can still fetch progressive formats without it).
    let ffmpegDir: URL?
    /// A JavaScript runtime (Deno) for solving YouTube's signature/`n` challenges.
    /// nil if not found — YouTube downloads then fail ("only images available"),
    /// but non-YouTube sites still work.
    let deno: URL?
    let source: Source

    enum Source: String, Sendable { case appSupport, bundled, path }
}

/// Finds `yt-dlp` and `ffmpeg`. Search order: a self-updated copy under
/// Application Support, the bundled copy in `Resources/bin`, then common
/// Homebrew/PATH locations. Finder-launched apps inherit a minimal PATH, so we
/// probe explicit directories rather than relying on `$PATH`.
enum MediaToolLocator {
    /// yt-dlp ships either as `yt-dlp` or the standalone `yt-dlp_macos` binary.
    private static let ytDlpNames = ["yt-dlp", "yt-dlp_macos"]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: MediaTools??  // outer nil = not computed

    /// Cached lookup (computed once per process). Pass `force` to recompute after
    /// the user installs tools.
    static func locate(force: Bool = false) -> MediaTools? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if !force, let cached { return cached }
        let result = resolve(in: defaultDirectories())
        cached = .some(result)
        return result
    }

    /// Pure resolution over an explicit directory list — unit-testable.
    static func resolve(in directories: [URL], fileManager: FileManager = .default) -> MediaTools? {
        func executable(_ name: String, in dir: URL) -> URL? {
            let u = dir.appendingPathComponent(name)
            return fileManager.isExecutableFile(atPath: u.path) ? u : nil
        }

        for (index, dir) in directories.enumerated() {
            guard let yt = ytDlpNames.lazy.compactMap({ executable($0, in: dir) }).first else { continue }
            // Prefer ffmpeg/deno next to yt-dlp; otherwise scan all dirs.
            let ffmpeg = executable("ffmpeg", in: dir)
                ?? directories.lazy.compactMap({ executable("ffmpeg", in: $0) }).first
            let deno = executable("deno", in: dir)
                ?? directories.lazy.compactMap({ executable("deno", in: $0) }).first
            let source: MediaTools.Source = index == 0 ? .appSupport : (yt.path.contains(".app/Contents/Resources") ? .bundled : .path)
            return MediaTools(ytDlp: yt, ffmpegDir: ffmpeg?.deletingLastPathComponent(), deno: deno, source: source)
        }
        return nil
    }

    /// Directory where a self-updated yt-dlp would live (writable, unlike the bundle).
    static var appSupportBinDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Macget/bin", isDirectory: true)
    }

    private static func defaultDirectories() -> [URL] {
        var dirs: [URL] = [appSupportBinDirectory]
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("bin", isDirectory: true))
        }
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            dirs.append(URL(fileURLWithPath: p, isDirectory: true))
        }
        // Last resort: ask a login shell where yt-dlp is (covers non-standard installs).
        if let shellDir = loginShellToolDirectory() {
            dirs.append(shellDir)
        }
        return dirs
    }

    /// `zsh -lc 'command -v yt-dlp'` → its parent directory, or nil.
    private static func loginShellToolDirectory() -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v yt-dlp yt-dlp_macos 2>/dev/null | head -1"]
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
}
