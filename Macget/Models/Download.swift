import Foundation

struct Download: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var url: URL
    var destinationFolder: URL
    var filename: String
    var totalBytes: Int64?              // nil until HEAD probe completes
    var status: DownloadStatus
    var error: String?
    var threadCount: Int                // 1...maxThreadCount

    static let maxThreadCount = 16
    var etag: String?
    var lastModified: String?
    var supportsRange: Bool
    var chunks: [Chunk]
    let createdAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        url: URL,
        destinationFolder: URL,
        filename: String,
        totalBytes: Int64? = nil,
        status: DownloadStatus = .queued,
        error: String? = nil,
        threadCount: Int = 8,
        etag: String? = nil,
        lastModified: String? = nil,
        supportsRange: Bool = false,
        chunks: [Chunk] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.destinationFolder = destinationFolder
        self.filename = filename
        self.totalBytes = totalBytes
        self.status = status
        self.error = error
        self.threadCount = max(1, min(Self.maxThreadCount, threadCount))
        self.etag = etag
        self.lastModified = lastModified
        self.supportsRange = supportsRange
        self.chunks = chunks
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    var bytesDownloaded: Int64 {
        chunks.reduce(0) { $0 + $1.bytesWritten }
    }

    var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(total))
    }

    /// Final on-disk path once completed.
    var destinationURL: URL {
        destinationFolder.appendingPathComponent(filename)
    }

    /// In-flight partial file path (sparse, preallocated). Hidden via leading dot.
    var partialFileURL: URL {
        destinationFolder.appendingPathComponent(".\(filename).macget-partial")
    }
}
