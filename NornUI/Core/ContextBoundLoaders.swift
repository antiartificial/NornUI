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

    func load(
        for requestedContext: NornProfileAppContext,
        operation: (String) async -> [NornReleaseQualification]
    ) async {
        if context != requestedContext { invalidate(for: requestedContext) }
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

    func load(
        for requestedContext: NornProfileAppContext,
        operation: (String) async -> [NornAppSnapshot]?
    ) async {
        if context != requestedContext { invalidate(for: requestedContext) }
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
