import Foundation
import SwiftUI

struct CreateAppSheet: View {
	@Environment(\.dismiss) private var dismiss
	let profileID: UUID?
	let canCreate: Bool
	@State private var name = ""
	@State private var kind: NornAppTemplateKind = .endpoint
	@State private var port = 8080
	@State private var isCreating = false
	@State private var errorMessage: String?
	@State private var mutationGate = NornProfileBoundMutationGate<NornCreateAppRequest>()
	let onCreate: (NornCreateAppRequest) async -> Bool

	private var normalizedName: String { name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }
	private var isValid: Bool { normalizedName.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil && (kind == .worker || (1...65535).contains(port)) }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 5) {
				Text("Create App").font(.title2.weight(.semibold))
				Text("Norn creates a safe InfraSpec draft with deployment disabled.").foregroundStyle(.secondary)
			}
			Form {
				TextField("Name", text: $name, prompt: Text("orders-api"))
					.onChange(of: name) { _, value in if value != normalizedName { name = normalizedName } }
				Picker("Template", selection: $kind) {
					Label("Endpoint", systemImage: "network").tag(NornAppTemplateKind.endpoint)
					Label("Worker", systemImage: "gearshape.2").tag(NornAppTemplateKind.worker)
				}
				.pickerStyle(.segmented)
				if kind == .endpoint { TextField("Container port", value: $port, format: .number) }
				LabeledContent("Deployment") { Label("Off", systemImage: "lock.shield").foregroundStyle(.secondary) }
			}
			if let errorMessage { Text(errorMessage).foregroundStyle(.red).accessibilityLabel("Error: \(errorMessage)") }
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("Create Draft") { create() }
					.keyboardShortcut(.defaultAction)
					.disabled(!isValid || isCreating || !canCreate)
					.help(canCreate ? "Create a disabled app draft" : "Requires authenticated api:write and the app-creation capability")
			}
		}
		.padding(20)
		.frame(width: 480)
		.interactiveDismissDisabled(isCreating)
		.onChange(of: profileID) { _, _ in
			mutationGate.invalidate()
			if !isCreating { dismiss() }
		}
		.onChange(of: canCreate) { _, _ in
			mutationGate.invalidate()
			if !isCreating { dismiss() }
		}
	}

	private func create() {
		let requested = NornCreateAppRequest(name: normalizedName, kind: kind, port: kind == .endpoint ? port : nil)
		mutationGate.present(requested, profileID: profileID, isAuthorized: canCreate)
		isCreating = true
		errorMessage = nil
		Task {
			guard let request = mutationGate.confirmedIntent(profileID: profileID, isAuthorized: canCreate, isStillCurrent: { $0 == requested }) else {
				isCreating = false
				return
			}
			if await onCreate(request) { dismiss() } else { errorMessage = "The app could not be created. Review the server message and try again." }
			isCreating = false
		}
	}
}
