import Foundation

/// One file inside a multi-file torrent, so the user can choose what to fetch.
/// `index` is aria2's 1-based file index, which is what `--select-file` wants.
struct TorrentFileEntry: Codable, Sendable, Equatable, Identifiable {
    var index: Int
    var path: String
    var length: Int64
    var selected: Bool

    var id: Int { index }

    /// Last path component, for display in the file picker.
    var displayName: String {
        (path as NSString).lastPathComponent
    }
}

struct Chunk: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let startByte: Int64
    var endByte: Int64          // inclusive — mutable so dynamic threading can shrink an in-flight chunk
    var bytesWritten: Int64
    var attempts: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        startByte: Int64,
        endByte: Int64,
        bytesWritten: Int64 = 0,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.startByte = startByte
        self.endByte = endByte
        self.bytesWritten = bytesWritten
        self.attempts = attempts
        self.lastError = lastError
    }

    var totalBytes: Int64 {
        endByte - startByte + 1
    }

    var remainingBytes: Int64 {
        max(0, totalBytes - bytesWritten)
    }

    var isComplete: Bool {
        bytesWritten >= totalBytes
    }

    /// Absolute file offset where the next byte should be written.
    var nextWriteOffset: Int64 {
        startByte + bytesWritten
    }
}
