import Foundation
import XCTest
@testable import NornUI

@MainActor
final class NornClientCrossClientHarnessTests: XCTestCase {
    func testNorn8ASignedCapabilitiesOverLoopback() async throws {
        let coordinationFile = URL(fileURLWithPath: "/tmp/norn-cross-client-capabilities.json")
        guard FileManager.default.fileExists(atPath: coordinationFile.path) else {
            throw XCTSkip("Set by Norn's TestCrossClientCapabilitiesHarness while it hosts the loopback capability endpoint.")
        }
        let coordination = try JSONDecoder().decode(
            CrossClientCoordination.self,
            from: Data(contentsOf: coordinationFile)
        )
        guard let baseURL = URL(string: coordination.baseURL) else {
            return XCTFail("Invalid loopback URL in cross-client coordination file")
        }

        let profile = NornServerProfile(name: "Norn 8a loopback", baseURL: baseURL)
        let client = try NornClient(
            profile: profile,
            credentialVault: CrossClientCredentialVault(token: coordination.validBearer),
            session: URLSession(configuration: .ephemeral)
        )
        let capabilities = try await client.capabilities()

        XCTAssertEqual(capabilities.environment?.id, "staging")
        XCTAssertEqual(capabilities.environment?.profile, "staging")
        XCTAssertEqual(capabilities.authenticatedPrincipal?.subject, "control-plane")
        XCTAssertTrue(capabilities.grantedScopes.contains("admin"))
        XCTAssertTrue(capabilities.features.contains("norn-signed-private-v1"))
        XCTAssertTrue(capabilities.supportsReleasePipeline)
        XCTAssertTrue(capabilities.supportsEventStream)
        XCTAssertTrue(capabilities.supportsFleet)

        let rejected = try NornClient(
            profile: profile,
            credentialVault: CrossClientCredentialVault(token: coordination.wrongBearer),
            session: URLSession(configuration: .ephemeral)
        )
        do {
            _ = try await rejected.capabilities()
            XCTFail("Expected the wrong bearer to be rejected")
        } catch let error as NornClientError {
            guard case .http(let status, _, _) = error else {
                return XCTFail("Wrong bearer error = \(error), want HTTP 401")
            }
            XCTAssertEqual(status, 401)
        }
    }
}

private struct CrossClientCoordination: Decodable {
    let baseURL: String
    let validBearer: String
    let wrongBearer: String
}

private actor CrossClientCredentialVault: NornCredentialVault {
    private let credential: NornCredential

    init(token: String) {
        credential = try! NornCredential(accessToken: token)
    }

    func credential(for identifier: String) -> NornCredential? { credential }
    func store(_ credential: NornCredential, for identifier: String) {}
    func removeCredential(for identifier: String) {}
}
