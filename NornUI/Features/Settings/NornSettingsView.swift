import SwiftUI

struct NornSettingsView: View {
    let profiles: [NornServerProfile]
    let selectedProfileID: UUID?
    let onSelect: (UUID?) async -> Void
    let onAdd: (NornServerProfile, String) async throws -> Void
    let onRemove: (UUID) -> Void

    @State private var isAddingServer = false
    @State private var pendingRemoval: NornServerProfile?

    var body: some View {
        Form {
            Section("Servers") {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No Servers",
                        systemImage: "macmini",
                        description: Text("Add a Norn server to leave fixture mode.")
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
                            Button("Use") {
                                Task { await onSelect(profile.id) }
                            }
                            .disabled(profile.id == selectedProfileID)
                            Button("Remove", role: .destructive) {
                                pendingRemoval = profile
                            }
                        }
                    }
                }

                Button("Add Server…", systemImage: "plus") {
                    isAddingServer = true
                }
            }

            Section("Security") {
                LabeledContent("Credentials", value: "Login Keychain")
                LabeledContent("Event authentication", value: "Bearer header")
                Text("Norn never stores access tokens in preferences, logs, or URLs.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 440)
        .sheet(isPresented: $isAddingServer) {
            ServerProfileEditor(onSave: onAdd)
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
            Text("This removes the server profile and its scoped token from Keychain. You can add it again later.")
        }
    }
}
