import Foundation
import Observation

/// The UI must not show data fetched for a different authenticated server or
/// selected application. A context change invalidates outstanding work before
/// the next request starts, and each response must prove it still belongs here.
@MainActor
@Observable
final class ReleaseQualificationEvidenceLoader {
    private(set) var qualifications: [NornReleaseQualification] = []
    private(set) var isLoading = false
    private(set) var loadedContext: NornProfileAppContext?

    @ObservationIgnored private var context: NornProfileAppContext?
    @ObservationIgnored private var requestGeneration: UInt64 = 0

    func invalidate(for context: NornProfileAppContext) {
        requestGeneration &+= 1
        self.context = context
        qualifications = []
        loadedContext = nil
        isLoading = false
    }

    /// Performs the whole context transition in one operation. Callers must
    /// not separately invalidate from a SwiftUI modifier: modifier ordering
    /// could otherwise invalidate this replacement request after it starts.
    func reload(
        for requestedContext: NornProfileAppContext,
        operation: (String) async -> [NornReleaseQualification]
    ) async {
        invalidate(for: requestedContext)
        guard requestedContext.isActive else { return }

        let generation = requestGeneration
        let profileID = requestedContext.profileID
        let appID = requestedContext.appID
        isLoading = true
        let result = await operation(appID)

        guard !Task.isCancelled,
              requestGeneration == generation,
              context?.profileID == profileID,
              context?.appID == appID,
              context?.isActive == true else { return }
        qualifications = result
        loadedContext = requestedContext
        isLoading = false
    }
}

@MainActor
@Observable
final class AppRecoverySnapshotLoader {
    private(set) var snapshots: [NornAppSnapshot] = []
    private(set) var isLoading = false
    private(set) var loadedContext: NornProfileAppContext?

    @ObservationIgnored private var context: NornProfileAppContext?
    @ObservationIgnored private var requestGeneration: UInt64 = 0

    func invalidate(for context: NornProfileAppContext) {
        requestGeneration &+= 1
        self.context = context
        snapshots = []
        loadedContext = nil
        isLoading = false
    }

    /// Performs the whole context transition in one operation. See the
    /// qualification loader for why this is intentionally not split between
    /// an onChange invalidation and a task body.
    func reload(
        for requestedContext: NornProfileAppContext,
        operation: (String) async -> [NornAppSnapshot]?
    ) async {
        invalidate(for: requestedContext)
        guard requestedContext.isActive else { return }

        let generation = requestGeneration
        let profileID = requestedContext.profileID
        let appID = requestedContext.appID
        isLoading = true
        let result = await operation(appID)

        guard !Task.isCancelled,
              requestGeneration == generation,
              context?.profileID == profileID,
              context?.appID == appID,
              context?.isActive == true else { return }
        snapshots = result ?? []
        loadedContext = requestedContext
        isLoading = false
    }
}

struct NornProfileAppContext: Hashable {
    let profileID: UUID?
    let appID: String
    let isActive: Bool
}

enum NornReleaseAppSelection {
    static func normalized(_ selectedApp: String, in apps: [NornAppStatus]) -> String {
        guard apps.contains(where: { $0.id == selectedApp }) else { return apps.first?.id ?? "" }
        return selectedApp
    }
}

/// A mutation presentation belongs to the profile and UI context that opened
/// it. Settings-window profile changes can otherwise leave a visible A intent
/// whose callback dispatches through B's current client.
struct NornProfileBoundMutationGate<Intent> {
    struct Pending: Identifiable {
        let profileID: UUID?
        let intent: Intent
        let contextGeneration: UInt64

        var id: String { "\(profileID?.uuidString ?? "none"):\(contextGeneration)" }
    }

    private(set) var pending: Pending?
    private(set) var contextGeneration: UInt64 = 0

    mutating func present(
        _ intent: Intent,
        profileID: UUID?,
        isAuthorized: Bool
    ) {
        guard isAuthorized else { return }
        pending = .init(profileID: profileID, intent: intent, contextGeneration: contextGeneration)
    }

    mutating func invalidate() {
        contextGeneration &+= 1
        pending = nil
    }

    mutating func dismiss() {
        pending = nil
    }

    mutating func confirmedIntent(
        profileID: UUID?,
        isAuthorized: Bool,
        isStillCurrent: (Intent) -> Bool
    ) -> Intent? {
        defer { pending = nil }
        guard let pending,
              isAuthorized,
              pending.profileID == profileID,
              pending.contextGeneration == contextGeneration,
              isStillCurrent(pending.intent) else {
            return nil
        }
        return pending.intent
    }
}
