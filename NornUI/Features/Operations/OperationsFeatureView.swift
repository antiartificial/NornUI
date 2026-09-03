//
//  OperationsFeatureView.swift
//  NornUI
//
//  Durable operation history and immutable release evidence in one operator timeline.
//

import AppKit
import SwiftUI

nonisolated struct NornOperationalActivity: Identifiable, Hashable, Sendable {
    nonisolated enum Evidence: Hashable, Sendable {
        case operation(NornOperation)
        case release(NornRelease)
    }

    let evidence: Evidence
    let releaseLabel: String?

    var id: String {
        switch evidence {
        case let .operation(operation): "operation:\(operation.id)"
        case let .release(release): "release:\(release.sha.lowercased())"
        }
    }

    var operation: NornOperation? {
        guard case let .operation(operation) = evidence else { return nil }
        return operation
    }

    var release: NornRelease? {
        guard case let .release(release) = evidence else { return nil }
        return release
    }

    var kind: String {
        switch evidence {
        case let .operation(operation): operation.kind
        case .release: "platform.release"
        }
    }

    var title: String {
        switch evidence {
        case let .operation(operation): operation.kind.replacingOccurrences(of: ".", with: " ").capitalized
        case .release: "Platform Release"
        }
    }

    var detail: String {
        switch evidence {
        case let .operation(operation): operation.message ?? operation.id
        case let .release(release): releaseLabel ?? release.version
        }
    }

    var target: String? {
        switch evidence {
        case let .operation(operation): operation.app ?? operation.ref
        case let .release(release): release.shortSHA
        }
    }

    var targetSortValue: String { target ?? "" }

    var occurredAt: Date {
        switch evidence {
        case let .operation(operation): operation.startedAt
        case let .release(release): release.createdAt
        }
    }

    var updatedAt: Date {
        switch evidence {
        case let .operation(operation): operation.updatedAt
        case let .release(release): release.createdAt
        }
    }

    var elapsedSeconds: TimeInterval? {
        guard case let .operation(operation) = evidence else { return nil }
        return max(0, (operation.finishedAt ?? operation.updatedAt).timeIntervalSince(operation.startedAt))
    }

    var elapsedDescription: String {
        guard let elapsedSeconds else { return "Artifact" }
        return Duration.seconds(elapsedSeconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    var elapsedSortValue: TimeInterval { elapsedSeconds ?? -1 }

    var statusLabel: String {
        switch evidence {
        case let .operation(operation): operation.status.rawValue.capitalized
        case let .release(release): release.current ? "Current" : "Available"
        }
    }

    var statusRank: Int {
        switch evidence {
        case let .operation(operation):
            switch operation.status {
            case .running: 0
            case .queued: 1
            case .failed: 2
            case .canceled: 3
            case .succeeded: 4
            }
        case let .release(release): release.current ? 5 : 6
        }
    }

    var statusSortValue: String { String(format: "%02d-%@", statusRank, statusLabel) }

    var searchableTerms: [String] {
        switch evidence {
        case let .operation(operation):
            return [operation.kind, operation.app, operation.ref, operation.id, operation.message]
                .compactMap { $0?.localizedLowercase }
        case let .release(release):
            return ["platform.release", "release", releaseLabel, release.version, release.sha, release.path]
                .compactMap { $0?.localizedLowercase }
        }
    }

    static func timeline(operations: [NornOperation], releases: [NornRelease]) -> [NornOperationalActivity] {
        let canonicalReleases = NornRelease.canonicalHistory(releases)
        return (
            operations.map { NornOperationalActivity(evidence: .operation($0), releaseLabel: nil) }
                + canonicalReleases.map {
                    NornOperationalActivity(
                        evidence: .release($0),
                        releaseLabel: $0.displayLabel(in: canonicalReleases)
                    )
                }
        )
        .sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

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

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All kinds"
        case platform = "Platform"
        case application = "Applications"
        case host = "Host"
        case fleet = "Fleet"
        case other = "Other"

        var id: String { rawValue }

        func includes(_ activity: NornOperationalActivity) -> Bool {
            let kind = activity.kind.lowercased()
            return switch self {
            case .all: true
            case .platform: kind.hasPrefix("platform.")
            case .application: kind.hasPrefix("app.")
            case .host: kind.hasPrefix("host.")
            case .fleet: kind.hasPrefix("fleet.")
            case .other:
                !kind.hasPrefix("platform.")
                    && !kind.hasPrefix("app.")
                    && !kind.hasPrefix("host.")
                    && !kind.hasPrefix("fleet.")
            }
        }
    }

    private enum StartedFilter: String, CaseIterable, Identifiable {
        case all = "Any time"
        case day = "Past 24 hours"
        case week = "Past 7 days"
        case month = "Past 30 days"

        var id: String { rawValue }

        func includes(_ activity: NornOperationalActivity, now: Date = Date()) -> Bool {
            let interval: TimeInterval?
            switch self {
            case .all: interval = nil
            case .day: interval = 86_400
            case .week: interval = 7 * 86_400
            case .month: interval = 30 * 86_400
            }
            guard let interval else { return true }
            return activity.occurredAt >= now.addingTimeInterval(-interval)
        }
    }

    private enum ElapsedFilter: String, CaseIterable, Identifiable {
        case all = "Any duration"
        case underMinute = "Under 1 minute"
        case oneToFiveMinutes = "1–5 minutes"
        case overFiveMinutes = "Over 5 minutes"
        case artifacts = "Release artifacts"

        var id: String { rawValue }

        func includes(_ activity: NornOperationalActivity) -> Bool {
            switch self {
            case .all: true
            case .underMinute: activity.elapsedSeconds.map { $0 < 60 } ?? false
            case .oneToFiveMinutes: activity.elapsedSeconds.map { $0 >= 60 && $0 <= 300 } ?? false
            case .overFiveMinutes: activity.elapsedSeconds.map { $0 > 300 } ?? false
            case .artifacts: activity.release != nil
            }
        }
    }

    let operations: [NornOperation]
    let releases: [NornRelease]
    let observedAt: Date?
    var onRefresh: () -> Void = {}
    var onOpenOperation: (NornOperation) -> Void = { _ in }
    var onCopyOperationID: (NornOperation) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: Filter = .all
    @State private var kindFilter: KindFilter = .all
    @State private var targetFilter: String?
    @State private var startedFilter: StartedFilter = .all
    @State private var elapsedFilter: ElapsedFilter = .all
    @State private var sortOrder = [KeyPathComparator(\NornOperationalActivity.occurredAt, order: .reverse)]
    @State private var searchText = ""
    @State private var selection: String?

    init(
        snapshot: NornDashboardSnapshot,
        onRefresh: @escaping () -> Void = {},
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onCopyOperationID: @escaping (NornOperation) -> Void = { _ in }
    ) {
        self.operations = snapshot.operations
        self.releases = NornRelease.canonicalHistory(snapshot.releases)
        self.observedAt = snapshot.observedAt
        self.onRefresh = onRefresh
        self.onOpenOperation = onOpenOperation
        self.onCopyOperationID = onCopyOperationID
    }

    init(
        operations: [NornOperation],
        releases: [NornRelease] = [],
        observedAt: Date? = nil,
        onRefresh: @escaping () -> Void = {},
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onCopyOperationID: @escaping (NornOperation) -> Void = { _ in }
    ) {
        self.operations = operations
        self.releases = NornRelease.canonicalHistory(releases)
        self.observedAt = observedAt
        self.onRefresh = onRefresh
        self.onOpenOperation = onOpenOperation
        self.onCopyOperationID = onCopyOperationID
    }

    private var activities: [NornOperationalActivity] {
        NornOperationalActivity.timeline(operations: operations, releases: releases)
    }

    private var filteredActivities: [NornOperationalActivity] {
        activities
            .filter { activity in
                guard let operation = activity.operation else { return filter == .all }
                return filter.includes(operation)
            }
            .filter(kindFilter.includes)
            .filter { targetFilter == nil || $0.target == targetFilter }
            .filter { startedFilter.includes($0) }
            .filter { elapsedFilter.includes($0) }
            .filter { activity in
                guard !searchText.isEmpty else { return true }
                return activity.searchableTerms.contains { $0.contains(searchText.localizedLowercase) }
            }
            .sorted(using: sortOrder)
    }

    private var selectedActivity: NornOperationalActivity? {
        activities.first { $0.id == selection }
    }

    private var targets: [String] {
        Set(activities.compactMap(\.target)).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    var body: some View {
        VStack(spacing: 0) {
            operationSummary
                .padding(.leading, 22)
                .padding(.trailing, 24)
                .padding(.vertical, 10)

            Divider()

            GeometryReader { proxy in
                if proxy.size.width >= 700 {
                    HSplitView {
                        operationList
                            .frame(minWidth: 390, idealWidth: 700)
                            .frame(maxHeight: .infinity, alignment: .topLeading)

                        receiptInspector
                            .frame(minWidth: 220, idealWidth: 340, maxWidth: 420)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    VSplitView {
                        operationList
                            .frame(minHeight: 250, idealHeight: 430)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        receiptInspector
                            .frame(minHeight: 170, idealHeight: 250)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
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
                .accessibilityHint("Fetches the newest durable operation receipts and release artifacts")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: filteredActivities)
    }

    private var operationSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                summaryIdentity
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                summaryMetrics
            }

            VStack(alignment: .leading, spacing: 10) {
                summaryIdentity
                summaryMetrics
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var summaryIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Operations")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("operations.header")
            Text(summarySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var summaryMetrics: some View {
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

    private var summarySubtitle: String {
        let evidence = "\(operations.count) durable receipts · \(releases.count) release artifacts"
        guard let observedAt else { return evidence }
        return "\(evidence) · observed \(observedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var operationList: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                wideFilterBar
                compactFilterBar
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if filteredActivities.isEmpty {
                ContentUnavailableView(
                    "No matching activity",
                    systemImage: "checkmark.circle",
                    description: Text("Try a different filter or search term.")
                )
            } else {
                Table(filteredActivities, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Operation", value: \.title) {
                        ActivityNameCell(activity: $0)
                    }
                    .width(min: 180, ideal: 230)

                    TableColumn("Status", value: \.statusSortValue) {
                        ActivityStatusBadge(activity: $0)
                    }
                    .width(min: 96, ideal: 108, max: 120)

                    TableColumn("Target", value: \.targetSortValue) {
                        Text($0.target ?? "—")
                            .lineLimit(1)
                            .foregroundStyle($0.target == nil ? .tertiary : .secondary)
                    }
                    .width(min: 110, ideal: 140)

                    TableColumn("Started", value: \.occurredAt) {
                        Text($0.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 126, ideal: 140)

                    TableColumn("Elapsed", value: \.elapsedSortValue) {
                        Text($0.elapsedDescription)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 104)
                }
                .contextMenu(forSelectionType: String.self) { identifiers in
                    if let identifier = identifiers.first,
                       let activity = activities.first(where: { $0.id == identifier }) {
                        switch activity.evidence {
                        case let .operation(operation):
                            Button("Open Receipt") { onOpenOperation(operation) }
                            Button("Copy Operation ID") { copyID(operation) }
                            Divider()
                            Button("Copy Reference") { copy(operation.ref ?? operation.id) }
                        case let .release(release):
                            Button("Copy Release SHA") { copy(release.sha) }
                            Button("Copy Version") { copy(activity.releaseLabel ?? release.version) }
                        }
                    }
                } primaryAction: { identifiers in
                    if let identifier = identifiers.first,
                       let operation = activities.first(where: { $0.id == identifier })?.operation {
                        onOpenOperation(operation)
                    }
                }
                .accessibilityLabel("Operations and release evidence timeline")
                .accessibilityIdentifier("operations.timeline")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var wideFilterBar: some View {
        HStack(spacing: 10) {
            filterLabel

            Picker("Operation filter", selection: $filter) {
                ForEach(Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .accessibilityLabel("Operation filter")

            columnFilters

            Spacer(minLength: 8)

            searchField
            shownCount
        }
    }

    private var compactFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                filterLabel

                Picker("Operation filter", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Operation filter")
                .accessibilityIdentifier("operations.compact-filter")

                columnFilters

                Spacer(minLength: 8)

                shownCount
            }

            searchField
        }
    }

    private var filterLabel: some View {
        Text("Show")
            .frame(width: 36, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("operations.show-label")
    }

    private var searchField: some View {
        TextField("Search activity", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, idealWidth: 180, maxWidth: 220)
            .accessibilityIdentifier("operations.search")
    }

    private var shownCount: some View {
        Text("\(filteredActivities.count) shown")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var activeColumnFilterCount: Int {
        (kindFilter == .all ? 0 : 1)
            + (targetFilter == nil ? 0 : 1)
            + (startedFilter == .all ? 0 : 1)
            + (elapsedFilter == .all ? 0 : 1)
    }

    private var columnFilters: some View {
        Menu {
            Picker("Operation", selection: $kindFilter) {
                ForEach(KindFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            Picker("Target", selection: $targetFilter) {
                Text("All targets").tag(String?.none)
                ForEach(targets, id: \.self) { target in
                    Text(target).tag(String?.some(target))
                }
            }

            Picker("Started", selection: $startedFilter) {
                ForEach(StartedFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            Picker("Elapsed", selection: $elapsedFilter) {
                ForEach(ElapsedFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            if activeColumnFilterCount > 0 {
                Divider()
                Button("Clear Column Filters") {
                    kindFilter = .all
                    targetFilter = nil
                    startedFilter = .all
                    elapsedFilter = .all
                }
            }
        } label: {
            Label(
                activeColumnFilterCount == 0 ? "Columns" : "Columns \(activeColumnFilterCount)",
                systemImage: activeColumnFilterCount == 0
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Column filters")
        .accessibilityValue(activeColumnFilterCount == 0 ? "none" : "\(activeColumnFilterCount) active")
        .accessibilityIdentifier("operations.column-filters")
    }

    private var receiptInspector: some View {
        ActivityReceiptInspector(
            activity: selectedActivity,
            onOpen: onOpenOperation,
            onCopyID: copyID
        )
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

private struct ActivityNameCell: View {
    let activity: NornOperationalActivity

    var body: some View {
        HStack(spacing: 7) {
            if activity.release != nil {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.body.weight(.medium))
                Text(activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(activity.release == nil ? "operations.operation-row" : "operations.release-row")
    }
}

private struct ActivityStatusBadge: View {
    let activity: NornOperationalActivity

    var body: some View {
        if let operation = activity.operation {
            OperationStatusBadge(status: operation.status)
        } else if let release = activity.release {
            Label(release.current ? "Current" : "Available", systemImage: release.current ? "checkmark.seal.fill" : "shippingbox")
                .font(.caption.weight(.medium))
                .foregroundStyle(release.current ? Color.green : Color.secondary)
                .accessibilityLabel("Release status: \(release.current ? "current" : "available")")
        }
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

private struct ActivityReceiptInspector: View {
    let activity: NornOperationalActivity?
    let onOpen: (NornOperation) -> Void
    let onCopyID: (NornOperation) -> Void

    var body: some View {
        switch activity?.evidence {
        case let .operation(operation):
            OperationReceiptInspector(operation: operation, onOpen: onOpen, onCopyID: onCopyID)
        case let .release(release):
            ReleaseEvidenceInspector(release: release, displayLabel: activity?.releaseLabel ?? release.version)
        case nil:
            ContentUnavailableView(
                "Select activity",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Its durable receipt or immutable release evidence will appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ReleaseEvidenceInspector: View {
    let release: NornRelease
    let displayLabel: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Release evidence")
                            .font(.headline)
                        Text("platform.release")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(release.current ? "Current" : "Available", systemImage: release.current ? "checkmark.seal.fill" : "shippingbox")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(release.current ? Color.green : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 9) {
                    ReceiptRow(label: "Release", value: displayLabel)
                    ReceiptRow(label: "SHA", value: release.sha, monospaced: true)
                    ReceiptRow(label: "Recorded", value: release.createdAt.formatted(date: .abbreviated, time: .standard))
                    ReceiptRow(label: "Path", value: release.path, monospaced: true)
                }

                ReceiptSection(title: "Artifact history", symbol: "shippingbox") {
                    Text("This immutable artifact was observed in release history. It is evidence of a built or installed release, not a durable queued operation receipt.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Copy SHA") { copy(release.sha) }
                    Button("Copy Version") { copy(displayLabel) }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .accessibilityLabel("Release evidence for \(displayLabel)")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
