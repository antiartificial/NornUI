import SwiftUI

/// The calm landing surface for a selected Norn profile.
///
/// It deliberately accepts a snapshot rather than owning transport state so the app shell can
/// reconcile HTTP and event-stream updates independently of rendering.
struct OverviewView: View {
    let snapshot: NornDashboardSnapshot?
    let connectionState: NornConnectionState
    var isRefreshing: Bool = false
    var onRefresh: () -> Void = {}
    var onShowServices: () -> Void = {}
    var onShowOperations: () -> Void = {}
    var onShowReleases: () -> Void = {}
    var onShowHost: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        snapshot: NornDashboardSnapshot?,
        connectionState: NornConnectionState,
        isRefreshing: Bool = false,
        onRefresh: @escaping () -> Void = {},
        onShowServices: @escaping () -> Void = {},
        onShowOperations: @escaping () -> Void = {},
        onShowReleases: @escaping () -> Void = {},
        onShowHost: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.connectionState = connectionState
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.onShowServices = onShowServices
        self.onShowOperations = onShowOperations
        self.onShowReleases = onShowReleases
        self.onShowHost = onShowHost
    }

    var body: some View {
        Group {
            if let snapshot {
                overview(snapshot)
            } else {
                unavailableState
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) {
                    Label("Refresh Overview", systemImage: "arrow.clockwise")
                }
                .help("Refresh Overview")
                .disabled(isRefreshing || isOffline)
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private func overview(_ snapshot: NornDashboardSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(snapshot)
                if isOffline {
                    staleBanner(snapshot)
                }
                pulseSection(snapshot)
                lowerSection(snapshot)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1_220, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var unavailableState: some View {
        switch connectionState {
        case let .offline(reason):
            NornStateView(
                state: .error(
                    title: "Norn is unavailable",
                    message: reason.isEmpty ? "Check your connection or choose another profile, then try again." : reason
                ),
                retry: onRefresh
            )
        case .idle:
            NornStateView(
                state: .empty(
                    title: "Choose a Norn profile",
                    message: "A profile connects this control room to a Norn control plane.",
                    symbol: "server.rack"
                )
            )
        case .connecting, .reconnecting, .online:
            NornStateView(state: .loading)
        }
    }

    private func header(_ snapshot: NornDashboardSnapshot) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    NornStatusGlyph(status: overallStatus(snapshot), size: 18)
                    Text(overallStatus(snapshot).title)
                        .font(.title2.weight(.semibold))
                }
                Text(headline(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                connectionBadge
                Text(observationLabel(snapshot.observedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pulseSection(_ snapshot: NornDashboardSnapshot) -> some View {
        NornSurfaceCard(
            title: "Platform pulse",
            subtitle: "A quiet read on the services and control plane you own",
            accessory: {
                NornSectionAction(title: "Services", action: onShowServices)
            }
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    metric(snapshot.passingServices, "healthy services", .healthy, "of \(snapshot.services.count) observed", destination: "Apps", action: onShowServices)
                    metric(attentionServiceCount(snapshot), "need attention", attentionServiceCount(snapshot) == 0 ? .neutral : .attention, "health checks", destination: "Apps", action: onShowServices)
                    metric(snapshot.activeOperations.count, "active operations", snapshot.activeOperations.isEmpty ? .neutral : .active, activeOperationDetail(snapshot), destination: "Operations", action: onShowOperations)
                    metric(snapshot.health.services.count, "control-plane checks", NornStatus(serviceStatus: snapshot.health.status), snapshot.health.status.capitalized, destination: "Host", action: onShowHost)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 22) {
                    metric(snapshot.passingServices, "healthy services", .healthy, "of \(snapshot.services.count) observed", destination: "Apps", action: onShowServices)
                    metric(attentionServiceCount(snapshot), "need attention", attentionServiceCount(snapshot) == 0 ? .neutral : .attention, "health checks", destination: "Apps", action: onShowServices)
                    metric(snapshot.activeOperations.count, "active operations", snapshot.activeOperations.isEmpty ? .neutral : .active, activeOperationDetail(snapshot), destination: "Operations", action: onShowOperations)
                    metric(snapshot.health.services.count, "control-plane checks", NornStatus(serviceStatus: snapshot.health.status), snapshot.health.status.capitalized, destination: "Host", action: onShowHost)
                }
            }
        }
        .accessibilityLabel("Platform pulse")
    }

    private func lowerSection(_ snapshot: NornDashboardSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                serviceCard(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                operationsCard(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 20) {
                serviceCard(snapshot)
                operationsCard(snapshot)
            }
        }
    }

    private func serviceCard(_ snapshot: NornDashboardSnapshot) -> some View {
        NornSurfaceCard(
            title: "Service health",
            subtitle: serviceSubtitle(snapshot),
            accessory: {
                NornSectionAction(title: "All Services", action: onShowServices)
            }
        ) {
            VStack(spacing: 2) {
                ForEach(snapshot.services.prefix(5)) { service in
                    OverviewServiceRow(service: service)
                }
            }
            if snapshot.services.count > 5 {
                Text("+ \(snapshot.services.count - 5) more services")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .contextMenu {
            Button("Show Services", action: onShowServices)
        }
    }

    private func operationsCard(_ snapshot: NornDashboardSnapshot) -> some View {
        NornSurfaceCard(
            title: "Recent receipts",
            subtitle: snapshot.activeOperations.isEmpty ? "No work is currently in flight" : "Server work continues independently",
            accessory: {
                NornSectionAction(title: "Operations", action: onShowOperations)
            }
        ) {
            if snapshot.operations.isEmpty {
                ContentUnavailableView(
                    "No operations yet",
                    systemImage: "checklist",
                    description: Text("Receipts will appear here as Norn records work."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 2) {
                    ForEach(snapshot.operations.sorted { $0.updatedAt > $1.updatedAt }.prefix(4)) { operation in
                        OverviewOperationRow(operation: operation)
                    }
                }
            }

            if let current = snapshot.releases.first(where: \.current) {
                Divider().padding(.vertical, 6)
                Button(action: onShowReleases) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Current release")
                            .foregroundStyle(.secondary)
                        Text(current.displayLabel(in: snapshot.releases))
                            .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show release history")
            }
        }
        .contextMenu {
            Button("Show Operations", action: onShowOperations)
            Button("Show Releases", action: onShowReleases)
        }
    }

    private func metric(
        _ value: Int,
        _ label: String,
        _ status: NornStatus,
        _ detail: String,
        destination: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            NornMetric(value: value, label: label, status: status, detail: detail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 54)
                }
        }
        .buttonStyle(.plain)
        .help("Show \(destination)")
        .accessibilityHint("Opens \(destination.lowercased())")
        .accessibilityIdentifier("overview.pulse." + label.replacingOccurrences(of: " ", with: "-"))
    }

    private var connectionBadge: some View {
        switch connectionState {
        case .online:
            NornStatusBadge(status: .healthy, label: "Live")
        case .connecting:
            NornStatusBadge(status: .active, label: "Connecting")
        case .reconnecting:
            NornStatusBadge(status: .active, label: "Reconnecting")
        case .idle:
            NornStatusBadge(status: .neutral, label: "Not connected")
        case .offline:
            NornStatusBadge(status: .offline, label: "Offline")
        }
    }

    private var isOffline: Bool {
        if case .offline = connectionState { return true }
        return false
    }

    private func staleBanner(_ snapshot: NornDashboardSnapshot) -> some View {
        Label {
            Text("Showing the last authoritative snapshot from \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)).")
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Offline. \(observationLabel(snapshot.observedAt))")
    }

    private func overallStatus(_ snapshot: NornDashboardSnapshot) -> NornStatus {
        if isOffline { return .offline }
        if snapshot.operations.contains(where: { $0.status == .failed }) { return .critical }
        if attentionServiceCount(snapshot) > 0 { return .attention }
        if !snapshot.activeOperations.isEmpty { return .active }
        return NornStatus(serviceStatus: snapshot.health.status)
    }

    private func attentionServiceCount(_ snapshot: NornDashboardSnapshot) -> Int {
        snapshot.services.filter { !$0.isPassing }.count
    }

    private func headline(_ snapshot: NornDashboardSnapshot) -> String {
        if isOffline { return "Your last-known platform state is preserved locally." }
        if attentionServiceCount(snapshot) > 0 { return "A few checks deserve a closer look." }
        if !snapshot.activeOperations.isEmpty { return "Norn is carrying out durable work in the background." }
        return "Your control plane is steady and ready."
    }

    private func serviceSubtitle(_ snapshot: NornDashboardSnapshot) -> String {
        let count = attentionServiceCount(snapshot)
        return count == 0 ? "All observed services are passing" : "\(count) service\(count == 1 ? "" : "s") need attention"
    }

    private func activeOperationDetail(_ snapshot: NornDashboardSnapshot) -> String {
        guard let first = snapshot.activeOperations.first else { return "nothing in flight" }
        return first.kind.replacingOccurrences(of: ".", with: " ")
    }

    private func observationLabel(_ date: Date) -> String {
        "Observed \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct OverviewServiceRow: View {
    let service: NornService
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            NornStatusGlyph(status: NornStatus(serviceStatus: service.status), size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.app)
                    .font(.subheadline.weight(.medium))
                Text("\(service.process.capitalized) · \(service.reachability.exposure.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NornStatusBadge(status: NornStatus(serviceStatus: service.status), label: service.status.capitalized)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(isHovered ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(service.app), \(service.status)")
    }
}

private struct OverviewOperationRow: View {
    let operation: NornOperation
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            NornStatusGlyph(status: NornStatus(operationStatus: operation.status), size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.message ?? operation.kind)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(operation.kind.replacingOccurrences(of: ".", with: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                NornStatusBadge(status: NornStatus(operationStatus: operation.status), label: operation.status.rawValue.capitalized)
                Text(operation.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(isHovered ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(operation.kind), \(operation.status.rawValue)")
    }
}

#Preview("Healthy platform") {
    NavigationStack {
        OverviewView(snapshot: NornFixtures.snapshot, connectionState: .online)
    }
    .frame(width: 1_040, height: 760)
}

#Preview("Cached offline") {
    NavigationStack {
        OverviewView(
            snapshot: NornFixtures.snapshot,
            connectionState: .offline("The server cannot be reached right now.")
        )
    }
    .frame(width: 820, height: 760)
}
