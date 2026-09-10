import Foundation

protocol NornEnrollmentClientProtocol: Sendable {
    func capabilities() async throws -> NornCapabilities
    func start(_ request: NornEnrollmentStartRequest) async throws -> NornEnrollmentSession
    func exchange(_ session: NornEnrollmentSession) async throws -> NornIssuedToken
}

extension NornEnrollmentClientProtocol {
    func capabilities() async throws -> NornCapabilities { throw NornEnrollmentClientError.invalidResponse }
}

nonisolated enum NornEnrollmentClientError: LocalizedError, Sendable, Equatable {
    case awaitingApproval
    case expired
    case invalidBaseURL
    case invalidResponse
    case http(status: Int, code: String?, message: String?, requestID: String?)
    case decoding(message: String)
    case transport(message: String)

    var errorDescription: String? {
        switch self {
        case .awaitingApproval:
            return "Waiting for an administrator to approve the pairing code."
        case .expired:
            return "The pairing code expired. Start a new enrollment."
        case .invalidBaseURL:
            return "Device pairing requires HTTPS, or HTTP on a direct loopback address."
        case .invalidResponse:
            return "Norn returned an invalid enrollment response."
        case let .http(status, code, message, requestID):
            let detail = message.map { ": \($0)" } ?? ""
            let stableCode = code.map { " [\($0)]" } ?? ""
            let request = requestID.map { " (request \($0))" } ?? ""
            return "Norn enrollment failed (HTTP \(status))\(stableCode)\(detail)\(request)"
        case let .decoding(message):
            return "Norn returned enrollment data the app could not read: \(message)"
        case let .transport(message):
            return "Norn could not be reached for enrollment: \(message)"
        }
    }
}

/// Unauthenticated transport used only for the short-lived pairing start and
/// verifier exchange. Administrator approval remains a separate authenticated
/// action, and all requests require the same trusted URL policy as NornClient.
actor NornEnrollmentClient: NornEnrollmentClientProtocol {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) throws {
        guard NornClient.isAllowedBaseURL(baseURL) else {
            throw NornEnrollmentClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    func start(_ request: NornEnrollmentStartRequest) async throws -> NornEnrollmentSession {
        try await perform(
            path: "api/v1/enrollments",
            body: try Self.encode(request),
            expectedStatus: 201
        )
    }

    /// Capabilities are deliberately public so pairing can request only the
    /// scopes a selected authority accepts, before a credential exists.
    func capabilities() async throws -> NornCapabilities {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/capabilities"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NornEnrollmentClientError.transport(message: (error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NornEnrollmentClientError.invalidResponse
        }
        do {
            return try Self.decode(NornCapabilities.self, from: data)
        } catch {
            throw NornEnrollmentClientError.decoding(message: String(describing: error))
        }
    }

    func exchange(_ enrollment: NornEnrollmentSession) async throws -> NornIssuedToken {
        guard Date.now < enrollment.expiresAt else {
            throw NornEnrollmentClientError.expired
        }
        struct ExchangeRequest: Encodable { let verifier: String }
        do {
            return try await perform(
                path: "api/v1/enrollments/\(enrollment.id.pathComponentEncoded)/exchange",
                body: try Self.encode(ExchangeRequest(verifier: enrollment.verifier)),
                expectedStatus: 200
            )
        } catch let error as NornEnrollmentClientError {
            if case let .http(status, code, _, _) = error,
               status == 409,
               code == "enrollment_not_approved" {
                throw NornEnrollmentClientError.awaitingApproval
            }
            throw error
        }
    }

    private func perform<Value: Decodable>(
        path: String,
        body: Data,
        expectedStatus: Int
    ) async throws -> Value {
        guard !path.hasPrefix("/") else { throw NornEnrollmentClientError.invalidBaseURL }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NornEnrollmentClientError.transport(message: (error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NornEnrollmentClientError.invalidResponse
        }
        guard http.statusCode == expectedStatus else {
            let problem = try? Self.decode(ProblemPayload.self, from: data)
            throw NornEnrollmentClientError.http(
                status: http.statusCode,
                code: problem?.code,
                message: problem?.detail ?? problem?.error,
                requestID: problem?.requestID ?? http.value(forHTTPHeaderField: "X-Request-ID")
            )
        }
        do {
            return try Self.decode(Value.self, from: data)
        } catch {
            throw NornEnrollmentClientError.decoding(message: String(describing: error))
        }
    }

    private nonisolated static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private nonisolated static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .nornISO8601
        return try decoder.decode(type, from: data)
    }
}

nonisolated private struct ProblemPayload: Decodable {
    let code: String?
    let detail: String?
    let error: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case code, detail, error
        case requestID = "requestId"
    }
}

extension JSONDecoder.DateDecodingStrategy {
    nonisolated static var nornISO8601: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date.")
        }
    }
}

private extension String {
    var pathComponentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
