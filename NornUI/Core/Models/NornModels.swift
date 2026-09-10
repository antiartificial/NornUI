import Foundation

nonisolated enum NornNavigation: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case apps
    case delivery
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
        case .delivery: "Delivery"
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
        case .delivery: "arrow.triangle.branch"
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
    struct Environment: Codable, Hashable, Sendable {
        var id: String
        var profile: String
    }
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
    var environment: Environment? = nil
    /// `fleet-only` exposes the infrastructure authority, not a runtime
    /// control-plane. Clients must not infer app or host state from it.
    var authority: String? = nil

    var isFleetAuthorityOnly: Bool {
        authority == "fleet-only" || features.contains("fleet-authority-only-v1")
    }
    /// Compatibility capability documents may list supported scopes, but do
    /// not identify the caller. Only an explicit authenticated principal is
    /// evidence for enabling privileged UI actions.
    var authenticatedPrincipal: Authentication.Principal? {
        guard let principal = auth.principal, principal.authenticated else { return nil }
        return principal
    }

    var grantedScopes: Set<String> { Set(authenticatedPrincipal?.scopes ?? []) }

    /// Environment identity for authority banners. Unlike the legacy release
    /// model's compatibility default, this never invents an environment.
    var assertedEnvironmentID: String? { environment?.id }
    var assertedEnvironmentProfile: String? { environment?.profile }

    /// Host metrics are optional so older control planes continue to work without
    /// presenting a connection failure in the Host view.
    var supportsHostMetrics: Bool {
        !isFleetAuthorityOnly && features.contains("host-metrics") && endpoints["hostMetrics"] != nil
    }

	var supportsAppCreation: Bool { !isFleetAuthorityOnly && features.contains("app-creation") && endpoints["appCreation"] != nil }

    var supportsDurableAppRecovery: Bool {
        !isFleetAuthorityOnly && features.contains("durable-app-recovery-v1") &&
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

    var canOperateFleet: Bool {
        !grantedScopes.isDisjoint(with: ["api:write", "admin"])
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

    var supportsReleasePipeline: Bool {
        !isFleetAuthorityOnly && ["release-provenance-v1", "release-qualifications-v2", "release-promotions-v1"].allSatisfy(features.contains)
    }

    var supportsEventStream: Bool {
        !isFleetAuthorityOnly && endpoints["events"] != nil
    }

    var environmentID: String { environment?.id ?? "development" }
    var environmentProfile: String { environment?.profile ?? "development" }
}

/// Immutable staging evidence passed unchanged to a production control plane.
/// The server, rather than the desktop client, verifies this receipt.
nonisolated struct NornReleaseQualification: Codable, Hashable, Sendable, Identifiable {
    var schemaVersion: String
    var id: String
    var deploymentID: String
    var app: String
    var sourceSHA: String
    var artifact: String
    var environment: String
    /// Retain the exact wire timestamps: they are part of the signed receipt
    /// that production must receive unchanged.
    var issuedAt: String
    var expiresAt: String
    var keyID: String
    var signature: String
    var candidate: NornReleaseCandidate
    var dsse: NornDSSEEnvelope

    var expiryDate: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
    var isExpired: Bool { expiryDate.map { $0 < .now } ?? true }
    var isV2Signed: Bool {
        schemaVersion == "norn.release-qualification/v2" &&
        !candidate.signerWorkflowRef.isEmpty &&
        candidate.signerWorkflowRef.hasSuffix("@\(candidate.signerWorkflowSHA)") &&
        !candidate.signerWorkflowSHA.isEmpty &&
        dsse.payloadType == "application/vnd.norn.release-qualification.v2+json" &&
        dsse.signatures.count == 1 &&
        dsse.signatures.first?.keyID == keyID && dsse.signatures.first?.sig == signature
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, app, artifact, environment, issuedAt, expiresAt, signature, candidate, dsse
        case deploymentID = "deploymentId"
        case sourceSHA = "sourceSha"
        case keyID = "keyId"
    }
}

nonisolated struct NornReleaseCandidate: Codable, Hashable, Sendable {
    var provider: String
    var repository: String
    var repositoryID: String
    var ownerID: String
    /// Server-derived GitHub visibility. It is part of the signed candidate
    /// identity and must survive decode/re-encode of DSSE-backed evidence.
    var repositoryVisibility: String?
    var runID: String
    var runAttempt: String?
    var workflowRef: String
    var workflowSHA: String
    var signerWorkflowRef: String
    var signerWorkflowSHA: String
    var ref: String
    var attestation: NornReleaseAttestation
    enum CodingKeys: String, CodingKey {
        case provider, repository, repositoryVisibility, ref, attestation
        case repositoryID = "repositoryId"
        case ownerID = "ownerId"
        case runID = "runId"
        case runAttempt
        case workflowRef
        case workflowSHA = "workflowSha"
        case signerWorkflowRef
        case signerWorkflowSHA = "signerWorkflowSha"
    }
}

nonisolated struct NornReleaseAttestation: Codable, Hashable, Sendable {
    /// The server selects this from its independently verified GitHub OIDC identity.
    var mode: String? = nil
    /// Display-only server verifier identity. Never a credential, token, or installation ID.
    var verifier: String? = nil
    var verifierIdentity: String? = nil
    var issuer: String
    var subjectDigest: String
    var materialSHA: String
    var provenanceURI: String?
    var sbomURI: String?
    /// Portable, server-signed provenance and SPDX statements used by the
    /// ordinary-private repository trust path. GitHub-backed adapters omit it.
    var bundle: NornReleaseAttestationBundle?

    var displayVerifier: String { verifier ?? verifierIdentity ?? "Not reported" }
    var displayMode: String {
        switch mode {
        case "norn-signed-private": "Norn-signed private"
        case "github-private": "GitHub Enterprise private"
        case "github-public": "GitHub public"
        case let value?: value
        case nil: "Not reported"
        }
    }

    enum CodingKeys: String, CodingKey {
        case mode, verifier, verifierIdentity, issuer, subjectDigest, bundle
        case materialSHA = "materialSha"
        case provenanceURI = "provenanceUri"
        case sbomURI = "sbomUri"
    }
}

nonisolated struct NornReleaseAttestationBundle: Codable, Hashable, Sendable {
    var schemaVersion: String
    var keyID: String
    var provenance: NornDSSEEnvelope
    var sbom: NornDSSEEnvelope

    enum CodingKeys: String, CodingKey {
        case schemaVersion, provenance, sbom
        case keyID = "keyId"
    }
}

nonisolated struct NornDSSEEnvelope: Codable, Hashable, Sendable {
    var payloadType: String
    var payload: String
    var signatures: [NornDSSESignature]
}

nonisolated struct NornDSSESignature: Codable, Hashable, Sendable {
    var keyID: String
    var sig: String

    enum CodingKeys: String, CodingKey { case sig; case keyID = "keyid" }
}

nonisolated struct NornReleaseQualificationList: Codable, Hashable, Sendable {
    var schemaVersion: String
    var qualifications: [NornReleaseQualification]
    var count: Int
}

nonisolated struct NornReleaseActionRequest: Codable, Hashable, Sendable {
    var sourceSHA: String
    var artifact: String?

    enum CodingKeys: String, CodingKey { case artifact; case sourceSHA = "sourceSha" }
}

nonisolated struct NornReleasePromotionRequest: Codable, Hashable, Sendable {
    var qualification: NornReleaseQualification
    var sourceSHA: String
    var artifact: String

    enum CodingKeys: String, CodingKey { case qualification, artifact; case sourceSHA = "sourceSha" }
}

nonisolated struct NornEventStreamInfo: Decodable, Hashable, Sendable {
    struct Bounds: Decodable, Hashable, Sendable {
        var oldestCursor: Int64
        var latestCursor: Int64
        var retainedEvents: Int64
    }

    var protocolVersion: Int
    var bounds: Bounds
    var gapDetection: Bool
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
    var environment: String?
    var defaultBranch: String?
    var configPath: String?
    var planWorkflow: String?
    var applyWorkflow: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, configured, connected, repository, environment, defaultBranch, configPath, planWorkflow, applyWorkflow, message
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

nonisolated enum NornFleetTimingAvailability: String, Codable, Hashable, Sendable {
    case available, unavailable
}

nonisolated enum NornFleetTimingOperationClass: String, Codable, Hashable, Sendable {
    case coldStart = "cold_start"
    case unknown
}

nonisolated enum NornFleetTimingConfidence: String, Codable, Hashable, Sendable {
    case low, none
}

nonisolated enum NornFleetTimingProvenanceMethod: String, Codable, Hashable, Sendable {
    case configuredRange = "configured_range"
    case unavailable
}

/// Server-provided, non-authoritative timing range. Values are milliseconds;
/// this client deliberately does not convert timestamps into a replacement ETA.
nonisolated struct NornFleetTimingRange: Codable, Hashable, Sendable {
    var lowMs: Int64
    var highMs: Int64

    var isUsable: Bool { lowMs >= 0 && highMs >= lowMs }
}

nonisolated struct NornFleetTimingCompletion: Codable, Hashable, Sendable {
    var earliestAt: Date
    var latestAt: Date
}

nonisolated struct NornFleetTimingProvenance: Codable, Hashable, Sendable {
    var method: NornFleetTimingProvenanceMethod
    var configuredRange: NornFleetTimingRange?
    var sampleCount: Int
    var successfulSampleCount: Int
    var exclusions: [String]

    /// Human-readable work excluded from the runner-only timing estimate.
    /// Keep an unfamiliar server code legible without making it part of the
    /// modeled contract.
    var excludedWorkSummary: String? {
        let labels = exclusions.map { exclusion in
            switch exclusion {
            case "review_approval": "review/approval"
            case "github_queue": "GitHub queue"
            case "dns_propagation": "DNS propagation"
            case "application_migrations": "application migrations"
            default: exclusion.replacingOccurrences(of: "_", with: " ")
            }
        }
        guard !labels.isEmpty else { return nil }
        return "Excludes \(Self.joined(labels))."
    }

    private static func joined(_ labels: [String]) -> String {
        switch labels.count {
        case 0: ""
        case 1: labels[0]
        case 2: "\(labels[0]) and \(labels[1])"
        default: "\(labels.dropLast().joined(separator: ", ")), and \(labels.last!)"
        }
    }
}

nonisolated struct NornFleetTimingPhase: Codable, Hashable, Sendable {
    var name: String
    var state: NornFleetTimingPhaseState
    var elapsedMs: Int64
    var estimatedRemaining: NornFleetTimingRange?
}

nonisolated enum NornFleetTimingPhaseState: String, Codable, Hashable, Sendable {
    case active
    case complete
    case terminal
}

/// Optional, server-authored timing context for one protected runner attempt.
/// It describes runner work only: review and dispatch queue time are outside
/// this contract.
nonisolated struct NornFleetRunnerTiming: Codable, Hashable, Sendable {
    var schemaVersion: String
    var scope: String
    var asOf: Date
    var availability: NornFleetTimingAvailability
    var operationClass: NornFleetTimingOperationClass
    var elapsedMs: Int64
    var estimatedRemaining: NornFleetTimingRange?
    var estimatedTotal: NornFleetTimingRange?
    var estimatedCompletion: NornFleetTimingCompletion?
    var confidence: NornFleetTimingConfidence
    var provenance: NornFleetTimingProvenance
    var phases: [NornFleetTimingPhase]
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
    var phaseStartedAt: Date? = nil
    var timing: NornFleetRunnerTiming? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, attempt, status, currentPhase, retryOf, heartbeatSequence
        case heartbeatTimeoutSeconds, revision, startedAt, heartbeatAt, heartbeatExpiresAt, updatedAt, finishedAt, lastError, phaseStartedAt, timing
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
        "prechange_verified", "provider_applying",
        "infrastructure_applied", "inventory_generated", "nodes_configured",
        "nodes_enrolled", "readiness_verified", "old_nodes_drained", "complete"
    ]
    static let destructiveOnlyPhases: Set<String> = [
        "prechange_verified", "provider_applying", "old_nodes_drained"
    ]

    var checkpoints: [NornFleetCheckpoint]
    var state: NornExecutionCheckpointState

    var provenCheckpointCount: Int {
        checkpoints.filter { $0.state == .completed }.count
    }

    var checkpointProgressAccessibilityValue: String {
        "\(provenCheckpointCount) of \(checkpoints.count) provisioning checkpoints proven"
    }

    init(plan: NornOperation, reconciliations: [NornOperation], runnerAttempt: NornFleetRunnerAttempt? = nil) {
        let payload = plan.payload ?? [:]
        let action = payload["action"]?.stringValue
        let currentDesired = payload["current"]?.objectValue?["desired"]?.intValue
        let proposedDesired = payload["proposed"]?.objectValue?["desired"]?.intValue
        let requiresDrain = action == "replace" || (action == "scale" && (proposedDesired ?? 0) < (currentDesired ?? 0))
        let phases = requiresDrain
            ? Self.orderedPhases
            : Self.orderedPhases.filter { !Self.destructiveOnlyPhases.contains($0) }
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

nonisolated enum NornFleetTimingState: String, Hashable, Sendable {
    case waiting
    case active
    case completed
    case paused
}

/// Display-ready timing derived only from a durable runner attempt. In
/// particular, it does not use the plan receipt, review receipt, or dispatch
/// receipt as a start time.
nonisolated struct NornFleetTimingProjection: Hashable, Sendable {
    var state: NornFleetTimingState
    var phaseLabel: String
    var availability: NornFleetTimingAvailability?
    var operationClass: NornFleetTimingOperationClass?
    var totalRange: NornFleetTimingRange?
    var elapsedMs: Int64?
    var remaining: NornFleetTimingRange?
    var completionDurationMs: Int64?
    var estimatedCompletion: NornFleetTimingCompletion?
    var confidence: NornFleetTimingConfidence?
    var provenance: NornFleetTimingProvenance?

    init(attempt: NornFleetRunnerAttempt, now: Date = .now) {
        let timing = attempt.timing
        let phase = timing?.phases.first { $0.name == attempt.currentPhase }
            ?? timing?.phases.first { $0.state == .active }
        phaseLabel = phase?.name.replacingOccurrences(of: "_", with: " ").capitalized
            ?? attempt.currentPhase.replacingOccurrences(of: "_", with: " ").capitalized
        availability = timing?.availability
        operationClass = timing?.operationClass
        totalRange = timing?.availability == .available && timing?.estimatedTotal?.isUsable == true ? timing?.estimatedTotal : nil
        remaining = timing?.availability == .available && timing?.estimatedRemaining?.isUsable == true ? timing?.estimatedRemaining : nil
        estimatedCompletion = timing?.availability == .available ? timing?.estimatedCompletion : nil
        confidence = timing?.confidence
        provenance = timing?.provenance

        let serverElapsed = timing.map { Swift.max(Int64(0), $0.elapsedMs) }

        switch attempt.status {
        case .queued:
            state = .waiting
            elapsedMs = serverElapsed
            completionDurationMs = nil
        case .running:
            state = .active
            elapsedMs = serverElapsed ?? Self.elapsedSince(attempt.startedAt, now: now)
            completionDurationMs = nil
        case .succeeded:
            state = .completed
            elapsedMs = serverElapsed ?? attempt.finishedAt.map { Self.elapsedSince(attempt.startedAt, now: $0) }
            completionDurationMs = elapsedMs
        case .failed, .canceled, .abandoned:
            state = .paused
            let terminal = attempt.finishedAt ?? attempt.updatedAt
            elapsedMs = serverElapsed ?? Self.elapsedSince(attempt.startedAt, now: terminal)
            completionDurationMs = nil
        }

        if timing?.availability != .available {
            totalRange = nil
            remaining = nil
            estimatedCompletion = nil
        }

        if state == .paused {
            remaining = nil
            estimatedCompletion = nil
        }
    }

    private static func elapsedSince(_ start: Date, now: Date) -> Int64 {
        Swift.max(0, Int64((now.timeIntervalSince(start) * 1_000).rounded()))
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
            var max: Int? = nil
            var perRegion: Int? = nil
		}

		var schedule: String?
		var function: JSONValue?
		var scaling: Scaling?
        var singleton: Bool? = nil
        var hostPort: Int? = nil
        var regions: [String]? = nil
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
    var regions: JSONValue? = nil
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

/// A compact, locally retained host sample. The control plane intentionally
/// serves a current sample only; the native app builds this bounded history
/// without requiring a new server capability.
nonisolated struct NornHostMetricSample: Codable, Hashable, Sendable, Identifiable {
    var observedAt: Date
    var cpuPercent: Double
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64

    var id: Date { observedAt }
    var memoryPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100
    }

    init(metrics: NornHostMetrics) {
        observedAt = metrics.observedAt
        cpuPercent = metrics.cpu.utilizationPercent
        memoryUsedBytes = metrics.memory.usedBytes
        memoryTotalBytes = metrics.memory.totalBytes
    }

    init(observedAt: Date, cpuPercent: Double, memoryUsedBytes: UInt64, memoryTotalBytes: UInt64) {
        self.observedAt = observedAt
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
    }
}

/// Current Nomad allocation usage exposed by Norn's compatibility resource
/// suggestions route. The macOS app records this alongside host samples so
/// tenant overlays remain useful without inventing container measurements.
nonisolated struct NornResourceSuggestionList: Codable, Hashable, Sendable {
    var suggestions: [NornResourceSuggestion]
}

nonisolated struct NornResourceSuggestion: Codable, Hashable, Sendable {
    var app: String
    var process: String
    var declaredMemoryMB: Int
    var declaredCpuMHz: Int
    var usedMemoryMB: Int
    var peakMemoryMB: Int
    var cpuPercent: Double
    var status: String
    var reason: String
}

nonisolated struct NornServiceMetricSample: Codable, Hashable, Sendable, Identifiable {
    var observedAt: Date
    var app: String
    var process: String
    var cpuPercent: Double
    var memoryPercent: Double

    var seriesID: String { "\(app)/\(process)" }
    var displayName: String { app == process ? app : "\(app) / \(process)" }
    var id: String { "\(seriesID)@\(observedAt.timeIntervalSinceReferenceDate)" }

    init(observedAt: Date, suggestion: NornResourceSuggestion) {
        self.observedAt = observedAt
        app = suggestion.app
        process = suggestion.process
        cpuPercent = max(0, suggestion.cpuPercent)
        if suggestion.declaredMemoryMB > 0 {
            memoryPercent = max(0, Double(suggestion.usedMemoryMB) / Double(suggestion.declaredMemoryMB) * 100)
        } else {
            memoryPercent = 0
        }
    }

    init(observedAt: Date, app: String, process: String, cpuPercent: Double, memoryPercent: Double) {
        self.observedAt = observedAt
        self.app = app
        self.process = process
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
    }
}

nonisolated enum NornHostMetricsRefreshInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case seconds5 = 5
    case seconds10 = 10
    case seconds30 = 30
    case minute1 = 60
    case minutes5 = 300
    case minutes10 = 600

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .seconds5: "5 sec"
        case .seconds10: "10 sec"
        case .seconds30: "30 sec"
        case .minute1: "1 min"
        case .minutes5: "5 min"
        case .minutes10: "10 min"
        }
    }
}

nonisolated enum NornHostMetricsWindow: Int, CaseIterable, Codable, Identifiable, Sendable {
    case minutes5 = 300
    case minutes15 = 900
    case hour1 = 3_600
    case hours6 = 21_600
    case hours24 = 86_400
    case days7 = 604_800
    case days30 = 2_592_000

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .minutes5: "5 min"
        case .minutes15: "15 min"
        case .hour1: "1 hr"
        case .hours6: "6 hr"
        case .hours24: "24 hr"
        case .days7: "7 days"
        case .days30: "30 days"
        }
    }
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
    var expectedState: String? = nil
    var schedule: String? = nil
    var healthPath: String?
    var reachability: Reachability
    var endpoints: [Endpoint]?
    var instances: [Instance]?

    var id: String { name }
    var isPassing: Bool { ["passing", "up", "ok"].contains(status.lowercased()) }
    var isExpectedIdle: Bool {
        switch expectedState?.lowercased() {
        case "disabled", "paused": true
        case "scheduled", "on_demand": instances?.isEmpty != false
        default: false
        }
    }
    var needsAttention: Bool { !isPassing && !isExpectedIdle }
    var displayStatus: String { isExpectedIdle ? (expectedState ?? status) : status }
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
