import XCTest
@testable import Macget

final class CredentialStoreTests: XCTestCase {

    // Uses the in-memory session cache (no Keychain entitlement needed in tests).
    func test_sessionCredentialRoundTrips() {
        let host = "test-\(UUID().uuidString).example.com"
        XCTAssertNil(CredentialStore.shared.credential(forHost: host))

        CredentialStore.shared.saveSession(host: host, user: "alice", password: "s3cret")

        let cred = CredentialStore.shared.credential(forHost: host)
        XCTAssertEqual(cred?.user, "alice")
        XCTAssertEqual(cred?.password, "s3cret")
        XCTAssertEqual(CredentialStore.shared.username(forHost: host), "alice")
    }

    func test_emptyHostIsIgnored() {
        CredentialStore.shared.saveSession(host: "", user: "x", password: "y")
        XCTAssertNil(CredentialStore.shared.credential(forHost: ""))
    }
}

final class AuthErrorClassificationTests: XCTestCase {

    func test_authRequiredErrorsAreRecognized() {
        XCTAssertTrue(DownloadCoordinator.isAuthRequired(ChunkError.authRequired(code: 401)))
        XCTAssertTrue(DownloadCoordinator.isAuthRequired(ChunkError.authRequired(code: 407)))
        XCTAssertTrue(DownloadCoordinator.isAuthRequired(RangeProbeError.authRequired(401)))
    }

    func test_otherErrorsAreNotAuth() {
        XCTAssertFalse(DownloadCoordinator.isAuthRequired(ChunkError.unexpectedStatus(404)))
        XCTAssertFalse(DownloadCoordinator.isAuthRequired(RangeProbeError.httpStatus(500)))
        XCTAssertFalse(DownloadCoordinator.isAuthRequired(CoordinatorError.stalled))
    }

    func test_authRequiredIsPermanent() {
        XCTAssertTrue(DownloadCoordinator.isPermanentChunkError(ChunkError.authRequired(code: 401)))
    }
}
