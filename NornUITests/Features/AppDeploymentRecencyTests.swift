import XCTest
@testable import NornUI

final class AppDeploymentRecencyTests: XCTestCase {
    func testNewestDeploymentComesBeforeAlphabeticalAppOrder() {
        let index = AppDeploymentRecency(deployments: [deployment("alpha", started: 100), deployment("offer-intake", started: 200)])
        XCTAssertEqual(["alpha", "offer-intake", "unknown"].sorted { index.precedes($0, $1) }, ["offer-intake", "alpha", "unknown"])
    }

    func testCompletionTimeDeterminesMostRecentDeploy() {
        let index = AppDeploymentRecency(deployments: [deployment("alpha", started: 100, finished: 300), deployment("offer-intake", started: 200, finished: 250)])
        XCTAssertTrue(index.precedes("alpha", "offer-intake"))
    }

    func testUnknownDatesRemainLastWhenReversedAndTiesAreStable() {
        let index = AppDeploymentRecency(deployments: [deployment("beta", started: 200), deployment("alpha", started: 200)])
        XCTAssertEqual(["unknown", "beta", "alpha"].sorted { index.precedes($0, $1, ascending: true) }, ["alpha", "beta", "unknown"])
    }

    func testLatestReceiptPerAppWinsRegardlessOfInputOrder() {
        let recent = deployment("offer-intake", started: 200)
        let index = AppDeploymentRecency(deployments: [recent, deployment("offer-intake", started: 100)])
        XCTAssertEqual(index.latestByApp["offer-intake"], recent)
    }

    func testQueuedOperationWithoutDeploymentSortsByItsStartTime() {
        let operation = NornOperation(id: "new", kind: "deploy", app: "offer-intake", status: .queued,
                                      startedAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300))
        let index = AppDeploymentRecency(deployments: [deployment("alpha", started: 200)], operations: [operation])
        XCTAssertTrue(index.precedes("offer-intake", "alpha"))
        XCTAssertNil(index.latestByApp["offer-intake"], "A queued operation must not fabricate a deployment receipt")
    }

    private func deployment(_ app: String, started: TimeInterval, finished: TimeInterval? = nil) -> NornDeployment {
        NornDeployment(id: "\(app)-\(started)", app: app, commitSHA: "abc", imageTag: "image", sagaID: "saga", status: .deployed, startedAt: Date(timeIntervalSince1970: started), finishedAt: finished.map { Date(timeIntervalSince1970: $0) })
    }
}
