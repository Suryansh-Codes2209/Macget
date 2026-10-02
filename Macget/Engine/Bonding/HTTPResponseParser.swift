import Foundation

/// A parsed status line and headers. Header names are stored lowercased.
struct HTTPResponseHead: Sendable, Equatable {
    let status: Int
    let headers: [String: String]

    init(status: Int, headers: [String: String]) {
        self.status = status
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
    }

    func value(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseEvent: Equatable {
    case head(HTTPResponseHead)
    case body(Data)
    case end
}

enum HTTPParseError: Error, Equatable {
    case malformedStatusLine
    case malformedHeader
    case malformedChunk
    case headerTooLarge
    case truncatedBody
}

/// Incremental HTTP/1.1 response parser for the pinned transport.
///
/// Pure and synchronous: it is fed whatever bytes the socket delivered, in
/// whatever packetization, and returns events. That keeps every framing branch —
/// `Content-Length`, chunked, close-delimited, interim 1xx — testable without a
/// socket.
struct HTTPResponseParser: Sendable {
    static let maxHeaderBytes = 64 * 1024
    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    private enum State: Sendable {
        case head
        case fixed(remaining: Int64)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers
        case untilClose
        case done
    }

    private var state: State = .head
    private var buffer = Data()
    private(set) var isComplete = false

    mutating func feed(_ data: Data) throws -> [HTTPParseEvent] {
        buffer.append(data)
        var events: [HTTPParseEvent] = []
        while true {
            switch state {
            case .head:
                guard let end = buffer.range(of: Self.headerEnd) else {
                    if buffer.count > Self.maxHeaderBytes { throw HTTPParseError.headerTooLarge }
                    return events
                }
                let head = try Self.parseHead(buffer[buffer.startIndex..<end.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                if (100..<200).contains(head.status) { continue }   // interim; the real head follows
                events.append(.head(head))
                if head.status == 204 || head.status == 304 {
                    markDone(&events)
                    return events
                }
                if head.value("transfer-encoding")?.lowercased().contains("chunked") == true {
                    state = .chunkSize
                } else if let raw = head.value("content-length"),
                          let length = Int64(raw.trimmingCharacters(in: .whitespaces)), length >= 0 {
                    state = .fixed(remaining: length)
                } else {
                    state = .untilClose
                }

            case .fixed(let remaining):
                if remaining == 0 {
                    markDone(&events)
                    return events
                }
                guard !buffer.isEmpty else { return events }
                let take = Int(min(Int64(buffer.count), remaining))
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                state = .fixed(remaining: remaining - Int64(take))

            case .chunkSize:
                guard let lineEnd = buffer.range(of: Self.crlf) else {
                    if buffer.count > 1024 { throw HTTPParseError.malformedChunk }
                    return events
                }
                let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                let hex = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { throw HTTPParseError.malformedChunk }
                state = size == 0 ? .trailers : .chunkData(remaining: size)

            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(buffer.count, remaining)
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                state = remaining == take ? .chunkDataEnd : .chunkData(remaining: remaining - take)

            case .chunkDataEnd:
                guard buffer.count >= 2 else { return events }
                guard Data(buffer.prefix(2)) == Self.crlf else { throw HTTPParseError.malformedChunk }
                buffer.removeFirst(2)
                state = .chunkSize

            case .trailers:
                guard let lineEnd = buffer.range(of: Self.crlf) else { return events }
                let isBlank = lineEnd.lowerBound == buffer.startIndex
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                if isBlank {
                    markDone(&events)
                    return events
                }

            case .untilClose:
                if !buffer.isEmpty {
                    events.append(.body(buffer))
                    buffer.removeAll()
                }
                return events

            case .done:
                return events
            }
        }
    }

    /// The peer closed the connection. Ends a close-delimited body; anything
    /// else still in progress is a truncated response.
    mutating func finish() throws -> [HTTPParseEvent] {
        switch state {
        case .done:
            return []
        case .untilClose:
            var events: [HTTPParseEvent] = []
            if !buffer.isEmpty { events.append(.body(buffer)); buffer.removeAll() }
            markDone(&events)
            return events
        default:
            throw HTTPParseError.truncatedBody
        }
    }

    private mutating func markDone(_ events: inout [HTTPParseEvent]) {
        state = .done
        isComplete = true
        events.append(.end)
    }

    private static func parseHead(_ data: Data) throws -> HTTPResponseHead {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedStatusLine }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw HTTPParseError.malformedStatusLine
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPParseError.malformedHeader }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return HTTPResponseHead(status: status, headers: headers)
    }
}
