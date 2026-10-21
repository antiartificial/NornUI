import SwiftUI

struct AppTracesView: View {
    private enum Range: String, CaseIterable, Identifiable {
        case fifteenMinutes = "15m", hour = "1h", sixHours = "6h", day = "24h"
        var id: String { rawValue }
        var interval: TimeInterval {
            switch self {
            case .fifteenMinutes: 900
            case .hour: 3_600
            case .sixHours: 21_600
            case .day: 86_400
            }
        }
    }

    let app: String
    @Binding var openTraceID: String?

    @Environment(\.observabilityActions) private var actions
    @State private var range = Range.hour
    @State private var minDurationText = ""
    @State private var reloadToken = 0
    @State private var traces: [NornTraceSummary] = []
    @State private var issue: NornObservabilityIssue?
    @State private var isLoading = false

    private struct QueryKey: Hashable { var range: Range; var minDuration: Double?; var reload: Int }
    private var minDuration: Double? { Double(minDurationText).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                TextField("Min duration (ms)", text: $minDurationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button { reloadToken += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if let issue, issue != .notFound, traces.isEmpty {
                NornObservabilityIssueView(issue: issue, noun: "Traces") { reloadToken += 1 }
                    .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    list.frame(minWidth: 320, idealWidth: 380)
                    detail.frame(minWidth: 460, maxWidth: .infinity)
                }
            }
        }
        .task(id: QueryKey(range: range, minDuration: minDuration, reload: reloadToken)) {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { await load() }
        }
    }

    private var list: some View {
        List(traces, selection: $openTraceID) { trace in
            VStack(alignment: .leading, spacing: 2) {
                Text(trace.rootName.isEmpty ? trace.traceID : trace.rootName).lineLimit(1)
                HStack(spacing: 8) {
                    Text(trace.rootService)
                    Text(trace.start, format: .dateTime.hour().minute().second())
                    Text(Self.duration(trace.durationMs))
                    Text("\(trace.spanCount) spans")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(trace.traceID)
        }
        .overlay {
            if traces.isEmpty && !isLoading {
                NornStateView(state: .empty(title: "No traces", message: "No traces matched this time range and duration filter.", symbol: "point.3.connected.trianglepath.dotted"))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let openTraceID {
            TraceDetailView(app: app, traceID: openTraceID)
                .id(openTraceID)
        } else {
            NornStateView(state: .empty(title: "Select a trace", message: "Choose a trace to see its spans.", symbol: "chart.bar.doc.horizontal"))
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            traces = try await actions.searchTraces(app, .now.addingTimeInterval(-range.interval), nil, 50, minDuration).traces
            issue = nil
        } catch is CancellationError {
            return
        } catch {
            traces = []
            issue = NornObservabilityIssue(error, feature: .traces)
        }
    }

    static func duration(_ milliseconds: Double) -> String {
        milliseconds >= 1_000 ? String(format: "%.2f s", milliseconds / 1_000) : String(format: "%.1f ms", milliseconds)
    }
}

struct TraceDetailView: View {
    let app: String
    let traceID: String

    @Environment(\.observabilityActions) private var actions
    @State private var detail: NornTraceDetail?
    @State private var layout: NornTraceLayout?
    @State private var issue: NornObservabilityIssue?
    @State private var selectedSpanID: String?

    private let labelWidth: CGFloat = 240

    var body: some View {
        Group {
            if let issue {
                NornObservabilityIssueView(issue: issue, noun: "Trace", retry: { Task { await load() } })
            } else if let detail, let layout {
                VStack(spacing: 0) {
                    header(detail, layout)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(layout.rows) { row in waterfallRow(row) }
                        }
                    }
                    if let span = layout.rows.first(where: { $0.id == selectedSpanID })?.span {
                        Divider()
                        SpanInspector(span: span)
                    }
                }
            } else {
                ProgressView("Loading trace…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func header(_ detail: NornTraceDetail, _ layout: NornTraceLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.traceID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack(spacing: 10) {
                Text("\(detail.spans.count) spans · \(AppTracesView.duration(layout.duration * 1_000))")
                if detail.omittedSpans > 0 {
                    Label("\(detail.omittedSpans) spans hidden (other apps)", systemImage: "eye.slash")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func waterfallRow(_ row: NornTraceLayout.Row) -> some View {
        HStack(spacing: 8) {
            Text(row.span.name)
                .lineLimit(1)
                .padding(.leading, CGFloat(row.depth) * 12)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary.opacity(0.4)).frame(height: 1)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(row.span.isError ? Color.red : Color.accentColor)
                        .frame(width: max(proxy.size.width * row.width, 2), height: 10)
                        .offset(x: proxy.size.width * row.offset)
                }
                .frame(maxHeight: .infinity)
            }
            Text(AppTracesView.duration(row.span.durationMs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(row.id == selectedSpanID ? Color.accentColor.opacity(0.18) : row.span.isError ? Color.red.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedSpanID = row.id }
    }

    private func load() async {
        issue = nil
        do {
            let loaded = try await actions.trace(app, traceID)
            detail = loaded
            layout = NornTraceLayout(spans: loaded.spans)
        } catch is CancellationError {
            return
        } catch {
            issue = NornObservabilityIssue(error, feature: .traceDetail)
        }
    }
}

private struct SpanInspector: View {
    let span: NornSpan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(span.name).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    field("Kind", span.kind)
                    field("Status", span.statusMessage.isEmpty ? span.status : "\(span.status): \(span.statusMessage)")
                    field("Service", span.service)
                    field("Allocation", span.allocID)
                    ForEach(span.attributes.keys.sorted(), id: \.self) { key in
                        field(key, Self.text(span.attributes[key]))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .font(.caption)
        .frame(height: 170)
    }

    @ViewBuilder
    private func field(_ name: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(name).foregroundStyle(.secondary)
                Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private static func text(_ value: JSONValue?) -> String {
        switch value {
        case let .string(string): string
        case let .number(number): number.rounded() == number ? String(Int(number)) : String(number)
        case let .bool(flag): String(flag)
        case .none, .null: ""
        default: String(describing: value!)
        }
    }
}
