import Foundation
import Observation

/// Drives the username/password sheet shown when a download needs HTTP auth.
/// `AppEnvironment` wires `onSubmit` to store the credential and resume.
@MainActor
@Observable
final class AuthPromptModel {
    struct Request: Equatable {
        let downloadID: UUID
        let host: String
        let suggestedUser: String
    }

    var request: Request?
    var isPresented: Bool { request != nil }

    /// Called with the entered credentials and whether to persist them.
    var onSubmit: ((_ user: String, _ password: String, _ remember: Bool) -> Void)?

    func present(downloadID: UUID, host: String, suggestedUser: String) {
        // One prompt at a time; ignore additional requests while one is open.
        guard request == nil else { return }
        request = Request(downloadID: downloadID, host: host, suggestedUser: suggestedUser)
    }

    func submit(user: String, password: String, remember: Bool) {
        onSubmit?(user, password, remember)
        reset()
    }

    func cancel() { reset() }

    private func reset() {
        request = nil
        onSubmit = nil
    }
}
