import Foundation
import Network
import OSLog

/// `PinnedTransport` over Network.framework: `NWConnection` with
/// `requiredInterface`, TLS from the system trust store, HTTP/1.1 keep-alive.
final class NWPinnedTransport: PinnedTransport, @unchecked Sendable {
    static let shared = NWPinnedTransport()

    private let pool = PinnedConnectionPool()
    private let queue = DispatchQueue(label: "com.macget.pinned-transport", attributes: .concurrent)
    private let interfaceLookup: @Sendable (String) async -> NWInterface?

    init(interfaceLookup: @escaping @Sendable (String) async -> NWInterface? = { NetworkLinkMonitor.shared.interface(for: $0) }) {
        self.interfaceLookup = interfaceLookup
    }

    func get(url: URL, headers: [(String, String)], linkID: String) async throws -> PinnedResponse {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false),
              let request = PinnedRequest.bytes(url: url, headers: headers)
        else { throw PinnedTransportError.unsupportedURL }
        guard let iface = await interfaceLookup(linkID) else {
            throw PinnedTransportError.interfaceUnavailable(linkID)
        }
        let key = PinnedConnectionPool.Key(linkID: linkID, host: host,
                                           port: url.port ?? (scheme == "https" ? 443 : 80),
                                           tls: scheme == "https")

        // A pooled connection may have been closed by the server while idle;
        // that only shows up when we use it, so fall back to a fresh one once.
        if let reused = await pool.checkout(key) {
            do {
                return try await exchange(reused, request: request, key: key)
            } catch is CancellationError {
                reused.cancel()
                throw CancellationError()
            } catch {
                reused.cancel()
            }
        }
        let fresh = try await connect(key: key, interface: iface)
        return try await exchange(fresh, request: request, key: key)
    }

    private func connect(key: PinnedConnectionPool.Key, interface: NWInterface) async throws -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.noDelay = true
        let params: NWParameters
        if key.tls {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, key.host)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.requiredInterface = interface
        params.preferNoProxies = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(key.port)) else { throw PinnedTransportError.unsupportedURL }
        let connection = NWConnection(host: NWEndpoint.Host(key.host), port: port, using: params)
        try await connection.startAndWaitReady(queue: queue)
        return connection
    }

    /// Sends the request and reads until the response head arrives. The rest of
    /// the body is pumped by a task that feeds the returned stream.
    private func exchange(_ connection: NWConnection, request: Data, key: PinnedConnectionPool.Key) async throws -> PinnedResponse {
        try await connection.sendAsync(request)

        var parser = HTTPResponseParser()
        var head: HTTPResponseHead?
        var early: [Data] = []
        var peerClosed = false
        while head == nil {
            let (data, isComplete) = try await connection.receiveChunk()
            var events = try data.map { try parser.feed($0) } ?? []
            if isComplete {
                peerClosed = true
                events += try parser.finish()
            }
            for event in events {
                switch event {
                case .head(let h): head = h
                case .body(let d): early.append(d)
                case .end: break
                }
            }
            if isComplete && head == nil { throw PinnedTransportError.closedBeforeResponse }
        }

        let finalHead = head!
        let reusable = !peerClosed && finalHead.value("connection")?.lowercased() != "close"
        let pool = self.pool
        let startParser = parser

        let body = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in early { continuation.yield(chunk) }
            if startParser.isComplete {
                Task {
                    if reusable {
                        await pool.checkin(connection, key: key)
                    } else {
                        connection.cancel()
                    }
                }
                continuation.finish()
                return
            }
            let pump = Task {
                var parser = startParser
                do {
                    while true {
                        let (data, isComplete) = try await connection.receiveChunk()
                        var events = try data.map { try parser.feed($0) } ?? []
                        if isComplete { events += try parser.finish() }
                        for case .body(let d) in events { continuation.yield(d) }
                        if parser.isComplete {
                            if reusable && !isComplete {
                                await pool.checkin(connection, key: key)
                            } else {
                                connection.cancel()
                            }
                            continuation.finish()
                            return
                        }
                    }
                } catch {
                    connection.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    pump.cancel()
                    connection.cancel()
                }
            }
        }
        return PinnedResponse(head: finalHead, body: body)
    }
}

/// Idle keep-alive connections per (link, host, port, scheme), so stealing the
/// next piece doesn't cost another TLS handshake over a slow tethered link.
actor PinnedConnectionPool {
    struct Key: Hashable, Sendable {
        let linkID: String
        let host: String
        let port: Int
        let tls: Bool
    }

    static let maxIdlePerKey = 16
    private var idle: [Key: [NWConnection]] = [:]

    func checkout(_ key: Key) -> NWConnection? {
        var list = idle[key] ?? []
        defer { idle[key] = list.isEmpty ? nil : list }
        while let connection = list.popLast() {
            if case .ready = connection.state { return connection }
            connection.cancel()
        }
        return nil
    }

    func checkin(_ connection: NWConnection, key: Key) {
        guard case .ready = connection.state else { connection.cancel(); return }
        var list = idle[key] ?? []
        guard list.count < Self.maxIdlePerKey else { connection.cancel(); return }
        list.append(connection)
        idle[key] = list
    }
}

/// Resumes a continuation at most once — `NWConnection.stateUpdateHandler` keeps
/// firing after the state we were waiting for.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

extension NWConnection {
    func startAndWaitReady(queue: DispatchQueue) async throws {
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        // `.waiting` means no route on this interface right now.
                        // For a pinned link that's a failure, not something to wait out.
                        self?.cancel()
                        once.run { continuation.resume(throwing: Self.map(error)) }
                    case .cancelled:
                        once.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                start(queue: queue)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            })
        }
    }

    /// One read of up to 64 KB. `isComplete` means the peer closed its side.
    func receiveChunk(maximumLength: Int = 64 * 1024) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    fileprivate static func map(_ error: NWError) -> PinnedTransportError {
        if case .tls = error { return .tlsFailed(error.debugDescription) }
        return .connectionFailed(error.debugDescription)
    }
}
