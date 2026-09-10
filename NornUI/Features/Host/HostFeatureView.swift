//
//  HostFeatureView.swift
//  NornUI
//
//  A quiet readiness surface for the host that runs Norn's independent assurance lane.
//

import AppKit
import Charts
import Foundation
import SwiftUI

struct HostFeatureView: View {
    let health: NornHealth
    let services: [NornService]
    let operations: [NornOperation]
    let observedAt: Date?
    let isConnected: Bool
    let metrics: NornHostMetrics?
    let metricHistory: [NornHostMetricSample]
    let serviceMetricHistory: [NornServiceMetricSample]
    /// Advances whenever a history page is replaced or published, including
    /// corrections that keep the same count and final timestamp.
    let historyRevision: UInt64
    @Binding var serviceMetricsCollectionEnabled: Bool
    @Binding var refreshInterval: NornHostMetricsRefreshInterval
    let isMetricsSupported: Bool
    /// Scope-derived gates supplied by the app model. The Host view still
    /// requires an active connection before issuing any request.
    let canReadRuntime: Bool
    let canWriteRuntime: Bool
    let canRunAssurance: Bool
	let profileID: UUID?
    var onQueue: (NornMaintenanceRequest) -> Void = { _ in }
    var onOpenOperation: (NornOperation) -> Void = { _ in }
    var onOpenService: (NornService) -> Void = { _ in }
    var onLoadServiceLogs: (NornService) async -> String? = { _ in nil }
	var issueMutationContext: () -> NornMutationContext? = { nil }
    var onRestartApp: (NornService, NornMutationContext) async -> Bool = { _, _ in false }
    var onRequestMetricsHistory: (NornHostMetricsWindow, Date) async -> Void = { _, _ in }
    var onRefresh: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingAllServices = false
    @State private var selectedReadinessCheck: HostReadinessCheck?
    @State private var selectedLogService: NornService?
    @State private var serviceLogs = ""
    @State private var isLoadingServiceLogs = false
    @State private var serviceLogRequestID: UUID?
	@State private var restartGate = NornProfileBoundMutationGate<NornService>()
	@State private var restartContext: NornMutationContext?
    @State private var isRestartingApp = false
    @AppStorage("norn.hostMetricsWindow.v1") private var selectedWindow: NornHostMetricsWindow = .hour1
    @AppStorage("norn.hostMetricsChartStyle.v1") private var chartStyle: HostMetricsChartStyle = .line

    init(
        snapshot: NornDashboardSnapshot,
        isConnected: Bool = true,
        metrics: NornHostMetrics? = nil,
        metricHistory: [NornHostMetricSample] = [],
        serviceMetricHistory: [NornServiceMetricSample] = [],
        historyRevision: UInt64 = 0,
        serviceMetricsCollectionEnabled: Binding<Bool> = .constant(false),
        refreshInterval: Binding<NornHostMetricsRefreshInterval> = .constant(.seconds10),
        isMetricsSupported: Bool? = nil,
        canReadRuntime: Bool = true,
        canWriteRuntime: Bool = false,
        canRunAssurance: Bool = true,
		profileID: UUID? = nil,
        onQueue: @escaping (NornMaintenanceRequest) -> Void = { _ in },
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onOpenService: @escaping (NornService) -> Void = { _ in },
        onLoadServiceLogs: @escaping (NornService) async -> String? = { _ in nil },
		issueMutationContext: @escaping () -> NornMutationContext? = { nil },
        onRestartApp: @escaping (NornService, NornMutationContext) async -> Bool = { _, _ in false },
        onRequestMetricsHistory: @escaping (NornHostMetricsWindow, Date) async -> Void = { _, _ in },
        onRefresh: @escaping () -> Void = {}
    ) {
        self.health = snapshot.health
        self.services = snapshot.services
        self.operations = snapshot.operations
        self.observedAt = snapshot.observedAt
        self.isConnected = isConnected
        self.metrics = metrics
        self.metricHistory = metricHistory
        self.serviceMetricHistory = serviceMetricHistory
        self.historyRevision = historyRevision
        self._serviceMetricsCollectionEnabled = serviceMetricsCollectionEnabled
        self._refreshInterval = refreshInterval
        self.isMetricsSupported = isMetricsSupported ?? snapshot.capabilities.supportsHostMetrics
        self.canReadRuntime = canReadRuntime
        self.canWriteRuntime = canWriteRuntime
        self.canRunAssurance = canRunAssurance
		self.profileID = profileID
        self.onQueue = onQueue
        self.onOpenOperation = onOpenOperation
        self.onOpenService = onOpenService
        self.onLoadServiceLogs = onLoadServiceLogs
		self.issueMutationContext = issueMutationContext
        self.onRestartApp = onRestartApp
        self.onRequestMetricsHistory = onRequestMetricsHistory
        self.onRefresh = onRefresh
    }

    init(
        health: NornHealth,
        services: [NornService],
        operations: [NornOperation],
        observedAt: Date? = nil,
        isConnected: Bool = true,
        metrics: NornHostMetrics? = nil,
        metricHistory: [NornHostMetricSample] = [],
        serviceMetricHistory: [NornServiceMetricSample] = [],
        historyRevision: UInt64 = 0,
        serviceMetricsCollectionEnabled: Binding<Bool> = .constant(false),
        refreshInterval: Binding<NornHostMetricsRefreshInterval> = .constant(.seconds10),
        isMetricsSupported: Bool = false,
        canReadRuntime: Bool = true,
        canWriteRuntime: Bool = false,
        canRunAssurance: Bool = true,
		profileID: UUID? = nil,
        onQueue: @escaping (NornMaintenanceRequest) -> Void = { _ in },
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onOpenService: @escaping (NornService) -> Void = { _ in },
        onLoadServiceLogs: @escaping (NornService) async -> String? = { _ in nil },
		issueMutationContext: @escaping () -> NornMutationContext? = { nil },
        onRestartApp: @escaping (NornService, NornMutationContext) async -> Bool = { _, _ in false },
        onRequestMetricsHistory: @escaping (NornHostMetricsWindow, Date) async -> Void = { _, _ in },
        onRefresh: @escaping () -> Void = {}
    ) {
        self.health = health
        self.services = services
        self.operations = operations
        self.observedAt = observedAt
        self.isConnected = isConnected
        self.metrics = metrics
        self.metricHistory = metricHistory
        self.serviceMetricHistory = serviceMetricHistory
        self.historyRevision = historyRevision
        self._serviceMetricsCollectionEnabled = serviceMetricsCollectionEnabled
        self._refreshInterval = refreshInterval
        self.isMetricsSupported = isMetricsSupported
        self.canReadRuntime = canReadRuntime
        self.canWriteRuntime = canWriteRuntime
        self.canRunAssurance = canRunAssurance
		self.profileID = profileID
        self.onQueue = onQueue
        self.onOpenOperation = onOpenOperation
        self.onOpenService = onOpenService
        self.onLoadServiceLogs = onLoadServiceLogs
		self.issueMutationContext = issueMutationContext
        self.onRestartApp = onRestartApp
        self.onRequestMetricsHistory = onRequestMetricsHistory
        self.onRefresh = onRefresh
    }

    private var passingServiceCount: Int { services.filter(\.isPassing).count }
    private var expectedIdleServiceCount: Int { services.filter(\.isExpectedIdle).count }
    private var attentionServices: [NornService] { services.filter(\.needsAttention) }
    private var assuranceOperations: [NornOperation] {
        operations
            .filter { $0.kind == "host.assure" }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var latestAssurance: NornOperation? { assuranceOperations.first }
    private var activeAssurance: NornOperation? { assuranceOperations.first(where: \.status.isActive) }
    private var displayedServices: [NornService] {
        if isShowingAllServices { return services.sorted { $0.name < $1.name } }
        return attentionServices.isEmpty ? services.sorted { $0.name < $1.name }.prefix(5).map { $0 } : attentionServices
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                hostHeader

                metricsCard

                HStack(alignment: .top, spacing: 18) {
                    readinessCard
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    assuranceCard
                        .frame(minWidth: 310, idealWidth: 380, maxWidth: 440)
                }

                serviceReadiness

                assuranceReceipts
            }
            .padding(20)
            .frame(maxWidth: 1_250, alignment: .leading)
        }
        .navigationTitle("Host")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) {
                    Label("Refresh Host", systemImage: "arrow.clockwise")
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: latestAssurance?.status)
        .sheet(item: $selectedReadinessCheck) { check in
            HostReadinessInspector(
                check: check,
                relatedServices: relatedServices(for: check),
                networkMetadata: networkMetadata(for: check),
                isConnected: isConnected,
                canReadRuntime: canReadRuntime,
                canRunAssurance: canRunAssurance,
                onRunAssurance: queueAssurance,
                onOpenService: onOpenService,
                onLoadLogs: onLoadServiceLogs
            )
        }
        .sheet(item: $selectedLogService, onDismiss: {
            serviceLogRequestID = nil
            isLoadingServiceLogs = false
        }) { service in
            HostServiceLogsView(
                service: service,
                logs: serviceLogs,
                isLoading: isLoadingServiceLogs,
                reload: { loadServiceLogs(service) }
            )
        }
        .confirmationDialog(
            "Restart all active allocations for \(restartGate.pending?.intent.app ?? "this app")?",
            isPresented: Binding(
                get: { restartGate.pending != nil },
                set: { if !$0 { restartGate.dismiss(); restartContext = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restart App Allocations", role: .destructive) { confirmRestartAppAllocations() }
			Button("Cancel", role: .cancel) { restartGate.dismiss(); restartContext = nil }
        } message: {
            Text("This directly replaces every active Nomad allocation for the app. It is app-wide, is not a durable Norn operation, and does not create a receipt.")
        }
		.onChange(of: profileID) { _, _ in
			restartGate.invalidate()
			restartContext = nil
			selectedLogService = nil
			serviceLogRequestID = nil
		}
    }

    private var hostHeader: some View {
        HStack(alignment: .top) {
            Image(systemName: "macmini")
                .font(.title2)
                .foregroundStyle(hostIsHealthy ? .green : .orange)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Host assurance")
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let observedAt {
                Text("Observed \(observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host assurance. \(headerSubtitle)")
        .accessibilityIdentifier("host.header")
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Readiness", systemImage: hostIsHealthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(hostIsHealthy ? .green : .orange)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(passingServiceCount)")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(readinessSummary)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(passingServiceCount) \(readinessSummary)")

            Divider()

            VStack(spacing: 2) {
                ForEach(readinessChecks) { check in
                    Button { selectedReadinessCheck = check } label: {
                        HStack(spacing: 8) {
                            Label(check.name, systemImage: check.symbol)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(check.status)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(check.isPassing ? .green : .orange)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Inspect \(check.name)") { selectedReadinessCheck = check }
                    }
                    .accessibilityHint("Opens readiness details")
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var metricsCard: some View {
        if !isMetricsSupported {
            NornSurfaceCard(title: "Norn mini metrics", subtitle: "Remote CPU and memory") {
                Label("Norn mini metrics are not available from this server.", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Norn mini metrics unavailable from this server")
            }
        } else if let metrics {
            NornSurfaceCard(
                title: "Norn mini metrics",
                subtitle: "Remote CPU and memory",
                accessory: {
                    NornStatusBadge(
                        status: metrics.stale ? .attention : .healthy,
                        label: metrics.stale ? "Stale" : "Current"
                    )
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 22) {
                        metricValues(metrics)
                        Spacer(minLength: 0)
                        HostMetricsTimestamp(metrics: metrics)
                    }
                    HostMetricsHistoryChart(
                        samples: metricHistory,
                        serviceSamples: serviceMetricHistory,
                        historyRevision: historyRevision,
                        serviceMetricsCollectionEnabled: $serviceMetricsCollectionEnabled,
                        latest: metrics,
                        window: $selectedWindow,
                        style: chartStyle,
                        onRequestHistory: onRequestMetricsHistory
                    )
                    .frame(minHeight: 190)
                }
                HStack(spacing: 12) {
                    Picker("Window", selection: $selectedWindow) {
                        ForEach(NornHostMetricsWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Metrics history window")

                    Picker("Chart style", selection: $chartStyle) {
                        ForEach(HostMetricsChartStyle.allCases) { style in
                            Label(style.title, systemImage: style.symbol).tag(style)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Metrics chart style")

                    Spacer()

                    Text("Refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Refresh interval", selection: $refreshInterval) {
                        ForEach(NornHostMetricsRefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Metrics refresh interval")
                }
                .controlSize(.small)
            }
        } else {
            NornSurfaceCard(title: "Norn mini metrics", subtitle: "Remote CPU and memory") {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isConnected ? "Waiting for the first metrics sample." : "Metrics will resume when the server reconnects.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                    .accessibilityLabel(isConnected ? "Waiting for the first Norn mini metrics sample" : "Norn mini metrics will resume when the server reconnects")
            }
        }
    }

    private var assuranceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Assurance lane", systemImage: "stethoscope")
                .font(.headline)

            Text("Runs independently of the API process and leaves a durable receipt when host recovery is complete.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let activeAssurance {
                HostReceiptStatus(operation: activeAssurance)
            } else if let latestAssurance {
                HostReceiptStatus(operation: latestAssurance)
            } else {
                Label("No assurance receipt yet", systemImage: "doc.badge.questionmark")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Run Assurance") { queueAssurance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected || !canRunAssurance || activeAssurance != nil)
                    .accessibilityHint("Queues a durable host assurance operation")
                if let latestAssurance {
                    Button("Open Receipt") { onOpenOperation(latestAssurance) }
                        .buttonStyle(.bordered)
                }
            }

            if !isConnected || !canRunAssurance {
                Label(!isConnected ? "Reconnect to queue assurance." : "Your current access cannot queue assurance.", systemImage: !isConnected ? "wifi.slash" : "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18))
        }
    }

    private var serviceReadiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Service readiness", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                if services.count > 5 {
                    Button(isShowingAllServices ? "Show Summary" : "Show All \(services.count)") {
                        isShowingAllServices.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(spacing: 0) {
                ForEach(displayedServices) { service in
                    HStack(spacing: 8) {
                        Button { onOpenService(service) } label: {
                            HostServiceRow(service: service, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)

                        if canReadRuntime || canWriteRuntime {
                            Menu {
                                Button("Open Service") { onOpenService(service) }
                                if canReadRuntime {
                                    Button("View App Logs") { loadServiceLogs(service) }
                                }
                                if canWriteRuntime && supportsDirectRuntimeControl(for: service) {
                                    Divider()
									Button("Restart App Allocations…", role: .destructive) { presentRestart(for: service) }
                                }
                            } label: {
                                Label("Service Actions", systemImage: "ellipsis.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(isLoadingServiceLogs || isRestartingApp)
                            .help("Inspect or control \(service.app)")
                        }
                    }
                    .contextMenu {
                        Button("Open \(service.name)") { onOpenService(service) }
                        if canReadRuntime {
                            Button("View App Logs") { loadServiceLogs(service) }
                        }
                        if canWriteRuntime && supportsDirectRuntimeControl(for: service) {
                            Divider()
							Button("Restart App Allocations…", role: .destructive) { presentRestart(for: service) }
                        }
                    }
                    if service.id != displayedServices.last?.id { Divider().padding(.leading, 34) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var assuranceReceipts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent assurance receipts", systemImage: "checkmark.seal")
                .font(.headline)

            if assuranceOperations.isEmpty {
                ContentUnavailableView(
                    "No host receipts",
                    systemImage: "doc.text",
                    description: Text("Run an assurance check to record the host’s recovery state."))
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                VStack(spacing: 0) {
                    ForEach(assuranceOperations.prefix(5)) { operation in
                        Button { onOpenOperation(operation) } label: {
                            HostReceiptRow(operation: operation)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open Receipt") { onOpenOperation(operation) }
                            Button("Copy Operation ID") { copy(operation.id) }
                        }
                        if operation.id != assuranceOperations.prefix(5).last?.id { Divider() }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var headerSubtitle: String {
        if !isConnected { return "Last-known readiness is available offline." }
        if let activeAssurance { return "Assurance is running — \(activeAssurance.message ?? "the host agent is collecting a receipt.")" }
        return hostIsHealthy ? "The host is ready for control-plane work." : "Review attention items before platform maintenance."
    }

    private var readinessSummary: String {
        var parts = ["of \(services.count) services passing"]
        if expectedIdleServiceCount > 0 {
            parts.append("\(expectedIdleServiceCount) expected idle")
        }
        return parts.joined(separator: " · ")
    }

    private var hostIsHealthy: Bool {
        health.status.lowercased() == "ok" && attentionServices.isEmpty
    }

    private var readinessChecks: [HostReadinessCheck] {
        health.services
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { name, status in
                HostReadinessCheck(name: name, status: status)
            }
    }

    private func relatedServices(for check: HostReadinessCheck) -> [NornService] {
        let terms = check.matchTerms
        return services.filter { service in
            let searchable = [service.name, service.app, service.process]
                .joined(separator: " ")
                .lowercased()
            return terms.contains { searchable.contains($0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func networkMetadata(for check: HostReadinessCheck) -> [(String, String)] {
        guard let network = health.network else { return [] }
        switch check.normalizedName {
        case "nomad":
            return network.nomadAddr.map { [("Nomad endpoint", $0)] } ?? []
        case "consul":
            return network.consulAddr.map { [("Consul endpoint", $0)] } ?? []
        default:
            var metadata: [(String, String)] = []
            if let mode = network.mode { metadata.append(("Network mode", mode)) }
            if let bindAddr = network.bindAddr { metadata.append(("Host bind address", bindAddr)) }
            return metadata
        }
    }

    private func queueAssurance() {
        onQueue(.hostAssurance)
    }

    private func supportsDirectRuntimeControl(for service: NornService) -> Bool {
        !service.isExpectedIdle
            && !["cron", "function"].contains(service.type.lowercased())
            && !service.app.isEmpty
    }

    private func loadServiceLogs(_ service: NornService) {
        let requestID = UUID()
        serviceLogRequestID = requestID
        selectedLogService = service
        serviceLogs = ""
        isLoadingServiceLogs = true
        Task {
            let loaded = await onLoadServiceLogs(service)
            guard serviceLogRequestID == requestID, selectedLogService?.id == service.id else { return }
            serviceLogs = loaded ?? "No app logs were returned. The app may not have a running allocation, or this credential may not have read access."
            isLoadingServiceLogs = false
            serviceLogRequestID = nil
        }
    }

    private func presentRestart(for service: NornService) {
		guard let context = issueMutationContext() else { return }
		restartContext = context
		restartGate.present(service, profileID: profileID, isAuthorized: canWriteRuntime)
	}

	private func confirmRestartAppAllocations() {
		guard let service = restartGate.confirmedIntent(
			profileID: profileID,
			isAuthorized: canWriteRuntime,
			isStillCurrent: { candidate in services.contains(where: { $0.id == candidate.id }) }
		), let context = restartContext else { return }
		restartContext = nil
        isRestartingApp = true
        Task {
            _ = await onRestartApp(service, context)
            isRestartingApp = false
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    @ViewBuilder
    private func metricValues(_ metrics: NornHostMetrics) -> some View {
        HostMetricValue(
            title: "CPU",
            value: "\(metrics.cpu.utilizationPercent.formatted(.number.precision(.fractionLength(1))))%",
            detail: "\(metrics.cpu.logicalCores) logical cores",
            symbol: "cpu"
        )

        Divider()

        HostMetricValue(
            title: "Memory",
            value: byteCount(metrics.memory.usedBytes),
            detail: "of \(byteCount(metrics.memory.totalBytes)) used · \(byteCount(metrics.memory.availableBytes)) available",
            symbol: "memorychip"
        )
    }

    private func metricsAccessibilityLabel(_ metrics: NornHostMetrics) -> String {
        let freshness = metrics.stale ? "stale" : "current"
        return "Norn mini metrics from the selected remote server, \(freshness). CPU \(metrics.cpu.utilizationPercent.formatted(.number.precision(.fractionLength(1)))) percent across \(metrics.cpu.logicalCores) logical cores. Memory \(byteCount(metrics.memory.usedBytes)) used of \(byteCount(metrics.memory.totalBytes)), \(byteCount(metrics.memory.availableBytes)) available. Sampled \(metrics.observedAt.formatted(date: .abbreviated, time: .standard))."
    }
}

private struct HostReadinessCheck: Identifiable, Hashable {
    let rawName: String
    let status: String

    init(name: String, status: String) {
        self.rawName = name
        self.status = status
    }

    var id: String { rawName.lowercased() }
    var normalizedName: String {
        rawName.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }
    var isPassing: Bool { ["up", "ok", "passing"].contains(status.lowercased()) }
    var name: String {
        switch normalizedName {
        case "s3", "objectstorage", "objectstore", "minio": "Object storage"
        case "nomad": "Nomad"
        case "consul": "Consul"
        case "grafana": "Grafana"
        case "postgres", "postgresql": "PostgreSQL"
        default:
            rawName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var symbol: String { isPassing ? "checkmark.circle" : "exclamationmark.triangle" }
    var statusLabel: String { status.uppercased() }
    var description: String {
        switch normalizedName {
        case "s3", "objectstorage", "objectstore", "minio":
            "Norn uses this readiness check to report object storage availability. It does not enumerate buckets or objects."
        case "nomad":
            "Nomad supplies workload scheduling and allocation state for manifest-backed apps."
        case "consul":
            "Consul supplies service discovery and health information used by Norn’s service manifest."
        case "grafana":
            "Grafana is an observability dependency. Norn reports its readiness here when configured."
        case "postgres", "postgresql":
            "PostgreSQL is a platform dependency. Use the app recovery workflow for database recovery rather than direct host actions."
        default:
            "Norn reported this host dependency through its readiness health check."
        }
    }
    var matchTerms: [String] {
        switch normalizedName {
        case "s3", "objectstorage", "objectstore", "minio": return ["s3", "minio"]
        case "postgres", "postgresql": return ["postgres", "postgresql"]
        default: return [normalizedName]
        }
    }
}

private struct HostReadinessInspector: View {
    let check: HostReadinessCheck
    let relatedServices: [NornService]
    let networkMetadata: [(String, String)]
    let isConnected: Bool
    let canReadRuntime: Bool
    let canRunAssurance: Bool
    let onRunAssurance: () -> Void
    let onOpenService: (NornService) -> Void
    let onLoadLogs: (NornService) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedLogService: NornService?
    @State private var logs = ""
    @State private var isLoadingLogs = false
    @State private var logRequestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    metadata
                    relatedServiceSection
                    assuranceSection
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 460, idealHeight: 620)
        .sheet(item: $selectedLogService, onDismiss: {
            logRequestID = nil
            isLoadingLogs = false
        }) { service in
            HostServiceLogsView(
                service: service,
                logs: logs,
                isLoading: isLoadingLogs,
                reload: { loadLogs(for: service) }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.isPassing ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(check.isPassing ? .green : .orange)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 5) {
                Text(check.name)
                    .font(.title2.weight(.semibold))
                Text(check.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(check.isPassing ? .green : .orange)
                Text(check.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness details")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("Check")
                        .foregroundStyle(.secondary)
                    Text(check.rawName)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Health source")
                        .foregroundStyle(.secondary)
                    Text("Host health")
                }
                ForEach(networkMetadata, id: \.0) { key, value in
                    GridRow {
                        Text(key)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var relatedServiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manifest-backed services")
                .font(.headline)
            if relatedServices.isEmpty {
                Label("No matching app service is present in the current manifest.", systemImage: "square.dashed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(relatedServices) { service in
                        readinessServiceRow(service)
                        if service.id != relatedServices.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func readinessServiceRow(_ service: NornService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: service.isPassing ? "checkmark.circle.fill" : (service.isExpectedIdle ? "moon.zzz.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(service.isPassing ? .green : (service.isExpectedIdle ? .secondary : .orange))
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.body.weight(.medium))
                    Text("\(service.app) · \(service.process) · \(service.type.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(service.displayStatus.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(service.isPassing ? .green : (service.isExpectedIdle ? .secondary : .orange))
            }

            HStack(spacing: 8) {
                Button("Open Service") {
                    onOpenService(service)
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("View App Logs") { loadLogs(for: service) }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected || !canReadRuntime || isLoadingLogs)

            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private var assuranceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Host-managed recovery")
                .font(.headline)
            Text("Run bounded checks and allowed repairs through Norn’s assurance lane; it leaves a durable receipt. Core dependencies are checked before any allowed app, route, or capacity repair.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Run Assurance") {
                onRunAssurance()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected || !canRunAssurance)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadLogs(for service: NornService) {
        let requestID = UUID()
        logRequestID = requestID
        selectedLogService = service
        logs = ""
        isLoadingLogs = true
        Task {
            let loadedLogs = await onLoadLogs(service)
            await MainActor.run {
                guard logRequestID == requestID, selectedLogService?.id == service.id else { return }
                logs = loadedLogs ?? "No logs were returned. The service may not expose runtime logs or the request may have failed."
                isLoadingLogs = false
                logRequestID = nil
            }
        }
    }

}

private struct HostServiceLogsView: View {
    let service: NornService
    let logs: String
    let isLoading: Bool
    let reload: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(service.app) app logs")
                        .font(.headline)
                    Text("Latest allocation, first task · up to first 256 KB · not a durable archive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload", action: reload)
                    .disabled(isLoading)
            }
            .padding(16)
            Divider()
            Group {
                if isLoading {
                    ProgressView("Loading logs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(logs.isEmpty ? "No log output." : logs)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(16)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 780, minHeight: 420, idealHeight: 560)
    }
}

private struct HostMetricValue: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private enum HostMetricsChartStyle: String, CaseIterable, Identifiable {
    case line
    case bar

    var id: String { rawValue }
    var title: String { self == .line ? "Line" : "Bars" }
    var symbol: String { self == .line ? "chart.xyaxis.line" : "chart.bar" }
}

private struct HostMetricsHistoryChart: View {
    let samples: [NornHostMetricSample]
    let serviceSamples: [NornServiceMetricSample]
    let historyRevision: UInt64
    @Binding var serviceMetricsCollectionEnabled: Bool
    let latest: NornHostMetrics
    @Binding var window: NornHostMetricsWindow
    let style: HostMetricsChartStyle
    let onRequestHistory: (NornHostMetricsWindow, Date) async -> Void

    @State private var requestedViewportStart: Date?
    @State private var requestedViewportDuration: TimeInterval?
    @State private var hoveredDate: Date?
    @State private var dragSelection: HostChartDragSelection?
    @State private var followsLatest = true
    @State private var prepared: HostMetricsChartPreparation?
    @State private var historyRequestID: UUID?
    @State private var isLoadingHistory = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var viewport: HostChartViewport {
        HostChartViewport(
            latest: latest.observedAt,
            window: window,
            requestedStart: requestedViewportStart,
            duration: requestedViewportDuration
        )
    }

    private var isCustomZoom: Bool { requestedViewportDuration != nil }

    private var chartData: HostMetricsChartPreparation {
        prepared ?? HostMetricsChartPreparation.prepare(
            samples: [], serviceSamples: [], latest: latest, window: window,
            requestedViewportStart: viewport.start,
            includesServiceMetrics: false,
            viewportDuration: viewport.duration
        )
    }
    private var hoveredHostSample: NornHostMetricSample? {
        hoveredDate.flatMap { chartData.nearestHost(to: $0) }
    }
    private var hoveredTenantSamples: [(HostMetricsChartPreparation.TenantSeries, NornServiceMetricSample)] {
        guard let hoveredDate else { return [] }
        return chartData.nearestTenantSamples(to: hoveredDate, tolerance: max(60, Double(window.rawValue) / 80))
    }
    private var preparationKey: HostChartPreparationKey {
        return HostChartPreparationKey(
            hostCount: samples.count, hostLast: samples.last?.observedAt, serviceCount: serviceSamples.count,
            serviceLast: serviceSamples.last?.observedAt, historyRevision: historyRevision, latest: latest, window: window,
            viewport: viewport.start, viewportDuration: viewport.duration,
            includesServiceMetrics: serviceMetricsCollectionEnabled
        )
    }
    private var historyRequestKey: HostChartHistoryRequestKey {
        return HostChartHistoryRequestKey(
            window: viewport.historyWindow,
            viewportEnd: requestedViewportStart == nil ? nil : viewport.end,
            includesServiceMetrics: serviceMetricsCollectionEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Usage history")
                    .font(.subheadline.weight(.medium))
                if isLoadingHistory {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Loading metrics history")
                }
                Spacer(minLength: 0)
                Text("High: CPU \(chartData.cpuHighWater.formatted(.number.precision(.fractionLength(1))))% · Memory \(chartData.memoryHighWater.formatted(.number.precision(.fractionLength(1))))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            metricLegend

            if chartData.hostSamples.count < 2 {
                ContentUnavailableView(
                    isLoadingHistory ? "Loading history" : "No history in this range",
                    systemImage: "chart.xyaxis.line",
                    description: Text(isLoadingHistory
                        ? "Current readings remain available while this range loads."
                        : "Choose another time range or wait for more samples."))
                    .frame(maxWidth: .infinity, minHeight: 128)
            } else {
                Chart {
                    ForEach(chartData.hostSamples) { sample in
                        if style == .line {
                            LineMark(
                                x: .value("Time", sample.observedAt),
                                y: .value("Usage", sample.cpuPercent),
                                series: .value("Series", "Norn mini CPU")
                            )
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(.init(lineWidth: 2.2))
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value("Time", sample.observedAt),
                                y: .value("Usage", sample.memoryPercent),
                                series: .value("Series", "Norn mini memory")
                            )
                            .foregroundStyle(Color.purple)
                            .lineStyle(.init(lineWidth: 2.2))
                            .interpolationMethod(.catmullRom)
                        } else {
                            BarMark(
                                x: .value("Time", sample.observedAt),
                                y: .value("Usage", sample.cpuPercent)
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.82))
                            .position(by: .value("Metric", "CPU"))

                            BarMark(
                                x: .value("Time", sample.observedAt),
                                y: .value("Usage", sample.memoryPercent)
                            )
                            .foregroundStyle(Color.purple.opacity(0.76))
                            .position(by: .value("Metric", "Memory"))
                        }
                    }

                    ForEach(chartData.tenantSeries) { series in
                        ForEach(series.samples) { sample in
                            LineMark(
                                x: .value("Time", sample.observedAt),
                                y: .value("Usage", sample.cpuPercent),
                                series: .value("Series", "\(series.id)-cpu")
                            )
                            .foregroundStyle(series.color.opacity(0.9))
                            .lineStyle(.init(lineWidth: 0.9))
                            .interpolationMethod(.linear)

                            LineMark(
                                x: .value("Time", sample.observedAt),
                                y: .value("Usage", sample.memoryPercent),
                                series: .value("Series", "\(series.id)-memory")
                            )
                            .foregroundStyle(series.color.opacity(0.62))
                            .lineStyle(.init(lineWidth: 0.75, dash: [3, 3]))
                            .interpolationMethod(.linear)
                        }
                    }

                    if let hoveredHostSample {
                        RuleMark(x: .value("Selected time", hoveredHostSample.observedAt))
                            .foregroundStyle(.secondary.opacity(0.48))
                            .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        PointMark(
                            x: .value("Time", hoveredHostSample.observedAt),
                            y: .value("Usage", hoveredHostSample.cpuPercent)
                        )
                        .foregroundStyle(Color.accentColor)
                        PointMark(
                            x: .value("Time", hoveredHostSample.observedAt),
                            y: .value("Usage", hoveredHostSample.memoryPercent)
                        )
                        .foregroundStyle(Color.purple)
                    }
                }
                .chartYScale(domain: 0...chartData.yDomainUpperBound)
                // Keep Charts' geometry strictly viewport-sized. A synthetic
                // month-wide scroll area with a minutes-wide window can hang
                // Charts layout on the main thread even with very few marks.
                .chartXScale(domain: chartData.viewportStart...chartData.viewportEnd)
                .chartXAxis {
                    AxisMarks(values: [chartData.viewportStart,
                        chartData.viewportStart.addingTimeInterval(chartData.viewportEnd.timeIntervalSince(chartData.viewportStart) / 2),
                        chartData.viewportEnd])
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .background {
                                HostChartScrollWheelMonitor { deltaY in
                                    zoomForScroll(deltaY)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if let dragSelection, let plotFrame = proxy.plotFrame {
                                    HostChartSelectionOverlay(
                                        selection: dragSelection,
                                        plotFrame: geometry[plotFrame]
                                    )
                                }
                            }
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    updateHover(at: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    hoveredDate = nil
                                }
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { value in
                                        updateSelection(at: value, proxy: proxy, geometry: geometry)
                                    }
                                    .onEnded { value in
                                        finishSelection(at: value, proxy: proxy, geometry: geometry)
                                    }
                            )
                    }
                }
                .frame(minHeight: 142)
                .accessibilityIdentifier("host.history.chart")
                .accessibilityLabel("Norn mini CPU and memory use for the selected history range. CPU high water \(chartData.cpuHighWater.formatted(.number.precision(.fractionLength(1)))) percent. Memory high water \(chartData.memoryHighWater.formatted(.number.precision(.fractionLength(1)))) percent.")
                .accessibilityValue("\(chartData.viewportStart.formatted(date: .abbreviated, time: .shortened)) to \(chartData.viewportEnd.formatted(date: .abbreviated, time: .shortened)); \(Int(chartData.viewportEnd.timeIntervalSince(chartData.viewportStart))) seconds")

                hoverReadout

                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Drag across the chart to zoom. Use Option-scroll to zoom at the pointer.")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .task(id: preparationKey) {
            // Coalesce rapid range changes before preparing the selected page.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let hostInput = samples
            let serviceInput = serviceSamples
            let latestInput = latest
            let windowInput = window
            let viewportInput = viewport.start
            let viewportDurationInput = viewport.duration
            let includesServiceMetrics = serviceMetricsCollectionEnabled
            let preparationTask = Task.detached(priority: .userInitiated) {
                HostMetricsChartPreparation.prepare(
                    samples: hostInput,
                    serviceSamples: serviceInput,
                    latest: latestInput,
                    window: windowInput,
                    requestedViewportStart: viewportInput,
                    includesServiceMetrics: includesServiceMetrics,
                    viewportDuration: viewportDurationInput
                )
            }
            let result = await withTaskCancellationHandler(
                operation: { await preparationTask.value },
                onCancel: { preparationTask.cancel() }
            )
            guard !Task.isCancelled else { return }
            if reduceMotion {
                prepared = result
            } else {
                withAnimation(.easeInOut(duration: 0.24)) {
                    prepared = result
                }
            }
        }
        .task(id: historyRequestKey) {
            let requestID = UUID()
            let viewportEnd = viewport.end
            historyRequestID = requestID
            isLoadingHistory = true
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await onRequestHistory(historyRequestKey.window, viewportEnd)
            guard !Task.isCancelled, historyRequestID == requestID else { return }
            isLoadingHistory = false
            historyRequestID = nil
        }
        .onChange(of: window) { _, _ in
            requestedViewportDuration = nil
            if followsLatest { requestedViewportStart = nil }
            hoveredDate = nil
        }
        .onDisappear {
            hoveredDate = nil
        }
    }

    private var metricLegend: some View {
        HStack(spacing: 12) {
            legendItem(name: "Norn mini CPU", color: .accentColor)
            legendItem(name: "Norn mini memory", color: .purple)

            Divider().frame(height: 12)
            Button {
                serviceMetricsCollectionEnabled.toggle()
            } label: {
                Label(
                    serviceMetricsCollectionEnabled ? "Hide workloads" : "Add workloads",
                    systemImage: serviceMetricsCollectionEnabled ? "eye" : "plus.circle"
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Opt in to fleet-wide Nomad allocation peaks. Solid lines are allocation CPU; dashed lines are memory versus the declared limit. Values are not attributed to this host.")

            if serviceMetricsCollectionEnabled {
                Text("Fleet-wide allocation peaks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ForEach(chartData.tenantSeries.prefix(3)) { series in
                    legendItem(name: series.name, color: series.color)
                }
                if chartData.tenantSeries.count > 3 {
                    Text("+\(chartData.tenantSeries.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
            Button { pageHistory(by: -1) } label: { Label("Earlier", systemImage: "chevron.left") }
                .disabled(!viewport.canGoOlder)
                .help("Load the previous time window")
                .accessibilityIdentifier("host.history.earlier")
            Button { pageHistory(by: 1) } label: { Label("Later", systemImage: "chevron.right") }
                .disabled(!viewport.canGoNewer)
                .help("Load the next time window")
                .accessibilityIdentifier("host.history.later")
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .disabled(viewport.duration >= HostChartViewport.maximumDuration)
                .help("Show a longer time window")
                .accessibilityIdentifier("host.history.zoom-out")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .disabled(viewport.duration <= HostChartViewport.minimumDuration)
                .help("Show a shorter time window")
                .accessibilityIdentifier("host.history.zoom-in")
            Button(action: resetZoom) { Image(systemName: "arrow.counterclockwise") }
                .disabled(!isCustomZoom)
                .help("Restore the selected time window")
                .accessibilityIdentifier("host.history.reset-zoom")
            Button(action: scrollToLatest) { Image(systemName: "arrow.right.to.line") }
                .help("Return to the latest sample")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private func legendItem(name: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var hoverReadout: some View {
        ZStack(alignment: .leading) {
            if let sample = hoveredHostSample {
                HStack(spacing: 10) {
                    Text(sample.observedAt.formatted(date: .abbreviated, time: .standard))
                    Text("CPU \(sample.cpuPercent.formatted(.number.precision(.fractionLength(1))))%")
                        .foregroundStyle(Color.accentColor)
                    Text("Memory \(sample.memoryPercent.formatted(.number.precision(.fractionLength(1))))%")
                        .foregroundStyle(Color.purple)
                    ForEach(hoveredTenantSamples.prefix(2), id: \.0.id) { series, tenant in
                        Text("\(series.name) CPU \(tenant.cpuPercent.formatted(.number.precision(.fractionLength(1))))% · limit \(tenant.memoryPercent.formatted(.number.precision(.fractionLength(1))))%")
                            .foregroundStyle(series.color)
                            .lineLimit(1)
                    }
                }
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .accessibilityIdentifier("host.history.hover-readout")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoveredHostSample != nil)
    }

    private func updateHover(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        hoveredDate = chartDate(at: location, proxy: proxy, geometry: geometry)
    }

    private func chartDate(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.width > 0,
              location.x >= frame.minX, location.x <= frame.maxX,
              location.y >= frame.minY, location.y <= frame.maxY else {
            return nil
        }
        let fraction = min(max((location.x - frame.minX) / frame.width, 0), 1)
        return chartData.viewportStart.addingTimeInterval(
            chartData.viewportEnd.timeIntervalSince(chartData.viewportStart) * fraction
        )
    }

    private func updateSelection(at value: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        let start = CGPoint(
            x: min(max(value.startLocation.x, frame.minX), frame.maxX),
            y: min(max(value.startLocation.y, frame.minY), frame.maxY)
        )
        let current = CGPoint(
            x: min(max(value.location.x, frame.minX), frame.maxX),
            y: min(max(value.location.y, frame.minY), frame.maxY)
        )
        dragSelection = HostChartDragSelection(start: start, current: current)
    }

    private func finishSelection(at value: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy) {
        defer { dragSelection = nil }
        guard let start = chartDate(at: value.startLocation, proxy: proxy, geometry: geometry),
              let end = chartDate(at: clampedLocation(value.location, proxy: proxy, geometry: geometry), proxy: proxy, geometry: geometry),
              abs(end.timeIntervalSince(start)) >= 8 else { return }
        apply(viewport.selectedRange(from: start, to: end))
    }

    private func clampedLocation(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> CGPoint {
        guard let plotFrame = proxy.plotFrame else { return location }
        let frame = geometry[plotFrame]
        return CGPoint(
            x: min(max(location.x, frame.minX), frame.maxX),
            y: min(max(location.y, frame.minY), frame.maxY)
        )
    }

    private func scrollToLatest() {
        followsLatest = true
        requestedViewportStart = nil
        requestedViewportDuration = nil
        hoveredDate = nil
    }

    private func pageHistory(by pages: Int) {
        let next = viewport.shifted(by: pages)
        followsLatest = next >= viewport.latestStart
        requestedViewportStart = followsLatest ? nil : next
        hoveredDate = nil
    }

    private func zoomOut() {
        zoom(by: 2, anchor: hoveredDate)
    }

    private func zoomIn() {
        zoom(by: 0.5, anchor: hoveredDate)
    }

    private func zoom(by scale: Double, anchor: Date?) {
        apply(viewport.zoomed(by: scale, anchor: anchor), preserving: anchor)
    }

    private func zoomForScroll(_ deltaY: CGFloat) {
        let boundedDelta = min(max(Double(deltaY), -8), 8)
        guard abs(boundedDelta) > 0.01 else { return }
        zoom(by: exp(-boundedDelta * 0.015), anchor: hoveredDate)
    }

    private func resetZoom() {
        requestedViewportDuration = nil
        hoveredDate = nil
    }

    private func apply(_ next: HostChartViewport, preserving anchor: Date? = nil) {
        followsLatest = next.start >= next.latestStart
        requestedViewportStart = followsLatest ? nil : next.start
        requestedViewportDuration = abs(next.duration - TimeInterval(window.rawValue)) < 0.5 ? nil : next.duration
        if let anchor {
            hoveredDate = min(max(anchor, next.start), next.end)
        } else {
            hoveredDate = nil
        }
    }
}

private struct HostChartDragSelection: Equatable {
    let start: CGPoint
    let current: CGPoint
}

private struct HostChartSelectionOverlay: View {
    let selection: HostChartDragSelection
    let plotFrame: CGRect

    var body: some View {
        let lowerX = min(selection.start.x, selection.current.x)
        let upperX = max(selection.start.x, selection.current.x)
        Rectangle()
            .fill(Color.accentColor.opacity(0.14))
            .overlay {
                Rectangle()
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
            .frame(width: max(upperX - lowerX, 1), height: plotFrame.height)
            .offset(x: lowerX, y: plotFrame.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Watches Option-scroll while the pointer is inside this chart surface. The
/// monitor's closure is replaced on every SwiftUI update, so it never holds a
/// stale metrics snapshot after a background refresh.
private struct HostChartScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func install(on view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.modifierFlags.contains(.option),
                      let view = self.view,
                      let window = view.window,
                      event.window === window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                self.onScroll(event.scrollingDeltaY)
                return nil
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { remove() }
    }
}

private extension HostMetricsChartPreparation.TenantSeries {
    var color: Color {
        let palette: [Color] = [.teal, .orange, .pink, .green, .indigo, .mint, .cyan, .brown]
        let stableIndex = id.utf8.reduce(0) { (value, byte) in (value &* 31 &+ Int(byte)) & 0x7fff_ffff }
        return palette[stableIndex % palette.count]
    }
}

private struct HostChartPreparationKey: Hashable {
    let hostCount: Int
    let hostLast: Date?
    let serviceCount: Int
    let serviceLast: Date?
    let historyRevision: UInt64
    let latest: NornHostMetrics
    let window: NornHostMetricsWindow
    let viewport: Date
    let viewportDuration: TimeInterval
    let includesServiceMetrics: Bool
}

private struct HostChartHistoryRequestKey: Hashable {
    let window: NornHostMetricsWindow
    let viewportEnd: Date?
    let includesServiceMetrics: Bool
}

private struct HostMetricsTimestamp: View {
    let metrics: NornHostMetrics
    var alignment: HorizontalAlignment = .trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didUpdate = false

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(metrics.stale ? "Last sampled" : "Sampled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(metrics.observedAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(metrics.stale ? .orange : .secondary)
                .scaleEffect(didUpdate ? 1.04 : 1)
                .opacity(didUpdate ? 0.72 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: didUpdate)
            Text("Every \(metrics.samplePeriodSeconds.formatted(.number.precision(.fractionLength(0)))) seconds")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onChange(of: metrics.observedAt) { _, _ in
            guard !reduceMotion else { return }
            didUpdate = true
            Task {
                try? await Task.sleep(for: .milliseconds(460))
                didUpdate = false
            }
        }
    }
}

private struct HostReceiptStatus: View {
    let operation: NornOperation

    private var tint: Color {
        switch operation.status {
        case .succeeded: .green
        case .failed, .canceled: .red
        case .queued, .running: .accentColor
        }
    }

    private var symbol: String {
        switch operation.status {
        case .succeeded: "checkmark.circle.fill"
        case .failed, .canceled: "exclamationmark.triangle.fill"
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(operation.status.rawValue.capitalized, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
            Text(operation.message ?? "Operation \(operation.id)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(operation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct HostServiceRow: View {
    let service: NornService
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: service.isPassing ? "checkmark.circle.fill" : (service.isExpectedIdle ? "moon.zzz.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(service.isPassing ? .green : (service.isExpectedIdle ? .secondary : .orange))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.body.weight(.medium))
                Text("\(service.type.capitalized) · \(service.reachability.exposure.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(service.displayStatus.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(service.isPassing ? .green : (service.isExpectedIdle ? .secondary : .orange))
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(service.name), \(service.displayStatus)")
        .accessibilityHint(showsDisclosure ? "Opens this service" : "")
    }
}

private struct HostReceiptRow: View {
    let operation: NornOperation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: operation.status == .succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(operation.status == .succeeded ? .green : .orange)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.message ?? operation.status.rawValue.capitalized)
                    .font(.body.weight(.medium))
                Text("\(operation.id.prefix(8)) · \(operation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the durable operation receipt")
    }
}

#Preview("Host") {
    HostFeatureView(
        snapshot: NornFixtures.snapshot,
        metrics: NornFixtures.hostMetrics,
        metricHistory: NornFixtures.hostMetricsHistory
    )
        .frame(width: 1_100, height: 760)
}

#Preview("Host Attention") {
    HostFeatureView(snapshot: NornFixtures.snapshot, isConnected: false)
        .frame(width: 1_100, height: 760)
}
