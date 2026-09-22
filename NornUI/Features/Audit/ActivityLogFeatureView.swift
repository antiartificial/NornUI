import SwiftUI

/// The Activity Log: a scope-graded ledger of what happened across the cell.
/// Pods and Cell ride the operator-facing beacon feed (api:read); Receipts is
/// the admin signed control-plane mutation-audit. Value-in / closures-out.
struct ActivityLogFeatureView: View {
    let beaconEvents: [NornBeaconEvent]
    let auditEvents: [MutationAuditEvent]
    var canReadActivity: Bool = true
    var canReadAudit: Bool = false
    var onRefresh: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case pods, cell, receipts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pods: "Pods"
            case .cell: "Cell"
            case .receipts: "Receipts"
            }
        }
    }

    @State private var tab: Tab = .pods
    @State private var searchText = ""

    private var podEvents: [NornBeaconEvent] {
        NornBeaconEvent.filter(beaconEvents.filter { !$0.isCellScoped }, query: searchText)
    }
    private var cellEvents: [NornBeaconEvent] {
        NornBeaconEvent.filter(beaconEvents.filter { $0.isCellScoped }, query: searchText)
    }
    private var receipts: [MutationAuditEvent] {
        MutationAuditEvent.filter(auditEvents, query: searchText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                content
            }
            .padding(22)
            .frame(maxWidth: 1_240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Activity Log")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload the activity log")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ACTIVITY LOG")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("What happened across your workloads and cell")
                .font(.title2.weight(.semibold))
            Text("Pods shows actions on your workloads — restart, scale, secret and config changes. Cell shows cluster events. Receipts is the signed control-plane audit.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("activity-log.header")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .pods:
            if canReadActivity {
                beaconList(podEvents, empty: "No Pod Activity", emptyHint: "No actions recorded on workloads yet.")
            } else {
                unavailable("Activity Unavailable", "This connection cannot read workload activity.", "lock")
            }
        case .cell:
            if canReadActivity {
                beaconList(cellEvents, empty: "No Cell Activity", emptyHint: "No cluster-level events yet.")
            } else {
                unavailable("Activity Unavailable", "This connection cannot read cell activity.", "lock")
            }
        case .receipts:
            if canReadAudit {
                auditList(receipts)
            } else {
                unavailable("Receipts Require Admin", "The signed control-plane audit needs the admin scope.", "lock.shield")
            }
        }
    }

    private func unavailable(_ title: String, _ message: String, _ symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder
    private func beaconList(_ events: [NornBeaconEvent], empty: String, emptyHint: String) -> some View {
        if events.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? empty : "No Matching Events",
                systemImage: "list.bullet.rectangle",
                description: Text(searchText.isEmpty ? emptyHint : "Try a different search.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        BeaconActivityRow(event: event)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func auditList(_ events: [MutationAuditEvent]) -> some View {
        if events.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Receipts" : "No Matching Receipts",
                systemImage: "doc.text.magnifyingglass",
                description: Text(searchText.isEmpty ? "No control-plane mutations recorded." : "Try a different search.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        AuditReceiptRow(event: event)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
    }
}

private struct BeaconActivityRow: View {
    let event: NornBeaconEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            NornStatusGlyph(status: NornStatus(beaconSeverity: event.severity), size: 12, pulsesWhenActive: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.callout)
                HStack(spacing: 8) {
                    Text(event.type).font(.caption.monospaced())
                    if let app = event.app, !app.isEmpty { Text("· \(app)") }
                    if let actor = event.actor { Text("· by \(actor)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let body = event.body, !body.isEmpty {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.type), \(event.title)")
    }
}

private struct AuditReceiptRow: View {
    let event: MutationAuditEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            NornStatusGlyph(status: NornStatus(auditOutcome: event.outcome), size: 12, pulsesWhenActive: false)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(event.method) \(event.path)")
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(event.principalSubject)
                    Text("·")
                    Text(event.outcome)
                    if event.status > 0 {
                        Text("· \(event.status)")
                    }
                    if let integrity = event.integrity {
                        Text("· \(integrity)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(event.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.method) \(event.path), \(event.outcome), by \(event.principalSubject)")
    }
}
