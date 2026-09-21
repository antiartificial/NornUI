import XCTest
@testable import NornUI

@MainActor
final class NornConnectionArchiveTests: XCTestCase {
    func testExportContainsOnlyPortableFields() throws {
        let profile = NornServerProfile(name: "Mini", baseURL: URL(string: "https://mini.example")!, credentialID: "secret-keychain-id", deviceID: "device-id", tokenID: "token-id", grantedScopes: ["admin"])
        let data = try NornConnectionArchive.encode([profile])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), ["name", "baseURL"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-keychain-id"))
        XCTAssertEqual(try NornConnectionArchive.decode(data).connections.first?.name, "Mini")
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
            NornServerProfile(name: "Pilot", baseURL: URL(string: "https://pilot.example")!),
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
