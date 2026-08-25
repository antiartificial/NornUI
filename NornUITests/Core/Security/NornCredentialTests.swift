import XCTest
@testable import NornUI

final class NornCredentialTests: XCTestCase {
    func testCredentialTrimsWhitespaceWithoutChangingTokenContent() throws {
        let credential = try NornCredential(accessToken: "  token.with.scope  \n")
        XCTAssertEqual(credential.accessToken, "token.with.scope")
    }

    func testCredentialRejectsWhitespaceOnlyTokens() {
        XCTAssertThrowsError(try NornCredential(accessToken: " \n\t ")) { error in
            XCTAssertEqual(error as? NornCredentialVaultError, .invalidCredential)
        }
    }
}
