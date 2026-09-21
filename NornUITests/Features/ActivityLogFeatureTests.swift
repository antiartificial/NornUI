import XCTest
@testable import NornUI

final class ActivityLogFeatureTests: XCTestCase {

    // MARK: Receipts (mutation-audit)

    private func audit(_ id: String, subject: String = "alice", method: String = "PUT",
                       path: String = "/api/v1/apps/demo/scale", outcome: String = "succeeded") -> MutationAuditEvent {
        MutationAuditEvent(id: id, principalSubject: subject, method: method, path: path,
                           status: 200, outcome: outcome,
                           startedAt: Date(timeIntervalSince1970: 2_000_000_000), durationMs: 12)
    }

    func testAuditFilterMatchesAcrossFieldsCaseInsensitively() {
        let events = [
            audit("a", subject: "alice", path: "/api/v1/apps/demo/scale"),
            audit("b", subject: "bob", path: "/api/v1/fleet/plan", outcome: "failed"),
        ]
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "bob").map(\.id), ["b"])
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "SCALE").map(\.id), ["a"])
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "failed").map(\.id), ["b"])
    }

    func testAuditOutcomeMapsToStatusLanguage() {
        XCTAssertEqual(NornStatus(auditOutcome: "succeeded"), .healthy)
        XCTAssertEqual(NornStatus(auditOutcome: "failed"), .critical)
        XCTAssertEqual(NornStatus(auditOutcome: "unrecognized"), .neutral)
    }

    // MARK: Pods / Cell (beacon)

    private func beacon(_ id: String, app: String? = "demo", type: String = "app.restarted",
                        severity: String = "info", title: String = "App restarted",
                        actor: String? = "alice") -> NornBeaconEvent {
        var metadata: [String: JSONValue] = [:]
        if let actor { metadata["actor"] = .string(actor) }
        return NornBeaconEvent(id: id, app: app, type: type, severity: severity, title: title,
                               occurredAt: Date(timeIntervalSince1970: 2_000_000_000),
                               metadata: metadata.isEmpty ? nil : metadata)
    }

    func testBeaconCellScopingSplitsAppVsInfraEvents() {
        let pod = beacon("pod", app: "demo")
        let cell = beacon("cell", app: nil, type: "nomad.allocation.rescheduled", title: "Alloc rescheduled")
        XCTAssertFalse(pod.isCellScoped)
        XCTAssertTrue(cell.isCellScoped)
        let empty = beacon("empty", app: "")
        XCTAssertTrue(empty.isCellScoped, "empty app string must be treated as cell-scoped")
    }

    func testBeaconActorExtractedFromMetadata() {
        XCTAssertEqual(beacon("a", actor: "alice").actor, "alice")
        XCTAssertNil(beacon("b", actor: nil).actor)
    }

    func testBeaconFilterMatchesTitleTypeAppActor() {
        let events = [
            beacon("a", app: "web", type: "app.restarted", title: "App restarted", actor: "alice"),
            beacon("b", app: "api", type: "app.secret-updated", title: "Secrets updated", actor: "bob"),
        ]
        XCTAssertEqual(NornBeaconEvent.filter(events, query: "secret").map(\.id), ["b"])
        XCTAssertEqual(NornBeaconEvent.filter(events, query: "ALICE").map(\.id), ["a"])
        XCTAssertEqual(NornBeaconEvent.filter(events, query: "api").map(\.id), ["b"])
        XCTAssertEqual(NornBeaconEvent.filter(events, query: "  ").map(\.id), ["a", "b"])
    }

    func testBeaconSeverityMapsToStatusLanguage() {
        XCTAssertEqual(NornStatus(beaconSeverity: "critical"), .critical)
        XCTAssertEqual(NornStatus(beaconSeverity: "warning"), .attention)
        XCTAssertEqual(NornStatus(beaconSeverity: "info"), .neutral)
    }

    func testBeaconListDecodesServerWireShape() throws {
        let json = Data("""
        {"events":[
          {"id":"b1","app":"demo","type":"app.restarted","severity":"info",
           "state":"","title":"App restarted","occurredAt":"2026-01-01T00:00:00Z",
           "metadata":{"actor":"alice","count":3}},
          {"id":"b2","app":"","type":"nomad.allocation.rescheduled","severity":"warning",
           "state":"","title":"Alloc rescheduled","occurredAt":"2026-01-01T00:01:00Z"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode(NornBeaconList.self, from: json)
        XCTAssertEqual(list.events.count, 2)
        let pod = try XCTUnwrap(list.events.first)
        XCTAssertEqual(pod.app, "demo")
        XCTAssertEqual(pod.type, "app.restarted")
        XCTAssertEqual(pod.actor, "alice")
        XCTAssertFalse(pod.isCellScoped)
        XCTAssertTrue(list.events[1].isCellScoped)
    }
}
