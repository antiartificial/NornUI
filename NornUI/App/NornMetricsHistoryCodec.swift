import Foundation

/// CPU-intensive history transforms. Keep this type nonisolated so callers can
/// decode and compact UserDefaults payloads away from SwiftUI's main actor.
nonisolated enum NornMetricsHistoryCodec {
    static func load(
        hostData: Data?,
        serviceData: Data?,
        window: NornHostMetricsWindow,
        endingAt: Date
    ) -> (host: [NornHostMetricSample], service: [NornServiceMetricSample]) {
        let host = compactHost(decodeHost(hostData), endingAt: endingAt)
        let service = compactService(decodeService(serviceData), endingAt: endingAt)
        let start = endingAt.addingTimeInterval(-TimeInterval(window.rawValue))
        return (
            host.filter { $0.observedAt >= start && $0.observedAt <= endingAt },
            service.filter { $0.observedAt >= start && $0.observedAt <= endingAt }
        )
    }

    static func mergeAndEncode(
        hostData: Data?,
        serviceData: Data?,
        hostAdditions: [NornHostMetricSample],
        serviceAdditions: [NornServiceMetricSample],
        endingAt: Date
    ) -> (hostData: Data?, serviceData: Data?) {
        let host = compactHost(decodeHost(hostData) + hostAdditions, endingAt: endingAt)
        let service = compactService(decodeService(serviceData) + serviceAdditions, endingAt: endingAt)
        return (
            try? JSONEncoder().encode(host),
            try? JSONEncoder().encode(service)
        )
    }

    static func mergedHost(
        _ cached: [NornHostMetricSample],
        _ incoming: [NornHostMetricSample]
    ) -> [NornHostMetricSample] {
        compactHost(cached + incoming, endingAt: maxDate(cached, incoming))
    }

    static func mergedService(
        _ cached: [NornServiceMetricSample],
        _ incoming: [NornServiceMetricSample]
    ) -> [NornServiceMetricSample] {
        compactService(cached + incoming, endingAt: maxDate(cached, incoming))
    }

    private static func decodeHost(_ data: Data?) -> [NornHostMetricSample] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([NornHostMetricSample].self, from: data)) ?? []
    }

    private static func decodeService(_ data: Data?) -> [NornServiceMetricSample] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([NornServiceMetricSample].self, from: data)) ?? []
    }

    private static func maxDate(_ host: [NornHostMetricSample], _ incoming: [NornHostMetricSample]) -> Date {
        (host + incoming).map(\.observedAt).max() ?? .now
    }

    private static func maxDate(_ service: [NornServiceMetricSample], _ incoming: [NornServiceMetricSample]) -> Date {
        (service + incoming).map(\.observedAt).max() ?? .now
    }

    private static func compactHost(_ samples: [NornHostMetricSample], endingAt: Date) -> [NornHostMetricSample] {
        NornAppModel.compactHostMetricsHistory(samples, endingAt: endingAt)
    }

    private static func compactService(_ samples: [NornServiceMetricSample], endingAt: Date) -> [NornServiceMetricSample] {
        NornAppModel.compactServiceMetricsHistory(samples, endingAt: endingAt)
    }
}
