import SwiftUI

struct NornSettingsView: View {
    let profiles: [NornServerProfile]
    let selectedProfileID: UUID?
    let onSelect: (UUID?) async -> Void
    let onManualSave: (NornServerProfile, String) async throws -> Void
    let onTestConnection: ServerProfileEditor.ConnectionTest?
    let onDiscoverCapabilities: ServerProfileEditor.CapabilityDiscovery
    let onStartEnrollment: ServerProfileEditor.EnrollmentStart
    let onCompleteEnrollment: (NornServerProfile, NornEnrollmentSession) async throws -> Void
    let issueMutationContext: () -> NornMutationContext?
    let onRotate: (NornMutationContext) async -> Void
    let onRemove: (UUID) -> Void

    @State private var isAddingServer = false
    @State private var editingProfile: NornServerProfile?
    @State private var pairingProfile: NornServerProfile?
    @State private var pendingRemoval: NornServerProfile?

    var body: some View {
        Form {
            Section("Servers") {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No Servers",
                        systemImage: "macmini",
                        description: Text("Add a Norn server to load live platform state.")
                    )
                } else {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .fontWeight(.medium)
                                Text(profile.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if profile.id == selectedProfileID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Selected")
                            }
                            if profile.isManagedDevice {
                                Label("Managed", systemImage: "person.badge.key.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Use") {
                                Task { await onSelect(profile.id) }
                            }
                            .disabled(profile.id == selectedProfileID)
                            Button("Edit…") {
                                editingProfile = profile
                            }
                            if !profile.isManagedDevice {
                                Button("Pair…") {
                                    pairingProfile = profile
                                }
                            }
                            Button("Remove", role: .destructive) {
                                pendingRemoval = profile
                            }
                        }
                        .contextMenu {
                            Button("Use") { Task { await onSelect(profile.id) } }
                            Button("Edit…") { editingProfile = profile }
                            Button("Pair…") { pairingProfile = profile }
                            Divider()
                            Button("Remove", role: .destructive) { pendingRemoval = profile }
                        }
                    }
                }

                Button("Add Server…", systemImage: "plus") {
                    isAddingServer = true
                }
            }

            Section("Security") {
                LabeledContent("Credential storage", value: "Login Keychain")
                if let profile = profiles.first(where: { $0.id == selectedProfileID }) {
                    LabeledContent(
                        "Authentication",
                        value: profile.isManagedDevice ? "Enrolled device" : "Manual token"
                    )
                    if let scopes = profile.grantedScopes, !scopes.isEmpty {
                        LabeledContent("Granted scopes", value: scopes.joined(separator: ", "))
                    }
                    if let expiresAt = profile.tokenExpiresAt {
                        LabeledContent("Credential expires") {
                            Text(expiresAt, style: .relative)
                            Text(expiresAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if profile.isManagedDevice {
                        Button("Rotate Device Credential Now", systemImage: "arrow.triangle.2.circlepath") {
                            guard let context = issueMutationContext() else { return }
                            Task { await onRotate(context) }
                        }
                    } else {
                        Button("Replace with Device Enrollment…", systemImage: "person.badge.key.fill") {
                            pairingProfile = profile
                        }
                    }
                }
                Text("Norn never stores access tokens in preferences, logs, or URLs.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 520)
        .sheet(isPresented: $isAddingServer) {
            editor(profile: nil)
        }
        .sheet(item: $editingProfile) { profile in
            editor(profile: profile, startsWithPairing: false)
        }
        .sheet(item: $pairingProfile) { profile in
            editor(profile: profile, startsWithPairing: true)
        }
        .alert(
            "Remove \(pendingRemoval?.name ?? "Server")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { profile in
            Button("Remove Server", role: .destructive) {
                onRemove(profile.id)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { _ in
            Text("This removes the server profile, scoped token, and device key from this Mac. Revoke the device from an administrator session if it should lose server access immediately.")
        }
    }

    private func editor(profile: NornServerProfile?, startsWithPairing: Bool = true) -> some View {
        ServerProfileEditor(
            profile: profile,
            startsWithPairing: startsWithPairing,
            onManualSave: onManualSave,
            onTestConnection: onTestConnection,
            onDiscoverCapabilities: onDiscoverCapabilities,
            onStartEnrollment: onStartEnrollment,
            onCompleteEnrollment: onCompleteEnrollment
        )
    }
}
