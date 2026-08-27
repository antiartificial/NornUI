import SwiftUI

struct ActivityFeatureView: View {
    let snapshot: NornDashboardSnapshot
    var onOpenOperation: (NornOperation) -> Void = { _ in }
    var onShowApps: () -> Void = {}

    @State private var searchText = ""
    @State private var expandedStates: Set<String> = []

    private var activeOperations: [NornOperation] {
        matchingOperations(snapshot.activeOperations)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recentOperations: [NornOperation] {
        matchingOperations(snapshot.operations.filter { !$0.status.isActive })
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var serviceGroups: [ServiceStateGroup] {
        let matching = snapshot.services.filter(matches)
        let grouped = Dictionary(grouping: matching) { $0.status.lowercased() }
        return grouped.map { status, services in
            ServiceStateGroup(
                status: status,
                services: services.sorted {
                    ($0.app, $0.process, $0.name) < ($1.app, $1.process, $1.name)
                }
            )
        }
        .sorted {
            let left = serviceStatusRank($0.status)
            let right = serviceStatusRank($1.status)
            return left == right ? $0.status < $1.status : left < right
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summary

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        operationsPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        servicesPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(spacing: 18) {
                        operationsPanel
                        servicesPanel
                    }
                }

                recentPanel
            }
            .padding(22)
            .frame(maxWidth: 1_240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Activity")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search activity")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ACTIVITY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("What Norn is doing and what it currently observes")
                .font(.title2.weight(.semibold))
            Text("Expand a health state to see the services behind the rollup, or open an operation to inspect its durable receipt.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("activity.header")
    }

    private var summary: some View {
        HStack(spacing: 12) {
            ActivitySummary(
                title: "Active operations",
                value: "\(snapshot.activeOperations.count)",
                status: snapshot.activeOperations.isEmpty ? .neutral : .active
            )
            ActivitySummary(
                title: "Passing services",
                value: "\(snapshot.passingServices) / \(snapshot.services.count)",
                status: snapshot.passingServices == snapshot.services.count ? .healthy : .attention
            )
        }
        .accessibilityIdentifier("activity.summary")
    }

    private var operationsPanel: some View {
        GroupBox("In Flight") {
            if activeOperations.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Active Operations" : "No Matching Operations",
                    systemImage: "checkmark.circle",
                    description: Text(searchText.isEmpty ? "The durable operation queue is settled." : "Try a different activity search.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeOperations.enumerated()), id: \.element.id) { index, operation in
                        Button { onOpenOperation(operation) } label: {
                            OperationActivityRow(operation: operation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity.operation.\(operation.id)")
                        if index < activeOperations.count - 1 { Divider() }
                    }
                }
                .padding(.top, 5)
            }
        }
        .accessibilityIdentifier("activity.in-flight")
    }

    private var servicesPanel: some View {
        GroupBox("Service Health") {
            if serviceGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(serviceGroups) { group in
                        DisclosureGroup(isExpanded: expansionBinding(for: group.status)) {
                            VStack(spacing: 0) {
                                ForEach(group.services) { service in
                                    Button(action: onShowApps) {
                                        ServiceActivityRow(service: service)
                                            .accessibilityElement(children: .combine)
                                            .accessibilityIdentifier("activity.service.\(service.id)")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(service.app), \(service.process), \(service.status)")
                                }
                            }
                            .padding(.leading, 8)
                        } label: {
                            HStack(spacing: 8) {
                                NornStatusGlyph(status: NornStatus(serviceStatus: group.status), size: 12, pulsesWhenActive: false)
                                Text(group.status.capitalized)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(group.services.count)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                        }
                        .accessibilityIdentifier("activity.services.\(group.status)")
                        if group.id != serviceGroups.last?.id { Divider() }
                    }
                }
                .padding(.top, 5)
            }
        }
        .accessibilityIdentifier("activity.service-health")
    }

    private var recentPanel: some View {
        GroupBox("Recent Receipts") {
            if recentOperations.isEmpty {
                Text(searchText.isEmpty ? "No completed operations have been observed." : "No recent receipts match the search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(recentOperations.prefix(12).enumerated()), id: \.element.id) { index, operation in
                        Button { onOpenOperation(operation) } label: {
                            OperationActivityRow(operation: operation)
                        }
                        .buttonStyle(.plain)
                        if index < min(recentOperations.count, 12) - 1 { Divider() }
                    }
                }
                .padding(.top, 5)
            }
        }
        .accessibilityIdentifier("activity.recent")
    }

    private func matchingOperations(_ operations: [NornOperation]) -> [NornOperation] {
        guard !searchText.isEmpty else { return operations }
        return operations.filter { operation in
            operation.kind.localizedStandardContains(searchText)
                || operation.app?.localizedStandardContains(searchText) == true
                || operation.message?.localizedStandardContains(searchText) == true
                || operation.status.rawValue.localizedStandardContains(searchText)
        }
    }

    private func matches(_ service: NornService) -> Bool {
        guard !searchText.isEmpty else { return true }
        return service.app.localizedStandardContains(searchText)
            || service.process.localizedStandardContains(searchText)
            || service.name.localizedStandardContains(searchText)
            || service.status.localizedStandardContains(searchText)
            || service.reachability.exposure.localizedStandardContains(searchText)
    }

    private func expansionBinding(for status: String) -> Binding<Bool> {
        Binding(
            get: { expandedStates.contains(status) },
            set: { isExpanded in
                if isExpanded { expandedStates.insert(status) }
                else { expandedStates.remove(status) }
            }
        )
    }

    private func serviceStatusRank(_ status: String) -> Int {
        switch NornStatus(serviceStatus: status) {
        case .critical: 0
        case .attention: 1
        case .active: 2
        case .healthy: 3
        case .neutral, .offline: 4
        }
    }
}

private struct ServiceStateGroup: Identifiable {
    let status: String
    let services: [NornService]
    var id: String { status }
}

private struct ActivitySummary: View {
    let title: String
    let value: String
    let status: NornStatus

    var body: some View {
        HStack(spacing: 10) {
            NornStatusGlyph(status: status, size: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OperationActivityRow: View {
    let operation: NornOperation

    var body: some View {
        HStack(spacing: 10) {
            NornStatusGlyph(status: NornStatus(operationStatus: operation.status), size: 13)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(operation.kind)
                        .fontWeight(.medium)
                    if let app = operation.app {
                        Text(app)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(operation.message ?? operation.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(operation.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 9)
    }
}

private struct ServiceActivityRow: View {
    let service: NornService

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.app)
                    .fontWeight(.medium)
                Text("\(service.process) · \(service.reachability.exposure)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let count = service.instances?.count, count > 0 {
                Text("\(count) allocation\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 7)
    }
}

#Preview {
    ActivityFeatureView(snapshot: NornFixtures.snapshot)
        .frame(width: 980, height: 700)
}
