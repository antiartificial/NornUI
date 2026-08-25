//
//  OperationsFeatureView.swift
//  NornUI
//
//  Durable operation history, with receipts that remain useful after the app closes.
//

import AppKit
import SwiftUI

struct OperationsFeatureView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case succeeded = "Succeeded"
        case attention = "Needs attention"

        var id: String { rawValue }

        func includes(_ operation: NornOperation) -> Bool {
            switch self {
            case .all: true
            case .active: operation.status.isActive
            case .succeeded: operation.status == .succeeded
            case .attention: operation.status == .failed || operation.status == .canceled
            }
        }
    }

    let operations: [NornOperation]
    let observedAt: Date?
    var onRefresh: () -> Void = {}
    var onOpenOperation: (NornOperation) -> Void = { _ in }
    var onCopyOperationID: (NornOperation) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var selection: String?

    init(
        snapshot: NornDashboardSnapshot,
        onRefresh: @escaping () -> Void = {},
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onCopyOperationID: @escaping (NornOperation) -> Void = { _ in }
    ) {
        self.operations = snapshot.operations
        self.observedAt = snapshot.observedAt
        self.onRefresh = onRefresh
        self.onOpenOperation = onOpenOperation
        self.onCopyOperationID = onCopyOperationID
    }

    init(
        operations: [NornOperation],
        observedAt: Date? = nil,
        onRefresh: @escaping () -> Void = {},
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onCopyOperationID: @escaping (NornOperation) -> Void = { _ in }
    ) {
        self.operations = operations
        self.observedAt = observedAt
        self.onRefresh = onRefresh
        self.onOpenOperation = onOpenOperation
        self.onCopyOperationID = onCopyOperationID
    }

    private var filteredOperations: [NornOperation] {
        operations
            .filter(filter.includes)
            .filter { operation in
                guard !searchText.isEmpty else { return true }
                let terms = [operation.kind, operation.app, operation.ref, operation.id, operation.message]
                    .compactMap { $0?.localizedLowercase }
                return terms.contains { $0.contains(searchText.localizedLowercase) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var selectedOperation: NornOperation? {
        operations.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            operationSummary
                .padding(.leading, 22)
                .padding(.trailing, 24)
                .padding(.vertical, 10)

            Divider()

            HSplitView {
                operationList
                    .frame(minWidth: 450, idealWidth: 700)
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                OperationReceiptInspector(
                    operation: selectedOperation,
                    onOpen: onOpenOperation,
                    onCopyID: copyID
                )
                .frame(minWidth: 220, idealWidth: 340, maxWidth: 420)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Operations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) {
                    Label("Refresh Operations", systemImage: "arrow.clockwise")
                }
                .accessibilityHint("Fetches the newest durable operation receipts")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: filteredOperations)
    }

    private var operationSummary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Operations")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("operations.header")
                Text(summarySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 16)

            HStack(spacing: 16) {
                OperationMetric(value: operations.filter(\.status.isActive).count, title: "Active", symbol: "arrow.triangle.2.circlepath")
                OperationMetric(value: operations.filter { $0.status == .succeeded }.count, title: "Complete", symbol: "checkmark.circle")
                OperationMetric(value: operations.filter { $0.status == .failed || $0.status == .canceled }.count, title: "Attention", symbol: "exclamationmark.triangle")
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(operations.filter(\.status.isActive).count) active, "
                    + "\(operations.filter { $0.status == .succeeded }.count) complete, "
                    + "\(operations.filter { $0.status == .failed || $0.status == .canceled }.count) need attention"
            )
            .accessibilityIdentifier("operations.metrics")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var summarySubtitle: String {
        guard let observedAt else { return "Durable activity and receipts" }
        return "Observed \(observedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var operationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Show")
                    .frame(width: 36, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("operations.show-label")

                Picker("Operation filter", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .accessibilityLabel("Operation filter")

                Spacer(minLength: 8)

                Text("\(filteredOperations.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if filteredOperations.isEmpty {
                ContentUnavailableView(
                    "No matching operations",
                    systemImage: "checkmark.circle",
                    description: Text("Try a different filter or search term.")
                )
            } else {
                Table(filteredOperations, selection: $selection) {
                    TableColumn("Operation") { operation in
                        OperationNameCell(operation: operation)
                    }
                    .width(min: 180, ideal: 230)

                    TableColumn("Status") { operation in
                        OperationStatusBadge(status: operation.status)
                    }
                    .width(min: 96, ideal: 108, max: 120)

                    TableColumn("Target") { operation in
                        Text(operation.app ?? operation.ref ?? "—")
                            .lineLimit(1)
                            .foregroundStyle(operation.app == nil && operation.ref == nil ? .tertiary : .secondary)
                    }
                    .width(min: 110, ideal: 140)

                    TableColumn("Started") { operation in
                        Text(operation.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 126, ideal: 140)

                    TableColumn("Elapsed") { operation in
                        Text(operation.elapsedDescription)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 72, ideal: 82)
                }
                .contextMenu(forSelectionType: String.self) { identifiers in
                    if let identifier = identifiers.first,
                       let operation = operations.first(where: { $0.id == identifier }) {
                        Button("Open Receipt") { onOpenOperation(operation) }
                        Button("Copy Operation ID") { copyID(operation) }
                        Divider()
                        Button("Copy Reference") { copy(operation.ref ?? operation.id) }
                    }
                } primaryAction: { identifiers in
                    if let identifier = identifiers.first,
                       let operation = operations.first(where: { $0.id == identifier }) {
                        onOpenOperation(operation)
                    }
                }
                .accessibilityLabel("Operation timeline")
                .accessibilityIdentifier("operations.timeline")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search operations")
    }

    private func copyID(_ operation: NornOperation) {
        copy(operation.id)
        onCopyOperationID(operation)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct OperationMetric: View {
    let value: Int
    let title: String
    let symbol: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label("\(value)", systemImage: symbol)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title) operations")
    }
}

private struct OperationNameCell: View {
    let operation: NornOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(operation.kind.replacingOccurrences(of: ".", with: " ").capitalized)
                .font(.body.weight(.medium))
            Text(operation.message ?? operation.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OperationStatusBadge: View {
    let status: NornOperationStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch status {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .queued: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .canceled: .orange
        }
    }

    var body: some View {
        Label(status.rawValue.capitalized, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.45), isActive: status == .running && !reduceMotion)
            .accessibilityLabel("Status: \(status.rawValue)")
    }
}

private struct OperationReceiptInspector: View {
    let operation: NornOperation?
    let onOpen: (NornOperation) -> Void
    let onCopyID: (NornOperation) -> Void

    var body: some View {
        Group {
            if let operation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Receipt")
                                    .font(.headline)
                                Text(operation.kind)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            OperationStatusBadge(status: operation.status)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            ReceiptRow(label: "Operation ID", value: operation.id, monospaced: true)
                            ReceiptRow(label: "Started", value: operation.startedAt.formatted(date: .abbreviated, time: .standard))
                            ReceiptRow(label: "Elapsed", value: operation.elapsedDescription)
                            if let finishedAt = operation.finishedAt {
                                ReceiptRow(label: "Finished", value: finishedAt.formatted(date: .abbreviated, time: .standard))
                            }
                            if let app = operation.app { ReceiptRow(label: "App", value: app) }
                            if let ref = operation.ref { ReceiptRow(label: "Reference", value: ref, monospaced: true) }
                            if let risk = operation.risk { ReceiptRow(label: "Risk", value: risk.capitalized) }
                            if let attempts = operation.attempts {
                                ReceiptRow(label: "Attempts", value: "\(attempts)/\(operation.maxAttempts ?? attempts)")
                            }
                        }

                        if let message = operation.message {
                            ReceiptSection(title: "Result", symbol: "text.quote") {
                                Text(message)
                                    .textSelection(.enabled)
                            }
                        }

                        if let error = operation.lastError {
                            ReceiptSection(title: "Error", symbol: "exclamationmark.triangle") {
                                Text(error)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }

                        if let payload = operation.payload, !payload.isEmpty {
                            ReceiptSection(title: "Request", symbol: "arrow.up.doc") {
                                Text(JSONValue.object(payload).receiptText)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let metadata = operation.metadata, !metadata.isEmpty {
                            ReceiptSection(title: "Metadata", symbol: "curlybraces") {
                                Text(JSONValue.object(metadata).receiptText)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        HStack {
                            Button("Open Full Receipt") { onOpen(operation) }
                            Button("Copy ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(operation.id, forType: .string)
                                onCopyID(operation)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .accessibilityLabel("Receipt for \(operation.kind)")
            } else {
                ContentUnavailableView(
                    "Select an operation",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Its durable receipt will appear here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ReceiptSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ReceiptRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private extension NornOperation {
    var elapsedDescription: String {
        let end = finishedAt ?? updatedAt
        let seconds = max(0, end.timeIntervalSince(startedAt))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}

private extension JSONValue {
    var receiptText: String {
        switch self {
        case let .string(value): return "\"\(value)\""
        case let .number(value): return value.formatted()
        case let .bool(value): return value ? "true" : "false"
        case .null: return "null"
        case let .array(values): return "[\(values.map(\.receiptText).joined(separator: ", "))]"
        case let .object(values):
            let entries = values.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.receiptText)" }
            return "{\n  \(entries.joined(separator: ",\n  "))\n}"
        }
    }
}

#Preview("Operations") {
    OperationsFeatureView(snapshot: NornFixtures.snapshot)
        .frame(width: 1_150, height: 690)
}
