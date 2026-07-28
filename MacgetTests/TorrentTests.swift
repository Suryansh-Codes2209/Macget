import XCTest
@testable import Macget

// MARK: - Magnet parsing

final class MagnetLinkTests: XCTestCase {

    func test_parsesHexInfoHashWithNameAndTrackers() throws {
        let magnet = "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056"
            + "&dn=ubuntu-24.04-desktop-amd64.iso"
            + "&tr=https%3A%2F%2Ftorrent.ubuntu.com%2Fannounce"
            + "&tr=udp%3A%2F%2Ftracker.example%3A1337"
        let link = try XCTUnwrap(MagnetLink.parse(magnet))

        XCTAssertEqual(link.infoHash, "c9e15763f722f23e98a29decdfae341b98d53056")
        XCTAssertEqual(link.displayName, "ubuntu-24.04-desktop-amd64.iso")
        XCTAssertEqual(link.trackers.count, 2)
    }

    func test_infoHashIsLowercased() throws {
        let link = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:C9E15763F722F23E98A29DECDFAE341B98D53056"))
        XCTAssertEqual(link.infoHash, "c9e15763f722f23e98a29decdfae341b98d53056")
    }

    /// Base32 info hashes are legal and still appear in the wild; rejecting them
    /// would silently fail on real magnets.
    func test_decodesBase32InfoHash() throws {
        // Base32 of the same 20 bytes as the hex case above.
        let link = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:ZHQVOY7XELZD5GFCTXWN7LRUDOMNKMCW"))
        XCTAssertEqual(link.infoHash.count, 40)
        XCTAssertEqual(link.infoHash, "c9e15763f722f23e98a29decdfae341b98d53056")
    }

    func test_plusSignsInNameBecomeSpaces() throws {
        let link = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&dn=Some+Long+Name"))
        XCTAssertEqual(link.displayName, "Some Long Name")
    }

    func test_parsesExactLength() throws {
        let link = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&xl=6203355136"))
        XCTAssertEqual(link.exactLength, 6_203_355_136)
    }

    /// A magnet with no `dn` still needs something to show in the queue.
    func test_provisionalNameFallsBackToHashPrefix() throws {
        let link = try XCTUnwrap(MagnetLink.parse("magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056"))
        XCTAssertEqual(link.provisionalName, "Torrent c9e15763")
    }

    func test_rejectsNonMagnetScheme() {
        XCTAssertNil(MagnetLink.parse("https://example.com/file.torrent"))
    }

    func test_rejectsMagnetWithoutInfoHash() {
        XCTAssertNil(MagnetLink.parse("magnet:?dn=no+hash+here"))
    }

    /// Other `xt` namespaces (ed2k, sha1) aren't BitTorrent info hashes.
    func test_ignoresNonBitTorrentExactTopics() {
        XCTAssertNil(MagnetLink.parse("magnet:?xt=urn:ed2k:31d6cfe0d16ae931b73c59d7e0c089c0"))
    }

    func test_rejectsWrongLengthHash() {
        XCTAssertNil(MagnetLink.parse("magnet:?xt=urn:btih:abcdef"))
    }

    func test_rejectsNonHexHashOfCorrectLength() {
        XCTAssertNil(MagnetLink.parse("magnet:?xt=urn:btih:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
    }
}

// MARK: - RPC wire format

final class Aria2RPCClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Aria2StubURLProtocol.reset()
    }

    private func makeClient() -> Aria2RPCClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Aria2StubURLProtocol.self]
        return Aria2RPCClient(
            endpoint: URL(string: "http://127.0.0.1:6800/jsonrpc")!,
            secret: "s3cret",
            session: URLSession(configuration: config)
        )
    }

    /// aria2 requires the secret as a leading `token:<secret>` element of params.
    /// Getting this wrong yields a confusing "Unauthorized" on every call.
    func test_prefixesSecretTokenOnEveryCall() async throws {
        Aria2StubURLProtocol.result = "\"abc123\""
        _ = try await makeClient().addURI("magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056")

        let body = try XCTUnwrap(Aria2StubURLProtocol.lastBody)
        let params = try XCTUnwrap(body["params"] as? [Any])
        XCTAssertEqual(params.first as? String, "token:s3cret")
        XCTAssertEqual(body["method"] as? String, "aria2.addUri")
        XCTAssertEqual(body["jsonrpc"] as? String, "2.0")
    }

    func test_addURIWrapsURIInAnArray() async throws {
        Aria2StubURLProtocol.result = "\"gid1\""
        _ = try await makeClient().addURI("magnet:?xt=urn:btih:aa", options: ["dir": "/tmp"])

        let body = try XCTUnwrap(Aria2StubURLProtocol.lastBody)
        let params = try XCTUnwrap(body["params"] as? [Any])
        XCTAssertEqual(params[1] as? [String], ["magnet:?xt=urn:btih:aa"])
        XCTAssertEqual((params[2] as? [String: String])?["dir"], "/tmp")
    }

    /// addTorrent's shape is [base64, webseeds, options] — omitting the empty
    /// webseed array shifts options into the wrong slot.
    func test_addTorrentSendsBase64WithEmptyWebseedArray() async throws {
        Aria2StubURLProtocol.result = "\"gid2\""
        let data = Data([0x64, 0x38, 0x3A])
        _ = try await makeClient().addTorrent(data, options: ["dir": "/tmp"])

        let body = try XCTUnwrap(Aria2StubURLProtocol.lastBody)
        let params = try XCTUnwrap(body["params"] as? [Any])
        XCTAssertEqual(params[1] as? String, data.base64EncodedString())
        XCTAssertEqual((params[2] as? [Any])?.count, 0)
        XCTAssertEqual((params[3] as? [String: String])?["dir"], "/tmp")
    }

    /// Every numeric field in aria2's reply is a decimal *string*.
    func test_parsesStringEncodedNumbers() async throws {
        Aria2StubURLProtocol.result = Fixtures.activeStatus
        let status = try await makeClient().tellStatus(gid: "gid1")

        XCTAssertEqual(status.totalLength, 6_203_355_136)
        XCTAssertEqual(status.completedLength, 1_073_741_824)
        XCTAssertEqual(status.uploadLength, 536_870_912)
        XCTAssertEqual(status.downloadSpeed, 5_242_880)
        XCTAssertEqual(status.uploadSpeed, 1_048_576)
        XCTAssertEqual(status.connections, 24)
        XCTAssertEqual(status.numSeeders, 12)
        XCTAssertEqual(status.status, "active")
    }

    func test_parsesBittorrentMetadata() async throws {
        Aria2StubURLProtocol.result = Fixtures.activeStatus
        let status = try await makeClient().tellStatus(gid: "gid1")
        XCTAssertEqual(status.infoHash, "c9e15763f722f23e98a29decdfae341b98d53056")
        XCTAssertEqual(status.name, "ubuntu-24.04-desktop-amd64.iso")
    }

    func test_parsesFileListWithSelectionFlags() async throws {
        Aria2StubURLProtocol.result = Fixtures.multiFileStatus
        let status = try await makeClient().tellStatus(gid: "gid1")

        XCTAssertEqual(status.files.count, 2)
        XCTAssertEqual(status.files[0].index, 1)
        XCTAssertEqual(status.files[0].length, 1000)
        XCTAssertTrue(status.files[0].selected)
        // aria2 encodes booleans as "true"/"false" strings here.
        XCTAssertFalse(status.files[1].selected)
    }

    /// A magnet's first GID only fetches metadata; aria2 then hands off to a new
    /// GID via followedBy. Missing this pins progress at 0 forever.
    func test_parsesFollowedByForMagnetHandoff() async throws {
        Aria2StubURLProtocol.result = Fixtures.metadataHandoffStatus
        let status = try await makeClient().tellStatus(gid: "meta")
        XCTAssertEqual(status.followedBy, ["realgid"])
        XCTAssertTrue(status.isComplete)
    }

    func test_surfacesRPCErrors() async {
        Aria2StubURLProtocol.errorBody = #"{"jsonrpc":"2.0","id":"1","error":{"code":1,"message":"Unauthorized"}}"#
        do {
            _ = try await makeClient().tellStatus(gid: "gid")
            XCTFail("Expected an error")
        } catch let error as Aria2Error {
            XCTAssertEqual(error, .rpc(code: 1, message: "Unauthorized"))
        } catch {
            XCTFail("Got \(error)")
        }
    }

    func test_ratioIsUploadOverDownloaded() async throws {
        Aria2StubURLProtocol.result = Fixtures.activeStatus
        let status = try await makeClient().tellStatus(gid: "gid1")
        XCTAssertEqual(try XCTUnwrap(status.ratio), 0.5, accuracy: 0.0001)
    }

    func test_ratioIsNilBeforeAnyProgress() {
        let status = Aria2RPCClient.parseStatus(["completedLength": "0", "uploadLength": "0"])
        XCTAssertNil(status.ratio)
    }

    /// Missing fields must default rather than crash — aria2 omits bittorrent
    /// keys entirely for non-torrent downloads.
    func test_parsesStatusWithMissingFields() {
        let status = Aria2RPCClient.parseStatus(["gid": "g", "status": "waiting"])
        XCTAssertEqual(status.gid, "g")
        XCTAssertEqual(status.totalLength, 0)
        XCTAssertNil(status.infoHash)
        XCTAssertNil(status.name)
        XCTAssertTrue(status.files.isEmpty)
        XCTAssertTrue(status.followedBy.isEmpty)
    }
}

// MARK: - Daemon configuration

final class Aria2DaemonTests: XCTestCase {

    private func args(_ options: TorrentEngineOptions = .init()) -> [String] {
        Aria2Daemon.arguments(port: 12345, secret: "abc", options: options)
    }

    /// MacGet owns the queue in queue.json and re-adds torrents itself on launch.
    /// If aria2 also restored its own session, the same info hash would be
    /// registered twice and aria2 would fail the second one outright
    /// ("InfoHash … is already registered") — i.e. exactly the resumed torrents.
    /// Two sources of truth for one queue; there must only be one.
    func test_doesNotUseAria2SessionPersistence() {
        let a = args()
        XCTAssertFalse(a.contains { $0.hasPrefix("--input-file") })
        XCTAssertFalse(a.contains { $0.hasPrefix("--save-session") })
    }

    /// Resume comes from the .aria2 control file beside the data instead, and
    /// saved metadata keeps a resumed magnet from re-fetching over BEP-9.
    func test_resumeReliesOnControlFileAndSavedMetadata() {
        let a = args()
        XCTAssertTrue(a.contains("--continue=true"))
        XCTAssertTrue(a.contains("--bt-save-metadata=true"))
    }

    /// The control channel must never leave the machine.
    func test_rpcBindsToLoopbackOnly() {
        let a = args()
        XCTAssertTrue(a.contains("--rpc-listen-all=false"))
        XCTAssertTrue(a.contains("--rpc-listen-port=12345"))
        XCTAssertTrue(a.contains("--rpc-secret=abc"))
        XCTAssertFalse(a.contains { $0.contains("--rpc-listen-all=true") })
    }

    func test_appliesSeedingLimits() {
        let a = args(TorrentEngineOptions(seedRatio: 2.5, seedMinutes: 30))
        XCTAssertTrue(a.contains("--seed-ratio=2.5"))
        XCTAssertTrue(a.contains("--seed-time=30"))
    }

    func test_dhtPortOnlyWhenDHTEnabled() {
        XCTAssertTrue(args(TorrentEngineOptions(listenPort: 7000, dhtEnabled: true)).contains("--dht-listen-port=7000-7009"))
        let off = args(TorrentEngineOptions(listenPort: 7000, dhtEnabled: false))
        XCTAssertFalse(off.contains { $0.hasPrefix("--dht-listen-port") })
        XCTAssertTrue(off.contains("--enable-dht=false"))
    }

    /// A single listen port makes aria2 fail outright ("Errors occurred while
    /// binding port") when anything else — another client, a stale aria2 — already
    /// holds it. A range lets it pick the next free one.
    func test_listenPortIsARangeNotASinglePort() {
        XCTAssertTrue(args(TorrentEngineOptions(listenPort: 6881)).contains("--listen-port=6881-6890"))
    }

    func test_portRangeStaysInsideValidBounds() {
        XCTAssertEqual(Aria2Daemon.portRange(from: 65530), "65530-65535")
        XCTAssertEqual(Aria2Daemon.portRange(from: 65535), "65535")
        XCTAssertEqual(Aria2Daemon.portRange(from: 1), "1024-1033")
    }

    /// `--follow-torrent=mem` stops aria2 spawning a second download for a
    /// .torrent MacGet added itself.
    func test_doesNotAutoFollowAddedTorrents() {
        XCTAssertTrue(args().contains("--follow-torrent=mem"))
    }

    func test_passesBandwidthCapsAsGlobalOptions() {
        let options = TorrentEngineOptions(maxUploadBytesPerSec: 500_000, maxDownloadBytesPerSec: 1_000_000)
        let a = args(options)
        XCTAssertTrue(a.contains("--max-overall-upload-limit=500000"))
        XCTAssertTrue(a.contains("--max-overall-download-limit=1000000"))
    }

    /// Unlimited is expressed as 0 to aria2, not omitted.
    func test_unlimitedBandwidthIsZero() {
        let mutable = TorrentEngineOptions().mutableGlobalOptions
        XCTAssertEqual(mutable["max-overall-upload-limit"], "0")
        XCTAssertEqual(mutable["max-overall-download-limit"], "0")
    }

    /// Ports and session paths can't be changed on a live daemon; sending them to
    /// changeGlobalOption would just error.
    func test_mutableOptionsExcludeLaunchOnlySettings() {
        let keys = Set(TorrentEngineOptions().mutableGlobalOptions.keys)
        XCTAssertFalse(keys.contains { $0.contains("port") })
        XCTAssertFalse(keys.contains { $0.contains("session") })
        XCTAssertFalse(keys.contains { $0.contains("seed") })
    }

    func test_secretIsUnpredictableAndLongEnough() {
        let a = Aria2Daemon.makeSecret()
        let b = Aria2Daemon.makeSecret()
        XCTAssertEqual(a.count, 64, "256 bits as hex")
        XCTAssertNotEqual(a, b)
    }

    func test_freePortIsInUsableRange() throws {
        let port = try Aria2Daemon.freePort()
        XCTAssertGreaterThan(port, 1024)
        XCTAssertLessThanOrEqual(port, 65535)
    }

    /// Two consecutive requests should not collide — a hardcoded 6800 would
    /// clash with any other aria2 on the machine.
    func test_freePortVariesAcrossCalls() throws {
        let ports = try (0..<5).map { _ in try Aria2Daemon.freePort() }
        XCTAssertGreaterThan(Set(ports).count, 1)
    }
}

// MARK: - Settings

final class TorrentSettingsTests: XCTestCase {

    func test_torrentsAreOffByDefault() {
        // Enabling torrents starts uploading and opens a listening port; that has
        // to be a deliberate choice.
        XCTAssertFalse(AppSettings().torrentsEnabled)
    }

    func test_defaultSeedingIsRatioOneOrOneHour() {
        let s = AppSettings()
        XCTAssertEqual(s.torrentSeedRatio, 1.0)
        XCTAssertEqual(s.torrentSeedMinutes, 60)
    }

    func test_clampsSeedRatio() {
        XCTAssertEqual(AppSettings(torrentSeedRatio: -5).torrentSeedRatio, 0)
        XCTAssertEqual(AppSettings(torrentSeedRatio: 999).torrentSeedRatio, 10)
    }

    func test_clampsSeedTimeToOneWeek() {
        XCTAssertEqual(AppSettings(torrentSeedMinutes: -1).torrentSeedMinutes, 0)
        XCTAssertEqual(AppSettings(torrentSeedMinutes: 999_999).torrentSeedMinutes, 10_080)
    }

    /// Ports below 1024 need root to bind, so they'd fail at launch.
    func test_rejectsPrivilegedAndOutOfRangePorts() {
        XCTAssertEqual(AppSettings(torrentListenPort: 80).torrentListenPort, 6881)
        XCTAssertEqual(AppSettings(torrentListenPort: 70000).torrentListenPort, 6881)
        XCTAssertEqual(AppSettings(torrentListenPort: 51413).torrentListenPort, 51413)
    }

    func test_nonPositiveUploadLimitMeansUnlimited() {
        XCTAssertNil(AppSettings(torrentMaxUploadBytesPerSec: 0).torrentMaxUploadBytesPerSec)
        XCTAssertNil(AppSettings(torrentMaxUploadBytesPerSec: -1).torrentMaxUploadBytesPerSec)
        XCTAssertEqual(AppSettings(torrentMaxUploadBytesPerSec: 1024).torrentMaxUploadBytesPerSec, 1024)
    }

    /// A settings.json written before torrents existed must still load, and must
    /// not silently switch torrents on.
    func test_decodesSettingsWrittenBeforeTorrentsExisted() throws {
        let json = #"{"defaultThreadCount":8,"maxConcurrentDownloads":3}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.torrentsEnabled)
        XCTAssertEqual(settings.torrentSeedRatio, 1.0)
        XCTAssertEqual(settings.torrentListenPort, 6881)
    }

    func test_globalSpeedLimitReachesTorrentOptions() {
        let settings = AppSettings(globalSpeedLimitBytesPerSec: 2_000_000)
        XCTAssertEqual(settings.torrentOptions.maxDownloadBytesPerSec, 2_000_000)
    }
}

// MARK: - Model round-tripping

final class TorrentDownloadModelTests: XCTestCase {

    func test_torrentKindRoundTrips() throws {
        let download = Download(
            url: URL(string: "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056")!,
            destinationFolder: URL(fileURLWithPath: "/tmp"),
            filename: "ubuntu.iso",
            kind: .torrent,
            torrentInfoHash: "c9e15763f722f23e98a29decdfae341b98d53056",
            torrentFiles: [TorrentFileEntry(index: 1, path: "/tmp/a.iso", length: 100, selected: true)],
            uploadedBytes: 512
        )
        let decoded = try JSONDecoder().decode(Download.self, from: JSONEncoder().encode(download))

        XCTAssertEqual(decoded.kind, .torrent)
        XCTAssertEqual(decoded.torrentInfoHash, download.torrentInfoHash)
        XCTAssertEqual(decoded.torrentFiles?.count, 1)
        XCTAssertEqual(decoded.uploadedBytes, 512)
    }

    /// A queue.json from before torrents existed must still decode — otherwise
    /// the whole queue is dropped on upgrade.
    func test_decodesQueueEntryWithoutTorrentFields() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "url": "https://example.com/a.zip",
          "destinationFolder": "file:///tmp/",
          "filename": "a.zip",
          "status": "queued",
          "threadCount": 8,
          "supportsRange": true,
          "chunks": [],
          "createdAt": 700000000
        }
        """
        let decoded = try JSONDecoder().decode(Download.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .httpFile)
        XCTAssertNil(decoded.torrentInfoHash)
        XCTAssertNil(decoded.torrentFiles)
    }

    func test_snapshotRatioUsesUploadedOverDownloaded() {
        let snapshot = DownloadSnapshot(
            id: UUID(),
            status: .downloading,
            bytesDownloaded: 1000,
            totalBytes: 2000,
            speedBytesPerSec: 0,
            etaSeconds: nil,
            uploadedBytes: 500
        )
        XCTAssertEqual(try XCTUnwrap(snapshot.ratio), 0.5, accuracy: 0.0001)
    }

    func test_snapshotRatioIsNilWithoutTorrentData() {
        let snapshot = DownloadSnapshot(
            id: UUID(),
            status: .downloading,
            bytesDownloaded: 1000,
            totalBytes: 2000,
            speedBytesPerSec: 0,
            etaSeconds: nil
        )
        XCTAssertNil(snapshot.ratio)
    }

    func test_torrentFileEntryDisplayNameIsLastComponent() {
        let entry = TorrentFileEntry(index: 1, path: "/downloads/season/ep01.mkv", length: 1, selected: true)
        XCTAssertEqual(entry.displayName, "ep01.mkv")
    }

    // MARK: Error mapping

    /// Adding the same torrent twice makes aria2 say "InfoHash … is already
    /// registered", which means nothing to a user.
    func test_duplicateTorrentGetsAReadableError() {
        let error = TorrentJob.friendlyError("InfoHash 01c137287d6f0ed05a56742dae794f632c79ff3d is already registered.")
        XCTAssertEqual(
            (error as? Aria2Error)?.errorDescription?.contains("already in the queue"),
            true
        )
    }

    func test_otherErrorsPassThroughUnchanged() {
        let error = TorrentJob.friendlyError("Timeout while contacting tracker")
        XCTAssertEqual((error as? Aria2Error)?.errorDescription?.contains("Timeout"), true)
    }

    func test_emptyErrorStillProducesAMessage() {
        XCTAssertNotNil((TorrentJob.friendlyError(nil) as? Aria2Error)?.errorDescription)
    }

    // MARK: ETA

    func test_etaFromRemainingBytesAndSpeed() {
        let eta = try? XCTUnwrap(TorrentJob.eta(total: 1_000_000, done: 500_000, speed: 100_000))
        XCTAssertEqual(eta ?? 0, 5.0, accuracy: 0.001)
    }

    /// Below 1 KB/s the estimate is noise — same threshold SpeedMeter uses.
    func test_etaIsNilAtTrickleSpeeds() {
        XCTAssertNil(TorrentJob.eta(total: 1_000_000, done: 0, speed: 500))
    }

    func test_etaIsNilWhenSizeUnknownOrComplete() {
        XCTAssertNil(TorrentJob.eta(total: 0, done: 0, speed: 100_000))
        XCTAssertNil(TorrentJob.eta(total: 1000, done: 1000, speed: 100_000))
    }
}

// MARK: - Stub

final class Aria2StubURLProtocol: URLProtocol {
    /// Raw JSON for the `result` field.
    nonisolated(unsafe) static var result = "\"ok\""
    /// When set, returned verbatim instead of wrapping `result`.
    nonisolated(unsafe) static var errorBody: String?
    nonisolated(unsafe) static var lastBody: [String: Any]?

    static func reset() {
        result = "\"ok\""
        errorBody = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody for some session configs; bodyStream is the
        // reliable source.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else if let body = request.httpBody {
            Self.lastBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }

        let json = Self.errorBody ?? #"{"jsonrpc":"2.0","id":"macget-1","result":\#(Self.result)}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum Fixtures {

    static let activeStatus = """
    {
      "gid": "gid1",
      "status": "active",
      "totalLength": "6203355136",
      "completedLength": "1073741824",
      "uploadLength": "536870912",
      "downloadSpeed": "5242880",
      "uploadSpeed": "1048576",
      "connections": "24",
      "numSeeders": "12",
      "bittorrent": {
        "infoHash": "c9e15763f722f23e98a29decdfae341b98d53056",
        "info": { "name": "ubuntu-24.04-desktop-amd64.iso" }
      },
      "files": []
    }
    """

    static let multiFileStatus = """
    {
      "gid": "gid1",
      "status": "active",
      "totalLength": "3000",
      "completedLength": "0",
      "files": [
        { "index": "1", "path": "/d/a.mkv", "length": "1000", "completedLength": "0", "selected": "true" },
        { "index": "2", "path": "/d/b.nfo", "length": "2000", "completedLength": "0", "selected": "false" }
      ]
    }
    """

    static let metadataHandoffStatus = """
    {
      "gid": "meta",
      "status": "complete",
      "totalLength": "0",
      "completedLength": "0",
      "followedBy": ["realgid"],
      "files": []
    }
    """
}
