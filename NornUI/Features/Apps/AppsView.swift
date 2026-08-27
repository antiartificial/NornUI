import SwiftUI

struct AppsView: View {
    var apps: [NornAppStatus] = []
    let services: [NornService]
    var canCreate = false
    var supportsRecovery = false
    var onCreate: () -> Void = {}
    var onEnable: (String) -> Void = { _ in }
    var onLoadSnapshots: (String) async -> [NornAppSnapshot]? = { _ in nil }
    var onQueueOperation: (NornAppOperationRequest) async -> NornOperation? = { _ in nil }
    var onOpenOperation: (NornOperation) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingEnable: NornAppStatus?
    @State private var selectedAppName: String?
    @State private var searchText = ""
    @State private var presentation: AppListPresentation = .grouped
    @State private var activeOnly = false
    @State private var sort = AppListSort.app
    @State private var sortAscending = true
    @State private var expandedApps: Set<String> = []

    private var filteredServices: [NornService] {
        services
            .filter { !activeOnly || isActive($0) }
            .filter { searchText.isEmpty || matchesSearch($0) }
            .sorted(by: serviceOrder)
    }

    private var groupedApps: [AppServiceGroup] {
        let appStatuses = apps.reduce(into: [String: NornAppStatus]()) { result, app in
            result[app.spec.name] = app
        }
        let activeServices = services.filter { !activeOnly || isActive($0) }
        var names = Set(activeServices.map(\.app))
        names.formUnion(apps.compactMap { app in
            guard app.spec.deploy != false else { return nil }
            guard !activeOnly || isActive(app) else { return nil }
            return app.spec.name
        })

        return names.compactMap { name in
            let app = appStatuses[name]
            let allChildren = activeServices.filter { $0.app == name }
            let appMatches = searchText.isEmpty
                || name.localizedStandardContains(searchText)
                || app?.nomadStatus?.localizedStandardContains(searchText) == true
            let children = appMatches ? allChildren : allChildren.filter(matchesSearch)
            guard searchText.isEmpty || appMatches || !children.isEmpty else { return nil }
            return AppServiceGroup(name: name, app: app, services: children.sorted(by: serviceOrder))
        }
        .sorted(by: groupOrder)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                draftStrip
                appList
            }
            .frame(minWidth: 410)

            if let selectedApp {
                AppRecoveryInspector(
                    app: selectedApp,
                    isSupported: supportsRecovery,
                    onLoadSnapshots: onLoadSnapshots,
                    onQueue: onQueueOperation,
                    onOpenOperation: onOpenOperation
                )
                .frame(minWidth: 290, idealWidth: 370, maxWidth: 480)
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
                .help(canCreate ? "Create a disabled app draft" : "This server does not support app creation")
            }
        }
        .task { normalizeSelection() }
        .onChange(of: visibleAppNames) { _, _ in normalizeSelection() }
        .confirmationDialog(
            "Enable deployment for \(pendingEnable?.spec.name ?? "this app")?",
            isPresented: Binding(
                get: { pendingEnable != nil },
                set: { if !$0 { pendingEnable = nil } }
            )
        ) {
            Button("Enable Deployment") {
                if let app = pendingEnable { onEnable(app.spec.name) }
                pendingEnable = nil
            }
            Button("Cancel", role: .cancel) { pendingEnable = nil }
        } message: {
            Text("The app will become eligible for deploy and host-recovery workflows. Verify its source, build, secrets, and health checks first.")
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
                                Button("Enable") { pendingEnable = app }
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
                                    isSelected: selectedAppName == group.name,
                                    onToggle: { toggleExpansion(group.name) },
                                    onSelect: { selectedAppName = group.name }
                                )
                                if expandedApps.contains(group.id) {
                                    ForEach(group.services) { service in
                                        AppServiceRow(
                                            service: service,
                                            isChild: true,
                                            isSelected: selectedAppName == service.app,
                                            onSelect: { selectedAppName = service.app }
                                        )
                                    }
                                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                                }
                                Divider()
                            }
                        } else {
                            ForEach(filteredServices) { service in
                                AppServiceRow(
                                    service: service,
                                    isChild: false,
                                    isSelected: selectedAppName == service.app,
                                    onSelect: { selectedAppName = service.app }
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
        case .flat: Array(Set(filteredServices.map(\.app))).sorted()
        }
    }

    private var selectedApp: NornAppStatus? {
        guard let name = selectedAppName ?? visibleAppNames.first else { return nil }
        return apps.first { $0.spec.name == name }
    }

    private func normalizeSelection() {
        if let selectedAppName, visibleAppNames.contains(selectedAppName) { return }
        selectedAppName = visibleAppNames.first
    }

    private func toggleExpansion(_ app: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if expandedApps.contains(app) { expandedApps.remove(app) }
            else { expandedApps.insert(app) }
        }
    }

    private func applySort(_ next: AppListSort) {
        if sort == next { sortAscending.toggle() }
        else { sort = next; sortAscending = true }
    }

    private func matchesSearch(_ service: NornService) -> Bool {
        service.app.localizedStandardContains(searchText)
            || service.process.localizedStandardContains(searchText)
            || service.name.localizedStandardContains(searchText)
            || service.status.localizedStandardContains(searchText)
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

    private func serviceOrder(_ left: NornService, _ right: NornService) -> Bool {
        ordered(serviceSortValue(left), serviceSortValue(right), tie: left.name, right.name)
    }

    private func groupOrder(_ left: AppServiceGroup, _ right: AppServiceGroup) -> Bool {
        ordered(groupSortValue(left), groupSortValue(right), tie: left.name, right.name)
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
        case .app: service.app
        case .process: service.process
        case .exposure: service.reachability.exposure
        case .status: "\(statusRank(service.status))-\(service.status)"
        }
    }

    private func groupSortValue(_ group: AppServiceGroup) -> String {
        switch sort {
        case .app: group.name
        case .process: group.processSummary
        case .exposure: group.exposure
        case .status: "\(statusRank(group.status))-\(group.status)"
        }
    }

    private func statusRank(_ status: String) -> Int {
        switch NornStatus(serviceStatus: status) {
        case .critical: 0
        case .attention: 1
        case .active: 2
        case .healthy: 3
        case .neutral, .offline: 4
        }
    }
}

private enum AppListPresentation: String, CaseIterable, Identifiable {
    case grouped
    case flat
    var id: String { rawValue }
}

private enum AppListSort: String {
    case app
    case process
    case exposure
    case status
}

private struct AppServiceGroup: Identifiable {
    let name: String
    let app: NornAppStatus?
    let services: [NornService]
    var id: String { name }

    var processSummary: String {
        "\(services.count) process\(services.count == 1 ? "" : "es")"
    }

    var exposure: String {
        let exposures = Set(services.map { $0.reachability.exposure.capitalized }).sorted()
        if exposures.isEmpty { return "—" }
        if exposures.count == 1 { return exposures[0] }
        return "Mixed"
    }

    var status: String {
        if app?.healthy == false { return "critical" }
        let states = services.map { $0.status.lowercased() }
        if states.isEmpty {
            if app?.healthy == true { return "passing" }
            return app?.nomadStatus ?? "unknown"
        }
        if states.allSatisfy({ ["passing", "running", "up", "healthy"].contains($0) }) { return "passing" }
        if states.contains(where: { ["critical", "failed", "down"].contains($0) }) { return "critical" }
        if states.contains(where: { ["warning", "pending", "degraded"].contains($0) }) { return "warning" }
        return "unknown"
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
                .frame(width: 90, alignment: .leading)
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
                    Text("\(group.services.count) service\(group.services.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Text(group.processSummary)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(group.exposure)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            NornStatusBadge(status: NornStatus(serviceStatus: group.status), label: group.status.capitalized)
                .frame(width: 90, alignment: .leading)
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

private struct AppServiceRow: View {
    let service: NornService
    let isChild: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if isChild { Color.clear.frame(width: 24) }
                Circle()
                    .fill(NornStatus(serviceStatus: service.status).tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: NornStatus(serviceStatus: service.status).tint.opacity(0.4), radius: 3)
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
            Text(service.status.capitalized)
                .foregroundStyle(NornStatus(serviceStatus: service.status).tint)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(isChild ? 0.08 : 0.14) : isHovered ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu { Button("Inspect \(service.app)", action: onSelect) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(service.app), \(service.process), \(service.status)")
        .accessibilityIdentifier("apps.service.\(service.id)")
    }

    private var allocationSummary: String {
        let count = service.instances?.count ?? 0
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

private struct AppRecoveryInspector: View {
	let app: NornAppStatus
	let isSupported: Bool
	let onLoadSnapshots: (String) async -> [NornAppSnapshot]?
	let onQueue: (NornAppOperationRequest) async -> NornOperation?
	let onOpenOperation: (NornOperation) -> Void

	@State private var snapshots: [NornAppSnapshot] = []
	@State private var keep = 3
	@State private var migrationRef = "HEAD"
	@State private var isLoading = false
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
	private var ordered: [NornAppSnapshot] { snapshots.sorted { $0.timestamp > $1.timestamp } }
	private var pruneCandidates: [NornAppSnapshot] { Array(ordered.dropFirst(keep)) }
	private var hasDatabase: Bool { app.spec.infrastructure?.postgres != nil }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				header
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
		.task(id: app.id) { await reload() }
		.confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
			Button(confirmationActionTitle, role: .destructive) { executeConfirmation() }
			Button("Cancel", role: .cancel) { confirmation = nil }
		} message: { Text(confirmationMessage) }
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("APP CONTROL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
			HStack { Text(app.spec.name).font(.title2.weight(.semibold)); Spacer(); NornStatusBadge(status: app.healthy ? .healthy : .critical) }
			Text(app.nomadStatus ?? "Unknown scheduler status").font(.callout).foregroundStyle(.secondary)
		}
	}

	private var quickActions: some View {
		GroupBox("Data Safety") {
			VStack(alignment: .leading, spacing: 10) {
				Button("Create Snapshot", systemImage: "camera.fill") { queue(.snapshot(app: app.id)) }.disabled(isQueuing)
				if app.spec.migrations?.isEmpty == false {
					TextField("Migration ref", text: $migrationRef).textFieldStyle(.roundedBorder)
					Button("Review Schema Migration…", systemImage: "cylinder.split.1x2") { confirmation = .migrate }.disabled(isQueuing || migrationRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
				Button("Review Prune…", systemImage: "trash", role: .destructive) { confirmation = .prune }.disabled(pruneCandidates.isEmpty || isQueuing)
			}
			.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
		}
	}

	@ViewBuilder private var snapshotList: some View {
		GroupBox("Local Snapshots") {
			if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
			else if ordered.isEmpty { ContentUnavailableView("No Snapshots", systemImage: "camera", description: Text("Create a baseline before risky changes.")).padding(.vertical, 12) }
			else {
				VStack(spacing: 0) {
					ForEach(Array(ordered.enumerated()), id: \.element.id) { index, snapshot in
						HStack {
							Image(systemName: index >= keep ? "trash.circle" : "checkmark.circle.fill").foregroundStyle(index >= keep ? .orange : .green)
							VStack(alignment: .leading) { Text(snapshot.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.timestamp).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
							Spacer(); Button("Restore", systemImage: "arrow.uturn.backward") { confirmation = .restore(snapshot) }.labelStyle(.iconOnly).buttonStyle(.borderless).help("Restore this snapshot")
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
				Button("Review Rollback…", systemImage: "arrow.uturn.backward", role: .destructive) { confirmation = .rollback }.disabled(!isSupported || isQueuing || app.spec.deploy == false)
				Text("Rolls every declared region back to the previous successful image and waits for readiness before promotion.").font(.caption).foregroundStyle(.secondary)
			}.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
		}
	}

	private func reload() async {
		keep = max(1, app.spec.snapshots?.keep ?? 3)
		guard isSupported, hasDatabase else { snapshots = []; return }
		isLoading = true; defer { isLoading = false }
		if let result = await onLoadSnapshots(app.id) { snapshots = result }
	}
	private func queue(_ request: NornAppOperationRequest) {
		guard !isQueuing else { return }; isQueuing = true
		Task { if let operation = await onQueue(request) { onOpenOperation(operation) }; isQueuing = false }
	}
	private func executeConfirmation() {
		guard let confirmation else { return }; self.confirmation = nil
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
    AppsView(services: NornFixtures.snapshot.services)
        .frame(width: 900, height: 560)
}
