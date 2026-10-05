import Foundation

/// Codable shapes for the Fleet resource view (control-v1 `FleetResource`).
/// Enum-like fields stay `String` so a newer server's unknown values survive decoding.
nonisolated struct NornFleetResource: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var targetID: String
    var revision: Int64
    var authorityEpoch: Int64
    var observationSequence: Int64
    var createdAt: Date
    var updatedAt: Date
    var desired: NornFleetResourceDesired
    var desiredHistory: [NornFleetResourceDesired]
    var status: NornFleetResourceStatus
    var blocker: NornFleetResourceBlocker?
    var observed: [String: NornFleetObservedSource]
    var approvalPolicy: NornFleetApprovalPolicy
    var executionMode: String?
    var controller: NornFleetControllerLiveness
    var readAt: Date

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, revision, authorityEpoch, observationSequence, createdAt, updatedAt
        case desired, desiredHistory, status, blocker, observed, approvalPolicy
        case executionMode, controller, readAt
        case targetID = "targetId"
    }
}

nonisolated struct NornFleetResourceList: Codable, Hashable, Sendable {
    var items: [NornFleetResource]
    var next: String?
    var controller: NornFleetControllerLiveness
}

nonisolated struct NornFleetResourceDesired: Codable, Hashable, Sendable {
    var generation: Int64
    var planID: String?
    var commitSha: String?
    var repository: String?
    var verification: String?
    var acceptedAt: Date?
    var acceptedBy: String?
    var converge: NornFleetConvergeView?

    enum CodingKeys: String, CodingKey {
        case generation, commitSha, repository, verification, acceptedAt, acceptedBy, converge
        case planID = "planId"
    }
}

nonisolated struct NornFleetConvergeView: Codable, Hashable, Sendable {
    var planSha256: String
    var requiresApproval: Bool
    var approved: Bool
    var refused: Bool?
}

nonisolated struct NornFleetResourceCondition: Codable, Hashable, Sendable, Identifiable {
    var type: String
    var status: String
    var reason: String?
    var message: String?
    var observedAt: Date?
    var evidenceRefs: [String]
    var observationSequence: Int64?

    var id: String { type }
}

nonisolated struct NornFleetLastApplied: Codable, Hashable, Sendable {
    var generation: Int64
    var commitSha: String
    var planID: String
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case generation, commitSha, reason
        case planID = "planId"
    }
}

nonisolated struct NornFleetActive: Codable, Hashable, Sendable {
    var planID: String
    var dispatchRunID: String?
    var attemptIDs: [String]
    var fenceGeneration: Int64
    var occupancy: String
    var occupancyReason: String?
    var resumeApproved: Bool?

    enum CodingKeys: String, CodingKey {
        case fenceGeneration, occupancy, occupancyReason, resumeApproved
        case planID = "planId"
        case dispatchRunID = "dispatchRunId"
        case attemptIDs = "attemptIds"
    }
}

nonisolated struct NornFleetResourceStatus: Codable, Hashable, Sendable {
    var observedGeneration: Int64
    var lastAppliedGeneration: Int64
    var lastApplied: NornFleetLastApplied?
    var active: NornFleetActive?
    var conditions: [NornFleetResourceCondition]
    var nextAction: String?
    var evaluatedAt: Date?
}

nonisolated struct NornFleetResourceBlocker: Codable, Hashable, Sendable {
    var kind: String
    var reason: String
    var message: String?
    var condition: String?
    var planID: String?

    enum CodingKeys: String, CodingKey {
        case kind, reason, message, condition
        case planID = "planId"
    }
}

nonisolated struct NornFleetObservedSource: Codable, Hashable, Sendable {
    var observedAt: Date
    var sequence: Int64
}

nonisolated struct NornFleetApprovalPolicy: Codable, Hashable, Sendable {
    var basis: String
    var protectedBranch: Bool
    var mergedPullRequest: Bool
    var planWorkflowSucceeded: Bool
    var boundPlanDigest: Bool
    var authorizedDispatch: Bool
    var ownerApprovalEnvelope: Bool
    var environmentReviewers: String
    var independentReview: String
    var protectedBranchVerified: Bool?
    var validateWorkflowSucceeded: Bool?
    var mergeGate: String?
    var destructiveApproval: String?
    var approvedBy: String?
    var requiredReviews: String?
}

nonisolated struct NornFleetControllerLiveness: Codable, Hashable, Sendable {
    var state: String
    var lastRescanAt: Date?
    var rescanIntervalSeconds: Int64?
}

/// Body of `POST /api/v1/fleet/plans/{planID}/converge/approve`.
nonisolated struct NornFleetConvergeApproveRequest: Codable, Hashable, Sendable {
    var commitSha: String
    var resume: Bool?
    var sourceAttemptID: String?

    enum CodingKeys: String, CodingKey {
        case commitSha, resume
        case sourceAttemptID = "sourceAttemptId"
    }
}

extension NornCapabilities {
    /// `GET /api/v1/fleet/resources` (the Fleet authority and the etcd runtime).
    var supportsFleetResources: Bool {
        features.contains("fleet-resource-v1") && endpoints["fleetResources"] != nil
    }

    /// Rescan and approve, mounted only with the executor lane.
    var supportsFleetExecutor: Bool {
        features.contains("fleet-executor-v1") &&
        endpoints["fleetResourceConverge"] != nil && endpoints["fleetConvergeApprove"] != nil
    }

    /// Rescan and approve require platform:operate; admin implies every scope.
    var canOperateFleetResources: Bool {
        supportsFleetExecutor && !grantedScopes.isDisjoint(with: ["platform:operate", "admin"])
    }
}
