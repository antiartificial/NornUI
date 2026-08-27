import Foundation

nonisolated enum NornNavigation: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case apps
    case operations
    case fleet
    case platform
    case host
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .apps: "Apps"
        case .operations: "Operations"
        case .fleet: "Fleet"
        case .platform: "Releases"
        case .host: "Host"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles.rectangle.stack"
        case .apps: "square.stack.3d.up"
        case .operations: "waveform.path.ecg.rectangle"
        case .fleet: "server.rack"
        case .platform: "shippingbox.and.arrow.backward"
        case .host: "macmini"
        case .activity: "bolt.horizontal.circle"
        }
    }
}

nonisolated enum NornConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case online
    case reconnecting
    case offline(String)
}

nonisolated struct NornServerProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: URL
    var credentialID: String
    var deviceID: String?
    var tokenID: String?
    var grantedScopes: [String]?
    var tokenExpiresAt: Date?
    var lastRotatedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        credentialID: String? = nil,
        deviceID: String? = nil,
        tokenID: String? = nil,
        grantedScopes: [String]? = nil,
        tokenExpiresAt: Date? = nil,
        lastRotatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.credentialID = credentialID ?? id.uuidString
        self.deviceID = deviceID
        self.tokenID = tokenID
        self.grantedScopes = grantedScopes
        self.tokenExpiresAt = tokenExpiresAt
        self.lastRotatedAt = lastRotatedAt
    }

    var isManagedDevice: Bool { deviceID != nil && tokenID != nil }
}

nonisolated struct NornEnrollmentStartRequest: Encodable, Sendable {
    var deviceName: String
    var platform: String
    var model: String
    var appVersion: String
    var publicKey: String
    var requestedScopes: [String]
}

nonisolated struct NornEnrollmentSession: Decodable, Sendable, Identifiable {
    var id: String
    var userCode: String
    var verifier: String
    var expiresAt: Date
    var verificationPath: String
    var pollPath: String
}

/// A token-bearing response. Keep instances short-lived and never persist or log
/// `token`; only the credential vault may store it.
nonisolated struct NornIssuedToken: Decodable, Sendable {
    var token: String
    var tokenID: String
    var deviceID: String
    var scopes: [String]
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case token, scopes, expiresAt
        case tokenID = "tokenId"
        case deviceID = "deviceId"
    }
}

nonisolated struct NornCapabilities: Codable, Hashable, Sendable {
    struct Authentication: Codable, Hashable, Sendable {
        struct Principal: Codable, Hashable, Sendable {
            var authenticated: Bool
            var subject: String?
            var deviceID: String?
            var scopes: [String]
            var expiresAt: Date?
            var legacy: Bool?

            enum CodingKeys: String, CodingKey {
                case authenticated, subject, scopes, expiresAt, legacy
                case deviceID = "deviceId"
            }
        }

        var scopes: [String]
        var websocketBearerHeader: Bool
        var websocketQueryToken: Bool
        var principal: Principal? = nil
    }

    var protocolVersion: Int
    var serverVersion: String
    var features: [String]
    var auth: Authentication
    var endpoints: [String: String]

    /// Host metrics are optional so older control planes continue to work without
    /// presenting a connection failure in the Host view.
    var supportsHostMetrics: Bool {
        features.contains("host-metrics") && endpoints["hostMetrics"] != nil
    }

	var supportsAppCreation: Bool { features.contains("app-creation") && endpoints["appCreation"] != nil }

    var supportsDurableAppRecovery: Bool {
        features.contains("durable-app-recovery-v1") &&
        endpoints["appSnapshots"] != nil &&
        endpoints["appSnapshotRestore"] != nil &&
        endpoints["appRollbacks"] != nil
    }

    var supportsFleet: Bool {
        features.contains("fleet-v1") &&
        features.contains("fleet-inventory") &&
        features.contains("durable-fleet-capacity-plans") &&
        endpoints["fleetNodePools"] != nil && endpoints["fleetPlans"] != nil
    }

    var supportsFleetReconciliation: Bool {
        features.contains("fleet-reconciliation-v1") && endpoints["fleetReconciliations"] != nil
    }

    var supportsFleetRunnerAttempts: Bool {
        features.contains("fleet-runner-attempts-v1") && endpoints["fleetRunnerAttempts"] != nil
    }

    var grantedScopes: Set<String> { Set(auth.principal?.scopes ?? []) }

    var canOperateFleet: Bool {
        !grantedScopes.isDisjoint(with: ["fleet:operate", "api:write", "admin"])
    }

    var supportsFleetGitHub: Bool {
        features.contains("fleet-github-app-v1") &&
        endpoints["fleetGitHub"] != nil &&
        endpoints["fleetGitHubPullRequest"] != nil &&
        endpoints["fleetGitHubDispatch"] != nil
    }

    var supportsDeploymentVisibility: Bool {
        features.contains("versioned-deployment-history-v1") &&
        endpoints["deployments"] != nil && endpoints["deploymentSteps"] != nil
    }
}

nonisolated struct NornFleetNodePool: Codable, Hashable, Sendable {
    nonisolated struct Replacement: Codable, Hashable, Sendable {
        var strategy: String?
        var requireCapacityHeadroom: Bool?
        var drainTimeout: String?
        var requireReadiness: Bool?
    }

    var size: String
    var min: Int
    var desired: Int
    var max: Int
    var labels: [String: String]?
    var replacement: Replacement?
}

nonisolated struct NornFleetInventory: Codable, Hashable, Sendable {
    nonisolated struct Document: Codable, Hashable, Sendable {
        nonisolated struct Metadata: Codable, Hashable, Sendable {
            var repository: String?
            var environment: String?
            var workflowURL: String?

            enum CodingKeys: String, CodingKey {
                case repository, environment
                case workflowURL = "workflowUrl"
            }
        }

        nonisolated struct Cluster: Codable, Hashable, Sendable {
            var name: String
            var provider: String
            var region: String
        }

        var apiVersion: String
        var kind: String
        var metadata: Metadata?
        var cluster: Cluster
    }

    nonisolated struct Validation: Codable, Hashable, Sendable {
        nonisolated struct Finding: Codable, Hashable, Sendable, Identifiable {
            var severity: String
            var code: String
            var field: String
            var message: String
            var remediation: String?
            var id: String { "\(code):\(field)" }
        }

        var schemaVersion: String
        var documentKind: String
        var name: String?
        var valid: Bool
        var findings: [Finding]
    }

    var schemaVersion: String
    var configured: Bool
    var source: String?
    var digest: String?
    var document: Document?
    var validation: Validation?
    var nodePools: [String: NornFleetNodePool]

    static let unconfigured = Self(
        schemaVersion: "norn.fleet-inventory/v1",
        configured: false,
        nodePools: [:]
    )
}

nonisolated struct NornFleetPlanRequest: Codable, Hashable, Sendable {
    var desired: Int
    var size: String
    var strategy: String?
    var reason: String
}

nonisolated struct NornFleetGitHubStatus: Codable, Hashable, Sendable {
    var schemaVersion: String
    var configured: Bool
    var connected: Bool
    var repository: String?
    var installationID: Int64?
    var defaultBranch: String?
    var configPath: String?
    var planWorkflow: String?
    var applyWorkflow: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, configured, connected, repository, defaultBranch, configPath, planWorkflow, applyWorkflow, message
        case installationID = "installationId"
    }

    static let unconfigured = Self(schemaVersion: "norn.fleet-github-status/v1", configured: false, connected: false)
}

nonisolated struct NornFleetPlanList: Codable, Hashable, Sendable {
    var plans: [NornOperation]
    var count: Int
}

nonisolated struct NornFleetReconciliationList: Codable, Hashable, Sendable {
    var schemaVersion: String
    var planID: String
    var reconciliations: [NornOperation]
    var count: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion, reconciliations, count
        case planID = "planId"
    }
}

nonisolated enum NornFleetRunnerAttemptStatus: String, Codable, Hashable, Sendable {
    case queued, running, succeeded, failed, canceled, abandoned
    var isActive: Bool { self == .queued || self == .running }
}

nonisolated struct NornFleetRunnerAttempt: Identifiable, Codable, Hashable, Sendable {
    var schemaVersion: String
    var id: String
    var planID: String
    var attempt: Int
    var runnerAttemptID: String?
    var status: NornFleetRunnerAttemptStatus
    var currentPhase: String
    var commitSHA: String
    var planSHA256: String
    var workflowURL: URL?
    var retryOf: String?
    var heartbeatSequence: Int64
    var heartbeatTimeoutSeconds: Int
    var revision: Int64
    var startedAt: Date
    var heartbeatAt: Date
    var heartbeatExpiresAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, attempt, status, currentPhase, retryOf, heartbeatSequence
        case heartbeatTimeoutSeconds, revision, startedAt, heartbeatAt, heartbeatExpiresAt, updatedAt, finishedAt, lastError
        case planID = "planId"
        case runnerAttemptID = "runnerAttemptId"
        case commitSHA = "commitSha"
        case planSHA256 = "planSha256"
        case workflowURL = "workflowUrl"
    }
}

nonisolated struct NornFleetRunnerAttemptList: Codable, Hashable, Sendable {
    var schemaVersion: String
    var planID: String
    var attempts: [NornFleetRunnerAttempt]
    var count: Int
    var serverTime: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion, attempts, count, serverTime
        case planID = "planId"
    }
}

nonisolated enum NornDeploymentStatus: String, Codable, Hashable, Sendable {
    case queued
    case building
    case testing
    case migrating
    case submitting
    case healthy
    case deployed
    case failed

    var isActive: Bool {
        switch self {
        case .queued, .building, .testing, .migrating, .submitting: true
        case .healthy, .deployed, .failed: false
        }
    }
}

nonisolated struct NornDeployment: Identifiable, Codable, Hashable, Sendable {
    nonisolated struct Region: Codable, Hashable, Sendable {
        var deploymentID: String?
        var region: String
        var nomadRegion: String
        var status: NornDeploymentStatus
        var desiredWeight: Int
        var activeWeight: Int
        var evalID: String?
        var lastError: String?
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case deploymentID = "deploymentId"
            case region, nomadRegion, status, desiredWeight, activeWeight, lastError, updatedAt
            case evalID = "evalId"
        }
    }

    var id: String
    var app: String
    var commitSHA: String
    var imageTag: String
    var sagaID: String
    var status: NornDeploymentStatus
    var sourceKind: String?
    var sourceRef: String?
    var sourceDirty: Bool?
    var sourceChanges: [String]?
    var startedAt: Date
    var finishedAt: Date?
    var regions: [Region]?

    enum CodingKeys: String, CodingKey {
        case id, app, imageTag, status, sourceKind, sourceRef, sourceDirty, sourceChanges, startedAt, finishedAt, regions
        case commitSHA = "commitSha"
        case sagaID = "sagaId"
    }
}

nonisolated struct NornDeploymentList: Codable, Hashable, Sendable {
    var schemaVersion: String
    var deployments: [NornDeployment]
    var count: Int
    var offset: Int?
}

nonisolated enum NornDeploymentStepStatus: String, Codable, Hashable, Sendable {
    case running
    case complete
    case failed
}

nonisolated enum NornDeploymentStepKind: String, Codable, Hashable, Sendable {
    case readonly
    case mutable
}

nonisolated struct NornDeploymentStep: Identifiable, Codable, Hashable, Sendable {
    var deploymentID: String
    var app: String
    var sagaID: String
    var step: String
    var status: NornDeploymentStepStatus
    var kind: NornDeploymentStepKind?
    var attempt: Int?
    var startedAt: Date
    var finishedAt: Date?
    var durationMs: Int64?
    var message: String?
    var metadata: [String: JSONValue]?

    var id: String { "\(deploymentID):\(step)" }

    enum CodingKeys: String, CodingKey {
        case app, step, status, kind, attempt, startedAt, finishedAt, durationMs, message, metadata
        case deploymentID = "deploymentId"
        case sagaID = "sagaId"
    }
}

nonisolated struct NornDeploymentStepList: Codable, Hashable, Sendable {
    var schemaVersion: String?
    var deploymentID: String?
    var steps: [NornDeploymentStep]
    var count: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion, steps, count
        case deploymentID = "deploymentId"
    }
}

nonisolated enum NornExecutionCheckpointState: String, Hashable, Sendable {
    case completed
    case pending
    case active
    case failed
    case blocked
}

nonisolated struct NornFleetCheckpoint: Identifiable, Hashable, Sendable {
    var phase: String
    var state: NornExecutionCheckpointState
    var operation: NornOperation?
    var runnerAttempt: NornFleetRunnerAttempt?

    var id: String { phase }
}

/// A contract-only projection of append-only runner evidence. It never assumes
/// that a protected workflow is running merely because it was dispatched.
nonisolated struct NornFleetPlanProgress: Hashable, Sendable {
    static let orderedPhases = [
        "infrastructure_applied", "inventory_generated", "nodes_configured",
        "nodes_enrolled", "readiness_verified", "old_nodes_drained", "complete"
    ]

    var checkpoints: [NornFleetCheckpoint]
    var state: NornExecutionCheckpointState

    init(plan: NornOperation, reconciliations: [NornOperation], runnerAttempt: NornFleetRunnerAttempt? = nil) {
        let payload = plan.payload ?? [:]
        let action = payload["action"]?.stringValue
        let currentDesired = payload["current"]?.objectValue?["desired"]?.intValue
        let proposedDesired = payload["proposed"]?.objectValue?["desired"]?.intValue
        let requiresDrain = action == "replace" || (action == "scale" && (proposedDesired ?? 0) < (currentDesired ?? 0))
        let phases = Self.orderedPhases.filter { requiresDrain || $0 != "old_nodes_drained" }
        let newestByPhase = Dictionary(grouping: reconciliations) { $0.payload?["phase"]?.stringValue ?? "" }
            .mapValues { $0.max(by: { $0.updatedAt < $1.updatedAt })! }

        var failureSeen = false
        checkpoints = phases.map { phase in
            let operation = newestByPhase[phase]
            let checkpointState: NornExecutionCheckpointState
            if failureSeen {
                checkpointState = .blocked
            } else if runnerAttempt?.currentPhase == phase && runnerAttempt?.status.isActive == true {
                checkpointState = .active
            } else if runnerAttempt?.currentPhase == phase && [.failed, .canceled, .abandoned].contains(runnerAttempt?.status) {
                checkpointState = .failed
                failureSeen = true
            } else {
                switch operation?.status {
                case .succeeded: checkpointState = .completed
                case .failed, .canceled:
                    checkpointState = .failed
                    failureSeen = true
                case .queued, .running: checkpointState = .active
                case nil: checkpointState = .pending
                }
            }
            return NornFleetCheckpoint(phase: phase, state: checkpointState, operation: operation, runnerAttempt: runnerAttempt?.currentPhase == phase ? runnerAttempt : nil)
        }

        if checkpoints.last?.state == .completed {
            state = .completed
        } else if checkpoints.contains(where: { $0.state == .failed }) {
            state = .blocked
        } else if checkpoints.contains(where: { $0.state == .active }) {
            state = .active
        } else {
            state = .pending
        }
    }
}

nonisolated enum NornAppTemplateKind: String, Codable, CaseIterable, Hashable, Sendable {
	case endpoint
	case worker
}

nonisolated struct NornCreateAppRequest: Codable, Hashable, Sendable {
	var name: String
	var kind: NornAppTemplateKind
	var port: Int?
}

nonisolated struct NornAppSpecSummary: Codable, Hashable, Sendable {
	nonisolated struct Process: Codable, Hashable, Sendable {
		nonisolated struct Scaling: Codable, Hashable, Sendable {
			var min: Int?
		}

		var schedule: String?
		var function: JSONValue?
		var scaling: Scaling?
	}

	nonisolated struct Infrastructure: Codable, Hashable, Sendable {
		nonisolated struct Postgres: Codable, Hashable, Sendable { var database: String }
		var postgres: Postgres? = nil
	}
	nonisolated struct SnapshotPolicy: Codable, Hashable, Sendable {
		var keep: Int? = nil
		var preRestore: Bool? = nil
		var retentionEnabled: Bool? = nil
		var exportBucket: String? = nil
	}
	var name: String
	var deploy: Bool?
	var processes: [String: Process]? = nil
	var migrations: String? = nil
	var infrastructure: Infrastructure? = nil
	var snapshots: SnapshotPolicy? = nil
}

nonisolated struct NornAppMutationReceipt: Codable, Hashable, Sendable {
	var app: String
	var created: Bool?
	var spec: NornAppSpecSummary
}

nonisolated struct NornAppStatus: Identifiable, Codable, Hashable, Sendable {
	nonisolated struct AllocationSummary: Codable, Hashable, Sendable {
		nonisolated struct ProcessCount: Codable, Hashable, Sendable {
			var running: Int
			var active: Int
			var retained: Int
			var total: Int
		}

		var running: Int
		var active: Int
		var retained: Int
		var total: Int
		var byProcess: [String: ProcessCount]?
	}

	var spec: NornAppSpecSummary
	var nomadStatus: String?
	var healthy: Bool
	var allocationSummary: AllocationSummary? = nil
	var id: String { spec.name }
}

nonisolated struct NornAppSnapshot: Identifiable, Codable, Hashable, Sendable {
	var filename: String
	var database: String
	var commitSHA: String? = nil
	var timestamp: String
	var createdAt: Date?
	var size: Int64
	var id: String { filename }

	enum CodingKeys: String, CodingKey {
		case filename, database, timestamp, createdAt, size
		case commitSHA = "commitSha"
	}
}

nonisolated enum NornAppOperationRequest: Hashable, Sendable {
	case snapshot(app: String)
	case pruneSnapshots(app: String, keep: Int)
	case restoreSnapshot(app: String, snapshot: String)
	case migrate(app: String, ref: String)
	case rollback(app: String, regions: [String])

	var app: String {
		switch self {
		case let .snapshot(app), let .pruneSnapshots(app, _), let .restoreSnapshot(app, _), let .migrate(app, _), let .rollback(app, _): app
		}
	}
}

nonisolated struct NornHostMetrics: Codable, Hashable, Sendable {
    nonisolated struct CPU: Codable, Hashable, Sendable {
        var utilizationPercent: Double
        var logicalCores: Int
    }

    nonisolated struct Memory: Codable, Hashable, Sendable {
        var totalBytes: UInt64
        var usedBytes: UInt64
        var availableBytes: UInt64
    }

    var schemaVersion: String
    var observedAt: Date
    var stale: Bool
    var samplePeriodSeconds: Double
    var cpu: CPU
    var memory: Memory
}

nonisolated struct NornHealth: Codable, Hashable, Sendable {
    struct Network: Codable, Hashable, Sendable {
        var mode: String?
        var bindAddr: String?
        var nomadAddr: String?
        var consulAddr: String?
    }

    var status: String
    var services: [String: String]
    var network: Network?
}

/// Versioned host state. Unlike the compatibility health response, this
/// resource carries the latest durable assurance receipt even when that
/// receipt has fallen outside the general operation-history page.
nonisolated struct NornHostStatus: Codable, Hashable, Sendable {
    var schemaVersion: String
    var status: String
    var services: [String: String]
    var latestAssurance: NornOperation?
    var observedAt: Date
}

nonisolated struct NornServiceManifest: Codable, Hashable, Sendable {
    var version: Int
    var generatedAt: Date
    var networkMode: String?
    var services: [NornService]
}

nonisolated struct NornService: Identifiable, Codable, Hashable, Sendable {
    struct Reachability: Codable, Hashable, Sendable {
        var endpointScope: String
        var instanceScope: String
        var exposure: String
        var routable: Bool
    }

    struct Endpoint: Codable, Hashable, Sendable {
        var url: String
        var region: String?
    }

    struct Instance: Codable, Hashable, Sendable {
        var id: String?
        var allocationID: String?
        var node: String?
        var address: String?
        var port: Int?
        var status: String?
        var region: String?
        var nodePool: String?
        var placementSource: String?
        var placementVerified: Bool = false

        enum CodingKeys: String, CodingKey {
            case id, node, address, port, status, region, nodePool, placementSource, placementVerified
            case allocationID = "allocationId"
        }
    }

    var name: String
    var app: String
    var process: String
    var type: String
    var status: String
    var healthPath: String?
    var reachability: Reachability
    var endpoints: [Endpoint]?
    var instances: [Instance]?

    var id: String { name }
    var isPassing: Bool { status == "passing" }
}

nonisolated enum NornOperationStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case canceled

    var isActive: Bool { self == .queued || self == .running }
    var isTerminal: Bool { !isActive }
}

nonisolated struct NornOperation: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: String
    var app: String?
    var sagaID: String?
    var ref: String?
    var status: NornOperationStatus
    var risk: String?
    var source: String?
    var message: String?
    var attempts: Int?
    var maxAttempts: Int?
    var lockedBy: String?
    var lockedUntil: Date?
    var nextAttemptAt: Date?
    var lastError: String?
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var payload: [String: JSONValue]? = nil
    var metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, kind, app, ref, status, risk, source, message, attempts, maxAttempts
        case lockedBy, lockedUntil, nextAttemptAt, lastError, startedAt, updatedAt, finishedAt, payload, metadata
        case sagaID = "sagaId"
    }
}

nonisolated struct NornOperationList: Codable, Hashable, Sendable {
    var operations: [NornOperation]
    var count: Int
}

nonisolated struct NornReleaseList: Codable, Hashable, Sendable {
    var current: String?
    var releases: [NornRelease]

    /// One row per immutable artifact, newest first.
    ///
    /// Older Norn servers can expose both an activation receipt and an imported
    /// artifact receipt for the same SHA, and may also surface an atomic staging
    /// directory. Those records describe one binary, not separate releases.
    func canonicalized() -> NornReleaseList {
        NornReleaseList(current: current, releases: NornRelease.canonicalHistory(releases))
    }
}

nonisolated struct NornRelease: Identifiable, Codable, Hashable, Sendable {
    var sha: String
    var version: String
    var createdAt: Date
    var path: String
    var current: Bool
    var displayVersion: String? = nil

    var id: String { sha }

    /// The best label this receipt can prove without consulting release history.
    ///
    /// New servers send `displayVersion`. Older servers may wrap a semantic
    /// version in an artifact name, so prefer the semantic portion when present.
    var directDisplayLabel: String? {
        if let displayVersion = displayVersion?.nornNonempty {
            return displayVersion.nornSemanticVersion ?? displayVersion
        }
        return version.nornSemanticVersion
    }

    /// A human-readable, version-first label with compatibility for older APIs.
    ///
    /// Legacy `platform-<sha>...` values can identify an earlier release receipt.
    /// Follow only those exact SHA links and reuse a semantic label that the list
    /// actually contains. The suffix remains the current immutable SHA rather
    /// than an inferred (and potentially misleading) commit distance.
    func displayLabel(in releases: [NornRelease]) -> String {
        if let directDisplayLabel {
            return directDisplayLabel
        }

        if let siblingLabel = releases.lazy
            .filter({ $0.sha == sha && $0 != self })
            .compactMap(\.directDisplayLabel)
            .first {
            return siblingLabel
        }

        var visited = Set<String>()
        if let semanticBase = inheritedSemanticBase(in: releases, visited: &visited) {
            return "\(semanticBase) · \(shortSHA)"
        }

        let rawVersion = version.nornNonempty
        if rawVersion?.lowercased().hasPrefix("platform-") == true {
            return "Platform \(shortSHA)"
        }
        if rawVersion?.nornLooksLikeSHA == true || rawVersion == nil {
            return "Release \(shortSHA)"
        }
        return rawVersion ?? "Release \(shortSHA)"
    }

    var shortSHA: String { String(sha.prefix(8)) }

    /// Collapses multiple receipts for the same immutable artifact and orders
    /// the resulting history by actual timestamps rather than encoded strings.
    static func canonicalHistory(_ releases: [NornRelease]) -> [NornRelease] {
        let groups = Dictionary(grouping: releases) { release in
            let normalizedSHA = release.sha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedSHA.isEmpty {
                return "missing-sha|\(release.path)|\(release.version)|\(release.createdAt.timeIntervalSince1970)"
            }
            return normalizedSHA
        }

        return groups.values
            .compactMap(canonicalRelease)
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.sha.localizedStandardCompare(rhs.sha) == .orderedDescending
            }
    }

    private static func canonicalRelease(from receipts: [NornRelease]) -> NornRelease? {
        guard var release = receipts.max(by: { releasePreference($0) < releasePreference($1) }) else {
            return nil
        }

        release.current = receipts.contains(where: \.current)
        release.createdAt = receipts.map(\.createdAt).max() ?? release.createdAt
        if release.displayVersion?.nornNonempty == nil {
            release.displayVersion = receipts.compactMap(\.displayVersion).first(where: { $0.nornNonempty != nil })
        }
        return release
    }

    private static func releasePreference(_ release: NornRelease) -> ReleasePreference {
        let selfArtifactVersion = "platform-\(release.sha.lowercased())"
        let describesArtifact = release.version.lowercased() != selfArtifactVersion
        return ReleasePreference(
            current: release.current,
            hasDisplayVersion: release.displayVersion?.nornNonempty != nil,
            hasSemanticVersion: release.directDisplayLabel != nil,
            describesArtifact: describesArtifact,
            createdAt: release.createdAt,
            stableTieBreak: "\(release.version)|\(release.path)"
        )
    }

    private var legacyAncestorSHA: String? {
        let value = version.lowercased()
        let prefix = "platform-"
        guard value.hasPrefix(prefix) else { return nil }
        let remainder = value.dropFirst(prefix.count)
        guard remainder.count >= 40 else { return nil }
        let candidate = String(remainder.prefix(40))
        guard candidate.nornLooksLikeSHA else { return nil }
        return candidate
    }

    private var semanticPlatformBase: String? {
        (displayVersion?.nornNonempty ?? version).nornSemanticBase.map { "\($0)-platform" }
    }

    private func inheritedSemanticBase(
        in releases: [NornRelease],
        visited: inout Set<String>
    ) -> String? {
        let recordKey = "\(sha.lowercased())|\(version)|\(displayVersion ?? "")"
        guard visited.insert(recordKey).inserted else { return nil }

        if let ancestorSHA = legacyAncestorSHA {
            for ancestor in releases where ancestor.sha.lowercased() == ancestorSHA {
                if let base = ancestor.semanticPlatformBase {
                    return base
                }
                if let base = ancestor.inheritedSemanticBase(in: releases, visited: &visited) {
                    return base
                }
            }
        }

        for sibling in releases where sibling.sha == sha && sibling != self {
            if let base = sibling.semanticPlatformBase {
                return base
            }
            if let base = sibling.inheritedSemanticBase(in: releases, visited: &visited) {
                return base
            }
        }
        return nil
    }
}

private nonisolated struct ReleasePreference: Comparable {
    let current: Bool
    let hasDisplayVersion: Bool
    let hasSemanticVersion: Bool
    let describesArtifact: Bool
    let createdAt: Date
    let stableTieBreak: String

    static func < (lhs: ReleasePreference, rhs: ReleasePreference) -> Bool {
        if lhs.current != rhs.current { return !lhs.current && rhs.current }
        if lhs.hasDisplayVersion != rhs.hasDisplayVersion { return !lhs.hasDisplayVersion && rhs.hasDisplayVersion }
        if lhs.hasSemanticVersion != rhs.hasSemanticVersion { return !lhs.hasSemanticVersion && rhs.hasSemanticVersion }
        if lhs.describesArtifact != rhs.describesArtifact { return !lhs.describesArtifact && rhs.describesArtifact }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.stableTieBreak < rhs.stableTieBreak
    }
}

private extension String {
    nonisolated var nornNonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated var nornSemanticVersion: String? {
        guard let range = range(
            of: #"v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let label = String(self[range])
        return label.replacingOccurrences(
            of: #"^(v[0-9]+\.[0-9]+\.[0-9]+)-control"#,
            with: "$1-platform",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    nonisolated var nornSemanticBase: String? {
        guard let range = range(
            of: #"v[0-9]+\.[0-9]+\.[0-9]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return String(self[range])
    }

    nonisolated var nornLooksLikeSHA: Bool {
        guard (7...64).contains(count) else { return false }
        return allSatisfy { $0.isHexDigit }
    }
}

nonisolated struct NornControlEvent: Identifiable, Codable, Hashable, Sendable {
    var id: Int64
    var timestamp: Date
    var type: String
    var appID: String?
    var payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case id, timestamp, type, payload
        case appID = "appId"
    }
}

nonisolated enum NornMaintenanceRequest: Hashable, Sendable {
    case platformPreflight(ref: String)
    case platformUpgrade(ref: String, mode: String, drainMode: String)
    case platformRollback(sha: String)
    case platformSmoke
    case hostAssurance
}

nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(value)
    }
}

nonisolated struct NornDashboardSnapshot: Hashable, Sendable {
    var capabilities: NornCapabilities
    var health: NornHealth
    var services: [NornService]
    var operations: [NornOperation]
    var releases: [NornRelease]
    var observedAt: Date
	var apps: [NornAppStatus] = []

    var passingServices: Int { services.filter(\.isPassing).count }
    var activeOperations: [NornOperation] { operations.filter { $0.status.isActive } }
}
