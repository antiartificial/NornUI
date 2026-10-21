import XCTest
@testable import NornUI

final class NornObservabilityTests: XCTestCase {
    private func entry(_ time: String, _ line: String, alloc: String = "alloc-1", stream: String = "stdout") -> NornLogEntry {
        NornLogEntry(time: time, allocID: alloc, stream: stream, line: line)
    }

    // MARK: Decoding

    func testLogQueryDecodesNanosecondTimestampsGapsAndTraceIDs() throws {
        let json = Data("""
        {"app":"web","source":"loki","truncated":false,"entries":[
          {"time":"2026-10-21T10:00:00.123456789Z","nodeId":"n1","nodeName":"node","jobId":"web","allocId":"4bf92f35-aaaa","taskGroup":"web","task":"web","stream":"stdout","line":"GET /","traceId":"4bf92f3577b34da6a3ce929d0e0e4736"},
          {"time":"2026-10-21T10:00:01Z","allocId":"4bf92f35-aaaa","task":"web","stream":"stderr","line":"","gap":"lost 3 lines"}]}
        """.utf8)
        let result = try JSONDecoder().decode(NornLogQueryResult.self, from: json)

        XCTAssertEqual(result.source, "loki")
        XCTAssertEqual(result.entries[0].time, "2026-10-21T10:00:00.123456789Z")
        XCTAssertEqual(result.entries[0].shortAllocID, "4bf92f35")
        XCTAssertEqual(result.entries[0].traceID, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(result.entries[0].date.timeIntervalSince1970, 1_792_576_800.123456789, accuracy: 0.001)
        XCTAssertTrue(result.entries[1].isGap)
        XCTAssertEqual(result.entries[1].date.timeIntervalSince1970, 1_792_576_801, accuracy: 0.001)
    }

    func testTimestampParsingAcceptsOffsetsAndRejectsGarbage() {
        XCTAssertEqual(NornTimestamp.parse("2026-10-21T12:00:00.5+02:00")?.timeIntervalSince1970 ?? 0, 1_792_576_800.5, accuracy: 0.001)
        XCTAssertNil(NornTimestamp.parse("yesterday"))
    }

    func testTraceListAndDetailDecode() throws {
        let list = try JSONDecoder().decode(NornTraceList.self, from: Data("""
        {"app":"web","traces":[{"traceId":"t1","rootName":"GET /","rootService":"web","start":"2026-10-21T10:00:00.5Z","durationMs":12.5,"spanCount":7}]}
        """.utf8))
        XCTAssertEqual(list.traces.first?.spanCount, 7)
        XCTAssertEqual(list.traces.first?.durationMs, 12.5)

        let detail = try JSONDecoder().decode(NornTraceDetail.self, from: Data("""
        {"traceId":"t1","app":"web","omittedSpans":3,"spans":[
          {"spanId":"s1","parentSpanId":"","name":"GET /","service":"web","app":"web","process":"web","allocId":"a1","kind":"server",
           "start":"2026-10-21T10:00:00.000000001Z","end":"2026-10-21T10:00:00.5Z","durationMs":500,"status":"error","statusMessage":"boom","attributes":{"http.route":"/","http.status_code":500}}]}
        """.utf8))
        XCTAssertEqual(detail.omittedSpans, 3)
        XCTAssertTrue(detail.spans[0].isError)
        XCTAssertEqual(detail.spans[0].attributes["http.route"], .string("/"))
        XCTAssertEqual(detail.spans[0].attributes["http.status_code"], .number(500))
    }

    // MARK: Query items

    func testFilterQueryItemsIncludeOnlySetFieldsAndClampLimit() {
        let since = Date(timeIntervalSince1970: 1_792_576_800)
        var filter = NornLogFilter(since: since, alloc: "a1", task: "web", stream: .stderr, contains: "err", limit: 99_999, direction: .forward)
        var items = Dictionary(uniqueKeysWithValues: filter.queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["since"], "2026-10-21T10:00:00.000Z")
        XCTAssertEqual(items["alloc"], "a1")
        XCTAssertEqual(items["task"], "web")
        XCTAssertEqual(items["stream"], "stderr")
        XCTAssertEqual(items["contains"], "err")
        XCTAssertEqual(items["limit"], "5000")
        XCTAssertEqual(items["direction"], "forward")
        XCTAssertNil(items["taskGroup"])
        XCTAssertNil(items["until"])

        filter.sinceCursor = "2026-10-21T10:00:00.123456789Z"
        items = Dictionary(uniqueKeysWithValues: filter.queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["since"], "2026-10-21T10:00:00.123456789Z")
    }

    // MARK: Tail buffer

    func testTailBufferDeduplicatesOverlappingPollsAndTracksNewest() {
        var buffer = NornLogTailBuffer(direction: .backward)
        buffer.replace(with: [entry("2026-10-21T10:00:02Z", "c"), entry("2026-10-21T10:00:01Z", "b")])
        XCTAssertEqual(buffer.newestTime, "2026-10-21T10:00:02Z")

        let added = buffer.append(chronological: [entry("2026-10-21T10:00:02Z", "c"), entry("2026-10-21T10:00:03Z", "d")])

        XCTAssertEqual(added, 1)
        XCTAssertEqual(buffer.entries.map(\.line), ["d", "c", "b"])
        XCTAssertEqual(buffer.newestTime, "2026-10-21T10:00:03Z")
        // Same time and line from a different allocation or stream is distinct.
        XCTAssertEqual(buffer.append(chronological: [entry("2026-10-21T10:00:03Z", "d", alloc: "alloc-2"), entry("2026-10-21T10:00:03Z", "d", stream: "stderr")]), 2)
    }

    func testTailBufferCapsMemoryAndForgetsDroppedKeys() {
        var forward = NornLogTailBuffer(direction: .forward, capacity: 3)
        forward.replace(with: (1 ... 3).map { entry("2026-10-21T10:00:0\($0)Z", "l\($0)") })
        forward.append(chronological: [entry("2026-10-21T10:00:04Z", "l4"), entry("2026-10-21T10:00:05Z", "l5")])
        XCTAssertEqual(forward.entries.map(\.line), ["l3", "l4", "l5"])
        // l1 was evicted, so it is accepted again instead of leaking in the seen set.
        XCTAssertEqual(forward.append(chronological: [entry("2026-10-21T10:00:01Z", "l1")]), 1)

        var backward = NornLogTailBuffer(direction: .backward, capacity: 2)
        backward.replace(with: [entry("2026-10-21T10:00:02Z", "b"), entry("2026-10-21T10:00:01Z", "a")])
        backward.append(chronological: [entry("2026-10-21T10:00:03Z", "c")])
        XCTAssertEqual(backward.entries.map(\.line), ["c", "b"])
    }

    // MARK: Waterfall layout

    private func span(_ id: String, parent: String = "", start: Double, end: Double) -> NornSpan {
        NornSpan(spanID: id, parentSpanID: parent, name: id, start: Date(timeIntervalSince1970: 1_000 + start), end: Date(timeIntervalSince1970: 1_000 + end))
    }

    func testLayoutOrdersTreeDepthFirstAndPositionsBars() {
        let layout = NornTraceLayout(spans: [
            span("child-b", parent: "root", start: 0.6, end: 0.8),
            span("root", start: 0, end: 1),
            span("child-a", parent: "root", start: 0.2, end: 0.5),
            span("grandchild", parent: "child-a", start: 0.3, end: 0.4),
        ])

        XCTAssertEqual(layout.rows.map(\.id), ["root", "child-a", "grandchild", "child-b"])
        XCTAssertEqual(layout.rows.map(\.depth), [0, 1, 2, 1])
        XCTAssertEqual(layout.duration, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.rows[1].offset, 0.2, accuracy: 0.0001)
        XCTAssertEqual(layout.rows[1].width, 0.3, accuracy: 0.0001)
    }

    func testLayoutTreatsOrphansAsRootsAndSurvivesCyclesAndZeroDuration() {
        let orphan = NornTraceLayout(spans: [span("a", parent: "hidden", start: 0, end: 1), span("b", parent: "a", start: 0.5, end: 2)])
        XCTAssertEqual(orphan.rows.map(\.depth), [0, 1])
        XCTAssertEqual(orphan.rows[1].width, 0.75, accuracy: 0.0001)

        let cycle = NornTraceLayout(spans: [span("x", parent: "y", start: 0, end: 1), span("y", parent: "x", start: 0, end: 1)])
        XCTAssertEqual(cycle.rows.count, 2)

        let instant = NornTraceLayout(spans: [span("z", start: 5, end: 5)])
        XCTAssertEqual(instant.rows.first?.width, 0)
        XCTAssertTrue(NornTraceLayout(spans: []).rows.isEmpty)
    }

    // MARK: Error mapping

    func testIssueMapping() {
        func http(_ status: Int) -> NornClientError { .http(status: status, message: nil, requestID: nil) }
        XCTAssertEqual(NornObservabilityIssue(http(404), feature: .logs), .unsupported)
        XCTAssertEqual(NornObservabilityIssue(http(404), feature: .traceDetail), .notFound)
        XCTAssertEqual(NornObservabilityIssue(http(503), feature: .logs), .notConfigured("NORN_LOG_SPOOL_DIR or NORN_LOKI_URL"))
        XCTAssertEqual(NornObservabilityIssue(http(503), feature: .traces), .notConfigured("NORN_TEMPO_URL"))
        XCTAssertEqual(NornObservabilityIssue(http(403), feature: .logs), .forbidden)
        if case .failed = NornObservabilityIssue(http(502), feature: .logs) {} else { XCTFail("502 should be a generic failure") }
    }
}
