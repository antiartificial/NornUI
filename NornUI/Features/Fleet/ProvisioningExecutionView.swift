import SwiftUI

struct ProvisioningExecutionView: View {
    let snapshot: NornDashboardSnapshot
    let deployments: [NornDeployment]
    let steps: [String: [NornDeploymentStep]]
    let isSupported: Bool
    let isStale: Bool

    private var activePlatformOperation: NornOperation? {
        snapshot.operations
            .filter { $0.kind.hasPrefix("platform.") && $0.status.isActive }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    private var currentRelease: NornRelease? {
        snapshot.releases.first(where: \.current)
    }

    private var visibleDeployments: [NornDeployment] {
        Array(deployments.sorted { $0.startedAt > $1.startedAt }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Execution")
                    .font(.title2.weight(.semibold))
                Spacer()
                if isStale {
                    Label("Cached", systemImage: "clock.badge.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Execution data is cached")
                }
            }

            platformState

            if !isSupported {
                ContentUnavailableView(
                    "Deployment Checkpoints Unavailable",
                    systemImage: "rectangle.stack.badge.questionmark",
                    description: Text("This server does not advertise regional deployment visibility.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if visibleDeployments.isEmpty {
                ContentUnavailableView(
                    "No Deployments Reported",
                    systemImage: "shippingbox",
                    description: Text("Norn has not returned deployment history from the authenticated compatibility surface.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 10) {
                    ForEach(visibleDeployments) { deployment in
                        DeploymentJourney(deployment: deployment, steps: steps[deployment.id] ?? [])
                    }
                }
            }
        }
    }

    private var platformState: some View {
        HStack(spacing: 12) {
            Image(systemName: activePlatformOperation == nil ? "checkmark.shield.fill" : "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(activePlatformOperation == nil ? .green : .accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(activePlatformOperation == nil ? "Platform steady" : "Platform change active")
                    .font(.headline)
                Text(activePlatformOperation?.kind.replacingOccurrences(of: ".", with: " ").capitalized
                     ?? currentRelease.map { "Current release \($0.version) · \($0.sha.prefix(8))" }
                     ?? "No current release marker reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let operation = activePlatformOperation {
                ExecutionStateBadge(state: operation.status == .queued ? .pending : .active)
            } else {
                ExecutionStateBadge(state: .completed)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator) }
        .accessibilityElement(children: .combine)
    }
}

private struct DeploymentJourney: View {
    let deployment: NornDeployment
    let steps: [NornDeploymentStep]

    @State private var expanded = false

    private var state: NornExecutionCheckpointState {
        switch deployment.status {
        case .failed: .failed
        case .healthy, .deployed: .completed
        case .queued: .pending
        case .building, .testing, .migrating, .submitting: .active
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if steps.isEmpty {
                    Label("No stage checkpoints returned", systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(steps.sorted { $0.startedAt < $1.startedAt }) { step in
                        HStack(spacing: 10) {
                            ExecutionStateIcon(state: step.executionState)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.step.replacingOccurrences(of: "-", with: " ").capitalized)
                                HStack(spacing: 6) {
                                    Text(step.kind == .mutable ? "Mutable" : "Read only")
                                    if let attempt = step.attempt { Text("Attempt \(attempt)") }
                                    if let durationMs = step.durationMs, durationMs > 0 {
                                        Text(Duration.milliseconds(durationMs).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ExecutionStateBadge(state: step.executionState)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(step.step), \(step.executionState.rawValue), \(step.kind == .mutable ? "mutable" : "read only")")
                    }
                }

                if let regions = deployment.regions, !regions.isEmpty {
                    Divider()
                    ForEach(regions, id: \.region) { region in
                        LabeledContent(region.region) {
                            Text("\(region.activeWeight)% active / \(region.desiredWeight)% desired")
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                ExecutionStateIcon(state: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deployment.app).font(.headline)
                    Text("\(deployment.status.rawValue.capitalized) · \(deployment.commitSHA.prefix(8)) · \(deployment.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ExecutionStateBadge(state: state)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Copy Deployment ID") { copy(deployment.id) }
            Button("Copy Commit SHA") { copy(deployment.commitSHA) }
            if !deployment.sagaID.isEmpty {
                Button("Copy Saga ID") { copy(deployment.sagaID) }
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct ExecutionStateIcon: View {
    let state: NornExecutionCheckpointState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.tint)
            .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: state == .active && !reduceMotion)
            .accessibilityHidden(true)
    }
}

struct ExecutionStateBadge: View {
    let state: NornExecutionCheckpointState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .accessibilityLabel("State: \(state.title)")
    }
}

extension NornExecutionCheckpointState {
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .pending: "clock"
        case .active: "arrow.triangle.2.circlepath"
        case .failed: "xmark.octagon.fill"
        case .blocked: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .completed: .green
        case .pending: .secondary
        case .active: .accentColor
        case .failed: .red
        case .blocked: .orange
        }
    }
}

private extension NornDeploymentStep {
    var executionState: NornExecutionCheckpointState {
        switch status {
        case .running: .active
        case .complete: .completed
        case .failed: .failed
        }
    }
}
