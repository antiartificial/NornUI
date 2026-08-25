import SwiftUI

struct FleetFeatureView: View {
    let inventory: NornFleetInventory
    let plans: [NornOperation]
    let reconciliations: [String: [NornOperation]]
    let githubStatus: NornFleetGitHubStatus
    let isSupported: Bool
    let canPlan: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onPlan: (String, Int, String, String) async -> Bool
    let onOpenReview: (String) async -> URL?
    let onDispatchApply: (String, Bool) async -> URL?
	let onOpenOperation: (NornOperation) -> Void

    @State private var planningPool: PoolSelection?

    private var pools: [PoolSelection] {
        inventory.nodePools
            .map { PoolSelection(name: $0.key, pool: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if !isSupported {
                ContentUnavailableView(
                    "Fleet Unavailable",
                    systemImage: "server.rack",
                    description: Text("Upgrade this Norn server to a release that advertises the complete fleet contract.")
                )
            } else if !inventory.configured {
                ContentUnavailableView {
                    Label("Connect norn-fleet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Point Norn at a read-only norn.dev/fleet/v1 document. Cloud credentials remain in the protected runner.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        fleetHeader
                        findings
                        poolGrid
                        planHistory
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { onRefresh() }
            }
        }
        .navigationTitle("Fleet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh Fleet", systemImage: "arrow.clockwise", action: onRefresh)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(isRefreshing)
            }
        }
        .sheet(item: $planningPool) { selection in
            FleetCapacitySheet(name: selection.name, pool: selection.pool) { desired, size, reason in
                let succeeded = await onPlan(selection.name, desired, size, reason)
                if succeeded { planningPool = nil }
                return succeeded
            }
        }
    }

    private var fleetHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DESIRED INFRASTRUCTURE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(inventory.document?.cluster.name ?? inventory.validation?.name ?? "Fleet")
                    .font(.largeTitle.weight(.semibold))
                Text([
                    inventory.document?.cluster.provider,
                    inventory.document?.cluster.region,
                    inventory.document?.metadata?.environment
                ].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 7) {
                Label(
                    inventory.validation?.valid == false ? "Needs attention" : "Schema valid",
                    systemImage: inventory.validation?.valid == false ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
                )
                .foregroundStyle(inventory.validation?.valid == false ? .orange : .green)
                .accessibilityLabel(inventory.validation?.valid == false ? "Fleet document needs attention" : "Fleet document is valid")
                Label(githubStatus.connected ? "GitHub connected" : githubStatus.configured ? "GitHub needs attention" : "GitHub not configured", systemImage: githubStatus.connected ? "link.circle.fill" : "link.badge.plus")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(githubStatus.connected ? .green : .secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var findings: some View {
        if let findings = inventory.validation?.findings, !findings.isEmpty {
            GroupBox("Sanity Findings") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: finding.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.severity == "error" ? .red : .orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.message)
                                Text(finding.code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
    }

    private var poolGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Node Pools")
                .font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                ForEach(pools) { selection in
                    FleetPoolCard(name: selection.name, pool: selection.pool, canPlan: canPlan && inventory.validation?.valid != false) {
                        planningPool = selection
                    }
                }
            }
        }
    }

    private var planHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Durable Changes")
                    .font(.title2.weight(.semibold))
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing fleet changes") }
            }
            Text("Every view is reconstructed from Norn. Closing the app does not lose the plan or its recovery position.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if plans.isEmpty {
                ContentUnavailableView(
                    "No Capacity Changes",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Choose a node pool to prepare an expansion or contraction.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 10) {
                    ForEach(plans) { plan in
                        FleetPlanJourney(
                            plan: plan,
                            checkpoints: reconciliations[plan.id] ?? [],
                            fallbackWorkflowURL: inventory.document?.metadata?.workflowURL,
                            canUseGitHub: githubStatus.connected,
                            onOpenReview: onOpenReview,
                            onDispatchApply: onDispatchApply,
							onOpenOperation: onOpenOperation
                        )
                    }
                }
            }
        }
    }
}

private struct FleetPoolCard: View {
    let name: String
    let pool: NornFleetNodePool
    let canPlan: Bool
    let onPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pool.labels?["workload"]?.uppercased() ?? "NODE POOL")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(name).font(.title3.weight(.semibold))
                }
                Spacer()
                Text("\(pool.desired) desired")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.green.opacity(0.12), in: Capsule())
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow { metric("Size", pool.size); metric("Range", "\(pool.min)–\(pool.max)") }
                GridRow { metric("Replacement", pool.replacement?.strategy ?? "blueGreen"); metric("Drain", pool.replacement?.drainTimeout ?? "Not set") }
            }
            Button("Change Capacity…", systemImage: "arrow.up.arrow.down", action: onPlan)
                .disabled(!canPlan)
                .help(canPlan ? "Prepare a durable capacity change" : "Connect with write access and fix fleet validation findings first")
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.separator) }
        .contextMenu {
            Button("Change Capacity…", systemImage: "arrow.up.arrow.down", action: onPlan).disabled(!canPlan)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced().weight(.medium)).lineLimit(1)
        }
    }
}

private struct FleetCapacitySheet: View {
    let name: String
    let pool: NornFleetNodePool
    let onSubmit: (Int, String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var desired: Int
    @State private var size: String
    @State private var reason = ""
    @State private var isSubmitting = false

    init(name: String, pool: NornFleetNodePool, onSubmit: @escaping (Int, String, String) async -> Bool) {
        self.name = name
        self.pool = pool
        self.onSubmit = onSubmit
        _desired = State(initialValue: pool.desired)
        _size = State(initialValue: pool.size)
    }

    private var isContraction: Bool { desired < pool.desired }
    private var isReplacement: Bool { size.trimmingCharacters(in: .whitespacesAndNewlines) != pool.size }
    private var actionTitle: String {
        if isContraction { return "Prepare Contraction" }
        if isReplacement { return "Prepare Replacement" }
        return desired > pool.desired ? "Record Expansion" : "Record Reconciliation"
    }
    private var reasonIsValid: Bool { reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Change \(name)").font(.title2.weight(.semibold))
                    Text("The durable plan survives app, API, and runner restarts.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }

            HStack(spacing: 14) {
                capacityValue("Current", pool.desired)
                Image(systemName: isContraction ? "arrow.down.forward" : "arrow.up.forward")
                    .font(.title2.weight(.semibold)).foregroundStyle(isContraction ? .orange : .accentColor)
                    .accessibilityHidden(true)
                capacityValue("Proposed", desired)
            }
            .frame(maxWidth: .infinity)

            Form {
                Stepper(value: $desired, in: pool.min...pool.max) {
                    LabeledContent("Desired nodes") { Text("\(desired)").monospacedDigit() }
                }
                TextField("VM size", text: $size, prompt: Text(pool.size))
                TextField("Reason", text: $reason, prompt: Text("Why is this change needed?"))
                    .accessibilityHint("At least four characters; recorded in the durable plan")
            }
            .formStyle(.grouped)

            if isContraction {
                Label(
                    "Contraction is prepared, not immediately applied. Norn must prove allocation headroom, readiness, and old-node drain before deletion.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
                .padding(12)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label("Expansion can resume from the last matching provider and Norn checkpoint if its runner is interrupted.", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !reasonIsValid { Text("Add a short reason to continue.").font(.caption).foregroundStyle(.secondary) }
                Button(actionTitle) {
                    isSubmitting = true
                    Task {
                        _ = await onSubmit(desired, size, reason)
                        isSubmitting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || !reasonIsValid || size.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .accessibilityElement(children: .contain)
    }

    private func capacityValue(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
        }
        .frame(minWidth: 110)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FleetPlanJourney: View {
    let plan: NornOperation
    let checkpoints: [NornOperation]
    let fallbackWorkflowURL: String?
    let canUseGitHub: Bool
    let onOpenReview: (String) async -> URL?
    let onDispatchApply: (String, Bool) async -> URL?
	let onOpenOperation: (NornOperation) -> Void

    @State private var expanded = false
    @State private var isWorking = false
    @State private var reviewURL: URL?
    @State private var applyURL: URL?
    @State private var confirmingDestructiveApply = false

    private let phases = [
        "infrastructure_applied", "inventory_generated", "nodes_configured",
        "nodes_enrolled", "readiness_verified", "old_nodes_drained", "complete"
    ]

    private var payload: [String: JSONValue] { plan.payload ?? [:] }
    private var pool: String { payload["pool"]?.stringValue ?? "pool" }
    private var action: String { payload["action"]?.stringValue ?? "reconcile" }
    private var currentDesired: Int? { payload["current"]?.objectValue?["desired"]?.intValue }
    private var proposedDesired: Int? { payload["proposed"]?.objectValue?["desired"]?.intValue }
    private var workflowURL: URL? { URL(string: payload["workflowUrl"]?.stringValue ?? fallbackWorkflowURL ?? "") }
    private var completedPhases: Set<String> {
        Set(checkpoints.compactMap { checkpoint in
            guard checkpoint.status == .succeeded else { return nil }
            return checkpoint.payload?["phase"]?.stringValue
        })
    }
    private var isComplete: Bool { completedPhases.contains("complete") }
    private var isDestructive: Bool { action == "replace" || (action == "scale" && (proposedDesired ?? 0) < (currentDesired ?? 0)) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if checkpoints.isEmpty {
                    Label("Awaiting the protected runner", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Text("You can close Norn now. This plan ID is the resume key for the repository workflow.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(phases, id: \.self) { phase in
                        let succeeded = completedPhases.contains(phase)
                        HStack(spacing: 10) {
                            Image(systemName: succeeded ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(succeeded ? Color.green : Color.secondary.opacity(0.45))
                                .accessibilityHidden(true)
                            Text(phase.replacingOccurrences(of: "_", with: " ").capitalized)
                            Spacer()
                            if succeeded { Text("Proven").font(.caption).foregroundStyle(.secondary) }
                        }
                        .accessibilityLabel("\(phase.replacingOccurrences(of: "_", with: " ")), \(succeeded ? "proven" : "pending")")
                    }
                }
                Divider()
                HStack {
                    Text(plan.id).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                    Spacer()
					Button("View Receipt", systemImage: "doc.text.magnifyingglass") { onOpenOperation(plan) }
                    if canUseGitHub {
                        Button("Open Review", systemImage: "arrow.triangle.branch") { runOpenReview() }
                            .disabled(isWorking)
                        Button("Apply After Review", systemImage: "play.circle.fill") {
                            if isDestructive { confirmingDestructiveApply = true } else { runApply() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    } else if let workflowURL {
                        Link(destination: workflowURL) { Label("Continue in Protected Runner", systemImage: "arrow.up.right.square") }
                    }
                }
                if let reviewURL { Link("View Pull Request", destination: reviewURL) }
                if let applyURL { Link("View Apply Run", destination: applyURL) }
                Text("Repeating either action safely recovers the existing GitHub review or plan-named workflow run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isComplete ? "checkmark.seal.fill" : action == "scale" && (proposedDesired ?? 0) < (currentDesired ?? 0) ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(isComplete ? .green : .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pool).font(.headline)
                    if let currentDesired, let proposedDesired {
                        Text("\(currentDesired) → \(proposedDesired) nodes · \(action)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(action.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(isComplete ? "Complete" : checkpoints.isEmpty ? "Planned" : "In progress")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Open Fleet Review", systemImage: "arrow.triangle.branch") { runOpenReview() }.disabled(!canUseGitHub || isWorking)
            Button("Apply Reviewed Change", systemImage: "play.circle.fill") {
                if isDestructive { confirmingDestructiveApply = true } else { runApply() }
            }.disabled(!canUseGitHub || isWorking)
        }
        .confirmationDialog(
            "Apply reviewed destructive fleet change?",
            isPresented: $confirmingDestructiveApply,
            titleVisibility: .visible
        ) {
            Button("Apply Reviewed Change", role: .destructive) { runApply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The protected runner still requires the exact reviewed deletion, readiness, and drain proof before removing nodes.")
        }
    }

    private func runOpenReview() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            reviewURL = await onOpenReview(plan.id)
            isWorking = false
        }
    }

    private func runApply() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            applyURL = await onDispatchApply(plan.id, isDestructive)
            isWorking = false
        }
    }
}

private struct PoolSelection: Identifiable {
    let name: String
    let pool: NornFleetNodePool
    var id: String { name }
}

private extension JSONValue {
    var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case let .object(value) = self { value } else { nil } }
    var intValue: Int? { if case let .number(value) = self { Int(value) } else { nil } }
}

#Preview {
    NavigationStack {
        FleetFeatureView(
            inventory: NornFixtures.fleetInventory,
            plans: [],
            reconciliations: [:],
            githubStatus: .init(schemaVersion: "norn.fleet-github-status/v1", configured: true, connected: true, repository: "antiartificial/norn-fleet"),
            isSupported: true,
            canPlan: true,
            isRefreshing: false,
            onRefresh: {},
            onPlan: { _, _, _, _ in true },
            onOpenReview: { _ in nil },
            onDispatchApply: { _, _ in nil },
			onOpenOperation: { _ in }
        )
    }
    .frame(width: 980, height: 720)
}
