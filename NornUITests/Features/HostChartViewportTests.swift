import XCTest
@testable import NornUI

final class HostChartViewportTests: XCTestCase {
    private let latest = Date(timeIntervalSince1970: 2_000_000_000)

    func testDefaultsToLatestWindowWithBoundedAxisDates() {
        let viewport = HostChartViewport(latest: latest, window: .minutes5, requestedStart: nil)

        XCTAssertEqual(viewport.start, latest.addingTimeInterval(-300))
        XCTAssertEqual(viewport.end, latest)
        XCTAssertEqual(viewport.axisDates, [
            latest.addingTimeInterval(-300),
            latest.addingTimeInterval(-150),
            latest,
        ])
        XCTAssertTrue(viewport.canGoOlder)
        XCTAssertFalse(viewport.canGoNewer)
    }

    func testRequestedStartAndPagingClampToRetentionBounds() {
        let requested = latest.addingTimeInterval(-3_600)
        let viewport = HostChartViewport(latest: latest, window: .minutes15, requestedStart: requested)

        XCTAssertEqual(viewport.start, requested)
        XCTAssertEqual(viewport.end, requested.addingTimeInterval(900))
        XCTAssertTrue(viewport.canGoOlder)
        XCTAssertTrue(viewport.canGoNewer)
        XCTAssertEqual(viewport.shifted(by: -1), requested.addingTimeInterval(-900))
        XCTAssertEqual(viewport.shifted(by: 1), requested.addingTimeInterval(900))
        XCTAssertEqual(viewport.shifted(by: .min), viewport.earliestStart)
        XCTAssertEqual(viewport.shifted(by: .max), viewport.latestStart)
    }

    func testThirtyDayWindowHasNoPagingRange() {
        let viewport = HostChartViewport(
            latest: latest,
            window: .days30,
            requestedStart: latest.addingTimeInterval(-60)
        )

        XCTAssertEqual(viewport.start, viewport.earliestStart)
        XCTAssertEqual(viewport.start, viewport.latestStart)
        XCTAssertEqual(viewport.end, latest)
        XCTAssertFalse(viewport.canGoOlder)
        XCTAssertFalse(viewport.canGoNewer)
    }

    func testNonfiniteRequestedStartFallsBackToLatestWindow() {
        let viewport = HostChartViewport(
            latest: latest,
            window: .hour1,
            requestedStart: Date(timeIntervalSinceReferenceDate: .nan)
        )

        XCTAssertEqual(viewport.start, viewport.latestStart)
        XCTAssertEqual(viewport.end, latest)
    }
}
