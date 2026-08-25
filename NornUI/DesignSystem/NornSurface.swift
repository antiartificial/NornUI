import SwiftUI

struct NornSurfaceCard<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> some View,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || subtitle != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let title {
                            Text(title)
                                .font(.headline)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(18)
        .background {
            surfaceBackground
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(isHovered ? 0.13 : 0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 12 : 7, y: isHovered ? 5 : 2)
        .scaleEffect(isHovered ? 1.006 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var surfaceBackground: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}

struct NornMetric: View {
    let value: Int
    let label: String
    var status: NornStatus = .neutral
    var detail: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value, format: .number)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .contentTransition(reduceMotion ? .identity : .numericText())
                NornStatusGlyph(status: status, size: 14, pulsesWhenActive: false)
            }
            Text(label)
                .font(.subheadline.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.38), value: appeared)
        .onAppear { appeared = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)\(detail.map { ", \($0)" } ?? "")")
    }
}

struct NornSectionAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.right")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .font(.subheadline.weight(.medium))
        .accessibilityHint("Shows \(title.lowercased())")
    }
}

#Preview("Surface") {
    NornSurfaceCard(title: "Platform pulse", subtitle: "Updated just now") {
        HStack(spacing: 32) {
            NornMetric(value: 6, label: "services", status: .healthy)
            NornMetric(value: 0, label: "active operations", status: .neutral)
        }
    }
    .padding()
    .frame(width: 500)
}
