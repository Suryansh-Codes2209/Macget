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
    /// True when the user explicitly typed/chose the filename. When false, the
    /// coordinator may overwrite `filename` with the server's `Content-Disposition`
    /// name after probing. Defaulted for backward-compat with older queue.json.
    var userSpecifiedFilename: Bool

    static let maxThreadCount = 16
    var etag: String?
    var lastModified: String?
    var supportsRange: Bool
    var chunks: [Chunk]
    let createdAt: Date
    var completedAt: Date?
    /// Optional per-download request headers (Cookie / Referer / User-Agent) for
    /// downloads captured from a browser. Secret-bearing headers (Cookie /
    /// Authorization) are kept in memory for the active session but redacted on
    /// persistence — see `RequestHeaderPolicy.strippingSensitive`.
    var requestHeaders: [String: String]?

    init(
        id: UUID = UUID(),
        url: URL,
        destinationFolder: URL,
        filename: String,
        totalBytes: Int64? = nil,
        status: DownloadStatus = .queued,
        error: String? = nil,
        threadCount: Int = 8,
        userSpecifiedFilename: Bool = false,
        etag: String? = nil,
        lastModified: String? = nil,
        supportsRange: Bool = false,
        chunks: [Chunk] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        requestHeaders: [String: String]? = nil
    ) {
        self.id = id
        self.url = url
        self.destinationFolder = destinationFolder
        self.filename = filename
        self.totalBytes = totalBytes
        self.status = status
        self.error = error
        self.threadCount = max(1, min(Self.maxThreadCount, threadCount))
        self.userSpecifiedFilename = userSpecifiedFilename
        self.etag = etag
        self.lastModified = lastModified
        self.supportsRange = supportsRange
        self.chunks = chunks
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.requestHeaders = requestHeaders
    }

    // Explicit Codable so new fields can be added with `decodeIfPresent`
    // defaults — older queue.json files (which lack them) must still decode,
    // otherwise the whole queue is silently dropped on upgrade. Encodable stays
    // synthesized from these CodingKeys.
    private enum CodingKeys: String, CodingKey {
        case id, url, destinationFolder, filename, totalBytes, status, error
        case threadCount, userSpecifiedFilename, etag, lastModified, supportsRange
        case chunks, createdAt, completedAt, requestHeaders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        destinationFolder = try c.decode(URL.self, forKey: .destinationFolder)
        filename = try c.decode(String.self, forKey: .filename)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        status = try c.decode(DownloadStatus.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        threadCount = try c.decode(Int.self, forKey: .threadCount)
        userSpecifiedFilename = try c.decodeIfPresent(Bool.self, forKey: .userSpecifiedFilename) ?? false
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        supportsRange = try c.decode(Bool.self, forKey: .supportsRange)
        chunks = try c.decode([Chunk].self, forKey: .chunks)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        requestHeaders = try c.decodeIfPresent([String: String].self, forKey: .requestHeaders)
    }

    // Custom encode so secret-bearing headers (Cookie/Authorization) are redacted
    // before they ever touch queue.json. Everything else mirrors the synthesized form.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(destinationFolder, forKey: .destinationFolder)
        try c.encode(filename, forKey: .filename)
        try c.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(threadCount, forKey: .threadCount)
        try c.encode(userSpecifiedFilename, forKey: .userSpecifiedFilename)
        try c.encodeIfPresent(etag, forKey: .etag)
        try c.encodeIfPresent(lastModified, forKey: .lastModified)
        try c.encode(supportsRange, forKey: .supportsRange)
        try c.encode(chunks, forKey: .chunks)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(RequestHeaderPolicy.strippingSensitive(requestHeaders), forKey: .requestHeaders)
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
