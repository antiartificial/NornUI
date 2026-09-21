import SwiftUI

/// Read-only view over the control-plane mutation-audit log
/// (GET /api/v1/audit/mutations). Value-in / closures-out, mirroring the other
/// feature views; the caller owns fetching into `events`.
struct AuditFeatureView: View {
    let events: [MutationAuditEvent]
    var canRead: Bool = true
    var onRefresh: () -> Void = {}

    @State private var searchText = ""

    private var filteredEvents: [MutationAuditEvent] {
        MutationAuditEvent.filter(events, query: searchText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .padding(22)
            .frame(maxWidth: 1_240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Audit")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search audit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) {
                    Label("Refresh Audit", systemImage: "arrow.clockwise")
                }
                .help("Reload the mutation-audit log")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AUDIT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Signed record of every control-plane mutation")
                .font(.title2.weight(.semibold))
            Text("Each row is a signed receipt for a mutating API request — who, which route, the outcome, and the signature integrity.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("audit.header")
    }

    @ViewBuilder
    private var content: some View {
        if !canRead {
            ContentUnavailableView(
                "Audit Requires Admin",
                systemImage: "lock.shield",
                description: Text("This connection does not grant the admin scope needed to read the mutation-audit log.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if filteredEvents.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Audit Events" : "No Matching Events",
                systemImage: "checklist",
                description: Text(searchText.isEmpty ? "No control-plane mutations have been recorded yet." : "Try a different audit search.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            GroupBox("Mutations") {
                VStack(spacing: 0) {
                    ForEach(Array(filteredEvents.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        AuditEventRow(event: event)
                            .padding(.vertical, 7)
                    }
                }
            }
            .accessibilityIdentifier("audit.list")
        }
    }
}

private struct AuditEventRow: View {
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
