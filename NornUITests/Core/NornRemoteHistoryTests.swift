import XCTest
@testable import NornUI

final class NornRemoteHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDensityScalesWithVisibleRangeAndPagesArriveNewestFirst() {
        let hour = ranges(.hour1)
        let day = ranges(.hours24)
        let month = ranges(.days30)
        XCTAssertEqual(hour.count, 1)
        XCTAssertEqual(hour.first?.step, 15)
        XCTAssertEqual(day.count, 4)
        XCTAssertEqual(day.first?.step, 120)
        XCTAssertEqual(month.count, 4)
        XCTAssertEqual(month.first?.step, 3_600)
        for window in NornHostMetricsWindow.allCases {
            let pages = ranges(window)
            XCTAssertEqual(pages.first?.end, now)
            XCTAssertEqual(pages.last?.start, now.addingTimeInterval(-Double(window.rawValue)))
            XCTAssertTrue(pages.allSatisfy { $0.includesServices })
            XCTAssertLessThanOrEqual(pages.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / Double($1.step) }, 720)
            for (newer, older) in zip(pages, pages.dropFirst()) {
                XCTAssertEqual(newer.start, older.end)
                XCTAssertGreaterThan(newer.end, older.end)
            }
        }
    }

    func testRangesClampFutureAndRetentionAndReduceOlderDensity() {
        let future = NornHistoryRange.pages(window: .hour1, endingAt: now.addingTimeInterval(600), includesServices: false, now: now)
        XCTAssertEqual(future.first?.end, now)
        XCTAssertTrue(future.allSatisfy { !$0.includesServices })
        let old = NornHistoryRange.pages(window: .hour1, endingAt: now.addingTimeInterval(-172_800), includesServices: false, now: now)
        XCTAssertEqual(old.first?.step, 300)
        let clipped = NornHistoryRange.pages(window: .days30, endingAt: now.addingTimeInterval(-86_400), includesServices: false, now: now)
        XCTAssertEqual(clipped.last?.start, now.addingTimeInterval(-2_592_000))
        XCTAssertTrue(NornHistoryRange.pages(window: .hour1, endingAt: now.addingTimeInterval(-2_592_001), includesServices: false, now: now).isEmpty)
    }

    func testCacheBoundsMemoryAndEvictsLeastRecentlyAccessedPage() {
        var cache = NornRemoteHistoryCache()
        var keys: [NornHistoryRange] = []
        for index in 0..<7 {
            let offset = Double(index) * 100
            let start = now.addingTimeInterval(-10_000 - offset)
            let end = now.addingTimeInterval(-9_900 - offset)
            keys.append(.init(start: start, end: end, step: 15, includesServices: false))
        }
        for index in 0..<6 { cache.insert(page(), for: keys[index], now: now.addingTimeInterval(Double(index))) }
        XCTAssertNotNil(cache.value(for: keys[0], now: now.addingTimeInterval(7)))
        cache.insert(page(), for: keys[6], now: now.addingTimeInterval(8))
        XCTAssertEqual(cache.count, 6)
        XCTAssertNil(cache.value(for: keys[1], now: now.addingTimeInterval(9)))
        XCTAssertNotNil(cache.value(for: keys[0], now: now.addingTimeInterval(9)))
    }

    func testCacheReadsDoNotExtendFreshnessBeyondLiveOrHistoricalTTL() {
        var cache = NornRemoteHistoryCache()
        let live = ranges(.hour1)[0]
        cache.insert(page(), for: live, now: now)
        XCTAssertNotNil(cache.value(for: live, now: now.addingTimeInterval(29)))
        XCTAssertNil(cache.value(for: live, now: now.addingTimeInterval(30)))
        let historic = NornHistoryRange(start: now.addingTimeInterval(-7_200), end: now.addingTimeInterval(-3_600), step: 15, includesServices: false)
        cache.insert(page(), for: historic, now: now)
        XCTAssertNotNil(cache.value(for: historic, now: now.addingTimeInterval(599)))
        XCTAssertNil(cache.value(for: historic, now: now.addingTimeInterval(600)))
        XCTAssertEqual(cache.count, 0)
    }

    func testOverlappingPageSamplesAreDeduplicatedAndChronologicallySorted() {
        let older = host(at: -30, cpu: 10)
        let boundary = host(at: -15, cpu: 20)
        let corrected = host(at: -15, cpu: 25)
        let newest = host(at: 0, cpu: 30)
        let service = NornServiceMetricSample(observedAt: now, app: "app", process: "worker", cpuPercent: 10, memoryPercent: 20)
        let correctedService = NornServiceMetricSample(observedAt: now, app: "app", process: "worker", cpuPercent: 12, memoryPercent: 22)
        let result = NornRemoteHistoryCache.samples([
            page(host: [newest, boundary], services: [service]),
            page(host: [older, corrected], services: [correctedService])
        ])
        XCTAssertEqual(result.host.map(\.observedAt), [older.observedAt, boundary.observedAt, newest.observedAt])
        XCTAssertEqual(result.host.map(\.cpuPercent), [10, 25, 30])
        XCTAssertEqual(result.services.count, 1)
        XCTAssertEqual(result.services.first?.cpuPercent, 12)
    }

    func testRemoteHistoryDoesNotAppendCurrentReadingFromDifferentCollector() {
        let latest = NornFixtures.hostMetrics
        let historical = NornHostMetricSample(observedAt: latest.observedAt.addingTimeInterval(-15), cpuPercent: 2, memoryUsedBytes: 20, memoryTotalBytes: 100)
        let remote = HostMetricsChartPreparation.prepare(samples: [historical], serviceSamples: [], latest: latest, window: .hour1, requestedViewportStart: latest.observedAt.addingTimeInterval(-3600), includesServiceMetrics: false, includeLatestSample: false)
        XCTAssertEqual(remote.hostSamples.count, 1)
        XCTAssertEqual(remote.hostSamples.first?.observedAt, historical.observedAt)
        XCTAssertEqual(remote.cpuHighWater, 2)
        XCTAssertEqual(remote.latestDate, latest.observedAt)
        let local = HostMetricsChartPreparation.prepare(samples: [historical], serviceSamples: [], latest: latest, window: .hour1, requestedViewportStart: latest.observedAt.addingTimeInterval(-3600), includesServiceMetrics: false)
        XCTAssertEqual(local.hostSamples.count, 2)
        XCTAssertEqual(local.hostSamples.last?.observedAt, latest.observedAt)
    }

    private func ranges(_ window: NornHostMetricsWindow) -> [NornHistoryRange] {
        NornHistoryRange.pages(window: window, endingAt: now, includesServices: true, now: now)
    }

    private func host(at offset: TimeInterval, cpu: Double) -> NornHostMetricSample {
        NornHostMetricSample(observedAt: now.addingTimeInterval(offset), cpuPercent: cpu, memoryUsedBytes: 20, memoryTotalBytes: 100)
    }

    private func page(host: [NornHostMetricSample] = [], services: [NornServiceMetricSample] = []) -> NornHostHistoryPage {
        NornHostHistoryPage(schemaVersion: "norn.host-metrics-history/v1", source: "nomad-prometheus", start: now.addingTimeInterval(-3_600), end: now, stepSeconds: 15, retentionSeconds: 2_592_000, host: host, services: services)
    }
}
