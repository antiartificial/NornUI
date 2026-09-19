import Foundation
import SwiftUI

@main
struct NornUIApp: App {
    private let credentialVault: KeychainCredentialVault
    private let deviceIdentityVault: KeychainDeviceIdentityVault
    @State private var appModel: NornAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let vault = KeychainCredentialVault()
        let identityVault = KeychainDeviceIdentityVault()
        let fixture = ProcessInfo.processInfo.environment["NORN_UI_FIXTURES"] == "1"
            ? NornFixtures.snapshot
            : nil
        credentialVault = vault
        deviceIdentityVault = identityVault
        let model = NornAppModel(
            clientFactory: { profile in
                try await NornClient(profile: profile, credentialVault: vault)
            },
            credentialVault: vault,
            deviceIdentityVault: identityVault,
            enrollmentClientFactory: { baseURL in
                try await NornEnrollmentClient(baseURL: baseURL)
            },
            fixture: fixture
        )
        if fixture != nil, ProcessInfo.processInfo.environment["NORN_UI_HISTORY_STRESS"] == "1" {
            // Explicit UI-test fixture: exercise opening Host with a month of data.
            let end = NornFixtures.hostMetrics.observedAt
            var hostHistory: [NornHostMetricSample] = []
            for index in 0..<40_000 {
                let date = end.addingTimeInterval(Double(index - 39_999) * 60)
                hostHistory.append(NornHostMetricSample(
                    observedAt: date, cpuPercent: Double(index % 100),
                    memoryUsedBytes: 4_000_000_000, memoryTotalBytes: 8_000_000_000
                ))
            }
            var serviceHistory: [NornServiceMetricSample] = []
            for index in 0..<120_000 {
                let date = end.addingTimeInterval(Double(index / 6 - 19_999) * 120)
                serviceHistory.append(NornServiceMetricSample(
                    observedAt: date, app: "fixture-\(index % 6)", process: "web",
                    cpuPercent: Double(index % 80), memoryPercent: Double(index % 95)
                ))
            }
            model.hostMetricsHistory = hostHistory
            model.serviceMetricsHistory = serviceHistory
        }
        _appModel = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .frame(minWidth: 900, minHeight: 600)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await appModel.refreshManagedCredentialIfNeeded() }
                    } else {
                        Task { await appModel.persistMetricsHistory() }
                    }
                }
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
                onManualSave: { try await appModel.saveProfile($0, token: $1) },
                onTestConnection: { try await appModel.testConnection(profile: $0, token: $1) },
                onDiscoverCapabilities: { try await appModel.discoverEnrollmentCapabilities(profile: $0) },
                onStartEnrollment: { profile, scopes in
                    try await appModel.startDeviceEnrollment(profile: profile, requestedScopes: scopes)
                },
                onCompleteEnrollment: { profile, enrollment in
                    try await appModel.completeDeviceEnrollment(profile: profile, enrollment: enrollment)
                },
                issueMutationContext: { appModel.issueMutationContext() },
                onRotate: { context in await appModel.rotateManagedCredentialNow(context: context) },
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
				appModel.navigate(to: .apps)
				appModel.isShowingCreateApp = true
			}
			.keyboardShortcut("n", modifiers: .command)
			.disabled(!appModel.canManageApps)
			.help(appModel.canManageApps ? "Create a disabled app draft" : "Requires authenticated api:write and the app-creation capability")

			Divider()
            Button("Refresh Control Room") {
                Task { await appModel.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Run Platform Smoke Check") {
                let context = appModel.issueMutationContext()
                Task { await appModel.queue(.platformSmoke, context: context) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!appModel.canRunPlatformMaintenance)
            .help(appModel.canRunPlatformMaintenance ? "Queue a platform smoke check" : "Requires an authenticated platform:operate scope")

            Button("Run Host Assurance") {
                let context = appModel.issueMutationContext()
                Task { await appModel.queue(.hostAssurance, context: context) }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!appModel.canRunHostAssurance)
            .help(appModel.canRunHostAssurance ? "Queue host assurance" : "Requires an authenticated host:operate scope")
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(appModel.availableNavigationDestinations) { destination in
                Button("Show \(destination.title)") {
                    appModel.navigate(to: destination)
                }
                .keyboardShortcut(navigationShortcut(for: destination), modifiers: .command)
            }
        }
    }

    private func navigationShortcut(for destination: NornNavigation) -> KeyEquivalent {
        switch destination {
        case .overview: "1"
        case .apps: "2"
        case .operations: "3"
        case .fleet: "4"
        case .platform: "5"
        case .host: "6"
        case .activity: "7"
        case .delivery: "8"
        }
    }
}
