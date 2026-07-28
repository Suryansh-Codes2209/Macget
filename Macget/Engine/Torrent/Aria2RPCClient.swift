import Foundation
import OSLog

enum Aria2Error: Error, LocalizedError, Equatable {
    case transport(String)
    case rpc(code: Int, message: String)
    case malformedResponse(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .transport(let detail):     return "Could not reach the torrent engine: \(detail)"
        case .rpc(let code, let message): return "Torrent engine error \(code): \(message)"
        case .malformedResponse(let d):  return "Unexpected reply from the torrent engine: \(d)"
        case .notRunning:                return "The torrent engine isn't running."
        }
    }
}

/// One torrent's live state, as reported by `aria2.tellStatus`.
struct Aria2Status: Sendable, Equatable {
    /// aria2's own GID for the download (not MacGet's UUID).
    var gid: String
    /// `active` | `waiting` | `paused` | `error` | `complete` | `removed`
    var status: String
    var totalLength: Int64
    var completedLength: Int64
    var uploadLength: Int64
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var connections: Int
    var numSeeders: Int?
    var infoHash: String?
    /// Torrent name from the metadata, once BEP-9 has resolved it.
    var name: String?
    var errorMessage: String?
    var files: [Aria2File]
    /// aria2 spawns a *separate* GID for the real download once a magnet's
    /// metadata arrives; this points at it.
    var followedBy: [String]

    var isComplete: Bool { status == "complete" }
    var isPaused: Bool { status == "paused" }
    var isError: Bool { status == "error" }
    var isRemoved: Bool { status == "removed" }

    /// Share ratio, or nil before anything has been downloaded.
    var ratio: Double? {
        guard completedLength > 0 else { return nil }
        return Double(uploadLength) / Double(completedLength)
    }
}

struct Aria2File: Sendable, Equatable {
    var index: Int
    var path: String
    var length: Int64
    var completedLength: Int64
    var selected: Bool
}

/// JSON-RPC client for a local `aria2c --enable-rpc` daemon.
///
/// Talks HTTP POST to `127.0.0.1` only. The secret token is passed as aria2
/// requires — a leading `token:<secret>` element in the params array — and the
/// daemon is started with `--rpc-listen-all=false`, so nothing off-machine can
/// reach it.
actor Aria2RPCClient {
    private let endpoint: URL
    private let secret: String
    private let session: URLSession
    private let log = Logger(subsystem: "com.macget", category: "Aria2RPC")
    private var nextID = 0

    init(port: Int, secret: String, session: URLSession = URLSessionFactory.metadata) {
        self.endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
        self.secret = secret
        self.session = session
    }

    /// Test seam: point the client at an arbitrary endpoint.
    init(endpoint: URL, secret: String, session: URLSession) {
        self.endpoint = endpoint
        self.secret = secret
        self.session = session
    }

    // MARK: - Commands

    /// Add a magnet link (or any URI aria2 understands). Returns the GID.
    @discardableResult
    func addURI(_ uri: String, options: [String: String] = [:]) async throws -> String {
        let params: [Any] = [[uri], options]
        return try await callString("aria2.addUri", params: params)
    }

    /// Add a `.torrent` file. Returns the GID.
    @discardableResult
    func addTorrent(_ data: Data, options: [String: String] = [:]) async throws -> String {
        // aria2 wants the torrent as base64, with an (empty) webseed array between
        // it and the options.
        let params: [Any] = [data.base64EncodedString(), [], options]
        return try await callString("aria2.addTorrent", params: params)
    }

    func tellStatus(gid: String) async throws -> Aria2Status {
        let value = try await call("aria2.tellStatus", params: [gid])
        guard let dict = value as? [String: Any] else {
            throw Aria2Error.malformedResponse("tellStatus did not return an object")
        }
        return Self.parseStatus(dict)
    }

    @discardableResult
    func pause(gid: String) async throws -> String {
        try await callString("aria2.pause", params: [gid])
    }

    @discardableResult
    func unpause(gid: String) async throws -> String {
        try await callString("aria2.unpause", params: [gid])
    }

    /// Stop and forget a download. `forceRemove` doesn't wait for a clean
    /// announce, which is what cancel should do.
    @discardableResult
    func forceRemove(gid: String) async throws -> String {
        try await callString("aria2.forceRemove", params: [gid])
    }

    /// Drop a finished/errored download from aria2's result list so its GID stops
    /// showing up in `tellStopped`.
    func removeDownloadResult(gid: String) async throws {
        _ = try await call("aria2.removeDownloadResult", params: [gid])
    }

    func changeGlobalOption(_ options: [String: String]) async throws {
        _ = try await call("aria2.changeGlobalOption", params: [options])
    }

    func changeOption(gid: String, options: [String: String]) async throws {
        _ = try await call("aria2.changeOption", params: [gid, options])
    }

    func shutdown() async throws {
        _ = try await call("aria2.shutdown", params: [])
    }

    /// Cheap liveness probe used while waiting for the daemon to come up.
    func ping() async throws {
        _ = try await call("aria2.getVersion", params: [])
    }

    // MARK: - Transport

    private func callString(_ method: String, params: [Any]) async throws -> String {
        let value = try await call(method, params: params)
        guard let gid = value as? String else {
            throw Aria2Error.malformedResponse("\(method) did not return a GID")
        }
        return gid
    }

    private func call(_ method: String, params: [Any]) async throws -> Any {
        nextID += 1
        // The secret is always the first parameter — aria2's documented scheme.
        var allParams: [Any] = ["token:\(secret)"]
        allParams.append(contentsOf: params)

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "macget-\(nextID)",
            "method": method,
            "params": allParams,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw Aria2Error.transport(error.localizedDescription)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Aria2Error.malformedResponse("not a JSON object")
        }
        if let error = object["error"] as? [String: Any] {
            throw Aria2Error.rpc(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "unknown"
            )
        }
        guard let result = object["result"] else {
            throw Aria2Error.malformedResponse("no result field")
        }
        return result
    }

    // MARK: - Parsing

    /// aria2 returns every numeric field as a decimal *string*.
    static func parseStatus(_ dict: [String: Any]) -> Aria2Status {
        func int64(_ key: String) -> Int64 {
            Int64((dict[key] as? String) ?? "") ?? 0
        }
        let bittorrent = dict["bittorrent"] as? [String: Any]
        let info = bittorrent?["info"] as? [String: Any]

        let files: [Aria2File] = (dict["files"] as? [[String: Any]] ?? []).map { file in
            Aria2File(
                index: Int((file["index"] as? String) ?? "") ?? 0,
                path: (file["path"] as? String) ?? "",
                length: Int64((file["length"] as? String) ?? "") ?? 0,
                completedLength: Int64((file["completedLength"] as? String) ?? "") ?? 0,
                // aria2 encodes booleans as "true"/"false" strings here too.
                selected: ((file["selected"] as? String) ?? "true") == "true"
            )
        }

        return Aria2Status(
            gid: (dict["gid"] as? String) ?? "",
            status: (dict["status"] as? String) ?? "",
            totalLength: int64("totalLength"),
            completedLength: int64("completedLength"),
            uploadLength: int64("uploadLength"),
            downloadSpeed: int64("downloadSpeed"),
            uploadSpeed: int64("uploadSpeed"),
            connections: Int((dict["connections"] as? String) ?? "") ?? 0,
            numSeeders: (dict["numSeeders"] as? String).flatMap(Int.init),
            infoHash: bittorrent?["infoHash"] as? String ?? dict["infoHash"] as? String,
            name: info?["name"] as? String,
            errorMessage: dict["errorMessage"] as? String,
            files: files,
            followedBy: (dict["followedBy"] as? [String]) ?? []
        )
    }
}
