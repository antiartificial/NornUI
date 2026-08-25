import XCTest
@testable import NornUI

@MainActor
final class NornAppModelTests: XCTestCase {
    func testFixtureModeStartsOnlineWithoutAConfiguredServer() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = NornAppModel(profileStore: NornProfileStore(defaults: defaults))

        await model.start()

        XCTAssertTrue(model.isFixtureMode)
        XCTAssertEqual(model.connectionState, .online)
        XCTAssertEqual(model.snapshot.capabilities.serverVersion, "v2.16.2-control")
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
}

private struct MockNornClient: NornClientProtocol {
    func capabilities() async throws -> NornCapabilities { NornFixtures.snapshot.capabilities }
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
