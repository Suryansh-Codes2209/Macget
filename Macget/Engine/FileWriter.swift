import Foundation

enum FileWriterError: Error, LocalizedError {
    case openFailed(String)
    case truncateFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s):     return "Could not open file: \(s)"
        case .truncateFailed(let s): return "Could not preallocate file: \(s)"
        case .writeFailed(let s):    return "Write failed: \(s)"
        }
    }
}

/// Serializes positional writes to a single underlying file. Wraps a
/// `FileHandle`. All workers go through this actor so concurrent seek+write
/// pairs are safe.
actor FileWriter {
    private let handle: FileHandle
    let url: URL
    let totalBytes: Int64

    init(url: URL, totalBytes: Int64) throws {
        self.url = url
        self.totalBytes = totalBytes

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw FileWriterError.openFailed(url.path)
            }
        }

        do {
            self.handle = try FileHandle(forWritingTo: url)
        } catch {
            throw FileWriterError.openFailed("\(error)")
        }

        // Preallocate by truncating to the full size. APFS keeps this sparse.
        if totalBytes > 0 {
            do {
                try handle.truncate(atOffset: UInt64(totalBytes))
            } catch {
                try? handle.close()
                throw FileWriterError.truncateFailed("\(error)")
            }
        }
    }

    func write(_ data: Data, at offset: Int64) throws {
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            throw FileWriterError.writeFailed("\(error)")
        }
    }

    func sync() throws {
        try handle.synchronize()
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    deinit {
        try? handle.close()
    }
}
