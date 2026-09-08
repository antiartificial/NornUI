import XCTest
@testable import NornUI

@MainActor
final class NornAppModelTests: XCTestCase {
    func testFixtureModeStartsOnlineWithoutAConfiguredServer() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = NornAppModel(
            profileStore: NornProfileStore(defaults: defaults),
            fixture: NornFixtures.snapshot
        )

        await model.start()

        XCTAssertTrue(model.isFixtureMode)
        XCTAssertEqual(model.connectionState, .online)
        XCTAssertEqual(model.snapshot.capabilities.serverVersion, "v2.16.2-control")
    }

    func testNoConfiguredServerDoesNotPresentFixtureHistoryAsLiveData() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = NornAppModel(profileStore: NornProfileStore(defaults: defaults))

        await model.start()

        XCTAssertFalse(model.isFixtureMode)
        XCTAssertEqual(model.connectionState, .idle)
        XCTAssertTrue(model.snapshot.operations.isEmpty)
        XCTAssertTrue(model.snapshot.releases.isEmpty)
    }

    func testConfiguredClientRefreshesAndQueuesMaintenance() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)

        let model = NornAppModel(
            profileStore: profileStore,
            clientFactory: { _ in MockNornClient() }
        )
        await model.start()

        XCTAssertFalse(model.isFixtureMode)
        XCTAssertEqual(model.connectionState, .online)
        XCTAssertEqual(model.snapshot.services.count, NornFixtures.snapshot.services.count)

        let queued = await model.queue(.platformSmoke)
        XCTAssertEqual(queued?.kind, "platform.smoke")
        XCTAssertEqual(model.navigation, .operations)
        XCTAssertEqual(model.selectedOperationID, queued?.id)
    }

    func testTransientMetricsFailureKeepsLastSampleAndConnectionOnline() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)

        let model = NornAppModel(
            profileStore: profileStore,
            clientFactory: { _ in FailingMetricsClient() }
        )
        await model.start()
        model.hostMetrics = NornFixtures.hostMetrics

        await model.refreshHost()

        var expected = NornFixtures.hostMetrics
        expected.stale = true
        XCTAssertEqual(model.hostMetrics, expected)
        XCTAssertEqual(model.connectionState, .online)
        XCTAssertNil(model.lastError)
    }

    func testFleetStateIsRestoredAndNewPlanIsImmediatelyVisible() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)

        let model = NornAppModel(profileStore: profileStore, clientFactory: { _ in MockNornClient() })
        await model.start()

        XCTAssertEqual(model.fleetInventory.document?.cluster.name, "production-nyc3")
        XCTAssertTrue(model.fleetSupported)
        let plan = await model.planFleetCapacity(pool: "app", desired: 3, size: "s-4vcpu-8gb", reason: "add headroom")
        XCTAssertEqual(plan?.payload?["proposed"], .object(["desired": .number(3)]))
        XCTAssertEqual(model.fleetPlans.first?.id, plan?.id)
        XCTAssertEqual(model.fleetReconciliations[plan?.id ?? ""], [])

        let retry = await model.planFleetCapacity(pool: "app", desired: 3, size: "s-4vcpu-8gb", reason: "add headroom")
        XCTAssertEqual(retry?.id, plan?.id, "the same intent must retain its idempotency key across an ambiguous retry")
    }

    func testDurableAppIntentSurvivesAnInterruptedRequest() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)

        let first = store.durableIntentKey(scope: "profile:atlas:restore", requestDigest: "snapshot-a")
        let retryAfterRelaunch = NornProfileStore(defaults: defaults)
            .durableIntentKey(scope: "profile:atlas:restore", requestDigest: "snapshot-a")
        XCTAssertEqual(first, retryAfterRelaunch)

        store.clearDurableIntent(scope: "profile:atlas:restore", key: first)
        let next = store.durableIntentKey(scope: "profile:atlas:restore", requestDigest: "snapshot-a")
        XCTAssertNotEqual(first, next)
    }

    func testOptionalRefreshFailureDoesNotHideFreshOperationsReleasesOrAssurance() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)

        let model = NornAppModel(
            profileStore: profileStore,
            clientFactory: { _ in PartialDashboardClient() }
        )
        await model.start()

        XCTAssertEqual(model.connectionState, .online)
        XCTAssertEqual(model.snapshot.operations.first?.id, "operation-new")
        XCTAssertTrue(model.snapshot.operations.contains { $0.id == "assurance-new" })
        XCTAssertEqual(model.snapshot.releases.first?.version, "v2.21.0")
        XCTAssertTrue(model.lastError?.contains("fleet inventory") == true)
        XCTAssertFalse(model.snapshot.operations.contains { $0.updatedAt == NornFixtures.snapshot.operations[0].updatedAt })
        XCTAssertEqual(model.fleetInventory, .unconfigured)
        XCTAssertTrue(model.fleetPlans.isEmpty)
        XCTAssertTrue(model.deployments.isEmpty)
    }

    func testCompatibilityScopesAndFleetAuthorityFilterActionsAndNavigation() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Compatibility", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in ScopeProbeClient(principal: nil, authority: "fleet-only") })
        await model.start()

        XCTAssertFalse(model.isServerAuthenticated)
        XCTAssertFalse(model.canOperateFleet)
        XCTAssertEqual(model.availableNavigationDestinations, [.overview, .fleet])
        let queued = await model.queue(.platformSmoke)
        XCTAssertNil(queued)
    }

    func testProfileSwitchFailureClearsPriorDashboardAndFleetEvidence() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "First", baseURL: URL(string: "https://first.example.test")!)
        let second = NornServerProfile(name: "Second", baseURL: URL(string: "https://second.example.test")!)
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        let model = NornAppModel(profileStore: store, clientFactory: { profile in
            profile.id == second.id ? ScopeProbeClient(failsCapabilities: true) : ScopeProbeClient()
        })
        await model.start()
        XCTAssertFalse(model.snapshot.services.isEmpty)
        await model.selectProfile(id: second.id)
        XCTAssertTrue(model.snapshot.services.isEmpty)
        XCTAssertTrue(model.snapshot.operations.isEmpty)
        XCTAssertTrue(model.fleetPlans.isEmpty)
        XCTAssertTrue(model.deployments.isEmpty)
        if case .offline = model.connectionState {} else { XCTFail("expected offline") }
    }

    func testDeviceEnrollmentPersistsOnlyManagedMetadataAndKeychainCredential() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Studio Mac", baseURL: URL(string: "https://norn.example.test")!)
        let enrollment = NornEnrollmentSession(
            id: "enrollment-1",
            userCode: "ABCD-EFGH",
            verifier: "memory-only-verifier",
            expiresAt: .now.addingTimeInterval(600),
            verificationPath: "/api/v1/enrollments/approve",
            pollPath: "/api/v1/enrollments/enrollment-1/exchange"
        )
        let issued = NornIssuedToken(
            token: "managed-device-token",
            tokenID: "token-1",
            deviceID: "device-1",
            scopes: ["events:read", "api:read"],
            expiresAt: .now.addingTimeInterval(30 * 24 * 60 * 60)
        )
        let identityVault = ModelDeviceIdentityVault()
        let credentialVault = ModelCredentialVault()
        let enrollmentClient = ModelEnrollmentClient(enrollment: enrollment, issued: issued)
        let model = NornAppModel(
            profileStore: profileStore,
            clientFactory: { _ in MockNornClient() },
            credentialVault: credentialVault,
            deviceIdentityVault: identityVault,
            enrollmentClientFactory: { _ in enrollmentClient }
        )

        let started = try await model.startDeviceEnrollment(
            profile: profile,
            requestedScopes: ["events:read", "api:read", "api:read"]
        )

        XCTAssertEqual(started.0.userCode, "ABCD-EFGH")
        XCTAssertEqual(started.1, .secureEnclave)
        let request = await enrollmentClient.lastStartRequest()
        XCTAssertEqual(request?.requestedScopes, ["api:read", "events:read"])
        XCTAssertEqual(request?.publicKey, "device-public-key")

        try await model.completeDeviceEnrollment(profile: profile, enrollment: enrollment)

        XCTAssertEqual(model.selectedProfile?.deviceID, "device-1")
        XCTAssertEqual(model.selectedProfile?.tokenID, "token-1")
        XCTAssertEqual(model.selectedProfile?.grantedScopes, ["api:read", "events:read"])
        let savedToken = await credentialVault.savedToken(for: profile.credentialID)
        XCTAssertEqual(savedToken, "managed-device-token")
        let storedProfileData = try XCTUnwrap(defaults.data(forKey: "norn.serverProfiles.v1"))
        XCTAssertFalse(String(decoding: storedProfileData, as: UTF8.self).contains("managed-device-token"))
        XCTAssertFalse(String(decoding: storedProfileData, as: UTF8.self).contains("memory-only-verifier"))
    }
}

private actor ModelDeviceIdentityVault: NornDeviceIdentityVault {
    func identity(for identifier: String) -> NornDeviceIdentity {
        NornDeviceIdentity(publicKey: "device-public-key", protection: .secureEnclave)
    }

    func removeIdentity(for identifier: String) {}
}

private actor ModelCredentialVault: NornCredentialVault {
    private var credentials: [String: NornCredential] = [:]

    func credential(for identifier: String) -> NornCredential? { credentials[identifier] }
    func store(_ credential: NornCredential, for identifier: String) { credentials[identifier] = credential }
    func removeCredential(for identifier: String) { credentials.removeValue(forKey: identifier) }
    func savedToken(for identifier: String) -> String? { credentials[identifier]?.accessToken }
}

private actor ModelEnrollmentClient: NornEnrollmentClientProtocol {
    private let enrollment: NornEnrollmentSession
    private let issued: NornIssuedToken
    private var request: NornEnrollmentStartRequest?

    init(enrollment: NornEnrollmentSession, issued: NornIssuedToken) {
        self.enrollment = enrollment
        self.issued = issued
    }

    func start(_ request: NornEnrollmentStartRequest) -> NornEnrollmentSession {
        self.request = request
        return enrollment
    }

    func exchange(_ session: NornEnrollmentSession) -> NornIssuedToken { issued }
    func lastStartRequest() -> NornEnrollmentStartRequest? { request }
}

private struct MockNornClient: NornClientProtocol {
    func capabilities() async throws -> NornCapabilities {
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.auth.principal?.scopes.append(contentsOf: ["platform:operate", "host:operate"])
        return capabilities
    }
    func hostMetrics() async throws -> NornHostMetrics { NornFixtures.hostMetrics }
    func health() async throws -> NornHealth { NornFixtures.snapshot.health }
    func fleetInventory() async throws -> NornFleetInventory { NornFixtures.fleetInventory }
    func fleetPlans() async throws -> [NornOperation] { [] }

    func planFleetCapacity(pool: String, request: NornFleetPlanRequest, idempotencyKey: String) async throws -> NornOperation {
        var operation = NornFixtures.snapshot.operations[0]
        operation.id = idempotencyKey
        operation.kind = "fleet.capacity-plan"
        operation.payload = [
            "pool": .string(pool),
            "current": .object(["desired": .number(2)]),
            "proposed": .object(["desired": .number(Double(request.desired))])
        ]
        return operation
    }

    func serviceManifest() async throws -> NornServiceManifest {
        NornServiceManifest(
            version: 1,
            generatedAt: NornFixtures.snapshot.observedAt,
            networkMode: "tailnet",
            services: NornFixtures.snapshot.services
        )
    }

    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] {
        NornFixtures.snapshot.operations
    }

    func operation(id: String) async throws -> NornOperation {
        NornFixtures.snapshot.operations[0]
    }

    func releases() async throws -> NornReleaseList {
        NornReleaseList(current: NornFixtures.snapshot.releases[0].path, releases: NornFixtures.snapshot.releases)
    }

    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        var operation = NornFixtures.snapshot.operations[0]
        operation.id = idempotencyKey
        operation.kind = "platform.smoke"
        operation.status = .queued
        return operation
    }

    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct FailingMetricsClient: NornClientProtocol {
    private let base = MockNornClient()

    func capabilities() async throws -> NornCapabilities { try await base.capabilities() }
    func hostMetrics() async throws -> NornHostMetrics { throw MetricsError.unavailable }
    func health() async throws -> NornHealth { try await base.health() }
    func serviceManifest() async throws -> NornServiceManifest { try await base.serviceManifest() }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] {
        try await base.operations(activeOnly: activeOnly, limit: limit)
    }
    func operation(id: String) async throws -> NornOperation { try await base.operation(id: id) }
    func releases() async throws -> NornReleaseList { try await base.releases() }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        try await base.queue(request, idempotencyKey: idempotencyKey)
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        base.events(after: cursor)
    }

    private enum MetricsError: Error {
        case unavailable
    }
}

private struct ScopeProbeClient: NornClientProtocol {
    let principal: NornCapabilities.Authentication.Principal?
    let authority: String?
    let failsCapabilities: Bool
    private let base = MockNornClient()

    init(
        principal: NornCapabilities.Authentication.Principal? = NornFixtures.snapshot.capabilities.auth.principal,
        authority: String? = nil,
        failsCapabilities: Bool = false
    ) {
        self.principal = principal
        self.authority = authority
        self.failsCapabilities = failsCapabilities
    }

    func capabilities() async throws -> NornCapabilities {
        if failsCapabilities { throw URLError(.cannotConnectToHost) }
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.auth.principal = principal
        capabilities.authority = authority
        if authority == "fleet-only" { capabilities.features.append("fleet-authority-only-v1") }
        return capabilities
    }
    func hostMetrics() async throws -> NornHostMetrics { try await base.hostMetrics() }
    func health() async throws -> NornHealth { try await base.health() }
    func fleetInventory() async throws -> NornFleetInventory { try await base.fleetInventory() }
    func fleetPlans() async throws -> [NornOperation] { try await base.fleetPlans() }
    func serviceManifest() async throws -> NornServiceManifest { try await base.serviceManifest() }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { try await base.operations(activeOnly: activeOnly, limit: limit) }
    func operation(id: String) async throws -> NornOperation { try await base.operation(id: id) }
    func releases() async throws -> NornReleaseList { try await base.releases() }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation { try await base.queue(request, idempotencyKey: idempotencyKey) }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> { base.events(after: cursor) }
}

private struct PartialDashboardClient: NornClientProtocol {
    private enum ExpectedFailure: Error { case unavailable }

    func capabilities() async throws -> NornCapabilities {
        var value = NornFixtures.snapshot.capabilities
        value.endpoints["hostStatus"] = "/api/v1/host/status"
        return value
    }

    func hostMetrics() async throws -> NornHostMetrics { NornFixtures.hostMetrics }
    func health() async throws -> NornHealth { NornFixtures.snapshot.health }
    func hostStatus() async throws -> NornHostStatus {
        NornHostStatus(
            schemaVersion: "norn.host-status/v1",
            status: "ok",
            services: ["postgres": "up"],
            latestAssurance: operation(id: "assurance-new", kind: "host.assure", at: 1_788_000_100),
            observedAt: Date(timeIntervalSince1970: 1_788_000_200)
        )
    }
    func serviceManifest() async throws -> NornServiceManifest {
        NornServiceManifest(version: 1, generatedAt: .now, networkMode: "tailnet", services: NornFixtures.snapshot.services)
    }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] {
        [operation(id: "operation-new", kind: "platform.smoke", at: 1_788_000_300)]
    }
    func operation(id: String) async throws -> NornOperation { operation(id: id, kind: "platform.smoke", at: 1_788_000_300) }
    func releases() async throws -> NornReleaseList {
        let release = NornRelease(
            sha: String(repeating: "a", count: 40),
            version: "v2.21.0",
            createdAt: Date(timeIntervalSince1970: 1_788_000_400),
            path: "/releases/new",
            current: true
        )
        return NornReleaseList(current: release.path, releases: [release])
    }
    func fleetInventory() async throws -> NornFleetInventory { throw ExpectedFailure.unavailable }
    func fleetPlans() async throws -> [NornOperation] { throw ExpectedFailure.unavailable }
    func fleetGitHubStatus() async throws -> NornFleetGitHubStatus { throw ExpectedFailure.unavailable }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        operation(id: idempotencyKey, kind: "platform.smoke", at: 1_788_000_300)
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func operation(id: String, kind: String, at timestamp: TimeInterval) -> NornOperation {
        NornOperation(
            id: id,
            kind: kind,
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: timestamp - 10),
            updatedAt: Date(timeIntervalSince1970: timestamp),
            finishedAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}
