import SwiftUI

/// Logs and traces for one app, presented from the Host service actions.
struct AppObservabilityView: View {
    enum Section: String, CaseIterable, Identifiable {
        case logs = "Logs"
        case traces = "Traces"
        var id: String { rawValue }
    }

    let service: NornService
    let loadCompatibilityLogs: (NornService) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var section = Section.logs
    @State private var openTraceID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(service.app)
                    .font(.headline)
                Spacer()
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            switch section {
            case .logs:
                AppLogsView(service: service, loadCompatibilityLogs: loadCompatibilityLogs) { traceID in
                    openTraceID = traceID
                    section = .traces
                }
            case .traces:
                AppTracesView(app: service.app, openTraceID: $openTraceID)
            }
        }
        .frame(minWidth: 900, idealWidth: 1_040, minHeight: 520, idealHeight: 660)
    }
}

/// Empty state for a failed logs or traces request, naming the setting that fixes it.
struct NornObservabilityIssueView: View {
    let issue: NornObservabilityIssue
    let noun: String
    var retry: (() -> Void)?

    var body: some View {
        NornStateView(state: state, retry: retry)
    }

    private var state: NornLoadState {
        switch issue {
        case .unsupported:
            .empty(title: "\(noun) need a newer Norn", message: "This server does not offer the \(noun.lowercased()) API yet.", symbol: "arrow.up.circle")
        case let .notConfigured(variable):
            .empty(title: "\(noun) are not configured", message: "Set \(variable) on the Norn API to enable them.", symbol: "gearshape")
        case .forbidden:
            .empty(title: "Not allowed", message: "This credential cannot read \(noun.lowercased()) for this app.", symbol: "lock")
        case .notFound:
            .empty(title: "Trace not found", message: "It may have expired from the trace backend.", symbol: "magnifyingglass")
        case let .failed(message):
            .error(title: "\(noun) could not be loaded", message: message)
        }
    }
}
