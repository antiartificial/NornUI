import Foundation

@MainActor
final class NornProfileStore {
    private let defaults: UserDefaults
    private let profilesKey = "norn.serverProfiles.v1"
    private let selectionKey = "norn.selectedProfile.v1"

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

    private func cursorKey(_ id: UUID) -> String {
        "norn.eventCursor.v1.\(id.uuidString)"
    }
}
