import AppKit
import Foundation
import SwiftUI

/// Delivery mutation authority belongs to protected GitHub workflows. Keeping
/// this policy explicit makes both staging and production presentation
/// read-only, even when a server profile otherwise has operator credentials.
enum ReleasePipelineFeaturePolicy {
    static let productionGateLabel = "Protected tag + Norn gate"
    static func permitsManualMutation(in _: String) -> Bool { false }
    static func requiresManagedFleet(in environment: String) -> Bool {
        environment == "staging" || environment == "production"
    }
    static func requiresSignedReleaseEvidence(in environment: String) -> Bool {
        requiresManagedFleet(in: environment)
    }
}

/// A read-only application release desk. Protected GitHub workflows own all
/// staging, qualification, and production mutations; NornUI presents the
/// immutable evidence they produced.
struct ReleasePipelineFeatureView: View {
    let apps: [NornAppStatus]
    let deployments: [NornDeployment]
    let environmentID: String
    let environmentProfile: String
    let isSupported: Bool
    let isConnected: Bool
    let profileID: UUID?
    var requestedDeploymentID: String? = nil
    var operations: [NornOperation] = []
    var deploymentSteps: [String: [NornDeploymentStep]] = [:]
    var loadingDeploymentIDs: Set<String> = []
    var deploymentStepErrors: [String: String] = [:]
    var deploymentActivityError: String? = nil
    var isLoadingDeploymentActivity = false
    var onSelectDeployment: (NornDeployment) -> Void = { _ in }
    var onLoadQualifications: (String) async -> [NornReleaseQualification] = { _ in [] }

    @State private var appName = ""
    @State private var qualificationLoader = ReleaseQualificationEvidenceLoader()
    @State private var selectedDeploymentID: String?

    private var recentDeployments: [NornDeployment] {
        deployments.sorted {
            let lhs = $0.finishedAt ?? $0.startedAt
            let rhs = $1.finishedAt ?? $1.startedAt
            if lhs != rhs { return lhs > rhs }
            return $0.id < $1.id
        }
    }

    private var selectedDeployment: NornDeployment? {
        recentDeployments.first { $0.id == (selectedDeploymentID ?? requestedDeploymentID) } ?? recentDeployments.first
    }

    private var isStaging: Bool { environmentID == "staging" }
    private var isProduction: Bool { environmentID == "production" }
    private var isManagedFleet: Bool { ReleasePipelineFeaturePolicy.requiresManagedFleet(in: environmentID) }
    private var selectedApp: String { NornReleaseAppSelection.normalized(appName, in: apps) }
    private var qualificationContext: NornProfileAppContext {
        .init(profileID: profileID, appID: selectedApp, isActive: isSupported && isConnected && !selectedApp.isEmpty)
    }

    private var displayedQualifications: [NornReleaseQualification] {
        qualificationLoader.loadedContext == qualificationContext ? qualificationLoader.qualifications : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                deploymentActivity
                if !isManagedFleet {
                    environmentCard
                    localDevelopmentLane
                } else if !isSupported {
                    ContentUnavailableView("Release pipeline unavailable", systemImage: "lock.shield", description: Text("This server has not advertised release provenance, qualifications, and promotions."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    environmentCard
                    if isStaging && !ReleasePipelineFeaturePolicy.permitsManualMutation(in: environmentID) { ciStagingLane }
                    if isProduction { productionGate }
                    qualificationsCard
                }
            }
            .padding(20)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .navigationTitle("Delivery")
        .task { normalizeSelectedApp() }
        .task(id: qualificationContext) { await loadQualifications() }
        .onChange(of: apps) { _, _ in normalizeSelectedApp() }
        .onChange(of: selectedDeployment?.id, initial: true) { _, _ in
            if let selectedDeployment { onSelectDeployment(selectedDeployment) }
        }
        .onChange(of: profileID) { _, _ in selectedDeploymentID = nil }
        .onChange(of: requestedDeploymentID, initial: true) { _, value in
            if let value, deployments.contains(where: { $0.id == value }) { selectedDeploymentID = value }
        }
    }

    private var deploymentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent application deployments", systemImage: "shippingbox")
                .font(.headline)
            if isLoadingDeploymentActivity { ProgressView("Refreshing deployment activity…").controlSize(.small) }
            if let deploymentActivityError {
                Label(deploymentActivityError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            inFlightOperations
            if let deployment = selectedDeployment {
                Picker("Deployment", selection: Binding(
                    get: { selectedDeployment?.id },
                    set: { selectedDeploymentID = $0 }
                )) {
                    ForEach(recentDeployments) { item in
                        Text("\(item.app) · \(item.status.rawValue) · \(item.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .tag(Optional(item.id))
                    }
                }
                .accessibilityIdentifier("delivery.deployment-picker")
                HStack {
                    Text(deployment.app).font(.title3.weight(.semibold))
                    Spacer()
                    Text(String(deployment.commitSHA.prefix(8)))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("Last reported \(deployment.status.rawValue) · Started \(deployment.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                DeploymentPipelineGraph(
                    deployment: deployment,
                    steps: deploymentSteps[deployment.id] ?? [],
                    isLoading: loadingDeploymentIDs.contains(deployment.id),
                    errorMessage: deploymentStepErrors[deployment.id],
                    isLive: isConnected && !deployment.sagaID.isEmpty && operations.contains {
                        $0.status.isActive && $0.sagaID == deployment.sagaID
                    }
                )
            } else {
                Text("No application deployments reported by this environment yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("delivery.deployment-activity")
    }

    private var inFlightOperations: some View {
        let active = operations.filter { $0.status.isActive && $0.kind.hasPrefix("app.") }
            .sorted { $0.startedAt > $1.startedAt }
        return VStack(alignment: .leading, spacing: 8) {
            if !active.isEmpty {
                Label(isConnected ? "In flight" : "Last reported in flight", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                ForEach(active) { operation in
                    let deployment = deployments.first { !$0.sagaID.isEmpty && $0.sagaID == operation.sagaID }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(operation.app ?? operation.kind).font(.subheadline.weight(.medium))
                            Text(operation.message ?? operation.kind.replacingOccurrences(of: ".", with: " "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(operation.status.rawValue.capitalized).font(.caption.weight(.medium))
                            if operation.status == .running && isConnected {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(Duration.seconds(max(0, context.date.timeIntervalSince(operation.startedAt)))
                                        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let deployment {
                            Button("View") { selectedDeploymentID = deployment.id }
                        }
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2).foregroundStyle(.tint).symbolRenderingMode(.hierarchical).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Application delivery").font(.title2.weight(.semibold))
                Text("Build once, qualify in staging, and promote the same immutable artifact.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Label(environmentID.capitalized, systemImage: isProduction ? "exclamationmark.shield.fill" : isStaging ? "testtube.2" : "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isProduction ? .red : isStaging ? .orange : .secondary)
                .accessibilityLabel("Connected environment: \(environmentID)")
        }
    }

    private var environmentCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow { Text("Environment").foregroundStyle(.secondary); Text(environmentID).font(.body.monospaced()).textSelection(.enabled) }
            GridRow { Text("Policy profile").foregroundStyle(.secondary); Text(environmentProfile).font(.body.monospaced()).textSelection(.enabled) }
            GridRow { Text("Delivery scope").foregroundStyle(.secondary); Text(isManagedFleet ? "Managed Fleet" : "Local development") }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Release environment \(environmentID), policy profile \(environmentProfile), \(isManagedFleet ? "managed Fleet" : "local development")")
    }

    private var localDevelopmentLane: some View {
        ContentUnavailableView(
            "Local development lane",
            systemImage: "macmini",
            description: Text("Fleet and signed private-release evidence are not required on this development control plane. They become mandatory when this workload enters managed staging or production.")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Local development lane. Fleet and signed private release evidence are required only in managed staging and production.")
    }

    private var ciStagingLane: some View {
        ContentUnavailableView(
            "CI-owned staging lane",
            systemImage: "lock.shield",
            description: Text("A protected merge workflow owns staging submission and qualification. Its configured signing backend may be Norn-controlled, KMS-backed, or the optional GitHub Enterprise adapter.")
        )
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("CI-owned staging lane. Release submission and qualification are available through CI only.")
    }

    private var productionGate: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("GitHub-governed production lane", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.red); Spacer(); Text(ReleasePipelineFeaturePolicy.productionGateLabel).font(.caption.weight(.semibold)).foregroundStyle(.red) }
            Text("This view is read-only for production promotion. Norn accepts the exact staged source, artifact, and signed qualification only from the protected GitHub release workflow.").font(.subheadline).foregroundStyle(.secondary)
            Picker("Application", selection: $appName) {
                ForEach(apps, id: \.id) { Text($0.spec.name).tag($0.spec.name) }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Text("To promote, create a protected v* tag at the qualified commit. The reusable production workflow transports the signed staging receipt to Norn, which independently verifies qualification and promotion policy.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Use the evidence below to review the source SHA, artifact digest, and signer. GitHub Environment reviewers may add a separate approval when the repository plan supports them; they are not assumed for a personal private repository.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.red.opacity(0.35)))
    }

    private var qualificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Staging qualifications", systemImage: "checklist").font(.headline); Spacer(); Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadQualifications() } }.buttonStyle(.borderless).disabled(qualificationLoader.isLoading) }
            Text("Evidence pairs a deployment, source SHA, artifact digest, and qualification receipt. It is displayed for review and may be copied without changing release state.").font(.subheadline).foregroundStyle(.secondary)
            if qualificationLoader.isLoading { ProgressView("Loading qualification evidence…") }
            else if displayedQualifications.isEmpty { ContentUnavailableView("No qualifications", systemImage: "clipboard", description: Text("Complete a staging deployment and record its qualification to make promotion evidence available.")) }
            else { ForEach(displayedQualifications) { qualificationRow($0) } }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func qualificationRow(_ qualification: NornReleaseQualification) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Label(qualification.isExpired ? "Expired evidence" : "Signed staging evidence", systemImage: qualification.isExpired ? "clock.badge.exclamationmark" : "checkmark.seal.fill").foregroundStyle(qualification.isExpired ? .orange : .green); Spacer(); Text(qualification.deploymentID.prefix(12)).font(.caption.monospaced()).textSelection(.enabled) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Source").foregroundStyle(.secondary); Text(qualification.sourceSHA).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("Artifact").foregroundStyle(.secondary); Text(qualification.artifact).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("GitHub repository").foregroundStyle(.secondary); Text(qualification.candidate.repository).font(.caption.monospaced()).textSelection(.enabled) }
                GridRow { Text("Owner / repository IDs").foregroundStyle(.secondary); Text("\(qualification.candidate.ownerID) / \(qualification.candidate.repositoryID)").font(.caption.monospaced()).textSelection(.enabled) }
                GridRow {
                    Text("Signing backend").foregroundStyle(.secondary)
                    Text(qualification.candidate.attestation.displayMode)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .help("Backend identifier: \(qualification.candidate.attestation.mode ?? "not reported")")
                }
                GridRow { Text("Verifier").foregroundStyle(.secondary); Text(qualification.candidate.attestation.displayVerifier).font(.caption.monospaced()).textSelection(.enabled) }
                if qualification.candidate.attestation.mode == "norn-signed-private",
                   let privateSigner = qualification.candidate.attestation.bundle?.keyID {
                    GridRow { Text("Private evidence signer").foregroundStyle(.secondary); Text(privateSigner).font(.caption.monospaced()).textSelection(.enabled) }
                }
                GridRow { Text("Qualification signer").foregroundStyle(.secondary); Text(qualification.keyID).font(.caption.monospaced()).textSelection(.enabled) }
                GridRow { Text("Expires").foregroundStyle(.secondary); Text(qualification.expiryDate?.formatted(date: .abbreviated, time: .shortened) ?? qualification.expiresAt) }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button("Copy signed qualification JSON") { copySignedReceipt(qualification) }
            Button("Copy Source SHA") { copy(qualification.sourceSHA) }
            Button("Copy Artifact Digest") { copy(qualification.artifact) }
            Button("Copy Deployment ID") { copy(qualification.deploymentID) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Qualification deployment \(qualification.deploymentID), source \(qualification.sourceSHA), artifact \(qualification.artifact), attestation mode \(qualification.candidate.attestation.displayMode), verifier \(qualification.candidate.attestation.displayVerifier)")
    }

    private func loadQualifications() async {
        await qualificationLoader.reload(for: qualificationContext, operation: onLoadQualifications)
    }

    private func normalizeSelectedApp() {
        appName = NornReleaseAppSelection.normalized(appName, in: apps)
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func copySignedReceipt(_ receipt: NornReleaseQualification) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt), let value = String(data: data, encoding: .utf8) else { return }
        copy(value)
    }
}
