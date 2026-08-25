import SwiftUI

@main
struct NornUIApp: App {
    private let credentialVault: KeychainCredentialVault
    @State private var appModel: NornAppModel

    init() {
        let vault = KeychainCredentialVault()
        credentialVault = vault
        _appModel = State(initialValue: NornAppModel(
            clientFactory: { profile in
                try await NornClient(profile: profile, credentialVault: vault)
            },
            credentialVault: vault
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowStyle(.automatic)
        .commands {
            NornCommands(appModel: appModel)
        }

        Settings {
            NornSettingsView(
                profiles: appModel.profiles,
                selectedProfileID: appModel.selectedProfileID,
                onSelect: { await appModel.selectProfile(id: $0) },
                onAdd: { try await appModel.saveProfile($0, token: $1) },
                onRemove: { id in
                    Task { await appModel.removeProfileAndCredential(id: id) }
                }
            )
        }
    }
}

private struct NornCommands: Commands {
    let appModel: NornAppModel

    var body: some Commands {
        CommandMenu("Norn") {
			Button("Create App…") {
				appModel.navigation = .apps
				appModel.isShowingCreateApp = true
			}
			.keyboardShortcut("n", modifiers: .command)
			.disabled(!appModel.canPerformOperations || !appModel.appCreationSupported)

			Divider()
            Button("Refresh Control Room") {
                Task { await appModel.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Run Platform Smoke Check") {
                Task { await appModel.queue(.platformSmoke) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!appModel.canPerformOperations)

            Button("Run Host Assurance") {
                Task { await appModel.queue(.hostAssurance) }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!appModel.canPerformOperations)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(NornNavigation.allCases.enumerated()), id: \.element.id) { index, destination in
                Button("Show \(destination.title)") {
                    appModel.navigation = destination
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
