import AppKit
import SwiftUI

/// An application release desk. It deliberately does not offer branch deploys:
/// staging records an immutable source/artifact pair and production promotes the
/// exact pair from an independently-qualified staging receipt.
struct ReleasePipelineFeatureView: View {
    let apps: [NornAppStatus]
    let deployments: [NornDeployment]
    let environmentID: String
    let environmentProfile: String
    let isSupported: Bool
    let isConnected: Bool
    var onLoadQualifications: (String) async -> [NornReleaseQualification] = { _ in [] }
    var onPreflight: (String, String, String?) async -> NornOperation? = { _, _, _ in nil }
    var onDeploy: (String, String, String?) async -> NornOperation? = { _, _, _ in nil }
    var onQualify: (String, String) async -> NornReleaseQualification? = { _, _ in nil }
    var onPromote: (String, NornReleaseQualification) async -> NornOperation? = { _, _ in nil }
    var onOpenOperation: (NornOperation) -> Void = { _ in }

    @State private var appName = ""
    @State private var sourceSHA = ""
    @State private var artifact = ""
    @State private var qualificationDeploymentID = ""
    @State private var qualificationError: String?
    @State private var qualifications: [NornReleaseQualification] = []
    @State private var isLoadingQualifications = false
    @State private var activeAction: Action?
    @State private var selectedQualification: NornReleaseQualification?
    @State private var productionAcknowledged = false
    @State private var pastedEvidence = ""
    @State private var evidenceError: String?

    private enum Action: Identifiable {
        case preflight, deploy, qualify(String), promote(NornReleaseQualification)

        var id: String {
            switch self {
            case .preflight: "preflight"
            case .deploy: "deploy"
            case let .qualify(value): "qualify-\(value)"
            case let .promote(value): "promote-\(value.id)"
            }
        }

        var title: String {
            switch self {
            case .preflight: "Queue staging preflight"
            case .deploy: "Deploy to staging"
            case .qualify: "Record staging qualification"
            case .promote: "Promote to production"
            }
        }

        var isProduction: Bool { if case .promote = self { true } else { false } }
    }

    private var isStaging: Bool { environmentID == "staging" }
    private var isProduction: Bool { environmentID == "production" }
    // A production-profile staging control plane admits protected CI release
    // candidates only. The native client cannot synthesize that attested
    // candidate, so it remains observational here while retaining the safe
    // qualification flow for completed CI deployments.
    private var permitsManualStaging: Bool { isStaging && environmentProfile.lowercased() != "production" }
    private var canSubmitArtifact: Bool {
        sourceSHA.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil &&
        (artifact.isEmpty || artifact.range(of: "@sha256:[a-f0-9]{64}$", options: [.regularExpression, .caseInsensitive]) != nil)
    }
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
                    if permitsManualStaging { stagingComposer }
                    if isStaging && !permitsManualStaging { protectedStagingLane }
                    if isStaging { qualificationComposer }
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
            selectedQualification = nil
            productionAcknowledged = false
            pastedEvidence = ""
            evidenceError = nil
            Task { await loadQualifications() }
        }
        .confirmationDialog(activeAction?.title ?? "Release action", isPresented: Binding(get: { activeAction != nil }, set: { if !$0 { clearAction() } }), titleVisibility: .visible) {
            if let action = activeAction {
                Button(action.title, role: action.isProduction ? .destructive : nil) { Task { await run(action) } }
                Button("Cancel", role: .cancel) { clearAction() }
            }
        } message: {
            if let action = activeAction { Text(actionMessage(action)) }
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

    private var stagingComposer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Stage an immutable artifact", systemImage: "testtube.2").font(.headline); Spacer(); Text("Staging only").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
            Text("A merge should supply its exact commit SHA and, when available, a digest-pinned OCI artifact. Norn records the durable operation that performs the work.").font(.subheadline).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow { Text("Application").foregroundStyle(.secondary); Picker("Application", selection: $appName) { ForEach(apps, id: \.id) { Text($0.spec.name).tag($0.spec.name) } }.labelsHidden().frame(maxWidth: 280, alignment: .leading) }
                GridRow { Text("Source SHA").foregroundStyle(.secondary); TextField("40-character commit SHA", text: $sourceSHA).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder).onChange(of: sourceSHA) { _, value in sourceSHA = value.lowercased() }.accessibilityHint("An exact 40-character source commit SHA") }
                GridRow { Text("Artifact").foregroundStyle(.secondary); TextField("registry/app@sha256:… (optional)", text: $artifact).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder).accessibilityHint("Optional OCI artifact pinned by SHA-256 digest") }
            }
            Text("A source SHA is required. Artifact references, if supplied, must end in @sha256: followed by 64 hexadecimal characters.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Review Preflight") { activeAction = .preflight }.buttonStyle(.bordered).disabled(!canSubmitArtifact || !isConnected)
                Button("Review Staging Deploy") { activeAction = .deploy }.buttonStyle(.borderedProminent).disabled(!canSubmitArtifact || !isConnected)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var protectedStagingLane: some View {
        ContentUnavailableView(
            "Protected staging lane",
            systemImage: "lock.shield",
            description: Text("This production-profile staging control plane accepts release candidates from the protected CI lane. Monitor the durable CI operation, then record qualification evidence for its successful deployment.")
        )
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Protected staging lane. Release submission is available through CI only.")
    }

    private var successfulDeployments: [NornDeployment] {
        deployments.filter { $0.app == selectedApp && ($0.status == .healthy || $0.status == .deployed) }
    }

    private var qualificationComposer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Record successful staging qualification", systemImage: "checkmark.seal").font(.headline); Spacer(); Text("Staging only").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
            Text("Select a successful staging deployment or enter its exact UUID. This creates the first signed evidence receipt.").font(.subheadline).foregroundStyle(.secondary)
            Picker("Successful staging deployment", selection: Binding(get: { "" }, set: { value in if !value.isEmpty { qualificationDeploymentID = value; qualificationError = nil } })) {
                Text("Choose a recent successful deployment").tag("")
                ForEach(successfulDeployments) { deployment in
                    Text("\(deployment.id.prefix(18))… · \(deployment.commitSHA.prefix(12)) · \(deployment.status.rawValue)").tag(deployment.id)
                }
            }
            .accessibilityHint("Selecting a deployment copies its ID into the qualification field")
            TextField("Deployment UUID", text: $qualificationDeploymentID)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityHint("The UUID shown after a successful staging release deployment")
                .onChange(of: qualificationDeploymentID) { _, _ in qualificationError = nil }
            Text("Use the deployment ID shown when the staging release operation succeeds. Norn verifies that it is a successful staging deployment before issuing evidence.").font(.caption).foregroundStyle(.secondary)
            if let qualificationError { Text(qualificationError).font(.caption).foregroundStyle(.red).accessibilityLabel("Qualification error: \(qualificationError)") }
            Button("Review Qualification", systemImage: "checkmark.seal") {
                let value = qualificationDeploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isUUID(value) else { qualificationError = "Enter the UUID from a successful staging deployment."; return }
                activeAction = .qualify(value)
            }
            .buttonStyle(.bordered)
            .disabled(!isConnected)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var productionGate: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Production promotion gate", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.red); Spacer(); Text("Production only").font(.caption.weight(.semibold)).foregroundStyle(.red) }
            Text("Production can promote only a selected staging qualification. It reuses its recorded source SHA and artifact digest; there is no branch deploy or rebuild path here.").font(.subheadline).foregroundStyle(.secondary)
            Picker("Application", selection: $appName) {
                ForEach(apps, id: \.id) { Text($0.spec.name).tag($0.spec.name) }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Text("To hand off evidence between separate server profiles, paste the complete signed staging qualification JSON. Norn verifies its signature and freshness again before deployment.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $pastedEvidence)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 86)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Signed staging qualification JSON")
            Button("Load Signed Evidence", systemImage: "doc.badge.plus") { importEvidence() }
                .buttonStyle(.bordered)
                .disabled(pastedEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let evidenceError { Text(evidenceError).font(.caption).foregroundStyle(.red).accessibilityLabel("Evidence import error: \(evidenceError)") }
            Toggle("I reviewed the selected staging evidence and understand this queues a production operation.", isOn: $productionAcknowledged)
                .toggleStyle(.checkbox)
                .disabled(selectedQualification == nil || selectedQualification?.isExpired == true)
            Button("Review Production Promotion") {
                if let selectedQualification { activeAction = .promote(selectedQualification) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!productionAcknowledged || selectedQualification == nil || selectedQualification?.isExpired == true || !isConnected)
        }
        .padding(18)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.red.opacity(0.35)))
    }

    private var qualificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Staging qualifications", systemImage: "checklist").font(.headline); Spacer(); Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadQualifications() } }.buttonStyle(.borderless).disabled(isLoadingQualifications) }
            Text("Evidence pairs a deployment, source SHA, artifact digest, and qualification receipt. Select it before a production promotion.").font(.subheadline).foregroundStyle(.secondary)
            if isLoadingQualifications { ProgressView("Loading qualification evidence…") }
            else if qualifications.isEmpty { ContentUnavailableView("No qualifications", systemImage: "clipboard", description: Text("Complete a staging deployment and record its qualification to make promotion evidence available.")) }
            else { ForEach(qualifications) { qualificationRow($0) } }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func qualificationRow(_ qualification: NornReleaseQualification) -> some View {
        let selected = selectedQualification?.id == qualification.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Label(qualification.isExpired ? "Expired evidence" : "Signed staging evidence", systemImage: qualification.isExpired ? "clock.badge.exclamationmark" : "checkmark.seal.fill").foregroundStyle(qualification.isExpired ? .orange : .green); Spacer(); Text(qualification.deploymentID.prefix(12)).font(.caption.monospaced()).textSelection(.enabled) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Source").foregroundStyle(.secondary); Text(qualification.sourceSHA).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("Artifact").foregroundStyle(.secondary); Text(qualification.artifact).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("Signer").foregroundStyle(.secondary); Text(qualification.keyID).font(.caption.monospaced()).textSelection(.enabled) }
                GridRow { Text("Expires").foregroundStyle(.secondary); Text(qualification.expiryDate?.formatted(date: .abbreviated, time: .shortened) ?? qualification.expiresAt) }
            }
            HStack {
                if isStaging { Button("Review Qualification") { activeAction = .qualify(qualification.deploymentID) }.buttonStyle(.bordered).disabled(!isConnected) }
                if isProduction { Button(selected ? "Selected for Promotion" : "Select Evidence") { selectedQualification = qualification; productionAcknowledged = false }.buttonStyle(.bordered).disabled(qualification.isExpired) }
                Spacer()
            }
        }
        .padding(12)
        .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button("Copy signed qualification JSON") { copySignedReceipt(qualification) }
            Button("Copy Source SHA") { copy(qualification.sourceSHA) }
            Button("Copy Artifact Digest") { copy(qualification.artifact) }
            Button("Copy Deployment ID") { copy(qualification.deploymentID) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Qualification deployment \(qualification.deploymentID), source \(qualification.sourceSHA), artifact \(qualification.artifact)")
    }

    private func loadQualifications() async {
        guard isSupported, !selectedApp.isEmpty else { return }
        isLoadingQualifications = true
        qualifications = await onLoadQualifications(selectedApp)
        if let selectedQualification, !qualifications.contains(where: { $0.id == selectedQualification.id }) { self.selectedQualification = nil; productionAcknowledged = false }
        isLoadingQualifications = false
    }

    private func actionMessage(_ action: Action) -> String {
        switch action {
        case .preflight: "Norn will verify the exact source SHA and digest without deploying. A durable preflight receipt will be recorded."
        case .deploy: "Norn will deploy the exact source SHA and artifact to staging. It will not resolve a branch or build a replacement artifact."
        case let .qualify(value): "Norn will record qualification evidence for successful staging deployment \(value)."
        case let .promote(value): "Norn will deploy source \(value.sourceSHA) with the exact staging artifact \(value.artifact) to production. This queues a production operation."
        }
    }

    private func run(_ action: Action) async {
        switch action {
        case let .qualify(value):
            let qualification = await onQualify(selectedApp, value)
            clearAction()
            if qualification != nil { await loadQualifications() }
            return
        case .preflight:
            let operation = await onPreflight(selectedApp, sourceSHA, normalizedArtifact)
            clearAction()
            if let operation { onOpenOperation(operation); await loadQualifications() }
            return
        case .deploy:
            let operation = await onDeploy(selectedApp, sourceSHA, normalizedArtifact)
            clearAction()
            if let operation {
                if let deploymentID = operation.metadata?["deploymentId"]?.stringValue ?? operation.payload?["deploymentId"]?.stringValue {
                    qualificationDeploymentID = deploymentID
                    qualificationError = nil
                }
                onOpenOperation(operation)
                await loadQualifications()
            }
            return
        case let .promote(value):
            let operation = await onPromote(selectedApp, value)
            clearAction()
            if let operation { onOpenOperation(operation); await loadQualifications() }
            return
        }
    }

    private func clearAction() { activeAction = nil }
    private func importEvidence() {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .nornISO8601
            let receipt = try decoder.decode(NornReleaseQualification.self, from: Data(pastedEvidence.utf8))
            guard receipt.isV2Signed, receipt.app == selectedApp, receipt.environment == "staging" else {
                evidenceError = "The receipt must be signed staging evidence for \(selectedApp)."
                return
            }
            selectedQualification = receipt
            productionAcknowledged = false
            evidenceError = nil
        } catch {
            evidenceError = "Paste the complete signed staging qualification for the selected application."
        }
    }
    private var normalizedArtifact: String? {
        let value = artifact.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private func isUUID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func copySignedReceipt(_ receipt: NornReleaseQualification) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt), let value = String(data: data, encoding: .utf8) else { return }
        copy(value)
    }
}
