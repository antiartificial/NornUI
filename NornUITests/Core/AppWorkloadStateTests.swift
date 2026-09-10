import XCTest
@testable import NornUI

@MainActor
final class AppWorkloadStateTests: XCTestCase {
    func testIdleCronIsScheduledInsteadOfUnknown() {
        let service = makeService(type: "cron", status: "unknown")

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: nil), .scheduled)
    }

    func testScheduledOnlyAppIsNotMistakenForScaledToZero() {
        let service = makeService(process: "daily", type: "cron", status: "unknown")
        let app = NornAppStatus(
            spec: .init(
                name: "sample",
                deploy: true,
                processes: [
                    "daily": .init(schedule: "17 3 * * *", function: nil, scaling: nil)
                ]
            ),
            nomadStatus: "running",
            healthy: false,
            allocationSummary: .init(
                running: 0,
                active: 0,
                retained: 0,
                total: 0,
                byProcess: [:]
            )
        )

        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [service]), .scheduled)
    }

    func testIdleFunctionIsOnDemandInsteadOfUnknown() {
        let service = makeService(type: "function", status: "unknown")

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: nil), .onDemand)
    }

    func testFailedScheduledJobRemainsCritical() {
        let service = makeService(type: "cron", status: "failed")

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: nil), .critical)
    }

    func testExpectedIdleScheduleDoesNotPromoteAnAbsentRegistrationToCritical() {
        let service = makeService(type: "cron", status: "critical", expectedState: "scheduled")

        XCTAssertTrue(service.isExpectedIdle)
        XCTAssertFalse(service.needsAttention)
        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: nil), .scheduled)
    }

    func testActiveCriticalScheduledRegistrationNeedsAttention() {
        var service = makeService(type: "cron", status: "critical", expectedState: "scheduled")
        service.instances = [.init(id: "instance-1", status: "critical")]

        XCTAssertFalse(service.isExpectedIdle)
        XCTAssertTrue(service.needsAttention)
        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: nil), .critical)
    }

    func testActiveAllocationKeepsCriticalScheduledServiceCriticalWithoutRegistration() {
        let service = makeService(type: "cron", status: "critical", expectedState: "scheduled")
        let app = makeApp(
            deploy: true,
            nomadStatus: "running",
            healthy: false,
            allocationSummary: .init(
                running: 1,
                active: 1,
                retained: 0,
                total: 1,
                byProcess: ["web": .init(running: 1, active: 1, retained: 0, total: 1)]
            )
        )

        XCTAssertTrue(service.isExpectedIdle)
        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: app), .critical)
    }

    func testActiveCriticalOnDemandRegistrationNeedsAttention() {
        var service = makeService(type: "function", status: "critical", expectedState: "on_demand")
        service.instances = [.init(id: "instance-1", status: "critical")]

        XCTAssertFalse(service.isExpectedIdle)
        XCTAssertTrue(service.needsAttention)
        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: nil), .critical)
    }
    func testDisabledResidentServiceIsNeutral() {
        let service = makeService(type: "service", status: "unknown")
        let app = makeApp(deploy: false, nomadStatus: "", healthy: false)

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: app), .disabled)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [service]), .disabled)
    }

    func testRunningSchedulerWithZeroProcessAllocationsIsScaledToZero() {
        let service = makeService(type: "service", status: "unknown")
        let app = makeApp(
            deploy: true,
            nomadStatus: "running",
            healthy: false,
            allocationSummary: .init(
                running: 0,
                active: 0,
                retained: 0,
                total: 0,
                byProcess: [:]
            )
        )

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: app), .scaledToZero)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [service]), .scaledToZero)
    }

    func testScaledToZeroIgnoresAStaleCriticalRegistration() {
        let service = makeService(type: "service", status: "critical")
        let app = makeApp(
            deploy: true,
            nomadStatus: "running",
            healthy: false,
            allocationSummary: .init(
                running: 0,
                active: 0,
                retained: 1,
                total: 1,
                byProcess: [:]
            )
        )

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: app), .scaledToZero)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [service]), .scaledToZero)
    }

    func testMissingRequiredResidentServiceRemainsCritical() {
        let service = makeService(type: "service", status: "unknown")
        let app = makeApp(deploy: true, nomadStatus: "", healthy: false)

        XCTAssertEqual(AppWorkloadState.resolve(service: service, app: app), .unknown)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [service]), .critical)
    }

    func testHealthyResidentServiceKeepsMixedScheduledAppHealthy() {
        let web = makeService(process: "web", type: "service", status: "passing")
        let cron = makeService(process: "daily-capture", type: "cron", status: "unknown")
        let app = makeApp(deploy: true, nomadStatus: "running", healthy: true)

        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [web, cron]), .healthy)
    }

    func testRegisteredWebAndRunningUnregisteredWorkerKeepAppHealthy() {
        let web = makeService(process: "web", type: "service", status: "passing")
        let worker = makeService(process: "worker", type: "worker", status: "unknown")
        let app = workerApp(running: 1, active: 1)

        XCTAssertEqual(AppWorkloadState.resolve(service: worker, app: app), .active)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [web, worker]), .healthy)
    }

    func testWorkerFailureIsNotHiddenByRunningAllocation() {
        let worker = makeService(process: "worker", type: "worker", status: "critical")
        let app = workerApp(running: 1, active: 1)

        XCTAssertEqual(AppWorkloadState.resolve(service: worker, app: app), .critical)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [worker]), .critical)
    }

    func testPendingWorkerDoesNotClaimToBeRunning() {
        let worker = makeService(process: "worker", type: "worker", status: "unknown")
        XCTAssertEqual(AppWorkloadState.resolve(service: worker, app: workerApp(running: 0, active: 1)), .unknown)
    }

    func testMissingWorkerCountsDoNotMeanScaledToZeroOrOnDemand() {
        let worker = makeService(process: "worker", type: "worker", status: "unknown")
        let app = makeApp(
            deploy: true, nomadStatus: "running", healthy: true,
            allocationSummary: .init(running: 1, active: 1, retained: 0, total: 1,
                                     byProcess: ["web": .init(running: 1, active: 1, retained: 0, total: 1)])
        )
        XCTAssertEqual(AppWorkloadState.resolve(service: worker, app: app), .unknown)
    }

    func testZeroScalingMinimumDoesNotHideRunningWorker() {
        let worker = makeService(process: "worker", type: "worker", status: "unknown")
        var app = workerApp(running: 1, active: 1)
        app.spec.processes = ["worker": .init(schedule: nil, function: nil, scaling: .init(min: 0))]

        XCTAssertEqual(AppWorkloadState.resolve(service: worker, app: app), .active)
        XCTAssertEqual(AppWorkloadState.aggregate(app: app, services: [worker]), .active)
    }

    func testWebServiceStillNeedsHealthEvidenceDespiteRunningAllocation() {
        let web = makeService(process: "worker", type: "service", status: "unknown")
        XCTAssertEqual(AppWorkloadState.resolve(service: web, app: workerApp(running: 1, active: 1)), .unknown)
    }

    private func workerApp(running: Int, active: Int) -> NornAppStatus {
        makeApp(
            deploy: true, nomadStatus: "running", healthy: true,
            allocationSummary: .init(
                running: running + 1, active: active + 1, retained: 0, total: active + 1,
                byProcess: [
                    "web": .init(running: 1, active: 1, retained: 0, total: 1),
                    "worker": .init(running: running, active: active, retained: 0, total: active)
                ]
            )
        )
    }

    private func makeApp(
        deploy: Bool,
        nomadStatus: String,
        healthy: Bool,
        allocationSummary: NornAppStatus.AllocationSummary? = nil
    ) -> NornAppStatus {
        NornAppStatus(
            spec: .init(
                name: "sample",
                deploy: deploy,
                processes: [
                    "web": .init(schedule: nil, function: nil, scaling: .init(min: 1))
                ]
            ),
            nomadStatus: nomadStatus,
            healthy: healthy,
            allocationSummary: allocationSummary
        )
    }

    private func makeService(
        process: String = "web",
        type: String,
        status: String,
        expectedState: String? = nil
    ) -> NornService {
        NornService(
            name: "sample-\(process)",
            app: "sample",
            process: process,
            type: type,
            status: status,
            expectedState: expectedState,
            healthPath: nil,
            reachability: .init(
                endpointScope: "none",
                instanceScope: "none",
                exposure: "internal",
                routable: false
            ),
            endpoints: nil,
            instances: []
        )
    }
}
