import CryptoKit
import Foundation
import Security

nonisolated enum NornDeviceIdentityProtection: String, Codable, Hashable, Sendable {
    case secureEnclave
    case keychain
}

nonisolated struct NornDeviceIdentity: Hashable, Sendable {
    let publicKey: String
    let protection: NornDeviceIdentityProtection
}

nonisolated protocol NornDeviceIdentityVault: Sendable {
    func identity(for identifier: String) async throws -> NornDeviceIdentity
    func removeIdentity(for identifier: String) async throws
}

nonisolated enum NornDeviceIdentityVaultError: LocalizedError, Sendable, Equatable {
    case invalidIdentifier
    case invalidKeyMaterial
    case accessControlUnavailable
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "The device identity identifier is invalid."
        case .invalidKeyMaterial:
            "The saved device identity could not be opened. Re-enroll this Mac."
        case .accessControlUnavailable:
            "The Mac could not create protected device-key access control."
        case let .unexpectedStatus(status):
            "Keychain could not complete the device identity request (status \(status))."
        }
    }
}

/// Stores a per-profile signing identity device-only. Apple silicon uses the
/// Secure Enclave when available; other Macs fall back to a software P-256 key
/// protected by the login Keychain. The private key is never exposed to views or
/// network code.
actor KeychainDeviceIdentityVault: NornDeviceIdentityVault {
    private enum Encoding: UInt8 {
        case secureEnclave = 1
        case software = 2
    }

    private let service: String

    init(service: String = "com.antiartificial.NornUI.device-identity") {
        self.service = service
    }

    func identity(for identifier: String) throws -> NornDeviceIdentity {
        let account = try validatedIdentifier(identifier)
        if let saved = try load(account: account) {
            return try decode(saved)
        }

        let generated = try generate()
        try store(generated.data, account: account)
        return generated.identity
    }

    func removeIdentity(for identifier: String) throws {
        let account = try validatedIdentifier(identifier)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NornDeviceIdentityVaultError.unexpectedStatus(status)
        }
    }

    private func generate() throws -> (data: Data, identity: NornDeviceIdentity) {
        if SecureEnclave.isAvailable,
           let accessControl = SecAccessControlCreateWithFlags(
               nil,
               kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
               [.privateKeyUsage],
               nil
           ),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl) {
            return (
                Data([Encoding.secureEnclave.rawValue]) + key.dataRepresentation,
                identity(publicKey: key.publicKey.x963Representation, protection: .secureEnclave)
            )
        }

        let key = P256.Signing.PrivateKey()
        return (
            Data([Encoding.software.rawValue]) + key.rawRepresentation,
            identity(publicKey: key.publicKey.x963Representation, protection: .keychain)
        )
    }

    private func decode(_ data: Data) throws -> NornDeviceIdentity {
        guard let first = data.first,
              let encoding = Encoding(rawValue: first),
              data.count > 1 else {
            throw NornDeviceIdentityVaultError.invalidKeyMaterial
        }
        let payload = Data(data.dropFirst())
        do {
            switch encoding {
            case .secureEnclave:
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: payload)
                return identity(publicKey: key.publicKey.x963Representation, protection: .secureEnclave)
            case .software:
                let key = try P256.Signing.PrivateKey(rawRepresentation: payload)
                return identity(publicKey: key.publicKey.x963Representation, protection: .keychain)
            }
        } catch {
            throw NornDeviceIdentityVaultError.invalidKeyMaterial
        }
    }

    private func identity(publicKey: Data, protection: NornDeviceIdentityProtection) -> NornDeviceIdentity {
        let encoded = publicKey.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NornDeviceIdentity(publicKey: encoded, protection: protection)
    }

    private func load(account: String) throws -> Data? {
        let query = baseQuery(account: account).merging([
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw NornDeviceIdentityVaultError.invalidKeyMaterial
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw NornDeviceIdentityVaultError.unexpectedStatus(status)
        }
    }

    private func store(_ data: Data, account: String) throws {
        let query = baseQuery(account: account).merging([
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NornDeviceIdentityVaultError.unexpectedStatus(status)
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
            throw NornDeviceIdentityVaultError.invalidIdentifier
        }
        return trimmed
    }
}
