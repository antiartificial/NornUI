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
            .pending, .pending, .completed, .completed, .failed, .blocked, .blocked, .blocked, .blocked
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
        XCTAssertEqual(progress.checkpoints.map(\.phase), [
            "infrastructure_applied", "inventory_generated", "nodes_configured",
            "nodes_enrolled", "readiness_verified", "complete"
        ])
        XCTAssertEqual(progress.checkpoints.count, 6)
        XCTAssertEqual(progress.checkpoints.first?.state, .active)
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

    func testLiveRunnerMakesOnlyItsDurablePhaseActive() {
        let plan = operation(id: "plan-4", status: .succeeded, payload: ["action": .string("replace")])
        let attempt = runnerAttempt(status: .running, phase: "nodes_configured")

        let progress = NornFleetPlanProgress(plan: plan, reconciliations: [], runnerAttempt: attempt)

        XCTAssertEqual(progress.state, .active)
        XCTAssertEqual(progress.checkpoints.first { $0.phase == "nodes_configured" }?.state, .active)
        XCTAssertEqual(progress.checkpoints.filter { $0.state == .active }.count, 1)
    }

    func testAbandonedRunnerBlocksLaterPhases() {
        let plan = operation(id: "plan-5", status: .succeeded, payload: ["action": .string("replace")])
        let attempt = runnerAttempt(status: .abandoned, phase: "inventory_generated")

        let progress = NornFleetPlanProgress(plan: plan, reconciliations: [], runnerAttempt: attempt)

        XCTAssertEqual(progress.state, .blocked)
        XCTAssertEqual(progress.checkpoints.first { $0.phase == "inventory_generated" }?.state, .failed)
        XCTAssertEqual(progress.checkpoints.first { $0.phase == "nodes_configured" }?.state, .blocked)
    }

    func testRunningAttemptUsesServerElapsedAndRemainingWithoutRecomputingItsRange() {
        var attempt = runnerAttempt(status: .running, phase: "nodes_configured")
        attempt.timing = timing(elapsedMs: 600_000, remaining: .init(lowMs: 0, highMs: 240_000))
        let now = attempt.startedAt.addingTimeInterval(600)

        let projection = NornFleetTimingProjection(attempt: attempt, now: now)

        XCTAssertEqual(projection.state, .active)
        XCTAssertEqual(projection.phaseLabel, "Nodes Configured")
        XCTAssertEqual(projection.elapsedMs, 600_000)
        XCTAssertEqual(projection.remaining, .init(lowMs: 0, highMs: 240_000))
        XCTAssertEqual(projection.totalRange, .init(lowMs: 480_000, highMs: 840_000))
        XCTAssertNil(projection.completionDurationMs)
    }

    func testQueuedAttemptDoesNotInferElapsedOrRemainingFromPlanOrQueueTime() {
        var attempt = runnerAttempt(status: .queued, phase: "infrastructure_applied")
        attempt.timing = timing(elapsedMs: 0, remaining: .init(lowMs: 480_000, highMs: 840_000))

        let projection = NornFleetTimingProjection(attempt: attempt, now: attempt.startedAt.addingTimeInterval(600))

        XCTAssertEqual(projection.state, .waiting)
        XCTAssertEqual(projection.elapsedMs, 0)
        XCTAssertEqual(projection.remaining, .init(lowMs: 480_000, highMs: 840_000))
    }

    func testFinishedAttemptRetainsActualCompletionDurationAndEstimate() {
        var attempt = runnerAttempt(status: .succeeded, phase: "complete")
        attempt.finishedAt = attempt.startedAt.addingTimeInterval(615)
        attempt.timing = timing(elapsedMs: 615_000, remaining: nil)

        let projection = NornFleetTimingProjection(attempt: attempt)

        XCTAssertEqual(projection.state, .completed)
        XCTAssertEqual(projection.completionDurationMs, 615_000)
        XCTAssertEqual(projection.elapsedMs, 615_000)
        XCTAssertEqual(projection.totalRange, .init(lowMs: 480_000, highMs: 840_000))
        XCTAssertNil(projection.remaining)
    }

    func testFailedAttemptPausesTimingAndDoesNotOfferRemainingEstimate() {
        var attempt = runnerAttempt(status: .failed, phase: "nodes_configured")
        attempt.finishedAt = attempt.startedAt.addingTimeInterval(321)
        attempt.timing = timing(elapsedMs: 321_000, remaining: .init(lowMs: 159_000, highMs: 519_000))

        let projection = NornFleetTimingProjection(attempt: attempt)

        XCTAssertEqual(projection.state, .paused)
        XCTAssertEqual(projection.elapsedMs, 321_000)
        XCTAssertNil(projection.remaining)
        XCTAssertNil(projection.completionDurationMs)
    }

    func testUnavailableServerTimingDoesNotExposeAnInventedRange() {
        var attempt = runnerAttempt(status: .running, phase: "nodes_configured")
        attempt.timing = unavailableTiming(elapsedMs: 90_000)

        let projection = NornFleetTimingProjection(attempt: attempt)

        XCTAssertEqual(projection.availability, .unavailable)
        XCTAssertEqual(projection.elapsedMs, 90_000)
        XCTAssertNil(projection.totalRange)
        XCTAssertNil(projection.remaining)
        XCTAssertNil(projection.estimatedCompletion)
    }

    func testCheckpointProgressReportsOnlyProvenCheckpoints() {
        let plan = operation(id: "plan-6", status: .succeeded, payload: ["action": .string("scale")])
        let progress = NornFleetPlanProgress(
            plan: plan,
            reconciliations: [
                checkpoint(phase: "infrastructure_applied", status: .succeeded, offset: 1),
                checkpoint(phase: "inventory_generated", status: .running, offset: 2),
            ]
        )

        XCTAssertEqual(progress.provenCheckpointCount, 1)
        XCTAssertEqual(progress.checkpointProgressAccessibilityValue, "1 of 6 provisioning checkpoints proven")
    }

    func testTimingProvenanceHumanizesExcludedWork() {
        let provenance = NornFleetTimingProvenance(
            method: .configuredRange,
            configuredRange: .init(lowMs: 900_000, highMs: 1_800_000),
            sampleCount: 0,
            successfulSampleCount: 0,
            exclusions: ["review_approval", "github_queue", "dns_propagation", "application_migrations"]
        )

        XCTAssertEqual(
            provenance.excludedWorkSummary,
            "Excludes review/approval, GitHub queue, DNS propagation, and application migrations."
        )
    }

    private func checkpoint(phase: String, status: NornOperationStatus, offset: TimeInterval) -> NornOperation {
        operation(id: "checkpoint-\(phase)", status: status, payload: ["phase": .string(phase)], offset: offset)
    }

    private func runnerAttempt(status: NornFleetRunnerAttemptStatus, phase: String) -> NornFleetRunnerAttempt {
        let date = Date(timeIntervalSince1970: 1_786_140_000)
        return .init(
            schemaVersion: "norn.fleet-runner-attempt/v1", id: "attempt-1", planID: "plan-1", attempt: 1,
            runnerAttemptID: "runner-1", status: status, currentPhase: phase,
            commitSHA: String(repeating: "a", count: 40), planSHA256: String(repeating: "b", count: 64),
            workflowURL: URL(string: "https://github.com/acme/fleet/actions/runs/1"), retryOf: nil,
            heartbeatSequence: 1, heartbeatTimeoutSeconds: 120, revision: 2,
            startedAt: date, heartbeatAt: date, heartbeatExpiresAt: date.addingTimeInterval(120),
            updatedAt: date, finishedAt: status.isActive ? nil : date, lastError: status == .abandoned ? "runner heartbeat expired" : nil
        )
    }

    private func timing(elapsedMs: Int64, remaining: NornFleetTimingRange?) -> NornFleetRunnerTiming {
        .init(
            schemaVersion: "norn.fleet-timing/v1",
            scope: "runner_attempt",
            asOf: Date(timeIntervalSince1970: 1_786_140_600),
            availability: .available,
            operationClass: .coldStart,
            elapsedMs: elapsedMs,
            estimatedRemaining: remaining,
            estimatedTotal: .init(lowMs: 480_000, highMs: 840_000),
            estimatedCompletion: .init(
                earliestAt: Date(timeIntervalSince1970: 1_786_140_480),
                latestAt: Date(timeIntervalSince1970: 1_786_140_840)
            ),
            confidence: .low,
            provenance: .init(
                method: .configuredRange,
                configuredRange: .init(lowMs: 480_000, highMs: 840_000),
                sampleCount: 4,
                successfulSampleCount: 3,
                exclusions: ["review_approval"]
            ),
            phases: [
                .init(name: "nodes_configured", state: .active, elapsedMs: elapsedMs, estimatedRemaining: nil),
            ]
        )
    }

    private func unavailableTiming(elapsedMs: Int64) -> NornFleetRunnerTiming {
        .init(
            schemaVersion: "norn.fleet-timing/v1",
            scope: "runner_attempt",
            asOf: Date(timeIntervalSince1970: 1_786_140_600),
            availability: .unavailable,
            operationClass: .unknown,
            elapsedMs: elapsedMs,
            estimatedRemaining: nil,
            estimatedTotal: nil,
            estimatedCompletion: nil,
            confidence: .none,
            provenance: .init(method: .unavailable, configuredRange: nil, sampleCount: 0, successfulSampleCount: 0, exclusions: []),
            phases: []
        )
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
