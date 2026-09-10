import Foundation

nonisolated enum NornOverviewUpdateMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case manual
    case seconds5
    case seconds10
    case seconds30
    case minute1
    case minutes5
    case minutes10

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .manual: "Manual"
        case .seconds5: "Every 5 seconds"
        case .seconds10: "Every 10 seconds"
        case .seconds30: "Every 30 seconds"
        case .minute1: "Every minute"
        case .minutes5: "Every 5 minutes"
        case .minutes10: "Every 10 minutes"
        }
    }

    var shortTitle: String {
        switch self {
        case .live: "Live"
        case .manual: "Manual"
        case .seconds5: "5 sec"
        case .seconds10: "10 sec"
        case .seconds30: "30 sec"
        case .minute1: "1 min"
        case .minutes5: "5 min"
        case .minutes10: "10 min"
        }
    }

    var refreshInterval: TimeInterval? {
        switch self {
        case .live, .manual: nil
        case .seconds5: 5
        case .seconds10: 10
        case .seconds30: 30
        case .minute1: 60
        case .minutes5: 300
        case .minutes10: 600
        }
    }
}

@MainActor
final class NornProfileStore {
    private let defaults: UserDefaults
    private let profilesKey = "norn.serverProfiles.v1"
    private let selectionKey = "norn.selectedProfile.v1"
    private let durableIntentsKey = "norn.durableIntents.v1"
    private let hostMetricsRefreshKey = "norn.hostMetricsRefresh.v1"
    private let serviceMetricsCollectionKey = "norn.serviceMetricsCollection.v1"
    private let overviewUpdateModeKey = "norn.overviewUpdateMode.v1"

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

    func loadHostMetricsRefreshInterval() -> NornHostMetricsRefreshInterval {
        guard let value = defaults.object(forKey: hostMetricsRefreshKey) as? Int,
              let interval = NornHostMetricsRefreshInterval(rawValue: value)
        else { return .seconds10 }
        return interval
    }

    func saveHostMetricsRefreshInterval(_ interval: NornHostMetricsRefreshInterval) {
        defaults.set(interval.rawValue, forKey: hostMetricsRefreshKey)
    }

    func loadServiceMetricsCollectionEnabled() -> Bool {
        defaults.bool(forKey: serviceMetricsCollectionKey)
    }

    func saveServiceMetricsCollectionEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: serviceMetricsCollectionKey)
    }

    func loadOverviewUpdateMode() -> NornOverviewUpdateMode {
        guard let value = defaults.string(forKey: overviewUpdateModeKey),
              let mode = NornOverviewUpdateMode(rawValue: value)
        else { return .live }
        return mode
    }

    func saveOverviewUpdateMode(_ mode: NornOverviewUpdateMode) {
        defaults.set(mode.rawValue, forKey: overviewUpdateModeKey)
    }

    func loadHostMetricsHistory(profileID: UUID) -> [NornHostMetricSample] {
        guard let data = defaults.data(forKey: hostMetricsHistoryKey(profileID)),
              let samples = try? JSONDecoder().decode([NornHostMetricSample].self, from: data)
        else { return [] }
        return samples.sorted { $0.observedAt < $1.observedAt }
    }

    func saveHostMetricsHistory(_ samples: [NornHostMetricSample], profileID: UUID) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        defaults.set(data, forKey: hostMetricsHistoryKey(profileID))
    }

    func loadServiceMetricsHistory(profileID: UUID) -> [NornServiceMetricSample] {
        guard let data = defaults.data(forKey: serviceMetricsHistoryKey(profileID)),
              let samples = try? JSONDecoder().decode([NornServiceMetricSample].self, from: data)
        else { return [] }
        return samples.sorted { $0.observedAt < $1.observedAt }
    }

    func saveServiceMetricsHistory(_ samples: [NornServiceMetricSample], profileID: UUID) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        defaults.set(data, forKey: serviceMetricsHistoryKey(profileID))
    }

    func removeMetricsHistory(profileID: UUID) {
        defaults.removeObject(forKey: hostMetricsHistoryKey(profileID))
        defaults.removeObject(forKey: serviceMetricsHistoryKey(profileID))
    }

    private func cursorKey(_ id: UUID) -> String {
        "norn.eventCursor.v1.\(id.uuidString)"
    }

    private func hostMetricsHistoryKey(_ id: UUID) -> String {
        "norn.hostMetricsHistory.v1.\(id.uuidString)"
    }

    private func serviceMetricsHistoryKey(_ id: UUID) -> String {
        "norn.serviceMetricsHistory.v1.\(id.uuidString)"
    }
}
