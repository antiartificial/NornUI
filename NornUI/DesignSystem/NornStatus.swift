import SwiftUI

/// The small, consistent vocabulary used whenever Norn communicates operational state.
enum NornStatus: String, CaseIterable, Sendable {
    case healthy
    case active
    case attention
    case critical
    case neutral
    case offline

    init(serviceStatus: String) {
        switch serviceStatus.lowercased() {
        case "passing", "ok", "up", "healthy": self = .healthy
        case "warning", "degraded", "unknown": self = .attention
        case "critical", "failing", "down", "failed": self = .critical
        default: self = .neutral
        }
    }

    init(operationStatus: NornOperationStatus) {
        switch operationStatus {
        case .queued, .running: self = .active
        case .succeeded: self = .healthy
        case .failed, .canceled: self = .critical
        }
    }

    var title: String {
        switch self {
        case .healthy: "Healthy"
        case .active: "Active"
        case .attention: "Needs attention"
        case .critical: "Action needed"
        case .neutral: "Unknown"
        case .offline: "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .active: "arrow.triangle.2.circlepath.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .neutral: "circle.dashed"
        case .offline: "wifi.slash"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .active: .accentColor
        case .attention: .orange
        case .critical: .red
        case .neutral: .secondary
        case .offline: .secondary
        }
    }

    var accessibilityDescription: String { title }
}

struct NornStatusGlyph: View {
    let status: NornStatus
    var size: CGFloat = 18
    var pulsesWhenActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if pulsesWhenActive && !reduceMotion && (status == .active || status == .attention || status == .critical) {
                Circle()
                    .fill(status.tint.opacity(0.16))
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 1.85 : 1)
                    .opacity(isPulsing ? 0 : 0.75)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }
                    .onDisappear { isPulsing = false }
            }

            Image(systemName: status.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(status.tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .accessibilityElement()
        .accessibilityLabel(status.accessibilityDescription)
    }
}

struct NornStatusBadge: View {
    let status: NornStatus
    var label: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            NornStatusGlyph(status: status, size: 10, pulsesWhenActive: false)
            Text(label ?? status.title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(status.tint.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Status language") {
    HStack {
        ForEach(NornStatus.allCases, id: \.self) { status in
            NornStatusBadge(status: status)
        }
    }
    .padding()
}
