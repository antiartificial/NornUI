import SwiftUI

struct AppsView: View {
	var apps: [NornAppStatus] = []
    let services: [NornService]
	var canCreate = false
	var onCreate: () -> Void = {}
	var onEnable: (String) -> Void = { _ in }
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
		.confirmationDialog("Enable deployment for \(pendingEnable?.spec.name ?? "this app")?", isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } })) {
			Button("Enable Deployment") { if let app = pendingEnable { onEnable(app.spec.name) }; pendingEnable = nil }
			Button("Cancel", role: .cancel) { pendingEnable = nil }
		} message: { Text("The app will become eligible for deploy and host-recovery workflows. Verify its source, build, secrets, and health checks first.") }
    }

	private var drafts: [NornAppStatus] { apps.filter { $0.spec.deploy == false }.sorted { $0.spec.name < $1.spec.name } }

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

#Preview {
    AppsView(services: NornFixtures.snapshot.services)
        .frame(width: 900, height: 560)
}
