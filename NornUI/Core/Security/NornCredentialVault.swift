import Foundation
import Security

/// A scoped Norn bearer token. Its value is intentionally not printable or logged.
nonisolated struct NornCredential: Sendable, Equatable {
    let accessToken: String

    init(accessToken: String) throws {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw NornCredentialVaultError.invalidCredential
        }
        self.accessToken = token
    }
}

nonisolated protocol NornCredentialVault: Sendable {
    func credential(for identifier: String) async throws -> NornCredential?
    func store(_ credential: NornCredential, for identifier: String) async throws
    func removeCredential(for identifier: String) async throws
}

nonisolated enum NornCredentialVaultError: LocalizedError, Sendable, Equatable {
    case invalidCredential
    case invalidIdentifier
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "The access token is empty."
        case .invalidIdentifier:
            "The credential identifier is invalid."
        case let .unexpectedStatus(status):
            "Keychain could not complete the credential request (status \(status))."
        }
    }
}

/// Keychain-backed storage for scoped Norn access tokens.
///
/// Tokens are stored device-only and are never written to UserDefaults, disk, or logs.
actor KeychainCredentialVault: NornCredentialVault {
    private let service: String

    init(service: String = "com.antiartificial.NornUI.access-token") {
        self.service = service
    }

    func credential(for identifier: String) throws -> NornCredential? {
        let account = try validatedIdentifier(identifier)
        let query = baseQuery(account: account).merging([
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw NornCredentialVaultError.invalidCredential
            }
            return try NornCredential(accessToken: token)
        case errSecItemNotFound:
            return nil
        default:
            throw NornCredentialVaultError.unexpectedStatus(status)
        }
    }

    func store(_ credential: NornCredential, for identifier: String) throws {
        let account = try validatedIdentifier(identifier)
        let tokenData = Data(credential.accessToken.utf8)
        let query = baseQuery(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: tokenData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NornCredentialVaultError.unexpectedStatus(updateStatus)
        }

        let createQuery = query.merging(attributes) { _, new in new }
        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw NornCredentialVaultError.unexpectedStatus(createStatus)
        }
    }

    func removeCredential(for identifier: String) throws {
        let account = try validatedIdentifier(identifier)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NornCredentialVaultError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    private func validatedIdentifier(_ identifier: String) throws -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NornCredentialVaultError.invalidIdentifier
        }
        return trimmed
    }
}
