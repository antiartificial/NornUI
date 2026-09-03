import AppKit
import SwiftUI

/// Delivery mutation authority belongs to protected GitHub workflows. Keeping
/// this policy explicit makes both staging and production presentation
/// read-only, even when a server profile otherwise has operator credentials.
enum ReleasePipelineFeaturePolicy {
    static func permitsManualMutation(in _: String) -> Bool { false }
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
    var onLoadQualifications: (String) async -> [NornReleaseQualification] = { _ in [] }

    @State private var appName = ""
    @State private var qualifications: [NornReleaseQualification] = []
    @State private var isLoadingQualifications = false

    private var isStaging: Bool { environmentID == "staging" }
    private var isProduction: Bool { environmentID == "production" }
    private var selectedApp: String { appName.isEmpty ? apps.first?.spec.name ?? "" : appName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !isSupported {
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
        .task { await loadQualifications() }
        .onChange(of: appName) { _, _ in
            Task { await loadQualifications() }
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
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Release environment \(environmentID), policy profile \(environmentProfile)")
    }

    private var ciStagingLane: some View {
        ContentUnavailableView(
            "CI-owned staging lane",
            systemImage: "lock.shield",
            description: Text("A protected merge workflow owns staging submission and qualification. This view is read-only: monitor CI and inspect its durable evidence here.")
        )
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("CI-owned staging lane. Release submission and qualification are available through CI only.")
    }

    private var productionGate: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("GitHub-governed production lane", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.red); Spacer(); Text("GitHub approval required").font(.caption.weight(.semibold)).foregroundStyle(.red) }
            Text("This view is read-only for production promotion. Norn accepts the exact staged source and artifact only from the protected GitHub release workflow.").font(.subheadline).foregroundStyle(.secondary)
            Picker("Application", selection: $appName) {
                ForEach(apps, id: \.id) { Text($0.spec.name).tag($0.spec.name) }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Text("To promote, create a protected v* tag at the qualified commit. GitHub Environment approval runs the reusable production workflow, which transports the signed staging receipt to Norn.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Use the evidence below to review the source SHA, artifact digest, and signer. Follow the GitHub Actions run for approval and promotion status; NornUI never pastes evidence or queues production work.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.red.opacity(0.35)))
    }

    private var qualificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Staging qualifications", systemImage: "checklist").font(.headline); Spacer(); Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadQualifications() } }.buttonStyle(.borderless).disabled(isLoadingQualifications) }
            Text("Evidence pairs a deployment, source SHA, artifact digest, and qualification receipt. It is displayed for review and may be copied without changing release state.").font(.subheadline).foregroundStyle(.secondary)
            if isLoadingQualifications { ProgressView("Loading qualification evidence…") }
            else if qualifications.isEmpty { ContentUnavailableView("No qualifications", systemImage: "clipboard", description: Text("Complete a staging deployment and record its qualification to make promotion evidence available.")) }
            else { ForEach(qualifications) { qualificationRow($0) } }
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
                GridRow { Text("Attestation mode").foregroundStyle(.secondary); Text(qualification.candidate.attestation.displayMode).font(.caption.monospaced()).textSelection(.enabled) }
                GridRow { Text("Verifier").foregroundStyle(.secondary); Text(qualification.candidate.attestation.displayVerifier).font(.caption.monospaced()).textSelection(.enabled) }
                GridRow { Text("Signer").foregroundStyle(.secondary); Text(qualification.keyID).font(.caption.monospaced()).textSelection(.enabled) }
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
        guard isSupported, !selectedApp.isEmpty else { return }
        isLoadingQualifications = true
        qualifications = await onLoadQualifications(selectedApp)
        isLoadingQualifications = false
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func copySignedReceipt(_ receipt: NornReleaseQualification) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt), let value = String(data: data, encoding: .utf8) else { return }
        copy(value)
    }
}
