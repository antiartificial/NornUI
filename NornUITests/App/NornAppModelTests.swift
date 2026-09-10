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

    func testFleetAuthorityOnlyConnectionDoesNotPollAbsentRuntimeSurfaces() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Fleet authority", baseURL: URL(string: "https://fleet.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let recorder = FleetAuthorityOnlyRecorder()
        let client = FleetAuthorityOnlyClient(recorder: recorder)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })

        await model.start()

        XCTAssertEqual(model.connectionState, .online)
        XCTAssertTrue(model.isFleetAuthorityOnly)
        XCTAssertFalse(model.canOperateFleet, "viewer enrollment must not prepare Fleet changes")
        XCTAssertTrue(model.snapshot.services.isEmpty)
        XCTAssertTrue(model.snapshot.apps.isEmpty)
        XCTAssertTrue(model.snapshot.releases.isEmpty)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(recorder.prohibitedCalls(), [])
    }

    func testFleetAuthorityEnrollmentRequestsOnlyViewerOrOperatorAPIScopes() {
        let capabilities = NornCapabilities(
            protocolVersion: 1,
            serverVersion: "fleet-authority",
            features: ["fleet-authority-only-v1"],
            auth: .init(scopes: ["api:read", "api:write"], websocketBearerHeader: false, websocketQueryToken: false),
            endpoints: [:],
            authority: "fleet-only"
        )

        let viewerScopes = NornEnrollmentScopes.requested(
            capabilities: capabilities,
            requestsAPIWrite: false,
            requestsPlatformOperations: true,
            requestsHostOperations: true,
            requestsFleetOperations: true,
            requestsTerminalSessions: true
        )
        let operatorScopes = NornEnrollmentScopes.requested(
            capabilities: capabilities,
            requestsAPIWrite: true,
            requestsPlatformOperations: true,
            requestsHostOperations: true,
            requestsFleetOperations: true,
            requestsTerminalSessions: true
        )

        XCTAssertEqual(viewerScopes, ["api:read"])
        XCTAssertEqual(operatorScopes, ["api:read", "api:write"])
        XCTAssertFalse(operatorScopes.contains("events:read"))
        XCTAssertFalse(operatorScopes.contains("fleet:operate"))
    }

    func testOverviewDrillDownOwnsExactServiceAndOperationSelections() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = NornAppModel(
            profileStore: NornProfileStore(defaults: defaults),
            fixture: NornFixtures.snapshot
        )
        let service = NornFixtures.snapshot.services[0]
        let operation = NornFixtures.snapshot.operations[0]

        model.openService(service)

        XCTAssertEqual(model.navigation, .apps)
        XCTAssertEqual(model.selectedAppName, service.app)
        XCTAssertTrue(model.selectedService?.matches(service) == true)

        model.openOperation(operation)

        XCTAssertEqual(model.navigation, .operations)
        XCTAssertEqual(model.selectedOperationID, operation.id)
    }

    func testOverviewUpdateModePersistsAndExposesRequestedCadences() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let model = NornAppModel(profileStore: store, fixture: NornFixtures.snapshot)

        XCTAssertEqual(model.overviewUpdateMode, .live)
        XCTAssertNil(NornOverviewUpdateMode.live.refreshInterval)
        XCTAssertNil(NornOverviewUpdateMode.manual.refreshInterval)
        XCTAssertEqual(NornOverviewUpdateMode.seconds5.refreshInterval, 5)
        XCTAssertEqual(NornOverviewUpdateMode.minutes10.refreshInterval, 600)

        model.overviewUpdateMode = .minutes5

        XCTAssertEqual(NornProfileStore(defaults: defaults).loadOverviewUpdateMode(), .minutes5)
    }

    func testAuthoritativeRefreshClearsAServiceSelectionMissingFromTheManifest() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in MockNornClient() })
        await model.start()
        var removedService = NornFixtures.snapshot.services[0]
        removedService.name += "-removed"

        model.openService(removedService)
        XCTAssertNotNil(model.selectedService)

        await model.refresh()

        XCTAssertNil(model.selectedService)
        XCTAssertEqual(model.selectedAppName, removedService.app)
    }

    func testConcurrentRefreshRequestsAreCoalescedWithoutOverlappingSnapshots() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let client = RefreshTrackingClient()
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })
        await model.start()
        await client.resetTracking()

        async let first: Void = model.refresh()
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = model.refresh()
        _ = await (first, second)

        let tracking = await client.tracking()
        XCTAssertEqual(tracking.peak, 1)
        XCTAssertEqual(tracking.calls, 2, "the overlapping request should run once more after the in-flight refresh")
    }

    func testProfileSwitchDiscardsDelayedRefreshFromPreviousProfile() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "Slow", baseURL: URL(string: "https://slow.example.test")!)
        let second = NornServerProfile(name: "Fast", baseURL: URL(string: "https://fast.example.test")!)
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        let model = NornAppModel(profileStore: store, clientFactory: { profile in
            ProfileSnapshotClient(marker: profile.name, delay: profile.id == first.id ? .milliseconds(180) : .milliseconds(5))
        })

        let firstConnection = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(25))
        await model.selectProfile(id: second.id)
        await firstConnection.value

        XCTAssertEqual(model.selectedProfileID, second.id)
        XCTAssertEqual(model.connectionState, .online)
        XCTAssertEqual(model.snapshot.capabilities.serverVersion, "Fast")
        XCTAssertEqual(model.snapshot.services.first?.app, "Fast")
    }

    func testLiveListenerRepairsGapCursorAfterAuthoritativeResync() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        store.saveCursor(20, profileID: profile.id)
        let recorder = EventCursorRecorder()
        let client = CursorReconciliationClient(recorder: recorder, metadataAvailable: true)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })

        await model.start()
        let connectedCursor = await recorder.waitForFirstCursor()

        XCTAssertEqual(store.loadCursor(profileID: profile.id), 120)
        XCTAssertEqual(connectedCursor, 120)
    }

    func testLiveListenerPreservesCursorWhenEventMetadataIsUnavailable() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        store.saveCursor(42, profileID: profile.id)
        let recorder = EventCursorRecorder()
        let client = CursorReconciliationClient(recorder: recorder, metadataAvailable: false)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })

        await model.start()
        let connectedCursor = await recorder.waitForFirstCursor()

        XCTAssertEqual(store.loadCursor(profileID: profile.id), 42)
        XCTAssertEqual(connectedCursor, 42)
    }

    func testReturningToLiveOverviewRefreshesEventsReceivedWhileHidden() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let recorder = OverviewRefreshRecorder()
        let client = HiddenOverviewEventClient(recorder: recorder)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })

        await model.start()
        model.setOverviewVisible(false)
        await recorder.waitForEventDelivery()
        let callsWhileHidden = await recorder.capabilityCallCount()
        XCTAssertEqual(callsWhileHidden, 1)

        model.setOverviewVisible(true)

        let refreshedOnReturn = await recorder.waitForCapabilityCalls(2)
        XCTAssertTrue(refreshedOnReturn)
    }

    func testChangingVisibleOverviewFromManualToLiveRefreshesMissedEventState() async throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let recorder = OverviewRefreshRecorder()
        let client = HiddenOverviewEventClient(recorder: recorder)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })
        model.overviewUpdateMode = .manual

        await model.start()
        model.setOverviewVisible(true)
        await recorder.waitForEventDelivery()
        let callsInManual = await recorder.capabilityCallCount()
        XCTAssertEqual(callsInManual, 1)

        model.overviewUpdateMode = .live

        let refreshedAfterModeChange = await recorder.waitForCapabilityCalls(2)
        XCTAssertTrue(refreshedAfterModeChange)
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

    func testRuntimeObservabilityIsScopeGatedAndUsesExactApp() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)
        let model = NornAppModel(profileStore: profileStore, clientFactory: { _ in MockNornClient() })

        await model.start()

        XCTAssertTrue(model.canReadRuntime)
        XCTAssertTrue(model.canWriteRuntime)
        XCTAssertTrue(model.canRunHostAssurance)
        let service = NornFixtures.snapshot.services[0]
        let logs = await model.appLogs(for: service)
        let restarted = await model.restartAppAllocations(for: service)
        XCTAssertEqual(logs, "logs for \(service.app)")
        XCTAssertTrue(restarted)
    }

    func testManagedRuntimeObservabilityUsesPersistedGrantedScopesWithoutPrincipalDiscovery() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(
            name: "Read only",
            baseURL: URL(string: "https://norn.example.test")!,
            deviceID: "device-1",
            tokenID: "token-1",
            grantedScopes: ["api:read"]
        )
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)
        let model = NornAppModel(profileStore: profileStore, clientFactory: { _ in MockNornClient() })

        await model.start()

        XCTAssertTrue(model.canReadRuntime)
        XCTAssertFalse(model.canWriteRuntime)
        XCTAssertFalse(model.canRunHostAssurance)
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

    func testHostMetricsHistoryRetainsDistinctFreshSamples() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)

        let model = NornAppModel(profileStore: profileStore, clientFactory: { _ in MockNornClient() })
        await model.start()
        await model.refreshHostMetrics()
        await model.refreshHostMetrics()

        XCTAssertEqual(model.hostMetricsHistory.count, 1)
        XCTAssertEqual(model.hostMetricsHistory.first?.cpuPercent, NornFixtures.hostMetrics.cpu.utilizationPercent)
        XCTAssertEqual(profileStore.loadHostMetricsHistory(profileID: profile.id).count, 1)
    }

    func testHostMetricsBeginPollingWithoutOpeningHost() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Test", baseURL: URL(string: "https://norn.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let client = RefreshTrackingClient()
        let model = NornAppModel(profileStore: store, clientFactory: { _ in client })

        await model.start()

        let didPoll = await client.waitForHostMetricCalls(1)
        XCTAssertTrue(didPoll)
        for _ in 0..<100 where model.hostMetricsHistory.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.navigation, .overview)
        XCTAssertFalse(model.hostMetricsHistory.isEmpty)
        let initialWorkloadCalls = await client.resourceSuggestionCallCount()
        XCTAssertEqual(initialWorkloadCalls, 0)
        XCTAssertTrue(model.canReadRuntime)
        XCTAssertFalse(model.isFixtureMode)
        XCTAssertTrue(model.hostMetricsSupported)

        model.serviceMetricsCollectionEnabled = true
        let didPollWorkloads = await client.waitForResourceSuggestionCalls(1)
        XCTAssertTrue(didPollWorkloads)
        for _ in 0..<100 where model.serviceMetricsHistory.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.serviceMetricsHistory.isEmpty)
    }

    func testHostMetricsHistoryCompactsOlderSamplesAndPreservesExtrema() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        var samples: [NornHostMetricSample] = []
        for offset in stride(from: 0, through: 86_400, by: 5) {
            let sample = NornHostMetricSample(
                observedAt: end.addingTimeInterval(TimeInterval(offset - 86_400)),
                cpuPercent: offset == 3_600 ? 99 : 12,
                memoryUsedBytes: offset == 7_200 ? 95 : 40,
                memoryTotalBytes: 100
            )
            samples.append(sample)
        }

        let compacted = NornAppModel.compactHostMetricsHistory(samples, endingAt: end)

        XCTAssertLessThanOrEqual(compacted.count, 2_110)
        XCTAssertEqual(compacted.map { $0.cpuPercent }.max(), 99)
        XCTAssertEqual(compacted.map { $0.memoryPercent }.max(), 95)
        XCTAssertEqual(compacted.last?.observedAt, end)
    }

    func testServiceMetricsHistoryKeepsNoisiestSeriesAndMonthOfExtrema() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        var samples: [NornServiceMetricSample] = []
        for appIndex in 0..<14 {
            for offset in stride(from: 0, through: 2_592_000, by: 300) {
                samples.append(.init(
                    observedAt: end.addingTimeInterval(TimeInterval(offset - 2_592_000)),
                    app: "app-\(appIndex)",
                    process: "web",
                    cpuPercent: Double(appIndex),
                    memoryPercent: offset == 1_800 && appIndex == 13 ? 99 : Double(appIndex * 2)
                ))
            }
        }

        let compacted = NornAppModel.compactServiceMetricsHistory(samples, endingAt: end)
        let series = Set(compacted.map(\.seriesID))

        XCTAssertEqual(series.count, 12)
        XCTAssertTrue(series.contains("app-13/web"))
        XCTAssertFalse(series.contains("app-0/web"))
        XCTAssertEqual(compacted.map(\.memoryPercent).max(), 99)
        XCTAssertTrue(compacted.allSatisfy { $0.observedAt >= end.addingTimeInterval(-2_592_000) })
    }

    func testProfileSwitchFlushesPendingHistoryAndLoadsIsolatedTimeline() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "First", baseURL: URL(string: "https://first.example.test")!)
        let second = NornServerProfile(name: "Second", baseURL: URL(string: "https://second.example.test")!)
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        let secondSample = NornHostMetricSample(
            observedAt: .now.addingTimeInterval(-120), cpuPercent: 22,
            memoryUsedBytes: 40, memoryTotalBytes: 100
        )
        store.saveHostMetricsHistory([secondSample], profileID: second.id)
        let model = NornAppModel(profileStore: store)
        let pendingFirst = NornHostMetricSample(
            observedAt: .now, cpuPercent: 91,
            memoryUsedBytes: 88, memoryTotalBytes: 100
        )
        model.hostMetricsHistory = [pendingFirst]

        await model.selectProfile(id: second.id)

        XCTAssertEqual(store.loadHostMetricsHistory(profileID: first.id), [pendingFirst])
        XCTAssertEqual(model.hostMetricsHistory, [secondSample])
    }

    func testRemovingSelectedProfileCannotContaminateReplacementHistory() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "First", baseURL: URL(string: "https://first.example.test")!)
        let second = NornServerProfile(name: "Second", baseURL: URL(string: "https://second.example.test")!)
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        let replacement = NornHostMetricSample(
            observedAt: .now.addingTimeInterval(-120), cpuPercent: 12,
            memoryUsedBytes: 30, memoryTotalBytes: 100
        )
        store.saveHostMetricsHistory([replacement], profileID: second.id)
        let model = NornAppModel(profileStore: store)
        model.hostMetricsHistory = [.init(
            observedAt: .now, cpuPercent: 99,
            memoryUsedBytes: 99, memoryTotalBytes: 100
        )]

        model.removeProfile(id: first.id)
        model.persistMetricsHistory()

        XCTAssertEqual(model.selectedProfileID, second.id)
        XCTAssertEqual(model.hostMetricsHistory, [replacement])
        XCTAssertTrue(store.loadHostMetricsHistory(profileID: first.id).isEmpty)
        XCTAssertEqual(store.loadHostMetricsHistory(profileID: second.id), [replacement])
    }

    func testCompactionDeduplicatesRecentHostAndServiceSamples() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let host = [
            NornHostMetricSample(observedAt: date, cpuPercent: 10, memoryUsedBytes: 20, memoryTotalBytes: 100),
            NornHostMetricSample(observedAt: date, cpuPercent: 90, memoryUsedBytes: 80, memoryTotalBytes: 100),
        ]
        let services = [
            NornServiceMetricSample(observedAt: date, app: "mail", process: "web", cpuPercent: 5, memoryPercent: 20),
            NornServiceMetricSample(observedAt: date, app: "mail", process: "web", cpuPercent: 75, memoryPercent: 60),
        ]

        let compactedHost = NornAppModel.compactHostMetricsHistory(host, endingAt: date)
        let compactedServices = NornAppModel.compactServiceMetricsHistory(services, endingAt: date)

        XCTAssertEqual(compactedHost.count, 1)
        XCTAssertEqual(compactedHost.first?.cpuPercent, 90)
        XCTAssertEqual(compactedHost.first?.memoryPercent, 80)
        XCTAssertEqual(compactedServices.count, 1)
        XCTAssertEqual(compactedServices.first?.cpuPercent, 75)
        XCTAssertEqual(compactedServices.first?.memoryPercent, 60)
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

private final class FleetAuthorityOnlyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var prohibited: [String] = []
    func record(_ value: String) { lock.lock(); prohibited.append(value); lock.unlock() }
    func prohibitedCalls() -> [String] { lock.lock(); defer { lock.unlock() }; return prohibited }
}

private struct FleetAuthorityOnlyClient: NornClientProtocol {
    let recorder: FleetAuthorityOnlyRecorder

    func capabilities() async throws -> NornCapabilities {
        .init(
            protocolVersion: 1,
            serverVersion: "fleet-authority",
            features: ["fleet-authority-only-v1", "fleet-v1", "fleet-inventory", "durable-fleet-capacity-plans"],
            auth: .init(
                scopes: ["api:read", "api:write"],
                websocketBearerHeader: true,
                websocketQueryToken: false,
                principal: .init(authenticated: true, subject: "viewer", scopes: ["api:read"])
            ),
            endpoints: [
                "fleetNodePools": "/api/v1/fleet/node-pools",
                "fleetPlans": "/api/v1/fleet/plans",
                "operationList": "/api/operations"
            ],
            authority: "fleet-only"
        )
    }

    func hostMetrics() async throws -> NornHostMetrics { recorder.record("metrics"); throw NornClientError.invalidResponse }
    func health() async throws -> NornHealth { recorder.record("health"); throw NornClientError.invalidResponse }
    func hostStatus() async throws -> NornHostStatus { recorder.record("host status"); throw NornClientError.invalidResponse }
    func serviceManifest() async throws -> NornServiceManifest { recorder.record("manifest"); throw NornClientError.invalidResponse }
    func apps() async throws -> [NornAppStatus] { recorder.record("apps"); throw NornClientError.invalidResponse }
    func releases() async throws -> NornReleaseList { recorder.record("releases"); throw NornClientError.invalidResponse }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> { recorder.record("events"); return AsyncThrowingStream { $0.finish() } }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { [] }
    func operation(id: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }
    func fleetInventory() async throws -> NornFleetInventory { NornFixtures.fleetInventory }
    func fleetPlans() async throws -> [NornOperation] { [] }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }
}

private struct MockNornClient: NornClientProtocol {
    func capabilities() async throws -> NornCapabilities {
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.auth.principal = nil
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

    func appLogs(app: String) async throws -> String { "logs for \(app)" }
    func restartApp(app: String) async throws {}

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

private struct ProfileSnapshotClient: NornClientProtocol {
    let marker: String
    let delay: Duration

    func capabilities() async throws -> NornCapabilities {
        try await Task.sleep(for: delay)
        var value = NornFixtures.snapshot.capabilities
        value.serverVersion = marker
        return value
    }
    func hostMetrics() async throws -> NornHostMetrics { NornFixtures.hostMetrics }
    func health() async throws -> NornHealth { NornFixtures.snapshot.health }
    func serviceManifest() async throws -> NornServiceManifest {
        var service = NornFixtures.snapshot.services[0]
        service.app = marker
        return .init(version: 1, generatedAt: .now, networkMode: "tailnet", services: [service])
    }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { [] }
    func operation(id: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }
    func releases() async throws -> NornReleaseList { .init(current: nil, releases: []) }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        NornFixtures.snapshot.operations[0]
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor EventCursorRecorder {
    private var cursors: [Int64?] = []
    func record(_ cursor: Int64?) { cursors.append(cursor) }
    func waitForFirstCursor() async -> Int64? {
        for _ in 0 ..< 100 {
            if let cursor = cursors.first { return cursor }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

private struct CursorReconciliationClient: NornClientProtocol {
    enum MetadataError: Error { case unavailable }

    let recorder: EventCursorRecorder
    let metadataAvailable: Bool

    func capabilities() async throws -> NornCapabilities { NornFixtures.snapshot.capabilities }
    func hostMetrics() async throws -> NornHostMetrics { NornFixtures.hostMetrics }
    func health() async throws -> NornHealth { NornFixtures.snapshot.health }
    func serviceManifest() async throws -> NornServiceManifest {
        .init(version: 1, generatedAt: .now, networkMode: "tailnet", services: NornFixtures.snapshot.services)
    }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { NornFixtures.snapshot.operations }
    func operation(id: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }
    func releases() async throws -> NornReleaseList {
        .init(current: NornFixtures.snapshot.releases[0].path, releases: NornFixtures.snapshot.releases)
    }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        NornFixtures.snapshot.operations[0]
    }
    func eventStreamInfo() async throws -> NornEventStreamInfo {
        guard metadataAvailable else { throw MetadataError.unavailable }
        return .init(
            protocolVersion: 1,
            bounds: .init(oldestCursor: 80, latestCursor: 120, retainedEvents: 41),
            gapDetection: true
        )
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(cursor)
                continuation.finish()
            }
        }
    }
}

private actor OverviewRefreshRecorder {
    private var capabilityCalls = 0
    private var deliveredEvent = false

    func recordCapabilityCall() { capabilityCalls += 1 }
    func capabilityCallCount() -> Int { capabilityCalls }
    func recordEventDelivery() { deliveredEvent = true }

    func waitForEventDelivery() async {
        while !deliveredEvent {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForCapabilityCalls(_ expected: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if capabilityCalls >= expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private struct HiddenOverviewEventClient: NornClientProtocol {
    let recorder: OverviewRefreshRecorder

    func capabilities() async throws -> NornCapabilities {
        await recorder.recordCapabilityCall()
        return NornFixtures.snapshot.capabilities
    }
    func hostMetrics() async throws -> NornHostMetrics { NornFixtures.hostMetrics }
    func health() async throws -> NornHealth { NornFixtures.snapshot.health }
    func serviceManifest() async throws -> NornServiceManifest {
        .init(version: 1, generatedAt: .now, networkMode: "tailnet", services: NornFixtures.snapshot.services)
    }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { NornFixtures.snapshot.operations }
    func operation(id: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }
    func releases() async throws -> NornReleaseList {
        .init(current: NornFixtures.snapshot.releases[0].path, releases: NornFixtures.snapshot.releases)
    }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        NornFixtures.snapshot.operations[0]
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                continuation.yield(.init(id: 1, timestamp: .now, type: "app.updated", appID: "orders", payload: .object([:])))
                await recorder.recordEventDelivery()
                try? await Task.sleep(for: .seconds(5))
                continuation.finish()
            }
        }
    }
}

private actor RefreshTrackingClient: NornClientProtocol {
    private var activeCapabilityCalls = 0
    private var peakCapabilityCalls = 0
    private var capabilityCalls = 0
    private var hostMetricCalls = 0
    private var resourceSuggestionCalls = 0

    func resetTracking() {
        activeCapabilityCalls = 0
        peakCapabilityCalls = 0
        capabilityCalls = 0
    }

    func tracking() -> (calls: Int, peak: Int) {
        (capabilityCalls, peakCapabilityCalls)
    }

    func waitForHostMetricCalls(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if hostMetricCalls >= expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func resourceSuggestionCallCount() -> Int { resourceSuggestionCalls }

    func waitForResourceSuggestionCalls(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if resourceSuggestionCalls >= expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func capabilities() async throws -> NornCapabilities {
        capabilityCalls += 1
        activeCapabilityCalls += 1
        peakCapabilityCalls = max(peakCapabilityCalls, activeCapabilityCalls)
        defer { activeCapabilityCalls -= 1 }
        try await Task.sleep(for: .milliseconds(80))
        return NornFixtures.snapshot.capabilities
    }

    func hostMetrics() async throws -> NornHostMetrics {
        hostMetricCalls += 1
        return NornFixtures.hostMetrics
    }
    func resourceSuggestions() async throws -> [NornResourceSuggestion] {
        resourceSuggestionCalls += 1
        return [.init(
            app: "mail", process: "web", declaredMemoryMB: 512,
            declaredCpuMHz: 300, usedMemoryMB: 256, peakMemoryMB: 320,
            cpuPercent: 17.5, status: "right_sized", reason: ""
        )]
    }
    func health() async throws -> NornHealth { NornFixtures.snapshot.health }
    func serviceManifest() async throws -> NornServiceManifest {
        .init(version: 1, generatedAt: .now, networkMode: "tailnet", services: NornFixtures.snapshot.services)
    }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { NornFixtures.snapshot.operations }
    func operation(id: String) async throws -> NornOperation { NornFixtures.snapshot.operations[0] }
    func releases() async throws -> NornReleaseList {
        .init(current: NornFixtures.snapshot.releases[0].path, releases: NornFixtures.snapshot.releases)
    }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        NornFixtures.snapshot.operations[0]
    }
    nonisolated func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in }
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
