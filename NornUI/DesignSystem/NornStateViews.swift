import SwiftUI

enum NornLoadState: Equatable {
    case loading
    case empty(title: String, message: String, symbol: String)
    case error(title: String, message: String)
}

struct NornStateView: View {
    let state: NornLoadState
    var retry: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                stateIcon
                    .font(.title2.weight(.medium))
                    .foregroundStyle(stateTint)
            }

            VStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel("Loading")
        case let .empty(_, _, symbol):
            Image(systemName: symbol)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var title: String {
        switch state {
        case .loading: "Connecting to Norn"
        case let .empty(title, _, _), let .error(title, _): title
        }
    }

    private var message: String {
        switch state {
        case .loading: "Establishing an authoritative view of your platform."
        case let .empty(_, message, _), let .error(_, message): message
        }
    }

    private var stateTint: Color {
        if case .error = state { return .orange }
        return .accentColor
    }
}

#Preview("Offline") {
    NornStateView(
        state: .error(
            title: "Norn is unavailable",
            message: "Your last known platform state will appear when a connection is restored."
        ),
        retry: {}
    )
    .frame(width: 540, height: 380)
}
