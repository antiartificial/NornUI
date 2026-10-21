import SwiftUI

struct AppLogsView: View {
    private enum Range: String, CaseIterable, Identifiable {
        case fifteenMinutes = "15m", hour = "1h", sixHours = "6h", day = "24h", custom = "Custom"
        var id: String { rawValue }
        var interval: TimeInterval? {
            switch self {
            case .fifteenMinutes: 900
            case .hour: 3_600
            case .sixHours: 21_600
            case .day: 86_400
            case .custom: nil
            }
        }
    }

    let service: NornService
    let loadCompatibilityLogs: (NornService) async -> String?
    let openTrace: (String) -> Void

    @Environment(\.observabilityActions) private var actions
    @State private var range = Range.hour
    @State private var customSince = Date.now.addingTimeInterval(-3_600)
    @State private var customUntil = Date.now
    @State private var alloc = ""
    @State private var taskGroup = ""
    @State private var task = ""
    @State private var stream: NornLogFilter.Stream?
    @State private var containsInput = ""
    @State private var contains = ""
    @State private var direction = NornLogFilter.Direction.backward
    @State private var limit = 500
    @State private var isTailing = false
    @State private var reloadToken = 0
    @State private var buffer = NornLogTailBuffer()
    @State private var result: NornLogQueryResult?
    @State private var issue: NornObservabilityIssue?
    @State private var isLoading = false
    @State private var selection: Set<String> = []
    @State private var compatibilityLogs: String?
    @FocusState private var containsFocused: Bool

    private struct QueryKey: Hashable {
        var range: Range, since: Date, until: Date, alloc: String, taskGroup: String, task: String
        var stream: NornLogFilter.Stream?, contains: String, direction: NornLogFilter.Direction, limit: Int, reload: Int
    }

    private var queryKey: QueryKey {
        QueryKey(range: range, since: customSince, until: customUntil, alloc: alloc, taskGroup: taskGroup, task: task,
                 stream: stream, contains: contains, direction: direction, limit: limit, reload: reloadToken)
    }

    private var instanceAllocIDs: [String] { (service.instances ?? []).compactMap(\.allocationID) }
    private var allocOptions: [String] {
        Set(instanceAllocIDs + buffer.entries.map(\.allocID) + (alloc.isEmpty ? [] : [alloc])).filter { !$0.isEmpty }.sorted()
    }
    private var taskGroupOptions: [String] {
        Set(buffer.entries.compactMap(\.taskGroup) + (taskGroup.isEmpty ? [] : [taskGroup])).filter { !$0.isEmpty }.sorted()
    }
    private var taskOptions: [String] {
        Set(buffer.entries.map(\.task) + (task.isEmpty ? [] : [task])).filter { !$0.isEmpty }.sorted()
    }

    private func makeFilter() -> NornLogFilter {
        var filter = NornLogFilter(alloc: alloc, taskGroup: taskGroup, task: task, stream: stream, contains: contains, limit: limit, direction: direction)
        if let interval = range.interval {
            filter.since = .now.addingTimeInterval(-interval)
        } else {
            filter.since = customSince
            filter.until = customUntil
        }
        return filter
    }

    var body: some View {
        VStack(spacing: 0) {
            if issue != .unsupported {
                filterBar
                Divider()
            }
            content
            Divider()
            statusBar
        }
        .task(id: containsInput) {
            guard containsInput != contains else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { contains = containsInput }
        }
        .task(id: queryKey) { await load() }
        .task(id: isTailing) { await tail() }
        .onChange(of: direction) { buffer = NornLogTailBuffer(direction: direction) }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                if range == .custom {
                    DatePicker("Since", selection: $customSince)
                    DatePicker("Until", selection: $customUntil)
                }
                Spacer()
                Toggle(isOn: $isTailing) { Label("Live Tail", systemImage: "dot.radiowaves.right") }
                    .toggleStyle(.button)
                    .disabled(range == .custom)
                    .help("Poll for new lines every 2 seconds")
                Button { reloadToken += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isLoading)
            }
            HStack(spacing: 10) {
                menuPicker("Pod", selection: $alloc, options: allocOptions) { String($0.prefix(8)) }
                menuPicker("Group", selection: $taskGroup, options: taskGroupOptions) { $0 }
                menuPicker("Task", selection: $task, options: taskOptions) { $0 }
                Picker("Stream", selection: $stream) {
                    Text("All streams").tag(NornLogFilter.Stream?.none)
                    ForEach(NornLogFilter.Stream.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                .fixedSize()
                TextField("Contains", text: $containsInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($containsFocused)
                    .frame(minWidth: 160)
                    .onSubmit { contains = containsInput }
                Button("Find") { containsFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                    .frame(width: 0)
                Picker("Order", selection: $direction) {
                    Text("Newest first").tag(NornLogFilter.Direction.backward)
                    Text("Oldest first").tag(NornLogFilter.Direction.forward)
                }
                .fixedSize()
                Picker("Limit", selection: $limit) {
                    ForEach([100, 500, 1_000, 5_000], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func menuPicker(_ title: String, selection: Binding<String>, options: [String], label: @escaping (String) -> String) -> some View {
        Picker(title, selection: selection) {
            Text("All \(title.lowercased())s").tag("")
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if issue == .unsupported {
            compatibilityContent
        } else if let issue, buffer.entries.isEmpty {
            NornObservabilityIssueView(issue: issue, noun: "Logs") { reloadToken += 1 }
                .frame(maxHeight: .infinity)
        } else if buffer.entries.isEmpty {
            if isLoading {
                ProgressView("Loading logs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NornStateView(state: .empty(title: "No log lines", message: "Nothing matched this time range and filter.", symbol: "text.alignleft"))
                    .frame(maxHeight: .infinity)
            }
        } else {
            List(buffer.entries, selection: $selection) { entry in
                row(entry)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 16)
            .font(.system(.caption, design: .monospaced))
            .copyable(buffer.entries.filter { selection.contains($0.id) }.map(Self.plainText))
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func row(_ entry: NornLogEntry) -> some View {
        if entry.isGap {
            Label(entry.gap ?? "", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .contextMenu { Button("Copy Line") { Self.copy(entry.gap ?? "") } }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    .foregroundStyle(.secondary)
                Text(entry.shortAllocID).foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(entry.task).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                    .lineLimit(1)
                Text(entry.stream)
                    .foregroundStyle(entry.isStderr ? .red : .secondary)
                    .frame(width: 48, alignment: .leading)
                Text(entry.line)
                    .foregroundStyle(entry.isStderr ? .red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if let traceID = entry.traceID {
                    Button { openTrace(traceID) } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        .buttonStyle(.borderless)
                        .help("Open trace \(traceID)")
                }
            }
            .background(entry.isStderr ? Color.red.opacity(0.06) : .clear)
            .contextMenu {
                Button("Copy Line") { Self.copy(entry.line) }
                Button("Copy Row") { Self.copy(Self.plainText(entry)) }
                if let traceID = entry.traceID {
                    Button("Open Trace") { openTrace(traceID) }
                    Button("Copy Trace ID") { Self.copy(traceID) }
                }
            }
        }
    }

    private var compatibilityContent: some View {
        VStack(spacing: 0) {
            Text("This server predates log queries. Showing the latest allocation output (first 256 KB, not a durable archive).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            Divider()
            if let compatibilityLogs {
                ScrollView([.horizontal, .vertical]) {
                    Text(compatibilityLogs.isEmpty ? "No log output." : compatibilityLogs)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ProgressView("Loading logs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let result {
                Text(result.source)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
                    .help("Log backend")
            }
            Text("\(buffer.entries.count) lines")
            if result?.truncated == true {
                Label("Truncated: more lines match than the limit", systemImage: "scissors")
                    .foregroundStyle(.orange)
            }
            if let issue, !buffer.entries.isEmpty, case let .failed(message) = issue {
                Text(message).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        var filter = makeFilter()
        filter.direction = direction
        do {
            let response = try await actions.queryLogs(service.app, filter)
            var fresh = NornLogTailBuffer(direction: direction)
            fresh.replace(with: response.entries)
            buffer = fresh
            result = response
            issue = nil
            selection = []
        } catch is CancellationError {
            return
        } catch {
            let mapped = NornObservabilityIssue(error, feature: .logs)
            issue = mapped
            if mapped == .unsupported {
                compatibilityLogs = nil
                compatibilityLogs = await loadCompatibilityLogs(service) ?? "No app logs were returned. The app may not have a running allocation, or this credential may not have read access."
            }
        }
    }

    private func tail() async {
        guard isTailing else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            var filter = makeFilter()
            filter.until = nil
            filter.direction = .forward
            filter.sinceCursor = buffer.newestTime
            do {
                let response = try await actions.queryLogs(service.app, filter)
                buffer.append(chronological: response.entries)
                result = response
                issue = nil
            } catch is CancellationError {
                return
            } catch {
                issue = NornObservabilityIssue(error, feature: .logs)
                isTailing = false
                return
            }
        }
    }

    private static func plainText(_ entry: NornLogEntry) -> String {
        entry.isGap ? "[gap] \(entry.gap ?? "")" : "\(entry.time) \(entry.shortAllocID) \(entry.task) \(entry.stream) \(entry.line)"
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
