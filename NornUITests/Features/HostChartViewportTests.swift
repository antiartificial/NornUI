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
    func testAnchoredZoomPreservesPointerFractionAndRoundTrips() {
        let viewport = HostChartViewport(latest: latest, window: .hour1, requestedStart: latest.addingTimeInterval(-7_200))
        let anchor = viewport.start.addingTimeInterval(900)
        let zoomed = viewport.zoomed(by: 0.5, anchor: anchor)

        XCTAssertEqual(zoomed.duration, 1_800)
        XCTAssertEqual(anchor.timeIntervalSince(zoomed.start) / zoomed.duration, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.zoomed(by: 2, anchor: anchor), viewport)
    }

    func testSelectionSupportsReverseDragAndExactNonPresetDuration() {
        let viewport = HostChartViewport(latest: latest, window: .hour1, requestedStart: nil)
        let first = latest.addingTimeInterval(-1_234)
        let second = latest.addingTimeInterval(-789)
        let selection = viewport.selectedRange(from: second, to: first)

        XCTAssertEqual(selection.start, first)
        XCTAssertEqual(selection.end, second)
        XCTAssertEqual(selection.duration, 445)
        XCTAssertEqual(selection.historyWindow, .minutes15)
    }

    func testTinySelectionAndExtremeZoomStayInsideRetention() {
        let viewport = HostChartViewport(latest: latest, window: .minutes5, requestedStart: nil)
        let selection = viewport.selectedRange(from: latest, to: latest)
        XCTAssertEqual(selection.duration, 60)
        XCTAssertEqual(selection.end, latest)

        let allHistory = selection.zoomed(by: Double.greatestFiniteMagnitude, anchor: latest)
        XCTAssertEqual(allHistory.duration, HostChartViewport.maximumDuration)
        XCTAssertEqual(allHistory.start, allHistory.earliestStart)
        XCTAssertEqual(allHistory.end, latest)
        XCTAssertEqual(viewport.zoomed(by: .nan), viewport)
        XCTAssertEqual(viewport.zoomed(by: 0), viewport)
    }

    func testCustomDurationIsClampedAndPagingUsesItsLength() {
        let viewport = HostChartViewport(latest: latest, window: .hour1, requestedStart: latest.addingTimeInterval(-2_000), duration: 137)
        XCTAssertEqual(viewport.end.timeIntervalSince(viewport.start), 137)
        XCTAssertEqual(viewport.shifted(by: -1), viewport.start.addingTimeInterval(-137))
        XCTAssertEqual(HostChartViewport(latest: latest, window: .hour1, requestedStart: nil, duration: -1).duration, 60)
        XCTAssertEqual(HostChartViewport(latest: latest, window: .hour1, requestedStart: nil, duration: .nan).duration, 3_600)
    }

}
