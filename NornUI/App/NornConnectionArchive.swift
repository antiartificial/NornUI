import Foundation

/// A portable connection list. Authentication remains in this Mac's Keychain.
nonisolated struct NornConnectionArchive: Codable, Sendable {
    static let maximumBytes = 1_048_576
    static let maximumConnections = 200

    struct Connection: Codable, Sendable {
        var name: String
        var baseURL: URL
    }

    var format = "nornui.connections"
    var version = 1
    var connections: [Connection]

    static func encode(_ profiles: [NornServerProfile]) throws -> Data {
        let archive = Self(connections: profiles.map { Connection(name: $0.name, baseURL: $0.baseURL) })
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        let archive: Self
        do { archive = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ArchiveError.invalidFile }
        try archive.validate()
        return archive
    }

    private func validate() throws {
        guard format == "nornui.connections", version == 1 else { throw ArchiveError.unsupportedVersion }
        guard connections.count <= Self.maximumConnections else { throw ArchiveError.tooManyConnections }
        for connection in connections {
            let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  connection.baseURL.absoluteString.utf8.count <= 4_096,
                  !(connection.baseURL.host ?? "").isEmpty,
                  NornClient.isAllowedBaseURL(connection.baseURL),
                  connection.baseURL.port.map({ (1...65535).contains($0) }) ?? true
            else { throw ArchiveError.invalidConnection }
        }
    }

    /// Treat a default port and a trailing root slash as the same endpoint.
    static func endpointKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? url.absoluteString
    }

    enum ArchiveError: LocalizedError {
        case tooLarge, tooManyConnections, invalidFile, unsupportedVersion, invalidConnection
        var errorDescription: String? {
            switch self {
            case .tooLarge: "The connection file must be smaller than 1 MB."
            case .tooManyConnections: "A connection file can contain up to 200 connections."
            case .invalidFile: "This is not a valid NornUI connection file."
            case .unsupportedVersion: "This connection file uses an unsupported format or version."
            case .invalidConnection: "Each connection needs a name and a valid HTTPS address (or HTTP on localhost), without credentials or query parameters."
            }
        }
    }
}

nonisolated struct NornConnectionImportResult: Sendable {
    var importedCount: Int
    var skippedCount: Int
    var summary: String {
        "Imported \(importedCount) connection\(importedCount == 1 ? "" : "s"). \(skippedCount) already saved. Add an access token or pair each new connection before connecting."
    }
}
