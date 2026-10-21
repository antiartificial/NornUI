import Foundation

/// Span tree and waterfall geometry for one trace.
nonisolated struct NornTraceLayout: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        var span: NornSpan
        var depth: Int
        /// Fractions of the trace duration, both within 0...1.
        var offset: Double
        var width: Double
        var id: String { span.id }
    }

    let start: Date
    let duration: TimeInterval
    let rows: [Row]

    /// Spans whose parent is absent (including parents hidden from this credential) become roots.
    init(spans: [NornSpan]) {
        let origin = spans.map(\.start).min() ?? .distantPast
        let end = spans.map(\.end).max() ?? origin
        let length = max(end.timeIntervalSince(origin), 0)
        let total = length > 0 ? length : 1

        let ids = Set(spans.map(\.spanID))
        let children = Dictionary(grouping: spans.filter { ids.contains($0.parentSpanID) && $0.parentSpanID != $0.spanID }, by: \.parentSpanID)
        let roots = spans.filter { !ids.contains($0.parentSpanID) || $0.parentSpanID == $0.spanID }
        let startOrder: (NornSpan, NornSpan) -> Bool = { ($0.start, $0.spanID) < ($1.start, $1.spanID) }

        var built: [Row] = []
        var visited: Set<String> = []
        func visit(_ span: NornSpan, depth: Int) {
            guard visited.insert(span.spanID).inserted else { return }
            let offset = min(max(span.start.timeIntervalSince(origin) / total, 0), 1)
            let width = min(max(span.end.timeIntervalSince(span.start) / total, 0), 1 - offset)
            built.append(Row(span: span, depth: depth, offset: offset, width: width))
            for child in (children[span.spanID] ?? []).sorted(by: startOrder) { visit(child, depth: depth + 1) }
        }
        for root in roots.sorted(by: startOrder) { visit(root, depth: 0) }
        for orphan in spans.sorted(by: startOrder) { visit(orphan, depth: 0) } // parent cycles
        start = origin
        duration = length
        rows = built
    }
}
