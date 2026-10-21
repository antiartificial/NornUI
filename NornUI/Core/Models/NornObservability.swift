import Foundation

/// RFC 3339 parsing that keeps nanosecond text intact. `Date` cannot hold nanoseconds,
/// so log entries retain the raw string for de-duplication and live-tail cursors.
nonisolated enum NornTimestamp {
    static func parse(_ value: String) -> Date? {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let dot = value.firstIndex(of: ".") else { return standard.date(from: value) }
        let afterDot = value.index(after: dot)
        let digitsEnd = value[afterDot...].firstIndex(where: { !$0.isNumber }) ?? value.endIndex
        let digits = value[afterDot ..< digitsEnd]
        guard !digits.isEmpty, let base = standard.date(from: String(value[..<dot]) + String(value[digitsEnd...])),
              let fraction = Double("0." + digits) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    fileprivate static func decode(from decoder: Decoder) throws -> (raw: String, date: Date) {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = parse(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an RFC 3339 timestamp.")
        }
        return (raw, date)
    }
}

nonisolated struct NornLogFilter: Equatable, Sendable {
    enum Stream: String, CaseIterable, Sendable { case stdout, stderr }
    enum Direction: String, CaseIterable, Sendable { case backward, forward }

    var since: Date?
    var until: Date?
    /// Exact server timestamp text; takes precedence over `since` (live-tail cursor).
    var sinceCursor: String?
    var alloc = ""
    var taskGroup = ""
    var task = ""
    var stream: Stream?
    var contains = ""
    var limit = 500
    var direction: Direction = .backward

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let sinceCursor { items.append(.init(name: "since", value: sinceCursor)) }
        else if let since { items.append(.init(name: "since", value: NornTimestamp.format(since))) }
        if let until { items.append(.init(name: "until", value: NornTimestamp.format(until))) }
        for (name, value) in [("alloc", alloc), ("taskGroup", taskGroup), ("task", task)] where !value.isEmpty {
            items.append(.init(name: name, value: value))
        }
        if let stream { items.append(.init(name: "stream", value: stream.rawValue)) }
        if !contains.isEmpty { items.append(.init(name: "contains", value: contains)) }
        items.append(.init(name: "limit", value: String(min(max(limit, 1), 5000))))
        items.append(.init(name: "direction", value: direction.rawValue))
        return items
    }
}

nonisolated struct NornLogEntry: Identifiable, Decodable, Hashable, Sendable {
    var time: String
    var date: Date
    var nodeID: String?
    var nodeName: String?
    var jobID: String?
    var allocID: String
    var taskGroup: String?
    var task: String
    var stream: String
    var line: String
    var gap: String?
    var traceID: String?

    var isGap: Bool { gap != nil }
    var shortAllocID: String { String(allocID.prefix(8)) }
    var isStderr: Bool { stream == "stderr" }
    /// Live-tail de-duplication identity from the API contract.
    var dedupKey: String { [time, allocID, stream, line, gap ?? ""].joined(separator: "\u{1F}") }
    var id: String { dedupKey }

    enum CodingKeys: String, CodingKey {
        case time, nodeName, taskGroup, task, stream, line, gap
        case nodeID = "nodeId", jobID = "jobId", allocID = "allocId", traceID = "traceId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (time, date) = try NornTimestamp.decode(from: c.superDecoder(forKey: .time))
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID)
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName)
        jobID = try c.decodeIfPresent(String.self, forKey: .jobID)
        allocID = try c.decodeIfPresent(String.self, forKey: .allocID) ?? ""
        taskGroup = try c.decodeIfPresent(String.self, forKey: .taskGroup)
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        stream = try c.decodeIfPresent(String.self, forKey: .stream) ?? ""
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        gap = try c.decodeIfPresent(String.self, forKey: .gap)
        traceID = try c.decodeIfPresent(String.self, forKey: .traceID)
    }

    init(time: String, allocID: String, task: String = "web", stream: String = "stdout", line: String, gap: String? = nil, traceID: String? = nil) {
        self.time = time
        self.date = NornTimestamp.parse(time) ?? .distantPast
        self.allocID = allocID
        self.task = task
        self.stream = stream
        self.line = line
        self.gap = gap
        self.traceID = traceID
    }
}

nonisolated struct NornLogQueryResult: Decodable, Equatable, Sendable {
    var app: String
    var source: String
    var entries: [NornLogEntry]
    var truncated: Bool

    init(app: String, source: String, entries: [NornLogEntry], truncated: Bool) {
        self.app = app
        self.source = source
        self.entries = entries
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case app, source, entries, truncated }
        let c = try decoder.container(keyedBy: Keys.self)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        entries = try c.decodeIfPresent([NornLogEntry].self, forKey: .entries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

nonisolated struct NornTraceSummary: Identifiable, Decodable, Hashable, Sendable {
    var traceID: String
    var rootName: String
    var rootService: String
    var start: Date
    var durationMs: Double
    var spanCount: Int
    var id: String { traceID }

    enum CodingKeys: String, CodingKey {
        case traceID = "traceId", rootName, rootService, start, durationMs, spanCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traceID = try c.decode(String.self, forKey: .traceID)
        rootName = try c.decodeIfPresent(String.self, forKey: .rootName) ?? ""
        rootService = try c.decodeIfPresent(String.self, forKey: .rootService) ?? ""
        start = try NornTimestamp.decode(from: c.superDecoder(forKey: .start)).date
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0
        spanCount = try c.decodeIfPresent(Int.self, forKey: .spanCount) ?? 0
    }

    init(traceID: String, rootName: String, rootService: String, start: Date, durationMs: Double, spanCount: Int) {
        self.traceID = traceID
        self.rootName = rootName
        self.rootService = rootService
        self.start = start
        self.durationMs = durationMs
        self.spanCount = spanCount
    }
}

nonisolated struct NornTraceList: Decodable, Equatable, Sendable {
    var app: String
    var traces: [NornTraceSummary]

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case app, traces }
        let c = try decoder.container(keyedBy: Keys.self)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        traces = try c.decodeIfPresent([NornTraceSummary].self, forKey: .traces) ?? []
    }
}

nonisolated struct NornSpan: Identifiable, Decodable, Hashable, Sendable {
    var spanID: String
    var parentSpanID: String
    var name: String
    var service: String
    var app: String
    var process: String
    var allocID: String
    var kind: String
    var start: Date
    var end: Date
    var durationMs: Double
    var status: String
    var statusMessage: String
    var attributes: [String: JSONValue]
    var id: String { spanID }
    var isError: Bool { status == "error" }

    enum CodingKeys: String, CodingKey {
        case spanID = "spanId", parentSpanID = "parentSpanId"
        case name, service, app, process, kind, start, end, durationMs, status, statusMessage, attributes
        case allocID = "allocId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spanID = try c.decode(String.self, forKey: .spanID)
        parentSpanID = try c.decodeIfPresent(String.self, forKey: .parentSpanID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        service = try c.decodeIfPresent(String.self, forKey: .service) ?? ""
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        process = try c.decodeIfPresent(String.self, forKey: .process) ?? ""
        allocID = try c.decodeIfPresent(String.self, forKey: .allocID) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unspecified"
        start = try NornTimestamp.decode(from: c.superDecoder(forKey: .start)).date
        end = try NornTimestamp.decode(from: c.superDecoder(forKey: .end)).date
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? end.timeIntervalSince(start) * 1000
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unset"
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage) ?? ""
        attributes = try c.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
    }

    init(spanID: String, parentSpanID: String = "", name: String, start: Date, end: Date, status: String = "unset", service: String = "web", allocID: String = "", kind: String = "internal") {
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.service = service
        self.app = service
        self.process = service
        self.allocID = allocID
        self.kind = kind
        self.start = start
        self.end = end
        self.durationMs = end.timeIntervalSince(start) * 1000
        self.status = status
        self.statusMessage = ""
        self.attributes = [:]
    }
}

nonisolated struct NornTraceDetail: Decodable, Equatable, Sendable {
    var traceID: String
    var app: String
    var omittedSpans: Int
    var spans: [NornSpan]

    enum CodingKeys: String, CodingKey { case traceID = "traceId", app, omittedSpans, spans }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traceID = try c.decode(String.self, forKey: .traceID)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        omittedSpans = try c.decodeIfPresent(Int.self, forKey: .omittedSpans) ?? 0
        spans = try c.decodeIfPresent([NornSpan].self, forKey: .spans) ?? []
    }
}

/// What a view should tell the user when a logs or traces request fails.
nonisolated enum NornObservabilityIssue: Equatable, Sendable {
    enum Feature: Sendable { case logs, traces, traceDetail }

    /// 404 from a server that predates the endpoint.
    case unsupported
    case notConfigured(String)
    case forbidden
    case notFound
    case failed(String)

    init(_ error: Error, feature: Feature) {
        if case let .http(status, _, _) = error as? NornClientError {
            switch status {
            case 404: self = feature == .traceDetail ? .notFound : .unsupported
            case 503:
                self = .notConfigured(feature == .logs ? "NORN_LOG_SPOOL_DIR or NORN_LOKI_URL" : "NORN_TEMPO_URL")
            case 403: self = .forbidden
            default: self = .failed(error.localizedDescription)
            }
        } else {
            self = .failed(error.localizedDescription)
        }
    }
}
