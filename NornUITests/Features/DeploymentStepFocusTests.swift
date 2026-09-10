import XCTest
@testable import NornUI

final class DeploymentStepFocusTests: XCTestCase {
    private func step(_ name: String, _ status: NornDeploymentStepStatus) -> NornDeploymentStep {
        NornDeploymentStep(
            deploymentID: "deployment", app: "app", sagaID: "saga", step: name,
            status: status, startedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    func testRunningStepTakesPrecedenceOverRetainedFailure() {
        let running = step("retry", .running)
        XCTAssertEqual(DeploymentStepFocus.attentionID(in: [running, step("old_failure", .failed)]), running.id)
    }

    func testAppendedRunningStepBecomesFocus() {
        let previous = step("build", .complete)
        let next = step("deploy", .running)
        XCTAssertEqual(DeploymentStepFocus.attentionID(in: [previous, next]), next.id)
    }

    func testCompletionFollowsFinalStepInsteadOfOldFailure() {
        let complete = step("health_check", .complete)
        XCTAssertEqual(DeploymentStepFocus.attentionID(in: [step("old_failure", .failed), complete]), complete.id)
    }

    func testEmptyJourneyHasNoFocus() {
        XCTAssertNil(DeploymentStepFocus.attentionID(in: []))
    }
}
