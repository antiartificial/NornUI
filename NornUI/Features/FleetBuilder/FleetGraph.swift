import Foundation
import CoreGraphics

/// Visual node kinds rendered on the canvas (distinct from config enums so rendering is simple).
nonisolated enum FleetNodeKind: String, Sendable, Hashable {
    case control, app, dbPrimary, dbReplica, dbExtra, cache, queue, lb, edgeCloudflare, edgeDNS, spaces
}

/// A connector between two graph nodes, styled by kind.
nonisolated enum FleetEdgeKind: String, Sendable, Hashable {
    case traffic       // edge/LB → app
    case write         // app → primary (same region)
    case xwrite        // app → primary (cross-region)
    case read          // app → replica (same region)
    case xread         // app → replica (cross-region)
    case repl          // primary → replica, primary → spaces
    case raft          // control mesh
    case fed           // region-A control ↔ region-B control (federation)
    case orch          // control → app (schedules)
    case cache         // app → cache
    case queue         // app → queue
}

nonisolated struct FleetGraphNode: Sendable, Identifiable, Hashable {
    var id: String
    var kind: FleetNodeKind
    var title: String
    var badge: String?
    var meta: String?
    var region: Int            // 0 = region A, 1 = region B, -1 = global
    var invalid: Bool = false
    var serviceID: UUID?       // set for cache/queue nodes
    var extraID: UUID?         // set for dbExtra nodes
    var position: CGPoint      // top-left
    var size: CGSize
    var center: CGPoint { CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2) }
}

nonisolated struct FleetGraphEdge: Sendable, Identifiable, Hashable {
    var id: String
    var from: String
    var to: String
    var kind: FleetEdgeKind
}

nonisolated struct FleetGraph: Sendable, Hashable {
    var nodes: [FleetGraphNode]
    var edges: [FleetGraphEdge]
    var canvasSize: CGSize
    func node(_ id: String) -> FleetGraphNode? { nodes.first { $0.id == id } }
}

extension FleetDraft {
    private static let nodeW: CGFloat = 150, nodeH: CGFloat = 58
    private static let ctlW: CGFloat = 104, ctlH: CGFloat = 54

    /// Compute the laid-out graph for the current draft. Manual `positions` overrides win so
    /// dragged nodes stay put until a structural change recomputes them.
    func graph() -> FleetGraph {
        let W = Self.nodeW, H = Self.nodeH
        let twoR = regions == 2
        let blocking = Set(validate().filter { $0.severity == "error" }.map { $0.code })

        var nodes: [FleetGraphNode] = []
        var edges: [FleetGraphEdge] = []

        func bandTop(_ r: Int) -> CGFloat {
            if twoR { return r == 0 ? 96 : 420 }
            return edgePresent ? 96 : 40
        }
        let canvasHeight: CGFloat = twoR ? 740 : 560
        let canvasWidth: CGFloat = 900

        // Global edge (Cloudflare / Global DNS)
        if edgePresent {
            let cf = edge == .cloudflare
            nodes.append(FleetGraphNode(
                id: "edge", kind: cf ? .edgeCloudflare : .edgeDNS,
                title: cf ? "Cloudflare" : "Global DNS", badge: nil, meta: cf ? "edge / WAF" : "anycast",
                region: -1, position: CGPoint(x: 375, y: 8), size: CGSize(width: W, height: H)))
        }

        // Per-region regional LB + app pool + control cluster
        for r in 0..<regions {
            let top = bandTop(r)
            nodes.append(FleetGraphNode(
                id: "lb\(r)", kind: .lb, title: "Regional LB", badge: nil, meta: "Traefik :18080",
                region: r, position: CGPoint(x: 375, y: top), size: CGSize(width: W, height: H)))

            let count = r == 0 ? appA : appB
            let gap = min(190, 640 / CGFloat(max(1, count - 1)))
            let startX = 340 - gap * CGFloat(count - 1) / 2 - W / 2
            for i in 0..<count {
                nodes.append(FleetGraphNode(
                    id: "a\(r)_\(i)", kind: .app, title: "App \(i + 1)", badge: nil, meta: sizes.app,
                    region: r, position: CGPoint(x: max(16, startX + CGFloat(i) * gap), y: top + 96),
                    size: CGSize(width: W, height: H)))
            }

            let cc = r == 0 ? controlA : controlB
            if cc > 0 {
                let cx: CGFloat = 770, cy = top + 74, R: CGFloat = 66
                let ctlMeta = FleetCatalog.node(sizes.control).map { "\($0.vcpu)v·\($0.memGB)g" }
                for i in 0..<cc {
                    let a = -Double.pi / 2 + Double(i) * (2 * Double.pi / Double(cc))
                    nodes.append(FleetGraphNode(
                        id: "c\(r)_\(i)", kind: .control, title: "Control \(i + 1)", badge: nil, meta: ctlMeta,
                        region: r, invalid: blocking.contains(r == 0 ? "control-quorum" : "control-region-b"),
                        position: CGPoint(x: cx + R * CGFloat(cos(a)) - Self.ctlW / 2,
                                          y: cy + R * CGFloat(sin(a)) - Self.ctlH / 2),
                        size: CGSize(width: Self.ctlW, height: Self.ctlH)))
                }
            }
        }

        // Primary DB (region A) + Spaces
        let managed = db.mode == .managed
        let engineTitle = db.engine.title
        let dbY = bandTop(0) + 188
        nodes.append(FleetGraphNode(
            id: "db0", kind: .dbPrimary, title: engineTitle, badge: managed ? "Managed" : "Patroni",
            meta: managed ? db.managedSize : "3× \(db.selfSize)", region: 0,
            invalid: blocking.contains("database"),
            position: CGPoint(x: 300, y: dbY), size: CGSize(width: W, height: H)))
        nodes.append(FleetGraphNode(
            id: "sp", kind: .spaces, title: "DO Spaces", badge: nil, meta: managed ? "state" : "state + WAL",
            region: 0, invalid: blocking.contains("object-storage"),
            position: CGPoint(x: 56, y: dbY), size: CGSize(width: W, height: H)))

        // Optional read replica (managed only)
        if managed && db.replica {
            let inB = replicaResidesInRegionB
            nodes.append(FleetGraphNode(
                id: "dbR", kind: .dbReplica, title: engineTitle, badge: "Read replica", meta: db.managedSize,
                region: inB ? 1 : 0,
                position: CGPoint(x: inB ? 300 : 500, y: inB ? bandTop(1) + 188 : dbY),
                size: CGSize(width: W, height: H)))
        }

        // Independent test DBs
        for (i, ex) in extras.enumerated() {
            let e2 = ex.engine.title
            nodes.append(FleetGraphNode(
                id: "ex\(i)", kind: .dbExtra, title: e2, badge: "Test",
                meta: "\(ex.mode.rawValue) · \(ex.size)", region: 0, extraID: ex.id,
                position: ex.position == .zero ? CGPoint(x: 430 + CGFloat(i) * 26, y: dbY + 78) : ex.position,
                size: CGSize(width: W, height: H)))
        }

        // Independent cache/queue pools
        for (i, sv) in services.enumerated() {
            nodes.append(FleetGraphNode(
                id: "sv\(i)", kind: sv.kind == .cache ? .cache : .queue,
                title: sv.kind.title, badge: sv.engine, meta: "\(sv.count)× \(sv.size)",
                region: 0, serviceID: sv.id,
                position: sv.position == .zero
                    ? CGPoint(x: 200 + CGFloat(i) * 30, y: (twoR ? 360 : 314))
                    : sv.position,
                size: CGSize(width: W, height: H)))
        }

        // Apply manual drag overrides
        nodes = nodes.map { n in
            guard let p = positions[n.id] else { return n }
            var copy = n; copy.position = p; return copy
        }

        // Edges
        let apps = nodes.filter { $0.kind == .app }
        for r in 0..<regions {
            if edgePresent { edges.append(FleetGraphEdge(id: "e-edge-lb\(r)", from: "edge", to: "lb\(r)", kind: .traffic)) }
            for a in apps where a.region == r {
                edges.append(FleetGraphEdge(id: "e-lb\(r)-\(a.id)", from: "lb\(r)", to: a.id, kind: .traffic))
            }
        }
        let replica = nodes.first { $0.kind == .dbReplica }
        for a in apps {
            edges.append(FleetGraphEdge(id: "e-\(a.id)-db0", from: a.id, to: "db0", kind: a.region == 0 ? .write : .xwrite))
            if let rep = replica {
                edges.append(FleetGraphEdge(id: "e-\(a.id)-\(rep.id)", from: a.id, to: rep.id,
                                            kind: rep.region == a.region ? .read : .xread))
            }
        }
        if let rep = replica { edges.append(FleetGraphEdge(id: "e-db0-\(rep.id)", from: "db0", to: rep.id, kind: .repl)) }
        if db.mode == .selfManaged { edges.append(FleetGraphEdge(id: "e-db0-sp", from: "db0", to: "sp", kind: .repl)) }

        for r in 0..<regions {
            let ctl = nodes.filter { $0.kind == .control && $0.region == r }
            for i in 0..<ctl.count {
                for j in (i + 1)..<ctl.count {
                    edges.append(FleetGraphEdge(id: "e-raft-\(ctl[i].id)-\(ctl[j].id)", from: ctl[i].id, to: ctl[j].id, kind: .raft))
                }
            }
            if let head = ctl.first {
                for a in apps where a.region == r {
                    edges.append(FleetGraphEdge(id: "e-orch-\(head.id)-\(a.id)", from: head.id, to: a.id, kind: .orch))
                }
            }
        }
        let ctlA = nodes.first { $0.kind == .control && $0.region == 0 }
        let ctlB = nodes.first { $0.kind == .control && $0.region == 1 }
        if let a = ctlA, let b = ctlB { edges.append(FleetGraphEdge(id: "e-fed", from: a.id, to: b.id, kind: .fed)) }

        for sv in nodes.filter({ $0.kind == .cache || $0.kind == .queue }) {
            for a in apps {
                edges.append(FleetGraphEdge(id: "e-\(a.id)-\(sv.id)", from: a.id, to: sv.id,
                                            kind: sv.kind == .cache ? .cache : .queue))
            }
        }

        return FleetGraph(nodes: nodes, edges: edges, canvasSize: CGSize(width: canvasWidth, height: canvasHeight))
    }
}
