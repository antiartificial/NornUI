import Foundation
import XCTest
@testable import NornUI

final class NornReleaseNamingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testDisplayVersionWinsWhenServerProvidesIt() {
        let release = makeRelease(
            sha: String(repeating: "a", count: 40),
            version: "platform-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            displayVersion: "v2.21.0-platform-2-gaaaaaaa"
        )

        XCTAssertEqual(release.displayLabel(in: [release]), "v2.21.0-platform-2-gaaaaaaa")
    }

    func testEmbeddedSemanticVersionDropsArtifactPrefix() {
        let release = makeRelease(
            sha: String(repeating: "b", count: 40),
            version: "platform-v2.14.1-platform-34-gbbbbbbb"
        )

        XCTAssertEqual(release.displayLabel(in: [release]), "v2.14.1-platform-34-gbbbbbbb")
    }

    func testLegacyArtifactUsesProvenSemanticAncestorWithoutInventingDistance() {
        let ancestorSHA = String(repeating: "c", count: 40)
        let releaseSHA = String(repeating: "d", count: 40)
        let ancestor = makeRelease(
            sha: ancestorSHA,
            version: "v2.20.0-control-1-gccccccc"
        )
        let release = makeRelease(
            sha: releaseSHA,
            version: "platform-\(ancestorSHA)-1-gddddddd"
        )

        XCTAssertEqual(
            release.displayLabel(in: [release, ancestor]),
            "v2.20.0-platform · dddddddd"
        )
    }

    func testControlTagUsesPlatformHistoryConvention() {
        let release = makeRelease(
            sha: String(repeating: "f", count: 40),
            version: "v2.20.0-control-15-gfffffff"
        )

        XCTAssertEqual(release.displayLabel(in: [release]), "v2.20.0-platform-15-gfffffff")
    }

    func testDuplicateImportedReceiptCanFollowSiblingLegacyChain() {
        let ancestorSHA = String(repeating: "1", count: 40)
        let releaseSHA = String(repeating: "2", count: 40)
        let ancestor = makeRelease(sha: ancestorSHA, version: "v2.20.0-control")
        let described = makeRelease(
            sha: releaseSHA,
            version: "platform-\(ancestorSHA)-1-g2222222"
        )
        let imported = makeRelease(
            sha: releaseSHA,
            version: "platform-\(releaseSHA)"
        )

        XCTAssertEqual(
            imported.displayLabel(in: [imported, described, ancestor]),
            "v2.20.0-platform · 22222222"
        )
    }

    func testStandaloneLegacyArtifactFallsBackSafely() {
        let release = makeRelease(
            sha: String(repeating: "e", count: 40),
            version: "platform-\(String(repeating: "e", count: 40))"
        )

        XCTAssertEqual(release.displayLabel(in: [release]), "Platform eeeeeeee")
    }

    func testCanonicalHistoryCollapsesReceiptsBySHAAndPreservesCurrentDescription() {
        let sha = String(repeating: "a", count: 40)
        let imported = NornRelease(
            sha: sha,
            version: "platform-\(sha)",
            createdAt: date.addingTimeInterval(120),
            path: "/releases/\(sha)",
            current: false
        )
        let activated = NornRelease(
            sha: sha.uppercased(),
            version: "v2.21.0-platform-3-gaaaaaaa",
            createdAt: date,
            path: "/releases/\(sha)",
            current: true
        )

        let history = NornRelease.canonicalHistory([imported, activated])

        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history[0].current)
        XCTAssertEqual(history[0].version, "v2.21.0-platform-3-gaaaaaaa")
        XCTAssertEqual(history[0].createdAt, imported.createdAt)
    }

    func testCanonicalHistorySortsNewestToOldestWithStableTies() {
        let oldest = makeRelease(sha: String(repeating: "1", count: 40), version: "v2.20.0-platform")
        var newestB = makeRelease(sha: String(repeating: "b", count: 40), version: "v2.21.0-platform-2")
        newestB.createdAt = date.addingTimeInterval(60)
        var newestA = makeRelease(sha: String(repeating: "a", count: 40), version: "v2.21.0-platform-1")
        newestA.createdAt = date.addingTimeInterval(60)

        let history = NornRelease.canonicalHistory([oldest, newestA, newestB])

        XCTAssertEqual(history.map(\.sha), [newestB.sha, newestA.sha, oldest.sha])
    }

    private func makeRelease(
        sha: String,
        version: String,
        displayVersion: String? = nil
    ) -> NornRelease {
        NornRelease(
            sha: sha,
            version: version,
            createdAt: date,
            path: "/releases/\(sha)",
            current: false,
            displayVersion: displayVersion
        )
    }
}
