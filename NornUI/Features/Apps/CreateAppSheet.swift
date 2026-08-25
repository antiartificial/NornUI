import SwiftUI

struct CreateAppSheet: View {
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var kind: NornAppTemplateKind = .endpoint
	@State private var port = 8080
	@State private var isCreating = false
	@State private var errorMessage: String?
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
				Button("Create Draft") { create() }.keyboardShortcut(.defaultAction).disabled(!isValid || isCreating)
			}
		}
		.padding(20)
		.frame(width: 480)
		.interactiveDismissDisabled(isCreating)
	}

	private func create() {
		isCreating = true
		errorMessage = nil
		Task {
			let request = NornCreateAppRequest(name: normalizedName, kind: kind, port: kind == .endpoint ? port : nil)
			if await onCreate(request) { dismiss() } else { errorMessage = "The app could not be created. Review the server message and try again." }
			isCreating = false
		}
	}
}
