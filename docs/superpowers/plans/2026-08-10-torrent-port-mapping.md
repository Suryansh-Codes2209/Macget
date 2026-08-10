# Torrent Inbound Reachability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MacGet connectable from the internet by mapping its BitTorrent listening port through the router with PCP/NAT-PMP, and tell the user honestly when that isn't possible.

**Architecture:** A new `PortMapper` actor owns one job: keep a TCP and a UDP mapping alive for `torrentListenPort` and expose a `Reachability` state. All protocol bytes live in `NATPortMapCodec`, a pure encoder/decoder with no I/O, so the wire formats are fully unit-testable. Socket work sits behind a `PortMapTransport` protocol, so the actor's state machine and negotiation logic are testable with a stub and no router. `Aria2Daemon` starts and stops the mapper alongside the daemon.

**Tech Stack:** Swift 6, actors, Network.framework (`NWConnection`, UDP), XCTest. Protocols: PCP (RFC 6887) and NAT-PMP (RFC 6886).

**Spec:** `docs/superpowers/specs/2026-08-10-torrent-performance-design.md` §2

**Companion plan:** `docs/superpowers/plans/2026-08-10-torrent-engine-tuning.md`. That plan adds `AppSettings.torrentAutoPortMapping`, which this plan is the first to read. **Task 1 of the tuning plan must land before Task 5 here.** Everything else is independent, and the two can be built in either order.

## Global Constraints

- **Build/test from the CLI requires `DEVELOPER_DIR`.** The active developer dir is CommandLineTools, so bare `xcodebuild` fails. Every command below is prefixed. Never run `sudo xcode-select`.
- **New `.swift` files need no `project.pbxproj` edit** — Xcode 16 `PBXFileSystemSynchronizedRootGroup`.
- **Logging:** `Logger(subsystem: "com.macget", category: …)`, as the other torrent files do. Never `print`.
- **Port mapping is best-effort and never fatal.** Every failure path resolves to a `Reachability` state and a slower download. No mapping error may reach `TorrentJob.fail` or prevent the daemon from starting.
- **No packets unless torrents are in use.** The mapper starts with the aria2 daemon and stops with it, so a user who never opens a torrent never talks to their router.
- **Delete mappings on shutdown.** A lifetime-0 request on exit, so MacGet doesn't leave a stale hole in the router.
- **App Sandbox is off**, so raw UDP to the gateway needs no entitlement.
- **Minimum macOS is 26.4** — `loadUnaligned`, `NWConnection`, and structured concurrency are all available.

**Test command (single class):**
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/<ClassName>
```

**Reading failures:** assertion text is not in `xcodebuild` output. Use the `.xcresult` path printed near the end of the log:
```bash
xcrun xcresulttool get test-results tests --path <…>.xcresult --format json
```
and walk `testNodes` for `nodeType: "Failure Message"`.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Macget/Engine/Torrent/NATPortMapCodec.swift` | Create | PCP + NAT-PMP packet encode/decode; CGNAT predicate. Pure, no I/O |
| `Macget/Engine/Torrent/PortMapGateway.swift` | Create | Default-gateway discovery from the sysctl routing table |
| `Macget/Engine/Torrent/PortMapTransport.swift` | Create | `PortMapTransport` protocol + the real UDP implementation |
| `Macget/Engine/Torrent/PortMapper.swift` | Create | Actor: negotiation, both mappings, renewal, `Reachability` |
| `Macget/Engine/Torrent/Aria2Daemon.swift` | Modify | Start/stop the mapper with the daemon; expose reachability |
| `Macget/Views/TorrentSettingsView.swift` | Modify | Connectivity row + auto-mapping toggle |
| `MacgetTests/NATPortMapCodecTests.swift` | Create | Wire formats, malformed input, CGNAT predicate |
| `MacgetTests/PortMapperTests.swift` | Create | Negotiation and state machine against a stub transport |

---

## Task 1: `NATPortMapCodec` — the wire formats

**Files:**
- Create: `Macget/Engine/Torrent/NATPortMapCodec.swift`
- Test: `MacgetTests/NATPortMapCodecTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum MappingProtocol { case pcp, natPMP }`
  - `enum PortMapProtocolKind { case tcp, udp }`
  - `struct PortMapResult { let externalPort: UInt16; let externalAddress: String?; let lifetime: UInt32 }`
  - `NATPortMapCodec.natPMPRequest(kind:internalPort:suggestedExternalPort:lifetime:) -> Data`
  - `NATPortMapCodec.parseNATPMPResponse(_ data: Data, kind: PortMapProtocolKind) -> PortMapResult?`
  - `NATPortMapCodec.pcpRequest(kind:internalPort:suggestedExternalPort:lifetime:clientAddress:nonce:) -> Data`
  - `NATPortMapCodec.parsePCPResponse(_ data: Data, nonce: [UInt8]) -> PortMapResult?`
  - `NATPortMapCodec.isNATPMPFallbackSignal(_ data: Data) -> Bool`
  - `NATPortMapCodec.isCarrierGradeNAT(_ address: String) -> Bool`
  - `NATPortMapCodec.makeNonce() -> [UInt8]`

- [ ] **Step 1: Write the failing test**

Create `MacgetTests/NATPortMapCodecTests.swift`:

```swift
import XCTest
@testable import Macget

final class NATPortMapCodecTests: XCTestCase {

    // MARK: - NAT-PMP (RFC 6886)

    func test_natPMPRequestMatchesRFC6886Layout() {
        let request = NATPortMapCodec.natPMPRequest(
            kind: .tcp, internalPort: 6881, suggestedExternalPort: 6881, lifetime: 7200)
        let bytes = [UInt8](request)

        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(bytes[0], 0, "version 0")
        XCTAssertEqual(bytes[1], 2, "opcode 2 is TCP; 1 is UDP")
        XCTAssertEqual(bytes[2], 0)
        XCTAssertEqual(bytes[3], 0)
        XCTAssertEqual(UInt16(bytes[4]) << 8 | UInt16(bytes[5]), 6881, "internal port, big-endian")
        XCTAssertEqual(UInt16(bytes[6]) << 8 | UInt16(bytes[7]), 6881, "suggested external port")
        XCTAssertEqual(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16
                       | UInt32(bytes[10]) << 8 | UInt32(bytes[11]), 7200, "lifetime")
    }

    func test_natPMPUsesOpcodeOneForUDP() {
        let request = NATPortMapCodec.natPMPRequest(
            kind: .udp, internalPort: 6881, suggestedExternalPort: 6881, lifetime: 7200)
        XCTAssertEqual([UInt8](request)[1], 1)
    }

    func test_parsesSuccessfulNATPMPMapping() throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0                      // version
        bytes[1] = 130                    // 128 + TCP opcode
        bytes[2] = 0; bytes[3] = 0        // result code 0 = success
        bytes[10] = 0x1A; bytes[11] = 0xE1   // external port 6881
        bytes[15] = 0x64                  // lifetime 100

        let result = try XCTUnwrap(NATPortMapCodec.parseNATPMPResponse(Data(bytes), kind: .tcp))
        XCTAssertEqual(result.externalPort, 6881)
        XCTAssertEqual(result.lifetime, 100)
    }

    func test_rejectsNATPMPResponseWithNonZeroResultCode() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[1] = 130
        bytes[3] = 2                      // "not authorized / refused"
        XCTAssertNil(NATPortMapCodec.parseNATPMPResponse(Data(bytes), kind: .tcp))
    }

    /// A response for the *other* protocol must not be accepted as ours, or a TCP
    /// mapping reports success on the strength of a UDP reply.
    func test_rejectsNATPMPResponseForTheWrongProtocol() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[1] = 129                    // UDP reply
        XCTAssertNil(NATPortMapCodec.parseNATPMPResponse(Data(bytes), kind: .tcp))
    }

    func test_rejectsTruncatedNATPMPResponse() {
        XCTAssertNil(NATPortMapCodec.parseNATPMPResponse(Data([0, 130, 0, 0]), kind: .tcp))
        XCTAssertNil(NATPortMapCodec.parseNATPMPResponse(Data(), kind: .tcp))
    }

    // MARK: - PCP (RFC 6887)

    func test_pcpRequestMatchesRFC6887Layout() {
        let nonce = [UInt8](repeating: 0x5A, count: 12)
        let request = NATPortMapCodec.pcpRequest(
            kind: .tcp, internalPort: 6881, suggestedExternalPort: 6881,
            lifetime: 7200, clientAddress: "192.168.1.50", nonce: nonce)
        let bytes = [UInt8](request)

        XCTAssertEqual(bytes.count, 60)
        XCTAssertEqual(bytes[0], 2, "version 2")
        XCTAssertEqual(bytes[1], 1, "R bit clear, opcode 1 = MAP")
        XCTAssertEqual(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
                       | UInt32(bytes[6]) << 8 | UInt32(bytes[7]), 7200)
        // Client address is IPv4-mapped IPv6: ::ffff:192.168.1.50
        XCTAssertEqual(Array(bytes[8..<18]), [UInt8](repeating: 0, count: 10))
        XCTAssertEqual(bytes[18], 0xFF)
        XCTAssertEqual(bytes[19], 0xFF)
        XCTAssertEqual(Array(bytes[20..<24]), [192, 168, 1, 50])
        XCTAssertEqual(Array(bytes[24..<36]), nonce)
        XCTAssertEqual(bytes[36], 6, "6 = TCP, 17 = UDP")
        XCTAssertEqual(UInt16(bytes[40]) << 8 | UInt16(bytes[41]), 6881)
        XCTAssertEqual(UInt16(bytes[42]) << 8 | UInt16(bytes[43]), 6881)
    }

    func test_pcpUsesProtocolSeventeenForUDP() {
        let request = NATPortMapCodec.pcpRequest(
            kind: .udp, internalPort: 1, suggestedExternalPort: 1, lifetime: 1,
            clientAddress: "10.0.0.2", nonce: [UInt8](repeating: 0, count: 12))
        XCTAssertEqual([UInt8](request)[36], 17)
    }

    func test_parsesSuccessfulPCPMappingIncludingExternalAddress() throws {
        let nonce = [UInt8](repeating: 0x11, count: 12)
        var bytes = [UInt8](repeating: 0, count: 60)
        bytes[0] = 2
        bytes[1] = 0x81                   // R bit set, opcode 1
        bytes[3] = 0                      // result code SUCCESS
        bytes[7] = 0x3C                   // lifetime 60
        for (offset, value) in nonce.enumerated() { bytes[24 + offset] = value }
        bytes[36] = 6
        bytes[42] = 0x1A; bytes[43] = 0xE1   // assigned external port 6881
        // Assigned external address ::ffff:203.0.113.9
        bytes[54] = 0xFF; bytes[55] = 0xFF
        bytes[56] = 203; bytes[57] = 0; bytes[58] = 113; bytes[59] = 9

        let result = try XCTUnwrap(NATPortMapCodec.parsePCPResponse(Data(bytes), nonce: nonce))
        XCTAssertEqual(result.externalPort, 6881)
        XCTAssertEqual(result.lifetime, 60)
        XCTAssertEqual(result.externalAddress, "203.0.113.9")
    }

    /// The nonce is what ties a reply to our request. Accepting a mismatched one
    /// lets any host on the LAN forge a "mapping succeeded".
    func test_rejectsPCPResponseWithMismatchedNonce() {
        var bytes = [UInt8](repeating: 0, count: 60)
        bytes[0] = 2
        bytes[1] = 0x81
        for offset in 0..<12 { bytes[24 + offset] = 0xAA }
        XCTAssertNil(NATPortMapCodec.parsePCPResponse(Data(bytes), nonce: [UInt8](repeating: 0x11, count: 12)))
    }

    func test_rejectsPCPResponseWithErrorResultCode() {
        let nonce = [UInt8](repeating: 0x11, count: 12)
        var bytes = [UInt8](repeating: 0, count: 60)
        bytes[0] = 2
        bytes[1] = 0x81
        bytes[3] = 8                      // NO_RESOURCES
        for (offset, value) in nonce.enumerated() { bytes[24 + offset] = value }
        XCTAssertNil(NATPortMapCodec.parsePCPResponse(Data(bytes), nonce: nonce))
    }

    func test_rejectsTruncatedPCPResponse() {
        XCTAssertNil(NATPortMapCodec.parsePCPResponse(Data([2, 0x81, 0, 0]), nonce: []))
    }

    /// A NAT-PMP-only router answers a version-2 request with version 0, which is
    /// how RFC 6887 says to discover it. That's the cue to retry as NAT-PMP.
    func test_detectsNATPMPOnlyRouterFromVersionZeroReply() {
        XCTAssertTrue(NATPortMapCodec.isNATPMPFallbackSignal(Data([0, 128, 0, 1])))
        XCTAssertFalse(NATPortMapCodec.isNATPMPFallbackSignal(Data([2, 0x81, 0, 0])))
        XCTAssertFalse(NATPortMapCodec.isNATPMPFallbackSignal(Data()))
    }

    func test_noncesAreTwelveBytesAndUnpredictable() {
        let a = NATPortMapCodec.makeNonce()
        let b = NATPortMapCodec.makeNonce()
        XCTAssertEqual(a.count, 12)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - CGNAT

    /// A mapping to a private address means the first NAT accepted it but the
    /// ISP's NAT upstream still blocks inbound. Reporting that as "open" would
    /// show a green check on a connection that can never receive a peer.
    func test_detectsCarrierGradeAndPrivateExternalAddresses() {
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("100.64.0.1"), "RFC 6598 CGN space")
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("100.127.255.254"), "top of 100.64/10")
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("10.0.0.1"))
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("192.168.1.1"))
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("172.16.0.1"))
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("172.31.255.255"))
        XCTAssertTrue(NATPortMapCodec.isCarrierGradeNAT("169.254.1.1"), "link-local means no mapping at all")
    }

    /// The boundaries are where an over-broad mask silently condemns a real
    /// public address. 100.63/100.128 and 172.15/172.32 are all public.
    func test_publicAddressesAreNotMistakenForCarrierGradeNAT() {
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("203.0.113.9"))
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("100.63.255.255"))
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("100.128.0.0"))
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("172.15.0.1"))
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("172.32.0.1"))
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("8.8.8.8"))
    }

    func test_malformedAddressIsNotTreatedAsCarrierGradeNAT() {
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT(""))
        XCTAssertFalse(NATPortMapCodec.isCarrierGradeNAT("not.an.address"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/NATPortMapCodecTests
```
Expected: compile failure — cannot find `NATPortMapCodec` in scope.

- [ ] **Step 3: Write the codec**

Create `Macget/Engine/Torrent/NATPortMapCodec.swift`:

```swift
import Foundation

/// Which protocol produced a mapping. PCP is the successor to NAT-PMP; most
/// consumer routers speak one or the other, so MacGet tries PCP and falls back.
enum MappingProtocol: Equatable, Sendable {
    case pcp
    case natPMP
}

/// BitTorrent needs *both*: TCP carries peer connections, UDP carries DHT and
/// µTP. Mapping only one is a common and silent half-fix.
enum PortMapProtocolKind: Equatable, Sendable {
    case tcp
    case udp
}

struct PortMapResult: Equatable, Sendable {
    let externalPort: UInt16
    /// PCP reports the external address; NAT-PMP's map response does not, so this
    /// is nil there and CGNAT can't be detected from a NAT-PMP mapping alone.
    let externalAddress: String?
    let lifetime: UInt32
}

/// Pure encoder/decoder for PCP (RFC 6887) and NAT-PMP (RFC 6886).
///
/// No sockets, no state: every byte layout here is exercised by unit tests, so
/// the parts that are easy to get subtly wrong never need a router to verify.
enum NATPortMapCodec {

    // MARK: - NAT-PMP (RFC 6886)

    static func natPMPRequest(
        kind: PortMapProtocolKind,
        internalPort: UInt16,
        suggestedExternalPort: UInt16,
        lifetime: UInt32
    ) -> Data {
        var bytes = [UInt8]()
        bytes.append(0)                                  // version
        bytes.append(kind == .udp ? 1 : 2)               // opcode
        bytes.append(contentsOf: [0, 0])                 // reserved
        bytes.append(contentsOf: bigEndian(internalPort))
        bytes.append(contentsOf: bigEndian(suggestedExternalPort))
        bytes.append(contentsOf: bigEndian(lifetime))
        return Data(bytes)
    }

    static func parseNATPMPResponse(_ data: Data, kind: PortMapProtocolKind) -> PortMapResult? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 0 else { return nil }
        // The reply opcode is 128 + the request opcode. Checking it stops a UDP
        // reply from being read as proof that the TCP mapping succeeded.
        guard bytes[1] == (kind == .udp ? 129 : 130) else { return nil }
        guard UInt16(bytes[2]) << 8 | UInt16(bytes[3]) == 0 else { return nil }   // result code

        return PortMapResult(
            externalPort: UInt16(bytes[10]) << 8 | UInt16(bytes[11]),
            externalAddress: nil,
            lifetime: UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        )
    }

    // MARK: - PCP (RFC 6887)

    static func pcpRequest(
        kind: PortMapProtocolKind,
        internalPort: UInt16,
        suggestedExternalPort: UInt16,
        lifetime: UInt32,
        clientAddress: String,
        nonce: [UInt8]
    ) -> Data {
        var bytes = [UInt8]()
        bytes.append(2)                                  // version
        bytes.append(1)                                  // R bit clear, opcode 1 = MAP
        bytes.append(contentsOf: [0, 0])                 // reserved
        bytes.append(contentsOf: bigEndian(lifetime))
        bytes.append(contentsOf: ipv4MappedIPv6(clientAddress))
        bytes.append(contentsOf: nonce)                  // 12 bytes
        bytes.append(kind == .udp ? 17 : 6)              // IANA protocol number
        bytes.append(contentsOf: [0, 0, 0])              // reserved
        bytes.append(contentsOf: bigEndian(internalPort))
        bytes.append(contentsOf: bigEndian(suggestedExternalPort))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))   // no preferred external IP
        return Data(bytes)
    }

    static func parsePCPResponse(_ data: Data, nonce: [UInt8]) -> PortMapResult? {
        let bytes = [UInt8](data)
        guard bytes.count >= 60, bytes[0] == 2, bytes[1] == 0x81 else { return nil }
        guard bytes[3] == 0 else { return nil }                       // result code
        // The nonce is the only thing tying this reply to our request; without
        // the check any host on the LAN could forge a success.
        guard Array(bytes[24..<36]) == nonce else { return nil }

        let externalAddress = ipv4String(from: Array(bytes[44..<60]))
        return PortMapResult(
            externalPort: UInt16(bytes[42]) << 8 | UInt16(bytes[43]),
            externalAddress: externalAddress,
            lifetime: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        )
    }

    /// RFC 6887: a NAT-PMP-only server answers a version-2 request with version 0.
    /// That's the documented way to discover it, so it's the cue to retry.
    static func isNATPMPFallbackSignal(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return bytes.count >= 2 && bytes[0] == 0
    }

    static func makeNonce() -> [UInt8] {
        (0..<12).map { _ in UInt8.random(in: 0...255) }
    }

    // MARK: - CGNAT

    /// True when a mapping's external address still can't receive inbound
    /// traffic: the first NAT accepted the mapping, but the address it handed
    /// back is itself behind another NAT.
    static func isCarrierGradeNAT(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        switch (parts[0], parts[1]) {
        case (10, _):                       return true    // RFC 1918
        case (192, 168):                    return true    // RFC 1918
        case (172, 16...31):                return true    // RFC 1918
        case (100, 64...127):               return true    // RFC 6598 carrier-grade NAT
        case (169, 254):                    return true    // link-local: no mapping at all
        default:                            return false
        }
    }

    // MARK: - Bytes

    private static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// PCP carries every address as 16 bytes, so IPv4 goes in as ::ffff:a.b.c.d.
    private static func ipv4MappedIPv6(_ address: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[10] = 0xFF
        bytes[11] = 0xFF
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return bytes }
        for (offset, octet) in octets.enumerated() { bytes[12 + offset] = octet }
        return bytes
    }

    /// Reads the IPv4 back out of a 16-byte PCP address, or nil if it isn't one.
    private static func ipv4String(from bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        let prefixIsIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xFF && bytes[11] == 0xFF
        guard prefixIsIPv4Mapped else { return nil }
        return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/NATPortMapCodecTests
```
Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Torrent/NATPortMapCodec.swift MacgetTests/NATPortMapCodecTests.swift
git commit -m "feat(torrent): add PCP and NAT-PMP packet codec"
```

---

## Task 2: Gateway and local-address discovery

**Files:**
- Create: `Macget/Engine/Torrent/PortMapGateway.swift`
- Test: `MacgetTests/PortMapperTests.swift` (create — a small first class; Task 4 adds more)

**Interfaces:**
- Consumes: nothing.
- Produces: `PortMapGateway.defaultIPv4() -> String?`, `PortMapGateway.localIPv4(towards gateway: String) -> String?`.

PCP requires our own internal address in the request, and both protocols need the gateway's. Both come from the kernel: the routing table via `sysctl`, and the interface list via `getifaddrs`. No subprocess.

- [ ] **Step 1: Write the failing test**

Create `MacgetTests/PortMapperTests.swift`:

```swift
import XCTest
@testable import Macget

final class PortMapGatewayTests: XCTestCase {

    /// This runs on whatever network the machine is on, so it asserts shape, not
    /// a specific address: a gateway is either absent (no network) or a real
    /// dotted-quad that is not loopback.
    func test_defaultGatewayIsAPlausibleIPv4AddressOrNil() {
        guard let gateway = PortMapGateway.defaultIPv4() else { return }
        let octets = gateway.split(separator: ".")
        XCTAssertEqual(octets.count, 4, "got \(gateway)")
        XCTAssertTrue(octets.allSatisfy { UInt8($0) != nil }, "got \(gateway)")
        XCTAssertFalse(gateway.hasPrefix("127."), "loopback is never the default gateway")
        XCTAssertNotEqual(gateway, "0.0.0.0")
    }

    /// The address PCP puts in its request must be this host's address on the
    /// same network as the gateway — not loopback, and not nil when a gateway
    /// was found.
    func test_localAddressTowardsGatewayIsOnTheSameNetwork() {
        guard let gateway = PortMapGateway.defaultIPv4(),
              let local = PortMapGateway.localIPv4(towards: gateway) else { return }
        XCTAssertFalse(local.hasPrefix("127."))
        XCTAssertEqual(local.split(separator: ".").count, 4, "got \(local)")

        // Same /24 is not guaranteed by IP in general, but is by every consumer
        // router this feature targets; a mismatch means we picked the wrong
        // interface (e.g. a VM bridge).
        let gatewayPrefix = gateway.split(separator: ".").dropLast().joined(separator: ".")
        let localPrefix = local.split(separator: ".").dropLast().joined(separator: ".")
        XCTAssertEqual(localPrefix, gatewayPrefix, "picked an interface on another network")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/PortMapGatewayTests
```
Expected: compile failure — cannot find `PortMapGateway` in scope.

- [ ] **Step 3: Write the discovery**

Create `Macget/Engine/Torrent/PortMapGateway.swift`:

```swift
import Foundation
import Darwin

/// Finds the router to talk to, and the address to claim as ours.
///
/// Both come from the kernel rather than a subprocess: `route -n get default`
/// would work but means spawning a process on a path that runs at every daemon
/// start, and its output format is not a contract.
enum PortMapGateway {

    /// The IPv4 address of the default gateway, or nil when there's no route
    /// (no network, or IPv6-only).
    static func defaultIPv4() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> String? in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0, offset + messageLength <= size else { break }

                if header.rtm_flags & RTF_GATEWAY != 0 {
                    if let gateway = gatewayOfDefaultRoute(raw, messageStart: offset, header: header, limit: size) {
                        return gateway
                    }
                }
                offset += messageLength
            }
            return nil
        }
    }

    /// Walks one routing message's address list, returning the gateway only when
    /// the destination is 0.0.0.0 — i.e. this really is the *default* route and
    /// not just some route that happens to have a gateway.
    private static func gatewayOfDefaultRoute(
        _ raw: UnsafeRawBufferPointer,
        messageStart: Int,
        header: rt_msghdr,
        limit: Int
    ) -> String? {
        var cursor = messageStart + MemoryLayout<rt_msghdr>.size
        var destinationIsDefault = false

        // Addresses appear in bit order of rtm_addrs: RTA_DST is bit 0,
        // RTA_GATEWAY bit 1. Each is a sockaddr padded to a 4-byte boundary.
        for bit in 0..<8 where header.rtm_addrs & (1 << bit) != 0 {
            guard cursor + MemoryLayout<sockaddr>.size <= limit else { return nil }
            let address = raw.loadUnaligned(fromByteOffset: cursor, as: sockaddr.self)
            let rawLength = Int(address.sa_len)
            let length = rawLength == 0 ? MemoryLayout<UInt32>.size : rawLength

            if bit == 0 {
                guard address.sa_family == UInt8(AF_INET) else { return nil }
                let inet = raw.loadUnaligned(fromByteOffset: cursor, as: sockaddr_in.self)
                destinationIsDefault = inet.sin_addr.s_addr == 0
                if !destinationIsDefault { return nil }
            } else if bit == 1 {
                guard destinationIsDefault, address.sa_family == UInt8(AF_INET) else { return nil }
                var inet = raw.loadUnaligned(fromByteOffset: cursor, as: sockaddr_in.self)
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &inet.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil
                else { return nil }
                return String(cString: text)
            }
            cursor += (length + 3) & ~3   // sockaddrs are 4-byte aligned
        }
        return nil
    }

    /// This host's IPv4 address on the same /24 as the gateway.
    ///
    /// PCP puts the client's own address in the request, and a Mac with a VM
    /// bridge or a VPN has several candidates — matching the gateway's prefix
    /// picks the one that actually faces the router.
    static func localIPv4(towards gateway: String) -> String? {
        let gatewayPrefix = gateway.split(separator: ".").dropLast().joined(separator: ".")

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let raw = interface.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var inet = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self).pointee
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inet.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil
            else { continue }

            let address = String(cString: text)
            if address.split(separator: ".").dropLast().joined(separator: ".") == gatewayPrefix {
                return address
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/PortMapGatewayTests
```
Expected: PASS. On a machine with no network both tests return early, which is correct — they assert shape when there is something to assert.

Sanity-check the value against the system's own view:
```bash
route -n get default | grep gateway
```
The address printed must match what the test saw. If they differ, the `rtm_addrs` walk is wrong — most likely the 4-byte alignment roundup.

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Torrent/PortMapGateway.swift MacgetTests/PortMapperTests.swift
git commit -m "feat(torrent): discover default gateway and local address from the kernel"
```

---

## Task 3: UDP transport

**Files:**
- Create: `Macget/Engine/Torrent/PortMapTransport.swift`
- Test: none directly — this is the I/O seam every other test replaces. Its correctness is covered by Task 5's end-to-end check against a real router.

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol PortMapTransport: Sendable { func exchange(_ request: Data, gateway: String, port: UInt16, timeout: Duration) async throws -> Data }`
  - `struct UDPPortMapTransport: PortMapTransport`
  - `enum PortMapTransportError: Error { case timedOut, cancelled, failed(String) }`

- [ ] **Step 1: Write the transport**

Create `Macget/Engine/Torrent/PortMapTransport.swift`:

```swift
import Foundation
import Network

enum PortMapTransportError: Error, Equatable {
    case timedOut
    case failed(String)
}

/// One request/response exchange with the router.
///
/// The seam exists so `PortMapper`'s negotiation and state machine can be tested
/// without a router — the protocol logic is where the bugs live, not the socket.
protocol PortMapTransport: Sendable {
    func exchange(_ request: Data, gateway: String, port: UInt16, timeout: Duration) async throws -> Data
}

/// Sends one UDP datagram to the gateway and waits for one reply.
///
/// A fresh connection per exchange: these are rare (a mapping and a renewal
/// every hour), and a long-lived UDP connection to a router that may reboot
/// underneath us buys nothing.
struct UDPPortMapTransport: PortMapTransport {

    func exchange(_ request: Data, gateway: String, port: UInt16, timeout: Duration) async throws -> Data {
        let connection = NWConnection(
            host: NWEndpoint.Host(gateway),
            port: NWEndpoint.Port(rawValue: port) ?? 5351,
            using: .udp
        )

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.send(request, over: connection)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PortMapTransportError.timedOut
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            guard let response = try await group.next() else {
                throw PortMapTransportError.timedOut
            }
            return response
        }
    }

    private static func send(_ request: Data, over connection: NWConnection) async throws -> Data {
        connection.start(queue: .global(qos: .utility))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // `resume` must fire exactly once; NWConnection can report .failed
            // after .ready, and a second resume traps.
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<Void, Error>) {
                let shouldResume = hasResumed.withLock { resumed -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            connection.send(content: request, completion: .contentProcessed { error in
                if let error {
                    finish(.failure(PortMapTransportError.failed(error.localizedDescription)))
                } else {
                    finish(.success(()))
                }
            })
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: PortMapTransportError.failed(error.localizedDescription))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PortMapTransportError.failed("empty reply"))
                }
            }
        }
    }
}
```

`OSAllocatedUnfairLock` comes from `os`; add `import os` if the compiler asks.

- [ ] **Step 2: Build**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Macget.xcodeproj -scheme Macget -configuration Debug build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Macget/Engine/Torrent/PortMapTransport.swift
git commit -m "feat(torrent): add UDP transport seam for port mapping"
```

---

## Task 4: `PortMapper` actor

**Files:**
- Create: `Macget/Engine/Torrent/PortMapper.swift`
- Test: `MacgetTests/PortMapperTests.swift` (extend)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces:
  - `enum Reachability: Equatable, Sendable { case unknown, mapped(port: UInt16, via: MappingProtocol), carrierGradeNAT(port: UInt16), unsupported(port: UInt16), failed(String) }`
  - `actor PortMapper` with `init(transport:)`, `func start(listenPort: Int) async`, `func stop() async`, `var reachability: Reachability { get }`

- [ ] **Step 1: Write the failing test**

Add to `MacgetTests/PortMapperTests.swift`:

```swift
/// Answers based on the *request*, not from a fixed queue.
///
/// This matters: `PortMapper` tries PCP before NAT-PMP for **each** of TCP and
/// UDP, so a reply queue drifts out of step after the first fallback and tests
/// start passing for the wrong reason. Responding to what was actually asked
/// also lets a stub router echo the random PCP nonce, which a pre-scripted
/// reply can never do.
final actor StubPortMapTransport: PortMapTransport {
    private let responder: @Sendable (Data) -> Data?
    private(set) var sent: [Data] = []

    init(responder: @escaping @Sendable (Data) -> Data?) { self.responder = responder }

    func exchange(_ request: Data, gateway: String, port: UInt16, timeout: Duration) async throws -> Data {
        sent.append(request)
        guard let reply = responder(request) else { throw PortMapTransportError.timedOut }
        return reply
    }

    var sentRequests: [Data] { sent }
}

final class PortMapperTests: XCTestCase {

    // Note on telling the two request formats apart in assertions: the **version
    // byte** is the reliable discriminator — PCP requests start with 2, NAT-PMP
    // with 0. Byte 1 is not: PCP's MAP opcode is 1, the same value as NAT-PMP's
    // UDP opcode.

    /// A router that speaks only NAT-PMP: it rejects PCP with a version-0 reply,
    /// exactly as RFC 6887 describes, and maps anything else.
    private var natPMPOnlyRouter: @Sendable (Data) -> Data? {
        { request in
            let bytes = [UInt8](request)
            guard bytes.count >= 12 else { return nil }
            if bytes[0] == 2 { return Data([0, 128, 0, 1]) }        // PCP → unsupported version

            var reply = [UInt8](repeating: 0, count: 16)
            reply[1] = bytes[1] == 1 ? 129 : 130                    // echo the protocol
            reply[10] = 0x1A; reply[11] = 0xE1                      // external port 6881
            reply[15] = 0x64                                        // lifetime 100
            return Data(reply)
        }
    }

    /// A PCP-capable router handing back the given external address. It echoes
    /// the nonce from the request, which is what makes the reply acceptable.
    private func pcpRouter(externalAddress: [UInt8]) -> @Sendable (Data) -> Data? {
        { request in
            let bytes = [UInt8](request)
            guard bytes.count >= 60, bytes[0] == 2 else { return nil }

            var reply = [UInt8](repeating: 0, count: 60)
            reply[0] = 2
            reply[1] = 0x81
            reply[3] = 0                                            // SUCCESS
            reply[7] = 0x3C                                         // lifetime 60
            for (offset, value) in bytes[24..<36].enumerated() { reply[24 + offset] = value }
            reply[42] = 0x1A; reply[43] = 0xE1                      // external port 6881
            reply[54] = 0xFF; reply[55] = 0xFF                      // IPv4-mapped
            for (offset, octet) in externalAddress.enumerated() { reply[56 + offset] = octet }
            return Data(reply)
        }
    }

    func test_fallsBackToNATPMPWhenTheRouterAnswersWithVersionZero() async {
        let transport = StubPortMapTransport(responder: natPMPOnlyRouter)
        let mapper = PortMapper(transport: transport, gateway: "192.168.1.1", localAddress: "192.168.1.50")
        await mapper.start(listenPort: 6881)

        XCTAssertEqual(await mapper.reachability, .mapped(port: 6881, via: .natPMP))
    }

    func test_usesPCPWhenTheRouterSupportsIt() async {
        let transport = StubPortMapTransport(responder: pcpRouter(externalAddress: [203, 0, 113, 9]))
        let mapper = PortMapper(transport: transport, gateway: "192.168.1.1", localAddress: "192.168.1.50")
        await mapper.start(listenPort: 6881)

        XCTAssertEqual(await mapper.reachability, .mapped(port: 6881, via: .pcp))
        // No NAT-PMP fallback should have been attempted at all.
        let sent = await transport.sentRequests
        XCTAssertTrue(sent.allSatisfy { [UInt8]($0).first == 2 })
    }

    /// Both must be mapped: TCP carries peers, UDP carries DHT and µTP. Mapping
    /// only one is a silent half-fix.
    func test_mapsBothTCPAndUDP() async {
        let transport = StubPortMapTransport(responder: natPMPOnlyRouter)
        let mapper = PortMapper(transport: transport, gateway: "192.168.1.1", localAddress: "192.168.1.50")
        await mapper.start(listenPort: 6881)

        let natPMPRequests = await transport.sentRequests.filter { [UInt8]($0).first == 0 }
        let opcodes = Set(natPMPRequests.map { [UInt8]($0)[1] })
        XCTAssertEqual(opcodes, [1, 2], "opcode 2 is TCP, 1 is UDP")
    }

    /// A router that never answers is `.unsupported`, not `.failed` — nothing
    /// went wrong, it just can't do this.
    func test_silentRouterIsReportedAsUnsupported() async {
        let transport = StubPortMapTransport(responder: { _ in nil })
        let mapper = PortMapper(transport: transport, gateway: "192.168.1.1", localAddress: "192.168.1.50")
        await mapper.start(listenPort: 6881)

        XCTAssertEqual(await mapper.reachability, .unsupported(port: 6881))
    }

    /// The mapping succeeded, but the address behind it is still private — the
    /// ISP's NAT upstream blocks inbound regardless. Reporting `.mapped` here
    /// would show a green check on a connection that can never receive a peer.
    func test_privateExternalAddressIsReportedAsCarrierGradeNAT() async {
        let transport = StubPortMapTransport(responder: pcpRouter(externalAddress: [100, 64, 12, 9]))
        let mapper = PortMapper(transport: transport, gateway: "192.168.1.1", localAddress: "192.168.1.50")
        await mapper.start(listenPort: 6881)

        XCTAssertEqual(await mapper.reachability, .carrierGradeNAT(port: 6881))
    }

    /// With no gateway there is nothing to talk to, and no packet should be sent.
    func test_noGatewayMeansUnsupportedAndNoTraffic() async {
        let transport = StubPortMapTransport(responder: { _ in nil })
        let mapper = PortMapper(transport: transport, gateway: nil, localAddress: nil)
        await mapper.start(listenPort: 6881)

        XCTAssertEqual(await mapper.reachability, .unsupported(port: 6881))
        let sent = await transport.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }

    /// Stopping must release the mapping rather than leaving a stale hole in the
    /// router. A deletion is a map request with lifetime 0.
    func test_stopSendsZeroLifetimeDeletionForBothProtocols() async {
        let transport = StubPortMapTransport(responder: pcpRouter(externalAddress: [203, 0, 113, 9]))
        let mapper = PortMapper(transport: transport, gateway: "192.168.1.1", localAddress: "192.168.1.50")
        await mapper.start(listenPort: 6881)

        let beforeStop = await transport.sentRequests.count
        await mapper.stop()

        let deletions = await transport.sentRequests.dropFirst(beforeStop).map { [UInt8]($0) }
        XCTAssertEqual(deletions.count, 2, "one deletion each for TCP and UDP")
        for deletion in deletions {
            // PCP lifetime lives at bytes 4...7.
            let lifetime = UInt32(deletion[4]) << 24 | UInt32(deletion[5]) << 16
                | UInt32(deletion[6]) << 8 | UInt32(deletion[7])
            XCTAssertEqual(lifetime, 0)
        }
        XCTAssertEqual(await mapper.reachability, .unknown)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/PortMapperTests
```
Expected: compile failure — cannot find `PortMapper` in scope.

- [ ] **Step 3: Write the actor**

Create `Macget/Engine/Torrent/PortMapper.swift`:

```swift
import Foundation
import OSLog

/// What the outside world can reach, as far as MacGet can tell.
enum Reachability: Equatable, Sendable {
    /// Not probed — either nothing has run yet, or the user turned mapping off.
    /// MacGet does not claim to know the state of a port it was told not to touch.
    case unknown
    case mapped(port: UInt16, via: MappingProtocol)
    /// Mapped, but to an address that is itself behind a NAT. Inbound is
    /// impossible no matter what the router says.
    case carrierGradeNAT(port: UInt16)
    /// The router didn't answer or refused. Also where UPnP-only routers land.
    case unsupported(port: UInt16)
    case failed(String)
}

/// Keeps a TCP and a UDP mapping alive for the BitTorrent listening port.
///
/// Why this exists: aria2 implements neither UPnP nor NAT-PMP, and macOS ships
/// no port-mapping API. Without a mapping MacGet can only reach peers it dials
/// out to and never receives an incoming connection — roughly half the swarm.
///
/// Best-effort throughout. Every failure resolves to a `Reachability` value and
/// a slower download; nothing here can fail a torrent or stop the daemon.
///
/// **UPnP IGD is a deliberate non-goal.** It needs SSDP discovery, XML device
/// descriptions and SOAP control requests — several times this much code, for a
/// protocol PCP largely supersedes. UPnP-only routers land in `.unsupported`
/// and get the manual-forwarding message.
actor PortMapper {
    private let transport: PortMapTransport
    private let gateway: String?
    private let localAddress: String?
    private let log = Logger(subsystem: "com.macget", category: "PortMapper")

    private(set) var reachability: Reachability = .unknown
    private var mappedProtocol: MappingProtocol?
    private var listenPort: UInt16 = 0
    private var renewalTask: Task<Void, Never>?

    /// RFC 6886 recommends 7200s and renewal at half-life.
    private static let requestedLifetime: UInt32 = 7200
    private static let exchangeTimeout = Duration.seconds(2)
    private static let gatewayPort: UInt16 = 5351

    init(
        transport: PortMapTransport = UDPPortMapTransport(),
        gateway: String? = PortMapGateway.defaultIPv4(),
        localAddress: String? = nil
    ) {
        self.transport = transport
        self.gateway = gateway
        self.localAddress = localAddress ?? gateway.flatMap { PortMapGateway.localIPv4(towards: $0) }
    }

    // MARK: - Lifecycle

    func start(listenPort: Int) async {
        self.listenPort = UInt16(clamping: listenPort)
        guard gateway != nil else {
            // No route to a router: nothing to ask, and nothing to report but
            // "this can't work here".
            reachability = .unsupported(port: self.listenPort)
            return
        }
        await refresh()
        scheduleRenewal()
    }

    func stop() async {
        renewalTask?.cancel()
        renewalTask = nil
        // A deletion is a map request with lifetime 0. Best-effort: if the router
        // is already gone, the mapping expires on its own.
        if mappedProtocol != nil {
            _ = await map(kind: .tcp, lifetime: 0)
            _ = await map(kind: .udp, lifetime: 0)
        }
        mappedProtocol = nil
        reachability = .unknown
    }

    // MARK: - Mapping

    private func refresh() async {
        guard let tcp = await map(kind: .tcp, lifetime: Self.requestedLifetime) else {
            reachability = .unsupported(port: listenPort)
            mappedProtocol = nil
            return
        }
        // UDP carries DHT and µTP. A failure here is not fatal — TCP peers still
        // work — so it's logged, not surfaced as a different state.
        if await map(kind: .udp, lifetime: Self.requestedLifetime) == nil {
            log.error("UDP mapping failed; DHT and µTP will be limited")
        }

        if let address = tcp.result.externalAddress, NATPortMapCodec.isCarrierGradeNAT(address) {
            reachability = .carrierGradeNAT(port: tcp.result.externalPort)
        } else {
            reachability = .mapped(port: tcp.result.externalPort, via: tcp.protocol)
        }
        mappedProtocol = tcp.protocol
        log.info("Port \(self.listenPort, privacy: .public) mapped via \(String(describing: tcp.protocol), privacy: .public)")
    }

    /// One mapping attempt: PCP first, NAT-PMP if the router says it only speaks
    /// the older protocol.
    private func map(
        kind: PortMapProtocolKind,
        lifetime: UInt32
    ) async -> (result: PortMapResult, `protocol`: MappingProtocol)? {
        guard let gateway else { return nil }

        if let localAddress {
            let nonce = NATPortMapCodec.makeNonce()
            let request = NATPortMapCodec.pcpRequest(
                kind: kind,
                internalPort: listenPort,
                suggestedExternalPort: listenPort,
                lifetime: lifetime,
                clientAddress: localAddress,
                nonce: nonce
            )
            if let reply = try? await transport.exchange(
                request, gateway: gateway, port: Self.gatewayPort, timeout: Self.exchangeTimeout
            ) {
                if let result = NATPortMapCodec.parsePCPResponse(reply, nonce: nonce) {
                    return (result, .pcp)
                }
                // Anything other than the documented version-0 fallback is a
                // refusal, not a reason to retry with an older protocol.
                guard NATPortMapCodec.isNATPMPFallbackSignal(reply) else { return nil }
            }
        }

        let request = NATPortMapCodec.natPMPRequest(
            kind: kind,
            internalPort: listenPort,
            suggestedExternalPort: listenPort,
            lifetime: lifetime
        )
        guard let reply = try? await transport.exchange(
            request, gateway: gateway, port: Self.gatewayPort, timeout: Self.exchangeTimeout
        ), let result = NATPortMapCodec.parseNATPMPResponse(reply, kind: kind) else { return nil }
        return (result, .natPMP)
    }

    // MARK: - Renewal

    /// Mappings expire. Renew at half-life so a missed renewal has a second
    /// chance before the hole closes.
    private func scheduleRenewal() {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Int(Self.requestedLifetime / 2)))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/PortMapperTests
```
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Macget/Engine/Torrent/PortMapper.swift MacgetTests/PortMapperTests.swift
git commit -m "feat(torrent): map the listening port via PCP with NAT-PMP fallback"
```

---

## Task 5: Wire the mapper into the daemon lifecycle

**Files:**
- Modify: `Macget/Engine/Torrent/Aria2Daemon.swift`

**Requires:** Task 1 of the companion tuning plan (`AppSettings.torrentAutoPortMapping`).

**Interfaces:**
- Consumes: `PortMapper` (Task 4), `AppSettings.torrentAutoPortMapping`.
- Produces: `TorrentEngineOptions.autoPortMapping: Bool` (default `true`), `Aria2Daemon.currentReachability: Reachability` (async getter).

- [ ] **Step 1: Add the option**

In `TorrentEngineOptions`, after `addPublicTrackers`:

```swift
    /// Ask the router to forward the listening port via PCP/NAT-PMP.
    var autoPortMapping: Bool = true
```

Add `autoPortMapping: Bool = true,` to the memberwise `init` with `self.autoPortMapping = autoPortMapping` in the body, and to `init(settings:)`:

```swift
            autoPortMapping: settings.torrentAutoPortMapping,
```

- [ ] **Step 2: Own a mapper in the daemon**

Add to `Aria2Daemon`'s stored properties:

```swift
    /// Started with the daemon and stopped with it, so a user who never opens a
    /// torrent never sends a packet to their router.
    private var portMapper: PortMapper?
```

and a getter:

```swift
    /// What the UI shows in the Connectivity row.
    var currentReachability: Reachability {
        get async { await portMapper?.reachability ?? .unknown }
    }
```

- [ ] **Step 3: Start it after the daemon is ready**

In `start(options:)`, after the `log.info("aria2c started …")` line and before `return client`:

```swift
        if options.autoPortMapping {
            let mapper = PortMapper()
            portMapper = mapper
            // Detached from startup: a slow or absent router must never delay
            // the first torrent.
            Task { await mapper.start(listenPort: options.listenPort) }
        }
```

- [ ] **Step 4: Stop it on shutdown**

In `shutdown()`, at the very top (before `startTask?.cancel()`):

```swift
        // Release the mapping before the process goes away, so MacGet doesn't
        // leave a stale hole in the router.
        if let portMapper {
            await portMapper.stop()
            self.portMapper = nil
        }
```

- [ ] **Step 5: Build and verify against a real router**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Macget.xcodeproj -scheme Macget -configuration Debug build
```
Expected: BUILD SUCCEEDED.

Then launch the app, enable torrents, and start any well-seeded public torrent. Watch the log:

```bash
log stream --predicate 'subsystem == "com.macget" AND category == "PortMapper"' --level info
```

Expect one line: `Port 6881 mapped via pcp` (or `natPMP`). If nothing appears within a few seconds, the router speaks neither protocol — that is a legitimate `.unsupported`, not a bug. Confirm the router agrees by checking its admin page's port-forwarding table for an entry on 6881.

- [ ] **Step 6: Commit**

```bash
git add Macget/Engine/Torrent/Aria2Daemon.swift
git commit -m "feat(torrent): map the listening port while the daemon runs"
```

---

## Task 6: Connectivity row

**Files:**
- Modify: `Macget/Views/TorrentSettingsView.swift`
- Test: manual (SwiftUI view; the project has no view-snapshot harness)

**Interfaces:**
- Consumes: `Aria2Daemon.currentReachability`, `AppSettings.torrentAutoPortMapping`.
- Produces: `TorrentSettingsView.connectivityText(for:)` — a `static func` so the copy is checkable without rendering.

- [ ] **Step 1: Write the failing test**

Add to `MacgetTests/PortMapperTests.swift`:

```swift
@MainActor
final class ConnectivityCopyTests: XCTestCase {

    /// Each state must say something a user can act on. `.carrierGradeNAT` in
    /// particular must not read like a router problem the user can fix.
    func test_everyStateProducesActionableCopy() {
        let mapped = TorrentSettingsView.connectivityText(for: .mapped(port: 6881, via: .pcp))
        XCTAssertTrue(mapped.contains("6881"))
        XCTAssertTrue(mapped.lowercased().contains("open"))

        let cgn = TorrentSettingsView.connectivityText(for: .carrierGradeNAT(port: 6881))
        XCTAssertTrue(cgn.lowercased().contains("carrier-grade"))
        XCTAssertFalse(cgn.lowercased().contains("forward port"), "the user cannot fix CGNAT by forwarding")

        let unsupported = TorrentSettingsView.connectivityText(for: .unsupported(port: 6881))
        XCTAssertTrue(unsupported.lowercased().contains("forward port 6881"))

        XCTAssertFalse(TorrentSettingsView.connectivityText(for: .unknown).isEmpty)
        XCTAssertTrue(TorrentSettingsView.connectivityText(for: .failed("no route")).contains("no route"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/ConnectivityCopyTests
```
Expected: compile failure — no member `connectivityText`.

- [ ] **Step 3: Add the copy and the row**

Add to `TorrentSettingsView`:

```swift
    /// Copy for each reachability state. `static` so it can be tested without
    /// rendering a view.
    static func connectivityText(for reachability: Reachability) -> String {
        switch reachability {
        case .unknown:
            return "Checking whether incoming connections can reach this Mac…"
        case .mapped(let port, let via):
            let name = via == .pcp ? "PCP" : "NAT-PMP"
            return "Port \(port) — open (mapped automatically via \(name))."
        case .carrierGradeNAT:
            // Not the router's fault and not fixable by forwarding: the ISP's NAT
            // sits above the user's own. Say so, rather than sending them to a
            // settings page that cannot help.
            return "Your internet provider uses carrier-grade NAT, so incoming connections can't reach this Mac. Downloads still work, but more slowly. A VPN with port forwarding is the usual workaround."
        case .unsupported(let port):
            return "Port \(port) — closed. This router doesn't support automatic port mapping. Forward port \(port) to this Mac in the router's settings, and check that macOS's firewall allows incoming connections for aria2."
        case .failed(let reason):
            return "Port mapping didn't complete: \(reason)"
        }
    }
```

Add the state and the row. In the `Section("Network")` body, after the DHT toggle:

```swift
                Toggle("Map the port automatically (PCP/NAT-PMP)", isOn: $vm.settings.torrentAutoPortMapping)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: connectivityIcon)
                        .foregroundStyle(connectivityColor)
                    Text(Self.connectivityText(for: reachability))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

with these members:

```swift
    @State private var reachability: Reachability = .unknown

    private var connectivityIcon: String {
        switch reachability {
        case .mapped:            return "checkmark.circle.fill"
        case .unknown:           return "clock"
        default:                 return "exclamationmark.circle"
        }
    }

    private var connectivityColor: Color {
        switch reachability {
        case .mapped:            return Theme.Palette.success
        case .unknown:           return .secondary
        default:                 return Theme.Palette.paused
        }
    }
```

and refresh it when the tab appears — extend the existing `.onAppear`:

```swift
        .onAppear {
            aria2Installed = TorrentToolInstaller.isInstalled
            Task { reachability = await Aria2Daemon.shared.currentReachability }
        }
```

Mapping only runs while the daemon does, so before the first torrent this correctly reads `.unknown` ("Checking…") rather than claiming the port is closed.

- [ ] **Step 4: Run test to verify it passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
  -only-testing:MacgetTests/ConnectivityCopyTests
```
Expected: PASS.

- [ ] **Step 5: Run the whole suite and build**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'
```
Expected: all tests pass.

Then launch the app, start a torrent, and open Settings ▸ Torrents. **Visual verification cannot be done from the shell** (`screencapture` has no Screen Recording permission) — ask the user for a screenshot showing the Connectivity row.

- [ ] **Step 6: Commit**

```bash
git add Macget/Views/TorrentSettingsView.swift MacgetTests/PortMapperTests.swift
git commit -m "feat(torrent): show inbound connectivity in Torrent settings"
```

---

## Task 7: Document the subsystem

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture.md`

- [ ] **Step 1: Update `CLAUDE.md`**

Add to the BitTorrent section:

```markdown
- **MacGet maps its own listening port.** aria2 implements neither UPnP nor NAT-PMP and macOS
  ships no port-mapping API, so an unmapped MacGet only reaches peers it dials out to — about
  half a swarm. `PortMapper` tries PCP (RFC 6887) and falls back to NAT-PMP (RFC 6886) when the
  router answers a version-2 request with version 0, maps **both** TCP (peers) and UDP (DHT, µTP),
  renews at half-life, and deletes the mapping on shutdown. It runs only while the daemon does.
- **CGNAT is reported, not hidden.** If the mapped external address is RFC 1918 or `100.64.0.0/10`,
  inbound is impossible regardless of the router, so the UI says so instead of showing a green
  check on a connection that can never receive a peer.
- **UPnP IGD is a deliberate non-goal** — SSDP + XML + SOAP for a protocol PCP largely supersedes.
  UPnP-only routers land in `.unsupported` and get the manual-forwarding message.
```

- [ ] **Step 2: Update `docs/architecture.md`** with the same substance in that document's prose style.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/architecture.md
git commit -m "docs: record the port-mapping subsystem"
```

---

## Self-Review

**Spec coverage (§2 of the spec):**

| Requirement | Task |
|---|---|
| PCP first, NAT-PMP fallback via version-0 detection | 1 (codec), 4 (negotiation) |
| Map both TCP and UDP | 4 |
| Gateway from the sysctl routing table, no subprocess | 2 |
| Lifetime 7200s, renewal at half-life | 4 |
| Delete mapping on shutdown | 4, 5 |
| Mapper starts/stops with the daemon; no packets otherwise | 5 |
| `torrentAutoPortMapping` gates the component | 5 (option), 6 (toggle) |
| CGNAT detection | 1 (predicate), 4 (state), 6 (copy) |
| Reachability state enum | 4 |
| UPnP explicitly out of scope | documented in 4, 7 |
| Firewall not probed; mentioned in help text | 6 |
| Connectivity UI row | 6 |
| Codec testable with no network; I/O behind a protocol | 1, 3, 4 |

**Placeholder scan:** none. Every step has runnable commands or complete code.

**Type consistency:** `MappingProtocol`, `PortMapProtocolKind`, and `PortMapResult` are defined in Task 1 and used unchanged in Tasks 4–6. `Reachability` is defined in Task 4 and consumed in 5 and 6. `PortMapTransport.exchange` keeps one signature across Tasks 3 and 4 and the test stub. `TorrentEngineOptions` gains `autoPortMapping` in Task 5, after `addPublicTrackers` from the companion plan's Task 8 — if this plan is built first, place it after `maxConcurrentDownloads` instead.

**Known gap, stated rather than hidden:** `UDPPortMapTransport` (Task 3) has no unit test — it is the seam every other test replaces. Its only verification is the live router check in Task 5, Step 5. That is a deliberate trade (testing it properly would mean a local UDP echo server), but it means a transport-level bug reaches the user as `.unsupported` rather than a failing test.
