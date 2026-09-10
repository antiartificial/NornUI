import XCTest
@testable import NornUI

@MainActor
final class NornMetricsHistoryRegressionTests: XCTestCase {
    func testFailedRefreshPreservesHistoryThroughFlushAndProfileSwitch() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "First", baseURL: URL(string: "https://first.example.test")!)
        let second = NornServerProfile(name: "Second", baseURL: URL(string: "https://second.example.test")!)
        let history = [NornHostMetricSample(observedAt: .now, cpuPercent: 25, memoryUsedBytes: 40, memoryTotalBytes: 100)]
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        store.saveHostMetricsHistory(history, profileID: first.id)
        let client = HistoryFailureClient()
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })
        await model.start()
        XCTAssertEqual(model.hostMetricsHistory, history)
        await client.failCapabilities()
        await model.refresh()
        XCTAssertEqual(model.hostMetricsHistory, history)
        model.persistMetricsHistory()
        XCTAssertEqual(store.loadHostMetricsHistory(profileID: first.id), history)
        await model.selectProfile(id: second.id)
        XCTAssertTrue(model.hostMetricsHistory.isEmpty)
        XCTAssertEqual(store.loadHostMetricsHistory(profileID: first.id), history)
    }
}

private actor HistoryFailureClient: NornClientProtocol {
    private var shouldFail = false
    func failCapabilities() { shouldFail = true }
    func capabilities() async throws -> NornCapabilities {
        if shouldFail { throw NornClientError.invalidResponse }
        var capabilities = await NornFixtures.snapshot.capabilities
        capabilities.features = []
        capabilities.endpoints = [:]
        return capabilities
    }
    func hostMetrics() async throws -> NornHostMetrics { await NornFixtures.hostMetrics }
    func health() async throws -> NornHealth { await NornFixtures.snapshot.health }
    func serviceManifest() async throws -> NornServiceManifest { throw NornClientError.invalidResponse }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { [] }
    func operation(id: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
    func releases() async throws -> NornReleaseList { throw NornClientError.invalidResponse }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
    nonisolated func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> { AsyncThrowingStream { $0.finish() } }
}
