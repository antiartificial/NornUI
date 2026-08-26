import XCTest
@testable import NornUI

final class ProvisioningStateTests: XCTestCase {
    func testFailedFleetCheckpointBlocksOnlyFollowingPhases() {
        let plan = operation(
            id: "plan-1",
            status: .succeeded,
            payload: [
                "action": .string("replace"),
                "current": .object(["desired": .number(2)]),
                "proposed": .object(["desired": .number(2)])
            ]
        )
        let applied = checkpoint(phase: "infrastructure_applied", status: .succeeded, offset: 1)
        let inventory = checkpoint(phase: "inventory_generated", status: .succeeded, offset: 2)
        let failed = checkpoint(phase: "nodes_configured", status: .failed, offset: 3)

        let progress = NornFleetPlanProgress(plan: plan, reconciliations: [applied, inventory, failed])

        XCTAssertEqual(progress.state, .blocked)
        XCTAssertEqual(progress.checkpoints.map(\.state), [
            .completed, .completed, .failed, .blocked, .blocked, .blocked, .blocked
        ])
    }

    func testActiveExpansionUsesActualOperationStatusAndOmitsDrainPhase() {
        let plan = operation(
            id: "plan-2",
            status: .succeeded,
            payload: [
                "action": .string("scale"),
                "current": .object(["desired": .number(2)]),
                "proposed": .object(["desired": .number(3)])
            ]
        )
        let active = checkpoint(phase: "infrastructure_applied", status: .running, offset: 1)

        let progress = NornFleetPlanProgress(plan: plan, reconciliations: [active])

        XCTAssertEqual(progress.state, .active)
        XCTAssertFalse(progress.checkpoints.contains { $0.phase == "old_nodes_drained" })
        XCTAssertEqual(progress.checkpoints.first?.state, .active)
        XCTAssertEqual(progress.checkpoints.dropFirst().first?.state, .pending)
    }

    func testSuccessfulDispatchReceiptDoesNotMakeMissingPhaseActive() {
        let plan = operation(
            id: "plan-3",
            status: .succeeded,
            payload: [
                "action": .string("scale"),
                "current": .object(["desired": .number(2)]),
                "proposed": .object(["desired": .number(3)])
            ]
        )
        var dispatch = operation(
            id: "dispatch-1",
            status: .succeeded,
            payload: ["planId": .string("plan-3")]
        )
        dispatch.kind = "fleet.github.apply-dispatch"

        // Dispatch is deliberately not reconciliation evidence.
        let progress = NornFleetPlanProgress(plan: plan, reconciliations: [])

        XCTAssertEqual(dispatch.status, .succeeded)
        XCTAssertEqual(progress.state, .pending)
        XCTAssertEqual(progress.checkpoints.first?.state, .pending)
    }

    private func checkpoint(phase: String, status: NornOperationStatus, offset: TimeInterval) -> NornOperation {
        operation(id: "checkpoint-\(phase)", status: status, payload: ["phase": .string(phase)], offset: offset)
    }

    private func operation(
        id: String,
        status: NornOperationStatus,
        payload: [String: JSONValue],
        offset: TimeInterval = 0
    ) -> NornOperation {
        let date = Date(timeIntervalSince1970: 1_786_140_000 + offset)
        return NornOperation(
            id: id,
            kind: id.hasPrefix("plan") ? "fleet.capacity-plan" : "fleet.reconciliation",
            app: nil,
            sagaID: nil,
            ref: nil,
            status: status,
            risk: nil,
            source: "test",
            message: nil,
            attempts: 1,
            maxAttempts: 1,
            lockedBy: nil,
            lockedUntil: nil,
            nextAttemptAt: nil,
            lastError: nil,
            startedAt: date,
            updatedAt: date,
            finishedAt: status.isTerminal ? date : nil,
            payload: payload,
            metadata: nil
        )
    }
}
