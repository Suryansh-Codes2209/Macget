import Foundation
import OSLog

/// Watches Macget's inbox directory for capture files dropped by the
/// native-messaging host (`MacgetCaptureHost`). Each file is a JSON
/// `CaptureRequest`. On appearance we decode, hand it to `onCapture`, and delete
/// the file. A drop directory (rather than a socket) means capture still works
/// when the app wasn't running — files written meanwhile are picked up by the
/// launch scan.
@MainActor
final class CaptureInbox {
    /// Fired for each successfully decoded capture file.
    var onCapture: ((CaptureRequest) -> Void)?

    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var enabled = false
    private let log = Logger(subsystem: "com.macget", category: "CaptureInbox")

    /// The shared inbox path. Must match `MacgetCaptureHost`'s computation.
    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Macget", isDirectory: true)
            .appendingPathComponent("incoming", isDirectory: true)
    }

    init(directory: URL = CaptureInbox.defaultDirectory) {
        self.directory = directory
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scan()   // catch anything dropped while we were not watching / not running

        dirFD = open(directory.path, O_EVTONLY)
        guard dirFD >= 0 else {
            log.error("Could not open inbox directory for watching: \(self.directory.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .main
        )
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        source = src
        src.resume()
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    /// Process every *.json in the directory once.
    private func scan() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "json" {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                let request = try JSONDecoder().decode(CaptureRequest.self, from: data)
                onCapture?(request)
            } catch {
                log.error("Discarding malformed capture file \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
