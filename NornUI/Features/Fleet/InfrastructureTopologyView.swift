import SwiftUI

struct InfrastructureTopologyView: View {
    let inventory: NornFleetInventory
    let services: [NornService]
    let deployments: [NornDeployment]
    let health: NornHealth

    private var ingress: [TopologyItem] {
        services
            .filter { $0.reachability.routable && $0.reachability.exposure != "none" }
            .map { service in
                let endpoint = service.endpoints?.first?.url ?? service.reachability.exposure
                return TopologyItem(
                    id: service.id,
                    title: service.name,
                    detail: endpoint,
                    state: service.isPassing ? .healthy : .attention
                )
            }
    }

    private var placements: [TopologyItem] {
        let regions = Set(
            deployments.flatMap { $0.regions ?? [] }.map(\.region)
            + services.flatMap { $0.endpoints ?? [] }.compactMap(\.region)
            + [inventory.document?.cluster.region].compactMap { $0 }
        )
        let regionItems = regions.sorted().map {
            TopologyItem(id: "region:\($0)", title: $0, detail: "Desired region", state: .planned)
        }
        let poolItems = inventory.nodePools.sorted(by: { $0.key < $1.key }).map {
            TopologyItem(
                id: "pool:\($0.key)",
                title: $0.key,
                detail: "\($0.value.desired) desired · \($0.value.size)",
                state: .planned
            )
        }
        return regionItems + poolItems
    }

    private var allocations: [TopologyItem] {
        var items: [TopologyItem] = []
        for service in services {
            for (index, instance) in (service.instances ?? []).enumerated() {
                let identity = instance.id ?? instance.node ?? "instance-\(index)"
                var details = [instance.node, instance.address].compactMap { $0 }
                if let port = instance.port { details.append(String(port)) }
                items.append(TopologyItem(
                    id: service.id + ":" + identity,
                    title: service.name,
                    detail: details.joined(separator: " · "),
                    state: instance.status == "passing" ? .healthy : .attention
                ))
            }
        }
        return items
    }

    private var dependencies: [TopologyItem] {
        health.services.sorted(by: { $0.key < $1.key }).map {
            TopologyItem(
                id: "dependency:\($0.key)",
                title: $0.key.capitalized,
                detail: $0.value,
                state: $0.value == "up" || $0.value == "passing" ? .healthy : .attention
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Platform Topology")
                .font(.title2.weight(.semibold))
            Text("Ingress and allocations come from the service manifest; regions come from deployment and endpoint records; pools remain desired fleet inventory.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    stage("Ingress", symbol: "network", items: ingress)
                    connector("can route to", vertical: false)
                    stage("Regions & Pools", symbol: "server.rack", items: placements)
                    connector("placement intent", vertical: false)
                    stage("Allocations", symbol: "shippingbox", items: allocations)
                    connector("can depend on", vertical: false)
                    stage("Platform", symbol: "gearshape.2", items: dependencies)
                }
                VStack(alignment: .leading, spacing: 8) {
                    stage("Ingress", symbol: "network", items: ingress)
                    connector("can route to", vertical: true)
                    stage("Regions & Pools", symbol: "server.rack", items: placements)
                    connector("placement intent", vertical: true)
                    stage("Allocations", symbol: "shippingbox", items: allocations)
                    connector("can depend on", vertical: true)
                    stage("Platform", symbol: "gearshape.2", items: dependencies)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Label(
                "The current API does not bind service-manifest allocations to a node pool or report provider resources, so those edges remain intentionally unclaimed.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Platform infrastructure topology")
    }

    private func stage(_ title: String, symbol: String, items: [TopologyItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            if items.isEmpty {
                Text("Not reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(items.prefix(8)) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.state.symbol)
                            .font(.caption2)
                            .foregroundStyle(item.state.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.title), \(item.state.label), \(item.detail)")
                    .contextMenu {
                        Button("Copy Details") { copy("\(item.title) \(item.detail)") }
                    }
                }
                if items.count > 8 {
                    Text("+ \(items.count - 8) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 170, maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator) }
    }

    private func connector(_ label: String, vertical: Bool) -> some View {
        Label(label, systemImage: vertical ? "arrow.down" : "arrow.right")
            .labelStyle(.iconOnly)
            .foregroundStyle(.tertiary)
            .frame(minWidth: vertical ? nil : 20, minHeight: vertical ? 18 : 72)
            .accessibilityLabel(label)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct TopologyItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: TopologyItemState
}

private enum TopologyItemState {
    case healthy
    case planned
    case attention

    var label: String {
        switch self {
        case .healthy: "Observed healthy"
        case .planned: "Desired placement"
        case .attention: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .planned: "circle.dashed"
        case .attention: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .planned: .secondary
        case .attention: .orange
        }
    }
}
