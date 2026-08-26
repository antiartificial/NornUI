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
                {"protocolVersion":1,"serverVersion":"v2.16.2-control","features":["event-cursor-replay"],"auth":{"scopes":["api:read"],"websocketBearerHeader":true,"websocketQueryToken":false},"endpoints":{"events":"/api/v1/events"}}
                """
            )
        }

        let client = try await makeClient()
        let capabilities = try await client.capabilities()

        XCTAssertEqual(capabilities.protocolVersion, 1)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/v1/capabilities")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
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
                {"schemaVersion":"norn.fleet-reconciliations/v1","planId":"plan-1","count":1,"reconciliations":[{"id":"checkpoint-1","kind":"fleet.reconciliation","status":"succeeded","startedAt":"2026-08-07T18:20:00Z","updatedAt":"2026-08-07T18:20:00Z","payload":{"phase":"readiness_verified"}}]}
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

    func testDeploymentVisibilityDecodesCompatibilityHistoryAndStageCheckpoints() async throws {
        let recorder = RequestRecorder()
        NornURLProtocol.setHandler { request in
            recorder.record(request, body: NornURLProtocol.body(of: request))
            if request.url?.path.hasSuffix("/steps") == true {
                return Self.response(request, status: 200, body: """
                {"steps":[{"deploymentId":"deploy-1","app":"orders-api","sagaId":"saga-1","step":"submit","status":"running","kind":"mutable","attempt":1,"startedAt":"2026-08-25T14:00:02Z"}],"count":1}
                """)
            }
            return Self.response(request, status: 200, body: """
            [{"id":"deploy-1","app":"orders-api","commitSha":"0123456789012345678901234567890123456789","imageTag":"orders:0123456","sagaId":"saga-1","status":"submitting","startedAt":"2026-08-25T14:00:00Z","regions":[{"region":"nyc3","nomadRegion":"global","status":"submitting","desiredWeight":100,"activeWeight":0,"updatedAt":"2026-08-25T14:00:02Z"}]}]
            """)
        }

        let client = try await makeClient()
        let deployments = try await client.deployments()
        XCTAssertEqual(deployments.first?.status, .submitting)
        XCTAssertEqual(deployments.first?.regions?.first?.region, "nyc3")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/deployments")

        let steps = try await client.deploymentSteps(deploymentID: "deploy-1")
        XCTAssertEqual(steps.first?.step, "submit")
        XCTAssertEqual(steps.first?.kind, .mutable)
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/api/deployments/deploy-1/steps")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-test-token")
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
    private let credential: NornCredential

    init(token: String) {
        credential = try! NornCredential(accessToken: token)
    }

    func credential(for identifier: String) -> NornCredential? {
        credential
    }

    func store(_ credential: NornCredential, for identifier: String) {}
    func removeCredential(for identifier: String) {}
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
