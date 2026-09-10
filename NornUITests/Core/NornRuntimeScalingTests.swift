import XCTest
@testable import NornUI

final class NornRuntimeScalingTests: XCTestCase {
    private func app(_ processes: [String: NornAppSpecSummary.Process]) -> NornAppStatus {
        .init(spec: .init(name: "example", deploy: true, processes: processes), nomadStatus: "running", healthy: true)
    }

    func testConfiguredResumeTargetsAreSortedAndDoNotUseObservedAllocations() {
        var value = app([
            "worker": .init(scaling: nil),
            "web": .init(scaling: .init(min: 2, perRegion: 3))
        ])
        value.allocationSummary = .init(running: 0, active: 0, retained: 9, total: 9, byProcess: nil)
        XCTAssertEqual(NornRuntimeScaling.targets(for: value), [.init(process: "web", count: 3), .init(process: "worker", count: 1)])
        XCTAssertNil(NornRuntimeScaling.unavailableReason(for: value), "Zero observed allocations do not prove suspension or remove scale controls")
    }

    func testSingletonAndFixedHostPortCannotScaleAboveOne() {
        let value = app([
            "worker": .init(scaling: .init(min: 4), singleton: true),
            "web": .init(scaling: nil, hostPort: 8080)
        ])
        for process in ["worker", "web"] {
            XCTAssertEqual(NornRuntimeScaling.maxCount(for: value, process: process), 1)
            XCTAssertFalse(NornRuntimeScaling.isValid([.init(process: process, count: 2)], for: value))
            XCTAssertTrue(NornRuntimeScaling.isValid([.init(process: process, count: 0)], for: value))
        }
    }

    func testScaleTargetsRejectUnknownDuplicateNegativeAndOverMaximum() {
        let value = app(["web": .init(scaling: .init(min: 1, max: 4))])
        let invalidTargets: [[NornRuntimeScaleTarget]] = [[], [.init(process: "missing", count: 1)], [.init(process: "web", count: -1)], [.init(process: "web", count: 5)], [.init(process: "web", count: 1), .init(process: "web", count: 2)]]
        for targets in invalidTargets {
            XCTAssertFalse(NornRuntimeScaling.isValid(targets, for: value))
        }
        XCTAssertTrue(NornRuntimeScaling.isValid([.init(process: "web", count: 4)], for: value))
    }

    func testRegionalAndScheduledProcessesRequireTheirOwnControls() {
        let scheduled = app(["cron": .init(schedule: "0 * * * *", scaling: nil)])
        let function = app(["task": .init(function: .object([:]), scaling: nil)])
        let regionalProcess = app(["web": .init(scaling: nil, regions: ["east"])])
        var regionalApp = app(["web": .init(scaling: nil)])
        regionalApp.spec.regions = .array([.string("east")])
        for value in [scheduled, function, regionalProcess, regionalApp] {
            XCTAssertNotNil(NornRuntimeScaling.unavailableReason(for: value))
            XCTAssertTrue(NornRuntimeScaling.eligibleProcesses(for: value).isEmpty)
            XCTAssertFalse(NornRuntimeScaling.isValid([.init(process: "web", count: 0)], for: value))
        }
    }

    func testDisabledDeploymentDoesNotPreventScalingButUnreportedJobsDo() {
        var disabled = app(["web": .init(scaling: nil)])
        disabled.spec.deploy = false
        var absent = app(["web": .init(scaling: nil)])
        absent.nomadStatus = nil
        XCTAssertNil(NornRuntimeScaling.unavailableReason(for: disabled))
        XCTAssertTrue(NornRuntimeScaling.isValid([.init(process: "web", count: 0)], for: disabled))
        for value in [absent, app([:])] {
            XCTAssertNotNil(NornRuntimeScaling.unavailableReason(for: value))
            XCTAssertTrue(NornRuntimeScaling.targets(for: value).isEmpty)
        }
    }
}
