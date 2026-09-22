import SwiftUI

/// The free-drag fleet canvas: a dot grid + bezier connectors drawn with `Canvas`, and
/// node cards positioned by offset with drag-to-move and tap-to-select.
struct FleetBuilderCanvas: View {
    let model: FleetBuilderModel

    @State private var dragStart: [String: CGPoint] = [:]
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat?
    private let viewportInset: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let graph = model.graph
        let frames = regionFrames(graph)
        let bounds = contentBounds(graph, frames: frames)
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(frames) { frame in
                        regionFrameView(frame)
                            .offset(x: frame.rect.minX, y: frame.rect.minY)
                    }

                    connectors(graph)
                        .frame(width: bounds.maxX, height: bounds.maxY)
                        .allowsHitTesting(false)

                    ForEach(graph.nodes) { node in
                        FleetNodeCard(node: node, selected: node.id == model.selectedNodeID)
                            .offset(x: node.position.x, y: node.position.y)
                            .highPriorityGesture(dragGesture(node))
                            .onTapGesture { model.select(node.id) }
                    }
                }
                .offset(x: -bounds.minX, y: -bounds.minY)
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: bounds.width * zoom, height: bounds.height * zoom, alignment: .topLeading)
                .padding(viewportInset)
                .padding(.bottom, 48)
            }
            .background {
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearSelection() }
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if gestureZoom == nil { gestureZoom = zoom }
                    zoom = Self.clampedZoom((gestureZoom ?? zoom) * value.magnification)
                }
                .onEnded { _ in gestureZoom = nil })
            .overlay(alignment: .topTrailing) { zoomControls(viewport: viewport.size, content: bounds.size) }
            .overlay(alignment: .bottom) { legend(graph) }
            .clipped()
        }
        .accessibilityLabel("Fleet topology canvas")
    }

    private static func clampedZoom(_ value: CGFloat) -> CGFloat { min(2, max(0.25, value)) }

    private func setZoom(_ value: CGFloat) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            zoom = Self.clampedZoom(value)
        }
    }

    private func zoomControls(viewport: CGSize, content: CGSize) -> some View {
        HStack(spacing: 8) {
            Button { setZoom(zoom / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
                .disabled(zoom <= 0.25)
            Button { setZoom(1) } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .help("Actual size")
            .accessibilityLabel("Actual size, current zoom \(Int((zoom * 100).rounded())) percent")
            Button { setZoom(zoom * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
                .disabled(zoom >= 2)
            Divider().frame(height: 14)
            Button("Fit") {
                setZoom(min((viewport.width - 2 * viewportInset) / content.width,
                            (viewport.height - 2 * viewportInset - 48) / content.height))
            }
            .help("Fit topology in view")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    // MARK: Connector legend

    /// Floating legend describing each connector kind present in the current graph.
    private func legend(_ graph: FleetGraph) -> some View {
        let present = Set(graph.edges.map(\.kind))
        let items = Self.legendOrder.filter { present.contains($0) }
        return Group {
            if !items.isEmpty {
                HStack(spacing: 16) {
                    ForEach(items, id: \.self) { kind in
                        HStack(spacing: 6) {
                            LegendSwatch(kind: kind, animate: !reduceMotion)
                            Text(Self.legendLabel(kind)).font(.caption2)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
                .accessibilityLabel("Connector legend")
            }
        }
    }

    private static let legendOrder: [FleetEdgeKind] =
        [.traffic, .write, .xwrite, .read, .xread, .repl, .raft, .fed, .orch, .cache, .queue]

    private static func legendLabel(_ kind: FleetEdgeKind) -> String {
        switch kind {
        case .traffic: "Ingress traffic"
        case .write: "DB write"
        case .xwrite: "Cross-region write"
        case .read: "DB read"
        case .xread: "Cross-region read"
        case .repl: "Replication / backup"
        case .raft: "Raft quorum"
        case .fed: "Region federation"
        case .orch: "Scheduling"
        case .cache: "Cache"
        case .queue: "Queue"
        }
    }

    /// A short line drawn with the exact stroke style of its connector kind — dashed kinds
    /// march to mirror the animated connectors on the canvas.
    private struct LegendSwatch: View {
        let kind: FleetEdgeKind
        let animate: Bool
        var body: some View {
            let style = FleetBuilderCanvas.edgeStyle(kind)
            let marching = animate && !style.dash.isEmpty
            TimelineView(.animation(paused: !marching)) { timeline in
                let phase = marching ? -timeline.date.timeIntervalSinceReferenceDate * FleetBuilderCanvas.antSpeed : 0
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(path, with: .color(style.color),
                                   style: StrokeStyle(lineWidth: style.width, lineCap: .round, dash: style.dash, dashPhase: CGFloat(phase)))
                }
                .frame(width: 26, height: 8)
            }
        }
    }

    // MARK: Region frames

    /// A labeled container that encapsulates every node in one region and grows to fit them.
    private struct FleetRegionFrame: Identifiable {
        let region: Int
        let rect: CGRect
        let label: String
        var id: Int { region }
    }

    /// Bounding box (with padding + a label gutter) around every node in each region. Recomputed
    /// from live node positions, so it grows as nodes are dragged.
    private func regionFrames(_ graph: FleetGraph) -> [FleetRegionFrame] {
        let pad: CGFloat = 24, labelGutter: CGFloat = 30
        var frames: [FleetRegionFrame] = []
        for r in 0..<max(1, model.draft.regions) {
            let regionNodes = graph.nodes.filter { $0.region == r }
            guard !regionNodes.isEmpty else { continue }
            let minX = regionNodes.map(\.position.x).min()! - pad
            let minY = regionNodes.map(\.position.y).min()! - pad - labelGutter
            let maxX = regionNodes.map { $0.position.x + $0.size.width }.max()! + pad
            let maxY = regionNodes.map { $0.position.y + $0.size.height }.max()! + pad
            let label = r == 0 ? model.draft.region : model.draft.secondRegion
            frames.append(FleetRegionFrame(region: r,
                                           rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                                           label: label))
        }
        return frames
    }

    private func regionFrameView(_ frame: FleetRegionFrame) -> some View {
        let tint: Color = frame.region == 0 ? .accentColor : .teal
        let selected = model.selectedRegion == frame.region
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(selected ? 0.09 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tint.opacity(selected ? 0.85 : 0.35),
                                      style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: [7, 5]))
                )
                .frame(width: frame.rect.width, height: frame.rect.height)
                .allowsHitTesting(false)

            // Only the label chip is interactive, so clicks on empty canvas still deselect.
            HStack(spacing: 5) {
                Image(systemName: "square.dashed")
                Text("Region \(frame.region == 0 ? "A" : "B") · \(frame.label)")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.85)))
            .overlay(Capsule().strokeBorder(tint.opacity(selected ? 0.9 : 0), lineWidth: 1))
            .padding(10)
            .contentShape(Capsule())
            .onTapGesture { model.selectRegion(frame.region) }
            .help("Click to reassign \(frame.region == 0 ? "Region A" : "Region B")")
        }
        .frame(width: frame.rect.width, height: frame.rect.height, alignment: .topLeading)
    }

    /// Include negative region-header coordinates before sizing the scroll content. Padding
    /// outside this normalized rectangle stays constant in screen points at every zoom level.
    private func contentBounds(_ graph: FleetGraph, frames: [FleetRegionFrame]) -> CGRect {
        var bounds = CGRect(origin: .zero, size: graph.canvasSize)
        for frame in frames { bounds = bounds.union(frame.rect) }
        for node in graph.nodes { bounds = bounds.union(CGRect(origin: node.position, size: node.size)) }
        return bounds
    }

    private func dragGesture(_ node: FleetGraphNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragStart[node.id] == nil {
                    dragStart[node.id] = node.position
                    model.beginInteraction()
                    model.select(node.id)
                }
                let start = dragStart[node.id] ?? node.position
                model.moveNode(id: node.id, to: CGPoint(x: start.x + value.translation.width / zoom,
                                                        y: start.y + value.translation.height / zoom))
            }
            .onEnded { _ in dragStart[node.id] = nil }
    }

    private func connectors(_ graph: FleetGraph) -> some View {
        // Marching ants: animate the dash phase of every dashed connector so flow direction reads
        // at a glance. Solid connectors stay static; honors Reduce Motion.
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : -timeline.date.timeIntervalSinceReferenceDate * Self.antSpeed
            Canvas { context, size in
                // dot grid
                let gap: CGFloat = 24
                var dots = Path()
                var y: CGFloat = 0
                while y < size.height { var x: CGFloat = 0; while x < size.width { dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5)); x += gap }; y += gap }
                context.fill(dots, with: .color(.gray.opacity(0.18)))

                let centers = Dictionary(graph.nodes.map { ($0.id, $0.center) }, uniquingKeysWith: { a, _ in a })
                for edge in graph.edges {
                    guard let a = centers[edge.from], let b = centers[edge.to] else { continue }
                    let style = Self.edgeStyle(edge.kind)
                    let dashPhase = style.dash.isEmpty ? 0 : CGFloat(phase)
                    context.stroke(Self.path(from: a, to: b),
                                   with: .color(style.color),
                                   style: StrokeStyle(lineWidth: style.width, lineCap: .round, dash: style.dash, dashPhase: dashPhase))
                }
            }
        }
    }

    /// Marching-ant speed in points per second (also drives the legend swatches).
    static let antSpeed: Double = 22

    /// Adaptive S-curve: vertical tangents when the edge is mostly vertical, else horizontal.
    static func path(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        if abs(b.y - a.y) >= abs(b.x - a.x) {
            let my = (a.y + b.y) / 2
            path.addCurve(to: b, control1: CGPoint(x: a.x, y: my), control2: CGPoint(x: b.x, y: my))
        } else {
            let mx = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        }
        return path
    }

    static func edgeStyle(_ kind: FleetEdgeKind) -> (color: Color, width: CGFloat, dash: [CGFloat]) {
        switch kind {
        case .traffic: (.accentColor, 2, [])
        case .write: (.blue, 2, [])
        case .xwrite: (.blue, 1.8, [7, 5])
        case .read: (.blue.opacity(0.8), 1.6, [5, 4])
        case .xread: (.blue.opacity(0.7), 1.4, [3, 5])
        case .repl: (.purple, 1.8, [5, 4])
        case .raft: (.gray.opacity(0.7), 1.4, [4, 4])
        case .fed: (.gray.opacity(0.8), 1.6, [6, 4])
        case .orch: (.gray.opacity(0.45), 1, [1, 5])
        case .cache: (.teal, 1.5, [2, 4])
        case .queue: (.indigo, 1.5, [2, 4])
        }
    }
}
