import XCTest
@testable import NornUI

final class AuditFeatureTests: XCTestCase {
    private func event(_ id: String, subject: String = "alice", method: String = "PUT",
                       path: String = "/api/v1/apps/demo/scale", outcome: String = "succeeded") -> MutationAuditEvent {
        MutationAuditEvent(id: id, principalSubject: subject, method: method, path: path,
                           status: 200, outcome: outcome,
                           startedAt: Date(timeIntervalSince1970: 2_000_000_000), durationMs: 12)
    }

    func testFilterMatchesAcrossFieldsCaseInsensitively() {
        let events = [
            event("a", subject: "alice", path: "/api/v1/apps/demo/scale"),
            event("b", subject: "bob", path: "/api/v1/fleet/plan", outcome: "failed"),
        ]
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "bob").map(\.id), ["b"])
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "SCALE").map(\.id), ["a"])
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "failed").map(\.id), ["b"])
        XCTAssertEqual(MutationAuditEvent.filter(events, query: "   ").map(\.id), ["a", "b"])
    }

    func testOutcomeMapsToStatusLanguage() {
        XCTAssertEqual(NornStatus(auditOutcome: "succeeded"), .healthy)
        XCTAssertEqual(NornStatus(auditOutcome: "started"), .active)
        XCTAssertEqual(NornStatus(auditOutcome: "rejected"), .attention)
        XCTAssertEqual(NornStatus(auditOutcome: "failed"), .critical)
        XCTAssertEqual(NornStatus(auditOutcome: "crashed"), .critical)
        XCTAssertEqual(NornStatus(auditOutcome: "unrecognized"), .neutral)
    }

    func testDecodesServerWireShape() throws {
        let json = Data("""
        {"schema":"norn.mutation-audit/v1","count":1,"events":[
          {"id":"evt-1","principalSubject":"alice","method":"PUT",
           "path":"/api/v1/apps/demo/scale","status":200,"outcome":"succeeded",
           "startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z",
           "durationMs":1000,"integrity":"verified","scopes":["admin"],
           "requestId":"req-9","clientIp":"10.0.0.2","tokenId":"tok-1"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode(MutationAuditList.self, from: json)
        XCTAssertEqual(list.count, 1)
        let event = try XCTUnwrap(list.events.first)
        XCTAssertEqual(event.id, "evt-1")
        XCTAssertEqual(event.method, "PUT")
        XCTAssertEqual(event.path, "/api/v1/apps/demo/scale")
        XCTAssertEqual(event.outcome, "succeeded")
        XCTAssertEqual(event.integrity, "verified")
        XCTAssertEqual(event.requestID, "req-9")
        XCTAssertEqual(event.clientIP, "10.0.0.2")
        XCTAssertEqual(event.tokenID, "tok-1")
        XCTAssertEqual(event.scopes, ["admin"])
    }
}
