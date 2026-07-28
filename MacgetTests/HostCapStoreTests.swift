import XCTest
@testable import Macget

final class HostCapStoreTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("host_caps_test_\(UUID().uuidString).json")
    }

    func test_capIsNilForUnknownHost() async {
        let store = HostCapStore(fileURL: tempStoreURL())
        let cap = await store.cap(for: "unknown.example.com")
        XCTAssertNil(cap)
    }

    func test_recordedCapIsRetrieved() async {
        let store = HostCapStore(fileURL: tempStoreURL())
        await store.recordCap(4, for: "tight.example.com")
        let cap = await store.cap(for: "tight.example.com")
        XCTAssertEqual(cap, 4)
    }

    func test_capRatchetsDownward() async {
        // A subsequent permissive run mustn't undo a tight cap learned earlier.
        let store = HostCapStore(fileURL: tempStoreURL())
        await store.recordCap(2, for: "h.example.com")
        await store.recordCap(8, for: "h.example.com")
        let cap = await store.cap(for: "h.example.com")
        XCTAssertEqual(cap, 2, "Higher cap must NOT override a previously-learned tighter cap")
    }

    func test_lowerCapOverridesHigher() async {
        let store = HostCapStore(fileURL: tempStoreURL())
        await store.recordCap(8, for: "h.example.com")
        await store.recordCap(2, for: "h.example.com")
        let cap = await store.cap(for: "h.example.com")
        XCTAssertEqual(cap, 2)
    }

    func test_capsAreIndependentPerHost() async {
        let store = HostCapStore(fileURL: tempStoreURL())
        await store.recordCap(4, for: "a.example.com")
        await store.recordCap(8, for: "b.example.com")
        let a = await store.cap(for: "a.example.com")
        let b = await store.cap(for: "b.example.com")
        XCTAssertEqual(a, 4)
        XCTAssertEqual(b, 8)
    }

    func test_clearForgetsCap() async {
        let store = HostCapStore(fileURL: tempStoreURL())
        await store.recordCap(4, for: "h.example.com")
        await store.clear(host: "h.example.com")
        let cap = await store.cap(for: "h.example.com")
        XCTAssertNil(cap)
    }

    func test_capPersistsAcrossInstances() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = HostCapStore(fileURL: url)
        await writer.recordCap(3, for: "persisted.example.com")
        await writer.flushNow()

        let reader = HostCapStore(fileURL: url)
        let cap = await reader.cap(for: "persisted.example.com")
        XCTAssertEqual(cap, 3)
    }

    // MARK: - Expiry

    /// A clock the test moves by hand, so expiry is exercised without sleeping.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ start: Date) { _now = start }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return _now
        }
        func advance(_ interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _now += interval
        }
    }

    func test_capSurvivesInsideRetentionWindow() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let store = HostCapStore(fileURL: tempStoreURL(), now: { clock.now })
        await store.recordCap(4, for: "h.example.com")

        clock.advance(HostCapStore.retention - 60)

        let cap = await store.cap(for: "h.example.com")
        XCTAssertEqual(cap, 4)
    }

    func test_capExpiresAfterRetentionWindow() async {
        // The whole point: a cap learned from one bad afternoon must not hold a
        // host down forever.
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let store = HostCapStore(fileURL: tempStoreURL(), now: { clock.now })
        await store.recordCap(4, for: "h.example.com")

        clock.advance(HostCapStore.retention + 60)

        let cap = await store.cap(for: "h.example.com")
        XCTAssertNil(cap)
    }

    func test_expiredCapIsReplacedByHigherValue() async {
        // Ratcheting down applies only within the window. Once a record has
        // aged out, a more permissive run is allowed to win.
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let store = HostCapStore(fileURL: tempStoreURL(), now: { clock.now })
        await store.recordCap(2, for: "h.example.com")

        clock.advance(HostCapStore.retention + 60)
        await store.recordCap(8, for: "h.example.com")

        let cap = await store.cap(for: "h.example.com")
        XCTAssertEqual(cap, 8)
    }

    func test_learnedHostCountIgnoresExpiredRecords() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let store = HostCapStore(fileURL: tempStoreURL(), now: { clock.now })
        await store.recordCap(2, for: "old.example.com")

        clock.advance(HostCapStore.retention + 60)
        await store.recordCap(4, for: "new.example.com")

        let count = await store.learnedHostCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Reset

    func test_clearAllForgetsEveryHost() async {
        let store = HostCapStore(fileURL: tempStoreURL())
        await store.recordCap(2, for: "a.example.com")
        await store.recordCap(4, for: "b.example.com")

        await store.clearAll()

        let a = await store.cap(for: "a.example.com")
        let b = await store.cap(for: "b.example.com")
        let count = await store.learnedHostCount()
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Migration

    func test_migratesLegacyIntegerFormat() async throws {
        // Pre-expiry releases wrote a bare [host: cap] map with no timestamps.
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = try JSONEncoder().encode(["legacy.example.com": 3])
        try legacy.write(to: url)

        let store = HostCapStore(fileURL: url)
        let cap = await store.cap(for: "legacy.example.com")
        XCTAssertEqual(cap, 3, "Legacy caps must still apply immediately after upgrade")
    }

    func test_migratedLegacyCapExpiresFromLoadTime() async throws {
        // Legacy records carry no timestamp, so they're stamped at load. That is
        // what lets a permanently-mislearned cap finally age out post-upgrade.
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = try JSONEncoder().encode(["legacy.example.com": 3])
        try legacy.write(to: url)

        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let store = HostCapStore(fileURL: url, now: { clock.now })
        _ = await store.cap(for: "legacy.example.com")  // triggers the load + stamp

        clock.advance(HostCapStore.retention + 60)

        let cap = await store.cap(for: "legacy.example.com")
        XCTAssertNil(cap)
    }

    func test_roundTripsTimestampedRecordsThroughDisk() async throws {
        // Encoder and decoder must agree on date strategy, or a saved store
        // silently reads back as empty.
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = HostCapStore(fileURL: url)
        await writer.recordCap(5, for: "rt.example.com")
        await writer.flushNow()

        let reader = HostCapStore(fileURL: url)
        let cap = await reader.cap(for: "rt.example.com")
        let count = await reader.learnedHostCount()
        XCTAssertEqual(cap, 5)
        XCTAssertEqual(count, 1)
    }
}
