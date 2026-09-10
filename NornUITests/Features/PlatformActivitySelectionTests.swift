import XCTest
@testable import NornUI

final class PlatformActivitySelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func operation(_ id: String, status: NornOperationStatus = .running, age: TimeInterval = 0, saga: String? = nil) -> NornOperation {
        NornOperation(id: id, kind: "deploy", app: "app", sagaID: saga, status: status,
                      startedAt: now.addingTimeInterval(-age), updatedAt: now.addingTimeInterval(-age))
    }

    func testActiveSelectionExcludesTerminalAndOrdersNewestFirst() {
        let result = PlatformActivitySelection.active([
            operation("old", age: 20), operation("done", status: .succeeded), operation("new", status: .queued)
        ])
        XCTAssertEqual(result.map(\.id), ["new", "old"])
    }

    func testReceiptsAreRecentDistinctTerminalAndBounded() {
        let result = PlatformActivitySelection.receipts([
            operation("running"), operation("stale", status: .failed, age: 601),
            operation("new", status: .succeeded, age: 1), operation("new", status: .succeeded, age: 2),
            operation("second", status: .canceled, age: 3), operation("third", status: .failed, age: 4),
            operation("still-active", status: .succeeded)
        ], excluding: ["still-active"], now: now)
        XCTAssertEqual(result.map(\.id), ["new", "second"])
    }

    func testGraphsRequireExactNonemptySagaMatch() {
        let deployment = NornDeployment(id: "deployment", app: "app", commitSHA: "sha", imageTag: "image",
                                        sagaID: "exact", status: .building, startedAt: now)
        XCTAssertNil(PlatformActivitySelection.deployment(for: operation("missing"), in: [deployment]))
        XCTAssertNil(PlatformActivitySelection.deployment(for: operation("wrong", saga: "other"), in: [deployment]))
        XCTAssertEqual(PlatformActivitySelection.deployment(for: operation("match", saga: "exact"), in: [deployment])?.id, deployment.id)
        var emptySaga = deployment
        emptySaga.sagaID = ""
        XCTAssertNil(PlatformActivitySelection.deployment(for: operation("empty", saga: ""), in: [emptySaga]))
    }
}
