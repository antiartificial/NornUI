import XCTest
@testable import NornUI

final class FleetBuilderTests: XCTestCase {

    // MARK: Validation

    func testDefaultDraftHasNoBlockingFindings() {
        let draft = FleetDraft()
        XCTAssertFalse(draft.hasBlockingFindings)
        XCTAssertTrue(draft.validate().contains { $0.code == "object-storage" && $0.severity == "info" })
    }

    func testEvenControlCountFailsQuorum() {
        var draft = FleetDraft()
        draft.controlA = 4
        let finding = draft.validate().first { $0.code == "control-quorum" }
        XCTAssertEqual(finding?.severity, "error")
    }

    func testRegionBControlQuorumRules() {
        var draft = FleetDraft()
        draft.regions = 2

        draft.controlB = 0
        XCTAssertEqual(draft.validate().first { $0.code == "control-region-b" }?.severity, "info")

        draft.controlB = 2
        XCTAssertEqual(draft.validate().first { $0.code == "control-region-b" }?.severity, "error")

        draft.controlB = 3
        XCTAssertEqual(draft.validate().first { $0.code == "control-region-b" }?.severity, "info")
    }

    func testDuplicateRegionsWarn() {
        var draft = FleetDraft()
        draft.regions = 2
        draft.region = "nyc3"
        draft.secondRegion = "nyc3"
        XCTAssertEqual(draft.validate().first { $0.code == "region-distinct" }?.severity, "warning")

        draft.secondRegion = "sfo3"
        XCTAssertNil(draft.validate().first { $0.code == "region-distinct" })
    }

    func testRegionWithoutSpacesIsBlocking() {
        var draft = FleetDraft()
        draft.region = "tor1"
        XCTAssertEqual(draft.validate().first { $0.code == "object-storage" }?.severity, "error")
        XCTAssertTrue(draft.hasBlockingFindings)
    }

    func testUndersizedSelfDBIsBlocking() {
        var draft = FleetDraft()
        draft.db.selfSize = "s-2vcpu-4gb" // 4gb < 8gb minimum
        XCTAssertEqual(draft.validate().first { $0.code == "database" }?.severity, "error")
    }

    func testMultiRegionAddsCrossRegionWriteWarning() {
        var draft = FleetDraft()
        draft.regions = 2
        XCTAssertEqual(draft.validate().first { $0.code == "cross-region-write" }?.severity, "warning")
    }

    // MARK: Cost

    func testDefaultCostTotal() {
        // control 3×63 + app 2×48 + postgres 3×126 + LB 12 + spaces 5
        XCTAssertEqual(FleetDraft().totalMonthlyUSD(), 189 + 96 + 378 + 12 + 5)
    }

    func testManagedReplicaCost() {
        var draft = FleetDraft()
        draft.db.mode = .managed          // db-s-2vcpu-4gb = 60
        draft.db.replica = true           // 2 instances
        let dbLine = draft.costLines().first { $0.label.hasPrefix("Managed DB") }
        XCTAssertEqual(dbLine?.usdMonthly, 120)
    }

    func testCloudflareEdgeIsFree() {
        var draft = FleetDraft()
        draft.edge = .cloudflare
        let line = draft.costLines().first { $0.label == "Cloudflare edge" }
        XCTAssertEqual(line?.usdMonthly, 0)
    }

    // MARK: cluster.yaml

    func testClusterYAMLShape() {
        // Default draft: 1 region, self-managed DB, no managed extras -> a single valid Cluster doc.
        let docs = FleetDraft().fleetDocuments()
        XCTAssertEqual(docs.count, 1)
        let doc = docs[0]
        XCTAssertEqual(doc.filename, "norn-prod-nyc3.cluster.yaml")
        let yaml = doc.yaml
        XCTAssertTrue(yaml.contains("apiVersion: norn.dev/fleet/v1"))
        XCTAssertTrue(yaml.contains("kind: Cluster"))
        XCTAssertTrue(yaml.contains("cluster:\n  name: norn-prod\n  provider: digitalocean\n  region: nyc3"))
        XCTAssertTrue(yaml.contains("nodePools:"))
        XCTAssertTrue(yaml.contains("control-nyc3:"))
        XCTAssertTrue(yaml.contains("app-nyc3:"))
        XCTAssertTrue(yaml.contains("db-nyc3:"))
        XCTAssertTrue(yaml.contains("workload: control"))
        // Control quorum is pinned (min == desired == max); apps get one node of headroom.
        XCTAssertTrue(yaml.contains("min: 3\n    desired: 3\n    max: 3"))
        XCTAssertTrue(yaml.contains("min: 2\n    desired: 2\n    max: 3"))
        XCTAssertTrue(yaml.contains("strategy: blueGreen"))
        XCTAssertTrue(yaml.contains("requireCapacityHeadroom: true"))
        XCTAssertTrue(yaml.contains("drainTimeout: 15m"))
    }

    func testManagedDatabaseGoesToExtrasSidecar() {
        var draft = FleetDraft()
        draft.db.mode = .managed
        let docs = draft.fleetDocuments()
        XCTAssertEqual(docs.count, 2)
        let cluster = docs[0].yaml
        XCTAssertFalse(cluster.contains("db-nyc3:"))          // managed DB is not a node pool
        let extras = docs[1]
        XCTAssertEqual(extras.filename, "norn-prod.fleet-extras.yaml")
        XCTAssertTrue(extras.yaml.contains("apiVersion: norn.dev/fleet-extras/v1"))
        XCTAssertTrue(extras.yaml.contains("managedDatabase:"))
    }

    func testTwoRegionsEmitOneClusterDocEach() {
        var draft = FleetDraft()
        draft.regions = 2
        draft.secondRegion = "sfo3"
        let docs = draft.fleetDocuments()
        XCTAssertTrue(docs.contains { $0.filename == "norn-prod-nyc3.cluster.yaml" })
        XCTAssertTrue(docs.contains { $0.filename == "norn-prod-sfo3.cluster.yaml" })
        let b = docs.first { $0.filename.contains("sfo3") }!.yaml
        XCTAssertTrue(b.contains("region: sfo3"))
        XCTAssertTrue(b.contains("app-sfo3:"))
        XCTAssertFalse(b.contains("db-sfo3:"))                // DB stays in the primary region
    }

    // MARK: Graph

    func testGraphContainsExpectedNodes() {
        let graph = FleetDraft().graph()
        let ids = Set(graph.nodes.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["db0", "sp", "lb0", "a0_0", "a0_1", "c0_0", "c0_1", "c0_2"]))
        XCTAssertFalse(graph.nodes.contains { $0.id == "edge" }) // single region, no edge, no global node
    }

    func testCloudflareAddsGlobalEdgeNode() {
        var draft = FleetDraft()
        draft.edge = .cloudflare
        XCTAssertTrue(draft.graph().nodes.contains { $0.id == "edge" && $0.kind == .edgeCloudflare })
    }

    // MARK: Model undo/redo

    @MainActor
    func testUndoRedoRoundTrip() {
        let model = FleetBuilderModel()
        XCTAssertEqual(model.draft.appA, 2)
        model.stepAppA(1)
        XCTAssertEqual(model.draft.appA, 3)
        model.undo()
        XCTAssertEqual(model.draft.appA, 2)
        model.redo()
        XCTAssertEqual(model.draft.appA, 3)
    }

    @MainActor
    func testAddAndRemoveCachePool() {
        let model = FleetBuilderModel()
        model.addCache()
        XCTAssertEqual(model.draft.services.count, 1)
        XCTAssertEqual(model.draft.services.first?.kind, .cache)
        let id = model.draft.services[0].id
        model.removeService(id: id)
        XCTAssertTrue(model.draft.services.isEmpty)
    }

    @MainActor
    func testControlBStepping() {
        let model = FleetBuilderModel()
        model.setRegions(2)
        XCTAssertEqual(model.draft.controlB, 0)
        model.stepControlB(1)
        XCTAssertEqual(model.draft.controlB, 3)
        model.stepControlB(1)
        XCTAssertEqual(model.draft.controlB, 5)
        model.stepControlB(-1)
        XCTAssertEqual(model.draft.controlB, 3)
        model.stepControlB(-1)
        XCTAssertEqual(model.draft.controlB, 0)
    }
}
