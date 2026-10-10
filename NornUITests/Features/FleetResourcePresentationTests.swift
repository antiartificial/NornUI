import Foundation
import XCTest
@testable import NornUI

final class FleetResourcePresentationTests: XCTestCase {
    func testBlockerMessageIsShownAndFallsBackToHumanizedReason() throws {
        let withMessage = try resource(blocker: #"{"kind":"approval","reason":"approval_required","message":"Approve the converge plan first."}"#)
        XCTAssertEqual(FleetResourcePresentation(withMessage).blocker, "Approve the converge plan first.")

        let reasonOnly = try resource(blocker: #"{"kind":"trigger","reason":"trigger_pending"}"#)
        XCTAssertEqual(FleetResourcePresentation(reasonOnly).blocker, "Trigger pending")

        XCTAssertNil(FleetResourcePresentation(try resource()).blocker)
    }

    func testApproveConvergeNextActionOffersApproveWithPlanAndCommit() throws {
        let value = try resource(nextAction: "approve_converge", executionMode: "controller")
        let model = FleetResourcePresentation(value)
        XCTAssertEqual(model.nextActionTitle, "Approve converge")
        XCTAssertEqual(model.approval, .approve(planID: "plan-1", commitSha: String(repeating: "a", count: 40)))
        XCTAssertTrue(model.canRescan)
    }

    func testResumeUsesStructuredAttemptAndCommit() throws {
        let commit = String(repeating: "e", count: 40)
        let active = #"{"planId":"plan-1","attemptIds":["att-1","att-2"],"fenceGeneration":3,"occupancy":"Uncertain","occupancyReason":"NoLiveAttempt","resumeNeededAttemptId":"att-1","commitSha":"\#(commit)"}"#
        let model = FleetResourcePresentation(try resource(nextAction: "approve_converge", executionMode: "controller", active: active))
        XCTAssertEqual(model.approval, .resume(planID: "plan-1", commitSha: commit, sourceAttemptID: "att-1"))
        XCTAssertEqual(model.nextActionTitle, "Approve resume")
        XCTAssertEqual(model.cliHints.first, "norn fleet converge staging --resume")
        XCTAssertTrue(model.running.contains("attempt 2"))
    }

    func testUncertainHolderWithoutServerApproveOffersNothing() throws {
        // The UI never re-derives a resume: resumeApproved, a live recovery or
        // a missing stop proof all leave nextAction off approve_converge.
        let active = #"{"planId":"plan-1","attemptIds":["att-1","att-2"],"fenceGeneration":3,"occupancy":"Uncertain"}"#
        XCTAssertNil(FleetResourcePresentation(try resource(nextAction: "resolve_uncertain_outcome", executionMode: "controller", active: active)).approval)
        let approved = #"{"planId":"plan-1","attemptIds":["att-1","att-2"],"fenceGeneration":3,"occupancy":"Uncertain","resumeApproved":true}"#
        XCTAssertNil(FleetResourcePresentation(try resource(nextAction: "resolve_uncertain_outcome", executionMode: "controller", active: approved)).approval)
    }

    func testResumeWithoutStructuredFieldsShowsHintOnly() throws {
        let sha = String(repeating: "e", count: 40)
        let noAttempt = #"{"planId":"plan-1","attemptIds":["att-2"],"fenceGeneration":3,"occupancy":"Uncertain","commitSha":"\#(sha)"}"#
        let noCommit = #"{"planId":"plan-1","attemptIds":["att-2"],"fenceGeneration":3,"occupancy":"Uncertain","resumeNeededAttemptId":"att-2"}"#
        for active in [noAttempt, noCommit] {
            let model = FleetResourcePresentation(try resource(nextAction: "approve_converge", executionMode: "controller", active: active))
            XCTAssertNil(model.approval)
            XCTAssertEqual(model.cliHints.first, "norn fleet converge staging --resume")
        }
    }

    func testApproveKeyChangesWithEachStoppedAttempt() {
        let sha = String(repeating: "a", count: 40)
        let first = FleetResourcePresentation.Approval.resume(planID: "plan-1", commitSha: sha, sourceAttemptID: "att-2")
        let retry = FleetResourcePresentation.Approval.resume(planID: "plan-1", commitSha: sha, sourceAttemptID: "att-2")
        let next = FleetResourcePresentation.Approval.resume(planID: "plan-1", commitSha: sha, sourceAttemptID: "att-3")
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, next.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, FleetResourcePresentation.Approval.approve(planID: "plan-1", commitSha: sha).idempotencyKey)
        XCTAssertLessThanOrEqual(next.idempotencyKey.count, 200)
    }

    func testResourceActionsNeedExecutorCapabilityAndPlatformOperate() {
        var capabilities = NornFixtures.snapshot.capabilities
        capabilities.features = ["fleet-resource-v1", "fleet-executor-v1"]
        capabilities.endpoints = ["fleetResources": "/api/v1/fleet/resources", "fleetResourceConverge": "/x", "fleetConvergeApprove": "/y"]
        capabilities.auth.principal?.scopes = ["api:read", "api:write"]
        XCTAssertTrue(capabilities.supportsFleetResources)
        XCTAssertFalse(capabilities.canOperateFleetResources, "api:write is not platform:operate")
        capabilities.auth.principal?.scopes = ["api:read", "platform:operate"]
        XCTAssertTrue(capabilities.canOperateFleetResources)
        capabilities.auth.principal?.scopes = ["admin"]
        XCTAssertTrue(capabilities.canOperateFleetResources)
        capabilities.features = ["fleet-resource-v1"]
        XCTAssertFalse(capabilities.canOperateFleetResources, "no executor lane mounted")
    }

    func testRescanOnlyInControllerMode() throws {
        XCTAssertFalse(FleetResourcePresentation(try resource()).canRescan)
        XCTAssertTrue(FleetResourcePresentation(try resource(executionMode: "controller")).canRescan)
    }

    func testUnknownAndStaleConditionsAreMarked() throws {
        let value = try resource(conditions: """
        [{"type":"ProviderStateKnown","status":"Unknown","reason":"ObservationStale","evidenceRefs":[]},
         {"type":"RuntimeReady","status":"True","reason":"ObservedReady","evidenceRefs":[]},
         {"type":"DriftDetected","status":"True","reason":"ObservedDrift","evidenceRefs":[]},
         {"type":"NodesEnrolled","status":"Unknown","reason":"NoObservation","evidenceRefs":[]}]
        """)
        let rows = FleetResourcePresentation(value).conditions
        XCTAssertEqual(rows[0].status, "Unknown (stale)")
        XCTAssertTrue(rows[0].isStale)
        XCTAssertEqual(rows[0].tone, .unknown)
        XCTAssertEqual(rows[1].tone, .good)
        XCTAssertEqual(rows[2].tone, .bad, "Drift being True is bad")
        XCTAssertEqual(rows[3].status, "Unknown")
        XCTAssertFalse(rows[3].isStale)
    }

    func testNilAndUnknownNextActionDoNotClaimDone() throws {
        XCTAssertEqual(FleetResourcePresentation(try resource(nextAction: nil)).nextActionTitle, "Not evaluated")
        XCTAssertEqual(FleetResourcePresentation(try resource(nextAction: "none")).nextActionTitle, "Nothing pending")
        XCTAssertEqual(FleetResourcePresentation(try resource(nextAction: "future_thing")).nextActionTitle, "Future thing")
    }

    func testLivenessAndPolicyAreStatedPlainly() throws {
        let unknown = FleetResourcePresentation(try resource(controllerState: "unknown"))
        XCTAssertFalse(unknown.livenessIsHealthy)
        XCTAssertTrue(unknown.liveness.contains("no reconciler"))
        XCTAssertTrue(FleetResourcePresentation(try resource(controllerState: "running")).livenessIsHealthy)
        XCTAssertTrue(unknown.policy.contains("Environment reviewers and independent review are not enforced."))
        XCTAssertTrue(unknown.policy.contains("merged pull request"))
    }

    func testCLIHintsNameExactCommands() throws {
        let hints = FleetResourcePresentation(try resource()).cliHints
        XCTAssertEqual(hints.first, "norn fleet mode staging controller|github")
        XCTAssertTrue(hints.contains("norn fleet release tgt_\(String(repeating: "0", count: 64)) --mode terminal|abandon [--provider-evidence <file>]"))
        XCTAssertTrue(hints.contains("norn fleet abandon plan-1 [--provider-evidence <file>]"))
        XCTAssertTrue(hints.contains("norn fleet provider-evidence plan-1 --source-attempt <attempt-id> --provider-evidence <file>"))
        XCTAssertEqual(FleetResourcePresentation(try resource(nextAction: "approve_converge")).cliHints.first, "norn fleet approve plan-1")
    }

    // MARK: - Fixtures

    private func resource(
        nextAction: String? = "none",
        executionMode: String? = nil,
        blocker: String? = nil,
        active: String? = nil,
        refused: Bool = false,
        controllerState: String = "running",
        conditions: String = "[]"
    ) throws -> NornFleetResource {
        try FleetResourceFixture.decode(
            nextAction: nextAction, executionMode: executionMode, blocker: blocker, active: active,
            refused: refused, controllerState: controllerState, conditions: conditions
        )
    }
}

enum FleetResourceFixture {
    static func json(
        nextAction: String? = "approve_converge",
        executionMode: String? = "controller",
        blocker: String? = nil,
        active: String? = nil,
        refused: Bool = false,
        controllerState: String = "running",
        conditions: String = "[]"
    ) -> String {
        let sha = String(repeating: "a", count: 40)
        return """
        {"name":"staging","targetId":"tgt_\(String(repeating: "0", count: 64))","revision":4,"authorityEpoch":1,"observationSequence":9,
         "createdAt":"2026-10-04T10:00:00Z","updatedAt":"2026-10-05T10:00:00.250Z",
         "desired":{"generation":2,"planId":"plan-1","commitSha":"\(sha)","verification":"github-protected-main","acceptedAt":"2026-10-05T09:00:00Z","acceptedBy":"op",
           "converge":{"planSha256":"\(String(repeating: "b", count: 64))","requiresApproval":true,"approved":false\(refused ? ",\"refused\":true" : "")}},
         "desiredHistory":[],
         "status":{"observedGeneration":2,"lastAppliedGeneration":1,
           "lastApplied":{"generation":1,"commitSha":"\(String(repeating: "c", count: 40))","planId":"plan-0"},
           \(active.map { "\"active\":\($0)," } ?? "")
           "conditions":\(conditions)\(nextAction.map { ",\"nextAction\":\"\($0)\"" } ?? "")},
         \(blocker.map { "\"blocker\":\($0)," } ?? "")
         "observed":{"provider":{"observedAt":"2026-10-05T09:59:00Z","sequence":9}},
         "approvalPolicy":{"basis":"github-protected-main","protectedBranch":true,"mergedPullRequest":true,"planWorkflowSucceeded":false,"boundPlanDigest":true,"authorizedDispatch":true,"ownerApprovalEnvelope":false,"environmentReviewers":"not_enforced","independentReview":"not_enforced"},
         \(executionMode.map { "\"executionMode\":\"\($0)\"," } ?? "")
         "controller":{"state":"\(controllerState)","lastRescanAt":"2026-10-05T10:00:00Z","rescanIntervalSeconds":60},
         "readAt":"2026-10-05T10:00:01Z"}
        """
    }

    static func decode(
        nextAction: String? = "approve_converge", executionMode: String? = "controller", blocker: String? = nil,
        active: String? = nil, refused: Bool = false, controllerState: String = "running", conditions: String = "[]"
    ) throws -> NornFleetResource {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .nornISO8601
        let text = json(nextAction: nextAction, executionMode: executionMode, blocker: blocker, active: active,
                        refused: refused, controllerState: controllerState, conditions: conditions)
        return try decoder.decode(NornFleetResource.self, from: Data(text.utf8))
    }
}
