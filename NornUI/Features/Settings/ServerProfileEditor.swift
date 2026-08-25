import SwiftUI

struct ServerProfileEditor: View {
    let existingProfile: NornServerProfile?
    let onSave: (NornServerProfile, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @State private var address: String
    @State private var token = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        profile: NornServerProfile? = nil,
        onSave: @escaping (NornServerProfile, String) async throws -> Void
    ) {
        existingProfile = profile
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _address = State(initialValue: profile?.baseURL.absoluteString ?? "https://")
    }

    private var normalizedURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && url.host?.isLoopbackHost == true),
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalizedURL != nil
            && (!token.isEmpty || existingProfile != nil)
            && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.breathe, options: .nonRepeating, isActive: !reduceMotion)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existingProfile == nil ? "Connect to Norn" : "Edit Norn Server")
                        .font(.title2.weight(.semibold))
                    Text("Credentials are stored in your login Keychain.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Studio Mini"))
                TextField("Server URL", text: $address, prompt: Text("https://norn.example.com"))
                    .textContentType(.URL)
                SecureField(
                    existingProfile == nil ? "Scoped access token" : "Replace token (optional)",
                    text: $token
                )
                .textContentType(.password)
            }
            .formStyle(.grouped)

            Label(
                "Start with api:read and events:read. Add platform or host operation scopes only when this Mac needs them.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityLabel("Connection error: \(errorMessage)")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingProfile == nil ? "Connect" : "Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func save() async {
        guard let normalizedURL else { return }
        isSaving = true
        defer { isSaving = false }
        let profile = NornServerProfile(
            id: existingProfile?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: normalizedURL,
            credentialID: existingProfile?.credentialID
        )
        do {
            try await onSave(profile, token)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var isLoopbackHost: Bool {
        self == "localhost" || self == "127.0.0.1" || self == "::1"
    }
}
