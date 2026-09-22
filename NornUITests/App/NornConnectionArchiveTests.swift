import XCTest
@testable import NornUI

@MainActor
final class NornConnectionArchiveTests: XCTestCase {
    func testExportContainsOnlyPortableFields() throws {
        let profile = NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!, credentialID: "secret-keychain-id", deviceID: "device-id", tokenID: "token-id", grantedScopes: ["admin"], connectionHue: .purple)
        let data = try NornConnectionArchive.encode([profile])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), ["name", "baseURL", "connectionHue"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-keychain-id"))
        XCTAssertEqual(try NornConnectionArchive.decode(data).connections.first?.name, "Mini")
        XCTAssertEqual(try NornConnectionArchive.decode(data).connections.first?.connectionHue, .purple)
    }

    func testLegacyProfilesAndArchivesDoNotNeedAColor() throws {
        let original = NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!)
        let decoded = try JSONDecoder().decode(NornServerProfile.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.connectionHue)
        let data = Data(#"{"format":"nornui.connections","version":1,"connections":[{"name":"Mini","baseURL":"https://mini.example"}]}"#.utf8)
        XCTAssertNil(try NornConnectionArchive.decode(data).connections.first?.connectionHue)
    }

    func testUnknownFutureColorKeepsConnectionReadable() throws {
        let data = Data(#"{"format":"nornui.connections","version":1,"connections":[{"name":"Mini","baseURL":"https://mini.example","connectionHue":"future-color"}]}"#.utf8)
        let connection = try XCTUnwrap(NornConnectionArchive.decode(data).connections.first)
        XCTAssertEqual(connection.name, "Mini")
        XCTAssertEqual(connection.connectionHue, .blue)
        let original = NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!, connectionHue: .purple)
        let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
            .replacingOccurrences(of: "purple", with: "future-color")
        let decoded = try JSONDecoder().decode(NornServerProfile.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.credentialID, original.credentialID)
        XCTAssertEqual(decoded.connectionHue, .blue)
    }

    func testChangingColorPreservesCredentialsAndDoesNotReconnect() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        var original = NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!, credentialID: "saved", deviceID: "device", tokenID: "token")
        store.saveProfiles([original])
        store.saveSelection(original.id)
        let model = NornAppModel(profileStore: store)
        model.setConnectionHue(.orange, for: original.id)
        original.connectionHue = .orange
        XCTAssertEqual(model.selectedProfile, original)
        XCTAssertEqual(store.loadProfiles(), [original])
        XCTAssertEqual(model.connectionState, .idle)
        model.setConnectionHue(nil, for: original.id)
        XCTAssertNil(store.loadProfiles().first?.connectionHue)
    }

    func testImportMergesAndPreservesExistingIdentitySelectionAndMetadata() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let existing = NornServerProfile(name: "My Mini", baseURL: URL(string: "https://mini.example")!, credentialID: "existing-key", deviceID: "device", tokenID: "token")
        store.saveProfiles([existing])
        store.saveSelection(existing.id)
        let model = NornAppModel(profileStore: store)
        let incoming = [
            NornServerProfile(name: "Different name", baseURL: URL(string: "https://MINI.example:443/")!),
            NornServerProfile(name: "Pilot", baseURL: URL(string: "https://pilot.example")!, connectionHue: .teal),
            NornServerProfile(name: "Duplicate Pilot", baseURL: URL(string: "https://pilot.example/")!)
        ]
        let result = try model.importConnections(NornConnectionArchive.encode(incoming))
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(model.profiles.first, existing)
        XCTAssertEqual(model.selectedProfileID, existing.id)
        XCTAssertEqual(model.connectionState, .idle)
        let added = try XCTUnwrap(model.profiles.last)
        XCTAssertNotEqual(added.id, incoming[1].id)
        XCTAssertNotEqual(added.credentialID, incoming[1].credentialID)
        XCTAssertEqual(added.connectionHue, .teal)
        XCTAssertNil(added.deviceID)
        XCTAssertEqual(store.loadProfiles(), model.profiles)
    }

    func testImportedIdentityFieldsCannotReuseExistingCredentials() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.removePersistentDomain(forName: #function)
        let store = NornProfileStore(defaults: defaults)
        let existing = NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!)
        store.saveProfiles([existing])
        let model = NornAppModel(profileStore: store)
        let data = try JSONSerialization.data(withJSONObject: ["format": "nornui.connections", "version": 1, "connections": [["name": "Changed", "baseURL": "https://other.example", "id": existing.id.uuidString, "credentialID": existing.credentialID]]])
        _ = try model.importConnections(data)
        XCTAssertEqual(model.profiles.first, existing)
        XCTAssertNotEqual(model.profiles.last?.credentialID, existing.credentialID)
        XCTAssertEqual(model.selectedProfileID, existing.id)
    }

    func testInvalidEntryRejectsEntireImport() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.removePersistentDomain(forName: #function)
        let model = NornAppModel(profileStore: NornProfileStore(defaults: defaults))
        let data = Data(#"{"format":"nornui.connections","version":1,"connections":[{"name":"Valid","baseURL":"https://valid.example"},{"name":"Invalid","baseURL":"http://remote.example"}]}"#.utf8)
        XCTAssertThrowsError(try model.importConnections(data))
        XCTAssertTrue(model.profiles.isEmpty)
    }

    func testRejectsUnsupportedAndOversizedArchivesAndUnsafeURLs() throws {
        XCTAssertThrowsError(try NornConnectionArchive.decode(Data(repeating: 32, count: NornConnectionArchive.maximumBytes + 1)))
        XCTAssertThrowsError(try NornConnectionArchive.decode(Data(#"{"format":"nornui.connections","version":2,"connections":[]}"#.utf8)))
        for address in ["https://token@mini.example", "https://mini.example?token=secret", "https://mini.example#secret", "http://remote.example"] {
            XCTAssertThrowsError(try NornConnectionArchive.encode([NornServerProfile(name: "Mini", baseURL: URL(string: address)!)]))
        }
        let entries = Array(repeating: NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!), count: 201)
        XCTAssertThrowsError(try NornConnectionArchive.encode(entries))
    }
}
