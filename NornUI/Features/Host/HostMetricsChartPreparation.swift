//
//  HostMetricsChartPreparation.swift
//  NornUI
//
//  Keeps chart shaping off the main actor. The input histories are time ordered
//  by the store, so a viewport only needs a small binary-search slice.
//

import Foundation

nonisolated struct HostMetricsChartPreparation: Sendable, Equatable {
    struct TenantSeries: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let samples: [NornServiceMetricSample]
        let highWater: Double
    }

    let hostSamples: [NornHostMetricSample]
    let tenantSeries: [TenantSeries]
    let cpuHighWater: Double
    let memoryHighWater: Double
    let yDomainUpperBound: Double
    let earliestDate: Date
    let latestDate: Date
    let viewportStart: Date
    let viewportEnd: Date

    static func prepare(
        samples: [NornHostMetricSample],
        serviceSamples: [NornServiceMetricSample],
        latest: NornHostMetrics,
        window: NornHostMetricsWindow,
        requestedViewportStart: Date,
        includesServiceMetrics: Bool
    ) -> Self {
        let current = NornHostMetricSample(metrics: latest)
        let hostHistory = orderedHostSamples(samples, current: current)
        let latestDate = hostHistory.last?.observedAt ?? current.observedAt
        // History arrives in viewport-sized pages. Keep the retained 30-day
        // extent scrollable even while only the recent page is resident.
        let earliestDate = min(hostHistory.first?.observedAt ?? latestDate, latestDate.addingTimeInterval(-Double(NornHostMetricsWindow.days30.rawValue)))
        let latestStart = latestDate.addingTimeInterval(-Double(window.rawValue))
        let viewportStart = min(max(requestedViewportStart, earliestDate), latestStart)
        let viewportEnd = viewportStart.addingTimeInterval(Double(window.rawValue))
        let visibleHosts = Array(hostHistory[range(in: hostHistory, from: viewportStart, through: viewportEnd, date: \.observedAt)])
        let plottedHosts = downsampleHost(visibleHosts)
        let tenants = includesServiceMetrics
            ? prepareTenants(serviceSamples, from: viewportStart, through: viewportEnd)
            : []
        let tenantHighWater = tenants.reduce(0.0) { current, series in max(current, series.highWater) }

        return Self(
            hostSamples: plottedHosts,
            tenantSeries: tenants,
            cpuHighWater: visibleHosts.map(\.cpuPercent).max() ?? 0,
            memoryHighWater: visibleHosts.map(\.memoryPercent).max() ?? 0,
            yDomainUpperBound: tenantHighWater > 100 ? ceil(tenantHighWater / 50) * 50 : 100,
            earliestDate: earliestDate,
            latestDate: latestDate,
            viewportStart: viewportStart,
            viewportEnd: viewportEnd
        )
    }

    func nearestHost(to date: Date) -> NornHostMetricSample? {
        Self.nearest(in: hostSamples, to: date, date: \.observedAt)
    }

    func nearestTenantSamples(to date: Date, tolerance: TimeInterval) -> [(TenantSeries, NornServiceMetricSample)] {
        tenantSeries.compactMap { series in
            guard let sample = Self.nearest(in: series.samples, to: date, date: \.observedAt),
                  abs(sample.observedAt.timeIntervalSince(date)) <= tolerance else { return nil }
            return (series, sample)
        }
    }

    private static func orderedHostSamples(_ samples: [NornHostMetricSample], current: NornHostMetricSample) -> [NornHostMetricSample] {
        var result = samples
        if result.last?.observedAt == current.observedAt {
            result[result.count - 1] = current
        } else if result.last?.observedAt ?? .distantPast < current.observedAt {
            result.append(current)
        } else {
            result.append(current)
            result.sort { $0.observedAt < $1.observedAt }
        }
        return result
    }

    private static func prepareTenants(_ samples: [NornServiceMetricSample], from start: Date, through end: Date) -> [TenantSeries] {
        let ordered = isOrdered(samples, date: \.observedAt) ? samples : samples.sorted { $0.observedAt < $1.observedAt }
        let visible = ordered[range(in: ordered, from: start, through: end, date: \.observedAt)]
        let grouped = Dictionary(grouping: visible, by: \.seriesID)
        return grouped.compactMap { id, values in
            guard let first = values.first else { return nil }
            let highWater = values.reduce(0.0) { max($0, $1.cpuPercent, $1.memoryPercent) }
            return TenantSeries(id: id, name: first.displayName, samples: downsampleTenant(values), highWater: highWater)
        }
        .sorted { $0.highWater == $1.highWater ? $0.name < $1.name : $0.highWater > $1.highWater }
        .prefix(6)
        .map { $0 }
    }

    /// Four extrema per bucket preserves peaks while bounding host marks at 480.
    private static func downsampleHost(_ values: [NornHostMetricSample]) -> [NornHostMetricSample] {
        downsample(values, maximumBuckets: 60, date: \.observedAt, cpu: \.cpuPercent, memory: \.memoryPercent)
    }

    /// Tenant overlays are capped at 80 points (160 marks) per series.
    private static func downsampleTenant(_ values: [NornServiceMetricSample]) -> [NornServiceMetricSample] {
        downsample(values, maximumBuckets: 20, date: \.observedAt, cpu: \.cpuPercent, memory: \.memoryPercent)
    }

    private static func downsample<Value>(
        _ values: [Value], maximumBuckets: Int, date: KeyPath<Value, Date>, cpu: KeyPath<Value, Double>, memory: KeyPath<Value, Double>
    ) -> [Value] {
        guard values.count > maximumBuckets else { return values }
        let bucketSize = Int(ceil(Double(values.count) / Double(maximumBuckets)))
        var result: [Value] = []
        result.reserveCapacity(maximumBuckets * 4)
        for start in stride(from: 0, to: values.count, by: bucketSize) {
            let bucket = values[start..<min(start + bucketSize, values.count)]
            if let first = bucket.first { result.append(first) }
            if let peak = bucket.max(by: { $0[keyPath: cpu] < $1[keyPath: cpu] }) { result.append(peak) }
            if let peak = bucket.max(by: { $0[keyPath: memory] < $1[keyPath: memory] }) { result.append(peak) }
            if let last = bucket.last { result.append(last) }
        }
        return Dictionary(result.map { ($0[keyPath: date], $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0[keyPath: date] < $1[keyPath: date] }
    }

    private static func range<Value>(in values: [Value], from start: Date, through end: Date, date: KeyPath<Value, Date>) -> Range<Int> {
        let lower = lowerBound(values, target: start, date: date)
        let upper = upperBound(values, target: end, date: date)
        return lower..<upper
    }

    private static func lowerBound<Value>(_ values: [Value], target: Date, date: KeyPath<Value, Date>) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = low + (high - low) / 2
            if values[mid][keyPath: date] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func upperBound<Value>(_ values: [Value], target: Date, date: KeyPath<Value, Date>) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = low + (high - low) / 2
            if values[mid][keyPath: date] <= target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func nearest<Value>(in values: [Value], to target: Date, date: KeyPath<Value, Date>) -> Value? {
        guard !values.isEmpty else { return nil }
        let index = lowerBound(values, target: target, date: date)
        guard index > 0, index < values.count else { return values[min(index, values.count - 1)] }
        let before = values[index - 1]
        let after = values[index]
        return abs(before[keyPath: date].timeIntervalSince(target)) <= abs(after[keyPath: date].timeIntervalSince(target)) ? before : after
    }

    private static func isOrdered<Value>(_ values: [Value], date: KeyPath<Value, Date>) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0[keyPath: date] <= $1[keyPath: date] }
    }
}
