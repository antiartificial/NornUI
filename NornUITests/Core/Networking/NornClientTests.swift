import Foundation
import XCTest
@testable import NornUI

@MainActor
final class NornClientTests: XCTestCase {
    override func tearDown() {
        NornURLProtocol.reset()
        super.tearDown()
    }

    func testCapabilitiesUsesBearerHeaderAndV1Route() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(
                request,
                status: 200,
                body: """
                {"protocolVersion":1,"serverVersion":"v2.16.2-control","features":["event-cursor-replay","principal-scope-discovery-v1"],"auth":{"scopes":["api:read","api:write"],"websocketBearerHeader":true,"websocketQueryToken":false,"principal":{"authenticated":true,"subject":"operator","scopes":["api:read","api:write"]}},"endpoints":{"events":"/api/v1/events"}}
                """
            )
        }

        let client = try await makeClient()
        let capabilities = try await client.capabilities()

        XCTAssertEqual(capabilities.protocolVersion, 1)
        XCTAssertEqual(capabilities.auth.principal?.scopes, ["api:read", "api:write"])
        XCTAssertTrue(capabilities.canOperateFleet)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/capabilities")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFleetControlsUseHumanAPIWriteInsteadOfRunnerOperateScope() {
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.auth.principal?.scopes = ["api:read", "fleet:operate"]
        XCTAssertFalse(capabilities.canOperateFleet)
        capabilities.auth.principal?.scopes = ["api:read", "api:write"]
        XCTAssertTrue(capabilities.canOperateFleet)

        let requested = NornEnrollmentScopes.requested(
            capabilities: capabilities,
            requestsAPIWrite: false,
            requestsPlatformOperations: false,
            requestsHostOperations: false,
            requestsFleetOperations: true,
            requestsTerminalSessions: false
        )
        XCTAssertEqual(requested, ["api:read", "events:read", "api:write"])
        XCTAssertFalse(requested.contains("fleet:operate"), "fleet:operate is reserved for bound CI runner identities")
    }

    func testCompatibilityCapabilitiesWithoutPrincipalDoNotClaimAuthentication() throws {
        let data = Data("""
        {"protocolVersion":1,"serverVersion":"compat","features":[],"auth":{"scopes":["api:read","api:write"],"websocketBearerHeader":true,"websocketQueryToken":false},"endpoints":{}}
        """.utf8)
        let capabilities = try JSONDecoder().decode(NornCapabilities.self, from: data)
        XCTAssertNil(capabilities.authenticatedPrincipal)
        XCTAssertTrue(capabilities.grantedScopes.isEmpty)
        XCTAssertFalse(capabilities.canOperateFleet)
    }

    func testTailscaleURLRequiresHTTPSAndEnrollmentSurfacesCertificateErrors() async throws {
        XCTAssertTrue(NornClient.isAllowedBaseURL(try XCTUnwrap(URL(string: "https://mini.tail1234.ts.net"))))
        XCTAssertFalse(NornClient.isAllowedBaseURL(try XCTUnwrap(URL(string: "http://mini.tail1234.ts.net"))))
        NornURLProtocol.setHandler { _ in throw URLError(.serverCertificateUntrusted) }
        let enrollment = try NornEnrollmentClient(
            baseURL: try XCTUnwrap(URL(string: "https://mini.tail1234.ts.net")),
            session: makeSession()
        )
        do {
            _ = try await enrollment.capabilities()
            XCTFail("expected certificate preflight failure")
        } catch let error as NornEnrollmentClientError {
            guard case .transport(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testHostMetricsUsesAuthenticatedV1RouteAndDecodesContract() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(
                request,
                status: 200,
                body: """
                {"schemaVersion":"norn.host-metrics/v1","observedAt":"2026-08-22T18:20:00.125Z","stale":false,"samplePeriodSeconds":10,"cpu":{"utilizationPercent":18.4,"logicalCores":8},"memory":{"totalBytes":17179869184,"usedBytes":8053063680,"availableBytes":9126805504}}
                """
            )
        }

        let client = try await makeClient()
        let metrics = try await client.hostMetrics()

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/host/metrics")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
        XCTAssertEqual(metrics.schemaVersion, "norn.host-metrics/v1")
        XCTAssertEqual(metrics.cpu.utilizationPercent, 18.4, accuracy: 0.001)
        XCTAssertEqual(metrics.cpu.logicalCores, 8)
        XCTAssertEqual(metrics.memory.availableBytes, 9_126_805_504)
        XCTAssertFalse(metrics.stale)
    }

    func testPromotionPreservesTheCompleteSignedStagingQualification() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 202, body: Self.operationJSON(timestamp: "2026-08-31T15:00:00Z"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .nornISO8601
        let qualification = try decoder.decode(NornReleaseQualification.self, from: Data("""
        {"schemaVersion":"norn.release-qualification/v2","id":"qualification-1","app":"api","environment":"staging","deploymentId":"deploy-1","sourceSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifact":"registry.example/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","issuedAt":"2026-08-31T14:00:00Z","expiresAt":"2026-09-01T14:00:00Z","keyId":"staging-2026","signature":"signed-receipt","candidate":{"provider":"github-actions","repository":"acme/api","repositoryId":"1","ownerId":"2","runId":"3","runAttempt":"1","workflowRef":"acme/api/.github/workflows/caller.yml@cccccccccccccccccccccccccccccccccccccccc","workflowSha":"cccccccccccccccccccccccccccccccccccccccc","signerWorkflowRef":"acme/norn/.github/workflows/release.yml@dddddddddddddddddddddddddddddddddddddddd","signerWorkflowSha":"dddddddddddddddddddddddddddddddddddddddd","ref":"refs/heads/main","attestation":{"issuer":"https://token.actions.githubusercontent.com","subjectDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","materialSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"dsse":{"payloadType":"application/vnd.norn.release-qualification.v2+json","payload":"payload","signatures":[{"keyid":"staging-2026","sig":"signed-receipt"}]}}
        """.utf8))

        _ = try await makeClient().promoteRelease(
            app: "api",
            request: .init(qualification: qualification, sourceSHA: qualification.sourceSHA, artifact: qualification.artifact),
            idempotencyKey: "promotion-1"
        )

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps/api/promotions")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "promotion-1")
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let signed = try XCTUnwrap(payload["qualification"] as? [String: Any])
        XCTAssertEqual(signed["id"] as? String, "qualification-1")
        XCTAssertEqual(signed["keyId"] as? String, "staging-2026")
        XCTAssertEqual(signed["signature"] as? String, "signed-receipt")
        XCTAssertEqual(signed["sourceSha"] as? String, qualification.sourceSHA)
    }

    func testQualificationUsesSuccessfulDeploymentIDAndDecodesSignedReceipt() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 201, body: """
            {"schemaVersion":"norn.release-qualification/v2","id":"qualification-new","app":"api","environment":"staging","deploymentId":"a2719d82-4f6c-4ac3-8c60-3e5a7b4c9d11","sourceSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifact":"registry.example/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","issuedAt":"2026-08-31T14:00:00Z","expiresAt":"2026-09-01T14:00:00Z","keyId":"staging-2026","signature":"signed-receipt","candidate":{"provider":"github-actions","repository":"acme/api","repositoryId":"1","ownerId":"2","runId":"3","workflowRef":"acme/api/.github/workflows/caller.yml@cccccccccccccccccccccccccccccccccccccccc","workflowSha":"cccccccccccccccccccccccccccccccccccccccc","signerWorkflowRef":"acme/norn/.github/workflows/release.yml@dddddddddddddddddddddddddddddddddddddddd","signerWorkflowSha":"dddddddddddddddddddddddddddddddddddddddd","ref":"refs/heads/main","attestation":{"issuer":"https://token.actions.githubusercontent.com","subjectDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","materialSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"dsse":{"payloadType":"application/vnd.norn.release-qualification.v2+json","payload":"payload","signatures":[{"keyid":"staging-2026","sig":"signed-receipt"}]}}
            """)
        }

        let receipt = try await makeClient().qualifyRelease(app: "api", deploymentID: "a2719d82-4f6c-4ac3-8c60-3e5a7b4c9d11", idempotencyKey: "qualification-1")

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps/api/qualifications")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "qualification-1")
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["deploymentId"] as? String, "a2719d82-4f6c-4ac3-8c60-3e5a7b4c9d11")
        XCTAssertEqual(receipt.id, "qualification-new")
        XCTAssertEqual(receipt.signature, "signed-receipt")
    }

    func testResourceSuggestionsDecodeNomadTenantUsage() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"suggestions":[{"app":"mail-mcp","process":"web","declaredMemoryMB":512,"declaredCpuMHz":300,"usedMemoryMB":256,"peakMemoryMB":320,"cpuPercent":17.5,"status":"right_sized","reason":""}]}
            """)
        }

        let suggestions = try await makeClient().resourceSuggestions()

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/resources/suggestions")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
        XCTAssertEqual(suggestions.first?.app, "mail-mcp")
        XCTAssertEqual(suggestions.first?.usedMemoryMB, 256)
        XCTAssertEqual(suggestions.first?.cpuPercent, 17.5)
    }

    func testHostStatusUsesVersionedRouteAndDecodesLatestAssurance() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.host-status/v1","status":"ok","services":{"postgres":"up","nomad":"up"},"latestAssurance":{"id":"assure-new","kind":"host.assure","status":"succeeded","startedAt":"2026-08-26T18:20:00Z","updatedAt":"2026-08-26T18:21:00Z"},"observedAt":"2026-08-26T18:22:00Z"}
            """)
        }

        let client = try await makeClient()
        let status = try await client.hostStatus()

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/host/status")
        XCTAssertEqual(status.schemaVersion, "norn.host-status/v1")
        XCTAssertEqual(status.latestAssurance?.id, "assure-new")
        XCTAssertEqual(status.services["nomad"], "up")
    }

    func testAppsDecodeWorkloadIntentAndAllocationSummary() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            [{"spec":{"name":"jobs","deploy":true,"processes":{"daily":{"schedule":"17 3 * * *"},"invoke":{"function":{"timeout":"30s"}},"web":{"scaling":{"min":0}}}},"nomadStatus":"running","healthy":false,"allocations":[],"allocationSummary":{"running":0,"active":0,"retained":0,"total":0,"byProcess":{}}}]
            """)
        }

        let apps = try await makeClient().apps()
        let app = try XCTUnwrap(apps.first)

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps")
        XCTAssertEqual(app.spec.processes?["daily"]?.schedule, "17 3 * * *")
        XCTAssertNotNil(app.spec.processes?["invoke"]?.function)
        XCTAssertEqual(app.spec.processes?["web"]?.scaling?.min, 0)
        XCTAssertEqual(app.allocationSummary?.active, 0)
        XCTAssertEqual(app.allocationSummary?.byProcess, [:])
    }

    func testReleasesPreferVersionedRoute() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"current":"/releases/new","releases":[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"v2.21.0","createdAt":"2026-08-26T19:00:00Z","path":"/releases/new","current":true}]}
            """)
        }

        let client = try await makeClient()
        let releases = try await client.releases()

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/releases")
        XCTAssertEqual(releases.releases.first?.version, "v2.21.0")
        XCTAssertNil(releases.releases.first?.displayVersion)
    }

    func testReleasesDecodeServerDisplayVersion() async throws {
        NornURLProtocol.setHandler { request in
            Self.response(request, status: 200, body: """
            {"releases":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","version":"platform-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","displayVersion":"v2.21.0-platform-2-gbbbbbbb","createdAt":"2026-08-26T19:00:00Z","path":"/releases/new","current":true}]}
            """)
        }

        let releases = try await makeClient().releases()

        XCTAssertEqual(releases.releases.first?.displayVersion, "v2.21.0-platform-2-gbbbbbbb")
        XCTAssertEqual(releases.releases.first?.displayLabel(in: releases.releases), "v2.21.0-platform-2-gbbbbbbb")
    }

    func testReleasesCollapseDuplicateArtifactReceiptsAndSortNewestFirst() async throws {
        NornURLProtocol.setHandler { request in
            Self.response(request, status: 200, body: """
            {"current":"/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","releases":[
              {"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"platform-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":"2026-08-26T19:02:00Z","path":"/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","current":false},
              {"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","version":"v2.20.0-platform","createdAt":"2026-08-26T18:00:00Z","path":"/releases/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","current":false},
              {"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"v2.21.0-platform-1-gaaaaaaa","createdAt":"2026-08-26T19:00:00Z","path":"/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","current":true}
            ]}
            """)
        }

        let releases = try await makeClient().releases().releases

        XCTAssertEqual(releases.map(\.sha), [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ])
        XCTAssertTrue(releases[0].current)
        XCTAssertEqual(releases[0].version, "v2.21.0-platform-1-gaaaaaaa")
        XCTAssertEqual(releases[0].createdAt, Date(timeIntervalSince1970: 1_787_770_920))
    }

    func testFleetInventoryUsesAuthenticatedV1RouteAndDecodesNodePools() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.fleet-inventory/v1","configured":true,"digest":"sha256:test","document":{"apiVersion":"norn.dev/fleet/v1","kind":"Cluster","cluster":{"name":"production-nyc3","provider":"digitalocean","region":"nyc3"}},"validation":{"schemaVersion":"norn.validation-report/v1","documentKind":"fleet","valid":true,"findings":[]},"nodePools":{"app":{"size":"s-4vcpu-8gb","min":2,"desired":3,"max":8}}}
            """)
        }

        let client = try await makeClient()
        let inventory = try await client.fleetInventory()

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/fleet/node-pools")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
        XCTAssertEqual(inventory.nodePools["app"]?.desired, 3)
        XCTAssertTrue(inventory.configured)
    }

    func testFleetPlanUsesRetryKeyAndReconciliationUsesDurablePlanRoute() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            if request.url?.path.hasSuffix("/reconciliations") == true {
                return Self.response(request, status: 200, body: """
                {"schemaVersion":"norn.fleet-reconciliation/v1","planId":"plan-1","count":1,"reconciliations":[{"id":"checkpoint-1","kind":"fleet.reconciliation","status":"succeeded","startedAt":"2026-08-07T18:20:00Z","updatedAt":"2026-08-07T18:20:00Z","payload":{"phase":"readiness_verified"}}]}
                """)
            }
            return Self.response(request, status: 201, body: """
            {"id":"plan-1","kind":"fleet.capacity-plan","status":"succeeded","startedAt":"2026-08-07T18:20:00Z","updatedAt":"2026-08-07T18:20:00Z","payload":{"pool":"app","action":"scale","current":{"desired":2},"proposed":{"desired":3}}}
            """)
        }

        let client = try await makeClient()
        let operation = try await client.planFleetCapacity(
            pool: "app",
            request: .init(desired: 3, size: "s-4vcpu-8gb", strategy: nil, reason: "add headroom"),
            idempotencyKey: "fleet-retry-1"
        )
        XCTAssertEqual(operation.id, "plan-1")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/fleet/node-pools/app/plan")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "fleet-retry-1")
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["desired"] as? Int, 3)
        XCTAssertEqual(payload["reason"] as? String, "add headroom")

        let checkpoints = try await client.fleetReconciliations(planID: operation.id)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/fleet/plans/plan-1/reconciliations")
        XCTAssertEqual(checkpoints.reconciliations.first?.payload?["phase"], .string("readiness_verified"))
    }

    func testFleetReconciliationsRejectsUnexpectedSchema() async throws {
        NornURLProtocol.setHandler { request in
            Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.fleet-reconciliations/v1","planId":"plan-1","count":0,"reconciliations":[]}
            """)
        }

        let client = try await makeClient()
        do {
            _ = try await client.fleetReconciliations(planID: "plan-1")
            XCTFail("unexpected reconciliation schema was accepted")
        } catch let error as NornClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testFleetGitHubUsesAuthenticatedStatusReviewAndDispatchRoutes() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            switch request.url?.path {
            case "/api/v1/fleet/github":
                return Self.response(request, status: 200, body: """
                {"schemaVersion":"norn.fleet-github-status/v1","configured":true,"connected":true,"repository":"antiartificial/norn-fleet","installationId":42}
                """)
            case "/api/v1/fleet/plans/plan-1/github/pull-request":
                return Self.response(request, status: 201, body: """
                {"id":"review-1","kind":"fleet.github.pull-request","status":"succeeded","startedAt":"2026-08-07T18:20:00Z","updatedAt":"2026-08-07T18:20:00Z","payload":{"url":"https://github.com/antiartificial/norn-fleet/pull/1"}}
                """)
            default:
                return Self.response(request, status: 201, body: """
                {"id":"apply-1","kind":"fleet.github.apply-dispatch","status":"succeeded","startedAt":"2026-08-07T18:20:00Z","updatedAt":"2026-08-07T18:20:00Z","payload":{"url":"https://github.com/antiartificial/norn-fleet/actions/runs/1"}}
                """)
            }
        }

        let client = try await makeClient()
        let status = try await client.fleetGitHubStatus()
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.installationID, 42)

        let review = try await client.createFleetPullRequest(planID: "plan-1")
        XCTAssertEqual(review.kind, "fleet.github.pull-request")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/fleet/plans/plan-1/github/pull-request")

        let apply = try await client.dispatchFleetApply(planID: "plan-1", allowDestructive: true)
        XCTAssertEqual(apply.kind, "fleet.github.apply-dispatch")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/fleet/plans/plan-1/github/dispatch")
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["allowDestructive"] as? Bool, true)
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
    }

    func testQueueUpgradeEncodesBodyAndIdempotencyKey() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 202, body: Self.operationJSON(timestamp: "2026-08-07T18:20:00.125Z"))
        }

        let client = try await makeClient()
        let operation = try await client.queue(
            .platformUpgrade(ref: "main", mode: "proxy", drainMode: "wait"),
            idempotencyKey: "upgrade-001"
        )

        XCTAssertEqual(operation.status, .queued)
        XCTAssertEqual(operation.payload?["mode"], .string("proxy"))
        XCTAssertEqual(operation.startedAt.timeIntervalSince1970, 1_786_126_800.125, accuracy: 0.001)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/platform/upgrades")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "upgrade-001")
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["ref"], "main")
        XCTAssertEqual(payload["mode"], "proxy")
        XCTAssertEqual(payload["drainMode"], "wait")
    }

    func testCreateAppUsesVersionedRouteAndKeepsDeploymentDisabled() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 201, body: """
            {"app":"orders-api","created":true,"spec":{"name":"orders-api","deploy":false}}
            """)
        }

        let client = try await makeClient()
        let receipt = try await client.createApp(.init(name: "orders-api", kind: .endpoint, port: 8080))

        XCTAssertEqual(receipt.app, "orders-api")
        XCTAssertEqual(receipt.spec.deploy, false)
        XCTAssertEqual(recorder.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps")
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["name"] as? String, "orders-api")
        XCTAssertEqual(payload["kind"] as? String, "endpoint")
        XCTAssertEqual(payload["port"] as? Int, 8080)
    }

	func testCompatibilityRuntimeObservabilityUsesLogsAndRestartRoutes() async throws {
		let recorder = RequestRecorder()
		NornURLProtocol.setHandler { request in
			recorder.record(request, body: NornURLProtocol.body(of: request))
			if request.url?.path.hasSuffix("/logs") == true {
				return Self.response(request, status: 200, body: "2026-08-28T12:00:00Z ready\\n")
			}
			return Self.response(request, status: 200, body: "{\"status\":\"ok\"}")
		}

		let client = try await makeClient()
		let logs = try await client.appLogs(app: "orders api")
		XCTAssertEqual(logs, "2026-08-28T12:00:00Z ready\\n")
		XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/apps/orders%20api/logs")
		XCTAssertEqual(recorder.lastRequest?.httpMethod, "GET")

		try await client.restartApp(app: "orders-api")
		XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/apps/orders-api/restart")
		XCTAssertEqual(recorder.lastRequest?.httpMethod, "POST")
	}

	func testCompatibilityLogsLimitDisplayedOutputToFirst256Kilobytes() async throws {
		let oversized = String(repeating: "a", count: 256 * 1_024 + 32) + "tail"
		NornURLProtocol.setHandler { request in
			Self.response(request, status: 200, body: oversized)
		}

		let client = try await makeClient()
		let logs = try await client.appLogs(app: "orders-api")

		XCTAssertTrue(logs.hasPrefix("[Showing first 256 KB of app output]\n"))
		XCTAssertFalse(logs.contains("tail"))
		XCTAssertLessThanOrEqual(logs.utf8.count, 256 * 1_024 + 64)
	}

	func testDurableAppRecoveryUsesTypedSnapshotAndMigrationRoutes() async throws {
		let recorder = RequestRecorder()
		NornURLProtocol.setHandler { request in
			recorder.record(request, body: NornURLProtocol.body(of: request))
			if request.httpMethod == "GET" {
				return Self.response(request, status: 200, body: """
				[{"filename":"orders_pre-migrate_20260825T140000.dump","database":"orders","timestamp":"20260825T140000","createdAt":"2026-08-25T14:00:00Z","size":4096}]
				""")
			}
			return Self.response(request, status: 202, body: """
			{"id":"migration-1","kind":"app.migrate","app":"orders-api","status":"queued","startedAt":"2026-08-25T14:00:00Z","updatedAt":"2026-08-25T14:00:00Z"}
			""")
	}

		let client = try await makeClient()
		let snapshots = try await client.appSnapshots(app: "orders-api")
		XCTAssertEqual(snapshots.first?.database, "orders")
		XCTAssertEqual(snapshots.first?.size, 4096)
		XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps/orders-api/snapshots")

		let operation = try await client.queueAppOperation(.migrate(app: "orders-api", ref: "main"), idempotencyKey: "migration-retry-1")
		XCTAssertEqual(operation.kind, "app.migrate")
		XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps/orders-api/migrations")
		XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "migration-retry-1")
		let body = try XCTUnwrap(recorder.lastBody)
		let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
		XCTAssertEqual(payload["ref"] as? String, "main")
		XCTAssertEqual(payload["confirm"] as? Bool, true)

		_ = try await client.queueAppOperation(
			.restoreSnapshot(app: "orders-api", snapshot: "orders_pre-migrate_20260825T140000.dump"),
			idempotencyKey: "restore-retry-1"
		)
		XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps/orders-api/snapshots/orders_pre-migrate_20260825T140000.dump/restore")
		XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "restore-retry-1")
		}

    func testDeploymentVisibilityDecodesVersionedHistoryAndStageCheckpoints() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            if request.url?.path.hasSuffix("/steps") == true {
                return Self.response(request, status: 200, body: """
                {"schemaVersion":"norn.deployment-steps/v1","deploymentId":"deploy-1","steps":[{"deploymentId":"deploy-1","app":"orders-api","sagaId":"saga-1","step":"submit","status":"running","kind":"mutable","attempt":1,"startedAt":"2026-08-25T14:00:02Z"}],"count":1}
                """)
            }
            return Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.deployments/v1","deployments":[{"id":"deploy-1","app":"orders-api","commitSha":"0123456789012345678901234567890123456789","imageTag":"orders:0123456","sagaId":"saga-1","status":"submitting","startedAt":"2026-08-25T14:00:00Z","regions":[{"region":"nyc3","nomadRegion":"global","status":"submitting","desiredWeight":100,"activeWeight":0,"updatedAt":"2026-08-25T14:00:02Z"}]}],"count":1,"offset":0}
            """)
        }

        let client = try await makeClient()
        let deployments = try await client.deployments()
        XCTAssertEqual(deployments.first?.status, .submitting)
        XCTAssertEqual(deployments.first?.regions?.first?.region, "nyc3")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/deployments")

        let steps = try await client.deploymentSteps(deploymentID: "deploy-1")
        XCTAssertEqual(steps.first?.step, "submit")
        XCTAssertEqual(steps.first?.kind, .mutable)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/deployments/deploy-1/steps")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
    }

    func testFleetRunnerAttemptListUsesReadOnlyV1Route() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            let attempt = """
            {"schemaVersion":"norn.fleet-runner-attempt/v1","id":"attempt-1","planId":"plan-1","attempt":2,"runnerAttemptId":"github-42","status":"running","currentPhase":"nodes_configured","commitSha":"0123456789012345678901234567890123456789","planSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","workflowUrl":"https://github.com/acme/fleet/actions/runs/42","heartbeatSequence":4,"heartbeatTimeoutSeconds":120,"revision":5,"startedAt":"2026-08-25T14:00:00Z","phaseStartedAt":"2026-08-25T14:08:00Z","heartbeatAt":"2026-08-25T14:01:00Z","heartbeatExpiresAt":"2026-08-25T14:03:00Z","updatedAt":"2026-08-25T14:01:00Z","timing":{"schemaVersion":"norn.fleet-timing/v1","scope":"runner_attempt","asOf":"2026-08-25T14:10:00Z","availability":"available","operationClass":"cold_start","elapsedMs":600000,"estimatedRemaining":{"lowMs":120000,"highMs":300000},"estimatedTotal":{"lowMs":480000,"highMs":840000},"estimatedCompletion":{"earliestAt":"2026-08-25T14:12:00Z","latestAt":"2026-08-25T14:15:00Z"},"confidence":"low","provenance":{"method":"configured_range","configuredRange":{"lowMs":480000,"highMs":840000},"sampleCount":4,"successfulSampleCount":3,"exclusions":["github_queue"]},"phases":[{"name":"nodes_configured","state":"active","elapsedMs":120000}]}}
            """
            return Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.fleet-runner-attempt/v1","planId":"plan-1","attempts":[\(attempt)],"count":1,"serverTime":"2026-08-25T14:01:01Z"}
            """)
        }

        let client = try await makeClient()
        let list = try await client.fleetRunnerAttempts(planID: "plan-1")
        XCTAssertEqual(list.attempts.first?.currentPhase, "nodes_configured")
        XCTAssertEqual(list.attempts.first?.phaseStartedAt, Date(timeIntervalSince1970: 1_787_666_880))
        XCTAssertEqual(list.attempts.first?.timing?.schemaVersion, "norn.fleet-timing/v1")
        XCTAssertEqual(list.attempts.first?.timing?.elapsedMs, 600_000)
        XCTAssertEqual(list.attempts.first?.timing?.estimatedRemaining, .init(lowMs: 120_000, highMs: 300_000))
        XCTAssertEqual(list.attempts.first?.timing?.provenance.successfulSampleCount, 3)
        XCTAssertEqual(list.attempts.first?.timing?.phases.first?.name, "nodes_configured")
        XCTAssertEqual(list.attempts.first?.timing?.phases.first?.state, .active)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/fleet/plans/plan-1/attempts")
    }

    func testReleaseQualificationDecodesPrivateAttestationModeAndSafeVerifierLabel() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.release-qualifications/v2","count":1,"qualifications":[{"schemaVersion":"norn.release-qualification/v2","id":"qualification-1","app":"api","environment":"staging","deploymentId":"deploy-1","sourceSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifact":"registry.example/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","issuedAt":"2026-08-31T14:00:00Z","expiresAt":"2026-12-01T14:00:00Z","keyId":"staging-2026","signature":"signed-receipt","candidate":{"provider":"github-actions","repository":"acme/api","repositoryId":"1","ownerId":"2","repositoryVisibility":"private","runId":"3","workflowRef":"acme/api/.github/workflows/caller.yml@cccccccccccccccccccccccccccccccccccccccc","workflowSha":"cccccccccccccccccccccccccccccccccccccccc","signerWorkflowRef":"acme/norn/.github/workflows/release.yml@dddddddddddddddddddddddddddddddddddddddd","signerWorkflowSha":"dddddddddddddddddddddddddddddddddddddddd","ref":"refs/heads/main","attestation":{"mode":"github-private","verifier":"GitHub private attestation verifier","issuer":"https://token.actions.githubusercontent.com","subjectDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","materialSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},"dsse":{"payloadType":"application/vnd.norn.release-qualification.v2+json","payload":"payload","signatures":[{"keyid":"staging-2026","sig":"signed-receipt"}]}}]}
            """)
        }

        let qualification = try await makeClient().releaseQualifications(app: "api").first

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/apps/api/qualifications")
        XCTAssertEqual(qualification?.candidate.repositoryVisibility, "private")
        XCTAssertEqual(qualification?.candidate.attestation.displayMode, "GitHub Enterprise private")
        XCTAssertEqual(qualification?.candidate.attestation.displayVerifier, "GitHub private attestation verifier")
        let encoded = try XCTUnwrap(try JSONEncoder().encode(qualification))
        let roundTrip = try JSONDecoder().decode(NornReleaseQualification.self, from: encoded)
        XCTAssertEqual(roundTrip.candidate.repositoryVisibility, "private")
        XCTAssertEqual(roundTrip.candidate.attestation.mode, "github-private")
        XCTAssertEqual(roundTrip.candidate.attestation.verifier, "GitHub private attestation verifier")
        XCTAssertNil(roundTrip.candidate.attestation.bundle)
    }

    func testReleaseQualificationDecodesAndRoundTripsNornSignedPrivateEvidence() async throws {
        NornURLProtocol.setHandler { request in
            Self.response(request, status: 200, body: """
            {"schemaVersion":"norn.release-qualifications/v2","count":1,"qualifications":[{"schemaVersion":"norn.release-qualification/v2","id":"qualification-private-1","app":"api","environment":"staging","deploymentId":"deploy-private-1","sourceSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifact":"registry.example/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","issuedAt":"2026-08-31T14:00:00Z","expiresAt":"2026-12-01T14:00:00Z","keyId":"norn-private-2026","signature":"signed-receipt","candidate":{"provider":"github-actions","repository":"personal-user/api","repositoryId":"101","ownerId":"202","repositoryVisibility":"private","runId":"303","workflowRef":"personal-user/api/.github/workflows/caller.yml@cccccccccccccccccccccccccccccccccccccccc","workflowSha":"cccccccccccccccccccccccccccccccccccccccc","signerWorkflowRef":"personal-user/norn/.github/workflows/release.yml@dddddddddddddddddddddddddddddddddddddddd","signerWorkflowSha":"dddddddddddddddddddddddddddddddddddddddd","ref":"refs/heads/main","attestation":{"mode":"norn-signed-private","verifier":"Norn private DSSE","issuer":"https://token.actions.githubusercontent.com","subjectDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","materialSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bundle":{"schemaVersion":"norn.private-release-attestation/v1","keyId":"sha256:private-key","provenance":{"payloadType":"application/vnd.in-toto+json","payload":"provenance-payload","signatures":[{"keyid":"sha256:private-key","sig":"provenance-signature"}]},"sbom":{"payloadType":"application/vnd.in-toto+json","payload":"sbom-payload","signatures":[{"keyid":"sha256:private-key","sig":"sbom-signature"}]}}}},"dsse":{"payloadType":"application/vnd.norn.release-qualification.v2+json","payload":"payload","signatures":[{"keyid":"norn-private-2026","sig":"signed-receipt"}]}}]}
            """)
        }

        let qualifications = try await makeClient().releaseQualifications(app: "api")
        let qualification = try XCTUnwrap(qualifications.first)
        XCTAssertEqual(qualification.candidate.repository, "personal-user/api")
        XCTAssertEqual(qualification.candidate.ownerID, "202")
        XCTAssertEqual(qualification.candidate.repositoryID, "101")
        XCTAssertEqual(qualification.candidate.attestation.mode, "norn-signed-private")
        XCTAssertEqual(qualification.candidate.attestation.displayMode, "Norn-signed private")
        XCTAssertEqual(qualification.candidate.attestation.displayVerifier, "Norn private DSSE")
        XCTAssertEqual(qualification.candidate.attestation.bundle?.schemaVersion, "norn.private-release-attestation/v1")
        XCTAssertEqual(qualification.candidate.attestation.bundle?.keyID, "sha256:private-key")
        XCTAssertEqual(qualification.candidate.attestation.bundle?.provenance.payload, "provenance-payload")
        XCTAssertEqual(qualification.candidate.attestation.bundle?.provenance.signatures.first?.keyID, "sha256:private-key")
        XCTAssertEqual(qualification.candidate.attestation.bundle?.sbom.payload, "sbom-payload")
        XCTAssertEqual(qualification.candidate.attestation.bundle?.sbom.signatures.first?.sig, "sbom-signature")

        let encoded = try JSONEncoder().encode(qualification)
        let roundTrip = try JSONDecoder().decode(NornReleaseQualification.self, from: encoded)
        XCTAssertEqual(roundTrip.candidate.attestation.mode, "norn-signed-private")
        XCTAssertEqual(roundTrip.candidate.attestation.bundle, qualification.candidate.attestation.bundle)
    }

    func testOperationsBuildsBoundedActiveQueryAndDecodesNonFractionalDate() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(
                request,
                status: 200,
                body: "{\"operations\":[\(Self.operationJSON(timestamp: "2026-08-07T18:20:00Z"))],\"count\":1}"
            )
        }

        let client = try await makeClient()
        let operations = try await client.operations(activeOnly: true, limit: 999)

        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0].updatedAt.timeIntervalSince1970, 1_786_126_800, accuracy: 0.001)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(recorder.lastRequest?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "active" })?.value, "true")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "200")
    }

    func testServerErrorPreservesSafeProblemDetails() async throws {
        NornURLProtocol.setHandler { request in
            Self.response(request, status: 403, headers: ["X-Request-ID": "req-42"], body: "{\"error\":\"scope apps:exec is required\"}")
        }

        let client = try await makeClient()
        do {
            _ = try await client.releases()
            XCTFail("Expected an HTTP error")
        } catch let error as NornClientError {
            XCTAssertEqual(error, .http(status: 403, message: "scope apps:exec is required", requestID: "req-42"))
        }
    }

    func testEventRequestUsesWSSBearerHeaderAndCursorWithoutTokenQuery() async throws {
        let client = try await makeClient()
        let request = try await client.eventRequest(after: 42)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/api/v1/events")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "after", value: "42")])
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "token" }))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
    }

    func testEventStreamInfoUsesAuthenticatedV1RouteAndDecodesBounds() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"protocolVersion":1,"bounds":{"oldestCursor":80,"latestCursor":120,"retainedEvents":41},"retentionPolicy":"database-retained","retention":{"mode":"unbounded","automaticPruning":false,"replayPageSize":500},"gapDetection":true,"heartbeatMinimumSeconds":10,"heartbeatMaximumSeconds":120,"filters":["types","apps"]}
            """)
        }

        let info = try await makeClient().eventStreamInfo()

        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/events/info")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
        XCTAssertEqual(info.bounds.oldestCursor, 80)
        XCTAssertEqual(info.bounds.latestCursor, 120)
        XCTAssertTrue(info.gapDetection)
    }

    func testEnrollmentStartsWithoutBearerAndMapsPendingExchangeByStableCode() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            if request.url?.path.hasSuffix("/exchange") == true {
                return Self.response(request, status: 409, body: """
                {"code":"enrollment_not_approved","detail":"enrollment is not approved"}
                """)
            }
            return Self.response(request, status: 201, body: """
            {"id":"ca761232-ed42-11ce-bacd-00aa0057b223","userCode":"ABCD-EFGH","verifier":"device-only-verifier","expiresAt":"2099-08-26T20:10:00Z","verificationPath":"/api/v1/enrollments/approve","pollPath":"/api/v1/enrollments/ca761232-ed42-11ce-bacd-00aa0057b223/exchange"}
            """)
        }

        let client = try NornEnrollmentClient(
            baseURL: try XCTUnwrap(URL(string: "https://norn.example")),
            session: makeSession()
        )
        let enrollment = try await client.start(.init(
            deviceName: "Studio Mac",
            platform: "macOS",
            model: "Mac14,3",
            appVersion: "2.22.0",
            publicKey: "base64url-x963-public-key",
            requestedScopes: ["api:read", "events:read"]
        ))

        XCTAssertEqual(enrollment.userCode, "ABCD-EFGH")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/enrollments")
        XCTAssertNil(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(recorder.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["deviceName"] as? String, "Studio Mac")
        XCTAssertEqual(payload["requestedScopes"] as? [String], ["api:read", "events:read"])

        do {
            _ = try await client.exchange(enrollment)
            XCTFail("Expected enrollment to remain pending")
        } catch let error as NornEnrollmentClientError {
            XCTAssertEqual(error, .awaitingApproval)
        }
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/enrollments/ca761232-ed42-11ce-bacd-00aa0057b223/exchange")
        XCTAssertNil(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testEnrollmentDiscoversAuthorityCapabilitiesWithoutBearerBeforePairing() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"protocolVersion":1,"serverVersion":"fleet-authority","features":["fleet-authority-only-v1"],"auth":{"scopes":["api:read","api:write"],"websocketBearerHeader":false,"websocketQueryToken":false},"endpoints":{},"authority":"fleet-only"}
            """)
        }
        let client = try NornEnrollmentClient(
            baseURL: try XCTUnwrap(URL(string: "https://norn.example")),
            session: makeSession()
        )

        let capabilities = try await client.capabilities()

        XCTAssertEqual(recorder.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/capabilities")
        XCTAssertNil(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(capabilities.isFleetAuthorityOnly)
    }

    func testManagedCredentialRotationReplacesKeychainToken() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            return Self.response(request, status: 200, body: """
            {"token":"replacement-token","tokenId":"token-2","deviceId":"device-1","scopes":["api:read","events:read"],"expiresAt":"2099-09-25T20:10:00Z"}
            """)
        }
        let vault = TestCredentialVault(token: "old-token")
        let profile = NornServerProfile(name: "Test server", baseURL: try XCTUnwrap(URL(string: "https://norn.example")))
        let client = try NornClient(profile: profile, credentialVault: vault, session: makeSession())

        let issued = try await client.rotateCredential()

        XCTAssertEqual(issued.tokenID, "token-2")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/auth/rotate")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer old-token")
        let savedToken = await vault.savedToken()
        XCTAssertEqual(savedToken, "replacement-token")
    }

    func testRejectsInsecureNonLoopbackProfile() async throws {
        let vault = TestCredentialVault(token: "scoped-test-token")
        let profile = NornServerProfile(name: "Remote", baseURL: try XCTUnwrap(URL(string: "http://norn.example")))
        do {
            _ = try NornClient(profile: profile, credentialVault: vault, session: makeSession())
            XCTFail("Expected insecure remote HTTP to be rejected")
        } catch let error as NornClientError {
            XCTAssertEqual(error, .invalidBaseURL)
        }
    }

    private func makeClient() async throws -> NornClient {
        let profile = NornServerProfile(name: "Test server", baseURL: try XCTUnwrap(URL(string: "https://norn.example")))
        return try NornClient(profile: profile, credentialVault: TestCredentialVault(token: "scoped-test-token"), session: makeSession())
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NornURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://norn.example")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }

    private static func operationJSON(timestamp: String) -> String {
        """
        {"id":"op-1","kind":"platform.upgrade","status":"queued","startedAt":"\(timestamp)","updatedAt":"\(timestamp)","payload":{"mode":"proxy","drainMode":"wait"}}
        """
    }
}

private actor TestCredentialVault: NornCredentialVault {
	private var credential: NornCredential?

    init(token: String) {
		credential = try! NornCredential(accessToken: token)
    }

    func credential(for identifier: String) -> NornCredential? {
        credential
    }

	func store(_ credential: NornCredential, for identifier: String) {
		self.credential = credential
	}

	func removeCredential(for identifier: String) {
		credential = nil
	}

	func savedToken() -> String? {
		credential?.accessToken
	}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?

    var lastRequest: URLRequest? {
        lock.withLock { request }
    }

    var lastBody: Data? {
        lock.withLock { body }
    }

    func record(_ request: URLRequest, body: Data?) {
        lock.withLock {
            self.request = request
            self.body = body
        }
    }
}

private final class NornURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handlerStore = HandlerStore()

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        handlerStore.handler = handler
    }

    static func reset() {
        handlerStore.handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handlerStore.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private final class HandlerStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
            get { lock.withLock { storedHandler } }
            set { lock.withLock { storedHandler = newValue } }
        }
    }
}
