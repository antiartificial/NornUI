import Foundation
import SwiftUI

struct AppsView: View {
    var apps: [NornAppStatus] = []
    let services: [NornService]
    var deployments: [NornDeployment] = []
    var operations: [NornOperation] = []
    var deploymentSteps: [String: [NornDeploymentStep]] = [:]
    var loadingDeploymentIDs: Set<String> = []
    var deploymentStepErrors: [String: String] = [:]
    var deploymentActivityError: String? = nil
    var isLoadingDeploymentActivity = false
    var onSelectDeployment: (String?) -> Void = { _ in }
    var onOpenDeployment: (NornDeployment) -> Void = { _ in }
	@Binding var selectedAppName: String?
	@Binding var selectedService: NornServiceSelection?
    var canCreate = false
    var supportsRecovery = false
    var canManageRecovery = false
    var canScaleRuntime = false
    var isScalingRuntime = false
    var runtimeFeedback: String? = nil
    var onScaleRuntime: (String, [NornRuntimeScaleTarget], NornMutationContext) async -> Void = { _, _, _ in }
	var profileID: UUID? = nil
	var isRecoveryConnected = false
    var onCreate: () -> Void = {}
    var onEnable: (String) -> Void = { _ in }
    var onLoadSnapshots: (String) async -> [NornAppSnapshot]? = { _ in nil }
    var issueMutationContext: () -> NornMutationContext? = { nil }
    var onQueueOperation: (NornAppOperationRequest, NornMutationContext) async -> NornOperation? = { _, _ in nil }
    var onOpenOperation: (NornOperation) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draftEnableGate = NornProfileBoundMutationGate<String>()
    @State private var searchText = ""
    @State private var presentation: AppListPresentation = .grouped
    @State private var activeOnly = false
    @State private var sort = AppListSort.recent
    @State private var sortAscending = false
    @State private var expandedApps: Set<String> = []

    private var deploymentRecency: AppDeploymentRecency { AppDeploymentRecency(deployments: deployments, operations: operations) }

    private var filteredServices: [NornService] {
        let recency = deploymentRecency
        return services
            .filter { !activeOnly || isActive($0) }
            .filter { searchText.isEmpty || matchesSearch($0) }
            .sorted { serviceOrder($0, $1, recency: recency) }
    }

    private var groupedApps: [AppServiceGroup] {
        let recency = deploymentRecency
        let activeOperations = operations.filter { $0.status.isActive && $0.kind.localizedCaseInsensitiveContains("deploy") }
        let operationsByApp = Dictionary(grouping: activeOperations, by: { $0.app ?? "" })
            .compactMapValues { $0.max { $0.startedAt < $1.startedAt } }
        let appStatuses = apps.reduce(into: [String: NornAppStatus]()) { result, app in
            result[app.spec.name] = app
        }
        let activeServices = services.filter { !activeOnly || isActive($0) }
        let servicesByApp = Dictionary(grouping: activeServices, by: \.app)
        var names = Set(activeServices.map(\.app))
        names.formUnion(apps.compactMap { app in
            guard app.spec.deploy != false else { return nil }
            guard !activeOnly || isActive(app) else { return nil }
            return app.spec.name
        })

        names.formUnion(operationsByApp.keys.filter { !$0.isEmpty })
        names.formUnion(recency.latestByApp.values.filter { !activeOnly || $0.status.isActive }.map(\.app))

        return names.compactMap { name in
            let app = appStatuses[name]
            let allChildren = servicesByApp[name] ?? []
            let appMatches = searchText.isEmpty
                || name.localizedStandardContains(searchText)
                || app?.nomadStatus?.localizedStandardContains(searchText) == true
            let children = appMatches ? allChildren : allChildren.filter(matchesSearch)
            guard searchText.isEmpty || appMatches || !children.isEmpty else { return nil }
            return AppServiceGroup(name: name, app: app, services: children.sorted { serviceOrder($0, $1, recency: recency) }, deployment: recency.latestByApp[name], activeOperation: operationsByApp[name])
        }
        .sorted { groupOrder($0, $1, recency: recency) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                inFlightStrip
                draftStrip
                appList
            }
            .frame(minWidth: 410)

            if let selectedApp {
                VStack(spacing: 0) {
                    selectedDeploymentGraph
                    AppRecoveryInspector(
                    app: selectedApp,
                    workloadState: AppWorkloadState.aggregate(
                        app: selectedApp,
                        services: services.filter { $0.app == selectedApp.spec.name }
                    ),
                    isSupported: supportsRecovery,
                    canManage: canManageRecovery,
                    canScaleRuntime: canScaleRuntime,
                    isScalingRuntime: isScalingRuntime,
                    runtimeFeedback: runtimeFeedback,
                    onScaleRuntime: onScaleRuntime,
					profileID: profileID,
					isConnected: isRecoveryConnected,
                    onLoadSnapshots: onLoadSnapshots,
                    issueMutationContext: issueMutationContext,
                    onQueue: onQueueOperation,
                    onOpenOperation: onOpenOperation
                )
                }
                .frame(minWidth: 290, idealWidth: 440, maxWidth: 620)
            } else if let deployment = selectedDeployment {
                VStack(alignment: .leading, spacing: 14) {
                    Text(deployment.app).font(.title2.weight(.semibold))
                    selectedDeploymentGraph
                    Text("This app has deployment activity but no app inventory is available yet.")
                        .foregroundStyle(.secondary)
                    Button("View Deployment", systemImage: "point.3.connected.trianglepath.dotted") { onOpenDeployment(deployment) }
                    Spacer()
                }
                .padding(18)
                .frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let operation = operations.first(where: { $0.app == selectedAppName && $0.status.isActive && $0.kind.localizedCaseInsensitiveContains("deploy") }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(operation.app ?? "Deployment").font(.title2.weight(.semibold))
                    Text(operation.message ?? "Deployment \(operation.status.rawValue)")
                    Text("Deployment steps appear when the deployment record becomes available.")
                        .foregroundStyle(.secondary)
                    Button("View Operation") { onOpenOperation(operation) }
                    Spacer()
                }
                .padding(18)
                .frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose an app to inspect its durable recovery controls.")
                )
                .frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search apps, processes, and status")
        .navigationTitle("Apps")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Organization", selection: $presentation) {
                    Label("Grouped", systemImage: "list.bullet.indent")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Grouped app list")
                        .accessibilityIdentifier("apps.presentation.grouped")
                        .tag(AppListPresentation.grouped)
                    Label("Flat", systemImage: "tablecells")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Flat app list")
                        .accessibilityIdentifier("apps.presentation.flat")
                        .tag(AppListPresentation.flat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 126)
                .help("Switch between app groups and a flat service list")
                .accessibilityIdentifier("apps.presentation")

                Toggle(isOn: $activeOnly) {
                    Label("Active Only", systemImage: "bolt.fill")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("apps.active-only")
                }
                .toggleStyle(.button)
                .help("Show only running, healthy, or routable apps and services")
                .accessibilityLabel("Show active apps only")

                Button(action: onCreate) {
                    Label("Create App", systemImage: "plus")
                }
                .disabled(!canCreate)
                .help(canCreate ? "Create a disabled app draft" : "Requires authenticated api:write and the app-creation capability")
            }
        }
        .task {
			revealLinkedServiceIfNeeded()
			normalizeSelection()
		}
        .task(id: "\(profileID?.uuidString ?? "none")/\(selectedDeployment?.id ?? "none")") {
            onSelectDeployment(selectedDeployment?.id)
        }
        .onChange(of: visibleAppNames) { _, _ in normalizeSelection() }
		.onChange(of: selectedService) { _, _ in revealLinkedServiceIfNeeded() }
        .onChange(of: profileID) { _, _ in draftEnableGate.invalidate() }
        .onChange(of: canCreate) { _, _ in draftEnableGate.invalidate() }
        .onChange(of: apps) { _, _ in draftEnableGate.invalidate() }
        .confirmationDialog(
            "Enable deployment for \(draftEnableGate.pending?.intent ?? "this app")?",
            isPresented: Binding(
                get: { draftEnableGate.pending != nil },
                set: { if !$0 { draftEnableGate.dismiss() } }
            )
        ) {
            Button("Enable Deployment") {
                if let appID = draftEnableGate.confirmedIntent(profileID: profileID, isAuthorized: canCreate, isStillCurrent: { appID in
                    apps.contains(where: { $0.id == appID && $0.spec.deploy == false })
                }) {
                    onEnable(appID)
                }
            }
            Button("Cancel", role: .cancel) { draftEnableGate.dismiss() }
        } message: {
            Text("The app will become eligible for deploy and host-recovery workflows. Verify its source, build, secrets, and health checks first.")
        }
    }

    @ViewBuilder
    private var selectedDeploymentGraph: some View {
        if let deployment = selectedDeployment {
            DeploymentPipelineGraph(
                deployment: deployment,
                steps: deploymentSteps[deployment.id] ?? [],
                isLoading: loadingDeploymentIDs.contains(deployment.id),
                errorMessage: deploymentStepErrors[deployment.id],
                isLive: isRecoveryConnected && !deployment.sagaID.isEmpty && operations.contains { $0.status.isActive && $0.sagaID == deployment.sagaID }
            )
            .padding(12)
            Divider()
        }
    }

    @ViewBuilder
    private var inFlightStrip: some View {
        let active = operations.filter { $0.status.isActive && $0.kind.localizedCaseInsensitiveContains("deploy") }
            .sorted { $0.startedAt > $1.startedAt }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(isRecoveryConnected ? "Deployments in flight" : "Last reported deployment activity", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption.weight(.semibold))
                ForEach(Array(active.prefix(5))) { operation in
                    Button { onOpenOperation(operation) } label: {
                        HStack {
                            Text(operation.app ?? "Deployment").fontWeight(.medium)
                            Spacer()
                            Text(operation.message ?? operation.status.rawValue.capitalized)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            Divider()
        }
    }

    @ViewBuilder
    private var draftStrip: some View {
        if !drafts.isEmpty {
            HStack(spacing: 10) {
                Label("Drafts", systemImage: "lock.shield")
                    .fixedSize()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(drafts) { app in
                            HStack(spacing: 5) {
                                Text(app.spec.name)
                                    .font(.callout.weight(.medium))
                                Button("Enable") {
                                    guard drafts.contains(where: { $0.id == app.id }) else { return }
                                    draftEnableGate.present(app.id, profileID: profileID, isAuthorized: canCreate)
                                }
                                    .disabled(!canCreate)
                                    .help(canCreate ? "Enable this app deployment" : "Requires authenticated api:write and app-creation capability")
                                    .buttonStyle(.link)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Text("Deployment off")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(12)
            Divider()
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            if let deploymentActivityError {
                Label(deploymentActivityError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
            }
            HStack {
                Button { applySort(.recent) } label: {
                    Label(sort == .recent && sortAscending ? "Oldest deployment first" : "Recent deployments", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(sort == .recent ? Color.accentColor : Color.secondary)
                .accessibilityIdentifier("apps.sort.recent")
                if isLoadingDeploymentActivity {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing apps and deployments")
                }
                Spacer()
                if let deployment = selectedDeployment {
                    Button("View Deployment") { onOpenDeployment(deployment) }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            AppListHeader(sort: sort, ascending: sortAscending, onSort: applySort)
            Divider()
            if visibleAppNames.isEmpty {
                ContentUnavailableView(
                    activeOnly && searchText.isEmpty ? "No Active Apps" : "No Matching Apps",
                    systemImage: activeOnly && searchText.isEmpty ? "bolt.slash" : "magnifyingglass",
                    description: Text(activeOnly && searchText.isEmpty ? "Turn off Active Only to include stopped or unhealthy services." : "Try a different search or filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if presentation == .grouped {
                            ForEach(groupedApps) { group in
                                AppGroupRow(
                                    group: group,
                                    isExpanded: expandedApps.contains(group.id),
                                    isSelected: selectedAppName == group.name && selectedService == nil,
                                    onToggle: { toggleExpansion(group.name) },
                                    onSelect: { selectApp(group.name) }
                                )
                                if expandedApps.contains(group.id) {
                                    ForEach(group.services) { service in
                                        AppServiceRow(
                                            service: service,
                                            app: group.app,
                                            isChild: true,
                                            isSelected: selectedService?.matches(service) == true,
                                            onSelect: { selectService(service) }
                                        )
                                    }
                                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                                }
                                Divider()
                            }
                        } else if sort == .recent {
                            ForEach(groupedApps) { group in
                                if group.services.isEmpty {
                                    AppGroupRow(group: group, isExpanded: false, isSelected: selectedAppName == group.name,
                                                onToggle: {}, onSelect: { selectApp(group.name) })
                                    Divider()
                                } else {
                                    ForEach(group.services) { service in
                                        AppServiceRow(service: service, app: group.app, isChild: false,
                                                      isSelected: selectedService?.matches(service) == true,
                                                      onSelect: { selectService(service) })
                                        Divider()
                                    }
                                }
                            }
                        } else {
                            ForEach(groupedApps.filter { $0.services.isEmpty }) { group in
                                AppGroupRow(group: group, isExpanded: false, isSelected: selectedAppName == group.name,
                                            onToggle: {}, onSelect: { selectApp(group.name) })
                                Divider()
                            }
                            ForEach(filteredServices) { service in
                                AppServiceRow(
                                    service: service,
                                    app: appStatus(for: service.app),
                                    isChild: false,
                                    isSelected: selectedService?.matches(service) == true,
                                    onSelect: { selectService(service) }
                                )
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("apps.list")
    }

    private var drafts: [NornAppStatus] {
        guard !activeOnly else { return [] }
        return apps
            .filter { $0.spec.deploy == false }
            .filter { searchText.isEmpty || $0.spec.name.localizedStandardContains(searchText) }
            .sorted { $0.spec.name.localizedStandardCompare($1.spec.name) == .orderedAscending }
    }

    private var visibleAppNames: [String] {
        switch presentation {
        case .grouped: groupedApps.map(\.name)
        case .flat: groupedApps.map(\.name)
        }
    }

    private var selectedDeployment: NornDeployment? {
        guard let name = selectedAppName ?? visibleAppNames.first else { return nil }
        return deploymentRecency.latestByApp[name]
    }

    private var selectedApp: NornAppStatus? {
        guard let name = selectedAppName ?? visibleAppNames.first else { return nil }
        return apps.first { $0.spec.name == name }
    }

    private func normalizeSelection() {
        if let selectedAppName, visibleAppNames.contains(selectedAppName) { return }
        selectedAppName = visibleAppNames.first
		selectedService = nil
    }

	private func selectApp(_ app: String) {
		selectedAppName = app
		selectedService = nil
	}

	private func selectService(_ service: NornService) {
		selectedAppName = service.app
		selectedService = NornServiceSelection(service: service)
	}

	private func revealLinkedServiceIfNeeded() {
		guard let selectedService,
			  let service = services.first(where: selectedService.matches) else { return }
		selectedAppName = service.app
		expandedApps.insert(service.app)
	}

    private func toggleExpansion(_ app: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if expandedApps.contains(app) { expandedApps.remove(app) }
            else { expandedApps.insert(app) }
        }
    }

    private func applySort(_ next: AppListSort) {
        if sort == next { sortAscending.toggle() }
        else { sort = next; sortAscending = next != .recent }
    }

    private func matchesSearch(_ service: NornService) -> Bool {
        let workloadState = AppWorkloadState.resolve(service: service, app: appStatus(for: service.app))
        return service.app.localizedStandardContains(searchText)
            || service.process.localizedStandardContains(searchText)
            || service.name.localizedStandardContains(searchText)
            || service.status.localizedStandardContains(searchText)
            || service.type.localizedStandardContains(searchText)
            || workloadState.label.localizedStandardContains(searchText)
            || service.reachability.exposure.localizedStandardContains(searchText)
            || service.endpoints?.contains { $0.url.localizedStandardContains(searchText) } == true
            || service.instances?.contains {
                $0.region?.localizedStandardContains(searchText) == true
                    || $0.nodePool?.localizedStandardContains(searchText) == true
                    || $0.node?.localizedStandardContains(searchText) == true
            } == true
    }

    private func isActive(_ service: NornService) -> Bool {
        guard apps.first(where: { $0.spec.name == service.app })?.spec.deploy != false else { return false }
        return ["passing", "running", "up", "healthy"].contains(service.status.lowercased())
            || service.reachability.routable
    }

    private func isActive(_ app: NornAppStatus) -> Bool {
        guard app.spec.deploy != false else { return false }
        return app.healthy || ["running", "up", "healthy"].contains(app.nomadStatus?.lowercased() ?? "")
    }

    private func serviceOrder(_ left: NornService, _ right: NornService, recency: AppDeploymentRecency) -> Bool {
        if sort == .recent { return recency.precedes(left.app, right.app, ascending: sortAscending, leftTie: left.name, rightTie: right.name) }
        return ordered(serviceSortValue(left), serviceSortValue(right), tie: left.name, right.name)
    }

    private func groupOrder(_ left: AppServiceGroup, _ right: AppServiceGroup, recency: AppDeploymentRecency) -> Bool {
        if sort == .recent { return recency.precedes(left.name, right.name, ascending: sortAscending) }
        return ordered(groupSortValue(left), groupSortValue(right), tie: left.name, right.name)
    }

    private func ordered(_ left: String, _ right: String, tie leftTie: String, _ rightTie: String) -> Bool {
        let result = left.localizedStandardCompare(right)
        if result == .orderedSame {
            let tie = leftTie.localizedStandardCompare(rightTie)
            return sortAscending ? tie == .orderedAscending : tie == .orderedDescending
        }
        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func serviceSortValue(_ service: NornService) -> String {
        switch sort {
        case .recent: return service.app
        case .app: return service.app
        case .process: return service.process
        case .exposure: return service.reachability.exposure
        case .status:
            let state = AppWorkloadState.resolve(service: service, app: appStatus(for: service.app))
            return "\(state.sortRank)-\(state.label)"
        }
    }

    private func groupSortValue(_ group: AppServiceGroup) -> String {
        switch sort {
        case .recent: group.name
        case .app: group.name
        case .process: group.processSummary
        case .exposure: group.exposure
        case .status: "\(group.workloadState.sortRank)-\(group.workloadState.label)"
        }
    }

    private func appStatus(for name: String) -> NornAppStatus? {
        apps.first { $0.spec.name == name }
    }
}

private enum AppListPresentation: String, CaseIterable, Identifiable {
    case grouped
    case flat
    var id: String { rawValue }
}

private enum AppListSort: String {
    case recent
    case app
    case process
    case exposure
    case status
}

private struct AppServiceGroup: Identifiable {
    let name: String
    let app: NornAppStatus?
    let services: [NornService]
    let deployment: NornDeployment?
    let activeOperation: NornOperation?
    var id: String { name }

    var processSummary: String {
        "\(services.count) process\(services.count == 1 ? "" : "es")"
    }

    var workloadSummary: String {
        let jobs = services.filter { ["cron", "function"].contains($0.type.lowercased()) }.count
        let residents = services.count - jobs
        if jobs == 0 { return "\(residents) service\(residents == 1 ? "" : "s")" }
        if residents == 0 { return "\(jobs) job\(jobs == 1 ? "" : "s")" }
        return "\(residents) service\(residents == 1 ? "" : "s") · \(jobs) job\(jobs == 1 ? "" : "s")"
    }

    var exposure: String {
        let exposures = Set(services.map { $0.reachability.exposure.capitalized }).sorted()
        if exposures.isEmpty { return "—" }
        if exposures.count == 1 { return exposures[0] }
        return "Mixed"
    }

    var workloadState: AppWorkloadState {
        AppWorkloadState.aggregate(app: app, services: services)
    }
}

private struct AppListHeader: View {
    let sort: AppListSort
    let ascending: Bool
    let onSort: (AppListSort) -> Void

    var body: some View {
        HStack(spacing: 0) {
            header("App / Service", .app)
                .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            header("Process", .process)
                .frame(width: 90, alignment: .leading)
            header("Exposure", .exposure)
                .frame(width: 72, alignment: .leading)
            header("Status", .status)
                .frame(width: 104, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func header(_ title: String, _ value: AppListSort) -> some View {
        Button { onSort(value) } label: {
            HStack(spacing: 4) {
                Text(title)
                if sort == value {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(sort == value ? .primary : .secondary)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("apps.sort.\(value.rawValue)")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityHint(sort == value ? "Sorted \(ascending ? "ascending" : "descending"); click to reverse" : "Click to sort ascending")
    }
}

private struct AppGroupRow: View {
    let group: AppServiceGroup
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(group.services.isEmpty)
                .help(isExpanded ? "Collapse \(group.name)" : "Expand \(group.name)")
                .accessibilityLabel(isExpanded ? "Collapse \(group.name)" : "Expand \(group.name)")
                .accessibilityIdentifier("apps.disclosure.\(group.name)")
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .accessibilityIdentifier("apps.root.\(group.name)")
                    if let operation = group.activeOperation {
                        Text("\(operation.status.rawValue.capitalized) deployment")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    } else if let deployment = group.deployment {
                        AppDeploymentSummary(deployment: deployment)
                    } else {
                        Text(group.workloadSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Text(group.processSummary)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(group.exposure)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            AppWorkloadBadge(state: group.workloadState)
                .frame(width: 104, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.14) : isHovered ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Inspect \(group.name)", action: onSelect)
            Button(isExpanded ? "Collapse" : "Expand", action: onToggle)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Click to inspect; use the disclosure control to show processes")
    }
}

private struct AppDeploymentSummary: View {
    let deployment: NornDeployment

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: deployment.status.isActive ? "arrow.trianglehead.2.clockwise.rotate.90" : deployment.status == .failed ? "exclamationmark.circle" : "checkmark.circle")
            Text(deployment.status.isActive ? "Last reported \(deployment.status.rawValue)" : deployment.status.rawValue.capitalized)
            Text("·")
            Text(deployment.finishedAt ?? deployment.startedAt, style: .relative)
                .monospacedDigit()
            Text("ago")
        }
        .font(.caption)
        .foregroundStyle(deployment.status.isActive ? Color.accentColor : deployment.status == .failed ? Color.orange : Color.secondary)
        .lineLimit(1)
        .help("Deployment \(deployment.id) · \(deployment.startedAt.formatted())")
    }
}

private struct AppServiceRow: View {
    let service: NornService
    let app: NornAppStatus?
    let isChild: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    private var workloadState: AppWorkloadState {
        AppWorkloadState.resolve(service: service, app: app)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if isChild { Color.clear.frame(width: 24) }
                Circle()
                    .fill(workloadState.semanticStatus.tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: workloadState.semanticStatus.tint.opacity(0.4), radius: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isChild ? service.name : service.app)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(isChild ? allocationSummary : service.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Label(service.process, systemImage: processSymbol(service.type))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            Text(service.reachability.exposure.capitalized)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            Label(workloadState.label, systemImage: workloadState.symbol)
                .foregroundStyle(workloadState.semanticStatus.tint)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(isChild ? 0.08 : 0.14) : isHovered ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu { Button("Inspect \(service.app)", action: onSelect) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(service.app), \(service.process), \(workloadState.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("apps.service.\(service.id)")
    }

    private var allocationSummary: String {
        let count = app?.allocationSummary?.byProcess?[service.process]?.running
            ?? service.instances?.count ?? 0
        if service.type == "worker", workloadState == .active {
            return count > 0 ? "Background worker · \(count) running" : "Background worker"
        }
        if service.type == "cron" { return "Scheduled job" }
        if service.type == "function" { return "On-demand job" }
        return count == 0 ? service.process : "\(count) allocation\(count == 1 ? "" : "s")"
    }

    private func processSymbol(_ type: String) -> String {
        switch type {
        case "cron": "calendar.badge.clock"
        case "worker": "gearshape.2"
        case "function": "function"
        default: "network"
        }
    }
}

enum AppWorkloadState: String, Equatable {
    case healthy
    case active
    case scheduled
    case onDemand
    case scaledToZero
    case disabled
    case attention
    case critical
    case unknown

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .active: "Running"
        case .scheduled: "Scheduled"
        case .onDemand: "On demand"
        case .scaledToZero: "Scaled to zero"
        case .disabled: "Disabled"
        case .attention: "Attention"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .active: "play.circle.fill"
        case .scheduled: "calendar.badge.clock"
        case .onDemand: "play.square"
        case .scaledToZero: "moon.zzz"
        case .disabled: "pause.circle"
        case .attention: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var semanticStatus: NornStatus {
        switch self {
        case .healthy: .healthy
        case .active: .active
        case .attention: .attention
        case .critical: .critical
        case .scheduled, .onDemand, .scaledToZero, .disabled, .unknown: .neutral
        }
    }

    var sortRank: Int {
        switch self {
        case .critical: 0
        case .attention: 1
        case .active: 2
        case .healthy: 3
        case .scheduled, .onDemand: 4
        case .scaledToZero, .disabled: 5
        case .unknown: 6
        }
    }

    static func resolve(service: NornService, app: NornAppStatus?) -> AppWorkloadState {
        if app?.spec.deploy == false { return .disabled }
        if isScaledToZero(service: service, app: app) { return .scaledToZero }

        // A scheduled or on-demand process may have no live Consul
        // registration between runs. Its last reported registration state must
        // not turn that expected absence into a critical workload.
        let hasObservedWork = service.instances?.isEmpty == false
            || (app?.allocationSummary?.byProcess?[service.process]?.active ?? 0) > 0
        if service.isExpectedIdle && !hasObservedWork {
            switch service.expectedState?.lowercased() {
            case "scheduled": return .scheduled
            case "on_demand": return .onDemand
            case "disabled", "paused": return .disabled
            default: break
            }
        }

        let rawStatus = service.status.lowercased()
        if ["critical", "failing", "down", "failed"].contains(rawStatus) { return .critical }
        if ["warning", "pending", "degraded"].contains(rawStatus) { return .attention }
        if ["passing", "ok", "up", "healthy"].contains(rawStatus) { return .healthy }
        if rawStatus == "running" { return .active }

        // Background workers need not register an HTTP service in Consul.
        // Use this process's scheduler evidence without claiming HTTP health
        // or assuming the worker is an on-demand job.
        if service.type.lowercased() == "worker",
           (app?.allocationSummary?.byProcess?[service.process]?.running ?? 0) > 0 {
            return .active
        }

        switch service.type.lowercased() {
        case "cron": return .scheduled
        case "function": return .onDemand
        default: break
        }

        return .unknown
    }

    static func aggregate(app: NornAppStatus?, services: [NornService]) -> AppWorkloadState {
        if app?.spec.deploy == false { return .disabled }

        let states = services.map { resolve(service: $0, app: app) }
        if states.contains(.critical) { return .critical }
        if states.contains(.attention) { return .attention }
        if !states.isEmpty, states.allSatisfy({ $0 == .scaledToZero }) { return .scaledToZero }
        if let app, isAppScaledToZero(app) { return .scaledToZero }

        let schedulerStatus = app?.nomadStatus?.lowercased() ?? ""
        if ["dead", "failed", "lost"].contains(schedulerStatus) { return .critical }
        if ["pending", "starting"].contains(schedulerStatus) { return .attention }

        if states.contains(.unknown) {
            return app?.healthy == false ? .critical : .unknown
        }
        if states.contains(.healthy) { return .healthy }
        if states.contains(.active) { return .active }
        if states.contains(.scaledToZero) { return .scaledToZero }
        if states.contains(.scheduled) { return .scheduled }
        if states.contains(.onDemand) { return .onDemand }

        if app?.healthy == true { return .healthy }
        if allProcesses(in: app, match: { $0.schedule?.isEmpty == false }) { return .scheduled }
        if allProcesses(in: app, match: { $0.function != nil }) { return .onDemand }
        return app?.healthy == false ? .critical : .unknown
    }

    private static func isScaledToZero(service: NornService, app: NornAppStatus?) -> Bool {
        guard let app else { return false }
        guard !["cron", "function"].contains(service.type.lowercased()) else { return false }
        guard service.instances?.isEmpty != false else { return false }
        if let counts = app.allocationSummary?.byProcess?[service.process] {
            return counts.active == 0 && counts.running == 0
                && app.nomadStatus?.lowercased() == "running"
        }
        // An omitted process entry is missing evidence, not a zero count.
        // A zero scaling minimum describes permission to idle, not current state.
        return app.nomadStatus?.lowercased() == "running"
            && app.allocationSummary?.active == 0
            && app.allocationSummary?.running == 0
    }

    private static func isAppScaledToZero(_ app: NornAppStatus) -> Bool {
        if allProcesses(in: app, match: { $0.schedule?.isEmpty == false || $0.function != nil }) { return false }
        return app.nomadStatus?.lowercased() == "running"
            && app.allocationSummary?.active == 0 && app.allocationSummary?.running == 0
    }

    private static func allProcesses(
        in app: NornAppStatus?,
        match predicate: (NornAppSpecSummary.Process) -> Bool
    ) -> Bool {
        guard let processes = app?.spec.processes, !processes.isEmpty else { return false }
        return processes.values.allSatisfy(predicate)
    }
}

private struct AppWorkloadBadge: View {
    let state: AppWorkloadState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.semanticStatus.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(state.semanticStatus.tint.opacity(0.1), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(state.label)")
    }
}

private enum AppRecoveryAuthority {
	static let disabledExplanation = "Requires an authenticated principal with api:write and the durable app recovery capability."
}

private struct AppRecoveryInspector: View {
	let app: NornAppStatus
	let workloadState: AppWorkloadState
	let isSupported: Bool
	let canManage: Bool
    let canScaleRuntime: Bool
    let isScalingRuntime: Bool
    let runtimeFeedback: String?
    let onScaleRuntime: (String, [NornRuntimeScaleTarget], NornMutationContext) async -> Void
	let profileID: UUID?
	let isConnected: Bool
	let onLoadSnapshots: (String) async -> [NornAppSnapshot]?
	let issueMutationContext: () -> NornMutationContext?
	let onQueue: (NornAppOperationRequest, NornMutationContext) async -> NornOperation?
	let onOpenOperation: (NornOperation) -> Void

	@State private var snapshotLoader = AppRecoverySnapshotLoader()
	@State private var keep = 3
	@State private var migrationRef = "HEAD"
	@State private var isQueuing = false
	@State private var confirmation: Confirmation?

	private enum Confirmation: Identifiable {
		case prune
		case restore(NornAppSnapshot)
		case migrate
		case rollback
		var id: String {
			switch self { case .prune: "prune"; case let .restore(snapshot): "restore-\(snapshot.id)"; case .migrate: "migrate"; case .rollback: "rollback" }
		}
	}
	private var recoveryContext: NornProfileAppContext {
		.init(profileID: profileID, appID: app.id, isActive: isConnected && isSupported && hasDatabase)
	}
	private var displayedSnapshots: [NornAppSnapshot] {
		snapshotLoader.loadedContext == recoveryContext ? snapshotLoader.snapshots : []
	}
	private var ordered: [NornAppSnapshot] { displayedSnapshots.sorted { $0.timestamp > $1.timestamp } }
	private var pruneCandidates: [NornAppSnapshot] { Array(ordered.dropFirst(keep)) }
	private var hasDatabase: Bool { app.spec.infrastructure?.postgres != nil }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				header
                AppRuntimeControls(app: app, canManage: canScaleRuntime, isBusy: isScalingRuntime, feedback: runtimeFeedback, issueMutationContext: issueMutationContext) { targets, context in
                    await onScaleRuntime(app.spec.name, targets, context)
                }
                .id("\(profileID?.uuidString ?? "offline")/\(app.id)")
                Divider()
				if !isSupported {
					ContentUnavailableView("Recovery Contract Unavailable", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", description: Text("Upgrade this Norn server to use durable snapshots, migrations, and rollback receipts."))
				} else if !hasDatabase {
					rollbackSection
					ContentUnavailableView("No PostgreSQL Database", systemImage: "externaldrive", description: Text("Snapshot and schema controls appear when the InfraSpec declares PostgreSQL."))
				} else {
					quickActions
					retention
					snapshotList
					rollbackSection
				}
			}
			.padding(18)
		}
		.background(.background.secondary)
		.task(id: recoveryContext) { await reload() }
		.onChange(of: recoveryContext) { _, _ in
			confirmation = nil
		}
		.onChange(of: canManage) { _, hasAuthority in
			if !hasAuthority { confirmation = nil }
		}
		.confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
			Button(confirmationActionTitle, role: .destructive) { executeConfirmation() }
			Button("Cancel", role: .cancel) { confirmation = nil }
		} message: { Text(confirmationMessage) }
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("APP CONTROL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
			HStack { Text(app.spec.name).font(.title2.weight(.semibold)); Spacer(); AppWorkloadBadge(state: workloadState) }
			Text(schedulerSummary).font(.callout).foregroundStyle(.secondary)
		}
	}

	private var schedulerSummary: String {
		if workloadState == .disabled { return "Deployment is disabled" }
		if workloadState == .scaledToZero { return "No active allocations; scheduler job remains available" }
		if workloadState == .scheduled { return "Scheduled workload; idle between runs" }
		if workloadState == .onDemand { return "On-demand workload; idle until invoked" }
		let schedulerStatus = app.nomadStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return schedulerStatus.isEmpty ? "Scheduler status unavailable" : schedulerStatus.capitalized
	}

	private var quickActions: some View {
		GroupBox("Data Safety") {
			VStack(alignment: .leading, spacing: 10) {
				Button("Create Snapshot", systemImage: "camera.fill") { queue(.snapshot(app: app.id)) }.disabled(isQueuing || !canManage).help(canManage ? "Queue a durable snapshot" : AppRecoveryAuthority.disabledExplanation).accessibilityHint(canManage ? "Queues a durable snapshot" : AppRecoveryAuthority.disabledExplanation)
				if app.spec.migrations?.isEmpty == false {
					TextField("Migration ref", text: $migrationRef).textFieldStyle(.roundedBorder)
					Button("Review Schema Migration…", systemImage: "cylinder.split.1x2") { confirmation = .migrate }.disabled(!canManage || isQueuing || migrationRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help(canManage ? "Review the migration before it is queued" : AppRecoveryAuthority.disabledExplanation).accessibilityHint(canManage ? "Shows migration impact before it is queued" : AppRecoveryAuthority.disabledExplanation)
				}
				Text("Norn creates a safety snapshot before restore or migration and serializes changes across control-plane replicas.").font(.caption).foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
		}
	}

	private var retention: some View {
		GroupBox("Retention Preview") {
			VStack(alignment: .leading, spacing: 10) {
				Stepper("Keep newest \(keep)", value: $keep, in: 1...1000)
				Label(pruneCandidates.isEmpty ? "Nothing will be pruned" : "\(pruneCandidates.count) snapshot\(pruneCandidates.count == 1 ? "" : "s") will be pruned", systemImage: pruneCandidates.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
						.font(.caption).foregroundStyle(pruneCandidates.isEmpty ? Color.secondary : Color.orange)
				Button("Review Prune…", systemImage: "trash", role: .destructive) { confirmation = .prune }.disabled(!canManage || pruneCandidates.isEmpty || isQueuing).help(canManage ? "Review the snapshots that will be pruned" : AppRecoveryAuthority.disabledExplanation).accessibilityHint(canManage ? "Shows prune impact before it is queued" : AppRecoveryAuthority.disabledExplanation)
			}
			.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
		}
	}

	@ViewBuilder private var snapshotList: some View {
		GroupBox("Local Snapshots") {
			if snapshotLoader.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
			else if ordered.isEmpty { ContentUnavailableView("No Snapshots", systemImage: "camera", description: Text("Create a baseline before risky changes.")).padding(.vertical, 12) }
			else {
				VStack(spacing: 0) {
					ForEach(Array(ordered.enumerated()), id: \.element.id) { index, snapshot in
						HStack {
							Image(systemName: index >= keep ? "trash.circle" : "checkmark.circle.fill").foregroundStyle(index >= keep ? .orange : .green)
							VStack(alignment: .leading) { Text(snapshot.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.timestamp).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
							Spacer(); Button("Restore", systemImage: "arrow.uturn.backward") { confirmation = .restore(snapshot) }.disabled(!canManage).labelStyle(.iconOnly).buttonStyle(.borderless).help(canManage ? "Restore this snapshot" : AppRecoveryAuthority.disabledExplanation)
						}.padding(.vertical, 8)
						if index < ordered.count - 1 { Divider() }
					}
				}
			}
		}
	}

	private var rollbackSection: some View {
		GroupBox("Application Recovery") {
			VStack(alignment: .leading, spacing: 8) {
				Button("Review Rollback…", systemImage: "arrow.uturn.backward", role: .destructive) { confirmation = .rollback }.disabled(!canManage || !isSupported || isQueuing || app.spec.deploy == false).help(canManage ? "Review the application rollback before it is queued" : AppRecoveryAuthority.disabledExplanation).accessibilityHint(canManage ? "Shows rollback impact before it is queued" : AppRecoveryAuthority.disabledExplanation)
				Text("Rolls every declared region back to the previous successful image and waits for readiness before promotion.").font(.caption).foregroundStyle(.secondary)
			}.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
		}
	}

	private func reload() async {
		keep = max(1, app.spec.snapshots?.keep ?? 3)
		await snapshotLoader.reload(for: recoveryContext, operation: onLoadSnapshots)
	}
	private func queue(_ request: NornAppOperationRequest) {
		guard !isQueuing, let context = issueMutationContext() else { return }; isQueuing = true
		Task { if let operation = await onQueue(request, context) { onOpenOperation(operation) }; isQueuing = false }
	}
	private func executeConfirmation() {
		guard canManage, isSupported, let confirmation else { self.confirmation = nil; return }; self.confirmation = nil
		switch confirmation {
		case .prune: queue(.pruneSnapshots(app: app.id, keep: keep))
		case let .restore(snapshot): queue(.restoreSnapshot(app: app.id, snapshot: snapshot.filename))
		case .migrate: queue(.migrate(app: app.id, ref: migrationRef.trimmingCharacters(in: .whitespacesAndNewlines)))
		case .rollback: queue(.rollback(app: app.id, regions: []))
		}
	}
	private var confirmationTitle: String { switch confirmation { case .prune: "Prune snapshots?"; case .restore: "Restore database?"; case .migrate: "Run schema migration?"; case .rollback: "Rollback application?"; case nil: "Confirm operation" } }
	private var confirmationActionTitle: String { switch confirmation { case .prune: "Queue Prune"; case .restore: "Queue Restore"; case .migrate: "Queue Migration"; case .rollback: "Queue Rollback"; case nil: "Confirm" } }
	private var confirmationMessage: String { switch confirmation { case .prune: "Keep the newest \(keep) and prune \(pruneCandidates.count) local snapshots. The exact candidates are marked in the list."; case .restore: "Norn creates a pre-restore safety snapshot before changing the database."; case .migrate: "Run the declared migration from \(migrationRef). Norn snapshots first and does not automatically replay an interrupted schema mutation."; case .rollback: "Roll every declared region back to the previous successful deployment after readiness checks."; case nil: "" } }
}

#Preview {
    AppsView(
		services: NornFixtures.snapshot.services,
		selectedAppName: .constant(nil),
		selectedService: .constant(nil)
	)
        .frame(width: 900, height: 560)
}
