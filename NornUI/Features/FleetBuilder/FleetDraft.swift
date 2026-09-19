import Foundation
import CoreGraphics

// MARK: - Enums

nonisolated enum FleetDBMode: String, Sendable, Codable, Hashable, CaseIterable {
    case selfManaged = "self"
    case managed
    var title: String { self == .managed ? "Managed" : "Self-managed" }
}

nonisolated enum FleetDBEngine: String, Sendable, Codable, Hashable, CaseIterable {
    case pg
    case mysql
    var title: String { self == .mysql ? "MySQL" : "PostgreSQL" }
}

nonisolated enum FleetEdgeMode: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    case cloudflare
    var title: String { self == .cloudflare ? "Cloudflare" : "None" }
}

nonisolated enum FleetReplicaRegion: String, Sendable, Codable, Hashable {
    case same
    case b
}

nonisolated enum FleetServiceKind: String, Sendable, Codable, Hashable {
    case cache
    case queue
    var title: String { self == .cache ? "Cache" : "Queue" }
    var engineOptions: [String] { self == .cache ? ["Valkey", "Redis"] : ["Redpanda", "Kafka"] }
    var defaultEngine: String { self == .cache ? "Valkey" : "Redpanda" }
    var defaultSize: String { self == .cache ? "s-2vcpu-4gb" : "s-4vcpu-8gb" }
    var defaultCount: Int { self == .cache ? 1 : 3 }
}

// MARK: - Independent pools

nonisolated struct FleetServicePool: Sendable, Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: FleetServiceKind
    var engine: String
    var size: String
    var count: Int
    var position: CGPoint = .zero
}

nonisolated struct FleetTestDB: Sendable, Codable, Hashable, Identifiable {
    var id = UUID()
    var mode: FleetDBMode = .selfManaged
    var engine: FleetDBEngine = .pg
    var size: String = "s-2vcpu-4gb"
    var position: CGPoint = .zero
}

// MARK: - Draft

/// The full fleet composition the builder edits. A value type so undo/redo is a snapshot stack
/// and drag positions travel with it. Mirror of `FleetDraft` in `v2/ui/src/lib/fleetDraft.ts`.
nonisolated struct FleetDraft: Sendable, Codable, Hashable {
    var name: String = "norn-prod"
    var region: String = "nyc3"
    var secondRegion: String = FleetCatalog.secondRegionDefault
    var regions: Int = 1               // 1 or 2
    var edge: FleetEdgeMode = .none
    var controlA: Int = 3
    var controlB: Int = 0
    var appA: Int = 2
    var appB: Int = 2
    var db: DB = DB()
    var services: [FleetServicePool] = []
    var extras: [FleetTestDB] = []
    var sizes: Sizes = Sizes()
    /// Manual node-position overrides keyed by graph-node id; empty means auto-layout.
    var positions: [String: CGPoint] = [:]

    nonisolated struct DB: Sendable, Codable, Hashable {
        var mode: FleetDBMode = .selfManaged
        var engine: FleetDBEngine = .pg
        var replica: Bool = false
        var replicaRegion: FleetReplicaRegion = .same
        var managedSize: String = "db-s-2vcpu-4gb"
        var selfSize: String = "g-4vcpu-16gb"
    }

    nonisolated struct Sizes: Sendable, Codable, Hashable {
        var control: String = "g-2vcpu-8gb"
        var app: String = "s-4vcpu-8gb"
        // NOTE: app size is shared across regions; per-region app sizing (appB) is a low-priority TODO.
    }

    var totalApps: Int { appA + (regions == 2 ? appB : 0) }
    var hasSpaces: Bool { FleetCatalog.hasSpaces(region) }
    var edgePresent: Bool { edge == .cloudflare || regions == 2 }
    var replicaResidesInRegionB: Bool { regions == 2 && db.replicaRegion == .b }
}

// MARK: - Validation

extension FleetDraft {
    typealias Finding = NornFleetInventory.Validation.Finding

    /// Live validation findings (error / warning / info). Codes/messages mirror the web client.
    func validate() -> [Finding] {
        var out: [Finding] = []

        let quorumA = controlA % 2 == 1 && controlA >= 3
        out.append(Finding(
            severity: quorumA ? "info" : "error",
            code: "control-quorum",
            field: "control.\(region)",
            message: "Control quorum \(region): \(controlA) node\(controlA == 1 ? "" : "s") — \(quorumA ? "odd, ≥3" : "must be odd and ≥3")",
            remediation: quorumA ? nil : "Use an odd number of at least 3 control nodes."))

        if regions == 2 {
            if controlB == 0 {
                out.append(Finding(severity: "info", code: "control-region-b", field: "control.\(secondRegion)",
                    message: "Region B has no control plane — depends on \(region) for scheduling (no independent quorum)", remediation: nil))
            } else if controlB % 2 == 1 && controlB >= 3 {
                out.append(Finding(severity: "info", code: "control-region-b", field: "control.\(secondRegion)",
                    message: "Region B: \(controlB)-node federated quorum — survives isolation from \(region)", remediation: nil))
            } else {
                out.append(Finding(severity: "error", code: "control-region-b", field: "control.\(secondRegion)",
                    message: "Region B control (\(controlB)) can't hold quorum",
                    remediation: "Use 0 (dependent on \(region)) or an odd number ≥3 (federated)."))
            }
        }

        out.append(hasSpaces
            ? Finding(severity: "info", code: "object-storage", field: "region",
                message: "\(region) has DO Spaces for state + WAL backup", remediation: nil)
            : Finding(severity: "error", code: "object-storage", field: "region",
                message: "\(region) has no DO Spaces — state + WAL backup need it",
                remediation: "Choose a Spaces region: \(FleetCatalog.spacesRegions.sorted().joined(separator: ", "))."))

        if db.mode == .managed {
            out.append(Finding(severity: "info", code: "database", field: "db.mode",
                message: "Managed \(db.engine.title) — provider-run HA\(db.replica ? " + read replica" : "")", remediation: nil))
        } else {
            let size = FleetCatalog.node(db.selfSize)
            let ok = (size?.vcpu ?? 0) >= FleetCatalog.dbSelfMinVCPU && (size?.memGB ?? 0) >= FleetCatalog.dbSelfMinMemGB
            out.append(Finding(severity: ok ? "info" : "error", code: "database", field: "db.size",
                message: "Self-managed Postgres (Patroni ×3) in \(region) · \(db.selfSize)\(ok ? "" : " below minimum")",
                remediation: ok ? nil : "Use at least \(FleetCatalog.dbSelfMinVCPU)vcpu / \(FleetCatalog.dbSelfMinMemGB)gb."))
        }

        if regions == 2 {
            out.append(Finding(severity: "warning", code: "cross-region-write", field: "db",
                message: "Region B apps write to the \(region) primary (added latency)",
                remediation: replicaResidesInRegionB ? nil : "Add a read replica in region B for local reads."))

            if region == secondRegion {
                out.append(Finding(severity: "warning", code: "region-distinct", field: "regions",
                    message: "Region A and Region B are both \(region) — a second region should be distinct for HA",
                    remediation: "Pick a different region for Region B, or set regions to 1."))
            }
        }

        return out
    }

    var hasBlockingFindings: Bool { validate().contains { $0.severity == "error" } }
}

// MARK: - Cost

extension FleetDraft {
    nonisolated struct CostLine: Sendable, Hashable, Identifiable {
        var label: String
        var usdMonthly: Int
        var id: String { label }
    }

    func costLines() -> [CostLine] {
        var lines: [CostLine] = []
        let control = FleetCatalog.node(sizes.control)?.usdMonthly ?? 0
        lines.append(CostLine(label: "Control A · \(controlA)×\(sizes.control)", usdMonthly: control * controlA))
        if regions == 2 && controlB > 0 {
            lines.append(CostLine(label: "Control B · \(controlB)×\(sizes.control)", usdMonthly: control * controlB))
        }
        let app = FleetCatalog.node(sizes.app)?.usdMonthly ?? 0
        lines.append(CostLine(label: "App · \(totalApps)×\(sizes.app)", usdMonthly: app * totalApps))

        if db.mode == .managed {
            let count = 1 + (db.replica ? 1 : 0)
            let unit = FleetCatalog.managed(db.managedSize)?.usdMonthly ?? 0
            lines.append(CostLine(label: "Managed DB · \(count)×\(db.managedSize)", usdMonthly: unit * count))
        } else {
            let unit = FleetCatalog.node(db.selfSize)?.usdMonthly ?? 0
            lines.append(CostLine(label: "Postgres · 3×\(db.selfSize)", usdMonthly: unit * 3))
        }

        for (index, extra) in extras.enumerated() {
            let unit = (extra.mode == .managed ? FleetCatalog.managed(extra.size) : FleetCatalog.node(extra.size))?.usdMonthly ?? 0
            lines.append(CostLine(label: "Test DB \(index + 1) · \(extra.mode.rawValue)", usdMonthly: unit))
        }
        for svc in services {
            let unit = FleetCatalog.node(svc.size)?.usdMonthly ?? 0
            lines.append(CostLine(label: "\(svc.kind.title) · \(svc.count)×\(svc.size)", usdMonthly: unit * svc.count))
        }

        if edge == .cloudflare { lines.append(CostLine(label: "Cloudflare edge", usdMonthly: 0)) }
        lines.append(CostLine(label: "Regional LB · \(regions)×", usdMonthly: FleetCatalog.lbMonthly * regions))
        lines.append(CostLine(label: "Spaces (est.)", usdMonthly: FleetCatalog.spacesMonthly))
        return lines
    }

    func totalMonthlyUSD() -> Int { costLines().reduce(0) { $0 + $1.usdMonthly } }
}

// MARK: - cluster.yaml export

extension FleetDraft {
    /// Emit a `norn.dev/fleet/v1` Cluster document. Mirrors the web `toClusterYaml`.
    func clusterYAML() -> String {
        var out = ""
        out += "apiVersion: norn.dev/fleet/v1\n"
        out += "kind: Cluster\n"
        out += "metadata:\n  name: \(name)\n"
        out += "spec:\n"
        out += "  provider: digitalocean\n"
        out += "  regions:\n"
        out += "    - name: \(region)\n      role: primary\n"
        if regions == 2 { out += "    - name: \(secondRegion)\n      role: secondary\n" }
        out += "  nodePools:\n"
        out += pool("control-\(region)", size: sizes.control, count: controlA)
        if regions == 2 && controlB > 0 { out += pool("control-\(secondRegion)", size: sizes.control, count: controlB) }
        out += pool("app-\(region)", size: sizes.app, count: appA)
        if regions == 2 { out += pool("app-\(secondRegion)", size: sizes.app, count: appB) }
        out += "  database:\n"
        if db.mode == .managed {
            out += "    managed: true\n    engine: \(db.engine.rawValue)\n    size: \(db.managedSize)\n    region: \(region)\n"
            if db.replica { out += "    readReplica:\n      region: \(replicaResidesInRegionB ? secondRegion : region)\n" }
        } else {
            out += "    managed: false\n    engine: pg\n    patroni: 3\n    size: \(db.selfSize)\n    region: \(region)\n"
        }
        if !services.isEmpty {
            out += "  services:\n"
            for svc in services {
                out += "    - kind: \(svc.kind.rawValue)\n      engine: \(svc.engine.lowercased())\n      size: \(svc.size)\n      count: \(svc.count)\n"
            }
        }
        out += "  ingress:\n    loadBalancer: do-regional\n"
        if edge == .cloudflare { out += "    edge: cloudflare\n" }
        out += "  objectStorage:\n    spaces: \(hasSpaces)\n"
        return out
    }

    private func pool(_ name: String, size: String, count: Int) -> String {
        "    - name: \(name)\n      size: \(size)\n      count: \(count)\n"
    }
}
