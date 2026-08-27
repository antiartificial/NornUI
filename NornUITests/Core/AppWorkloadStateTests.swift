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
        status: String
    ) -> NornService {
        NornService(
            name: "sample-\(process)",
            app: "sample",
            process: process,
            type: type,
            status: status,
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
