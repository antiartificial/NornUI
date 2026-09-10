import SwiftUI

struct AppRuntimeControls: View {
    let app: NornAppStatus
    let canManage: Bool
    let isBusy: Bool
    let feedback: String?
    let issueMutationContext: () -> NornMutationContext?
    let onApply: ([NornRuntimeScaleTarget], NornMutationContext) async -> Void

    @State private var isEditing = false
    @State private var reviewedProcesses: [String] = []
    @State private var counts: [String: Int] = [:]
    @State private var mutationContext: NornMutationContext?

    private var processes: [String] { NornRuntimeScaling.eligibleProcesses(for: app) }
    private var unavailableReason: String? { NornRuntimeScaling.unavailableReason(for: app) }
    private var targets: [NornRuntimeScaleTarget] {
        reviewedProcesses.map { .init(process: $0, count: counts[$0, default: 0]) }
    }
    private var isSuspending: Bool { !targets.isEmpty && targets.allSatisfy { $0.count == 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Runtime", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            if let unavailableReason {
                Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button("Suspend…", systemImage: "pause.fill") { beginEditing(suspend: true) }
                        .accessibilityIdentifier("apps.runtime.suspend")
                    Button("Resume / Scale…", systemImage: "slider.horizontal.3") {
                        beginEditing(suspend: false)
                    }
                    .accessibilityIdentifier("apps.runtime.scale")
                }
                .disabled(!canManage || isBusy)
                Text(canManage ? "Adjust running instances without changing the app’s deployment settings." : "Runtime changes require a connection with scaling permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let feedback, !feedback.isEmpty {
                Text(feedback).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("apps.runtime.feedback")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("apps.runtime")
        .popover(isPresented: $isEditing, arrowEdge: .leading) { editor }
        .onChange(of: canManage) { _, allowed in if !allowed { isEditing = false; mutationContext = nil } }
        .onChange(of: app.spec) { _, _ in isEditing = false; mutationContext = nil }
        .onChange(of: app.id) { _, _ in isEditing = false; mutationContext = nil }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isSuspending ? "Suspend \(app.spec.name)" : "Scale \(app.spec.name)").font(.headline)
            Text("Review suggested instance counts from the app’s configuration. These are not saved runtime counts.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(reviewedProcesses, id: \.self) { process in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process).fontWeight(.medium)
                                Text(observedCount(for: process)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper(value: countBinding(for: process), in: 0...NornRuntimeScaling.maxCount(for: app, process: process)) {
                                Text("\(counts[process, default: 0])").monospacedDigit().frame(minWidth: 28)
                            }
                            .fixedSize()
                            .accessibilityLabel("\(process) target instances")
                            .accessibilityIdentifier("apps.runtime.count.\(process)")
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            Text(isSuspending
                 ? "Zero targets stop running processes and interrupt service. Deployment or host assurance may replace these runtime targets."
                 : "Processes set to zero will stop. Deployment or host assurance may reset these runtime counts.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Processes update one at a time. If a change fails, earlier changes may already have applied.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { isEditing = false; mutationContext = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSuspending ? "Suspend App" : "Apply Counts") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canManage || isBusy || mutationContext == nil || targets.isEmpty)
                    .accessibilityIdentifier("apps.runtime.apply")
            }
        }
        .padding(18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func observedCount(for process: String) -> String {
        guard let count = app.allocationSummary?.byProcess?[process]?.running else { return "Running count unavailable" }
        return "\(count) currently running"
    }

    private func countBinding(for process: String) -> Binding<Int> {
        Binding(get: { counts[process, default: 0] }, set: { counts[process] = $0 })
    }

    private func beginEditing(suspend: Bool) {
        guard canManage, !isBusy, let context = issueMutationContext() else { return }
        reviewedProcesses = processes
        counts = Dictionary(uniqueKeysWithValues: NornRuntimeScaling.targets(for: app).map {
            ($0.process, suspend ? 0 : min(NornRuntimeScaling.maxCount(for: app, process: $0.process), max(1, $0.count)))
        })
        mutationContext = context
        isEditing = true
    }

    private func apply() {
        guard canManage, !isBusy, let context = mutationContext else { return }
        let reviewedTargets = targets
        isEditing = false
        mutationContext = nil
        Task { await onApply(reviewedTargets, context) }
    }
}
