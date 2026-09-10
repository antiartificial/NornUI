import Foundation
import CryptoKit
import Observation

typealias NornClientFactory = @Sendable (NornServerProfile) async throws -> any NornClientProtocol

typealias NornEnrollmentClientFactory = @Sendable (URL) async throws -> any NornEnrollmentClientProtocol

nonisolated struct NornServiceSelection: Equatable, Sendable {
    let app: String
    let process: String
    let name: String

    init(service: NornService) {
        app = service.app
        process = service.process
        name = service.name
    }

    func matches(_ service: NornService) -> Bool {
        app == service.app && process == service.process && name == service.name
    }
}

/// A model-issued, single-connection authority lease for a user mutation.
/// Views obtain it synchronously before creating a Task; the model checks it
/// again immediately before every mutating client call.
nonisolated struct NornMutationContext: Hashable, Sendable {
    let profileID: UUID?
    fileprivate let connectionGeneration: UInt64
}

nonisolated private enum NornRefreshValue<Value: Sendable>: Sendable {
    case value(Value)
    case failure
    case unavailable
}

nonisolated private func captureRefreshValue<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> NornRefreshValue<Value> {
    do {
        return .value(try await operation())
    } catch {
        return .failure
    }
}

@MainActor
@Observable
final class NornAppModel {
    var navigation: NornNavigation = .overview
    var profiles: [NornServerProfile]
    var selectedProfileID: UUID?
    var connectionState: NornConnectionState = .idle
    var snapshot: NornDashboardSnapshot
    var hostMetrics: NornHostMetrics?
    var hostMetricsHistory: [NornHostMetricSample]
    var serviceMetricsHistory: [NornServiceMetricSample]
    /// Changes whenever chart inputs are replaced or appended, including when
    /// the count stays the same after a corrected aggregate arrives.
    var hostHistoryPresentationRevision: UInt64 = 0
    var hostMetricsRefreshInterval: NornHostMetricsRefreshInterval {
        didSet {
            profileStore.saveHostMetricsRefreshInterval(hostMetricsRefreshInterval)
            stopHostMetricsPolling()
            startHostMetricsPollingIfNeeded()
        }
    }
    var serviceMetricsCollectionEnabled: Bool {
        didSet {
            profileStore.saveServiceMetricsCollectionEnabled(serviceMetricsCollectionEnabled)
            if serviceMetricsCollectionEnabled {
                lastServiceMetricsRefreshAt = nil
                Task { [weak self] in await self?.refreshServiceMetricsIfNeeded(force: true) }
            }
        }
    }
    var overviewUpdateMode: NornOverviewUpdateMode {
        didSet {
            profileStore.saveOverviewUpdateMode(overviewUpdateMode)
            stopOverviewUpdating()
            startOverviewUpdatingIfNeeded()
            refreshDirtyOverviewIfNeeded()
        }
    }
    var fleetInventory: NornFleetInventory
    var fleetPlans: [NornOperation]
    var fleetReconciliations: [String: [NornOperation]] = [:]
    var fleetRunnerAttempts: [String: [NornFleetRunnerAttempt]] = [:]
    var fleetGitHubStatus: NornFleetGitHubStatus
    var deployments: [NornDeployment]
    var deploymentSteps: [String: [NornDeploymentStep]]
    var selectedDeploymentID: String?
    var activeDeploymentOperations: [NornOperation] = []
    var scalingRuntimeApps: Set<String> = []
    var runtimeScaleFeedback: [String: String] = [:]
    var activePlatformOperations: [NornOperation] = []
    var isDeploymentActivityRefreshing = false
    var deploymentActivityError: String?
    var deploymentStepLoadingIDs: Set<String> = []
    var deploymentStepErrors: [String: String] = [:]
    var isFleetRefreshing = false
    var selectedOperationID: String?
    var selectedAppName: String?
    var selectedService: NornServiceSelection?
    var isRefreshing = false
    var isShowingProfileEditor = false
	var isShowingCreateApp = false
    var lastError: String?
    var isFixtureMode: Bool

    @ObservationIgnored private let profileStore: NornProfileStore
    @ObservationIgnored private let clientFactory: NornClientFactory?
    @ObservationIgnored private let credentialVault: (any NornCredentialVault)?
    @ObservationIgnored private let deviceIdentityVault: (any NornDeviceIdentityVault)?
    @ObservationIgnored private let enrollmentClientFactory: NornEnrollmentClientFactory?
    @ObservationIgnored private var client: (any NornClientProtocol)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var hostMetricsTask: Task<Void, Never>?
    @ObservationIgnored private var deploymentActivityTask: Task<Void, Never>?
    @ObservationIgnored private var deploymentStepTask: Task<Void, Never>?
    @ObservationIgnored private var deploymentListTask: Task<[NornDeployment], Error>?
    @ObservationIgnored private var deploymentListTaskID: UUID?
    @ObservationIgnored private var deploymentStepRequestID: UUID?
    @ObservationIgnored private var deploymentActivityRequestID: UUID?
    @ObservationIgnored private var isDeploymentActivityVisible = false
    @ObservationIgnored private var fleetTask: Task<Void, Never>?
    @ObservationIgnored private var overviewRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var overviewEventRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var authoritativeRefreshTask: Task<String?, Error>?
    @ObservationIgnored private var authoritativeRefreshTaskID: UUID?
    @ObservationIgnored private var isFleetVisible = false
    @ObservationIgnored private var isOverviewVisible = false
    @ObservationIgnored private var isHostVisible = false
    @ObservationIgnored private var historyGeneration: UInt64 = 0
    @ObservationIgnored private var historyRequestGeneration: UInt64 = 0
    @ObservationIgnored private var metricsHistoryRevision: UInt64 = 0
    @ObservationIgnored private var isOverviewDirty = false
    @ObservationIgnored private var shouldRefreshAgain = false
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var authoritativeRefreshSequence: UInt64 = 0
    @ObservationIgnored private var eventMutationSequence: UInt64 = 0
    @ObservationIgnored private var eventMutatedOperationIDs: Set<String> = []
    @ObservationIgnored private var lastHostMetricsPersistenceAt: Date?
    @ObservationIgnored private var metricsPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var lastServiceMetricsRefreshAt: Date?
    @ObservationIgnored private var lastServiceMetricsPersistenceAt: Date?
    @ObservationIgnored private var serviceMetricsEndpointUnavailable = false

    init(
        profileStore: NornProfileStore? = nil,
        clientFactory: NornClientFactory? = nil,
        credentialVault: (any NornCredentialVault)? = nil,
        deviceIdentityVault: (any NornDeviceIdentityVault)? = nil,
        enrollmentClientFactory: NornEnrollmentClientFactory? = nil,
        fixture: NornDashboardSnapshot? = nil
    ) {
        let profileStore = profileStore ?? NornProfileStore()
        let storedProfiles = profileStore.loadProfiles()
        self.profileStore = profileStore
        self.clientFactory = clientFactory
        self.credentialVault = credentialVault
        self.deviceIdentityVault = deviceIdentityVault
        self.enrollmentClientFactory = enrollmentClientFactory
        self.profiles = storedProfiles
        self.selectedProfileID = profileStore.loadSelection()
        self.snapshot = fixture ?? Self.emptySnapshot
        self.hostMetrics = fixture != nil ? NornFixtures.hostMetrics : nil
        self.hostMetricsHistory = fixture != nil ? NornFixtures.hostMetricsHistory : []
        self.serviceMetricsHistory = fixture != nil ? NornFixtures.serviceMetricsHistory : []
        self.hostMetricsRefreshInterval = profileStore.loadHostMetricsRefreshInterval()
        self.serviceMetricsCollectionEnabled = fixture != nil || profileStore.loadServiceMetricsCollectionEnabled()
        self.overviewUpdateMode = profileStore.loadOverviewUpdateMode()
        self.fleetInventory = fixture != nil ? NornFixtures.fleetInventory : .unconfigured
        self.fleetPlans = []
        self.fleetGitHubStatus = fixture != nil ? .init(schemaVersion: "norn.fleet-github-status/v1", configured: true, connected: true, repository: "antiartificial/norn-fleet") : .unconfigured
        self.deployments = fixture != nil ? NornFixtures.deployments : []
        self.deploymentSteps = fixture != nil ? NornFixtures.deploymentSteps : [:]
        self.isFixtureMode = fixture != nil

        if selectedProfileID == nil {
            selectedProfileID = profiles.first?.id
        }
    }

    deinit {
        eventTask?.cancel()
        hostMetricsTask?.cancel()
        deploymentActivityTask?.cancel()
        deploymentStepTask?.cancel()
        deploymentListTask?.cancel()
        fleetTask?.cancel()
        overviewRefreshTask?.cancel()
        overviewEventRefreshTask?.cancel()
    }

    var selectedProfile: NornServerProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var selectedOperation: NornOperation? {
        snapshot.operations.first { $0.id == selectedOperationID }
    }

    var canPerformOperations: Bool {
        connectionState == .online && client != nil
    }

    /// Same-profile reconnect failures retain only profile-keyed evidence.
    /// Consumers use this to label it as stale; profile boundaries clear it.
    var hasStaleCachedConnectionState: Bool {
        guard !isFixtureMode else { return false }
        switch connectionState {
        case .reconnecting, .offline: return true
        case .idle, .connecting, .online: return false
        }
    }

    var isFleetAuthorityOnly: Bool { snapshot.capabilities.isFleetAuthorityOnly }
    var isServerAuthenticated: Bool { snapshot.capabilities.authenticatedPrincipal != nil }
    var assertedEnvironmentID: String? { snapshot.capabilities.assertedEnvironmentID }
    var assertedEnvironmentProfile: String? { snapshot.capabilities.assertedEnvironmentProfile }
    var assertedAuthority: String? { snapshot.capabilities.authority }

    var canReadRuntime: Bool { hasScope("api:read") && !isFleetAuthorityOnly }
    var canWriteRuntime: Bool { hasScope("api:write") && !isFleetAuthorityOnly }
    var canRunPlatformMaintenance: Bool { hasScope("platform:operate") && !isFleetAuthorityOnly }
    var canRunHostAssurance: Bool { hasScope("host:operate") && !isFleetAuthorityOnly }
    var canManageApps: Bool { canWriteRuntime && appCreationSupported }

    /// Capture this on the main actor before scheduling a mutation Task.
    func issueMutationContext() -> NornMutationContext {
        .init(profileID: selectedProfileID, connectionGeneration: connectionGeneration)
    }

    var availableNavigationDestinations: [NornNavigation] {
        isFleetAuthorityOnly ? [.overview, .fleet] : NornNavigation.allCases.filter { $0 != .activity }
    }

    func navigate(to destination: NornNavigation) {
        guard availableNavigationDestinations.contains(destination) else {
            lastError = "This server authority does not expose \(destination.title)."
            return
        }
        navigation = destination
    }

    func openService(_ service: NornService) {
        guard availableNavigationDestinations.contains(.apps) else { return }
        selectedAppName = service.app
        selectedService = NornServiceSelection(service: service)
        navigate(to: .apps)
    }

    func openOperation(_ operation: NornOperation) {
        guard availableNavigationDestinations.contains(.operations) else {
            lastError = "This server authority does not expose Operations."
            return
        }
        selectedOperationID = operation.id
        navigation = .operations
    }

    var hostMetricsSupported: Bool {
        snapshot.capabilities.supportsHostMetrics
    }

    var canManageAppRecovery: Bool {
        canWriteRuntime && durableAppRecoverySupported
    }

    /// Legacy release calls may create staging evidence only. Production
    /// promotion stays upstream CI-owned, even if an older server advertises
    /// the endpoint.
    var canReadLegacyReleaseEvidence: Bool { canReadRuntime && releasePipelineSupported }
    var canMutateLegacyReleaseEvidence: Bool { canWriteRuntime && releasePipelineSupported }

	var appCreationSupported: Bool { snapshot.capabilities.supportsAppCreation }
	var durableAppRecoverySupported: Bool { snapshot.capabilities.supportsDurableAppRecovery }
	var releasePipelineSupported: Bool { snapshot.capabilities.supportsReleasePipeline }
	var environmentID: String { snapshot.capabilities.environmentID }
	var environmentProfile: String { snapshot.capabilities.environmentProfile }

	func releaseQualifications(app: String) async -> [NornReleaseQualification] {
		guard let client, canReadLegacyReleaseEvidence else { return [] }
        let generation = connectionGeneration; let profileID = selectedProfileID
		do {
            let qualifications = try await client.releaseQualifications(app: app)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return [] }
            return qualifications
        }
		catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return [] }
			lastError = error.localizedDescription
			return []
		}
	}

	@discardableResult
	func preflightRelease(app: String, sourceSHA: String, artifact: String?, context: NornMutationContext) async -> NornOperation? {
		await queueRelease(app: app, kind: "preflight", sourceSHA: sourceSHA, artifact: artifact, context: context) { client, request, key in
			try await client.preflightRelease(app: app, request: request, idempotencyKey: key)
		}
	}

	@discardableResult
	func deployRelease(app: String, sourceSHA: String, artifact: String?, context: NornMutationContext) async -> NornOperation? {
		await queueRelease(app: app, kind: "deployment", sourceSHA: sourceSHA, artifact: artifact, context: context) { client, request, key in
			try await client.deployRelease(app: app, request: request, idempotencyKey: key)
		}
	}

	@discardableResult
	func qualifyRelease(app: String, deploymentID: String, context: NornMutationContext) async -> NornReleaseQualification? {
		guard let client, isValidMutationContext(context, permits: canMutateLegacyReleaseEvidence && environmentID == "staging") else { return nil }
		let generation = context.connectionGeneration; let profileID = context.profileID
		lastError = nil
		let intent = releaseIntent(app: app, kind: "qualification", values: [deploymentID])
		let idempotencyKey = profileStore.durableIntentKey(scope: intent.scope, requestDigest: intent.digest)
		do {
			let qualification = try await client.qualifyRelease(app: app, deploymentID: deploymentID, idempotencyKey: idempotencyKey)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			return qualification
		} catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			lastError = error.localizedDescription
			return nil
		}
	}

    func appLogs(for service: NornService) async -> String? {
        guard let client, canReadRuntime else { return nil }
        let generation = connectionGeneration; let profileID = selectedProfileID
        lastError = nil
        do {
            let logs = try await client.appLogs(app: service.app)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            return logs
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    func scaleAppRuntime(app appName: String, targets: [NornRuntimeScaleTarget], context: NornMutationContext) async {
        guard let client, isValidMutationContext(context, permits: canWriteRuntime),
              !scalingRuntimeApps.contains(appName),
              let app = snapshot.apps.first(where: { $0.id == appName }),
              NornRuntimeScaling.isValid(targets, for: app) else { return }
        guard !snapshot.operations.contains(where: { $0.app == appName && $0.status.isActive }) else {
            runtimeScaleFeedback[appName] = "Wait for this app’s current operation to finish before changing capacity."
            return
        }
        scalingRuntimeApps.insert(appName)
        runtimeScaleFeedback[appName] = "Applying runtime capacity…"
        defer {
            if isCurrentConnection(generation: context.connectionGeneration, profileID: context.profileID) {
                scalingRuntimeApps.remove(appName)
            }
        }
        var applied: [String] = []
        for target in targets {
            // A profile switch or revoked authority must stop the remaining requests.
            guard isValidMutationContext(context, permits: canWriteRuntime) else {
                if isCurrentConnection(generation: context.connectionGeneration, profileID: context.profileID) {
                    let prefix = applied.isEmpty ? "" : "Accepted: \(applied.joined(separator: ", ")). "
                    runtimeScaleFeedback[appName] = prefix + "Remaining updates stopped because this request no longer has authority. Check current allocations before continuing."
                }
                return
            }
            do {
                try await client.scaleApp(app: appName, process: target.process, count: target.count)
                applied.append("\(target.process) → \(target.count)")
            } catch {
                guard isCurrentConnection(generation: context.connectionGeneration, profileID: context.profileID) else { return }
                let prefix = applied.isEmpty ? "" : "Accepted: \(applied.joined(separator: ", ")). "
                runtimeScaleFeedback[appName] = prefix + "Could not confirm \(target.process). \(error.localizedDescription) Refresh and check current allocations before trying again."
                await refresh()
                return
            }
        }
        guard isCurrentConnection(generation: context.connectionGeneration, profileID: context.profileID) else { return }
        runtimeScaleFeedback[appName] = "Targets accepted: \(applied.joined(separator: ", ")). Allocations may still be changing."
        await refresh()
    }

    @discardableResult
    func restartAppAllocations(for service: NornService, context: NornMutationContext) async -> Bool {
        guard let client,
              isValidMutationContext(context, permits: canWriteRuntime),
              !service.isExpectedIdle,
              !["cron", "function"].contains(service.type.lowercased())
        else { return false }
        let generation = context.connectionGeneration; let profileID = context.profileID
        lastError = nil
        do {
            try await client.restartApp(app: service.app)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return false }
            await refresh()
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return false }
            return true
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

	@discardableResult
	func promoteRelease(app: String, qualification: NornReleaseQualification, context: NornMutationContext) async -> NornOperation? {
		guard isValidMutationContext(context, permits: canMutateLegacyReleaseEvidence && environmentID == "production"), !qualification.isExpired else { return nil }
        lastError = "Production promotion is upstream CI-owned and read-only in NornUI."
        return nil
	}

	private func queueRelease(
		app: String,
		kind: String,
		sourceSHA: String,
		artifact: String?,
		context: NornMutationContext,
		action: @escaping @Sendable (any NornClientProtocol, NornReleaseActionRequest, String) async throws -> NornOperation
	) async -> NornOperation? {
		guard let client, isValidMutationContext(context, permits: canMutateLegacyReleaseEvidence && environmentID == "staging") else { return nil }
		let generation = context.connectionGeneration; let profileID = context.profileID
		let normalizedSHA = sourceSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let trimmedArtifact = artifact?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let normalizedArtifact = trimmedArtifact.isEmpty ? nil : trimmedArtifact
		guard normalizedSHA.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
			lastError = "A release source must be an exact 40-character lowercase SHA."
			return nil
		}
		lastError = nil
		let intent = releaseIntent(app: app, kind: kind, values: [normalizedSHA, normalizedArtifact ?? ""])
		let idempotencyKey = profileStore.durableIntentKey(scope: intent.scope, requestDigest: intent.digest)
		do {
			let operation = try await action(client, .init(sourceSHA: normalizedSHA, artifact: normalizedArtifact), idempotencyKey)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			upsert(operation)
			return operation
		} catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			lastError = error.localizedDescription
			return nil
		}
	}

	private func releaseIntent(app: String, kind: String, values: [String]) -> (scope: String, digest: String) {
		let profile = selectedProfileID?.uuidString ?? "fixture"
		let canonical = ([profile, app, kind] + values).joined(separator: "\u{1f}")
		let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
		return ("release:\(profile):\(app):\(kind)", digest)
	}

	func appSnapshots(app: String) async -> [NornAppSnapshot]? {
		guard let client, canReadRuntime, durableAppRecoverySupported else { return nil }
		let generation = connectionGeneration; let profileID = selectedProfileID
		do {
            let snapshots = try await client.appSnapshots(app: app)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            return snapshots
        }
		catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			lastError = error.localizedDescription
			return nil
		}
	}

	@discardableResult
	func queueAppOperation(_ request: NornAppOperationRequest, context: NornMutationContext) async -> NornOperation? {
		guard let client, isValidMutationContext(context, permits: canManageAppRecovery) else { return nil }
		let generation = context.connectionGeneration; let profileID = context.profileID
		lastError = nil
		let intent = appOperationIntent(request)
		let idempotencyKey = profileStore.durableIntentKey(scope: intent.scope, requestDigest: intent.digest)
		do {
			let operation = try await client.queueAppOperation(request, idempotencyKey: idempotencyKey)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			upsert(operation)
			selectedOperationID = operation.id
			navigate(to: .operations)
			return operation
		} catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			lastError = error.localizedDescription
			return nil
		}
	}

	private func appOperationIntent(_ request: NornAppOperationRequest) -> (scope: String, digest: String) {
		let profile = selectedProfileID?.uuidString ?? "fixture"
		let kind: String
		let canonical: String
		switch request {
		case let .snapshot(app):
			kind = "snapshot"; canonical = app
		case let .pruneSnapshots(app, keep):
			kind = "snapshot-prune"; canonical = "\(app)\u{1f}\(keep)"
		case let .restoreSnapshot(app, snapshot):
			kind = "snapshot-restore"; canonical = "\(app)\u{1f}\(snapshot)"
		case let .migrate(app, ref):
			kind = "migrate"; canonical = "\(app)\u{1f}\(ref)"
		case let .rollback(app, regions):
			kind = "rollback"; canonical = "\(app)\u{1f}\(regions.joined(separator: ","))"
		}
		let digest = SHA256.hash(data: Data("\(profile)\u{1f}\(kind)\u{1f}\(canonical)".utf8))
			.map { String(format: "%02x", $0) }.joined()
		return ("\(profile):\(request.app):\(kind)", digest)
	}

    var fleetSupported: Bool { snapshot.capabilities.supportsFleet }
    var fleetReconciliationSupported: Bool { snapshot.capabilities.supportsFleetReconciliation }
    var fleetRunnerAttemptsSupported: Bool { snapshot.capabilities.supportsFleetRunnerAttempts }
    var fleetGitHubSupported: Bool { snapshot.capabilities.supportsFleetGitHub }
    var deploymentVisibilitySupported: Bool { snapshot.capabilities.supportsDeploymentVisibility }
    var canOperateFleet: Bool {
        guard canPerformOperations, isServerAuthenticated else { return false }
        return hasScope("api:write")
    }

	@discardableResult
	func createApp(_ request: NornCreateAppRequest, context: NornMutationContext) async -> NornAppMutationReceipt? {
		guard let client, isValidMutationContext(context, permits: canManageApps) else { return nil }
		let generation = context.connectionGeneration; let profileID = context.profileID
		lastError = nil
		do {
			let receipt = try await client.createApp(request)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			let refreshError = try await coalescedAuthoritativeRefresh(generation: generation, profileID: profileID, afterMutation: true)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			lastError = refreshError
			isShowingCreateApp = false
			navigate(to: .apps)
			return receipt
		} catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
			lastError = error.localizedDescription
			return nil
		}
	}

	func setAppDeployment(app: String, enabled: Bool, context: NornMutationContext) async {
		guard let client, isValidMutationContext(context, permits: canManageApps) else { return }
		let generation = context.connectionGeneration; let profileID = context.profileID
		lastError = nil
		do {
			_ = try await client.setAppDeployment(app: app, enabled: enabled)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
			let refreshError = try await coalescedAuthoritativeRefresh(generation: generation, profileID: profileID, afterMutation: true)
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
			lastError = refreshError
		} catch {
			guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
			lastError = error.localizedDescription
		}
	}

    func start() async {
        guard !isFixtureMode else {
            connectionState = .online
            return
        }
        guard !profiles.isEmpty, clientFactory != nil else {
            transitionConnectionState(to: .idle)
            return
        }
        await connect()
    }

    func connect() async {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        eventTask?.cancel()
        authoritativeRefreshTask?.cancel()
        authoritativeRefreshTask = nil
        authoritativeRefreshTaskID = nil
        stopOverviewUpdating()
        stopHostMetricsPolling()
        stopFleetPolling()
        stopDeploymentActivityPolling()
        client = nil
        clearConnectionScopedState()
        hostMetrics = nil
        invalidateHistoryLoading()
        lastHostMetricsPersistenceAt = nil
        lastServiceMetricsRefreshAt = nil
        lastServiceMetricsPersistenceAt = nil
        serviceMetricsEndpointUnavailable = false
        eventMutatedOperationIDs.removeAll()
        fleetReconciliations = [:]
        fleetRunnerAttempts = [:]
        guard let profile = selectedProfile, let clientFactory else {
            isFixtureMode = false
            connectionState = .idle
            return
        }

        connectionState = .connecting
        do {
            let nextClient = try await clientFactory(profile)
            guard isCurrentConnection(generation: generation, profileID: profile.id) else { return }
            client = nextClient
            try await rotateSelectedCredentialIfNeeded(force: false, context: issueMutationContext())
            guard isCurrentConnection(generation: generation, profileID: profile.id) else { return }
            isFixtureMode = false
            let refreshError = try await coalescedAuthoritativeRefresh(generation: generation, profileID: profile.id)
            guard isCurrentConnection(generation: generation, profileID: profile.id) else { return }
            lastError = refreshError
            if isFleetAuthorityOnly { navigate(to: .fleet) }
            connectionState = .online
            if snapshot.capabilities.supportsEventStream { listenForEvents(profile: profile, generation: generation) }
            startOverviewUpdatingIfNeeded()
            startHostMetricsPollingIfNeeded()
            startFleetPollingIfNeeded()
            startDeploymentActivityPollingIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profile.id) else { return }
            client = nil
            clearConnectionScopedState()
            connectionState = .offline(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard client != nil else {
            snapshot.observedAt = .now
            return
        }
        if isRefreshing {
            shouldRefreshAgain = true
            return
        }
        let generation = connectionGeneration
        let profileID = selectedProfileID
        isRefreshing = true
        defer {
            if isCurrentConnection(generation: generation, profileID: profileID) {
                isRefreshing = false
            }
        }
        repeat {
            shouldRefreshAgain = false
            do {
                let refreshError = try await coalescedAuthoritativeRefresh(generation: generation, profileID: profileID)
                guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
                lastError = refreshError
                connectionState = .online
                startOverviewUpdatingIfNeeded()
                startHostMetricsPollingIfNeeded()
                startFleetPollingIfNeeded()
                startDeploymentActivityPollingIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
                clearConnectionScopedState(preservingMetricsHistory: true)
                transitionConnectionState(to: .offline(error.localizedDescription))
                lastError = error.localizedDescription
                stopOverviewUpdating()
                stopHostMetricsPolling()
                stopFleetPolling()
                stopDeploymentActivityPolling()
                return
            }
        } while shouldRefreshAgain && isCurrentConnection(generation: generation, profileID: profileID)
    }

    /// Keeps Overview's optional refresh work scoped to the visible destination.
    /// Live mode is driven by the existing cursor-aware event stream; cadence
    /// modes use a bounded poller and Manual performs no background requests.
    func setOverviewVisible(_ isVisible: Bool) {
        isOverviewVisible = isVisible
        if isVisible {
            startOverviewUpdatingIfNeeded()
            refreshDirtyOverviewIfNeeded()
        } else {
            stopOverviewUpdating()
        }
    }

    func refreshHostMetrics(onlyWhileHostVisible: Bool = false) async {
        guard let client, connectionState == .online, hostMetricsSupported else { return }
        let generation = connectionGeneration
        let profileID = selectedProfileID
        do {
            let metrics = try await client.hostMetrics()
            guard !Task.isCancelled,
                  (!onlyWhileHostVisible || isHostVisible),
                  isCurrentConnection(generation: generation, profileID: profileID) else { return }
            hostMetrics = metrics
            recordHostMetrics(metrics)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  (!onlyWhileHostVisible || isHostVisible),
                  isCurrentConnection(generation: generation, profileID: profileID) else { return }
            // Preserve the most recent good sample. Host metrics are an optional
            // observational endpoint and must not take the whole UI offline.
            // A retained value is explicitly marked stale rather than displayed
            // as indefinitely current.
            hostMetrics?.stale = true
        }
    }

    /// Host refresh prioritizes the data visible on the Host screen. The full
    /// dashboard refresh is intentionally left to Overview's own lifecycle.
    func refreshHost() async {
        async let metrics: Void = refreshHostMetrics()
        async let context: Void = refreshHostContext()
        async let services: Void = refreshServiceMetricsIfNeeded(force: true)
        _ = await (metrics, context, services)
    }

    private func refreshHostContext() async {
        guard let client,
              connectionState == .online,
              isHostVisible,
              !isFleetAuthorityOnly else { return }
        let generation = connectionGeneration
        let profileID = selectedProfileID
        async let health: Void = applyHostHealth(client, generation: generation, profileID: profileID)
        async let hostStatus: Void = applyHostStatus(client, generation: generation, profileID: profileID)
        async let manifest: Void = applyHostManifest(client, generation: generation, profileID: profileID)
        _ = await (health, hostStatus, manifest)
    }

    private func applyHostHealth(_ client: any NornClientProtocol, generation: UInt64, profileID: UUID?) async {
        guard let value = try? await client.health(),
              isHostVisible,
              isCurrentConnection(generation: generation, profileID: profileID) else { return }
        snapshot.health = value
        snapshot.observedAt = .now
    }

    private func applyHostManifest(_ client: any NornClientProtocol, generation: UInt64, profileID: UUID?) async {
        guard let value = try? await client.serviceManifest(),
              isHostVisible,
              isCurrentConnection(generation: generation, profileID: profileID) else { return }
        snapshot.services = value.services
        snapshot.observedAt = .now
    }

    private func applyHostStatus(_ client: any NornClientProtocol, generation: UInt64, profileID: UUID?) async {
        guard let value = try? await client.hostStatus(),
              isHostVisible,
              isCurrentConnection(generation: generation, profileID: profileID) else { return }
        snapshot.health.status = value.status
        snapshot.health.services.merge(value.services) { _, current in current }
        if let assurance = value.latestAssurance { upsert(assurance) }
        snapshot.observedAt = .now
    }

    /// Flushes live samples without replacing older persisted ranges that have
    /// not been requested by the Host view yet.
    func persistMetricsHistory() async {
        guard let profileID = selectedProfile?.id else { return }
        await persistMetricsHistory(profileID: profileID)
    }

    private func persistMetricsHistory(profileID: UUID) async {
        guard !isFixtureMode else { return }
        // Capture before awaiting an older write: by the time this task runs,
        // the selected profile may have changed.
        let hostAdditions = hostMetricsHistory
        let serviceCollectionEnabled = serviceMetricsCollectionEnabled
        let serviceAdditions = serviceCollectionEnabled ? serviceMetricsHistory : []
        await persistMetricsHistory(
            profileID: profileID,
            hostAdditions: hostAdditions,
            serviceAdditions: serviceAdditions,
            serviceCollectionEnabled: serviceCollectionEnabled
        )
    }

    private func persistMetricsHistory(
        profileID: UUID,
        hostAdditions: [NornHostMetricSample],
        serviceAdditions: [NornServiceMetricSample],
        serviceCollectionEnabled: Bool
    ) async {
        let previousTask = metricsPersistenceTask
        let task = Task { [weak self] in
            await previousTask?.value
            await self?.writeMetricsHistory(
                profileID: profileID,
                hostAdditions: hostAdditions,
                serviceAdditions: serviceAdditions,
                serviceCollectionEnabled: serviceCollectionEnabled
            )
        }
        metricsPersistenceTask = task
        await task.value
    }

    /// Capture on the main actor before scheduling a fire-and-forget flush.
    /// A profile switch can otherwise make the task persist the replacement
    /// profile's arrays under the previous profile's key.
    private func scheduleMetricsHistoryPersistence(profileID: UUID) {
        guard !isFixtureMode else { return }
        let hostAdditions = hostMetricsHistory
        let serviceCollectionEnabled = serviceMetricsCollectionEnabled
        let serviceAdditions = serviceCollectionEnabled ? serviceMetricsHistory : []
        Task { [weak self] in
            await self?.persistMetricsHistory(
                profileID: profileID,
                hostAdditions: hostAdditions,
                serviceAdditions: serviceAdditions,
                serviceCollectionEnabled: serviceCollectionEnabled
            )
        }
    }

    private func writeMetricsHistory(
        profileID: UUID,
        hostAdditions: [NornHostMetricSample],
        serviceAdditions: [NornServiceMetricSample],
        serviceCollectionEnabled: Bool
    ) async {
        let hostData = profileStore.hostMetricsHistoryData(profileID: profileID)
        let serviceData = serviceCollectionEnabled
            ? profileStore.serviceMetricsHistoryData(profileID: profileID)
            : nil
        let encoded = await Task.detached(priority: .utility) {
            NornMetricsHistoryCodec.mergeAndEncode(
                hostData: hostData,
                serviceData: serviceData,
                hostAdditions: hostAdditions,
                serviceAdditions: serviceAdditions,
                endingAt: .now
            )
        }.value
        // A removed profile must not be recreated by a delayed persistence task.
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        if let hostData = encoded.hostData {
            profileStore.saveHostMetricsHistoryData(hostData, profileID: profileID)
        }
        if serviceCollectionEnabled, let serviceData = encoded.serviceData {
            profileStore.saveServiceMetricsHistoryData(serviceData, profileID: profileID)
        }
        lastHostMetricsPersistenceAt = .now
        lastServiceMetricsPersistenceAt = .now
    }

    /// Starts and stops Host-only network and disk work. Event processing stays
    /// connected globally; metrics collection and history decoding do not.
    func setHostVisible(_ isVisible: Bool) {
        setHostVisible(isVisible, profileID: selectedProfileID)
    }

    /// `profileID` is captured by the Host view. It prevents a disappearing
    /// view for profile A from stopping work after profile B has replaced it.
    func setHostVisible(_ isVisible: Bool, profileID: UUID?) {
        guard profileID == selectedProfileID else { return }
        isHostVisible = isVisible
        if isVisible {
            startHostMetricsPollingIfNeeded()
        } else {
            stopHostMetricsPolling()
            historyRequestGeneration &+= 1
        }
    }

    /// Loads only the range requested by the chart. The persisted payload is
    /// decoded and compacted on a utility executor, then merged on the main
    /// actor only if this profile and Host presentation are still current.
    func requestMetricsHistory(
        window: NornHostMetricsWindow,
        endingAt: Date = .now
    ) async {
        guard !isFixtureMode,
              isHostVisible,
              let profileID = selectedProfile?.id else { return }
        let generation = historyGeneration
        historyRequestGeneration &+= 1
        let requestGeneration = historyRequestGeneration
        let hostData = profileStore.hostMetricsHistoryData(profileID: profileID)
        let serviceData = serviceMetricsCollectionEnabled
            ? profileStore.serviceMetricsHistoryData(profileID: profileID)
            : nil
        let loadTask = Task.detached(priority: .utility) {
            NornMetricsHistoryCodec.load(
                hostData: hostData,
                serviceData: serviceData,
                window: window,
                endingAt: endingAt
            )
        }
        let loaded = await withTaskCancellationHandler(
            operation: { await loadTask.value },
            onCancel: { loadTask.cancel() }
        )
        guard !Task.isCancelled,
              isHostVisible,
              historyGeneration == generation,
              historyRequestGeneration == requestGeneration,
              selectedProfileID == profileID else { return }
        // Fresh live samples may have arrived while the persisted blob decoded.
        // Merge against the current cache, not the snapshot captured at launch.
        var currentHost = hostMetricsHistory
        var currentService = serviceMetricsHistory
        var currentRevision = metricsHistoryRevision
        var result: (host: [NornHostMetricSample], service: [NornServiceMetricSample])
        while true {
            let mergeTask = Task.detached(priority: .utility) {
                (
                    host: NornMetricsHistoryCodec.mergedHost(currentHost, loaded.host),
                    service: NornMetricsHistoryCodec.mergedService(currentService, loaded.service)
                )
            }
            result = await withTaskCancellationHandler(
                operation: { await mergeTask.value },
                onCancel: { mergeTask.cancel() }
            )
            guard metricsHistoryRevision != currentRevision else { break }
            guard !Task.isCancelled else { return }
            currentHost = hostMetricsHistory
            currentService = serviceMetricsHistory
            currentRevision = metricsHistoryRevision
        }
        guard !Task.isCancelled,
              isHostVisible,
              historyGeneration == generation,
              historyRequestGeneration == requestGeneration,
              selectedProfileID == profileID else { return }
        hostMetricsHistory = result.host
        serviceMetricsHistory = result.service
        hostHistoryPresentationRevision &+= 1
    }

    func setFleetVisible(_ isVisible: Bool) {
        isFleetVisible = isVisible
        if isVisible {
            startFleetPollingIfNeeded()
        } else {
            stopFleetPolling()
        }
    }

    func refreshFleet() async {
        guard let client, connectionState == .online, fleetSupported else { return }
        let generation = connectionGeneration
        let profileID = selectedProfileID
        isFleetRefreshing = true
        defer {
            if isCurrentConnection(generation: generation, profileID: profileID) {
                isFleetRefreshing = false
            }
        }
        do {
            async let inventory = client.fleetInventory()
            async let plans = client.fleetPlans()
            async let githubStatus: NornFleetGitHubStatus = fleetGitHubSupported ? client.fleetGitHubStatus() : .unconfigured
            let refreshedInventory = try await inventory
            let refreshedPlans = try await plans
            let refreshedGitHubStatus = try await githubStatus
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            fleetInventory = refreshedInventory
            fleetPlans = refreshedPlans
            fleetGitHubStatus = refreshedGitHubStatus
            for plan in fleetPlans where fleetReconciliationSupported {
                if let result = try? await client.fleetReconciliations(planID: plan.id) {
                    guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
                    fleetReconciliations[plan.id] = result.reconciliations
                }
            }
            for plan in fleetPlans where fleetRunnerAttemptsSupported {
                if let result = try? await client.fleetRunnerAttempts(planID: plan.id) {
                    guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
                    fleetRunnerAttempts[plan.id] = result.attempts
                }
            }
            if !isFleetAuthorityOnly {
                await refreshDeploymentVisibility(
                    using: client,
                    expectedGeneration: generation,
                    expectedProfileID: profileID
                )
            }
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            clearFleetAndDeploymentState()
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func createFleetPullRequest(planID: String, context: NornMutationContext) async -> URL? {
        guard let client, isValidMutationContext(context, permits: canOperateFleet && fleetGitHubSupported && fleetGitHubStatus.connected) else { return nil }
        let generation = context.connectionGeneration; let profileID = context.profileID
        lastError = nil
        do {
            let operation = try await client.createFleetPullRequest(planID: planID)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            upsert(operation)
            return operation.payload?["url"]?.stringValue.flatMap(URL.init(string:))
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func dispatchFleetApply(planID: String, allowDestructive: Bool, context: NornMutationContext) async -> URL? {
        guard let client, isValidMutationContext(context, permits: canOperateFleet && fleetGitHubSupported && fleetGitHubStatus.connected) else { return nil }
        let generation = context.connectionGeneration; let profileID = context.profileID
        lastError = nil
        do {
            let operation = try await client.dispatchFleetApply(planID: planID, allowDestructive: allowDestructive)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            upsert(operation)
            return operation.payload?["url"]?.stringValue.flatMap(URL.init(string:))
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func planFleetCapacity(pool: String, desired: Int, size: String, reason: String, context: NornMutationContext) async -> NornOperation? {
        guard let client, isValidMutationContext(context, permits: canOperateFleet) else { return nil }
        let generation = context.connectionGeneration; let profileID = context.profileID
        guard let current = fleetInventory.nodePools[pool] else {
            lastError = "The selected fleet pool is no longer available."
            return nil
        }
        lastError = nil
        do {
            let request = NornFleetPlanRequest(
                desired: desired,
                size: size.trimmingCharacters(in: .whitespacesAndNewlines),
                strategy: size == current.size ? nil : "blueGreen",
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let operation = try await client.planFleetCapacity(
                pool: pool,
                request: request,
                idempotencyKey: fleetPlanIdempotencyKey(pool: pool, request: request)
            )
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            fleetPlans.removeAll { $0.id == operation.id }
            fleetPlans.insert(operation, at: 0)
            if fleetReconciliationSupported {
                fleetReconciliations[operation.id] = []
            }
            if fleetRunnerAttemptsSupported {
                fleetRunnerAttempts[operation.id] = []
            }
            return operation
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    /// A retry after a process, network, or runner interruption must identify the
    /// same intent. The fleet document digest changes after a successful apply,
    /// so an identical future change against new desired state receives a new key.
    private func fleetPlanIdempotencyKey(pool: String, request: NornFleetPlanRequest) -> String {
        let canonical = [
            selectedProfileID?.uuidString ?? "fixture",
            fleetInventory.digest ?? "unversioned",
            pool,
            String(request.desired),
            request.size,
            request.strategy ?? "",
            request.reason
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "fleet-plan-\(digest)"
    }

    @discardableResult
    func queue(_ request: NornMaintenanceRequest, context: NornMutationContext) async -> NornOperation? {
        guard let client, isValidMutationContext(context, permits: mayQueue(request)) else { return nil }
        let generation = context.connectionGeneration; let profileID = context.profileID
        lastError = nil
        do {
            let operation = try await client.queue(request, idempotencyKey: UUID().uuidString)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            upsert(operation)
            selectedOperationID = operation.id
            navigate(to: .operations)
            connectionState = .online
            return operation
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    func addProfile(_ profile: NornServerProfile) {
        if let previousID = selectedProfileID, previousID != profile.id {
            scheduleMetricsHistoryPersistence(profileID: previousID)
        }
        invalidateHistoryLoading()
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        selectedProfileID = profile.id
        persistProfiles()
    }

    func saveProfile(_ profile: NornServerProfile, token: String) async throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = profile
        if !trimmedToken.isEmpty {
            guard let credentialVault else { throw NornCredentialVaultError.invalidCredential }
            try await credentialVault.store(
                NornCredential(accessToken: trimmedToken),
                for: profile.credentialID
            )
            profile.deviceID = nil
            profile.tokenID = nil
            profile.grantedScopes = nil
            profile.tokenExpiresAt = nil
            profile.lastRotatedAt = nil
        }
        addProfile(profile)
        await selectProfile(id: profile.id)
    }

    func startDeviceEnrollment(
        profile: NornServerProfile,
        requestedScopes: [String]
    ) async throws -> (NornEnrollmentSession, NornDeviceIdentityProtection) {
        guard let enrollmentClientFactory, let deviceIdentityVault else {
            throw NornEnrollmentClientError.invalidResponse
        }
        let scopes = Array(Set(requestedScopes)).sorted()
        guard !scopes.isEmpty, !scopes.contains("admin") else {
            throw NornEnrollmentClientError.invalidResponse
        }
        let identity = try await deviceIdentityVault.identity(for: profile.credentialID)
        let client = try await enrollmentClientFactory(profile.baseURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let localName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = String((localName.flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.hostName).prefix(120))
        let enrollment = try await client.start(NornEnrollmentStartRequest(
            deviceName: deviceName,
            platform: "macOS",
            model: "Mac",
            appVersion: version,
            publicKey: identity.publicKey,
            requestedScopes: scopes
        ))
        return (enrollment, identity.protection)
    }

    func discoverEnrollmentCapabilities(profile: NornServerProfile) async throws -> NornCapabilities {
        guard let enrollmentClientFactory else { throw NornEnrollmentClientError.invalidResponse }
        return try await enrollmentClientFactory(profile.baseURL).capabilities()
    }

    func completeDeviceEnrollment(
        profile: NornServerProfile,
        enrollment: NornEnrollmentSession
    ) async throws {
        guard let enrollmentClientFactory, let credentialVault else {
            throw NornEnrollmentClientError.invalidResponse
        }
        let client = try await enrollmentClientFactory(profile.baseURL)
        let issued = try await client.exchange(enrollment)
        try await credentialVault.store(
            NornCredential(accessToken: issued.token),
            for: profile.credentialID
        )
        var managed = profile
        managed.deviceID = issued.deviceID
        managed.tokenID = issued.tokenID
        managed.grantedScopes = issued.scopes.sorted()
        managed.tokenExpiresAt = issued.expiresAt
        managed.lastRotatedAt = .now
        addProfile(managed)
        await selectProfile(id: managed.id)
    }

    func rotateManagedCredentialNow(context: NornMutationContext) async {
        guard isValidMutationContext(context, permits: selectedProfile?.isManagedDevice == true, requiresClient: false) else { return }
        let generation = context.connectionGeneration
        let profileID = context.profileID
        eventTask?.cancel()
        do {
            if client == nil, let profile = selectedProfile, let clientFactory {
                let refreshedClient = try await clientFactory(profile)
                guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
                client = refreshedClient
            }
            try await rotateSelectedCredentialIfNeeded(force: true, context: context)
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            await connect()
        } catch {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            transitionConnectionState(to: .offline(error.localizedDescription))
            lastError = error.localizedDescription
        }
    }

    func refreshManagedCredentialIfNeeded() async {
        guard shouldRotate(selectedProfile, force: false) else { return }
        await connect()
    }

    func removeProfile(id: UUID) {
        let wasSelected = selectedProfileID == id
        if wasSelected {
            connectionGeneration &+= 1
            eventTask?.cancel()
            stopOverviewUpdating()
            stopHostMetricsPolling()
            stopFleetPolling()
            stopDeploymentActivityPolling()
            client = nil
            clearConnectionScopedState()
            connectionState = .idle
        }
        profiles.removeAll { $0.id == id }
        if wasSelected {
            selectedProfileID = profiles.first?.id
            invalidateHistoryLoading()
            lastHostMetricsPersistenceAt = nil
            lastServiceMetricsRefreshAt = nil
            lastServiceMetricsPersistenceAt = nil
            serviceMetricsEndpointUnavailable = false
        }
        profileStore.removeMetricsHistory(profileID: id)
        persistProfiles()
    }

    func removeProfileAndCredential(id: UUID) async {
        let profile = profiles.first { $0.id == id }
        let wasSelected = selectedProfileID == id
        removeProfile(id: id)
        if let profile, let credentialVault {
            try? await credentialVault.removeCredential(for: profile.credentialID)
        }
        if let profile, let deviceIdentityVault {
            try? await deviceIdentityVault.removeIdentity(for: profile.credentialID)
        }
        if wasSelected {
            await connect()
        }
    }

    func selectProfile(id: UUID?) async {
        let previousID = selectedProfileID
        let hostAdditions = hostMetricsHistory
        let serviceCollectionEnabled = serviceMetricsCollectionEnabled
        let serviceAdditions = serviceCollectionEnabled ? serviceMetricsHistory : []
        // Invalidate every in-flight response before changing the profile ID.
        // This closes the tiny gap between selection and connect() setup.
        connectionGeneration &+= 1
        invalidateHistoryLoading()
        eventTask?.cancel()
        stopHostMetricsPolling()
        stopFleetPolling()
        stopDeploymentActivityPolling()
        client = nil
        clearConnectionScopedState()
        stopOverviewUpdating()
        selectedProfileID = id
        profileStore.saveSelection(id)
        if let previousID, previousID != id {
            await persistMetricsHistory(
                profileID: previousID,
                hostAdditions: hostAdditions,
                serviceAdditions: serviceAdditions,
                serviceCollectionEnabled: serviceCollectionEnabled
            )
        }
        await connect()
    }

    private func persistProfiles() {
        profileStore.saveProfiles(profiles)
        profileStore.saveSelection(selectedProfileID)
    }

    private func rotateSelectedCredentialIfNeeded(force: Bool, context: NornMutationContext) async throws {
        guard let profile = selectedProfile,
              shouldRotate(profile, force: force),
              let client,
              isValidMutationContext(context, permits: profile.isManagedDevice) else { return }
        let generation = context.connectionGeneration
        let profileID = context.profileID
        let issued = try await client.rotateCredential()
        guard isCurrentConnection(generation: generation, profileID: profileID), profile.id == profileID else {
            throw CancellationError()
        }
        var updated = profile
        updated.deviceID = issued.deviceID
        updated.tokenID = issued.tokenID
        updated.grantedScopes = issued.scopes.sorted()
        updated.tokenExpiresAt = issued.expiresAt
        updated.lastRotatedAt = .now
        profiles.removeAll { $0.id == updated.id }
        profiles.append(updated)
        persistProfiles()
    }

    private func shouldRotate(_ profile: NornServerProfile?, force: Bool) -> Bool {
        guard let profile, profile.isManagedDevice else { return false }
        if force { return true }
        guard let expiresAt = profile.tokenExpiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= 7 * 24 * 60 * 60
    }

    private func refreshAuthoritativeState(
        generation: UInt64? = nil,
        profileID: UUID? = nil
    ) async throws -> String? {
        guard let client else { return nil }
        authoritativeRefreshSequence &+= 1
        let refreshSequence = authoritativeRefreshSequence
        let startingEventSequence = eventMutationSequence
        let expectedGeneration = generation ?? connectionGeneration
        let expectedProfileID = profileID ?? selectedProfileID
        let capabilities = try await client.capabilities()
        try validateCurrentRefresh(
            refreshSequence,
            generation: expectedGeneration,
            profileID: expectedProfileID
        )
        let authorityOnly = capabilities.isFleetAuthorityOnly
        async let healthResult: NornRefreshValue<NornHealth> = authorityOnly ? .unavailable : captureRefreshValue { try await client.health() }
        async let hostStatusResult: NornRefreshValue<NornHostStatus> = authorityOnly ? .unavailable : captureRefreshValue { try await client.hostStatus() }
        async let manifestResult: NornRefreshValue<NornServiceManifest> = authorityOnly ? .unavailable : captureRefreshValue { try await client.serviceManifest() }
		async let appsResult: NornRefreshValue<[NornAppStatus]> = authorityOnly ? .unavailable : captureRefreshValue { try await client.apps() }
        let authorityOperationsAvailable = capabilities.endpoints["operationList"] != nil
        async let operationsResult: NornRefreshValue<[NornOperation]> = authorityOnly && !authorityOperationsAvailable ? .unavailable : captureRefreshValue { try await client.operations(activeOnly: false, limit: 100) }
        async let releasesResult: NornRefreshValue<NornReleaseList> = authorityOnly ? .unavailable : captureRefreshValue { try await client.releases() }
        async let fleetInventoryResult = captureRefreshValue {
            capabilities.supportsFleet ? try await client.fleetInventory() : .unconfigured
        }
        async let fleetPlansResult = captureRefreshValue {
            capabilities.supportsFleet ? try await client.fleetPlans() : []
        }
        async let fleetGitHubResult = captureRefreshValue {
            capabilities.supportsFleetGitHub ? try await client.fleetGitHubStatus() : .unconfigured
        }

        let result = await (
            healthResult,
            hostStatusResult,
            manifestResult,
            operationsResult,
            releasesResult,
            appsResult,
            fleetInventoryResult,
            fleetPlansResult,
            fleetGitHubResult
        )
        try validateCurrentRefresh(
            refreshSequence,
            generation: expectedGeneration,
            profileID: expectedProfileID
        )
        let eventOperationIDs = eventMutatedOperationIDs
        let eventOperations = snapshot.operations.filter { eventOperationIDs.contains($0.id) }
        var failures: [String] = []
        // Begin from an empty snapshot on every authoritative refresh. A
        // partially failed request may omit information, but it must never
        // inherit it from a different server profile.
        var next = Self.emptySnapshot
        next.capabilities = capabilities
        next.observedAt = .now

        switch result.0 {
        case let .value(health): next.health = health
        case .failure: failures.append("health")
        case .unavailable: break
        }
        switch result.2 {
        case let .value(manifest): next.services = manifest.services
        case .failure: failures.append("services")
        case .unavailable: next.services = []
        }
        switch result.3 {
        case let .value(operations):
            next.operations = operations
            for operation in eventOperations {
                if let index = next.operations.firstIndex(where: { $0.id == operation.id }) {
                    if operation.updatedAt > next.operations[index].updatedAt {
                        next.operations[index] = operation
                    }
                } else {
                    next.operations.append(operation)
                }
            }
            next.operations.sort { $0.updatedAt > $1.updatedAt }
        case .failure: failures.append("operations")
        case .unavailable: next.operations = []
        }
        switch result.4 {
        case let .value(releases): next.releases = NornRelease.canonicalHistory(releases.releases)
        case .failure: failures.append("releases")
        case .unavailable: next.releases = []
        }
        switch result.5 {
		case let .value(apps): next.apps = apps
        case .failure: failures.append("apps")
        case .unavailable: next.apps = []
        }

        // Host status is its own versioned resource. Merge its latest receipt
        // after the bounded general history so assurance never appears stale
        // merely because it fell outside the first operation page.
        switch result.1 {
        case let .value(hostStatus):
            next.health.status = hostStatus.status
            next.health.services.merge(hostStatus.services) { _, current in current }
            if let assurance = hostStatus.latestAssurance {
                next.operations.removeAll { $0.id == assurance.id }
                next.operations.append(assurance)
                next.operations.sort { $0.updatedAt > $1.updatedAt }
            }
        case .failure:
            if capabilities.endpoints["hostStatus"] != nil {
                failures.append("host assurance")
            }
        case .unavailable: break
        }
        snapshot = next
        eventMutatedOperationIDs.subtract(eventOperationIDs)
        reconcileNavigationSelections()

        switch result.6 {
        case let .value(inventory): fleetInventory = inventory
        case .failure:
            fleetInventory = .unconfigured
            failures.append("fleet inventory")
        case .unavailable: break
        }
        switch result.7 {
        case let .value(plans): fleetPlans = plans
        case .failure:
            fleetPlans = []
            fleetReconciliations = [:]
            fleetRunnerAttempts = [:]
            failures.append("fleet plans")
        case .unavailable: break
        }
        switch result.8 {
        case let .value(status): fleetGitHubStatus = status
        case .failure:
            fleetGitHubStatus = .unconfigured
            failures.append("fleet GitHub status")
        case .unavailable: break
        }
        if !authorityOnly {
            await refreshDeploymentVisibility(
                using: client,
                expectedGeneration: expectedGeneration,
                expectedProfileID: expectedProfileID,
                expectedRefreshSequence: refreshSequence
            )
        } else {
            deployments = []
            deploymentSteps = [:]
        }
        try validateCurrentRefresh(
            refreshSequence,
            generation: expectedGeneration,
            profileID: expectedProfileID
        )
        isOverviewDirty = eventMutationSequence != startingEventSequence
        if isOverviewDirty { scheduleLiveOverviewRefresh() }
        guard !failures.isEmpty else { return nil }
        return "Connected, but \(failures.joined(separator: ", ")) could not refresh. Other sections are current."
    }

    private func reconcileNavigationSelections() {
        if let selectedService,
           !snapshot.services.contains(where: selectedService.matches) {
            self.selectedService = nil
        }
    }

    /// Apps and Delivery share one bounded, visibility-scoped refresh loop.
    func setDeploymentActivityVisible(_ isVisible: Bool, profileID: UUID?) {
        guard profileID == selectedProfileID else { return }
        isDeploymentActivityVisible = isVisible
        if isVisible {
            startDeploymentActivityPollingIfNeeded()
            selectDeployment(id: selectedDeploymentID)
        } else {
            stopDeploymentActivityPolling()
        }
    }

    func selectDeployment(id: String?) {
        selectedDeploymentID = id
        deploymentStepTask?.cancel()
        deploymentStepRequestID = nil
        deploymentStepLoadingIDs.removeAll()
        guard let id, navigation != .overview, isDeploymentActivityVisible, connectionState == .online,
              !isFixtureMode, snapshot.capabilities.supportsDeploymentVisibility else { return }
        let generation = connectionGeneration
        let profileID = selectedProfileID
        deploymentStepTask = Task { [weak self] in
            await self?.loadDeploymentSteps(id: id, generation: generation, profileID: profileID)
        }
    }

    private func loadDeploymentSteps(id: String, generation: UInt64, profileID: UUID?) async {
        guard let client, isDeploymentActivityVisible,
              isCurrentConnection(generation: generation, profileID: profileID) else { return }
        let requestID = UUID()
        deploymentStepRequestID = requestID
        deploymentStepLoadingIDs.insert(id)
        defer {
            if deploymentStepRequestID == requestID {
                deploymentStepLoadingIDs.remove(id)
                deploymentStepRequestID = nil
            }
        }
        do {
            let steps = try await client.deploymentSteps(deploymentID: id)
            guard !Task.isCancelled, deploymentStepRequestID == requestID,
                  selectedDeploymentID == id, isDeploymentActivityVisible,
                  isCurrentConnection(generation: generation, profileID: profileID) else { return }
            deploymentSteps[id] = steps
            deploymentStepErrors[id] = nil
        } catch {
            guard !Task.isCancelled, deploymentStepRequestID == requestID,
                  isCurrentConnection(generation: generation, profileID: profileID) else { return }
            deploymentStepErrors[id] = error.localizedDescription
        }
    }

    func refreshDeploymentActivity() async {
        guard let client, isDeploymentActivityVisible, !isFleetAuthorityOnly,
              connectionState == .online, deploymentActivityRequestID == nil else { return }
        let generation = connectionGeneration
        let profileID = selectedProfileID
        let requestID = UUID()
        deploymentActivityRequestID = requestID
        isDeploymentActivityRefreshing = true
        defer {
            if deploymentActivityRequestID == requestID {
                deploymentActivityRequestID = nil
                isDeploymentActivityRefreshing = false
            }
        }
        async let apps = captureRefreshValue { try await client.apps() }
        async let operations = captureRefreshValue { try await client.operations(activeOnly: false, limit: 100) }
        async let active = captureRefreshValue { try await client.operations(activeOnly: true, limit: 100) }
        async let services = captureRefreshValue { try await client.serviceManifest() }
        async let listing: Void = refreshDeploymentVisibility(using: client, expectedGeneration: generation, expectedProfileID: profileID, expectedActivityRequestID: requestID)
        let result = await (apps, operations, active, services, listing)
        guard !Task.isCancelled, isDeploymentActivityVisible,
              deploymentActivityRequestID == requestID,
              isCurrentConnection(generation: generation, profileID: profileID) else { return }
        var failures: [String] = []
        if case let .value(value) = result.0 { snapshot.apps = value } else { failures.append("apps") }
        if case let .value(value) = result.1 {
            // Preserve newer event receipts delivered while this request was in flight.
            var merged = Dictionary(value.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            for operation in snapshot.operations where eventMutatedOperationIDs.contains(operation.id) {
                if merged[operation.id].map({ $0.updatedAt < operation.updatedAt }) ?? true {
                    merged[operation.id] = operation
                }
            }
            snapshot.operations = merged.values.sorted { $0.updatedAt > $1.updatedAt }
        } else { failures.append("operation history") }
        if case let .value(value) = result.2 {
            var current = Dictionary(value.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            for operation in snapshot.operations where eventMutatedOperationIDs.contains(operation.id) {
                if current[operation.id].map({ $0.updatedAt < operation.updatedAt }) ?? operation.status.isActive {
                    current[operation.id] = operation
                }
            }
            activePlatformOperations = current.values.filter { $0.status.isActive }.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
            activeDeploymentOperations = activePlatformOperations.filter { $0.kind.hasPrefix("app.") }
            for operation in value where !snapshot.operations.contains(where: { $0.id == operation.id }) {
                snapshot.operations.append(operation)
            }
        } else {
            activeDeploymentOperations = []
            activePlatformOperations = []
            failures.append("active operations (current activity unavailable)")
        }
        if case let .value(value) = result.3 { snapshot.services = value.services }
        else { failures.append("services") }
        snapshot.observedAt = .now
        if !failures.isEmpty {
            deploymentActivityError = "Could not refresh \(failures.joined(separator: ", ")). Showing the last available information."
        }
        if navigation == .overview, snapshot.capabilities.supportsDeploymentVisibility {
            // Fetch only the graphs displayed in the HUD, concurrently and off the UI thread.
            let visible = activePlatformOperations.prefix(3).compactMap { operation in
                deployments.filter { !$0.sagaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.sagaID == operation.sagaID }
                    .max { $0.startedAt < $1.startedAt }
            }
            await withTaskGroup(of: (String, [NornDeploymentStep]?, String?).self) { group in
                for deployment in visible {
                    group.addTask {
                        do { return (deployment.id, try await client.deploymentSteps(deploymentID: deployment.id), nil) }
                        catch { return (deployment.id, nil, error.localizedDescription) }
                    }
                }
                for await (id, steps, error) in group {
                    guard !Task.isCancelled, isDeploymentActivityVisible, navigation == .overview,
                          deploymentActivityRequestID == requestID,
                          isCurrentConnection(generation: generation, profileID: profileID) else { continue }
                    if let steps { deploymentSteps[id] = steps }
                    deploymentStepErrors[id] = error
                }
            }
        } else if let id = selectedDeploymentID, deploymentStepRequestID == nil {
            selectDeployment(id: id)
        }
    }

    private func startDeploymentActivityPollingIfNeeded() {
        guard isDeploymentActivityVisible, !isFixtureMode, !isFleetAuthorityOnly,
              connectionState == .online, client != nil, deploymentActivityTask == nil else { return }
        deploymentActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isDeploymentActivityVisible else { return }
                await self.refreshDeploymentActivity()
                let active = !self.activePlatformOperations.isEmpty
                do { try await Task.sleep(for: .seconds(active ? 5 : 15)) }
                catch { return }
            }
        }
    }

    private func stopDeploymentActivityPolling() {
        activeDeploymentOperations = []
        activePlatformOperations = []
        deploymentActivityTask?.cancel()
        deploymentActivityTask = nil
        deploymentStepTask?.cancel()
        deploymentStepTask = nil
        deploymentStepRequestID = nil
        deploymentStepLoadingIDs.removeAll()
        deploymentActivityRequestID = nil
        isDeploymentActivityRefreshing = false
    }

    /// Publish the bounded deployment inventory independently of optional step detail.
    /// Concurrent general/view refreshes share the same request.
    private func refreshDeploymentVisibility(
        using client: any NornClientProtocol,
        expectedGeneration: UInt64? = nil,
        expectedProfileID: UUID? = nil,
        expectedRefreshSequence: UInt64? = nil,
        expectedActivityRequestID: UUID? = nil
    ) async {
        let generation = expectedGeneration ?? connectionGeneration
        let profileID = expectedProfileID ?? selectedProfileID
        guard isCurrentConnection(generation: generation, profileID: profileID),
              expectedRefreshSequence == nil || expectedRefreshSequence == authoritativeRefreshSequence else { return }
        guard snapshot.capabilities.supportsDeploymentVisibility else {
            deployments = []
            deploymentSteps = [:]
            return
        }
        let task: Task<[NornDeployment], Error>
        let requestID: UUID
        if let existing = deploymentListTask, let existingID = deploymentListTaskID {
            task = existing
            requestID = existingID
        } else {
            task = Task { try await client.deployments() }
            requestID = UUID()
            deploymentListTask = task
            deploymentListTaskID = requestID
        }
        defer {
            if deploymentListTaskID == requestID {
                deploymentListTask = nil
                deploymentListTaskID = nil
            }
        }
        do {
            let current = try await task.value
            guard !Task.isCancelled,
                  expectedActivityRequestID == nil || (isDeploymentActivityVisible && deploymentActivityRequestID == expectedActivityRequestID),
                  isCurrentConnection(generation: generation, profileID: profileID),
                  expectedRefreshSequence == nil || expectedRefreshSequence == authoritativeRefreshSequence else { return }
            deployments = current.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
            deploymentActivityError = nil
        } catch {
            guard !Task.isCancelled,
                  expectedActivityRequestID == nil || (isDeploymentActivityVisible && deploymentActivityRequestID == expectedActivityRequestID),
                  isCurrentConnection(generation: generation, profileID: profileID) else { return }
            deploymentActivityError = "Deployment history could not refresh: \(error.localizedDescription)"
        }
    }

    private func listenForEvents(profile: NornServerProfile, generation: UInt64) {
        guard let client else { return }
        eventTask = Task { [weak self] in
            var retry = 0
            while !Task.isCancelled {
                guard let self, self.isCurrentConnection(generation: generation, profileID: profile.id) else { return }
                let cursor = self.profileStore.loadCursor(profileID: profile.id)
                do {
                    let safeCursor = try await self.reconciledEventCursor(
                        cursor,
                        client: client,
                        profileID: profile.id,
                        generation: generation
                    )
                    for try await event in client.events(after: safeCursor) {
                        guard !Task.isCancelled else { return }
                        await self.receive(event, profileID: profile.id, generation: generation)
                    }
                    guard !Task.isCancelled else { return }
                    guard self.isCurrentConnection(generation: generation, profileID: profile.id) else { return }
                    self.transitionConnectionState(to: .reconnecting)
                    self.stopOverviewUpdating()
                    self.stopHostMetricsPolling()
                    self.stopFleetPolling()
                    self.stopDeploymentActivityPolling()
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentConnection(generation: generation, profileID: profile.id) else { return }
                    self.transitionConnectionState(to: .reconnecting)
                    self.lastError = error.localizedDescription
                    self.stopOverviewUpdating()
                    self.stopHostMetricsPolling()
                    self.stopFleetPolling()
                    self.stopDeploymentActivityPolling()
                }

                retry += 1
                let delaySeconds = min(pow(2.0, Double(retry - 1)), 30)
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                    guard self.isCurrentConnection(generation: generation, profileID: profile.id) else { return }
                    let refreshError = try await self.coalescedAuthoritativeRefresh(generation: generation, profileID: profile.id)
                    guard self.isCurrentConnection(generation: generation, profileID: profile.id) else { return }
                    self.lastError = refreshError
                    self.transitionConnectionState(to: .online)
                    self.startOverviewUpdatingIfNeeded()
                    self.startHostMetricsPollingIfNeeded()
                    self.startFleetPollingIfNeeded()
                    self.startDeploymentActivityPollingIfNeeded()
                    retry = 0
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentConnection(generation: generation, profileID: profile.id) else { return }
                    self.transitionConnectionState(to: .offline(error.localizedDescription))
                    self.lastError = error.localizedDescription
                    self.stopOverviewUpdating()
                    self.stopHostMetricsPolling()
                    self.stopFleetPolling()
                    self.stopDeploymentActivityPolling()
                }
            }
        }
    }

    private func validateCurrentRefresh(
        _ refreshSequence: UInt64,
        generation: UInt64,
        profileID: UUID?
    ) throws {
        guard isCurrentConnection(generation: generation, profileID: profileID) else {
            throw CancellationError()
        }
        guard authoritativeRefreshSequence == refreshSequence else { throw CancellationError() }
    }

    private func coalescedAuthoritativeRefresh(generation: UInt64? = nil, profileID: UUID? = nil, afterMutation: Bool = false) async throws -> String? {
        let expectedGeneration = generation ?? connectionGeneration
        let expectedProfileID = profileID ?? selectedProfileID
        guard isCurrentConnection(generation: expectedGeneration, profileID: expectedProfileID), !Task.isCancelled else { throw CancellationError() }
        if afterMutation, let pendingTask = authoritativeRefreshTask {
            // An existing request may have read state before this mutation.
            // Let it finish, then require a new pass to observe the receipt.
            let pendingID = authoritativeRefreshTaskID
            _ = try? await pendingTask.value
            guard isCurrentConnection(generation: expectedGeneration, profileID: expectedProfileID), !Task.isCancelled else { throw CancellationError() }
            if authoritativeRefreshTaskID == pendingID {
                authoritativeRefreshTask = nil
                authoritativeRefreshTaskID = nil
            }
        }
        if let authoritativeRefreshTask {
            return try await authoritativeRefreshTask.value
        }
        let taskID = UUID()
        let task = Task { [weak self] () throws -> String? in
            guard let self else { throw CancellationError() }
            return try await self.refreshAuthoritativeState(generation: expectedGeneration, profileID: expectedProfileID)
        }
        authoritativeRefreshTaskID = taskID
        authoritativeRefreshTask = task
        defer {
            if authoritativeRefreshTaskID == taskID {
                authoritativeRefreshTask = nil
                authoritativeRefreshTaskID = nil
            }
        }
        return try await task.value
    }

    private func reconciledEventCursor(
        _ cursor: Int64?,
        client: any NornClientProtocol,
        profileID: UUID,
        generation: UInt64
    ) async throws -> Int64? {
        guard let cursor else { return nil }
        // Metadata failure is an ordinary transport failure: retain the durable
        // cursor so the server can replay it when connectivity returns.
        guard let info = try? await client.eventStreamInfo() else { return cursor }
        guard isCurrentConnection(generation: generation, profileID: profileID) else {
            throw CancellationError()
        }
        let minimum = max(0, info.bounds.oldestCursor - 1)
        let maximum = max(0, info.bounds.latestCursor)
        guard cursor < minimum || cursor > maximum else { return cursor }

        // Query bounds first, then refresh current state, then connect after the
        // captured head. Events created during the refresh remain replayable.
        _ = try await coalescedAuthoritativeRefresh(generation: generation, profileID: profileID)
        guard isCurrentConnection(generation: generation, profileID: profileID) else {
            throw CancellationError()
        }
        profileStore.saveCursor(maximum, profileID: profileID)
        return maximum
    }

    private static let emptySnapshot = NornDashboardSnapshot(
        capabilities: NornCapabilities(
            protocolVersion: 1,
            serverVersion: "Unavailable",
            features: [],
            auth: .init(scopes: [], websocketBearerHeader: true, websocketQueryToken: false),
            endpoints: [:]
        ),
        health: NornHealth(status: "unknown", services: [:], network: nil),
        services: [],
        operations: [],
        releases: [],
        observedAt: .now,
        apps: []
    )

    private func receive(_ event: NornControlEvent, profileID: UUID, generation: UInt64) async {
        guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
        eventMutationSequence &+= 1
        profileStore.saveCursor(event.id, profileID: profileID)
        let shouldApplyOperationEvent = !isOverviewVisible || overviewUpdateMode != .manual
        if shouldApplyOperationEvent,
           let object = event.payload.objectValue,
           let operationID = object["operationId"]?.stringValue,
           let client,
           let updated = try? await client.operation(id: operationID) {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            upsert(updated)
            if isDeploymentActivityVisible {
                activePlatformOperations.removeAll { $0.id == updated.id }
                if updated.status.isActive { activePlatformOperations.append(updated) }
                activePlatformOperations.sort { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
                activeDeploymentOperations = activePlatformOperations.filter { $0.kind.hasPrefix("app.") }
            }
            eventMutatedOperationIDs.insert(operationID)
        }
        guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
        isOverviewDirty = true
        scheduleLiveOverviewRefresh()
    }

    private func isCurrentConnection(generation: UInt64, profileID: UUID?) -> Bool {
        connectionGeneration == generation && selectedProfileID == profileID
    }

    /// Checks the lease, current connection, and the capability predicate in
    /// one synchronous MainActor turn immediately before a mutating client
    /// call. A Task that was created under profile A therefore cannot dispatch
    /// through profile B's newly connected client.
    private func isValidMutationContext(_ context: NornMutationContext, permits: Bool, requiresClient: Bool = true) -> Bool {
        !Task.isCancelled
            && permits
            && (!requiresClient || client != nil)
            && isCurrentConnection(generation: context.connectionGeneration, profileID: context.profileID)
    }

    private func transitionConnectionState(to nextState: NornConnectionState) {
        if connectionState == .online, nextState != .online {
            // Metrics are profile-keyed observational data. A same-profile
            // reconnect/offline transition retains the last sample only with
            // an explicit stale marker; profile boundaries clear it outright.
            hostMetrics?.stale = true
        }
        connectionState = nextState
    }

    private func hasScope(_ scope: String) -> Bool {
        guard canPerformOperations else { return false }
        return snapshot.capabilities.grantedScopes.contains(scope)
            || snapshot.capabilities.grantedScopes.contains("admin")
    }

    private func mayQueue(_ request: NornMaintenanceRequest) -> Bool {
        switch request {
        case .hostAssurance: return canRunHostAssurance
        case .platformPreflight, .platformUpgrade, .platformRollback, .platformSmoke:
            return canRunPlatformMaintenance
        }
    }

    private func clearConnectionScopedState(preservingMetricsHistory: Bool = false) {
        lastError = nil
        isRefreshing = false
        isFleetRefreshing = false
        snapshot = Self.emptySnapshot
        hostMetrics = nil
        clearFleetAndDeploymentState()
        selectedOperationID = nil
        selectedAppName = nil
        selectedService = nil
        if !preservingMetricsHistory {
            hostMetricsHistory = []
            serviceMetricsHistory = []
        }
        lastHostMetricsPersistenceAt = nil
        lastServiceMetricsRefreshAt = nil
        lastServiceMetricsPersistenceAt = nil
        serviceMetricsEndpointUnavailable = false
        eventMutatedOperationIDs.removeAll()
        isOverviewDirty = false
        shouldRefreshAgain = false
        authoritativeRefreshTask?.cancel()
        authoritativeRefreshTask = nil
        authoritativeRefreshTaskID = nil
    }

    private func clearFleetAndDeploymentState() {
        scalingRuntimeApps.removeAll()
        runtimeScaleFeedback.removeAll()
        stopDeploymentActivityPolling()
        deploymentListTask?.cancel()
        deploymentListTask = nil
        deploymentListTaskID = nil
        selectedDeploymentID = nil
        activeDeploymentOperations = []
        activePlatformOperations = []
        deploymentActivityError = nil
        deploymentStepErrors = [:]
        fleetInventory = .unconfigured
        fleetPlans = []
        fleetReconciliations = [:]
        fleetRunnerAttempts = [:]
        fleetGitHubStatus = .unconfigured
        deployments = []
        deploymentSteps = [:]
    }

    private func upsert(_ operation: NornOperation) {
        snapshot.operations.removeAll { $0.id == operation.id }
        snapshot.operations.insert(operation, at: 0)
        snapshot.observedAt = .now
    }

    private func startOverviewUpdatingIfNeeded() {
        guard isOverviewVisible,
              connectionState == .online,
              client != nil,
              overviewRefreshTask == nil,
              let interval = overviewUpdateMode.refreshInterval else { return }

        overviewRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, self.isOverviewVisible else { return }
                await self.refresh()
            }
        }
    }

    private func scheduleLiveOverviewRefresh() {
        guard isOverviewVisible,
              overviewUpdateMode == .live,
              connectionState == .online,
              client != nil else { return }

        // Throttle from the leading edge so a steady event stream still gets a
        // bounded refresh instead of perpetually resetting a trailing debounce.
        guard overviewEventRefreshTask == nil else { return }
        overviewEventRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  self.isOverviewVisible,
                  self.overviewUpdateMode == .live else { return }
            self.overviewEventRefreshTask = nil
            await self.refresh()
        }
    }

    private func refreshDirtyOverviewIfNeeded() {
        guard isOverviewVisible,
              isOverviewDirty,
              overviewUpdateMode != .manual,
              connectionState == .online,
              client != nil else { return }
        Task { [weak self] in await self?.refresh() }
    }

    private func stopOverviewUpdating() {
        overviewRefreshTask?.cancel()
        overviewRefreshTask = nil
        overviewEventRefreshTask?.cancel()
        overviewEventRefreshTask = nil
    }

    private func startHostMetricsPollingIfNeeded() {
        guard isHostVisible,
              connectionState == .online,
              client != nil,
              hostMetricsSupported,
              hostMetricsTask == nil else { return }

        hostMetricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshHostMetrics(onlyWhileHostVisible: true)
                await self?.refreshServiceMetricsIfNeeded()

                do {
                    try await Task.sleep(for: .seconds(self?.hostMetricsRefreshInterval.rawValue ?? 10))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func stopHostMetricsPolling() {
        hostMetricsTask?.cancel()
        hostMetricsTask = nil
    }

    private func recordHostMetrics(_ metrics: NornHostMetrics) {
        guard !metrics.stale, !isFixtureMode else { return }
        let sample = NornHostMetricSample(metrics: metrics)
        guard hostMetricsHistory.last?.observedAt != sample.observedAt else { return }

        hostMetricsHistory.append(sample)
        metricsHistoryRevision &+= 1
        hostHistoryPresentationRevision &+= 1

        let now = Date.now
        if let profileID = selectedProfile?.id,
           lastHostMetricsPersistenceAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            scheduleMetricsHistoryPersistence(profileID: profileID)
            lastHostMetricsPersistenceAt = now
        }
    }

    private func refreshServiceMetricsIfNeeded(force: Bool = false) async {
        guard let client,
              connectionState == .online,
              hostMetricsSupported,
              canReadRuntime,
              serviceMetricsCollectionEnabled,
              isHostVisible,
              !serviceMetricsEndpointUnavailable,
              !isFixtureMode else { return }
        let now = Date.now
        // The compatibility resource endpoint fans out across Nomad allocations,
        // so collect it much less often than the inexpensive cached host sample.
        let minimumInterval = max(300, TimeInterval(hostMetricsRefreshInterval.rawValue))
        if !force, let lastServiceMetricsRefreshAt,
           now.timeIntervalSince(lastServiceMetricsRefreshAt) < minimumInterval {
            return
        }
        lastServiceMetricsRefreshAt = now
        let generation = connectionGeneration
        let profileID = selectedProfileID
        do {
            let suggestions = try await client.resourceSuggestions()
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            recordServiceMetrics(suggestions, observedAt: now)
        } catch is CancellationError {
            return
        } catch let NornClientError.http(status, _, _) where status == 403 || status == 404 {
            guard isCurrentConnection(generation: generation, profileID: profileID) else { return }
            serviceMetricsEndpointUnavailable = true
        } catch {
            // Allocation metrics are an optional compatibility surface. Missing
            // or temporarily unavailable Nomad stats never degrade host metrics.
        }
    }

    private func recordServiceMetrics(_ suggestions: [NornResourceSuggestion], observedAt: Date) {
        guard serviceMetricsCollectionEnabled, !suggestions.isEmpty, !isFixtureMode else { return }
        serviceMetricsHistory.append(contentsOf: suggestions.map {
            NornServiceMetricSample(observedAt: observedAt, suggestion: $0)
        })
        metricsHistoryRevision &+= 1
        hostHistoryPresentationRevision &+= 1

        let now = Date.now
        if let profileID = selectedProfile?.id,
           lastServiceMetricsPersistenceAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            scheduleMetricsHistoryPersistence(profileID: profileID)
            lastServiceMetricsPersistenceAt = now
        }
    }

    private func invalidateHistoryLoading() {
        historyGeneration &+= 1
        historyRequestGeneration &+= 1
        metricsHistoryRevision &+= 1
        hostHistoryPresentationRevision &+= 1
        hostMetricsHistory = []
        serviceMetricsHistory = []
    }

    /// Retains full fidelity for the newest hour, one-minute extrema through
    /// the first day, and five-minute extrema through 30 days.
    nonisolated static func compactHostMetricsHistory(
        _ samples: [NornHostMetricSample],
        endingAt end: Date
    ) -> [NornHostMetricSample] {
        let historyCutoff = end.addingTimeInterval(-Double(NornHostMetricsWindow.days30.rawValue))
        let dayCutoff = end.addingTimeInterval(-Double(NornHostMetricsWindow.hours24.rawValue))
        let recentCutoff = end.addingTimeInterval(-Double(NornHostMetricsWindow.hour1.rawValue))
        let retained = samples.filter { $0.observedAt >= historyCutoff }.sorted { $0.observedAt < $1.observedAt }
        var minuteBuckets: [Int64: NornHostMetricSample] = [:]
        var fiveMinuteBuckets: [Int64: NornHostMetricSample] = [:]
        var recentBuckets: [Date: NornHostMetricSample] = [:]

        for sample in retained {
            guard sample.observedAt < recentCutoff else {
                if var aggregate = recentBuckets[sample.observedAt] {
                    aggregate.cpuPercent = max(aggregate.cpuPercent, sample.cpuPercent)
                    if sample.memoryPercent > aggregate.memoryPercent {
                        aggregate.memoryUsedBytes = sample.memoryUsedBytes
                        aggregate.memoryTotalBytes = sample.memoryTotalBytes
                    }
                    recentBuckets[sample.observedAt] = aggregate
                } else {
                    recentBuckets[sample.observedAt] = sample
                }
                continue
            }
            let width: TimeInterval = sample.observedAt >= dayCutoff ? 60 : 300
            let bucket = Int64(sample.observedAt.timeIntervalSince1970 / width)
            if width == 60 {
                mergeHostMetricSample(sample, bucket: bucket, into: &minuteBuckets)
            } else {
                mergeHostMetricSample(sample, bucket: bucket, into: &fiveMinuteBuckets)
            }
        }

        return (Array(fiveMinuteBuckets.values) + Array(minuteBuckets.values) + Array(recentBuckets.values))
            .sorted { $0.observedAt < $1.observedAt }
    }

    private nonisolated static func mergeHostMetricSample(
        _ sample: NornHostMetricSample,
        bucket: Int64,
        into buckets: inout [Int64: NornHostMetricSample]
    ) {
        guard var aggregate = buckets[bucket] else {
            buckets[bucket] = sample
            return
        }
        aggregate.observedAt = max(aggregate.observedAt, sample.observedAt)
        aggregate.cpuPercent = max(aggregate.cpuPercent, sample.cpuPercent)
        if sample.memoryPercent > aggregate.memoryPercent {
            aggregate.memoryUsedBytes = sample.memoryUsedBytes
            aggregate.memoryTotalBytes = sample.memoryTotalBytes
        }
        buckets[bucket] = aggregate
    }

    /// Keeps the twelve busiest app/process series and tiered extrema for a
    /// month. This bounds local storage while preserving the noisy tenants the
    /// overlay is designed to reveal.
    nonisolated static func compactServiceMetricsHistory(
        _ samples: [NornServiceMetricSample],
        endingAt end: Date
    ) -> [NornServiceMetricSample] {
        let historyCutoff = end.addingTimeInterval(-Double(NornHostMetricsWindow.days30.rawValue))
        let dayCutoff = end.addingTimeInterval(-Double(NornHostMetricsWindow.hours24.rawValue))
        let recentCutoff = end.addingTimeInterval(-Double(NornHostMetricsWindow.hour1.rawValue))
        let retained = samples.filter { $0.observedAt >= historyCutoff }
        let grouped = Dictionary(grouping: retained, by: \.seriesID)
        var rankings: [(id: String, highWater: Double)] = []
        for (id, values) in grouped {
            let highWater = values.reduce(0.0) { result, sample in
                max(result, max(sample.cpuPercent, sample.memoryPercent))
            }
            rankings.append((id: id, highWater: highWater))
        }
        rankings.sort { lhs, rhs in
            lhs.highWater == rhs.highWater ? lhs.id < rhs.id : lhs.highWater > rhs.highWater
        }
        let rankedSeries = rankings.prefix(12).map { $0.id }
        let selected = Set(rankedSeries)
        var buckets: [String: NornServiceMetricSample] = [:]
        var recentBuckets: [String: NornServiceMetricSample] = [:]

        for sample in retained where selected.contains(sample.seriesID) {
            guard sample.observedAt < recentCutoff else {
                if var aggregate = recentBuckets[sample.id] {
                    aggregate.cpuPercent = max(aggregate.cpuPercent, sample.cpuPercent)
                    aggregate.memoryPercent = max(aggregate.memoryPercent, sample.memoryPercent)
                    recentBuckets[sample.id] = aggregate
                } else {
                    recentBuckets[sample.id] = sample
                }
                continue
            }
            let width: TimeInterval = sample.observedAt >= dayCutoff ? 300 : 1_800
            let bucket = Int64(sample.observedAt.timeIntervalSince1970 / width)
            let key = "\(sample.seriesID)@\(bucket)"
            guard var aggregate = buckets[key] else {
                buckets[key] = sample
                continue
            }
            aggregate.observedAt = max(aggregate.observedAt, sample.observedAt)
            aggregate.cpuPercent = max(aggregate.cpuPercent, sample.cpuPercent)
            aggregate.memoryPercent = max(aggregate.memoryPercent, sample.memoryPercent)
            buckets[key] = aggregate
        }

        return (Array(buckets.values) + Array(recentBuckets.values)).sorted {
            $0.observedAt == $1.observedAt ? $0.seriesID < $1.seriesID : $0.observedAt < $1.observedAt
        }
    }

    private func startFleetPollingIfNeeded() {
        guard isFleetVisible,
              connectionState == .online,
              client != nil,
              fleetSupported,
              fleetTask == nil else { return }

        fleetTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshFleet()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
            }
        }
    }

    private func stopFleetPolling() {
        fleetTask?.cancel()
        fleetTask = nil
    }
}
