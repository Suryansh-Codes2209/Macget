import Foundation

/// Builds a human-readable diagnostics report for a download: per-chunk progress,
/// attempt counts, last errors, and the live concurrency state (effective worker
/// count, learned host cap, demotion, adaptive ceiling). Surfaced via the list's
/// "Copy Diagnostics" action so server-specific failures are debuggable without
/// attaching a debugger — and so the adaptive concurrency decisions are visible.
enum DownloadDiagnostics {
    static func report(
        for d: Download,
        activeWorkers: Int? = nil,
        effectiveThreads: Int? = nil,
        demotedTo: Int? = nil,
        perHostCap: Int? = nil,
        adaptiveCeiling: Int? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("Macget download diagnostics")
        lines.append("File: \(d.filename)")
        lines.append("URL: \(d.url.absoluteString)")
        lines.append("Status: \(d.status)")
        if let total = d.totalBytes {
            lines.append("Size: \(d.bytesDownloaded) / \(total) bytes (\(percent(d.fractionComplete)))")
        } else {
            lines.append("Size: \(d.bytesDownloaded) bytes (total unknown)")
        }
        lines.append("Supports range: \(d.supportsRange)")
        lines.append("Threads (user-requested): \(d.threadCount)")
        if let effectiveThreads { lines.append("Threads (effective now): \(effectiveThreads)") }
        if let activeWorkers { lines.append("Active workers: \(activeWorkers)") }
        if let adaptiveCeiling { lines.append("Adaptive ceiling: \(adaptiveCeiling)") }
        if let perHostCap { lines.append("Learned host cap: \(perHostCap)") }
        if let demotedTo { lines.append("Demoted (anti-leech) to: \(demotedTo)") }
        if let etag = d.etag { lines.append("ETag: \(etag)") }
        if let lm = d.lastModified { lines.append("Last-Modified: \(lm)") }
        if let cs = d.expectedChecksum, let alg = d.checksumAlgorithm {
            lines.append("Expected checksum (\(alg.rawValue)): \(cs)")
        }
        if let err = d.error { lines.append("Error: \(err)") }

        lines.append("")
        lines.append("Chunks: \(d.chunks.count)")
        for (i, c) in d.chunks.enumerated() {
            var line = "  #\(i) [\(c.startByte)…\(c.endByte)] \(c.bytesWritten)/\(c.totalBytes)B attempts=\(c.attempts)"
            if c.isComplete { line += " ✓" }
            if let e = c.lastError { line += " lastError=\(e)" }
            lines.append(line)
        }

        let totalAttempts = d.chunks.reduce(0) { $0 + $1.attempts }
        let chunksWithErrors = d.chunks.filter { $0.lastError != nil }.count
        lines.append("")
        lines.append("Totals: \(totalAttempts) chunk-attempts, \(chunksWithErrors) chunk(s) with a recorded error.")
        return lines.joined(separator: "\n")
    }

    private static func percent(_ f: Double) -> String {
        String(format: "%.1f%%", f * 100)
    }
}
