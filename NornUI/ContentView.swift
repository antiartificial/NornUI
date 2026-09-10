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
                onDiscoverCapabilities: { profile in
                    try await appModel.discoverEnrollmentCapabilities(profile: profile)
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
			CreateAppSheet(
				profileID: appModel.selectedProfileID,
				canCreate: appModel.canManageApps,
				issueMutationContext: { appModel.issueMutationContext() }
			) { request, context in await appModel.createApp(request, context: context) != nil }
		}
        .task { await appModel.start() }
    }

    private var sidebar: some View {
        List(selection: guardedNavigation) {
            if appModel.isServerAuthenticated {
                Section {
                    AuthorityContextBanner(appModel: appModel)
                }
            }
            Section("Control Room") {
                ForEach(appModel.availableNavigationDestinations) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                        .tag(destination)
                        .accessibilityHint("Shows \(destination.title.lowercased())")
                }
            }

            if !appModel.isFleetAuthorityOnly {
            Section("Activity") {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Inspect Activity", systemImage: NornNavigation.activity.symbol)
                    HStack(spacing: 10) {
                        Label("\(appModel.snapshot.activeOperations.count) active", systemImage: "bolt.horizontal")
                        Label("\(appModel.snapshot.passingServices)/\(appModel.snapshot.services.count)", systemImage: "checkmark.circle")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .tag(NornNavigation.activity)
                .accessibilityIdentifier("sidebar.activity")
                .accessibilityHint("Shows the operations and services behind these totals")
            }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ConnectionCard(appModel: appModel)
                .padding(10)
        }
        .navigationTitle("Norn")
    }

    private var guardedNavigation: Binding<NornNavigation> {
        Binding(
            get: { appModel.navigation },
            set: { appModel.navigate(to: $0) }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch appModel.navigation {
        case .overview:
            OverviewView(
                snapshot: appModel.selectedProfile == nil && !appModel.isFixtureMode ? nil : appModel.snapshot,
                connectionState: appModel.isFixtureMode ? .idle : appModel.connectionState,
                updateMode: $appModel.overviewUpdateMode,
                isRefreshing: appModel.isRefreshing,
                onRefresh: refresh,
                onShowServices: { appModel.navigate(to: .apps) },
                onShowOperations: { appModel.navigate(to: .operations) },
                onShowReleases: { appModel.navigate(to: .platform) },
                onShowHost: { appModel.navigate(to: .host) },
                onOpenService: appModel.openService,
                onOpenOperation: openOperation
            )
			.onAppear { appModel.setOverviewVisible(true) }
			.onDisappear { appModel.setOverviewVisible(false) }
		case .apps:
			AppsView(
				apps: appModel.snapshot.apps,
				services: appModel.snapshot.services,
				selectedAppName: $appModel.selectedAppName,
				selectedService: $appModel.selectedService,
				canCreate: appModel.canManageApps,
				supportsRecovery: appModel.canReadRuntime && appModel.durableAppRecoverySupported,
				canManageRecovery: appModel.canManageAppRecovery,
				profileID: appModel.selectedProfileID,
				isRecoveryConnected: appModel.canReadRuntime,
				onCreate: { appModel.isShowingCreateApp = true },
				onEnable: { app in
					let context = appModel.issueMutationContext()
					Task { await appModel.setAppDeployment(app: app, enabled: true, context: context) }
				},
				onLoadSnapshots: { await appModel.appSnapshots(app: $0) },
				issueMutationContext: { appModel.issueMutationContext() },
				onQueueOperation: { request, context in await appModel.queueAppOperation(request, context: context) },
				onOpenOperation: openOperation
			)
		case .delivery:
			ReleasePipelineFeatureView(
				apps: appModel.snapshot.apps,
				deployments: appModel.deployments,
				environmentID: appModel.environmentID,
				environmentProfile: appModel.environmentProfile,
				isSupported: appModel.releasePipelineSupported,
				isConnected: appModel.canReadLegacyReleaseEvidence,
				profileID: appModel.selectedProfileID,
				onLoadQualifications: { await appModel.releaseQualifications(app: $0) }
			)
		case .operations:
            OperationsFeatureView(
                snapshot: appModel.snapshot,
				selectedOperationID: $appModel.selectedOperationID,
                onRefresh: refresh,
                onOpenOperation: openOperation
            )
        case .platform:
            PlatformFeatureView(
                snapshot: appModel.snapshot,
                isConnected: appModel.canRunPlatformMaintenance,
				profileID: appModel.selectedProfileID,
                onQueue: queue
            )
        case .host:
            let hostProfileID = appModel.selectedProfileID
            HostFeatureView(
                snapshot: appModel.snapshot,
                isConnected: appModel.canReadRuntime,
                metrics: appModel.hostMetrics,
				metricHistory: appModel.hostMetricsHistory,
				serviceMetricHistory: appModel.serviceMetricsHistory,
                historyRevision: appModel.hostHistoryPresentationRevision,
				serviceMetricsCollectionEnabled: $appModel.serviceMetricsCollectionEnabled,
				refreshInterval: $appModel.hostMetricsRefreshInterval,
                isMetricsSupported: appModel.hostMetricsSupported,
                canReadRuntime: appModel.canReadRuntime,
                canWriteRuntime: appModel.canWriteRuntime,
                canRunAssurance: appModel.canRunHostAssurance,
				profileID: appModel.selectedProfileID,
                onQueue: queue,
                onOpenOperation: openOperation,
				onOpenService: appModel.openService,
				onLoadServiceLogs: { await appModel.appLogs(for: $0) },
				issueMutationContext: { appModel.issueMutationContext() },
				onRestartApp: { service, context in
					return await appModel.restartAppAllocations(for: service, context: context)
				},
                onRequestMetricsHistory: { window, end in await appModel.requestMetricsHistory(window: window, endingAt: end) },
                onRefresh: refreshHost
            )
			.id(appModel.selectedProfileID)
            .onAppear { appModel.setHostVisible(true, profileID: hostProfileID) }
            .onDisappear { appModel.setHostVisible(false, profileID: hostProfileID) }
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
                environmentID: appModel.environmentID,
                isSupported: appModel.fleetSupported,
                canPlan: appModel.canOperateFleet,
				profileID: appModel.selectedProfileID,
                isStale: appModel.hasStaleCachedConnectionState,
                isRefreshing: appModel.isFleetRefreshing,
                onRefresh: refreshFleet,
                issueMutationContext: { appModel.issueMutationContext() },
                onPlan: { pool, desired, size, reason, context in
                    await appModel.planFleetCapacity(
                        pool: pool,
                        desired: desired,
                        size: size,
                        reason: reason,
                        context: context
                    ) != nil
                },
				onOpenReview: { planID, context in await appModel.createFleetPullRequest(planID: planID, context: context) },
				onDispatchApply: { planID, allowDestructive, context in await appModel.dispatchFleetApply(planID: planID, allowDestructive: allowDestructive, context: context) },
				onOpenOperation: openOperation
            )
            .onAppear { appModel.setFleetVisible(true) }
            .onDisappear { appModel.setFleetVisible(false) }
        case .activity:
            ActivityFeatureView(
                snapshot: appModel.snapshot,
                onOpenOperation: openOperation,
                onShowApps: { appModel.navigate(to: .apps) }
            )
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
        let context = appModel.issueMutationContext()
        Task { await appModel.queue(request, context: context) }
    }

    private func openOperation(_ operation: NornOperation) {
        appModel.openOperation(operation)
    }
}

private struct AuthorityContextBanner: View {
    let appModel: NornAppModel

    private var environment: String {
        appModel.assertedEnvironmentID?.capitalized ?? "Environment not asserted"
    }

    private var authority: String {
        guard let asserted = appModel.assertedAuthority else { return "Authority mode not asserted" }
        return asserted == "fleet-only" ? "Fleet-only authority" : asserted
    }

    var body: some View {
        Label("Authenticated: \(environment) · \(appModel.assertedEnvironmentProfile ?? "Profile not asserted") · \(authority)", systemImage: "checkmark.shield.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(appModel.isFleetAuthorityOnly ? .purple : .green)
            .accessibilityIdentifier("authority.context.banner")
            .help("Environment and authority are asserted by the authenticated server response.")
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
