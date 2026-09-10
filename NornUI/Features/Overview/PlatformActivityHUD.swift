import SwiftUI

/// A bounded view of authoritative work, with execution graphs only for matching sagas.
struct PlatformActivityHUD: View {
    let operations: [NornOperation]
    let recentOperations: [NornOperation]
    let deployments: [NornDeployment]
    let steps: [String: [NornDeploymentStep]]
    let isLive: Bool
    var stepErrors: [String: String] = [:]
    var errorMessage: String?
    var onOpenOperation: (NornOperation) -> Void = { _ in }
    var onOpenDeployment: (NornDeployment) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeOperations: [NornOperation] {
        PlatformActivitySelection.active(operations)
    }

    private var receipts: [NornOperation] {
        PlatformActivitySelection.receipts(recentOperations, excluding: Set(activeOperations.map(\.id)), now: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Happening now", systemImage: "waveform.path")
                    .font(.headline)
                Spacer()
                Text(isLive ? "Live platform activity" : "Last reported activity")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if activeOperations.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: isLive ? "checkmark.circle" : "clock.arrow.circlepath")
                        .font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isLive && errorMessage == nil ? "Nothing in flight" : "Live activity is paused or unavailable")
                            .font(.subheadline.weight(.medium))
                        Text(isLive ? "Deployments and other platform work will appear here as they begin." : "Live updates are paused or unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier("overview.activity.quiet")
            } else {
                ForEach(Array(activeOperations.prefix(3))) { operation in
                    activeCard(operation)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
                if activeOperations.count > 3 {
                    Text("\(activeOperations.count - 3) more in flight · Open Operations for all activity")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !receipts.isEmpty {
                Divider()
                Text("JUST FINISHED")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(receipts) { operation in
                    Button { onOpenOperation(operation) } label: {
                        HStack(spacing: 9) {
                            NornStatusGlyph(status: NornStatus(operationStatus: operation.status), size: 13)
                            Text(operation.app ?? kindLabel(operation))
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(kindLabel(operation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(operation.status.rawValue.capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                            Text((operation.finishedAt ?? operation.updatedAt).formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open operation receipt")
                    .accessibilityIdentifier("overview.activity.receipt.\(operation.id)")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: Array(activeOperations.prefix(3).map(\.id)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.activity.hud")
    }

    private func activeCard(_ operation: NornOperation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NornStatusGlyph(status: NornStatus(operationStatus: operation.status), size: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(operation.app ?? kindLabel(operation)).font(.subheadline.weight(.semibold))
                    Text(kindLabel(operation)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    NornStatusBadge(status: NornStatus(operationStatus: operation.status), label: operation.status.rawValue.capitalized)
                    PlatformActivityElapsed(operation: operation, isLive: isLive)
                }
                Button { onOpenOperation(operation) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open operation details")
                .accessibilityLabel("Open \(operation.app ?? kindLabel(operation)) operation details")
            }
            if let message = operation.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let deployment = matchingDeployment(operation) {
                DeploymentPipelineGraph(
                    deployment: deployment,
                    steps: steps[deployment.id] ?? [],
                    errorMessage: stepErrors[deployment.id],
                    isLive: isLive
                )
                Button("Open deployment") { onOpenDeployment(deployment) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.activity.operation.\(operation.id)")
    }

    private func matchingDeployment(_ operation: NornOperation) -> NornDeployment? {
        PlatformActivitySelection.deployment(for: operation, in: deployments)
    }

    private func kindLabel(_ operation: NornOperation) -> String {
        operation.kind.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct PlatformActivityElapsed: View {
    let operation: NornOperation
    let isLive: Bool

    var body: some View {
        if isLive && operation.status.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                elapsed(at: context.date)
            }
        } else {
            elapsed(at: operation.finishedAt ?? operation.updatedAt)
        }
    }

    private func elapsed(at date: Date) -> some View {
        Text(Duration.seconds(max(0, date.timeIntervalSince(operation.startedAt)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityLabel("Elapsed time")
    }
}

nonisolated enum PlatformActivitySelection {
    static func active(_ operations: [NornOperation]) -> [NornOperation] {
        operations.filter(\.status.isActive).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
    }

    static func receipts(_ operations: [NornOperation], excluding activeIDs: Set<String>, now: Date) -> [NornOperation] {
        let cutoff = now.addingTimeInterval(-600)
        var seen = Set<String>()
        return operations.filter {
            $0.status.isTerminal && ($0.finishedAt ?? $0.updatedAt) >= cutoff
                && !activeIDs.contains($0.id)
        }.sorted {
            ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt)
        }.filter { seen.insert($0.id).inserted }.prefix(2).map { $0 }
    }

    static func deployment(for operation: NornOperation, in deployments: [NornDeployment]) -> NornDeployment? {
        guard let sagaID = operation.sagaID, !sagaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return deployments.filter { $0.sagaID == sagaID }.max { $0.startedAt < $1.startedAt }
    }
}
