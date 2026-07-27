import Foundation

// MacgetCaptureHost — a Native Messaging host.
//
// Browsers (Chrome/Edge/Brave/Firefox) launch this executable and speak the
// Native Messaging protocol over stdio: a 4-byte little-endian length prefix
// followed by that many bytes of UTF-8 JSON. We read exactly one message, drop
// it as a file into Macget's inbox directory, make sure Macget is running so it
// picks the file up, write a small ack to stdout, and exit.
//
// Handoff is via a drop directory rather than a socket so capture still works
// when Macget isn't running yet — the file simply waits and is ingested on the
// app's next launch.

let appBundleID = "com.suryansh.Macget"

func inboxDirectory() -> URL {
    let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Macget", isDirectory: true)
        .appendingPathComponent("incoming", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Read exactly `count` bytes from stdin, or nil on EOF/short read.
func readExactly(_ count: Int) -> Data? {
    var buffer = Data()
    let stdin = FileHandle.standardInput
    while buffer.count < count {
        let chunk = stdin.readData(ofLength: count - buffer.count)
        if chunk.isEmpty { return nil }   // EOF
        buffer.append(chunk)
    }
    return buffer
}

func readMessage() -> Data? {
    guard let header = readExactly(4) else { return nil }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }   // little-endian on Apple silicon/Intel
    guard length > 0, length <= 16 * 1024 * 1024 else { return nil }   // sanity cap: 16 MB
    return readExactly(Int(length))
}

func writeAck(ok: Bool) {
    let payload = try? JSONSerialization.data(withJSONObject: ["ok": ok])
    guard let payload else { return }
    var length = UInt32(payload.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(payload)
}

/// Ensure Macget is running so it ingests the dropped file promptly. `open -g`
/// is idempotent — launching an already-running app just no-ops without
/// foregrounding it. Avoids linking AppKit just to check the running set.
func launchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "-b", appBundleID]
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            logError("`open -g -b \(appBundleID)` exited with status \(task.terminationStatus); "
                + "Macget may not be registered with LaunchServices yet. The dropped file "
                + "will be ingested on the next manual launch.")
        }
    } catch {
        logError("Could not run /usr/bin/open to launch Macget: \(error). The dropped file "
            + "will be ingested on the next manual launch.")
    }
}

/// Log to stderr — surfaced in Console.app and captured by the browser when it
/// spawns the host, so cold-launch failures are diagnosable instead of silent.
func logError(_ message: String) {
    FileHandle.standardError.write(Data("MacgetCaptureHost: \(message)\n".utf8))
}

// MARK: - main

guard let message = readMessage() else {
    writeAck(ok: false)
    exit(1)
}

let dir = inboxDirectory()
let fileURL = dir.appendingPathComponent("\(UUID().uuidString).json")
do {
    try message.write(to: fileURL, options: .atomic)
    launchApp()
    writeAck(ok: true)
    exit(0)
} catch {
    writeAck(ok: false)
    exit(1)
}
