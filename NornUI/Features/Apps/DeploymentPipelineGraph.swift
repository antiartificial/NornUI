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
    @State private var followsProgress = true
    @State private var graphContentSize = CGSize.zero
    @State private var graphViewportSize = CGSize.zero
    @State private var hasPositionedGraph = false

    private var orderedSteps: [NornDeploymentStep] {
        steps.filter { $0.deploymentID == deployment.id }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.step < $1.step
        }
    }

    private var selectedStep: NornDeploymentStep? {
        if followsProgress { return orderedSteps.first { $0.id == attentionStepID } }
        return orderedSteps.first { $0.id == selectedStepID }
            ?? orderedSteps.first { $0.id == attentionStepID }
    }

    private var attentionStepID: String? {
        DeploymentStepFocus.attentionID(in: orderedSteps)
    }

    private var scrollRequest: GraphScrollRequest {
        GraphScrollRequest(
            deploymentID: deployment.id,
            targetID: followsProgress ? attentionStepID : selectedStep?.id,
            contentSize: graphContentSize, viewportSize: graphViewportSize
        )
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
                        HStack(spacing: 0) {
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
                        .onGeometryChange(for: CGSize.self) { $0.size } action: {
                            graphContentSize = $0
                        }
                    }
                    .scrollIndicators(.visible)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: {
                        graphViewportSize = $0
                    }
                    .task(id: scrollRequest) {
                        // Layout must establish the target before scrolling, including when
                        // the latest step arrives in the same update as a wider graph.
                        guard let target = scrollRequest.targetID,
                              graphContentSize.width > 0, graphViewportSize.width > 0 else { return }
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion || !hasPositionedGraph ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        hasPositionedGraph = true
                    }
                }
                .frame(height: 108)
                .accessibilityIdentifier("deployment.journey.graph")

                HStack(spacing: 8) {
                    Toggle("Follow progress", isOn: $followsProgress)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Keep the current deployment step visible. Selecting a past step pauses following.")
                        .accessibilityIdentifier("deployment.journey.follow")
                    if !followsProgress {
                        Text("Inspecting a step")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let step = selectedStep {
                    stepDetail(step)
                }
            }
            Text("Reported execution order · Select a step for details. Upcoming steps appear when Norn reports them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: deployment.id) { _, _ in
            selectedStepID = nil
            followsProgress = true
            hasPositionedGraph = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deployment.journey")
    }

    private func stepNode(_ step: NornDeploymentStep) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                selectedStepID = step.id
                followsProgress = step.id == attentionStepID
            }
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

private struct GraphScrollRequest: Equatable {
    let deploymentID: String
    let targetID: String?
    let contentSize: CGSize
    let viewportSize: CGSize
}

nonisolated enum DeploymentStepFocus {
    /// A retried deployment can retain failed steps; current work takes precedence.
    static func attentionID(in orderedSteps: [NornDeploymentStep]) -> String? {
        orderedSteps.last { $0.status == .running }?.id ?? orderedSteps.last?.id
    }
}
