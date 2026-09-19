import AppKit
import SwiftUI

private enum ServerAuthenticationMethod: String, CaseIterable, Identifiable {
    case pair
    case token

    var id: String { rawValue }
    var title: String { self == .pair ? "Pair This Mac" : "Access Token" }
}

struct ServerProfileEditor: View {
    typealias EnrollmentStart = (
        NornServerProfile,
        [String]
    ) async throws -> (session: NornEnrollmentSession, protection: NornDeviceIdentityProtection)
    typealias CapabilityDiscovery = (NornServerProfile) async throws -> NornCapabilities
    typealias ConnectionTest = (NornServerProfile, String) async throws -> String

    let existingProfile: NornServerProfile?
    let onManualSave: (NornServerProfile, String) async throws -> Void
    let onTestConnection: ConnectionTest?
    let onDiscoverCapabilities: CapabilityDiscovery
    let onStartEnrollment: EnrollmentStart
    let onCompleteEnrollment: (NornServerProfile, NornEnrollmentSession) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @State private var address: String
    @State private var token = ""
    @State private var authenticationMethod: ServerAuthenticationMethod
    @State private var allowAppChanges = false
    @State private var allowPlatformOperations = false
    @State private var allowHostOperations = false
    @State private var allowFleetOperations = false
    @State private var allowTerminalSessions = false
    @State private var discoveredCapabilities: NornCapabilities?
    @State private var enrollment: NornEnrollmentSession?
    @State private var identityProtection: NornDeviceIdentityProtection?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var connectionTestResult: String?

    init(
        profile: NornServerProfile? = nil,
        startsWithPairing: Bool = true,
        onManualSave: @escaping (NornServerProfile, String) async throws -> Void,
        onTestConnection: ConnectionTest? = nil,
        onDiscoverCapabilities: @escaping CapabilityDiscovery,
        onStartEnrollment: @escaping EnrollmentStart,
        onCompleteEnrollment: @escaping (NornServerProfile, NornEnrollmentSession) async throws -> Void
    ) {
        existingProfile = profile
        self.onManualSave = onManualSave
        self.onTestConnection = onTestConnection
        self.onDiscoverCapabilities = onDiscoverCapabilities
        self.onStartEnrollment = onStartEnrollment
        self.onCompleteEnrollment = onCompleteEnrollment
        _name = State(initialValue: profile?.name ?? "")
        _address = State(initialValue: profile?.baseURL.absoluteString ?? "https://")
        _authenticationMethod = State(initialValue: startsWithPairing ? .pair : .token)
    }

    private var normalizedURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              NornClient.isAllowedBaseURL(url)
        else {
            return nil
        }
        return url
    }

    private var profile: NornServerProfile? {
        guard let normalizedURL,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NornServerProfile(
            id: existingProfile?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: normalizedURL,
            credentialID: existingProfile?.credentialID,
            deviceID: existingProfile?.deviceID,
            tokenID: existingProfile?.tokenID,
            grantedScopes: existingProfile?.grantedScopes,
            tokenExpiresAt: existingProfile?.tokenExpiresAt,
            lastRotatedAt: existingProfile?.lastRotatedAt
        )
    }

    private var requestedScopes: [String] {
        NornEnrollmentScopes.requested(
            capabilities: discoveredCapabilities,
            requestsAPIWrite: allowAppChanges,
            requestsPlatformOperations: allowPlatformOperations,
            requestsHostOperations: allowHostOperations,
            requestsFleetOperations: allowFleetOperations,
            requestsTerminalSessions: allowTerminalSessions
        )
    }

    private var primaryActionTitle: String {
        guard authenticationMethod == .pair else { return existingProfile == nil ? "Connect" : "Save" }
        return discoveredCapabilities == nil ? "Verify Authority" : "Start Pairing"
    }

    private var canPerformPrimaryAction: Bool {
        guard profile != nil, !isWorking else { return false }
        switch authenticationMethod {
        case .pair: return enrollment == nil
        case .token:
            return !token.isEmpty || (existingProfile != nil && !hasChangedOrigin)
        }
    }

    private var hasChangedOrigin: Bool {
        guard let existingProfile else { return false }
        return normalizedURL?.standardized != existingProfile.baseURL.standardized
    }

    private var canTestConnection: Bool {
        guard onTestConnection != nil, profile != nil, !isWorking else { return false }
        return authenticationMethod == .token
            && (!token.isEmpty || (existingProfile != nil && !hasChangedOrigin))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            Form {
                Section("Server") {
                    TextField("Name", text: $name, prompt: Text("Studio Mini"))
                    TextField("Server URL", text: $address, prompt: Text("https://norn.example.com"))
                        .textContentType(.URL)
                    if normalizedURL?.host?.isTailscaleHostname == true {
                        Label("Tailscale endpoints require their normal HTTPS certificate. Verification uses this exact .ts.net URL; NornUI does not discover peers or allow an insecure TLS bypass.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(enrollment != nil)

                Section("Authentication") {
                    Picker("Method", selection: $authenticationMethod) {
                        ForEach(ServerAuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(enrollment != nil)

                    switch authenticationMethod {
                    case .pair:
                        pairingContent
                    case .token:
                        SecureField(
                            existingProfile == nil ? "Scoped access token" : "Replace token (optional)",
                            text: $token
                        )
                        .textContentType(.password)
                        Text("Manual tokens are a compatibility path and may expire without renewal.")
                            .foregroundStyle(.secondary)
                        if hasChangedOrigin && token.isEmpty {
                            Label("Enter a replacement token or pair this Mac before using a new server URL. The saved credential is never sent to a changed origin.", systemImage: "lock.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(enrollment != nil || isWorking)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityLabel("Connection error: \(errorMessage)")
            }

            if let connectionTestResult {
                Label(connectionTestResult, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .accessibilityLabel("Connection test succeeded: \(connectionTestResult)")
            }

            footer
        }
        .padding(24)
        .frame(width: 560)
        .task(id: enrollment?.id) {
            guard let enrollment else { return }
            await waitForApproval(enrollment)
        }
        .onChange(of: address) { _, _ in
            guard enrollment == nil else { return }
            discoveredCapabilities = nil
            connectionTestResult = nil
        }
        .onChange(of: name) { _, _ in connectionTestResult = nil }
        .onChange(of: token) { _, _ in connectionTestResult = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.breathe, options: .nonRepeating, isActive: !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text(existingProfile == nil ? "Connect to Norn" : "Edit Norn Connection")
                    .font(.title2.weight(.semibold))
                Text(authenticationMethod == .pair
                    ? "Pairing keeps the control-plane token off this Mac."
                    : "Update this saved connection without exposing its current token.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        if let enrollment {
            VStack(alignment: .leading, spacing: 12) {
                Label("Approve this code in an existing administrator session", systemImage: "checkmark.shield")
                    .font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(enrollment.userCode)
                        .font(.system(.title, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing code \(enrollment.userCode)")
                    Button("Copy", systemImage: "doc.on.doc") {
                        copy(enrollment.userCode)
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy pairing code")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(enrollment.expiresAt.timeIntervalSince(context.date)))
                    Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(remaining < 60 ? .orange : .secondary)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…")
                        .foregroundStyle(.secondary)
                }
                Button("Copy CLI Approval Command", systemImage: "terminal") {
                    copy("norn access approve \(enrollment.userCode) --scope \(requestedScopes.joined(separator: ","))")
                }
                .help("Copies a command for an authenticated Norn administrator")
                if let identityProtection {
                    Label(
                        identityProtection == .secureEnclave
                            ? "Device key protected by Secure Enclave"
                            : "Device key protected by Login Keychain",
                        systemImage: "key.horizontal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } else {
            DisclosureGroup("Requested access") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        discoveredCapabilities?.isFleetAuthorityOnly == true
                            ? "View this Fleet authority and its durable plans"
                            : "View platform state and live events",
                        systemImage: "checkmark.circle.fill"
                    )
                        .foregroundStyle(.secondary)
                    if discoveredCapabilities?.isFleetAuthorityOnly == true {
                        Label("This authority intentionally omits runtime events and app, host, and release access.", systemImage: "lock.shield")
                            .foregroundStyle(.secondary)
                        Toggle("Request capacity-plan access (api:write)", isOn: $allowAppChanges)
                    } else {
                        Toggle("Manage apps and recovery", isOn: $allowAppChanges)
                        Toggle("Run platform maintenance", isOn: $allowPlatformOperations)
                        Toggle("Run host assurance", isOn: $allowHostOperations)
                        Toggle("Manage Fleet capacity (api:write)", isOn: $allowFleetOperations)
                        Toggle("Open audited terminal sessions", isOn: $allowTerminalSessions)
                    }
                }
                .padding(.top, 6)
            }
            Text("An administrator reviews these scopes before this Mac receives a revocable 30-day device credential.")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if enrollment != nil {
                Button("Start Over") {
                    enrollment = nil
                    identityProtection = nil
                    errorMessage = nil
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if enrollment == nil, authenticationMethod == .token, onTestConnection != nil {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isWorking {
                        Label("Testing…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(!canTestConnection)
            }
            if enrollment == nil {
                Button(primaryActionTitle) {
                    Task { await performPrimaryAction() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canPerformPrimaryAction)
            }
        }
    }

    private func performPrimaryAction() async {
        guard let profile else { return }
        isWorking = true
        errorMessage = nil
        connectionTestResult = nil
        defer { isWorking = false }
        do {
            switch authenticationMethod {
            case .pair:
                guard let capabilities = discoveredCapabilities else {
                    let discovered = try await onDiscoverCapabilities(profile)
                    discoveredCapabilities = discovered
                    if discovered.isFleetAuthorityOnly {
                        allowAppChanges = false
                        allowPlatformOperations = false
                        allowHostOperations = false
                        allowFleetOperations = false
                        allowTerminalSessions = false
                    }
                    return
                }
                if capabilities.isFleetAuthorityOnly {
                    allowPlatformOperations = false
                    allowHostOperations = false
                    allowFleetOperations = false
                    allowTerminalSessions = false
                }
                let result = try await onStartEnrollment(profile, requestedScopes)
                enrollment = result.session
                identityProtection = result.protection
            case .token:
                try await onManualSave(profile, token)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() async {
        guard let profile, let onTestConnection else { return }
        isWorking = true
        errorMessage = nil
        connectionTestResult = nil
        defer { isWorking = false }
        do {
            connectionTestResult = try await onTestConnection(profile, token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func waitForApproval(_ enrollment: NornEnrollmentSession) async {
        guard let profile else { return }
        while !Task.isCancelled, Date.now < enrollment.expiresAt {
            do {
                try await onCompleteEnrollment(profile, enrollment)
                dismiss()
                return
            } catch NornEnrollmentClientError.awaitingApproval {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if !Task.isCancelled {
            errorMessage = NornEnrollmentClientError.expired.localizedDescription
            self.enrollment = nil
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension String {
    var isTailscaleHostname: Bool {
        lowercased().hasSuffix(".ts.net")
    }
}
