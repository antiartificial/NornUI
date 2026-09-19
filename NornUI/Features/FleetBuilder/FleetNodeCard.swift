import SwiftUI

/// Visual styling for each node kind — SF Symbol + tint, matching the app's semantic-color idiom.
nonisolated enum FleetNodeStyle {
    static func symbol(_ kind: FleetNodeKind) -> String {
        switch kind {
        case .control: "cpu"
        case .app: "square.grid.2x2.fill"
        case .dbPrimary: "cylinder.fill"
        case .dbReplica: "cylinder.split.1x2.fill"
        case .dbExtra: "testtube.2"
        case .cache: "bolt.fill"
        case .queue: "tray.2.fill"
        case .lb: "arrow.triangle.branch"
        case .edgeCloudflare: "cloud.fill"
        case .edgeDNS: "globe"
        case .spaces: "archivebox.fill"
        }
    }

    static func tint(_ kind: FleetNodeKind) -> Color {
        switch kind {
        case .control: .accentColor
        case .app: .blue
        case .dbPrimary, .dbReplica, .dbExtra: .purple
        case .cache: .teal
        case .queue: .indigo
        case .lb: .secondary
        case .edgeCloudflare: .orange
        case .edgeDNS: .secondary
        case .spaces: .secondary
        }
    }
}

/// A single draggable/selectable node card on the fleet canvas.
struct FleetNodeCard: View {
    let node: FleetGraphNode
    let selected: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tint: Color { FleetNodeStyle.tint(node.kind) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: FleetNodeStyle.symbol(node.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(node.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let badge = node.badge {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                }
                if let meta = node.meta {
                    Text(meta)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(width: node.size.width, height: node.size.height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected || node.invalid ? 2 : 1)
        }
        .shadow(color: .black.opacity(selected ? 0.16 : 0.08), radius: selected ? 8 : 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title)\(node.meta.map { ", \($0)" } ?? "")\(node.invalid ? ", has a blocking issue" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var borderColor: Color {
        if node.invalid { return .red }
        if selected { return .accentColor }
        return .primary.opacity(0.10)
    }
}
