import Foundation
import XCTest
@testable import NornUI

final class NornOperationalActivityTests: XCTestCase {
    func testTimelineIncludesReleaseEvidenceWithoutConvertingItToAnOperation() throws {
        let release = NornRelease(
            sha: String(repeating: "a", count: 40),
            version: "v2.22.0-platform-1-gaaaaaaa",
            createdAt: NornFixtures.now.addingTimeInterval(60),
            path: "/releases/aaaaaaaa",
            current: true
        )

        let timeline = NornOperationalActivity.timeline(
            operations: NornFixtures.snapshot.operations,
            releases: [release]
        )
        let activity = try XCTUnwrap(timeline.first)

        XCTAssertEqual(activity.id, "release:\(release.sha)")
        XCTAssertEqual(activity.kind, "platform.release")
        XCTAssertEqual(activity.statusLabel, "Current")
        XCTAssertEqual(activity.elapsedDescription, "Artifact")
        XCTAssertNil(activity.operation)
        XCTAssertEqual(activity.release, release)
    }

    func testTimelineCanonicalizesDuplicateReleaseReceiptsAndKeepsNamespacedIDs() {
        let sha = String(repeating: "b", count: 40)
        let imported = NornRelease(
            sha: sha,
            version: "platform-\(sha)",
            createdAt: NornFixtures.now,
            path: "/releases/\(sha)",
            current: false
        )
        let activated = NornRelease(
            sha: sha.uppercased(),
            version: "v2.22.0-platform-2-gbbbbbbb",
            createdAt: NornFixtures.now.addingTimeInterval(-60),
            path: "/releases/\(sha)",
            current: true
        )

        let timeline = NornOperationalActivity.timeline(
            operations: NornFixtures.snapshot.operations,
            releases: [imported, activated]
        )
        let releaseActivities = timeline.filter { $0.release != nil }
        let operationActivities = timeline.filter { $0.operation != nil }

        XCTAssertEqual(releaseActivities.count, 1)
        XCTAssertEqual(releaseActivities[0].releaseLabel, "v2.22.0-platform-2-gbbbbbbb")
        XCTAssertTrue(releaseActivities[0].release?.current == true)
        XCTAssertTrue(releaseActivities[0].id.hasPrefix("release:"))
        XCTAssertTrue(operationActivities.allSatisfy { $0.id.hasPrefix("operation:") })
    }
}
