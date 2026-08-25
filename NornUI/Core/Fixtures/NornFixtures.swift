import Foundation

enum NornFixtures {
    static let now = Date(timeIntervalSince1970: 1_786_140_000)

    static let snapshot = NornDashboardSnapshot(
        capabilities: NornCapabilities(
            protocolVersion: 1,
            serverVersion: "v2.16.2-control",
            features: ["durable-operations", "event-cursor-replay", "host-assurance", "host-metrics", "fleet-v1", "fleet-inventory", "durable-fleet-capacity-plans", "fleet-reconciliation-v1", "fleet-github-app-v1"],
            auth: .init(
                scopes: ["api:read", "events:read", "platform:operate", "host:operate"],
                websocketBearerHeader: true,
                websocketQueryToken: false
            ),
            endpoints: [
                "events": "/api/v1/events",
                "hostMetrics": "/api/v1/host/metrics",
                "fleetNodePools": "/api/v1/fleet/node-pools",
                "fleetPlans": "/api/v1/fleet/plans",
                "fleetReconciliations": "/api/v1/fleet/plans/{planID}/reconciliations",
                "fleetGitHub": "/api/v1/fleet/github",
                "fleetGitHubPullRequest": "/api/v1/fleet/plans/{planID}/github/pull-request",
                "fleetGitHubDispatch": "/api/v1/fleet/plans/{planID}/github/dispatch"
            ]
        ),
        health: NornHealth(
            status: "ok",
            services: ["postgres": "up", "nomad": "up", "consul": "up", "sops": "up"],
            network: .init(mode: "tailnet", bindAddr: "0.0.0.0", nomadAddr: nil, consulAddr: nil)
        ),
        services: [
            service("mail-agent", process: "web", exposure: "public", status: "passing"),
            service("mail-indexer", process: "web", exposure: "public", status: "passing"),
            service("mail-mcp", process: "mcp", exposure: "private", status: "passing"),
            service("like-trove", process: "web", exposure: "private", status: "passing"),
            service("vigil-gateway", process: "web", exposure: "private", status: "passing"),
            service("contextdb", process: "web", exposure: "local", status: "unknown")
        ],
        operations: [
            operation("platform.smoke", status: .succeeded, offset: -420, message: "Platform smoke complete"),
            operation("host.assure", status: .succeeded, offset: -760, message: "Host assurance complete"),
            operation("app.deploy", app: "mail-mcp", status: .succeeded, offset: -3_200, message: "Deployment healthy")
        ],
        releases: [
            NornRelease(
                sha: "b3a3958019be2655",
                version: "v2.16.2-control",
                createdAt: now.addingTimeInterval(-1_800),
                path: "/releases/b3a3958",
                current: true
            ),
            NornRelease(
                sha: "f641de1bb51421a0",
                version: "v2.15.0-platform",
                createdAt: now.addingTimeInterval(-172_800),
                path: "/releases/f641de1",
                current: false
            )
        ],
        observedAt: now
    )

    static let hostMetrics = NornHostMetrics(
        schemaVersion: "norn.host-metrics/v1",
        observedAt: now,
        stale: false,
        samplePeriodSeconds: 10,
        cpu: .init(utilizationPercent: 18.4, logicalCores: 8),
        memory: .init(
            totalBytes: 17_179_869_184,
            usedBytes: 8_053_063_680,
            availableBytes: 9_126_805_504
        )
    )

    static let fleetInventory = NornFleetInventory(
        schemaVersion: "norn.fleet-inventory/v1",
        configured: true,
        digest: "sha256:6f44c7d65a28f46f4cb7fa10c107cee344e4cf3e2c8bdb448f3452fc0fbf6721",
        document: .init(
            apiVersion: "norn.dev/fleet/v1",
            kind: "Cluster",
            metadata: .init(
                repository: "antiartificial/norn-fleet",
                environment: "production",
                workflowURL: "https://github.com/antiartificial/norn-fleet/actions/workflows/apply.yml"
            ),
            cluster: .init(name: "production-nyc3", provider: "digitalocean", region: "nyc3")
        ),
        validation: .init(
            schemaVersion: "norn.validation-report/v1",
            documentKind: "fleet",
            name: "production-nyc3",
            valid: true,
            findings: []
        ),
        nodePools: [
            "control": .init(size: "s-4vcpu-8gb", min: 3, desired: 3, max: 5, labels: ["workload": "control-plane"], replacement: .init(strategy: "blueGreen", requireCapacityHeadroom: true, drainTimeout: "15m", requireReadiness: true)),
            "ingress": .init(size: "s-2vcpu-4gb", min: 2, desired: 2, max: 4, labels: ["workload": "ingress"], replacement: .init(strategy: "blueGreen", requireCapacityHeadroom: true, drainTimeout: "15m", requireReadiness: true)),
            "app": .init(size: "s-4vcpu-8gb", min: 2, desired: 2, max: 8, labels: ["workload": "app"], replacement: .init(strategy: "blueGreen", requireCapacityHeadroom: true, drainTimeout: "15m", requireReadiness: true))
        ]
    )

    private static func service(
        _ app: String,
        process: String,
        exposure: String,
        status: String
    ) -> NornService {
        NornService(
            name: "\(app)-\(process)",
            app: app,
            process: process,
            type: process == "web" ? "service" : process,
            status: status,
            healthPath: "/health",
            reachability: .init(
                endpointScope: exposure,
                instanceScope: "private",
                exposure: exposure,
                routable: status == "passing"
            ),
            endpoints: [],
            instances: []
        )
    }

    private static func operation(
        _ kind: String,
        app: String? = nil,
        status: NornOperationStatus,
        offset: TimeInterval,
        message: String
    ) -> NornOperation {
        let started = now.addingTimeInterval(offset)
        return NornOperation(
            id: UUID().uuidString,
            kind: kind,
            app: app,
            sagaID: nil,
            ref: nil,
            status: status,
            risk: "read-only",
            source: "control-api",
            message: message,
            attempts: 1,
            maxAttempts: 1,
            lockedBy: nil,
            lockedUntil: nil,
            nextAttemptAt: nil,
            lastError: nil,
            startedAt: started,
            updatedAt: started.addingTimeInterval(8),
            finishedAt: started.addingTimeInterval(8),
            metadata: nil
        )
    }
}
