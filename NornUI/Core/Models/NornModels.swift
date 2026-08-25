import Foundation

nonisolated enum NornNavigation: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case apps
    case operations
    case fleet
    case platform
    case host

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .apps: "Apps"
        case .operations: "Operations"
        case .fleet: "Fleet"
        case .platform: "Releases"
        case .host: "Host"
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

    init(id: UUID = UUID(), name: String, baseURL: URL, credentialID: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.credentialID = credentialID ?? id.uuidString
    }
}

nonisolated struct NornCapabilities: Codable, Hashable, Sendable {
    struct Authentication: Codable, Hashable, Sendable {
        var scopes: [String]
        var websocketBearerHeader: Bool
        var websocketQueryToken: Bool
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

    var supportsFleet: Bool {
        features.contains("fleet-v1") &&
        features.contains("fleet-inventory") &&
        features.contains("durable-fleet-capacity-plans") &&
        endpoints["fleetNodePools"] != nil && endpoints["fleetPlans"] != nil
    }

    var supportsFleetReconciliation: Bool {
        features.contains("fleet-reconciliation-v1") && endpoints["fleetReconciliations"] != nil
    }

    var supportsFleetGitHub: Bool {
        features.contains("fleet-github-app-v1") &&
        endpoints["fleetGitHub"] != nil &&
        endpoints["fleetGitHubPullRequest"] != nil &&
        endpoints["fleetGitHubDispatch"] != nil
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
	var name: String
	var deploy: Bool?
}

nonisolated struct NornAppMutationReceipt: Codable, Hashable, Sendable {
	var app: String
	var created: Bool?
	var spec: NornAppSpecSummary
}

nonisolated struct NornAppStatus: Identifiable, Codable, Hashable, Sendable {
	var spec: NornAppSpecSummary
	var nomadStatus: String?
	var healthy: Bool
	var id: String { spec.name }
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
        var node: String?
        var address: String?
        var port: Int?
        var status: String?
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
}

nonisolated struct NornRelease: Identifiable, Codable, Hashable, Sendable {
    var sha: String
    var version: String
    var createdAt: Date
    var path: String
    var current: Bool

    var id: String { sha }
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
