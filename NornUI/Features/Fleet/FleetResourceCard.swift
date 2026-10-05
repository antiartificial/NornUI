import SwiftUI

/// Pure presentation of one Fleet resource record: requested, exists, running,
/// blocking, next action, liveness and approval policy. Kept free of SwiftUI so
/// it can be unit tested.
nonisolated struct FleetResourcePresentation: Equatable, Sendable {
    struct ConditionRow: Equatable, Identifiable, Sendable {
        enum Tone: Equatable, Sendable { case good, bad, unknown }
        var id: String
        var title: String
        var status: String
        var tone: Tone
        var isStale: Bool
        var detail: String?
    }

    enum Approval: Equatable, Sendable {
        case approve(planID: String, commitSha: String)
        case resume(planID: String, commitSha: String, sourceAttemptID: String)

        /// Deterministic per plan, commit and attempt: a retry replays the same
        /// approve, while a resume for a new attempt (the previous approve was
        /// consumed by a recovery that then stopped) gets a new key.
        var idempotencyKey: String {
            switch self {
            case let .approve(plan, commit): "fleet-approve-\(plan)-\(commit)-converge"
            case let .resume(plan, commit, attempt): "fleet-approve-\(plan)-\(commit)-\(attempt)"
            }
        }
    }

    let name: String
    let requested: String
    let lastApplied: String
    let conditions: [ConditionRow]
    let running: String
    let blocker: String?
    let nextActionTitle: String
    let nextActionDetail: String
    let liveness: String
    let livenessIsHealthy: Bool
    let policy: String
    let approval: Approval?
    let canRescan: Bool
    let cliHints: [String]

    init(_ resource: NornFleetResource) {
        name = resource.name
        let desired = resource.desired
        requested = desired.generation == 0
            ? "No desired revision declared."
            : "Generation \(desired.generation), commit \(Self.shortSHA(desired.commitSha))"
                + (desired.verification.map { " (\(Self.verification($0)))" } ?? "")

        if let applied = resource.status.lastApplied {
            var text = "Generation \(applied.generation), commit \(Self.shortSHA(applied.commitSha))"
            if applied.reason == "GenerationOutOfHistory" { text += ", older than the retained history" }
            if applied.reason == "CommitNotDesired" { text += ", not a declared revision" }
            lastApplied = text
        } else {
            lastApplied = "Nothing applied yet."
        }

        conditions = resource.status.conditions.map(Self.row)

        if let active = resource.status.active {
            var text = "Plan \(Self.shortID(active.planID)), "
            if let attempt = active.attemptIDs.last {
                text += "attempt \(active.attemptIDs.count) (\(Self.shortID(attempt)))"
            } else {
                text += "no attempt registered"
            }
            text += ", \(Self.occupancy(active.occupancy))"
            if let reason = active.occupancyReason { text += ": \(Self.humanize(reason))" }
            running = text
        } else {
            running = "Nothing is running. The target fence is free."
        }

        if let blocker = resource.blocker {
            let text = blocker.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.blocker = (text?.isEmpty == false ? text : nil) ?? Self.humanize(blocker.reason)
        } else {
            blocker = nil
        }

        // The server decides; the UI only reads which approve it means. Derive
        // (controller.DeriveConverge) reports approve_converge while the fence is
        // held only for a stopped holder attempt that needs a new resume approve,
        // with the WhileHeld approval_required blocker naming the holder plan.
        let approveNext = resource.status.nextAction == "approve_converge"
        let resumeActive = approveNext ? resource.status.active : nil
        let next = resumeActive != nil
            ? ("Approve resume", "The last attempt stopped and its resume approval is spent or absent. Approve one recovery attempt.")
            : Self.nextAction(resource.status.nextAction)
        nextActionTitle = next.0
        nextActionDetail = next.1

        switch resource.controller.state {
        case "running":
            liveness = "Controller running"
            livenessIsHealthy = true
        case "stale":
            liveness = "Controller stale: the last rescan is overdue. Status may be out of date."
            livenessIsHealthy = false
        default:
            liveness = "Controller liveness unknown: this server runs no reconciler. Status may be empty or out of date."
            livenessIsHealthy = false
        }

        policy = Self.policy(resource.approvalPolicy)

        let controllerMode = resource.executionMode == "controller"
        canRescan = controllerMode

        var approval: Approval?
        if let active = resumeActive {
            // The resume-needed attempt is the holder plan's latest attempt
            // (attemptIds last); the view has no structured field for it, so
            // also require the server's blocker to name it.
            let b = resource.blocker
            if b?.kind == "approval", b?.reason == "approval_required", b?.planID == active.planID,
               let attempt = active.attemptIDs.last, b?.message.map({ $0.contains(attempt) }) ?? true,
               let commit = Self.commit(of: active.planID, in: resource) {
                approval = .resume(planID: active.planID, commitSha: commit, sourceAttemptID: attempt)
            }
        } else if approveNext, let planID = desired.planID, let commit = desired.commitSha {
            approval = .approve(planID: planID, commitSha: commit)
        }
        self.approval = approval

        let n = resource.name
        let plan = resource.status.active?.planID ?? desired.planID ?? "<plan-id>"
        var hints: [String] = []
        if let active = resumeActive {
            hints.append(resource.desired.planID == active.planID
                ? "norn fleet converge \(n) --resume"
                : "norn fleet approve \(active.planID) --resume --source-attempt \(active.attemptIDs.last ?? "<attempt-id>") --commit <sha>")
        } else if approveNext, let planID = desired.planID {
            hints.append("norn fleet approve \(planID)")
        }
        hints += [
            "norn fleet mode \(n) controller|github",
            "norn fleet provider-evidence \(plan) --source-attempt <attempt-id> --provider-evidence <file>",
            "norn fleet release \(resource.targetID) --mode terminal|abandon [--provider-evidence <file>]",
            "norn fleet abandon \(plan) [--provider-evidence <file>]"
        ]
        cliHints = hints
    }

    /// The commit of plan `planID`: the desired revision's, or a retained
    /// history entry's (a holder plan the desired revision has moved past).
    private static func commit(of planID: String, in resource: NornFleetResource) -> String? {
        ([resource.desired] + resource.desiredHistory).first { $0.planID == planID }?.commitSha
    }

    static func shortSHA(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return String(value.prefix(8))
    }

    static func shortID(_ value: String) -> String { String(value.prefix(8)) }

    static func humanize(_ code: String) -> String {
        var out = ""
        for (index, ch) in code.enumerated() {
            if ch == "_" { out += " "; continue }
            if ch.isUppercase, index > 0 { out += " " }
            out.append(index == 0 ? Character(ch.uppercased()) : Character(ch.lowercased()))
        }
        return out
    }

    private static func verification(_ value: String) -> String {
        switch value {
        case "github-merged-plan": "merged plan"
        case "github-protected-main": "protected main"
        case "operator-declared": "operator declared, not verified"
        default: value
        }
    }

    private static func occupancy(_ value: String) -> String {
        switch value {
        case "Active": "live attempt holds the fence"
        case "Uncertain": "outcome uncertain, fence held"
        case "Free": "fence free"
        default: value
        }
    }

    private static func nextAction(_ value: String?) -> (String, String) {
        switch value {
        case "resolve_uncertain_outcome": ("Resolve uncertain outcome", "A holder is in an uncertain state. Follow the operator runbook before anything else runs.")
        case "await_runner": ("Wait for the runner", "A live attempt holds the fence. Nothing to do yet.")
        case "approve_converge": ("Approve converge", "The desired converge plan needs your approval before the controller starts it.")
        case "refresh_observations": ("Refresh observations", "A condition is Unknown. Run or fix the observation job.")
        case "investigate_drift": ("Investigate drift", "Drift was observed. Review it, then plan through the normal reviewed flow.")
        case "none": ("Nothing pending", "No action is needed right now.")
        case .some(let other): (humanize(other), "Reported by a newer server than this app understands.")
        case nil: ("Not evaluated", "The server has not evaluated this resource yet.")
        }
    }

    private static func row(_ condition: NornFleetResourceCondition) -> ConditionRow {
        let stale = condition.reason == "ObservationStale"
        let tone: ConditionRow.Tone
        let status: String
        switch condition.status {
        case "Unknown":
            tone = .unknown
            status = stale ? "Unknown (stale)" : "Unknown"
        default:
            // DriftDetected and ReconciliationRequired are bad when True.
            let badWhenTrue = ["DriftDetected", "ReconciliationRequired"].contains(condition.type)
            let isTrue = condition.status == "True"
            tone = (isTrue != badWhenTrue) ? .good : .bad
            status = condition.status
        }
        let detail = condition.message.flatMap { $0.isEmpty ? nil : $0 } ?? condition.reason.map(humanize)
        return ConditionRow(id: condition.type, title: humanize(condition.type), status: status, tone: tone, isStale: stale, detail: detail)
    }

    private static func policy(_ p: NornFleetApprovalPolicy) -> String {
        var parts: [String] = []
        parts.append(p.basis == "none" ? "No desired revision has been verified." : "Basis: \(verification(p.basis)).")
        let checks: [(String, Bool)] = [
            ("protected branch", p.protectedBranch),
            ("merged pull request", p.mergedPullRequest),
            ("plan workflow succeeded", p.planWorkflowSucceeded),
            ("plan digest bound", p.boundPlanDigest)
        ]
        let enforced = checks.filter(\.1).map(\.0)
        parts.append(enforced.isEmpty ? "Norn enforces none of: protected branch, merged PR, plan workflow, plan digest." : "Norn enforces: \(enforced.joined(separator: ", ")).")
        parts.append("Environment reviewers and independent review are not enforced.")
        if let by = p.approvedBy { parts.append("Approved by \(by).") }
        return parts.joined(separator: " ")
    }
}

struct FleetResourceCard: View {
    let resource: NornFleetResource
    let canOperate: Bool
    let isBusy: Bool
    let onRescan: () -> Void
    let onApprove: (FleetResourcePresentation.Approval) -> Void

    @State private var confirming: FleetResourcePresentation.Approval?

    private var model: FleetResourcePresentation { FleetResourcePresentation(resource) }

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FLEET RESOURCE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(m.name).font(.title3.weight(.semibold))
                }
                Spacer()
                Label(m.livenessIsHealthy ? "Controller running" : "Controller not confirmed",
                      systemImage: m.livenessIsHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(m.livenessIsHealthy ? .green : .orange)
            }
            if !m.livenessIsHealthy {
                Text(m.liveness).font(.callout).foregroundStyle(.orange)
            }

            section("Requested") {
                Text(m.requested)
                Text("Last applied: \(m.lastApplied)").foregroundStyle(.secondary)
            }
            section("What exists") {
                if m.conditions.isEmpty {
                    Text("No conditions reported.").foregroundStyle(.secondary)
                }
                ForEach(m.conditions) { condition in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(condition.tone)).foregroundStyle(color(condition.tone)).accessibilityHidden(true)
                        Text(condition.title)
                        Spacer(minLength: 8)
                        Text(condition.status).foregroundStyle(color(condition.tone)).fontWeight(.medium)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(condition.title): \(condition.status)\(condition.detail.map { ". \($0)" } ?? "")")
                    .help(condition.detail ?? "")
                }
            }
            section("What is running") { Text(m.running) }
            section("What is blocking") {
                if let blocker = m.blocker {
                    Label(blocker, systemImage: "hand.raised.fill").foregroundStyle(.orange)
                } else {
                    Text("Nothing is blocking.").foregroundStyle(.secondary)
                }
            }
            section("Next action") {
                Text(m.nextActionTitle).fontWeight(.semibold)
                Text(m.nextActionDetail).foregroundStyle(.secondary)
            }
            section("Approval policy") { Text(m.policy).foregroundStyle(.secondary) }

            // Approve and rescan need platform:operate (or admin) on a server with
            // fleet-executor-v1; without them the buttons would always fail.
            if canOperate {
                HStack {
                    if let approval = m.approval {
                        Button(approvalTitle(approval), systemImage: "checkmark.seal") { confirming = approval }
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy)
                            .accessibilityLabel("\(approvalTitle(approval)) for fleet resource \(m.name)")
                    }
                    if m.canRescan {
                        Button("Rescan", systemImage: "arrow.clockwise", action: onRescan)
                            .disabled(isBusy)
                            .help("Check the protected main tip for a new converge plan")
                            .accessibilityLabel("Rescan fleet resource \(m.name)")
                    }
                    if isBusy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                }
            } else if m.approval != nil || m.canRescan {
                Label("Approving and rescanning need the platform:operate scope on a server with the executor lane.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Admin actions (CLI)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mode, provider evidence, release and abandon are admin actions. Run them with the CLI:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(m.cliHints, id: \.self) { hint in
                        Text(hint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fleet resource \(m.name)")
        .confirmationDialog(
            confirming.map { approvalTitle($0) } ?? "Approve",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { approval in
            Button(approvalTitle(approval)) { onApprove(approval) }
            Button("Cancel", role: .cancel) {}
        } message: { approval in
            switch approval {
            case let .approve(_, commit): Text("Approve converge of commit \(FleetResourcePresentation.shortSHA(commit)) for \(m.name).")
            case let .resume(_, commit, attempt): Text("Authorize one recovery attempt of stopped attempt \(FleetResourcePresentation.shortID(attempt)) for commit \(FleetResourcePresentation.shortSHA(commit)) on \(m.name).")
            }
        }
    }

    private func approvalTitle(_ approval: FleetResourcePresentation.Approval) -> String {
        switch approval {
        case .approve: "Approve Converge"
        case .resume: "Approve Resume"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }

    private func icon(_ tone: FleetResourcePresentation.ConditionRow.Tone) -> String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .bad: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private func color(_ tone: FleetResourcePresentation.ConditionRow.Tone) -> Color {
        switch tone {
        case .good: .green
        case .bad: .red
        case .unknown: .orange
        }
    }
}
