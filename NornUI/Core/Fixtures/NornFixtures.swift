import Foundation

enum NornFixtures {
    static let now = Date(timeIntervalSince1970: 1_786_140_000)

    static let snapshot = NornDashboardSnapshot(
        capabilities: NornCapabilities(
            protocolVersion: 1,
            serverVersion: "v2.16.2-control",
            features: ["durable-operations", "event-cursor-replay", "host-assurance", "host-metrics", "durable-app-recovery-v1", "durable-snapshots", "standalone-migrations", "regional-deployments", "versioned-deployment-history-v1", "service-instance-placement-v2", "principal-scope-discovery-v1", "fleet-v1", "fleet-inventory", "durable-fleet-capacity-plans", "fleet-reconciliation-v1", "fleet-runner-attempts-v1", "fleet-github-app-v1"],
            auth: .init(
                scopes: ["api:read", "events:read", "platform:operate", "host:operate"],
                websocketBearerHeader: true,
                websocketQueryToken: false,
                principal: .init(authenticated: true, subject: "fixture-operator", scopes: ["api:read", "fleet:operate"])
            ),
            endpoints: [
                "events": "/api/v1/events",
                "hostMetrics": "/api/v1/host/metrics",
				"appSnapshots": "/api/v1/apps/{id}/snapshots",
				"appSnapshotRestore": "/api/v1/apps/{id}/snapshots/{snapshot}/restore",
				"appRollbacks": "/api/v1/apps/{id}/rollbacks",
                "fleetNodePools": "/api/v1/fleet/node-pools",
                "fleetPlans": "/api/v1/fleet/plans",
                "fleetReconciliations": "/api/v1/fleet/plans/{planID}/reconciliations",
                "fleetRunnerAttempts": "/api/v1/fleet/plans/{planID}/attempts",
                "fleetGitHub": "/api/v1/fleet/github",
                "fleetGitHubPullRequest": "/api/v1/fleet/plans/{planID}/github/pull-request",
                "fleetGitHubDispatch": "/api/v1/fleet/plans/{planID}/github/dispatch",
                "deployments": "/api/v1/deployments",
                "deploymentSteps": "/api/v1/deployments/{id}/steps",
                "serviceManifest": "/api/v1/services/manifest"
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
            service("mail-mcp", process: "worker", exposure: "private", status: "passing"),
            service("like-trove", process: "web", exposure: "private", status: "passing"),
            service("vigil-gateway", process: "web", exposure: "private", status: "passing"),
            service("contextdb", process: "web", exposure: "local", status: "unknown")
        ],
        operations: [
            operation("app.deploy", app: "mail-mcp", status: .running, offset: -42, message: "Waiting for regional readiness"),
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
        observedAt: now,
		apps: [
			NornAppStatus(
				spec: .init(
					name: "mail-mcp",
					deploy: true,
					migrations: "./bin/migrate",
					infrastructure: .init(postgres: .init(database: "mail_mcp")),
					snapshots: .init(keep: 3, preRestore: true, retentionEnabled: true)
				),
				nomadStatus: "running",
				healthy: true
			)
		]
    )

	static let appSnapshots = [
		NornAppSnapshot(filename: "mail_mcp_pre-migrate_20260825T140000.dump", database: "mail_mcp", timestamp: "20260825T140000", createdAt: now.addingTimeInterval(-3_600), size: 18_400_000),
		NornAppSnapshot(filename: "mail_mcp_manual_20260824T140000.dump", database: "mail_mcp", timestamp: "20260824T140000", createdAt: now.addingTimeInterval(-90_000), size: 17_900_000),
		NornAppSnapshot(filename: "mail_mcp_release_20260820T140000.dump", database: "mail_mcp", timestamp: "20260820T140000", createdAt: now.addingTimeInterval(-435_600), size: 16_800_000),
		NornAppSnapshot(filename: "mail_mcp_release_20260812T140000.dump", database: "mail_mcp", timestamp: "20260812T140000", createdAt: now.addingTimeInterval(-1_126_800), size: 15_600_000),
	]

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

    static let deployments: [NornDeployment] = [
        NornDeployment(
            id: "deploy-mail-mcp-20260825",
            app: "mail-mcp",
            commitSHA: "b3a3958019be2655b3a3958019be2655b3a39580",
            imageTag: "mail-mcp:b3a3958",
            sagaID: "saga-mail-mcp-20260825",
            status: .healthy,
            sourceKind: "git",
            sourceRef: "main",
            sourceDirty: false,
            sourceChanges: nil,
            startedAt: now.addingTimeInterval(-3_260),
            finishedAt: now.addingTimeInterval(-3_200),
            regions: [
                .init(
                    deploymentID: "deploy-mail-mcp-20260825",
                    region: "nyc3",
                    nomadRegion: "global",
                    status: .healthy,
                    desiredWeight: 100,
                    activeWeight: 100,
                    evalID: "eval-mail-mcp",
                    lastError: nil,
                    updatedAt: now.addingTimeInterval(-3_200)
                )
            ]
        )
    ]

    static let deploymentSteps: [String: [NornDeploymentStep]] = [
        "deploy-mail-mcp-20260825": [
            deploymentStep("clone", kind: .readonly, offset: -3_260, durationMs: 1_400),
            deploymentStep("admission", kind: .readonly, offset: -3_258, durationMs: 320),
            deploymentStep("build", kind: .readonly, offset: -3_257, durationMs: 18_200),
            deploymentStep("test", kind: .readonly, offset: -3_238, durationMs: 7_900),
            deploymentStep("submit", kind: .mutable, offset: -3_229, durationMs: 2_100),
            deploymentStep("healthy", kind: .mutable, offset: -3_226, durationMs: 24_000)
        ]
    ]

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
            endpoints: exposure == "public" ? [.init(url: "https://\(app).example.test", region: "nyc3")] : [],
            instances: [
                .init(id: "\(app)-\(process)-service", allocationID: "\(app)-\(process)-alloc", node: "node-app-1", address: "10.0.1.12", port: 8080, status: status, region: "nyc3", nodePool: "app", placementSource: "consul-tags", placementVerified: true)
            ]
        )
    }

    private static func deploymentStep(
        _ name: String,
        kind: NornDeploymentStepKind,
        offset: TimeInterval,
        durationMs: Int64
    ) -> NornDeploymentStep {
        let startedAt = now.addingTimeInterval(offset)
        return NornDeploymentStep(
            deploymentID: "deploy-mail-mcp-20260825",
            app: "mail-mcp",
            sagaID: "saga-mail-mcp-20260825",
            step: name,
            status: .complete,
            kind: kind,
            attempt: 1,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(Double(durationMs) / 1_000),
            durationMs: durationMs,
            message: nil,
            metadata: nil
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
