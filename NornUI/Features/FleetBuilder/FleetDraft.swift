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

// MARK: - fleet document export (norn.dev/fleet/v1)

extension FleetDraft {
    nonisolated struct FleetDocument: Sendable, Hashable, Identifiable {
        let filename: String
        let yaml: String
        var id: String { filename }
    }

    /// The emitted documents: one valid single-region `norn.dev/fleet/v1` Cluster per region,
    /// plus a `fleet-extras.yaml` sidecar for managed services the contract doesn't model.
    /// Mirror of the web `fleetDocuments` in v2/ui/src/lib/fleetDraft.ts.
    func fleetDocuments() -> [FleetDocument] {
        var docs: [FleetDocument] = []
        for r in 0..<regions {
            let regionName = r == 0 ? region : secondRegion
            docs.append(FleetDocument(filename: "\(name)-\(regionName).cluster.yaml",
                                      yaml: clusterDoc(regionIndex: r, regionName: regionName)))
        }
        if let extras = extrasDoc() {
            docs.append(FleetDocument(filename: "\(name).fleet-extras.yaml", yaml: extras))
        }
        return docs
    }

    /// Combined, human-readable view of every emitted document (for the YAML pane + clipboard).
    /// Each document is preceded by a `# ===== <filename> =====` comment, which YAML ignores, so a
    /// single-document export remains a valid Cluster.
    func clusterYAML() -> String {
        fleetDocuments().map { "# ===== \($0.filename) =====\n\($0.yaml)" }.joined(separator: "\n")
    }

    // Auto-derive capacity bounds from the single builder count. Stateful/quorum pools stay pinned;
    // stateless pools get one node of blue/green headroom.
    private func nodePoolYAML(name poolName: String, size: String,
                             min: Int, desired: Int, max: Int, workload: String) -> String {
        var out = "  \(poolName):\n"
        out += "    size: \(size)\n"
        out += "    min: \(min)\n    desired: \(desired)\n    max: \(max)\n"
        out += "    labels:\n      workload: \(workload)\n"
        out += "    replacement:\n"
        out += "      strategy: blueGreen\n"
        out += "      requireCapacityHeadroom: true\n"
        out += "      requireReadiness: true\n"
        out += "      drainTimeout: 15m\n"
        return out
    }

    private func clusterDoc(regionIndex r: Int, regionName: String) -> String {
        var out = ""
        out += "apiVersion: norn.dev/fleet/v1\n"
        out += "kind: Cluster\n"
        out += "cluster:\n  name: \(name)\n  provider: digitalocean\n  region: \(regionName)\n"
        // Object storage + edge are managed separately (see fleet-extras); noted here for context.
        out += "# objectStorage: DO Spaces (terraform state + WAL) in \(region)\(hasSpaces ? "" : " — none available")\n"
        if edge == .cloudflare { out += "# edge: cloudflare in front of the regional load balancer\n" }
        out += "nodePools:\n"

        let controlCount = r == 0 ? controlA : controlB
        if controlCount > 0 {
            out += nodePoolYAML(name: "control-\(regionName)", size: sizes.control,
                                min: controlCount, desired: controlCount, max: controlCount, workload: "control")
        }
        let appCount = r == 0 ? appA : appB
        out += nodePoolYAML(name: "app-\(regionName)", size: sizes.app,
                            min: appCount, desired: appCount, max: appCount + 1, workload: "app")

        // DB, cache/queue and self-managed test DBs live in the primary region.
        if r == 0 {
            if db.mode == .selfManaged {
                out += nodePoolYAML(name: "db-\(regionName)", size: db.selfSize,
                                    min: 3, desired: 3, max: 3, workload: "database")
            }
            var cacheN = 0, queueN = 0
            for svc in services {
                let kind = svc.kind == .cache ? "cache" : "queue"
                let n: Int
                if svc.kind == .cache { n = cacheN; cacheN += 1 } else { n = queueN; queueN += 1 }
                let poolName = n == 0 ? "\(kind)-\(regionName)" : "\(kind)-\(regionName)-\(n + 1)"
                out += nodePoolYAML(name: poolName, size: svc.size,
                                    min: svc.count, desired: svc.count, max: svc.count + 1, workload: kind)
            }
            for (i, ex) in extras.enumerated() where ex.mode == .selfManaged {
                out += nodePoolYAML(name: "db-test-\(i + 1)-\(regionName)", size: ex.size,
                                    min: 1, desired: 1, max: 1, workload: "database")
            }
        }
        return out
    }

    /// Managed services that are NOT part of norn.dev/fleet/v1 (provisioned separately). Returns nil
    /// when there is nothing managed to record.
    private func extrasDoc() -> String? {
        let managedExtras = extras.filter { $0.mode == .managed }
        guard db.mode == .managed || edge == .cloudflare || !managedExtras.isEmpty else { return nil }

        var out = "# Managed services not modelled by norn.dev/fleet/v1 — provisioned separately.\n"
        out += "apiVersion: norn.dev/fleet-extras/v1\n"
        out += "cluster: \(name)\n"
        if db.mode == .managed {
            out += "managedDatabase:\n  engine: \(db.engine.rawValue)\n  size: \(db.managedSize)\n  region: \(region)\n"
            if db.replica {
                out += "  readReplica:\n    region: \(replicaResidesInRegionB ? secondRegion : region)\n"
            }
        }
        if !managedExtras.isEmpty {
            out += "testDatabases:\n"
            for ex in managedExtras {
                out += "  - engine: \(ex.engine.rawValue)\n    size: \(ex.size)\n    region: \(region)\n"
            }
        }
        if edge == .cloudflare { out += "edge:\n  provider: cloudflare\n" }
        out += "objectStorage:\n  spaces: \(hasSpaces)\n  region: \(region)\n"
        return out
    }
}
