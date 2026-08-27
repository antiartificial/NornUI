//
//  HostFeatureView.swift
//  NornUI
//
//  A quiet readiness surface for the host that runs Norn's independent assurance lane.
//

import AppKit
import Foundation
import SwiftUI

struct HostFeatureView: View {
    let health: NornHealth
    let services: [NornService]
    let operations: [NornOperation]
    let observedAt: Date?
    let isConnected: Bool
    let metrics: NornHostMetrics?
    let isMetricsSupported: Bool
    var onQueue: (NornMaintenanceRequest) -> Void = { _ in }
    var onOpenOperation: (NornOperation) -> Void = { _ in }
    var onRefresh: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingAllServices = false

    init(
        snapshot: NornDashboardSnapshot,
        isConnected: Bool = true,
        metrics: NornHostMetrics? = nil,
        isMetricsSupported: Bool? = nil,
        onQueue: @escaping (NornMaintenanceRequest) -> Void = { _ in },
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onRefresh: @escaping () -> Void = {}
    ) {
        self.health = snapshot.health
        self.services = snapshot.services
        self.operations = snapshot.operations
        self.observedAt = snapshot.observedAt
        self.isConnected = isConnected
        self.metrics = metrics
        self.isMetricsSupported = isMetricsSupported ?? snapshot.capabilities.supportsHostMetrics
        self.onQueue = onQueue
        self.onOpenOperation = onOpenOperation
        self.onRefresh = onRefresh
    }

    init(
        health: NornHealth,
        services: [NornService],
        operations: [NornOperation],
        observedAt: Date? = nil,
        isConnected: Bool = true,
        metrics: NornHostMetrics? = nil,
        isMetricsSupported: Bool = false,
        onQueue: @escaping (NornMaintenanceRequest) -> Void = { _ in },
        onOpenOperation: @escaping (NornOperation) -> Void = { _ in },
        onRefresh: @escaping () -> Void = {}
    ) {
        self.health = health
        self.services = services
        self.operations = operations
        self.observedAt = observedAt
        self.isConnected = isConnected
        self.metrics = metrics
        self.isMetricsSupported = isMetricsSupported
        self.onQueue = onQueue
        self.onOpenOperation = onOpenOperation
        self.onRefresh = onRefresh
    }

    private var passingServiceCount: Int { services.filter(\.isPassing).count }
    private var attentionServices: [NornService] { services.filter { !$0.isPassing } }
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
            VStack(alignment: .leading, spacing: 20) {
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
                Text("of \(services.count) services passing")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(passingServiceCount) of \(services.count) services passing")

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(readinessChecks, id: \.name) { check in
                    GridRow {
                        Label(check.name, systemImage: check.symbol)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(check.status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(check.isPassing ? .green : .orange)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var metricsCard: some View {
        if !isMetricsSupported {
            NornSurfaceCard(title: "Host metrics", subtitle: "Optional server capability") {
                Label("Host metrics are not available on this server.", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Host metrics unavailable on this server")
            }
        } else if let metrics {
            NornSurfaceCard(
                title: "Host metrics",
                subtitle: "CPU and memory",
                accessory: {
                    NornStatusBadge(
                        status: metrics.stale ? .attention : .healthy,
                        label: metrics.stale ? "Stale" : "Current"
                    )
                }
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        metricValues(metrics)
                        Spacer(minLength: 0)
                        HostMetricsTimestamp(metrics: metrics)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 22) {
                            metricValues(metrics)
                        }
                        HostMetricsTimestamp(metrics: metrics, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metricsAccessibilityLabel(metrics))
            }
        } else {
            NornSurfaceCard(title: "Host metrics", subtitle: "CPU and memory") {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isConnected ? "Waiting for the first metrics sample." : "Metrics will resume when the server reconnects.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(isConnected ? "Waiting for the first host metrics sample" : "Host metrics will resume when the server reconnects")
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
                    .disabled(!isConnected || activeAssurance != nil)
                    .accessibilityHint("Queues a durable host assurance operation")
                if let latestAssurance {
                    Button("Open Receipt") { onOpenOperation(latestAssurance) }
                        .buttonStyle(.bordered)
                }
            }

            if !isConnected {
                Label("Reconnect to queue assurance.", systemImage: "wifi.slash")
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
                    HostServiceRow(service: service)
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

    private var hostIsHealthy: Bool {
        health.status.lowercased() == "ok" && attentionServices.isEmpty
    }

    private var readinessChecks: [(name: String, status: String, symbol: String, isPassing: Bool)] {
        health.services
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { name, status in
                let passing = ["up", "ok", "passing"].contains(status.lowercased())
                return (name.capitalized, status.uppercased(), passing ? "checkmark.circle" : "exclamationmark.triangle", passing)
            }
    }

    private func queueAssurance() {
        onQueue(.hostAssurance)
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
        return "Host metrics, \(freshness). CPU \(metrics.cpu.utilizationPercent.formatted(.number.precision(.fractionLength(1)))) percent across \(metrics.cpu.logicalCores) logical cores. Memory \(byteCount(metrics.memory.usedBytes)) used of \(byteCount(metrics.memory.totalBytes)), \(byteCount(metrics.memory.availableBytes)) available. Sampled \(metrics.observedAt.formatted(date: .abbreviated, time: .standard))."
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

private struct HostMetricsTimestamp: View {
    let metrics: NornHostMetrics
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(metrics.stale ? "Last sampled" : "Sampled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(metrics.observedAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(metrics.stale ? .orange : .secondary)
            Text("Every \(metrics.samplePeriodSeconds.formatted(.number.precision(.fractionLength(0)))) seconds")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: service.isPassing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(service.isPassing ? .green : .orange)
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
            Text(service.status.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(service.isPassing ? .green : .orange)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(service.name), \(service.status)")
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
    HostFeatureView(snapshot: NornFixtures.snapshot, metrics: NornFixtures.hostMetrics)
        .frame(width: 1_100, height: 760)
}

#Preview("Host Attention") {
    HostFeatureView(snapshot: NornFixtures.snapshot, isConnected: false)
        .frame(width: 1_100, height: 760)
}
