import SwiftUI

/// A chronological execution story. Connections show reported order, not inferred dependencies.
struct DeploymentPipelineGraph: View {
    let deployment: NornDeployment
    let steps: [NornDeploymentStep]
    var isLoading = false
    var errorMessage: String?
    var isLive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedStepID: String?

    private var orderedSteps: [NornDeploymentStep] {
        steps.filter { $0.deploymentID == deployment.id }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.step < $1.step
        }
    }

    private var selectedStep: NornDeploymentStep? {
        orderedSteps.first { $0.id == selectedStepID }
            ?? orderedSteps.last { $0.status == .running || $0.status == .failed }
            ?? orderedSteps.last
    }

    private var attentionStepID: String? {
        orderedSteps.last { $0.status == .running || $0.status == .failed }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Deployment journey", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing deployment steps") }
                Text(isLive && deployment.status.isActive ? deployment.status.rawValue.capitalized : "Last reported \(deployment.status.rawValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(deployment.status == .failed ? Color.red : Color.secondary)
            }

            Text(deployment.app).font(.subheadline.weight(.semibold))
            Text("Started \(deployment.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let finished = deployment.finishedAt {
                Text("Total \(Duration.seconds(max(0, finished.timeIntervalSince(deployment.startedAt))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if isLive && deployment.status.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Elapsed \(Duration.seconds(max(0, context.date.timeIntervalSince(deployment.startedAt))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if orderedSteps.isEmpty {
                Text(isLoading ? "Loading reported steps…" : "No steps reported yet. The deployment is \(deployment.status.rawValue).")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(orderedSteps.enumerated()), id: \.element.id) { index, step in
                                if index > 0 {
                                    Image(systemName: "arrow.right")
                                        .font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                                        .frame(width: 28).accessibilityHidden(true)
                                }
                                stepNode(step).id(step.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: attentionStepID, initial: true) { old, value in
                        guard let value else { return }
                        withAnimation(reduceMotion || old == nil ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                    }
                }
                .frame(height: 108)
                .accessibilityIdentifier("deployment.journey.graph")

                if let step = selectedStep {
                    stepDetail(step)
                }
            }
            Text("Reported execution order · Select a step for details. Upcoming steps appear when Norn reports them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: deployment.id) { _, _ in selectedStepID = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deployment.journey")
    }

    private func stepNode(_ step: NornDeploymentStep) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selectedStepID = step.id }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(step.step.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "), systemImage: symbol(step.status))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(step.status == .running && !isLive ? "Last reported running" : step.status.rawValue.capitalized).font(.caption)
                    Spacer(minLength: 3)
                    DeploymentStepDuration(step: step, runsClock: isLive && deployment.status.isActive)
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 184, height: 82, alignment: .leading)
            .background(tint(step.status).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tint(step.status).opacity(selectedStep?.id == step.id ? 0.9 : 0.35), lineWidth: selectedStep?.id == step.id ? 2 : 1)
            }
            .foregroundStyle(tint(step.status))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Show \(step.step) details")
        .accessibilityIdentifier("deployment.step.\(step.step)")
        .accessibilityAddTraits(selectedStep?.id == step.id ? .isSelected : [])
    }

    private func stepDetail(_ step: NornDeploymentStep) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(step.step).font(.subheadline.weight(.medium)).textSelection(.enabled)
                Spacer()
                if let attempt = step.attempt { Text("Attempt \(attempt)").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 14) {
                Text("Started \(step.startedAt.formatted(date: .abbreviated, time: .standard))")
                if let finished = step.finishedAt {
                    Text("Finished \(finished.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text("Duration").font(.caption).foregroundStyle(.secondary)
                DeploymentStepDuration(step: step, runsClock: isLive && deployment.status.isActive)
            }
            if let message = step.message, !message.isEmpty {
                Text(message).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deployment.step-details")
    }

    private func symbol(_ status: NornDeploymentStepStatus) -> String {
        switch status {
        case .running: "arrow.triangle.2.circlepath"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ status: NornDeploymentStepStatus) -> Color {
        switch status {
        case .running: .accentColor
        case .complete: .green
        case .failed: .red
        }
    }
}

private struct DeploymentStepDuration: View {
    let step: NornDeploymentStep
    let runsClock: Bool

    var body: some View {
        if runsClock && step.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                durationText(now: context.date)
            }
        } else {
            durationText(now: step.finishedAt ?? step.startedAt)
        }
    }

    private func durationText(now: Date) -> some View {
        Text(DeploymentStepTiming.description(step, now: now, runsClock: runsClock))
            .font(.caption.monospacedDigit())
            .fixedSize()
    }
}

nonisolated enum DeploymentStepTiming {
    static func seconds(_ step: NornDeploymentStep, now: Date, runsClock: Bool) -> TimeInterval? {
        if let duration = step.durationMs { return max(0, Double(duration) / 1_000) }
        if let end = step.finishedAt { return max(0, end.timeIntervalSince(step.startedAt)) }
        guard runsClock, step.status == .running else { return nil }
        return max(0, now.timeIntervalSince(step.startedAt))
    }

    static func description(_ step: NornDeploymentStep, now: Date, runsClock: Bool) -> String {
        guard let seconds = seconds(step, now: now, runsClock: runsClock) else { return "Time unreported" }
        if seconds < 1 { return "<1s" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}
