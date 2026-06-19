import Foundation
import OSLog

/// Downloads optional media tools on demand into the writable Application Support
/// bin dir (which `MediaToolLocator` searches first). Used for Deno — the JS
/// runtime yt-dlp needs to solve YouTube's challenges — which is too large
/// (~130MB) to bundle in the DMG, so it's fetched the first time it's needed.
actor MediaToolInstaller {
    static let shared = MediaToolInstaller()

    private var inFlight: Task<URL, Error>?
    private let log = Logger(subsystem: "com.macget", category: "MediaToolInstaller")

    enum InstallError: Error, LocalizedError {
        case downloadFailed(Int)
        case unzipFailed(Int32)
        case binaryMissing

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let code): return "Deno download failed (HTTP \(code))."
            case .unzipFailed(let code):    return "Could not unzip Deno (exit \(code))."
            case .binaryMissing:            return "Deno archive did not contain the expected binary."
            }
        }
    }

    /// Returns the path to a runnable Deno, downloading it once if needed.
    /// Concurrent callers share a single in-flight download.
    func ensureDeno() async throws -> URL {
        let dest = MediaToolLocator.appSupportBinDirectory.appendingPathComponent("deno")
        if FileManager.default.isExecutableFile(atPath: dest.path) { return dest }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await Self.install(to: dest) }
        inFlight = task
        defer { inFlight = nil }
        let url = try await task.value
        log.info("Deno installed at \(url.path)")
        return url
    }

    /// Deno's macOS release asset for the *running* architecture. In a universal
    /// app the executing slice picks the right one at runtime.
    private static var assetName: String {
        #if arch(arm64)
        return "deno-aarch64-apple-darwin.zip"
        #else
        return "deno-x86_64-apple-darwin.zip"
        #endif
    }

    private static func install(to dest: URL) async throws -> URL {
        let url = URL(string: "https://github.com/denoland/deno/releases/latest/download/\(assetName)")!
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Download the zip (follows GitHub's redirect to the asset host).
        let (tmpZip, response) = try await URLSessionFactory.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.downloadFailed(http.statusCode)
        }

        // Unzip into a scratch dir, then move the single `deno` binary into place.
        let work = fm.temporaryDirectory.appendingPathComponent("macget-deno-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", tmpZip.path, "-d", work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw InstallError.unzipFailed(unzip.terminationStatus) }

        let extracted = work.appendingPathComponent("deno")
        guard fm.isReadableFile(atPath: extracted.path) else { throw InstallError.binaryMissing }

        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.moveItem(at: extracted, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // Deno's release is notarized; clearing quarantine avoids a Gatekeeper prompt
        // when we exec it via Process.
        stripQuarantine(dest)
        return dest
    }

    private static func stripQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
