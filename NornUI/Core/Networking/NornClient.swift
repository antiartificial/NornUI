import Foundation

enum NornClientError: LocalizedError, Sendable, Equatable {
    case invalidBaseURL
    case missingCredential
    case invalidIdempotencyKey
    case invalidResponse
    case http(status: Int, message: String?, requestID: String?)
    case decoding(message: String)
    case transport(message: String)
    case unsupportedWebSocketMessage

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The Norn server address must use HTTPS, or HTTP on a loopback address."
        case .missingCredential:
            return "No access token is available for this server profile."
        case .invalidIdempotencyKey:
            return "A non-empty idempotency key is required for this operation."
        case .invalidResponse:
            return "Norn returned an invalid response."
        case let .http(status, message, requestID):
            let detail = message.map { ": \($0)" } ?? ""
            let request = requestID.map { " (request \($0))" } ?? ""
            return "Norn request failed (HTTP \(status))\(detail)\(request)"
        case let .decoding(message):
            return "Norn returned data the app could not read: \(message)"
        case let .transport(message):
            return "Norn could not be reached: \(message)"
        case .unsupportedWebSocketMessage:
            return "Norn sent an unsupported event-stream message."
        }
    }
}

/// The authenticated v1 Norn transport. All mutable work is queued on the server
/// so an operation survives this client process and an API restart.
actor NornClient: NornClientProtocol {
    private let profile: NornServerProfile
    private let credentialVault: any NornCredentialVault
    private let session: URLSession

    init(
        profile: NornServerProfile,
        credentialVault: some NornCredentialVault,
        session: URLSession = .shared
    ) throws {
        guard Self.isAllowedBaseURL(profile.baseURL) else {
            throw NornClientError.invalidBaseURL
        }
        self.profile = profile
        self.credentialVault = credentialVault
        self.session = session
    }

    func capabilities() async throws -> NornCapabilities {
        try await get("api/v1/capabilities")
    }

    func hostMetrics() async throws -> NornHostMetrics {
        try await get("api/v1/host/metrics")
    }

    func health() async throws -> NornHealth {
        try await get("api/health")
    }

    func serviceManifest() async throws -> NornServiceManifest {
        try await get("api/services/manifest")
    }

	func apps() async throws -> [NornAppStatus] { try await get("api/v1/apps") }

    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation] {
        var components = URLComponents(url: try url(path: "api/operations"), resolvingAgainstBaseURL: false)
        let boundedLimit = min(max(limit, 1), 200)
        var items = [URLQueryItem(name: "limit", value: String(boundedLimit))]
        if activeOnly {
            items.append(URLQueryItem(name: "active", value: "true"))
        }
        components?.queryItems = items
        guard let endpoint = components?.url else {
            throw NornClientError.invalidBaseURL
        }
        let result: NornOperationList = try await perform(url: endpoint, method: "GET")
        return result.operations
    }

    func operation(id: String) async throws -> NornOperation {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NornClientError.invalidResponse
        }
        return try await get("api/v1/operations/\(id.pathComponentEncoded)")
    }

    func releases() async throws -> NornReleaseList {
        try await get("api/platform/releases")
    }

	func fleetInventory() async throws -> NornFleetInventory {
		try await get("api/v1/fleet/node-pools")
	}

	func fleetPlans() async throws -> [NornOperation] {
		let result: NornFleetPlanList = try await get("api/v1/fleet/plans")
		return result.plans
	}

	func planFleetCapacity(pool: String, request: NornFleetPlanRequest, idempotencyKey: String) async throws -> NornOperation {
		let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !key.isEmpty, key.count <= 200 else { throw NornClientError.invalidIdempotencyKey }
		return try await perform(
			path: "api/v1/fleet/node-pools/\(pool.pathComponentEncoded)/plan",
			method: "POST",
			body: Self.encoder.encode(request),
			idempotencyKey: key
		)
	}

	func fleetReconciliations(planID: String) async throws -> NornFleetReconciliationList {
		let value = planID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { throw NornClientError.invalidResponse }
		return try await get("api/v1/fleet/plans/\(value.pathComponentEncoded)/reconciliations")
	}

	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus {
		try await get("api/v1/fleet/github")
	}

	func createFleetPullRequest(planID: String) async throws -> NornOperation {
		let value = planID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { throw NornClientError.invalidResponse }
		return try await perform(path: "api/v1/fleet/plans/\(value.pathComponentEncoded)/github/pull-request", method: "POST", body: Data("{}".utf8))
	}

	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation {
		struct Body: Encodable { let allowDestructive: Bool }
		let value = planID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { throw NornClientError.invalidResponse }
		return try await perform(path: "api/v1/fleet/plans/\(value.pathComponentEncoded)/github/dispatch", method: "POST", body: Self.encoder.encode(Body(allowDestructive: allowDestructive)))
	}

	func deployments() async throws -> [NornDeployment] {
		try await get("api/deployments")
	}

	func deploymentSteps(deploymentID: String) async throws -> [NornDeploymentStep] {
		let value = deploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { throw NornClientError.invalidResponse }
		let result: NornDeploymentStepList = try await get("api/deployments/\(value.pathComponentEncoded)/steps")
		return result.steps
	}

	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt {
		try await perform(path: "api/v1/apps", method: "POST", body: Self.encoder.encode(request))
	}

	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt {
		struct Body: Encodable { let enabled: Bool }
		return try await perform(path: "api/v1/apps/\(app.pathComponentEncoded)/deployment", method: "PUT", body: Self.encoder.encode(Body(enabled: enabled)))
	}

	func appSnapshots(app: String) async throws -> [NornAppSnapshot] {
		try await get("api/v1/apps/\(app.pathComponentEncoded)/snapshots")
	}

	func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation {
		let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !key.isEmpty, key.count <= 200 else { throw NornClientError.invalidIdempotencyKey }
		struct Confirmation: Encodable { let confirm = true }
		struct Retention: Encodable { let keep: Int; let confirm = true }
		struct Migration: Encodable { let ref: String; let confirm = true }
		struct Rollback: Encodable { let regions: [String]; let confirm = true }
		switch request {
		case let .snapshot(app):
			return try await queue(path: "api/v1/apps/\(app.pathComponentEncoded)/snapshots", body: EmptyRequest(), idempotencyKey: key)
		case let .pruneSnapshots(app, keep):
			return try await queue(path: "api/v1/apps/\(app.pathComponentEncoded)/snapshots/retention", body: Retention(keep: keep), idempotencyKey: key)
		case let .restoreSnapshot(app, snapshot):
			return try await queue(path: "api/v1/apps/\(app.pathComponentEncoded)/snapshots/\(snapshot.pathComponentEncoded)/restore", body: Confirmation(), idempotencyKey: key)
		case let .migrate(app, ref):
			return try await queue(path: "api/v1/apps/\(app.pathComponentEncoded)/migrations", body: Migration(ref: ref), idempotencyKey: key)
		case let .rollback(app, regions):
			return try await queue(path: "api/v1/apps/\(app.pathComponentEncoded)/rollbacks", body: Rollback(regions: regions), idempotencyKey: key)
		}
	}

    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation {
        let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 200 else {
            throw NornClientError.invalidIdempotencyKey
        }

        switch request {
        case let .platformPreflight(ref):
            return try await queue(
                path: "api/v1/platform/preflights",
                body: PlatformRequest(ref: ref, mode: nil, drainMode: nil),
                idempotencyKey: key
            )
        case let .platformUpgrade(ref, mode, drainMode):
            return try await queue(
                path: "api/v1/platform/upgrades",
                body: PlatformRequest(ref: ref, mode: mode, drainMode: drainMode),
                idempotencyKey: key
            )
        case let .platformRollback(sha):
            return try await queue(
                path: "api/v1/platform/rollbacks",
                body: RollbackRequest(sha: sha),
                idempotencyKey: key
            )
        case .platformSmoke:
            return try await queue(path: "api/v1/platform/smoke", body: EmptyRequest(), idempotencyKey: key)
        case .hostAssurance:
            return try await queue(path: "api/v1/host/assurances", body: EmptyRequest(), idempotencyKey: key)
        }
    }

    nonisolated func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error> {
        AsyncThrowingStream { continuation in
            let connection = EventConnection()
            let receiveTask = Task {
                await self.receiveEvents(after: cursor, continuation: continuation, connection: connection)
            }
            continuation.onTermination = { @Sendable _ in
                connection.cancel()
                receiveTask.cancel()
            }
        }
    }

    private func get<Value: Decodable>(_ path: String) async throws -> Value {
        try await perform(path: path, method: "GET")
    }

    private func queue<Body: Encodable>(
        path: String,
        body: Body,
        idempotencyKey: String
    ) async throws -> NornOperation {
        try await perform(path: path, method: "POST", body: Self.encoder.encode(body), idempotencyKey: idempotencyKey)
    }

    private func perform<Value: Decodable>(
        path: String,
        method: String,
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Value {
        try await perform(url: url(path: path), method: method, body: body, idempotencyKey: idempotencyKey)
    }

    private func perform<Value: Decodable>(
        url: URL,
        method: String,
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Value {
        var request = try await authorizedRequest(url: url, method: method)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NornClientError.transport(message: Self.transportMessage(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw NornClientError.invalidResponse
        }
        guard 200 ... 299 ~= http.statusCode else {
            throw Self.httpError(response: http, body: data)
        }
        do {
            return try Self.decoder.decode(Value.self, from: data)
        } catch {
            throw NornClientError.decoding(message: String(describing: error))
        }
    }

    private func receiveEvents(
        after cursor: Int64?,
        continuation: AsyncThrowingStream<NornControlEvent, Error>.Continuation,
        connection: EventConnection
    ) async {
        do {
            let request = try await eventRequest(after: cursor)
            let socket = session.webSocketTask(with: request)
            connection.install(socket)
            socket.resume()
            defer {
                connection.clear(socket)
                socket.cancel(with: .normalClosure, reason: nil)
            }

            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .data(value):
                    data = value
                case let .string(value):
                    guard let encoded = value.data(using: .utf8) else {
                        throw NornClientError.unsupportedWebSocketMessage
                    }
                    data = encoded
                @unknown default:
                    throw NornClientError.unsupportedWebSocketMessage
                }
                do {
                    continuation.yield(try Self.decoder.decode(NornControlEvent.self, from: data))
                } catch let error as NornClientError {
                    throw error
                } catch {
                    throw NornClientError.decoding(message: String(describing: error))
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            // The caller retains the last event ID and can create a new stream to replay.
            continuation.finish(throwing: Self.normalizeStreamError(error))
        }
    }

    /// Internal contract seam: event authentication is verified without opening a socket.
    func eventRequest(after cursor: Int64?) async throws -> URLRequest {
        var components = URLComponents(url: try url(path: "api/v1/events"), resolvingAgainstBaseURL: false)
        if let cursor, cursor >= 0 {
            components?.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        }
        guard let endpoint = components?.url else {
            throw NornClientError.invalidBaseURL
        }
        return try await authorizedRequest(url: Self.webSocketURL(from: endpoint), method: "GET")
    }

    private func authorizedRequest(url: URL, method: String) async throws -> URLRequest {
        guard let credential = try await credentialVault.credential(for: profile.credentialID) else {
            throw NornClientError.missingCredential
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func url(path: String) throws -> URL {
        guard !path.hasPrefix("/") else {
            throw NornClientError.invalidBaseURL
        }
        return profile.baseURL.appendingPathComponent(path)
    }

    nonisolated static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    nonisolated static func webSocketURL(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components?.url ?? url
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let withFractionalSeconds = ISO8601DateFormatter()
            withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractionalSeconds.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date.")
        }
        return decoder
    }()

    private nonisolated static func httpError(response: HTTPURLResponse, body: Data) -> NornClientError {
        let message = (try? decoder.decode(ErrorPayload.self, from: body))?.error
        return .http(
            status: response.statusCode,
            message: message,
            requestID: response.value(forHTTPHeaderField: "X-Request-ID")
        )
    }

    private nonisolated static func transportMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return nsError.localizedDescription.isEmpty ? "network request failed" : nsError.localizedDescription
    }

    private nonisolated static func normalizeStreamError(_ error: Error) -> NornClientError {
        if let nornError = error as? NornClientError {
            return nornError
        }
        return .transport(message: transportMessage(error))
    }
}

nonisolated private struct ErrorPayload: Decodable {
    let error: String?
}

nonisolated private struct PlatformRequest: Encodable {
    let ref: String
    let mode: String?
    let drainMode: String?
}

nonisolated private struct RollbackRequest: Encodable {
    let sha: String
}

nonisolated private struct EmptyRequest: Encodable {}

/// Allows an `AsyncThrowingStream` cancellation handler to promptly close a
/// socket even while its receive loop is suspended.
nonisolated private final class EventConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var cancelled = false

    func install(_ socket: URLSessionWebSocketTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            if cancelled { return true }
            self.socket = socket
            return false
        }
        if shouldCancel {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func clear(_ socket: URLSessionWebSocketTask) {
        lock.withLock {
            guard self.socket === socket else { return }
            self.socket = nil
        }
    }

    func cancel() {
        let socket = lock.withLock { () -> URLSessionWebSocketTask? in
            cancelled = true
            let activeSocket = self.socket
            self.socket = nil
            return activeSocket
        }
        socket?.cancel(with: .goingAway, reason: nil)
    }
}

private extension String {
    var pathComponentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
