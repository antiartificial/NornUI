import Foundation

nonisolated struct NornHostHistoryPage: Codable, Sendable {
    var schemaVersion: String
    var source: String
    var start: Date
    var end: Date
    var stepSeconds: Int
    var retentionSeconds: Int
    var host: [NornHostMetricSample]
    var services: [NornServiceMetricSample]
}

nonisolated struct NornHistoryRange: Hashable, Sendable {
    var start: Date
    var end: Date
    var step: Int
    var includesServices: Bool

    static func pages(window: NornHostMetricsWindow, endingAt: Date, includesServices: Bool, now: Date = .now) -> [Self] {
        let end = min(endingAt, now)
        let start = max(end.addingTimeInterval(-Double(window.rawValue)), now.addingTimeInterval(-2_592_000))
        guard start < end else { return [] }
        let span = end.timeIntervalSince(start)
        let age = now.timeIntervalSince(end)
        let floor = age >= 86_400 ? 300 : (span > 3_600 ? 60 : 15)
        let step = max(floor, Int(ceil(span / 720 / Double(floor))) * floor)
        let count = span > 21_600 ? 4 : 1
        return (0..<count).map { index in
            let pageEnd = end.addingTimeInterval(-span * Double(index) / Double(count))
            return .init(start: end.addingTimeInterval(-span * Double(index + 1) / Double(count)), end: pageEnd,
                         step: step, includesServices: includesServices)
        }
    }
}

/// View-range cache, deliberately separate from locally collected telemetry.
nonisolated struct NornRemoteHistoryCache: Sendable {
    private struct Entry: Sendable { var page: NornHostHistoryPage; var accessed: Date; var loaded: Date }
    private var entries: [NornHistoryRange: Entry] = [:]
    var count: Int { entries.count }

    mutating func value(for key: NornHistoryRange, now: Date = .now) -> NornHostHistoryPage? {
        entries = entries.filter { now.timeIntervalSince($0.value.accessed) < 600 }
        guard var entry = entries[key] else { return nil }
        let ttl: TimeInterval = key.end > now.addingTimeInterval(-300) ? 30 : 600
        guard now.timeIntervalSince(entry.loaded) < ttl else { entries[key] = nil; return nil }
        entry.accessed = now
        entries[key] = entry
        return entry.page
    }

    mutating func insert(_ page: NornHostHistoryPage, for key: NornHistoryRange, now: Date = .now) {
        entries[key] = Entry(page: page, accessed: now, loaded: now)
        while entries.count > 6, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            entries[oldest] = nil
        }
    }

    static func samples(_ pages: [NornHostHistoryPage]) -> (host: [NornHostMetricSample], services: [NornServiceMetricSample]) {
        let hosts = Dictionary(pages.flatMap(\.host).map { ($0.observedAt, $0) }, uniquingKeysWith: { _, newer in newer })
        let services = Dictionary(pages.flatMap(\.services).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        return (hosts.values.sorted { $0.observedAt < $1.observedAt },
                services.values.sorted { $0.observedAt == $1.observedAt ? $0.seriesID < $1.seriesID : $0.observedAt < $1.observedAt })
    }
}
