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

    static let minimumDuration: TimeInterval = 60
    static let maximumDuration = TimeInterval(NornHostMetricsWindow.days30.rawValue)

    let duration: TimeInterval

    init(latest: Date, window: NornHostMetricsWindow, requestedStart: Date?, duration: TimeInterval? = nil) {
        let requestedDuration = duration.flatMap { $0.isFinite ? $0 : nil } ?? TimeInterval(window.rawValue)
        let duration = min(max(requestedDuration, Self.minimumDuration), Self.maximumDuration)
        let finiteLatest = latest.timeIntervalSinceReferenceDate.isFinite
            ? latest
            : Date(timeIntervalSinceReferenceDate: 0)
        let retainedStart = finiteLatest.addingTimeInterval(-TimeInterval(NornHostMetricsWindow.days30.rawValue))

        earliestStart = retainedStart
        latestStart = finiteLatest.addingTimeInterval(-duration)
        self.duration = duration

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
        let offset = Double(windowCount) * duration
        guard offset.isFinite else { return windowCount < 0 ? earliestStart : latestStart }
        return min(max(start.addingTimeInterval(offset), earliestStart), latestStart)
    }

    /// Changes the range while keeping the date under the pointer at the same
    /// fractional position, unless the retained-history boundary is reached.
    func zoomed(by scale: Double, anchor: Date? = nil) -> Self {
        guard scale.isFinite, scale > 0 else { return self }
        let anchor = anchor.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
            .map { min(max($0, start), end) } ?? start.addingTimeInterval(duration / 2)
        let fraction = anchor.timeIntervalSince(start) / duration
        let newDuration = min(max(duration * scale, Self.minimumDuration), Self.maximumDuration)
        return Self(
            latest: latestStart.addingTimeInterval(duration),
            window: .days30,
            requestedStart: anchor.addingTimeInterval(-newDuration * fraction),
            duration: newDuration
        )
    }

    /// Supports dragging in either direction. Tiny selections expand around
    /// their midpoint to retain a usable time axis.
    func selectedRange(from first: Date, to second: Date) -> Self {
        guard first.timeIntervalSinceReferenceDate.isFinite,
              second.timeIntervalSinceReferenceDate.isFinite else { return self }
        let lower = min(max(min(first, second), start), end)
        let upper = min(max(max(first, second), start), end)
        let selectedDuration = max(upper.timeIntervalSince(lower), Self.minimumDuration)
        let midpoint = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
        let selectedStart = min(max(midpoint.addingTimeInterval(-selectedDuration / 2), start), end.addingTimeInterval(-selectedDuration))
        return Self(
            latest: latestStart.addingTimeInterval(duration),
            window: .days30,
            requestedStart: selectedStart,
            duration: selectedDuration
        )
    }

    /// Fetch the smallest supported history page that fully covers this view.
    var historyWindow: NornHostMetricsWindow {
        NornHostMetricsWindow.allCases.first { TimeInterval($0.rawValue) >= duration } ?? .days30
    }

    var axisDates: [Date] {
        [start, start.addingTimeInterval(duration / 2), end]
    }
}
