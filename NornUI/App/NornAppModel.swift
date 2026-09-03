import Foundation
import CryptoKit
import Observation

typealias NornClientFactory = @Sendable (NornServerProfile) async throws -> any NornClientProtocol
typealias NornEnrollmentClientFactory = @Sendable (URL) async throws -> any NornEnrollmentClientProtocol

nonisolated private enum NornRefreshValue<Value: Sendable>: Sendable {
    case value(Value)
    case failure
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
    var fleetInventory: NornFleetInventory
    var fleetPlans: [NornOperation]
    var fleetReconciliations: [String: [NornOperation]] = [:]
    var fleetRunnerAttempts: [String: [NornFleetRunnerAttempt]] = [:]
    var fleetGitHubStatus: NornFleetGitHubStatus
    var deployments: [NornDeployment]
    var deploymentSteps: [String: [NornDeploymentStep]]
    var isFleetRefreshing = false
    var selectedOperationID: String?
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
    @ObservationIgnored private var fleetTask: Task<Void, Never>?
    @ObservationIgnored private var isHostMetricsVisible = false
    @ObservationIgnored private var isFleetVisible = false

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
        fleetTask?.cancel()
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

    var hostMetricsSupported: Bool {
        snapshot.capabilities.supportsHostMetrics
    }

	var appCreationSupported: Bool { snapshot.capabilities.supportsAppCreation }
	var durableAppRecoverySupported: Bool { snapshot.capabilities.supportsDurableAppRecovery }
	var releasePipelineSupported: Bool { snapshot.capabilities.supportsReleasePipeline }
	var environmentID: String { snapshot.capabilities.environmentID }
	var environmentProfile: String { snapshot.capabilities.environmentProfile }

	func releaseQualifications(app: String) async -> [NornReleaseQualification] {
		guard let client, releasePipelineSupported else { return [] }
		do { return try await client.releaseQualifications(app: app) }
		catch {
			lastError = error.localizedDescription
			return []
		}
	}

	@discardableResult
	func preflightRelease(app: String, sourceSHA: String, artifact: String?) async -> NornOperation? {
		await queueRelease(app: app, kind: "preflight", sourceSHA: sourceSHA, artifact: artifact) { client, request, key in
			try await client.preflightRelease(app: app, request: request, idempotencyKey: key)
		}
	}

	@discardableResult
	func deployRelease(app: String, sourceSHA: String, artifact: String?) async -> NornOperation? {
		await queueRelease(app: app, kind: "deployment", sourceSHA: sourceSHA, artifact: artifact) { client, request, key in
			try await client.deployRelease(app: app, request: request, idempotencyKey: key)
		}
	}

	@discardableResult
	func qualifyRelease(app: String, deploymentID: String) async -> NornReleaseQualification? {
		guard let client, canPerformOperations, releasePipelineSupported, environmentID == "staging" else { return nil }
		lastError = nil
		let intent = releaseIntent(app: app, kind: "qualification", values: [deploymentID])
		let idempotencyKey = profileStore.durableIntentKey(scope: intent.scope, requestDigest: intent.digest)
		do {
			let qualification = try await client.qualifyRelease(app: app, deploymentID: deploymentID, idempotencyKey: idempotencyKey)
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			return qualification
		} catch {
			lastError = error.localizedDescription
			return nil
		}
	}

	@discardableResult
	func promoteRelease(app: String, qualification: NornReleaseQualification) async -> NornOperation? {
		guard let client, canPerformOperations, releasePipelineSupported, environmentID == "production", !qualification.isExpired else { return nil }
		lastError = nil
		let intent = releaseIntent(app: app, kind: "promotion", values: [qualification.id, qualification.deploymentID, qualification.sourceSHA, qualification.artifact])
		let idempotencyKey = profileStore.durableIntentKey(scope: intent.scope, requestDigest: intent.digest)
		do {
			let operation = try await client.promoteRelease(app: app, request: .init(qualification: qualification, sourceSHA: qualification.sourceSHA, artifact: qualification.artifact), idempotencyKey: idempotencyKey)
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			upsert(operation)
			return operation
		} catch {
			lastError = error.localizedDescription
			return nil
		}
	}

	private func queueRelease(
		app: String,
		kind: String,
		sourceSHA: String,
		artifact: String?,
		action: @escaping @Sendable (any NornClientProtocol, NornReleaseActionRequest, String) async throws -> NornOperation
	) async -> NornOperation? {
		guard let client, canPerformOperations, releasePipelineSupported, environmentID == "staging" else { return nil }
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
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			upsert(operation)
			return operation
		} catch {
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
		guard let client, durableAppRecoverySupported else { return nil }
		do { return try await client.appSnapshots(app: app) }
		catch {
			lastError = error.localizedDescription
			return nil
		}
	}

	@discardableResult
	func queueAppOperation(_ request: NornAppOperationRequest) async -> NornOperation? {
		guard let client, durableAppRecoverySupported else { return nil }
		lastError = nil
		let intent = appOperationIntent(request)
		let idempotencyKey = profileStore.durableIntentKey(scope: intent.scope, requestDigest: intent.digest)
		do {
			let operation = try await client.queueAppOperation(request, idempotencyKey: idempotencyKey)
			profileStore.clearDurableIntent(scope: intent.scope, key: idempotencyKey)
			upsert(operation)
			selectedOperationID = operation.id
			navigation = .operations
			return operation
		} catch {
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
    var canOperateFleet: Bool { canPerformOperations && snapshot.capabilities.canOperateFleet }

	@discardableResult
	func createApp(_ request: NornCreateAppRequest) async -> NornAppMutationReceipt? {
		guard let client else { return nil }
		lastError = nil
		do {
			let receipt = try await client.createApp(request)
			lastError = try await refreshAuthoritativeState()
			isShowingCreateApp = false
			navigation = .apps
			return receipt
		} catch {
			lastError = error.localizedDescription
			return nil
		}
	}

	func setAppDeployment(app: String, enabled: Bool) async {
		guard let client else { return }
		lastError = nil
		do {
			_ = try await client.setAppDeployment(app: app, enabled: enabled)
			lastError = try await refreshAuthoritativeState()
		} catch { lastError = error.localizedDescription }
	}

    func start() async {
        guard !isFixtureMode else {
            connectionState = .online
            return
        }
        guard !profiles.isEmpty, clientFactory != nil else {
            connectionState = .idle
            return
        }
        await connect()
    }

    func connect() async {
        eventTask?.cancel()
        stopHostMetricsPolling()
        stopFleetPolling()
        hostMetrics = nil
        fleetReconciliations = [:]
        fleetRunnerAttempts = [:]
        guard let profile = selectedProfile, let clientFactory else {
            client = nil
            isFixtureMode = false
            connectionState = .idle
            return
        }

        connectionState = .connecting
        do {
            client = try await clientFactory(profile)
            try await rotateSelectedCredentialIfNeeded(force: false)
            isFixtureMode = false
            lastError = try await refreshAuthoritativeState()
            connectionState = .online
            listenForEvents(profile: profile)
            startHostMetricsPollingIfNeeded()
            startFleetPollingIfNeeded()
        } catch {
            connectionState = .offline(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard client != nil else {
            snapshot.observedAt = .now
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            lastError = try await refreshAuthoritativeState()
            connectionState = .online
            startHostMetricsPollingIfNeeded()
            startFleetPollingIfNeeded()
        } catch {
            connectionState = .offline(error.localizedDescription)
            lastError = error.localizedDescription
            stopHostMetricsPolling()
            stopFleetPolling()
        }
    }

    /// Begins or stops the optional metrics poller as the Host view enters and
    /// leaves the navigation hierarchy. Metrics have their own failure domain:
    /// a failed optional sample never changes the control-plane connection state.
    func setHostMetricsVisible(_ isVisible: Bool) {
        isHostMetricsVisible = isVisible
        if isVisible {
            startHostMetricsPollingIfNeeded()
        } else {
            stopHostMetricsPolling()
        }
    }

    func refreshHostMetrics() async {
        guard let client, connectionState == .online, hostMetricsSupported else { return }
        do {
            hostMetrics = try await client.hostMetrics()
        } catch is CancellationError {
            return
        } catch {
            // Preserve the most recent good sample. Host metrics are an optional
            // observational endpoint and must not take the whole UI offline.
            // A retained value is explicitly marked stale rather than displayed
            // as indefinitely current.
            hostMetrics?.stale = true
        }
    }

    func refreshHost() async {
        await refresh()
        await refreshHostMetrics()
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
        isFleetRefreshing = true
        defer { isFleetRefreshing = false }
        do {
            async let inventory = client.fleetInventory()
            async let plans = client.fleetPlans()
            async let githubStatus: NornFleetGitHubStatus = fleetGitHubSupported ? client.fleetGitHubStatus() : .unconfigured
            fleetInventory = try await inventory
            fleetPlans = try await plans
            fleetGitHubStatus = try await githubStatus
            for plan in fleetPlans where fleetReconciliationSupported {
                if let result = try? await client.fleetReconciliations(planID: plan.id) {
                    fleetReconciliations[plan.id] = result.reconciliations
                }
            }
            for plan in fleetPlans where fleetRunnerAttemptsSupported {
                if let result = try? await client.fleetRunnerAttempts(planID: plan.id) {
                    fleetRunnerAttempts[plan.id] = result.attempts
                }
            }
            await refreshDeploymentVisibility(using: client)
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func createFleetPullRequest(planID: String) async -> URL? {
        guard let client, fleetGitHubSupported, fleetGitHubStatus.connected else { return nil }
        lastError = nil
        do {
            let operation = try await client.createFleetPullRequest(planID: planID)
            upsert(operation)
            return operation.payload?["url"]?.stringValue.flatMap(URL.init(string:))
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func dispatchFleetApply(planID: String, allowDestructive: Bool) async -> URL? {
        guard let client, fleetGitHubSupported, fleetGitHubStatus.connected else { return nil }
        lastError = nil
        do {
            let operation = try await client.dispatchFleetApply(planID: planID, allowDestructive: allowDestructive)
            upsert(operation)
            return operation.payload?["url"]?.stringValue.flatMap(URL.init(string:))
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func planFleetCapacity(pool: String, desired: Int, size: String, reason: String) async -> NornOperation? {
        guard let client else { return nil }
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
    func queue(_ request: NornMaintenanceRequest) async -> NornOperation? {
        guard let client else { return nil }
        lastError = nil
        do {
            let operation = try await client.queue(request, idempotencyKey: UUID().uuidString)
            upsert(operation)
            selectedOperationID = operation.id
            navigation = .operations
            connectionState = .online
            return operation
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func addProfile(_ profile: NornServerProfile) {
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

    func rotateManagedCredentialNow() async {
        guard selectedProfile?.isManagedDevice == true else { return }
        eventTask?.cancel()
        do {
            if client == nil, let profile = selectedProfile, let clientFactory {
                client = try await clientFactory(profile)
            }
            try await rotateSelectedCredentialIfNeeded(force: true)
            await connect()
        } catch {
            connectionState = .offline(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func refreshManagedCredentialIfNeeded() async {
        guard shouldRotate(selectedProfile, force: false) else { return }
        await connect()
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
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
        selectedProfileID = id
        profileStore.saveSelection(id)
        await connect()
    }

    private func persistProfiles() {
        profileStore.saveProfiles(profiles)
        profileStore.saveSelection(selectedProfileID)
    }

    private func rotateSelectedCredentialIfNeeded(force: Bool) async throws {
        guard let profile = selectedProfile,
              shouldRotate(profile, force: force),
              let client else { return }
        let issued = try await client.rotateCredential()
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

    private func refreshAuthoritativeState() async throws -> String? {
        guard let client else { return nil }
        let capabilities = try await client.capabilities()
        async let healthResult = captureRefreshValue { try await client.health() }
        async let hostStatusResult = captureRefreshValue { try await client.hostStatus() }
        async let manifestResult = captureRefreshValue { try await client.serviceManifest() }
		async let appsResult = captureRefreshValue { try await client.apps() }
        async let operationsResult = captureRefreshValue { try await client.operations(activeOnly: false, limit: 100) }
        async let releasesResult = captureRefreshValue { try await client.releases() }
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
        var failures: [String] = []
        var next = snapshot
        next.capabilities = capabilities
        next.observedAt = .now

        switch result.0 {
        case let .value(health): next.health = health
        case .failure: failures.append("health")
        }
        switch result.2 {
        case let .value(manifest): next.services = manifest.services
        case .failure: failures.append("services")
        }
        switch result.3 {
        case let .value(operations): next.operations = operations.sorted { $0.updatedAt > $1.updatedAt }
        case .failure: failures.append("operations")
        }
        switch result.4 {
        case let .value(releases): next.releases = NornRelease.canonicalHistory(releases.releases)
        case .failure: failures.append("releases")
        }
        switch result.5 {
		case let .value(apps): next.apps = apps
        case .failure: failures.append("apps")
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
        }
        snapshot = next

        switch result.6 {
        case let .value(inventory): fleetInventory = inventory
        case .failure: failures.append("fleet inventory")
        }
        switch result.7 {
        case let .value(plans): fleetPlans = plans
        case .failure: failures.append("fleet plans")
        }
        switch result.8 {
        case let .value(status): fleetGitHubStatus = status
        case .failure: failures.append("fleet GitHub status")
        }
        await refreshDeploymentVisibility(using: client)
        guard !failures.isEmpty else { return nil }
        return "Connected, but \(failures.joined(separator: ", ")) could not refresh. Other sections are current."
    }

    /// Deployment checkpoints are an optional compatibility lane. A failure
    /// must not discard the last known execution picture or take v1 offline.
    private func refreshDeploymentVisibility(using client: any NornClientProtocol) async {
        guard snapshot.capabilities.supportsDeploymentVisibility else {
            deployments = []
            deploymentSteps = [:]
            return
        }
        do {
            let current = try await client.deployments()
            var steps: [String: [NornDeploymentStep]] = [:]
            for deployment in current.prefix(12) {
                steps[deployment.id] = (try? await client.deploymentSteps(deploymentID: deployment.id)) ?? []
            }
            deployments = current
            deploymentSteps = steps
        } catch is CancellationError {
            return
        } catch {
            // Preserve cached compatibility data. The main v1 refresh remains authoritative.
        }
    }

    private func listenForEvents(profile: NornServerProfile) {
        guard let client else { return }
        eventTask = Task { [weak self] in
            var retry = 0
            while !Task.isCancelled {
                guard let self, self.selectedProfileID == profile.id else { return }
                let cursor = self.profileStore.loadCursor(profileID: profile.id)
                do {
                    for try await event in client.events(after: cursor) {
                        guard !Task.isCancelled else { return }
                        await self.receive(event, profileID: profile.id)
                    }
                    guard !Task.isCancelled else { return }
                    self.connectionState = .reconnecting
                    self.stopHostMetricsPolling()
                    self.stopFleetPolling()
                } catch is CancellationError {
                    return
                } catch {
                    self.connectionState = .reconnecting
                    self.lastError = error.localizedDescription
                    self.stopHostMetricsPolling()
                    self.stopFleetPolling()
                }

                retry += 1
                let delaySeconds = min(pow(2.0, Double(retry - 1)), 30)
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                    self.lastError = try await self.refreshAuthoritativeState()
                    self.connectionState = .online
                    self.startHostMetricsPollingIfNeeded()
                    self.startFleetPollingIfNeeded()
                    retry = 0
                } catch is CancellationError {
                    return
                } catch {
                    self.connectionState = .offline(error.localizedDescription)
                    self.lastError = error.localizedDescription
                    self.stopHostMetricsPolling()
                    self.stopFleetPolling()
                }
            }
        }
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

    private func receive(_ event: NornControlEvent, profileID: UUID) async {
        profileStore.saveCursor(event.id, profileID: profileID)
        if let object = event.payload.objectValue,
           let operationID = object["operationId"]?.stringValue,
           let client,
           let updated = try? await client.operation(id: operationID) {
            upsert(updated)
        }
    }

    private func upsert(_ operation: NornOperation) {
        snapshot.operations.removeAll { $0.id == operation.id }
        snapshot.operations.insert(operation, at: 0)
        snapshot.observedAt = .now
    }

    private func startHostMetricsPollingIfNeeded() {
        guard isHostMetricsVisible,
              connectionState == .online,
              client != nil,
              hostMetricsSupported,
              hostMetricsTask == nil else { return }

        hostMetricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshHostMetrics()

                do {
                    try await Task.sleep(for: .seconds(10))
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
