import Foundation

/// User preferences for combining several internet links into one download.
///
/// Off by default: a tethered phone's data usually counts against a mobile plan,
/// so using it is always the user's explicit choice.
struct BondingSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// BSD names (e.g. "en7") the user switched off. Stored as the negative so a
    /// newly-plugged link is used by default once bonding is on.
    var disabledLinkIDs: Set<String> = []

    init(enabled: Bool = false, disabledLinkIDs: Set<String> = []) {
        self.enabled = enabled
        self.disabledLinkIDs = disabledLinkIDs
    }

    // Explicit so a partial `bonding` object decodes missing fields as defaults;
    // the synthesized decoder would throw keyNotFound and fail all of AppSettings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        disabledLinkIDs = try c.decodeIfPresent(Set<String>.self, forKey: .disabledLinkIDs) ?? []
    }

    func isLinkEnabled(_ id: String) -> Bool {
        !disabledLinkIDs.contains(id)
    }
}
