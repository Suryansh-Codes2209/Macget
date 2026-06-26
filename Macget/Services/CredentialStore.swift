import Foundation
import Security
import OSLog

/// Keychain-backed store for HTTP auth credentials, keyed by host. Used to answer
/// Basic/Digest/NTLM challenges and to persist credentials the user enters so
/// authenticated downloads keep working across launches.
final class CredentialStore: @unchecked Sendable {
    static let shared = CredentialStore()

    private let service = "com.macget.credentials"
    private let log = Logger(subsystem: "com.macget", category: "CredentialStore")

    private struct Entry: Codable { let user: String; let password: String }

    /// In-memory credentials for "don't remember" — used this session only, never
    /// written to the Keychain. Checked before the Keychain.
    private let lock = NSLock()
    private var sessionCache: [String: Entry] = [:]

    /// A `URLCredential` for `host`, or nil if none is stored.
    func credential(forHost host: String) -> URLCredential? {
        guard let entry = lookup(host) else { return nil }
        return URLCredential(user: entry.user, password: entry.password, persistence: .forSession)
    }

    /// The stored username for `host` (to prefill the prompt), if any.
    func username(forHost host: String) -> String? {
        lookup(host)?.user
    }

    private func lookup(_ host: String) -> Entry? {
        lock.lock()
        let cached = sessionCache[host]
        lock.unlock()
        return cached ?? entry(forHost: host)
    }

    /// Store credentials for this session only (not persisted).
    func saveSession(host: String, user: String, password: String) {
        guard !host.isEmpty else { return }
        lock.lock()
        sessionCache[host] = Entry(user: user, password: password)
        lock.unlock()
    }

    /// Store (or replace) credentials for `host`.
    func save(host: String, user: String, password: String) {
        guard !host.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(Entry(user: user, password: password)) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Keychain save failed for \(host, privacy: .public): OSStatus \(status)")
        }
        // Mirror into the session cache so the immediate resume sees it regardless.
        lock.lock()
        sessionCache[host] = Entry(user: user, password: password)
        lock.unlock()
    }

    func remove(forHost host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func entry(forHost host: String) -> Entry? {
        guard !host.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry
    }
}

/// Minimal per-task delegate that answers a Basic/Digest/NTLM challenge with a
/// credential (first attempt only). Used where there's no streaming delegate —
/// e.g. `RangeProbe`'s `URLSession.data(for:delegate:)`. Non-auth challenges
/// (server trust) get default handling.
final class AuthChallengeResponder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let credential: URLCredential?
    init(credential: URLCredential?) { self.credential = credential }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let isServerAuth = method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM
        guard isServerAuth else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let credential, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
