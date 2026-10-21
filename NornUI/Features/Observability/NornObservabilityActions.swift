import SwiftUI

/// Logs and traces requests, injected so the views stay free of the model and client.
struct NornObservabilityActions: Sendable {
    var queryLogs: @Sendable (_ app: String, _ filter: NornLogFilter) async throws -> NornLogQueryResult
    var searchTraces: @Sendable (_ app: String, _ since: Date?, _ until: Date?, _ limit: Int, _ minDurationMs: Double?) async throws -> NornTraceList
    var trace: @Sendable (_ app: String, _ traceID: String) async throws -> NornTraceDetail

    static let unavailable = NornObservabilityActions(
        queryLogs: { _, _ in throw NornClientError.invalidResponse },
        searchTraces: { _, _, _, _, _ in throw NornClientError.invalidResponse },
        trace: { _, _ in throw NornClientError.invalidResponse }
    )
}

private struct NornObservabilityActionsKey: EnvironmentKey {
    static let defaultValue = NornObservabilityActions.unavailable
}

extension EnvironmentValues {
    var observabilityActions: NornObservabilityActions {
        get { self[NornObservabilityActionsKey.self] }
        set { self[NornObservabilityActionsKey.self] = newValue }
    }
}
