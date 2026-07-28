import Foundation
import os

/// Coarse lifecycle phase for a media (yt-dlp) download, surfaced to the UI so the
/// row shows a meaningful label during the windows where no bytes move: initial
/// setup/signature solving, and the post-download ffmpeg merge.
enum MediaPhase: Sendable, Equatable {
    case preparing
    case downloading
    case merging

    var label: String {
        switch self {
        case .preparing:   return "Preparing…"
        case .downloading: return "Downloading…"
        case .merging:     return "Merging…"
        }
    }
}

enum MediaError: Error, LocalizedError {
    case toolsUnavailable
    case ytDlpFailed(status: Int32, message: String)
    case noOutputFile
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolsUnavailable:
            return "yt-dlp not found. Install media tools, e.g. `brew install yt-dlp ffmpeg`."
        case .ytDlpFailed(let status, let message):
            let tail = message.isEmpty ? "" : " — \(message)"
            return "Video download failed (yt-dlp exit \(status))\(tail)"
        case .noOutputFile:
            return "yt-dlp finished but did not report an output file."
        case .decodeFailed(let s):
            return "Could not read video formats: \(s)"
        }
    }
}

/// Drives the bundled/system `yt-dlp` via `Foundation.Process`. One runner per
/// media download; `cancel()` terminates the in-flight process.
actor YtDlpRunner {
    struct ProgressUpdate: Sendable {
        let downloaded: Int64
        let total: Int64?
        let speed: Double?         // bytes/sec
        let eta: Double?           // seconds
    }

    /// stdout sentinel so progress lines are unambiguous vs. the `--print` path line.
    static let progressPrefix = "macget-progress:"

    private let tools: MediaTools
    private var process: Process?

    init(tools: MediaTools) {
        self.tools = tools
    }

    // MARK: - Probe

    /// Resolve available formats for a page without downloading.
    func probe(pageURL: URL, headers: [String: String]?) async throws -> MediaInfo {
        var args = ["--no-config", "--no-playlist", "-J"]
        args += jsRuntimeArgs()
        args += Self.headerArgs(headers)
        let cookies = cookieArgs(headers, pageURL: pageURL)
        defer { if let dir = cookies.cleanup { try? FileManager.default.removeItem(at: dir) } }
        args += cookies.args
        args.append(pageURL.absoluteString)

        let (status, stdout, stderr) = try await execute(arguments: args, onLine: nil)
        guard status == 0 else {
            throw MediaError.ytDlpFailed(status: status, message: Self.tail(stderr))
        }
        guard let data = stdout.data(using: .utf8) else {
            throw MediaError.decodeFailed("empty output")
        }
        do {
            return try JSONDecoder().decode(MediaInfo.self, from: data)
        } catch {
            throw MediaError.decodeFailed(error.localizedDescription)
        }
    }

    /// Resolve a playlist's entries cheaply (no per-video format probing). Returns
    /// an empty array for a non-playlist URL (which decodes with `entries == nil`).
    func probePlaylist(pageURL: URL, headers: [String: String]?) async throws -> [PlaylistEntry] {
        var args = ["--no-config", "--flat-playlist", "-J"]
        args += jsRuntimeArgs()
        args += Self.headerArgs(headers)
        let cookies = cookieArgs(headers, pageURL: pageURL)
        defer { if let dir = cookies.cleanup { try? FileManager.default.removeItem(at: dir) } }
        args += cookies.args
        args.append(pageURL.absoluteString)

        let (status, stdout, stderr) = try await execute(arguments: args, onLine: nil)
        guard status == 0 else {
            throw MediaError.ytDlpFailed(status: status, message: Self.tail(stderr))
        }
        guard let data = stdout.data(using: .utf8) else {
            throw MediaError.decodeFailed("empty output")
        }
        do {
            return try JSONDecoder().decode(PlaylistProbe.self, from: data).entries ?? []
        } catch {
            throw MediaError.decodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Download

    /// Download `pageURL` at `formatSelector` into `destinationFolder`, muxing with
    /// ffmpeg when needed. Returns the final on-disk file URL.
    func download(
        pageURL: URL,
        formatSelector: String,
        destinationFolder: URL,
        headers: [String: String]?,
        options: MediaDownloadOptions = .none,
        onProgress: @Sendable @escaping (ProgressUpdate) async -> Void,
        onPhase: @Sendable @escaping (MediaPhase) async -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        var args = [
            // `--print` implies `--quiet`, which otherwise suppresses ALL
            // `--progress-template` output — so the progress lines below would
            // never be emitted. `--progress` forces them even under quiet mode.
            "--no-config", "--no-playlist", "--newline", "--no-simulate", "--progress",
            "--restrict-filenames",
            "--progress-template",
            "\(Self.progressPrefix)%(progress.downloaded_bytes)s/%(progress.total_bytes)s/%(progress.total_bytes_estimate)s/%(progress.speed)s/%(progress.eta)s",
            "--print", "after_move:filepath",
            "-f", formatSelector,
            "-o", destinationFolder.appendingPathComponent("%(title)s.%(ext)s").path,
        ]
        args += mediaOptionArgs(options)
        if let ffmpegDir = tools.ffmpegDir {
            args += ["--ffmpeg-location", ffmpegDir.path]
        }
        args += jsRuntimeArgs()
        args += Self.headerArgs(headers)
        let cookies = cookieArgs(headers, pageURL: pageURL)
        defer { if let dir = cookies.cleanup { try? FileManager.default.removeItem(at: dir) } }
        args += cookies.args
        args.append(pageURL.absoluteString)

        let (status, stdout, stderr) = try await execute(arguments: args) { line in
            if let p = Self.parseProgress(line) {
                await onProgress(p)
            } else if let phase = Self.detectPhase(line) {
                await onPhase(phase)
            }
        }

        guard status == 0 else {
            throw MediaError.ytDlpFailed(status: status, message: Self.tail(stderr))
        }
        // `--print after_move:filepath` emits the final destination path on stdout.
        guard let finalPath = Self.outputPath(fromStdout: stdout) else {
            throw MediaError.noOutputFile
        }
        return URL(fileURLWithPath: finalPath)
    }

    func cancel() {
        process?.terminate()
        process = nil
    }

    // MARK: - Process plumbing

    /// Point yt-dlp at our JS runtime so it can solve YouTube's signature/`n`
    /// challenges. The bundled yt-dlp already carries the EJS solver scripts.
    private func jsRuntimeArgs() -> [String] {
        guard let deno = tools.deno else { return [] }
        return ["--js-runtimes", "deno:\(deno.path)"]
    }

    /// Subtitle / metadata / thumbnail flags from the user's media options.
    /// Embedding (subs/metadata/thumbnail) needs ffmpeg; when it's missing we fall
    /// back to writing sidecar files so the user still gets the data.
    func mediaOptionArgs(_ options: MediaDownloadOptions) -> [String] {
        Self.mediaOptionArgs(options, hasFFmpeg: tools.ffmpegDir != nil)
    }

    static func mediaOptionArgs(_ options: MediaDownloadOptions, hasFFmpeg: Bool) -> [String] {
        var args: [String] = []
        if options.writeSubtitles {
            let langs = options.subtitleLanguages.trimmingCharacters(in: .whitespaces)
            args += ["--write-subs", "--write-auto-subs", "--sub-langs", langs.isEmpty ? "en" : langs]
            if hasFFmpeg { args.append("--embed-subs") }
        }
        if options.embedMetadata {
            args.append("--embed-metadata")
        }
        if options.writeThumbnail {
            args.append("--write-thumbnail")
            if hasFFmpeg { args.append("--embed-thumbnail") }
        }
        return args
    }

    // MARK: - Headers and cookies

    /// `--add-header` args for everything *except* cookies.
    ///
    /// Cookies are deliberately excluded. `--add-header "Cookie: …"` is applied by
    /// yt-dlp to every request it makes, including the media fetch from
    /// `googlevideo.com` — and YouTube answers an authenticated CDN request that
    /// carries no proof-of-origin token with `HTTP Error 403: Forbidden`. That's
    /// why a probe would succeed (innertube metadata is fine authenticated) and
    /// the download that followed would die. yt-dlp warns about this itself:
    /// "they will be scoped to the domain of the downloaded urls". Cookies go
    /// through `netscapeCookieJar` instead, which is domain-scoped.
    static func headerArgs(_ headers: [String: String]?) -> [String] {
        guard let headers else { return [] }
        var args: [String] = []
        for (k, v) in headers where !v.isEmpty && !isCookieHeader(k) {
            args += ["--add-header", "\(k): \(v)"]
        }
        return args
    }

    /// Browsers aren't consistent about header casing, and a case-sensitive check
    /// would let `cookie:` straight back into `--add-header`.
    static func isCookieHeader(_ name: String) -> Bool {
        name.caseInsensitiveCompare("Cookie") == .orderedSame
    }

    static func cookieHeaderValue(_ headers: [String: String]?) -> String? {
        guard let headers else { return nil }
        return headers.first { isCookieHeader($0.key) }?.value
    }

    /// A `Cookie:` header rendered as a Netscape cookie jar scoped to `pageURL`'s
    /// domain, or nil when there's nothing usable to write.
    ///
    /// Fields are tab-separated: domain, include_subdomains, path, secure, expiry,
    /// name, value. `www.` is stripped and a leading dot added so one entry covers
    /// both the bare host and its subdomains — but *not* `googlevideo.com`, which
    /// is the entire point.
    static func netscapeCookieJar(cookieHeader: String, pageURL: URL) -> String? {
        guard let host = pageURL.host, !host.isEmpty else { return nil }
        let domain = "." + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)

        var rows: [String] = []
        for pair in cookieHeader.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            // Split on the *first* `=` only: session tokens are base64 and
            // routinely end in padding, which a greedy split would truncate.
            guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { continue }
            let name = String(trimmed[trimmed.startIndex..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard !name.isEmpty else { continue }
            // Expiry 0 marks a session cookie, which is what a live browser
            // handoff always is.
            rows.append("\(domain)\tTRUE\t/\tTRUE\t0\t\(name)\t\(value)")
        }
        guard !rows.isEmpty else { return nil }
        return (["# Netscape HTTP Cookie File"] + rows).joined(separator: "\n") + "\n"
    }

    /// Writes the jar to a private temp directory and returns `--cookies <path>`
    /// plus the directory to delete once yt-dlp exits.
    ///
    /// The file holds a live session, so it is created `0600` inside a
    /// per-invocation directory and removed by the caller's `defer`. This is the
    /// one place cookies touch disk; nothing persists them.
    private func cookieArgs(_ headers: [String: String]?, pageURL: URL) -> (args: [String], cleanup: URL?) {
        guard let cookie = Self.cookieHeaderValue(headers),
              let jar = Self.netscapeCookieJar(cookieHeader: cookie, pageURL: pageURL)
        else { return ([], nil) }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macget-cookies-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("cookies.txt")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try jar.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // Better to download anonymously than to fail outright — and better
            // than falling back to the header, which is what 403s.
            Log.engine.error("Could not write cookie jar: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: dir)
            return ([], nil)
        }
        return (["--cookies", file.path], dir)
    }

    /// Runs yt-dlp, streaming **both** stdout and stderr lines to `onLine` and
    /// collecting full stdout/stderr. Returns the exit status. yt-dlp writes its
    /// `--progress-template` output to stderr and the `--print` path to stdout, so
    /// progress parsing must see both streams. The stream ends when both pipes EOF.
    private func execute(
        arguments: [String],
        onLine: (@Sendable (String) async -> Void)?
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = tools.ytDlp
        proc.arguments = arguments
        // Inherit our environment but force unbuffered Python output so progress
        // lines stream in real time rather than buffering until the process exits.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.process = proc

        let stdoutAll = DataBox()
        let stderrAll = DataBox()

        let lines = AsyncStream<String> { continuation in
            // Both pipe handlers fire on background queues; finish the merged
            // stream only once both have hit EOF.
            let openPipes = Counter(2)

            func makeHandler(collect: DataBox, pending: DataBox) -> @Sendable (FileHandle) -> Void {
                return { h in
                    let d = h.availableData
                    if d.isEmpty {
                        if let rest = pending.takeRemainderString() { continuation.yield(rest) }
                        h.readabilityHandler = nil
                        if openPipes.decrement() == 0 { continuation.finish() }
                        return
                    }
                    collect.append(d)
                    pending.append(d)
                    for line in pending.takeLines() { continuation.yield(line) }
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = makeHandler(collect: stdoutAll, pending: DataBox())
            errPipe.fileHandleForReading.readabilityHandler = makeHandler(collect: stderrAll, pending: DataBox())
        }

        Log.engine.info("yt-dlp launching \(proc.executableURL?.path ?? "nil", privacy: .public)")
        Log.engine.info("yt-dlp argv: \(Self.redactedArgv(arguments), privacy: .public)")
        try proc.run()

        for await line in lines {
            await onLine?(line)
        }
        proc.waitUntilExit()          // both pipes closed → process is exiting
        self.process = nil

        let stdout = String(data: stdoutAll.takeAll(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrAll.takeAll(), encoding: .utf8) ?? ""
        Log.engine.info("yt-dlp exited status=\(proc.terminationStatus) stderrTail=\(Self.tail(stderr, lines: 5), privacy: .public)")
        if proc.terminationStatus != 0 {
            // The 5-line tail hides the warnings that precede a failure, and those
            // are usually what explains it. Progress lines are dropped so the
            // diagnostic ones aren't buried.
            let meaningful = stderr.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix(Self.progressPrefix) && !$0.hasPrefix("[download]") }
            Log.engine.error("yt-dlp full stderr (\(meaningful.count) lines):\n\(meaningful.joined(separator: "\n"), privacy: .public)")
        }
        return (proc.terminationStatus, stdout, stderr)
    }

    // MARK: - Parsing (pure / testable)

    static func parseProgress(_ line: String) -> ProgressUpdate? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let payload = String(line.dropFirst(progressPrefix.count))
        let parts = payload.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else { return nil }
        func num(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return (t == "NA" || t.isEmpty || t == "None") ? nil : Double(t)
        }
        let downloaded = Int64(num(parts[0]) ?? 0)
        let total = num(parts[1]).map { Int64($0) } ?? num(parts[2]).map { Int64($0) }
        return ProgressUpdate(downloaded: downloaded, total: total, speed: num(parts[3]), eta: num(parts[4]))
    }

    /// Detects the post-download ffmpeg phase from yt-dlp's postprocessor banners
    /// (e.g. `[Merger] Merging formats into ...`). These lines carry no byte
    /// progress, so the UI shows an indeterminate "Merging…" state instead of a
    /// frozen-looking bar.
    static func detectPhase(_ line: String) -> MediaPhase? {
        if line.contains("[Merger]") || line.contains("Merging formats")
            || line.contains("[ExtractAudio]") || line.contains("[VideoConvertor]")
            || line.contains("[VideoRemuxer]") {
            return .merging
        }
        return nil
    }

    /// The last absolute-path line in stdout (yt-dlp's `--print after_move:filepath`),
    /// ignoring progress lines.
    static func outputPath(fromStdout stdout: String) -> String? {
        stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && !$0.hasPrefix(progressPrefix) }
            .last
    }

    /// The argv as launched, with any credential values replaced by their shape.
    /// Diagnostic only — enough to replay the invocation by hand without ever
    /// putting a live session token in the log.
    static func redactedArgv(_ arguments: [String]) -> String {
        var out: [String] = []
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a == "--add-header", i + 1 < arguments.count {
                let h = arguments[i + 1]
                let name = h.split(separator: ":", maxSplits: 1).first.map(String.init) ?? h
                out += [a, isCookieHeader(name) ? "\(name): <\(h.count) chars REDACTED>" : h]
                i += 2
            } else if a == "--cookies", i + 1 < arguments.count {
                let path = arguments[i + 1]
                let jar = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                let names = jar.split(separator: "\n")
                    .filter { !$0.hasPrefix("#") }
                    .compactMap { $0.split(separator: "\t").dropLast().last.map(String.init) }
                out += [a, "<jar: \(names.count) cookies [\(names.joined(separator: ","))]>"]
                i += 2
            } else {
                out.append(a)
                i += 1
            }
        }
        return out.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// Last few non-empty stderr lines, for surfacing a useful failure reason.
    static func tail(_ stderr: String, lines: Int = 3) -> String {
        stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: " ")
    }
}

/// Thread-safe byte accumulator for pipe `readabilityHandler`s, which fire on a
/// background queue.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }

    func takeAll() -> Data {
        lock.lock(); defer { lock.unlock() }
        let copy = data
        data.removeAll(keepingCapacity: false)
        return copy
    }

    /// Extract complete lines, leaving any partial remainder. Treats both `\n`
    /// (LF) and `\r` (CR) as terminators: yt-dlp's progress updates can arrive
    /// carriage-return-terminated depending on launch context, and a LF-only
    /// splitter would never surface them as lines (they'd accumulate until EOF).
    /// Empty tokens (e.g. the gap in a `\r\n` pair) are skipped.
    func takeLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        while let idx = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data[data.startIndex..<idx]
            if !lineData.isEmpty, let s = String(data: lineData, encoding: .utf8) { out.append(s) }
            data.removeSubrange(data.startIndex...idx)
        }
        return out
    }

    func takeRemainderString() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let s = String(data: data, encoding: .utf8)
        data.removeAll(keepingCapacity: false)
        return s.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Thread-safe countdown used to coordinate two pipe `readabilityHandler`s, which
/// fire on background queues. `decrement()` returns the new value.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func decrement() -> Int {
        lock.lock(); defer { lock.unlock() }
        value -= 1
        return value
    }
}
