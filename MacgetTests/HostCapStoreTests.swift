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

        // Force the debounced save to disk before reading from a fresh instance.
        try await Task.sleep(nanoseconds: 700_000_000)

        let reader = HostCapStore(fileURL: url)
        let cap = await reader.cap(for: "persisted.example.com")
        XCTAssertEqual(cap, 3)
    }
}
