import XCTest
@testable import NornUI

final class DeploymentStepTimingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    private func step(status: NornDeploymentStepStatus = .complete, end: Date? = nil, duration: Int64? = nil) -> NornDeploymentStep {
        NornDeploymentStep(
            deploymentID: "deployment", app: "app", sagaID: "saga", step: "build",
            status: status, startedAt: start, finishedAt: end, durationMs: duration
        )
    }

    func testReportedDurationTakesPrecedenceOverTimestamps() {
        let value = step(end: start.addingTimeInterval(9), duration: 1_250)
        XCTAssertEqual(DeploymentStepTiming.seconds(value, now: start, runsClock: false), 1.25)
    }

    func testFinishedTimeProvidesFallbackForMissingDuration() {
        let value = step(end: start.addingTimeInterval(0.002))
        XCTAssertEqual(DeploymentStepTiming.seconds(value, now: start, runsClock: false)!, 0.002, accuracy: 0.0001)
        XCTAssertEqual(DeploymentStepTiming.description(value, now: start, runsClock: false), "<1s")
    }

    func testOnlyConfirmedLiveRunningStepsAccumulateTime() {
        let running = step(status: .running)
        XCTAssertEqual(DeploymentStepTiming.seconds(running, now: start.addingTimeInterval(10), runsClock: true), 10)
        XCTAssertNil(DeploymentStepTiming.seconds(running, now: start.addingTimeInterval(10), runsClock: false))
        XCTAssertNil(DeploymentStepTiming.seconds(step(), now: start.addingTimeInterval(10), runsClock: true))
    }

    func testNegativeClockSkewDoesNotProduceNegativeDuration() {
        XCTAssertEqual(DeploymentStepTiming.seconds(step(status: .running), now: start.addingTimeInterval(-5), runsClock: true), 0)
    }
}
