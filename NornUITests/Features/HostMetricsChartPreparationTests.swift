import XCTest
@testable import NornUI

final class HostMetricsChartPreparationTests: XCTestCase {
    func testViewportPreparationKeepsEndpointAndBoundsRenderedMarks() {
        let latest = NornFixtures.hostMetrics
        let end = latest.observedAt
        var samples: [NornHostMetricSample] = []
        samples.reserveCapacity(10_000)
        for index in 0..<10_000 {
            samples.append(NornHostMetricSample(
                observedAt: end.addingTimeInterval(Double(index - 9_999)),
                cpuPercent: Double(index % 101),
                memoryUsedBytes: UInt64(40 + index % 50),
                memoryTotalBytes: 100
            ))
        }
        var services: [NornServiceMetricSample] = []
        services.reserveCapacity(12_000)
        for index in 0..<12_000 {
            services.append(NornServiceMetricSample(
                observedAt: end.addingTimeInterval(Double(index - 11_999)),
                app: "app\(index % 8)",
                process: "web",
                cpuPercent: Double(index % 130),
                memoryPercent: Double(index % 110)
            ))
        }

        let prepared = HostMetricsChartPreparation.prepare(
            samples: samples,
            serviceSamples: services,
            latest: latest,
            window: .hours6,
            requestedViewportStart: end.addingTimeInterval(-Double(NornHostMetricsWindow.hours6.rawValue)),
            includesServiceMetrics: true
        )

        XCTAssertLessThanOrEqual(prepared.hostSamples.count, 240)
        XCTAssertTrue(prepared.hostSamples.contains(where: { $0.observedAt == end }))
        XCTAssertLessThanOrEqual(prepared.tenantSeries.count, 6)
        XCTAssertTrue(prepared.tenantSeries.allSatisfy { $0.samples.count <= 80 })
    }

    func testRecentPageStillAllowsBrowsingIntoRetainedHistory() {
        let latest = NornFixtures.hostMetrics
        let prepared = HostMetricsChartPreparation.prepare(
            samples: [NornHostMetricSample(metrics: latest)],
            serviceSamples: [],
            latest: latest,
            window: .hour1,
            requestedViewportStart: latest.observedAt.addingTimeInterval(-Double(NornHostMetricsWindow.days30.rawValue)),
            includesServiceMetrics: false
        )

        XCTAssertEqual(prepared.earliestDate, latest.observedAt.addingTimeInterval(-Double(NornHostMetricsWindow.days30.rawValue)))
        XCTAssertEqual(prepared.viewportStart, prepared.earliestDate)
    }
}
