//
//  HostChartViewport.swift
//  NornUI
//
//  Bounds a history chart to one rendered window while allowing explicit
//  paging across the locally retained 30-day history.
//

import Foundation

nonisolated struct HostChartViewport: Equatable, Sendable {
    let start: Date
    let end: Date
    let earliestStart: Date
    let latestStart: Date

    private let windowDuration: TimeInterval

    init(latest: Date, window: NornHostMetricsWindow, requestedStart: Date?) {
        let duration = TimeInterval(window.rawValue)
        let finiteLatest = latest.timeIntervalSinceReferenceDate.isFinite
            ? latest
            : Date(timeIntervalSinceReferenceDate: 0)
        let retainedStart = finiteLatest.addingTimeInterval(-TimeInterval(NornHostMetricsWindow.days30.rawValue))

        earliestStart = retainedStart
        latestStart = finiteLatest.addingTimeInterval(-duration)
        windowDuration = duration

        if let requestedStart, requestedStart.timeIntervalSinceReferenceDate.isFinite {
            start = min(max(requestedStart, earliestStart), latestStart)
        } else {
            start = latestStart
        }
        end = start.addingTimeInterval(duration)
    }

    var canGoOlder: Bool { start > earliestStart }
    var canGoNewer: Bool { start < latestStart }

    func shifted(by windowCount: Int) -> Date {
        guard windowCount != 0 else { return start }
        let offset = Double(windowCount) * windowDuration
        guard offset.isFinite else { return windowCount < 0 ? earliestStart : latestStart }
        return min(max(start.addingTimeInterval(offset), earliestStart), latestStart)
    }

    var axisDates: [Date] {
        [start, start.addingTimeInterval(windowDuration / 2), end]
    }
}
