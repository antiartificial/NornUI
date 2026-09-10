import XCTest
@testable import NornUI

@MainActor
final class NornHostViewLoadingTests: XCTestCase {
    func testHostRefreshDoesNotCallUnrelatedDashboardEndpoints() async {
        let (model, client, profile) = makeModel()
        await model.start()
        model.setHostVisible(true, profileID: profile.id)
        let initialMetricCompleted = await client.waitForMetricCompletions(1)
        XCTAssertTrue(initialMetricCompleted)
        await client.resetCounts()

        await model.refreshHost()
        model.setHostVisible(false, profileID: profile.id)

        let counts = await client.counts()
        XCTAssertEqual(counts.capabilities, 0)
        XCTAssertEqual(counts.apps, 0)
        XCTAssertEqual(counts.operations, 0)
        XCTAssertEqual(counts.releases, 0)
        XCTAssertEqual(counts.fleet, 0)
        XCTAssertEqual(counts.deployments, 0)
        XCTAssertEqual(counts.health, 1)
        XCTAssertEqual(counts.hostStatus, 1)
        XCTAssertEqual(counts.manifest, 1)
        XCTAssertEqual(counts.metrics, 1)
    }

    func testHiddenHostDoesNotPollMetrics() async {
        let (model, client, _) = makeModel()
        await model.start()
        await client.resetCounts()

        try? await Task.sleep(for: .milliseconds(80))

        let counts = await client.counts()
        XCTAssertEqual(counts.metrics, 0)
        XCTAssertNil(model.hostMetrics)
    }

    func testLateMetricResponseAfterHostDisappearsIsNotApplied() async {
        let gate = MetricGate()
        let (model, client, profile) = makeModel(gate: gate)
        await model.start()

        model.setHostVisible(true, profileID: profile.id)
        let didStart = await gate.waitUntilStarted()
        XCTAssertTrue(didStart)
        model.setHostVisible(false, profileID: profile.id)
        await gate.release()
        let didComplete = await client.waitForMetricCompletions(1)
        XCTAssertTrue(didComplete)

        XCTAssertNil(model.hostMetrics)
        XCTAssertTrue(model.hostMetricsHistory.isEmpty)
    }

    func testStaleDisappearFromPreviousProfileCannotStopCurrentHostPolling() async {
        let defaults = isolatedDefaults()
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        let second = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        let firstClient = HostLoadingClient()
        let secondClient = HostLoadingClient()
        let model = NornAppModel(profileStore: store, clientFactory: { profile in
            profile.id == first.id ? firstClient : secondClient
        })
        await model.start()

        model.setHostVisible(true, profileID: first.id)
        let firstDidPoll = await firstClient.waitForMetricCalls(1)
        XCTAssertTrue(firstDidPoll)
        await model.selectProfile(id: second.id)
        model.setHostVisible(true, profileID: second.id)
        model.setHostVisible(false, profileID: first.id)

        let secondDidPoll = await secondClient.waitForMetricCalls(1)
        XCTAssertTrue(secondDidPoll)
        XCTAssertEqual(model.selectedProfileID, second.id)
    }

    private func makeModel(
        gate: MetricGate? = nil
    ) -> (NornAppModel, HostLoadingClient, NornServerProfile) {
        let defaults = isolatedDefaults()
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let client = HostLoadingClient(metricGate: gate)
        return (NornAppModel(profileStore: store, clientFactory: { _ in client }), client, profile)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "NornHostViewLoadingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private actor MetricGate {
    private var started = false
    private var released = false

    func wait() async {
        started = true
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<100 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func release() { released = true }
}

private actor HostLoadingClient: NornClientProtocol {
    struct Counts: Sendable {
        var capabilities = 0
        var metrics = 0
        var metricCompletions = 0
        var health = 0
        var hostStatus = 0
        var manifest = 0
        var apps = 0
        var operations = 0
        var releases = 0
        var fleet = 0
        var deployments = 0
    }

    private var callCounts = Counts()
    private let metricGate: MetricGate?

    init(metricGate: MetricGate? = nil) { self.metricGate = metricGate }

    func resetCounts() { callCounts = Counts() }
    func counts() -> Counts { callCounts }

    func waitForMetricCalls(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if callCounts.metrics >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func waitForMetricCompletions(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if callCounts.metricCompletions >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func capabilities() async throws -> NornCapabilities {
        callCounts.capabilities += 1
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.endpoints.removeValue(forKey: "events")
        capabilities.features.removeAll {
            $0 == "fleet-v1" ||
            $0 == "fleet-inventory" ||
            $0 == "durable-fleet-capacity-plans" ||
            $0 == "fleet-github-app-v1" ||
            $0 == "versioned-deployment-history-v1"
        }
        return capabilities
    }

    func hostMetrics() async throws -> NornHostMetrics {
        callCounts.metrics += 1
        if let metricGate { await metricGate.wait() }
        callCounts.metricCompletions += 1
        return NornFixtures.hostMetrics
    }

    func health() async throws -> NornHealth {
        callCounts.health += 1
        return NornFixtures.snapshot.health
    }

    func hostStatus() async throws -> NornHostStatus {
        callCounts.hostStatus += 1
        return NornHostStatus(
            schemaVersion: "norn.host-status/v1",
            status: NornFixtures.snapshot.health.status,
            services: NornFixtures.snapshot.health.services,
            latestAssurance: nil,
            observedAt: .now
        )
    }

    func serviceManifest() async throws -> NornServiceManifest {
        callCounts.manifest += 1
        return .init(version: 1, generatedAt: .now, networkMode: "tailnet", services: NornFixtures.snapshot.services)
    }

    func apps() async throws -> [NornAppStatus] {
        callCounts.apps += 1
        return NornFixtures.snapshot.apps
    }

    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] {
        callCounts.operations += 1
        return NornFixtures.snapshot.operations
    }

    func operation(id: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }

    func releases() async throws -> NornReleaseList {
        callCounts.releases += 1
        return .init(current: NornFixtures.snapshot.releases.first?.path, releases: NornFixtures.snapshot.releases)
    }

    func fleetInventory() async throws -> NornFleetInventory {
        callCounts.fleet += 1
        return .unconfigured
    }

    func fleetPlans() async throws -> [NornOperation] {
        callCounts.fleet += 1
        return []
    }

    func fleetGitHubStatus() async throws -> NornFleetGitHubStatus {
        callCounts.fleet += 1
        return .unconfigured
    }

    func deployments() async throws -> [NornDeployment] {
        callCounts.deployments += 1
        return []
    }

    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        NornFixtures.snapshot.operations[0]
    }

    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
