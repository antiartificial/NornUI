import SwiftUI

struct ContentView: View {
    @Bindable var appModel: NornAppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } detail: {
            detail
                .frame(minWidth: 700, minHeight: 560)
                .overlay(alignment: .top) {
                    if let lastError = appModel.lastError {
                        ErrorBanner(message: lastError) {
                            appModel.lastError = nil
                        }
                        .padding(.top, 10)
                        .padding(.horizontal, 16)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appModel.lastError)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ProfileMenu(appModel: appModel)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Add Server…", systemImage: "plus") {
                        appModel.isShowingProfileEditor = true
                    }
                    SettingsLink {
                        Label("Server Settings…", systemImage: "gear")
                    }
                } label: {
                    Label("Server Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $appModel.isShowingProfileEditor) {
            ServerProfileEditor(
                onManualSave: { profile, token in
                    try await appModel.saveProfile(profile, token: token)
                },
                onStartEnrollment: { profile, scopes in
                    try await appModel.startDeviceEnrollment(profile: profile, requestedScopes: scopes)
                },
                onCompleteEnrollment: { profile, enrollment in
                    try await appModel.completeDeviceEnrollment(profile: profile, enrollment: enrollment)
                }
            )
        }
		.sheet(isPresented: $appModel.isShowingCreateApp) {
			CreateAppSheet { request in await appModel.createApp(request) != nil }
		}
        .task { await appModel.start() }
    }

    private var sidebar: some View {
        List(selection: $appModel.navigation) {
            Section("Control Room") {
                ForEach(NornNavigation.allCases) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                        .tag(destination)
                        .accessibilityHint("Shows \(destination.title.lowercased())")
                }
            }

            Section("Activity") {
                LabeledContent {
                    Text("\(appModel.snapshot.activeOperations.count)")
                        .font(.body.monospacedDigit())
                } label: {
                    Label("Active", systemImage: "bolt.horizontal.circle")
                }

                LabeledContent {
                    Text("\(appModel.snapshot.passingServices)/\(appModel.snapshot.services.count)")
                        .font(.body.monospacedDigit())
                } label: {
                    Label("Passing", systemImage: "checkmark.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ConnectionCard(appModel: appModel)
                .padding(10)
        }
        .navigationTitle("Norn")
    }

    @ViewBuilder
    private var detail: some View {
        switch appModel.navigation {
        case .overview:
            OverviewView(
                snapshot: appModel.selectedProfile == nil && !appModel.isFixtureMode ? nil : appModel.snapshot,
                connectionState: appModel.isFixtureMode ? .idle : appModel.connectionState,
                isRefreshing: appModel.isRefreshing,
                onRefresh: refresh,
                onShowServices: { appModel.navigation = .apps },
                onShowOperations: { appModel.navigation = .operations },
                onShowReleases: { appModel.navigation = .platform },
                onShowHost: { appModel.navigation = .host }
            )
        case .apps:
			AppsView(
				apps: appModel.snapshot.apps,
				services: appModel.snapshot.services,
				canCreate: appModel.canPerformOperations && appModel.appCreationSupported,
				supportsRecovery: appModel.canPerformOperations && appModel.durableAppRecoverySupported,
				onCreate: { appModel.isShowingCreateApp = true },
				onEnable: { app in Task { await appModel.setAppDeployment(app: app, enabled: true) } },
				onLoadSnapshots: { await appModel.appSnapshots(app: $0) },
				onQueueOperation: { await appModel.queueAppOperation($0) },
				onOpenOperation: openOperation
			)
        case .operations:
            OperationsFeatureView(
                snapshot: appModel.snapshot,
                onRefresh: refresh,
                onOpenOperation: openOperation
            )
        case .platform:
            PlatformFeatureView(
                snapshot: appModel.snapshot,
                isConnected: appModel.canPerformOperations,
                onQueue: queue
            )
        case .host:
            HostFeatureView(
                snapshot: appModel.snapshot,
                isConnected: appModel.canPerformOperations,
                metrics: appModel.hostMetrics,
                isMetricsSupported: appModel.hostMetricsSupported,
                onQueue: queue,
                onOpenOperation: openOperation,
                onRefresh: refreshHost
            )
            .onAppear { appModel.setHostMetricsVisible(true) }
            .onDisappear { appModel.setHostMetricsVisible(false) }
        case .fleet:
            FleetFeatureView(
                inventory: appModel.fleetInventory,
                plans: appModel.fleetPlans,
                reconciliations: appModel.fleetReconciliations,
                runnerAttempts: appModel.fleetRunnerAttempts,
                githubStatus: appModel.fleetGitHubStatus,
                snapshot: appModel.snapshot,
                deployments: appModel.deployments,
                deploymentSteps: appModel.deploymentSteps,
                deploymentVisibilitySupported: appModel.deploymentVisibilitySupported,
                isSupported: appModel.fleetSupported,
                canPlan: appModel.canPerformOperations,
                canOperateFleet: appModel.canOperateFleet,
                isStale: !appModel.isFixtureMode && appModel.connectionState != .online,
                isRefreshing: appModel.isFleetRefreshing,
                onRefresh: refreshFleet,
                onPlan: { pool, desired, size, reason in
                    await appModel.planFleetCapacity(
                        pool: pool,
                        desired: desired,
                        size: size,
                        reason: reason
                    ) != nil
                },
                onOpenReview: { await appModel.createFleetPullRequest(planID: $0) },
                onDispatchApply: { await appModel.dispatchFleetApply(planID: $0, allowDestructive: $1) },
				onAdvanceRunner: { await appModel.advanceFleetRunnerAttempt(planID: $0, attempt: $1) },
				onOpenOperation: openOperation
            )
            .onAppear { appModel.setFleetVisible(true) }
            .onDisappear { appModel.setFleetVisible(false) }
        }
    }

    private func refresh() {
        Task { await appModel.refresh() }
    }

    private func refreshHost() {
        Task { await appModel.refreshHost() }
    }

    private func refreshFleet() {
        Task {
            if appModel.connectionState == .online {
                await appModel.refreshFleet()
            } else {
                await appModel.refresh()
            }
        }
    }

    private func queue(_ request: NornMaintenanceRequest) {
        Task { await appModel.queue(request) }
    }

    private func openOperation(_ operation: NornOperation) {
        appModel.selectedOperationID = operation.id
        appModel.navigation = .operations
    }
}

private struct ProfileMenu: View {
    @Bindable var appModel: NornAppModel

    var body: some View {
        Menu {
            if appModel.profiles.isEmpty {
                Text("Exploring fixture data")
            } else {
                ForEach(appModel.profiles) { profile in
                    Button {
                        Task { await appModel.selectProfile(id: profile.id) }
                    } label: {
                        if profile.id == appModel.selectedProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }

            Divider()
            Button("Add Server…", systemImage: "plus") {
                appModel.isShowingProfileEditor = true
            }
        } label: {
            Label(appModel.selectedProfile?.name ?? "Explore Norn", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .help("Choose a Norn server")
    }
}

private struct ConnectionCard: View {
    @Bindable var appModel: NornAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: (title: String, detail: String, symbol: String, tint: Color, animated: Bool) {
        if appModel.isFixtureMode {
            return ("Explore Mode", "Sample data", "sparkles", .purple, false)
        }
        switch appModel.connectionState {
        case .idle:
            return ("Not Connected", "Choose a server", "circle.dashed", .secondary, false)
        case .connecting:
            return ("Connecting", "Negotiating capabilities", "antenna.radiowaves.left.and.right", .accentColor, true)
        case .online:
            return ("Online", "Events are live", "checkmark.circle.fill", .green, false)
        case .reconnecting:
            return ("Reconnecting", "Cached state remains visible", "arrow.triangle.2.circlepath", .orange, true)
        case .offline:
            return ("Offline", "Cached state remains visible", "wifi.slash", .orange, false)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .symbolEffect(.pulse, options: .repeating.speed(0.55), isActive: presentation.animated && !reduceMotion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                Text(presentation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !appModel.isFixtureMode, appModel.connectionState != .online {
                Button {
                    Task { await appModel.connect() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reconnect")
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Norn connection: \(presentation.title). \(presentation.detail)")
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Norn request failed. \(message)")
    }
}

#Preview {
    ContentView(appModel: NornAppModel(fixture: NornFixtures.snapshot))
        .frame(width: 1_180, height: 760)
}
