import Foundation

@MainActor
final class NornProfileStore {
    private let defaults: UserDefaults
    private let profilesKey = "norn.serverProfiles.v1"
    private let selectionKey = "norn.selectedProfile.v1"
    private let durableIntentsKey = "norn.durableIntents.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProfiles() -> [NornServerProfile] {
        guard let data = defaults.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([NornServerProfile].self, from: data)
        else {
            return []
        }
        return profiles
    }

    func saveProfiles(_ profiles: [NornServerProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    func loadSelection() -> UUID? {
        guard let rawValue = defaults.string(forKey: selectionKey) else { return nil }
        return UUID(uuidString: rawValue)
    }

    func saveSelection(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectionKey)
    }

    func loadCursor(profileID: UUID) -> Int64? {
        guard defaults.object(forKey: cursorKey(profileID)) != nil else { return nil }
        return Int64(defaults.integer(forKey: cursorKey(profileID)))
    }

    func saveCursor(_ cursor: Int64, profileID: UUID) {
        defaults.set(cursor, forKey: cursorKey(profileID))
    }

    /// Stores only an opaque idempotency key and request digest. No credentials
    /// or request payloads are persisted. An interrupted mutation can therefore
    /// be retried safely after the app relaunches.
    func durableIntentKey(scope: String, requestDigest: String) -> String {
        var intents = defaults.dictionary(forKey: durableIntentsKey) as? [String: String] ?? [:]
        if let value = intents[scope] {
            let components = value.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            if components.count == 2, components[0] == requestDigest {
                return components[1]
            }
        }
        let key = "norn-macos-\(UUID().uuidString)"
        intents[scope] = "\(requestDigest)\u{1f}\(key)"
        defaults.set(intents, forKey: durableIntentsKey)
        return key
    }

    func clearDurableIntent(scope: String, key: String) {
        var intents = defaults.dictionary(forKey: durableIntentsKey) as? [String: String] ?? [:]
        guard intents[scope]?.hasSuffix("\u{1f}\(key)") == true else { return }
        intents.removeValue(forKey: scope)
        defaults.set(intents, forKey: durableIntentsKey)
    }

    private func cursorKey(_ id: UUID) -> String {
        "norn.eventCursor.v1.\(id.uuidString)"
    }
}
