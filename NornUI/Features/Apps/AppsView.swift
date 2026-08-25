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
	@State private var pendingEnable: NornAppStatus?
    @State private var selection: NornService.ID?
    @State private var searchText = ""

    private var filteredServices: [NornService] {
        guard !searchText.isEmpty else { return services }
        return services.filter {
            $0.app.localizedStandardContains(searchText)
                || $0.process.localizedStandardContains(searchText)
                || $0.name.localizedStandardContains(searchText)
        }
    }

    var body: some View {
		HSplitView {
		VStack(spacing: 0) {
			if !drafts.isEmpty {
				HStack(spacing: 10) {
					Label("Drafts", systemImage: "lock.shield")
					ForEach(drafts) { app in
						HStack(spacing: 5) {
							Text(app.spec.name).font(.callout.weight(.medium))
							Button("Enable") { pendingEnable = app }.buttonStyle(.link)
						}
						.padding(.horizontal, 9).padding(.vertical, 5).background(.quaternary, in: Capsule())
					}
					Spacer()
					Text("Deployment off").foregroundStyle(.secondary)
				}
				.padding(12)
				Divider()
			}
        Table(filteredServices, selection: $selection) {
            TableColumn("Service") { service in
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor(service.status))
                        .frame(width: 7, height: 7)
                        .shadow(color: statusColor(service.status).opacity(0.45), radius: 3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.app)
                            .fontWeight(.medium)
                        Text(service.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(service.app), \(service.status)")
            }
            .width(min: 190, ideal: 260)

            TableColumn("Process") { service in
                Label(service.process, systemImage: processSymbol(service.type))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Exposure") { service in
                Text(service.reachability.exposure.capitalized)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Status") { service in
                Text(service.status.capitalized)
                    .foregroundStyle(statusColor(service.status))
            }
            .width(min: 80, ideal: 100)
        }
		}
		.frame(minWidth: 430)
		if let selectedApp {
			AppRecoveryInspector(
				app: selectedApp,
				isSupported: supportsRecovery,
				onLoadSnapshots: onLoadSnapshots,
				onQueue: onQueueOperation,
				onOpenOperation: onOpenOperation
			)
			.frame(minWidth: 330, idealWidth: 390, maxWidth: 480)
		} else {
			ContentUnavailableView("Select an App", systemImage: "square.stack.3d.up", description: Text("Choose a service to inspect durable recovery controls."))
				.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
		}
		}
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search apps and services")
        .navigationTitle("Apps")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button(action: onCreate) { Label("Create App", systemImage: "plus") }
					.disabled(!canCreate)
					.help(canCreate ? "Create a disabled app draft" : "This server does not support app creation")
			}
		}
        .overlay {
            if filteredServices.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
		.task {
			if selection == nil { selection = filteredServices.first?.id }
		}
		.confirmationDialog("Enable deployment for \(pendingEnable?.spec.name ?? "this app")?", isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } })) {
			Button("Enable Deployment") { if let app = pendingEnable { onEnable(app.spec.name) }; pendingEnable = nil }
			Button("Cancel", role: .cancel) { pendingEnable = nil }
		} message: { Text("The app will become eligible for deploy and host-recovery workflows. Verify its source, build, secrets, and health checks first.") }
    }

	private var drafts: [NornAppStatus] { apps.filter { $0.spec.deploy == false }.sorted { $0.spec.name < $1.spec.name } }
	private var selectedApp: NornAppStatus? {
		guard let selection, let service = services.first(where: { $0.id == selection }) else { return apps.first }
		return apps.first(where: { $0.spec.name == service.app })
	}

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "passing", "running", "up": .green
        case "warning", "pending": .orange
        case "critical", "failed", "down": .red
        default: .secondary
        }
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
		case let .restore(snapshot): queue(.restoreSnapshot(app: app.id, timestamp: snapshot.timestamp))
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
