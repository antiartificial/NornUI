import XCTest
@testable import NornUI

@MainActor
final class NornAppModelTests: XCTestCase {
    private func releaseQualification(id: String, app: String) -> NornReleaseQualification {
        NornReleaseQualification(
            schemaVersion: "norn.release-qualification/v2",
            id: id,
            deploymentID: "deployment-\(id)",
            app: app,
            sourceSHA: String(repeating: "a", count: 40),
            artifact: "registry.example/\(app)@sha256:\(String(repeating: "b", count: 64))",
            environment: "staging",
            issuedAt: "2026-09-01T00:00:00Z",
            expiresAt: "2026-12-01T00:00:00Z",
            keyID: "test-key",
            signature: "test-signature",
            candidate: NornReleaseCandidate(
                provider: "github-actions",
                repository: "example/\(app)",
                repositoryID: "1",
                ownerID: "2",
                repositoryVisibility: "private",
                runID: "3",
                runAttempt: "1",
                workflowRef: "example/\(app)/.github/workflows/release.yml@\(String(repeating: "c", count: 40))",
                workflowSHA: String(repeating: "c", count: 40),
                signerWorkflowRef: "example/\(app)/.github/workflows/sign.yml@\(String(repeating: "d", count: 40))",
                signerWorkflowSHA: String(repeating: "d", count: 40),
                ref: "refs/heads/main",
                attestation: NornReleaseAttestation(
                    mode: "github-private",
                    verifier: "test verifier",
                    verifierIdentity: nil,
                    issuer: "https://token.actions.githubusercontent.com",
                    subjectDigest: "sha256:\(String(repeating: "b", count: 64))",
                    materialSHA: String(repeating: "a", count: 40),
                    provenanceURI: nil,
                    sbomURI: nil,
                    bundle: nil
                )
            ),
            dsse: NornDSSEEnvelope(
                payloadType: "application/vnd.norn.release-qualification.v2+json",
                payload: "payload-\(id)",
                signatures: [.init(keyID: "test-key", sig: "test-signature")]
            )
        )
    }

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

        let queued = await model.queue(.platformSmoke, context: model.issueMutationContext())
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
        let restarted = await model.restartAppAllocations(for: service, context: model.issueMutationContext())
        XCTAssertEqual(logs, "logs for \(service.app)")
        XCTAssertTrue(restarted)
    }

    func testManagedRuntimeObservabilityRequiresPrincipalDiscoveryDespitePersistedGrants() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profileStore = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(
            name: "Read only",
            baseURL: URL(string: "https://norn.example.test")!,
            deviceID: "device-1",
            tokenID: "token-1",
            grantedScopes: ["api:read", "api:write", "host:operate"]
        )
        profileStore.saveProfiles([profile])
        profileStore.saveSelection(profile.id)
        let model = NornAppModel(profileStore: profileStore, clientFactory: { _ in ScopeProbeClient(principal: nil) })

        await model.start()

        XCTAssertFalse(model.canReadRuntime)
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

        let model = NornAppModel(profileStore: profileStore, clientFactory: { _ in CurrentMetricsClient() })
        await model.start()
        await model.refreshHostMetrics()
        await model.refreshHostMetrics()
        await model.persistMetricsHistory()

        XCTAssertEqual(model.hostMetricsHistory.count, 1)
        XCTAssertEqual(model.hostMetricsHistory.first?.cpuPercent, NornFixtures.hostMetrics.cpu.utilizationPercent)
        XCTAssertEqual(profileStore.loadHostMetricsHistory(profileID: profile.id).count, 1)
    }

    func testHostMetricsBeginPollingWhenHostBecomesVisible() async {
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
        model.setHostVisible(true, profileID: profile.id)

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
        XCTAssertTrue(model.hostMetricsHistory.isEmpty)
        model.setHostVisible(true, profileID: second.id)
        await model.requestMetricsHistory(window: .hour1)
        XCTAssertEqual(model.hostMetricsHistory, [secondSample])
    }

    func testRemovingSelectedProfileCannotContaminateReplacementHistory() async {
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
        model.setHostVisible(true, profileID: second.id)
        await model.requestMetricsHistory(window: .hour1)
        await model.persistMetricsHistory()

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
        let plan = await model.planFleetCapacity(pool: "app", desired: 3, size: "s-4vcpu-8gb", reason: "add headroom", context: model.issueMutationContext())
        XCTAssertEqual(plan?.payload?["proposed"], .object(["desired": .number(3)]))
        XCTAssertEqual(model.fleetPlans.first?.id, plan?.id)
        XCTAssertEqual(model.fleetReconciliations[plan?.id ?? ""], [])

        let retry = await model.planFleetCapacity(pool: "app", desired: 3, size: "s-4vcpu-8gb", reason: "add headroom", context: model.issueMutationContext())
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
        let queued = await model.queue(.platformSmoke, context: model.issueMutationContext())
        XCTAssertNil(queued)
    }

    func testFleetCapacityUsesHumanAPIWriteNotRunnerOperateScope() async {
        let cases: [([String], Bool)] = [
            (["api:read", "fleet:operate"], false),
            (["api:read", "api:write"], true),
        ]
        for (index, item) in cases.enumerated() {
            let suite = "\(#function)-\(index)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = NornProfileStore(defaults: defaults)
            let profile = NornServerProfile(name: "Fleet", baseURL: URL(string: "https://fleet.example.test")!)
            store.saveProfiles([profile])
            store.saveSelection(profile.id)
            let principal = NornCapabilities.Authentication.Principal(
                authenticated: true,
                subject: "engineer",
                scopes: item.0
            )
            let model = NornAppModel(profileStore: store, clientFactory: { _ in ScopeProbeClient(principal: principal) })
            await model.start()
            XCTAssertEqual(model.canOperateFleet, item.1)
        }
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

    func testProfileBoundMutationContextRejectsQueuedAIntentAfterAuthorizedSwitchToB() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profileA = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        let profileB = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
        store.saveProfiles([profileA, profileB])
        store.saveSelection(profileA.id)
        let bCalls = MutationCallCounter()
        let model = NornAppModel(profileStore: store, clientFactory: { profile in
            CountingMutationClient(counter: profile.id == profileB.id ? bCalls : MutationCallCounter())
        })
        await model.start()
        XCTAssertTrue(model.canManageAppRecovery, "A must have the exact recovery authority before its token is captured")
        let contextFromA = model.issueMutationContext()

        await model.selectProfile(id: profileB.id)
        XCTAssertTrue(model.canRunHostAssurance)
        XCTAssertTrue(model.canManageAppRecovery)

        let host = await model.queue(.hostAssurance, context: contextFromA)
        let app = await model.queueAppOperation(.snapshot(app: "mail-mcp"), context: contextFromA)

        XCTAssertNil(host)
        XCTAssertNil(app)
        let calls = await bCalls.mutations()
        XCTAssertEqual(calls, [], "An A context must not dispatch through authorized B, even for the same app name")
    }

    func testProfileSwitchDropsEveryDeferredFleetAndMetricsResponse() async {
        for endpoint in ["fleetInventory", "fleetReconciliations", "fleetRunnerAttempts", "deployments", "hostMetrics"] {
            let suite = "\(#function).\(endpoint)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = NornProfileStore(defaults: defaults)
            let first = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
            let second = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
            store.saveProfiles([first, second])
            store.saveSelection(first.id)
            let oldControl = DeferredResponseControl()
            let model = NornAppModel(profileStore: store, clientFactory: { profile in
                profile.id == first.id
                    ? InterleavingClient(marker: "A", control: oldControl)
                    : InterleavingClient(marker: "B", control: DeferredResponseControl())
            })
            await model.start()
            await oldControl.block(endpoint)

            let refresh: Task<Void, Never>
            if endpoint == "hostMetrics" {
                refresh = Task { await model.refreshHostMetrics() }
            } else {
                refresh = Task { await model.refreshFleet() }
            }
            await oldControl.waitUntilCalled(endpoint)
            await model.selectProfile(id: second.id)
            await oldControl.release(endpoint)
            await refresh.value

            XCTAssertEqual(model.snapshot.capabilities.serverVersion, "B", "old \(endpoint) response replaced the selected profile")
            XCTAssertFalse(model.fleetPlans.contains { $0.id.hasPrefix("A-") })
            XCTAssertFalse(model.fleetReconciliations.keys.contains { $0.hasPrefix("A-") })
            XCTAssertFalse(model.fleetRunnerAttempts.keys.contains { $0.hasPrefix("A-") })
            XCTAssertFalse(model.deployments.contains { $0.id.hasPrefix("A-") })
            XCTAssertNotEqual(model.hostMetrics?.cpu.utilizationPercent, 11)
            XCTAssertNil(model.lastError)
        }
    }

    func testDeploymentInventoryDoesNotLoadStepsUntilSelected() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let control = DeferredResponseControl()
        let model = NornAppModel(profileStore: store, clientFactory: { _ in InterleavingClient(marker: "A", control: control) })
        await model.start()
        XCTAssertEqual(model.deployments.first?.id, "A-deployment")
        let eagerlyLoaded = await control.wasCalled("deploymentSteps")
        XCTAssertFalse(eagerlyLoaded, "Inventory must publish without serial detail requests")

        await control.block("deploymentSteps", failing: true)
        model.navigation = .delivery
        model.setDeploymentActivityVisible(true, profileID: profile.id)
        model.selectDeployment(id: "A-deployment")
        await control.waitUntilCalled("deploymentSteps")
        XCTAssertTrue(model.deploymentStepLoadingIDs.contains("A-deployment"))
        await control.release("deploymentSteps")
        for _ in 0..<100 where model.deploymentStepErrors["A-deployment"] == nil {
            await Task.yield()
        }
        XCTAssertNotNil(model.deploymentStepErrors["A-deployment"], "A failed detail request must not masquerade as empty steps")
        model.setDeploymentActivityVisible(false, profileID: profile.id)
        XCTAssertTrue(model.deploymentStepLoadingIDs.isEmpty)
    }

    func testLeavingDeploymentActivityClearsActiveClaims() async {
        let model = NornAppModel(fixture: NornFixtures.snapshot)
        var operation = NornFixtures.snapshot.operations[0]
        operation.kind = "app.deploy"
        operation.status = .running
        model.activeDeploymentOperations = [operation]
        model.setDeploymentActivityVisible(false, profileID: model.selectedProfileID)
        XCTAssertTrue(model.activeDeploymentOperations.isEmpty)
        XCTAssertTrue(model.deploymentStepLoadingIDs.isEmpty)
    }

    func testDeploymentStepResponseCannotCrossProfileBoundary() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        let second = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
        store.saveProfiles([first, second])
        store.saveSelection(first.id)
        let oldControl = DeferredResponseControl()
        let model = NornAppModel(profileStore: store, clientFactory: { profile in
            InterleavingClient(marker: profile.id == first.id ? "A" : "B", control: profile.id == first.id ? oldControl : DeferredResponseControl())
        })
        await model.start()
        await oldControl.block("deploymentSteps")
        model.navigation = .delivery
        model.setDeploymentActivityVisible(true, profileID: first.id)
        model.selectDeployment(id: "A-deployment")
        await oldControl.waitUntilCalled("deploymentSteps")
        await model.selectProfile(id: second.id)
        await oldControl.release("deploymentSteps")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.deploymentSteps["A-deployment"])
        XCTAssertNil(model.selectedDeploymentID)
        model.setDeploymentActivityVisible(false, profileID: second.id)
    }

    func testOverviewFetchesOnlyThreeVisibleGraphsAndNotHiddenSelection() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let control = DeferredResponseControl()
        let operations = (0..<4).map { index in
            var operation = NornFixtures.snapshot.operations[0]
            operation.id = "op-\(index)"
            operation.sagaID = "saga-\(index)"
            operation.status = .running
            operation.startedAt = Date(timeIntervalSince1970: 10_000 - Double(index))
            return operation
        }
        let deployments = (0..<4).map { index in
            var deployment = NornFixtures.deployments[0]
            deployment.id = "deployment-\(index)"
            deployment.sagaID = "saga-\(index)"
            return deployment
        }
        let model = NornAppModel(profileStore: store, clientFactory: { _ in
            InterleavingClient(marker: "A", control: control, hudOperations: operations, hudDeployments: deployments)
        })
        await model.start()
        model.navigation = .overview
        model.selectedDeploymentID = "hidden-selection"
        model.setDeploymentActivityVisible(true, profileID: profile.id)
        await control.waitUntilCalled("step:deployment-0")
        await control.waitUntilCalled("step:deployment-1")
        await control.waitUntilCalled("step:deployment-2")
        let fourth = await control.wasCalled("step:deployment-3")
        let hidden = await control.wasCalled("step:hidden-selection")
        XCTAssertFalse(fourth)
        XCTAssertFalse(hidden)
        XCTAssertEqual(model.activePlatformOperations.count, 4)
        model.setDeploymentActivityVisible(false, profileID: profile.id)
    }

    func testOverviewStepReplyIsDiscardedAfterLeavingView() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        store.saveProfiles([profile])
        store.saveSelection(profile.id)
        let control = DeferredResponseControl()
        var operation = NornFixtures.snapshot.operations[0]
        operation.status = .running
        operation.sagaID = "live-saga"
        var deployment = NornFixtures.deployments[0]
        deployment.id = "live-deployment"
        deployment.sagaID = "live-saga"
        let model = NornAppModel(profileStore: store, clientFactory: { _ in
            InterleavingClient(marker: "A", control: control, hudOperations: [operation], hudDeployments: [deployment])
        })
        await model.start()
        await control.block("deploymentSteps")
        model.navigation = .overview
        model.setDeploymentActivityVisible(true, profileID: profile.id)
        await control.waitUntilCalled("deploymentSteps")
        model.navigation = .host
        model.setDeploymentActivityVisible(false, profileID: profile.id)
        await control.release("deploymentSteps")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(model.deploymentSteps["live-deployment"])
        XCTAssertFalse(model.isDeploymentActivityRefreshing)
    }

    func testRuntimeScalingStopsAfterProfileSwitchAndDoesNotPublishOldFeedback() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        let second = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
        store.saveProfiles([first, second]); store.saveSelection(first.id)
        let control = DeferredResponseControl()
        let model = NornAppModel(profileStore: store, clientFactory: { profile in
            InterleavingClient(marker: profile.id == first.id ? "A" : "B", control: profile.id == first.id ? control : DeferredResponseControl())
        })
        await model.start()
        model.snapshot.apps = [.init(spec: .init(name: "scale-test", deploy: true, processes: ["web": .init(scaling: nil), "worker": .init(scaling: nil)]), nomadStatus: "running", healthy: true)]
        model.snapshot.operations = []
        await control.block("scale:web:0")
        let context = model.issueMutationContext()
        async let mutation: Void = model.scaleAppRuntime(app: "scale-test", targets: [.init(process: "web", count: 0), .init(process: "worker", count: 0)], context: context)
        await control.waitUntilCalled("scale:web:0")
        await model.selectProfile(id: second.id)
        await control.release("scale:web:0")
        await mutation
        let workerCalled = await control.wasCalled("scale:worker:0")
        XCTAssertFalse(workerCalled)
        XCTAssertNil(model.runtimeScaleFeedback["scale-test"])
        XCTAssertFalse(model.scalingRuntimeApps.contains("scale-test"))
    }

    func testRuntimeScalingReportsPartialAcceptanceAndStopsAfterFailure() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        store.saveProfiles([profile]); store.saveSelection(profile.id)
        let control = DeferredResponseControl()
        let model = NornAppModel(profileStore: store, clientFactory: { _ in InterleavingClient(marker: "A", control: control) })
        await model.start()
        model.snapshot.apps = [.init(spec: .init(name: "scale-test", deploy: true, processes: ["web": .init(scaling: nil), "worker": .init(scaling: nil), "third": .init(scaling: nil)]), nomadStatus: "running", healthy: true)]
        model.snapshot.operations = []
        await control.block("scale:worker:0", failing: true)
        let context = model.issueMutationContext()
        async let mutation: Void = model.scaleAppRuntime(app: "scale-test", targets: [.init(process: "web", count: 0), .init(process: "worker", count: 0), .init(process: "third", count: 0)], context: context)
        await control.waitUntilCalled("scale:worker:0")
        await control.release("scale:worker:0")
        await mutation
        let webCalled = await control.wasCalled("scale:web:0")
        let thirdCalled = await control.wasCalled("scale:third:0")
        XCTAssertTrue(webCalled)
        XCTAssertFalse(thirdCalled)
        XCTAssertTrue(model.runtimeScaleFeedback["scale-test"]?.contains("Accepted: web → 0") == true)
        XCTAssertTrue(model.runtimeScaleFeedback["scale-test"]?.contains("Could not confirm worker") == true)
        XCTAssertFalse(model.scalingRuntimeApps.contains("scale-test"))
    }

    func testProfileSwitchDropsDeferredMutationSuccessAndFailure() async {
        for shouldFail in [false, true] {
            let suite = "\(#function).\(shouldFail)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = NornProfileStore(defaults: defaults)
            let first = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
            let second = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
            store.saveProfiles([first, second])
            store.saveSelection(first.id)
            let oldControl = DeferredResponseControl()
            let model = NornAppModel(profileStore: store, clientFactory: { profile in
                profile.id == first.id
                    ? InterleavingClient(marker: "A", control: oldControl)
                    : InterleavingClient(marker: "B", control: DeferredResponseControl())
            })
            await model.start()
            await oldControl.block("queueMutation", failing: shouldFail)
            XCTAssertTrue(model.canRunHostAssurance)

            let context = model.issueMutationContext()
            async let mutation: NornOperation? = model.queue(.hostAssurance, context: context)
            await oldControl.waitUntilCalled("queueMutation")
            await model.selectProfile(id: second.id)
            await oldControl.release("queueMutation")
            let result = await mutation
            XCTAssertNil(result)
            XCTAssertFalse(model.snapshot.operations.contains { $0.id.hasPrefix("A-mutation") })
            XCTAssertNil(model.lastError, "an old mutation failure must not surface on profile B")
        }
    }

    func testExactScopesAndAuthorityGuardNavigationAndOperations() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Fleet", baseURL: URL(string: "https://fleet.example.test")!)
        store.saveProfiles([profile]); store.saveSelection(profile.id)
        let principal = NornCapabilities.Authentication.Principal(authenticated: true, subject: "operator", scopes: ["api:read"])
        let model = NornAppModel(profileStore: store, clientFactory: { _ in ScopeProbeClient(principal: principal, authority: "fleet-only") })
        await model.start()

        XCTAssertFalse(model.canManageApps)
        XCTAssertFalse(model.canManageAppRecovery)
        XCTAssertFalse(model.canRunHostAssurance)
        XCTAssertFalse(model.canMutateLegacyReleaseEvidence)
        model.navigate(to: .apps)
        XCTAssertEqual(model.navigation, .fleet)
        XCTAssertNotNil(model.lastError)
        let operation = NornFixtures.snapshot.operations[0]
        model.openOperation(operation)
        XCTAssertEqual(model.navigation, .fleet)
        let hostOperation = await model.queue(.hostAssurance, context: model.issueMutationContext())
        let appOperation = await model.queueAppOperation(.snapshot(app: "mail-mcp"), context: model.issueMutationContext())
        XCTAssertNil(hostOperation)
        XCTAssertNil(appOperation)
    }

    func testAppRecoveryHostAndLegacyReleaseControlsRequireTheirExactReturnedScopes() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Scoped", baseURL: URL(string: "https://scoped.example.test")!)
        store.saveProfiles([profile]); store.saveSelection(profile.id)
        let readOnly = NornCapabilities.Authentication.Principal(authenticated: true, subject: "reader", scopes: ["api:read"])
        let model = NornAppModel(profileStore: store, clientFactory: { _ in
            ScopeProbeClient(principal: readOnly, supportsAppCreation: true, supportsReleasePipeline: true)
        })
        await model.start()
        XCTAssertFalse(model.canManageApps, "Enable deployment must require api:write plus app capability")
        XCTAssertFalse(model.canManageAppRecovery, "Snapshot/migrate/prune/restore/rollback must require api:write plus recovery capability")
        XCTAssertFalse(model.canRunHostAssurance, "Host assurance must not inherit api:read")
        XCTAssertFalse(model.canMutateLegacyReleaseEvidence, "Legacy release mutation must require authenticated api:write")
        for request in [
            NornAppOperationRequest.snapshot(app: "mail-mcp"),
            .migrate(app: "mail-mcp", ref: "HEAD"),
            .pruneSnapshots(app: "mail-mcp", keep: 2),
            .restoreSnapshot(app: "mail-mcp", snapshot: "safe.dump"),
            .rollback(app: "mail-mcp", regions: [])
        ] {
            let operation = await model.queueAppOperation(request, context: model.issueMutationContext())
            XCTAssertNil(operation)
        }
        let assurance = await model.queue(.hostAssurance, context: model.issueMutationContext())
        XCTAssertNil(assurance)

        let writableDefaults = UserDefaults(suiteName: "\(suite).writer")!
        writableDefaults.removePersistentDomain(forName: "\(suite).writer")
        let writableStore = NornProfileStore(defaults: writableDefaults)
        let writableProfile = NornServerProfile(name: "Writer", baseURL: URL(string: "https://writer.example.test")!)
        writableStore.saveProfiles([writableProfile]); writableStore.saveSelection(writableProfile.id)
        let writer = NornCapabilities.Authentication.Principal(authenticated: true, subject: "writer", scopes: ["api:read", "api:write", "host:operate"])
        let writableModel = NornAppModel(profileStore: writableStore, clientFactory: { _ in
            ScopeProbeClient(principal: writer, supportsAppCreation: true, supportsReleasePipeline: true)
        })
        await writableModel.start()
        XCTAssertTrue(writableModel.canManageApps)
        XCTAssertTrue(writableModel.canManageAppRecovery)
        XCTAssertTrue(writableModel.canRunHostAssurance)
        XCTAssertTrue(writableModel.canMutateLegacyReleaseEvidence)
    }

    func testAuthorityBannerAssertionsDoNotInventEnvironmentOrMini() async {
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.auth.principal = .init(authenticated: true, subject: "operator", scopes: ["api:read"])
        capabilities.authority = nil
        capabilities.environment = nil
        XCTAssertNil(capabilities.assertedEnvironmentID)
        XCTAssertNil(capabilities.assertedEnvironmentProfile)
        XCTAssertNil(capabilities.authority)
        XCTAssertFalse(capabilities.isFleetAuthorityOnly)

        capabilities.authority = "fleet-only"
        capabilities.environment = .init(id: "staging", profile: "managed")
        XCTAssertTrue(capabilities.isFleetAuthorityOnly)
        XCTAssertEqual(capabilities.assertedEnvironmentID, "staging")
        XCTAssertEqual(capabilities.assertedEnvironmentProfile, "managed")
    }

    func testProfileBoundaryClearsPriorErrorBeforeTheNextProfileConnects() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let first = NornServerProfile(name: "A", baseURL: URL(string: "https://a.example.test")!)
        let second = NornServerProfile(name: "B", baseURL: URL(string: "https://b.example.test")!)
        store.saveProfiles([first, second]); store.saveSelection(first.id)
        let model = NornAppModel(profileStore: store, clientFactory: { _ in ScopeProbeClient() })
        await model.start()
        model.lastError = "A-only failure"
        await model.selectProfile(id: second.id)
        XCTAssertEqual(model.selectedProfileID, second.id)
        XCTAssertNil(model.lastError)
    }

    func testEventReconnectFailureKeepsOnlyProfileKeyedCacheMarkedStale() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = NornProfileStore(defaults: defaults)
        let profile = NornServerProfile(name: "Event", baseURL: URL(string: "https://events.example.test")!)
        store.saveProfiles([profile]); store.saveSelection(profile.id)
        let counter = EventReconnectCounter()
        let model = NornAppModel(profileStore: store, clientFactory: { _ in EventReconnectFailureClient(counter: counter) })
        await model.start()
        model.hostMetrics = NornFixtures.hostMetrics
        await counter.waitUntilRefreshStarts()
        // A failed event stream already puts this profile in reconnecting, and
        // the next stream may immediately begin another reconnect cycle after
        // the authoritative refresh fails. Assert the durable observable
        // contract instead of sampling the transient offline state.
        XCTAssertTrue(model.hasStaleCachedConnectionState)
        XCTAssertFalse(model.snapshot.services.isEmpty)
        XCTAssertTrue(model.hostMetrics?.stale == true, "Retained host metrics must be marked stale through reconnect and offline transitions")
        XCTAssertNotNil(model.lastError)
    }

    func testReleaseQualificationLoaderDropsDelayedEvidenceAfterProfileSwitch() async {
        let loader = ReleaseQualificationEvidenceLoader()
        let control = ContextLoadControl()
        let app = "orders"
        let first = NornProfileAppContext(profileID: UUID(), appID: app, isActive: true)
        let second = NornProfileAppContext(profileID: UUID(), appID: app, isActive: true)
        let firstEvidence = releaseQualification(id: "A-evidence", app: app)
        let secondEvidence = releaseQualification(id: "B-evidence", app: app)

        let firstLoad = Task { await loader.reload(for: first) { _ in await control.wait(for: "A"); return [firstEvidence] } }
        await control.waitUntilStarted("A")

        let secondLoad = Task { await loader.reload(for: second) { _ in await control.wait(for: "B"); return [secondEvidence] } }
        await control.waitUntilStarted("B")
        XCTAssertTrue(loader.qualifications.isEmpty, "The coordinated B transition clears A evidence before B returns")
        await control.release("B")
        await secondLoad.value
        XCTAssertEqual(loader.loadedContext, second)
        XCTAssertEqual(loader.qualifications.map(\.id), ["B-evidence"])

        await control.release("A")
        await firstLoad.value
        XCTAssertEqual(loader.loadedContext, second, "Delayed evidence from profile A must not appear under profile B")
        XCTAssertEqual(loader.qualifications.map(\.id), ["B-evidence"], "Only B's signed evidence may be rendered after A returns")
    }

    func testReleaseQualificationLoaderDropsDelayedEvidenceAfterAppSwitch() async {
        let loader = ReleaseQualificationEvidenceLoader()
        let control = ContextLoadControl()
        let profileID = UUID()
        let first = NornProfileAppContext(profileID: profileID, appID: "orders", isActive: true)
        let second = NornProfileAppContext(profileID: profileID, appID: "billing", isActive: true)
        let firstEvidence = releaseQualification(id: "orders-evidence", app: "orders")
        let secondEvidence = releaseQualification(id: "billing-evidence", app: "billing")

        let firstLoad = Task { await loader.reload(for: first) { _ in await control.wait(for: "A"); return [firstEvidence] } }
        await control.waitUntilStarted("A")

        let secondLoad = Task { await loader.reload(for: second) { _ in await control.wait(for: "B"); return [secondEvidence] } }
        await control.waitUntilStarted("B")
        await control.release("B")
        await secondLoad.value
        await control.release("A")
        await firstLoad.value

        XCTAssertEqual(loader.loadedContext, second, "Evidence fetched for orders must not appear while billing is selected")
        XCTAssertEqual(loader.qualifications.map(\.id), ["billing-evidence"])
    }

    func testAppRecoverySnapshotLoaderCannotRestoreDelayedFilenamesIntoNewApp() async {
        let loader = AppRecoverySnapshotLoader()
        let control = ContextLoadControl()
        let profileID = UUID()
        let first = NornProfileAppContext(profileID: profileID, appID: "orders", isActive: true)
        let second = NornProfileAppContext(profileID: profileID, appID: "billing", isActive: true)
        var oldSnapshot = NornFixtures.appSnapshots[0]
        oldSnapshot.filename = "orders-only.dump"
        var currentSnapshot = NornFixtures.appSnapshots[0]
        currentSnapshot.filename = "billing-current.dump"

        let firstLoad = Task { await loader.reload(for: first) { _ in await control.wait(for: "A"); return [oldSnapshot] } }
        await control.waitUntilStarted("A")

        let secondLoad = Task { await loader.reload(for: second) { _ in await control.wait(for: "B"); return [currentSnapshot] } }
        await control.waitUntilStarted("B")
        XCTAssertTrue(loader.snapshots.isEmpty, "The coordinated B transition clears restore candidates before B returns")
        await control.release("B")
        await secondLoad.value
        await control.release("A")
        await firstLoad.value

        XCTAssertEqual(loader.loadedContext, second)
        XCTAssertEqual(loader.snapshots.map(\.filename), ["billing-current.dump"], "A delayed response must not make an old filename restorable in the current app")
    }

    func testReleaseAppSelectionNormalizesStaleASelectionForBDifferentAppSet() {
        var appA = NornFixtures.snapshot.apps[0]
        appA.spec.name = "orders"
        var appB = NornFixtures.snapshot.apps[0]
        appB.spec.name = "billing"

        let selectedOnA = NornReleaseAppSelection.normalized("orders", in: [appA])
        let selectedOnB = NornReleaseAppSelection.normalized(selectedOnA, in: [appB])

        XCTAssertEqual(selectedOnB, "billing", "A nonempty stale selection must normalize to B's available application")
    }

    func testDraftEnableConfirmationCannotDispatchToAuthorizedProfileBWithTheSameAppName() {
        let profileA = UUID()
        let profileB = UUID()
        let appName = "orders"
        var gate = NornProfileBoundMutationGate<String>()
        var profileBMutationCalls = 0

        gate.present(appName, profileID: profileA, isAuthorized: true)
        if let appID = gate.confirmedIntent(profileID: profileB, isAuthorized: true, isStillCurrent: { $0 == appName }) {
            XCTAssertEqual(appID, appName)
            profileBMutationCalls += 1
        }

        XCTAssertEqual(profileBMutationCalls, 0, "An A draft confirmation must not enable the same-named app through B's authorized client")
    }

    func testCreateDraftPresentationCannotDispatchToAuthorizedProfileB() {
        let profileA = UUID()
        let profileB = UUID()
        let request = NornCreateAppRequest(name: "orders", kind: .endpoint, port: 8080)
        var gate = NornProfileBoundMutationGate<NornCreateAppRequest>()
        var profileBMutationCalls = 0

        gate.present(request, profileID: profileA, isAuthorized: true)
        if let dispatched = gate.confirmedIntent(profileID: profileB, isAuthorized: true, isStillCurrent: { $0 == request }) {
            XCTAssertEqual(dispatched, request)
            profileBMutationCalls += 1
        }

        XCTAssertEqual(profileBMutationCalls, 0)
    }

    func testFleetCapacityPresentationCannotDispatchToAuthorizedProfileBWithTheSamePool() {
        let profileA = UUID()
        let profileB = UUID()
        let pool = "app"
        var gate = NornProfileBoundMutationGate<String>()
        var profileBMutationCalls = 0

        gate.present(pool, profileID: profileA, isAuthorized: true)
        if let dispatched = gate.confirmedIntent(profileID: profileB, isAuthorized: true, isStillCurrent: { $0 == pool }) {
            XCTAssertEqual(dispatched, pool)
            profileBMutationCalls += 1
        }

        XCTAssertEqual(profileBMutationCalls, 0)
    }

    func testPlatformActionPresentationCannotDispatchToAuthorizedProfileB() {
        let profileA = UUID()
        let profileB = UUID()
        let request = NornMaintenanceRequest.platformSmoke
        var gate = NornProfileBoundMutationGate<NornMaintenanceRequest>()
        var profileBMutationCalls = 0

        gate.present(request, profileID: profileA, isAuthorized: true)
        if let dispatched = gate.confirmedIntent(profileID: profileB, isAuthorized: true, isStillCurrent: { $0 == request }) {
            XCTAssertEqual(dispatched, request)
            profileBMutationCalls += 1
        }

        XCTAssertEqual(profileBMutationCalls, 0)
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

private actor MutationCallCounter {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func mutations() -> [String] { values }
}

private struct CountingMutationClient: NornClientProtocol {
    let counter: MutationCallCounter
    private let base = MockNornClient()

    func capabilities() async throws -> NornCapabilities {
        var capabilities = try await base.capabilities()
        capabilities.auth.principal?.scopes.append("api:write")
        return capabilities
    }
    func hostMetrics() async throws -> NornHostMetrics { try await base.hostMetrics() }
    func health() async throws -> NornHealth { try await base.health() }
    func serviceManifest() async throws -> NornServiceManifest { try await base.serviceManifest() }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { try await base.operations(activeOnly: activeOnly, limit: limit) }
    func operation(id: String) async throws -> NornOperation { try await base.operation(id: id) }
    func releases() async throws -> NornReleaseList { try await base.releases() }
    func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation {
        await counter.record("app:\(request.app)")
        return try await base.queue(.hostAssurance, idempotencyKey: idempotencyKey)
    }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        await counter.record("maintenance")
        return try await base.queue(request, idempotencyKey: idempotencyKey)
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> { base.events(after: cursor) }
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
        AsyncThrowingStream { _ in }
    }

    private enum MetricsError: Error {
        case unavailable
    }
}

private struct CurrentMetricsClient: NornClientProtocol {
    private let base = MockNornClient()
    private let sampleDate = Date.now

    func capabilities() async throws -> NornCapabilities { try await base.capabilities() }
    func hostMetrics() async throws -> NornHostMetrics {
        var metrics = NornFixtures.hostMetrics
        metrics.observedAt = sampleDate
        return metrics
    }
    func health() async throws -> NornHealth { try await base.health() }
    func serviceManifest() async throws -> NornServiceManifest { try await base.serviceManifest() }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { try await base.operations(activeOnly: activeOnly, limit: limit) }
    func operation(id: String) async throws -> NornOperation { try await base.operation(id: id) }
    func releases() async throws -> NornReleaseList { try await base.releases() }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation { try await base.queue(request, idempotencyKey: idempotencyKey) }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> { AsyncThrowingStream { _ in } }
}

private struct ScopeProbeClient: NornClientProtocol {
    let principal: NornCapabilities.Authentication.Principal?
    let authority: String?
    let failsCapabilities: Bool
    let supportsAppCreation: Bool
    let supportsReleasePipeline: Bool
    private let base = MockNornClient()

    init(
        principal: NornCapabilities.Authentication.Principal? = NornFixtures.snapshot.capabilities.auth.principal,
        authority: String? = nil,
        failsCapabilities: Bool = false,
        supportsAppCreation: Bool = false,
        supportsReleasePipeline: Bool = false
    ) {
        self.principal = principal
        self.authority = authority
        self.failsCapabilities = failsCapabilities
        self.supportsAppCreation = supportsAppCreation
        self.supportsReleasePipeline = supportsReleasePipeline
    }

    func capabilities() async throws -> NornCapabilities {
        if failsCapabilities { throw URLError(.cannotConnectToHost) }
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.auth.principal = principal
        capabilities.authority = authority
        if authority == "fleet-only" { capabilities.features.append("fleet-authority-only-v1") }
        if supportsAppCreation {
            capabilities.features.append("app-creation")
            capabilities.endpoints["appCreation"] = "/api/v1/apps"
        }
        if supportsReleasePipeline {
            capabilities.features.append(contentsOf: ["release-provenance-v1", "release-qualifications-v2", "release-promotions-v1"])
        }
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

private enum DeferredResponseError: Error { case unavailable }

/// A deterministic test double: an endpoint cannot finish until the test
/// explicitly releases it. This makes A→B profile-switch races reproducible
/// without sleeps or timing assumptions.
private actor DeferredResponseControl {
    private var blocked: Set<String> = []
    private var failures: Set<String> = []
    private var calls: Set<String> = []
    private var responseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var callWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func block(_ endpoint: String, failing: Bool = false) {
        blocked.insert(endpoint)
        if failing { failures.insert(endpoint) }
    }

    func checkpoint(_ endpoint: String) async throws {
        calls.insert(endpoint)
        let notified = callWaiters.removeValue(forKey: endpoint) ?? []
        notified.forEach { $0.resume() }
        if blocked.contains(endpoint) {
            await withCheckedContinuation { continuation in
                responseWaiters[endpoint, default: []].append(continuation)
            }
        }
        if failures.contains(endpoint) { throw DeferredResponseError.unavailable }
    }

    func wasCalled(_ endpoint: String) -> Bool { calls.contains(endpoint) }

    func waitUntilCalled(_ endpoint: String) async {
        guard !calls.contains(endpoint) else { return }
        await withCheckedContinuation { continuation in
            callWaiters[endpoint, default: []].append(continuation)
        }
    }

    func release(_ endpoint: String) {
        blocked.remove(endpoint)
        let waiters = responseWaiters.removeValue(forKey: endpoint) ?? []
        waiters.forEach { $0.resume() }
    }
}

/// Continuation-controlled loader responses keep context races deterministic;
/// no test depends on task scheduling delays or wall-clock sleeps.
private actor ContextLoadControl {
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var responseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(for key: String) async {
        started.insert(key)
        let observers = startWaiters.removeValue(forKey: key) ?? []
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            responseWaiters[key, default: []].append(continuation)
        }
    }

    func waitUntilStarted(_ key: String) async {
        guard !started.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        let waiters = responseWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
    }
}

private struct InterleavingClient: NornClientProtocol {
    let marker: String
    let control: DeferredResponseControl
    var hudOperations: [NornOperation]? = nil
    var hudDeployments: [NornDeployment]? = nil
    private let base = MockNornClient()

    func scaleApp(app: String, process: String, count: Int) async throws {
        try await control.checkpoint("scale:\(process):\(count)")
    }

    func capabilities() async throws -> NornCapabilities {
        var capabilities = try await base.capabilities()
        capabilities.serverVersion = marker
        capabilities.features.append("app-creation")
        capabilities.endpoints["appCreation"] = "/api/v1/apps"
        capabilities.auth.principal?.scopes = ["api:read", "api:write", "fleet:operate", "host:operate", "platform:operate"]
        capabilities.environment = .init(id: marker == "A" ? "development" : "staging", profile: "profile-\(marker)")
        return capabilities
    }

    func hostMetrics() async throws -> NornHostMetrics {
        try await control.checkpoint("hostMetrics")
        var metrics = NornFixtures.hostMetrics
        metrics.cpu.utilizationPercent = marker == "A" ? 11 : 77
        return metrics
    }
    func health() async throws -> NornHealth { try await base.health() }
    func hostStatus() async throws -> NornHostStatus { try await base.hostStatus() }
    func serviceManifest() async throws -> NornServiceManifest { try await base.serviceManifest() }
    func apps() async throws -> [NornAppStatus] { try await base.apps() }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] {
        if let hudOperations { return hudOperations }
        return try await base.operations(activeOnly: activeOnly, limit: limit)
    }
    func operation(id: String) async throws -> NornOperation { try await base.operation(id: id) }
    func releases() async throws -> NornReleaseList { try await base.releases() }
    func fleetInventory() async throws -> NornFleetInventory {
        try await control.checkpoint("fleetInventory")
        return try await base.fleetInventory()
    }
    func fleetPlans() async throws -> [NornOperation] {
        try await control.checkpoint("fleetPlans")
        return [plan]
    }
    func fleetReconciliations(planID: String) async throws -> NornFleetReconciliationList {
        try await control.checkpoint("fleetReconciliations")
        return .init(schemaVersion: "norn.fleet-reconciliation/v1", planID: planID, reconciliations: [], count: 0)
    }
    func fleetRunnerAttempts(planID: String) async throws -> NornFleetRunnerAttemptList {
        try await control.checkpoint("fleetRunnerAttempts")
        return .init(schemaVersion: "norn.fleet-runner-attempt/v1", planID: planID, attempts: [], count: 0, serverTime: .now)
    }
    func fleetGitHubStatus() async throws -> NornFleetGitHubStatus { try await base.fleetGitHubStatus() }
    func deployments() async throws -> [NornDeployment] {
        try await control.checkpoint("deployments")
        if let hudDeployments { return hudDeployments }
        var deployment = NornFixtures.deployments[0]
        deployment.id = "\(marker)-deployment"
        return [deployment]
    }
    func deploymentSteps(deploymentID: String) async throws -> [NornDeploymentStep] {
        try await control.checkpoint("step:\(deploymentID)")
        try await control.checkpoint("deploymentSteps")
        return []
    }
    func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation {
        try await control.checkpoint("queueAppOperation")
        var operation = plan
        operation.id = "\(marker)-mutation-\(idempotencyKey)"
        return operation
    }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        try await control.checkpoint("queueMutation")
        var operation = plan
        operation.id = "\(marker)-mutation-\(idempotencyKey)"
        return operation
    }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    private var plan: NornOperation {
        var operation = NornFixtures.snapshot.operations[0]
        operation.id = "\(marker)-plan"
        operation.kind = "fleet.capacity-plan"
        return operation
    }
}

private actor EventReconnectCounter {
    private var capabilityCalls = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    func nextCapabilitiesShouldFail() -> Bool {
        capabilityCalls += 1
        let isRefresh = capabilityCalls > 1
        if isRefresh {
            let waiters = refreshWaiters
            refreshWaiters = []
            waiters.forEach { $0.resume() }
        }
        return isRefresh
    }
    func waitUntilRefreshStarts() async {
        guard capabilityCalls < 2 else { return }
        await withCheckedContinuation { refreshWaiters.append($0) }
    }
}

private struct EventReconnectFailureClient: NornClientProtocol {
    private let counter: EventReconnectCounter
    private let base = MockNornClient()

    init(counter: EventReconnectCounter) { self.counter = counter }

    func capabilities() async throws -> NornCapabilities {
        if await counter.nextCapabilitiesShouldFail() { throw DeferredResponseError.unavailable }
        return try await base.capabilities()
    }
    func hostMetrics() async throws -> NornHostMetrics { try await base.hostMetrics() }
    func health() async throws -> NornHealth { try await base.health() }
    func serviceManifest() async throws -> NornServiceManifest { try await base.serviceManifest() }
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] { try await base.operations(activeOnly: activeOnly, limit: limit) }
    func operation(id: String) async throws -> NornOperation { try await base.operation(id: id) }
    func releases() async throws -> NornReleaseList { try await base.releases() }
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation { try await base.queue(request, idempotencyKey: idempotencyKey) }
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DeferredResponseError.unavailable) }
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
