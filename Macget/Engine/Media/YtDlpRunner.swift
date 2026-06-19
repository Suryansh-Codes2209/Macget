import Foundation

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
        args += headerArgs(headers)
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

    // MARK: - Download

    /// Download `pageURL` at `formatSelector` into `destinationFolder`, muxing with
    /// ffmpeg when needed. Returns the final on-disk file URL.
    func download(
        pageURL: URL,
        formatSelector: String,
        destinationFolder: URL,
        headers: [String: String]?,
        onProgress: @Sendable @escaping (ProgressUpdate) async -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        var args = [
            "--no-config", "--no-playlist", "--newline", "--no-simulate",
            "--restrict-filenames",
            "--progress-template",
            "\(Self.progressPrefix)%(progress.downloaded_bytes)s/%(progress.total_bytes)s/%(progress.total_bytes_estimate)s/%(progress.speed)s/%(progress.eta)s",
            "--print", "after_move:filepath",
            "-f", formatSelector,
            "-o", destinationFolder.appendingPathComponent("%(title)s.%(ext)s").path,
        ]
        if let ffmpegDir = tools.ffmpegDir {
            args += ["--ffmpeg-location", ffmpegDir.path]
        }
        args += jsRuntimeArgs()
        args += headerArgs(headers)
        args.append(pageURL.absoluteString)

        let (status, stdout, stderr) = try await execute(arguments: args) { line in
            if let p = Self.parseProgress(line) {
                await onProgress(p)
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

    private func headerArgs(_ headers: [String: String]?) -> [String] {
        guard let headers else { return [] }
        var args: [String] = []
        for (k, v) in headers where !v.isEmpty {
            args += ["--add-header", "\(k): \(v)"]
        }
        return args
    }

    /// Runs yt-dlp, streaming stdout lines to `onLine` and collecting full
    /// stdout/stderr. Returns the exit status. The stdout EOF marks process end.
    private func execute(
        arguments: [String],
        onLine: (@Sendable (String) async -> Void)?
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = tools.ytDlp
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.process = proc

        let stdoutAll = DataBox()
        let stderrBox = DataBox()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { stderrBox.append(d) }
        }

        let lines = AsyncStream<String> { continuation in
            let pending = DataBox()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    if let rest = pending.takeRemainderString() { continuation.yield(rest) }
                    continuation.finish()
                    h.readabilityHandler = nil
                    return
                }
                stdoutAll.append(d)
                pending.append(d)
                for line in pending.takeLines() { continuation.yield(line) }
            }
        }

        try proc.run()

        for await line in lines {
            await onLine?(line)
        }
        proc.waitUntilExit()          // stdout closed → process is exiting
        self.process = nil

        let stdout = String(data: stdoutAll.takeAll(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.takeAll(), encoding: .utf8) ?? ""
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

    /// The last absolute-path line in stdout (yt-dlp's `--print after_move:filepath`),
    /// ignoring progress lines.
    static func outputPath(fromStdout stdout: String) -> String? {
        stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && !$0.hasPrefix(progressPrefix) }
            .last
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

    /// Extract complete `\n`-terminated lines, leaving any partial remainder.
    func takeLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<nl]
            if let s = String(data: lineData, encoding: .utf8) { out.append(s) }
            data.removeSubrange(data.startIndex...nl)
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
