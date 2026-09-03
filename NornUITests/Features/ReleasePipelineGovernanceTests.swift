import XCTest
@testable import NornUI

final class ReleasePipelineGovernanceTests: XCTestCase {
    func testDeliveryNeverPresentsManualStagingOrProductionMutations() {
        XCTAssertFalse(ReleasePipelineFeaturePolicy.permitsManualMutation(in: "staging"))
        XCTAssertFalse(ReleasePipelineFeaturePolicy.permitsManualMutation(in: "production"))
        XCTAssertFalse(ReleasePipelineFeaturePolicy.permitsManualMutation(in: "development"))
    }

    func testOnlyManagedReleaseEnvironmentsRequireFleetAndSignedEvidence() {
        XCTAssertFalse(ReleasePipelineFeaturePolicy.requiresManagedFleet(in: "development"))
        XCTAssertFalse(ReleasePipelineFeaturePolicy.requiresSignedReleaseEvidence(in: "development"))
        XCTAssertTrue(ReleasePipelineFeaturePolicy.requiresManagedFleet(in: "staging"))
        XCTAssertTrue(ReleasePipelineFeaturePolicy.requiresSignedReleaseEvidence(in: "staging"))
        XCTAssertTrue(ReleasePipelineFeaturePolicy.requiresManagedFleet(in: "production"))
        XCTAssertTrue(ReleasePipelineFeaturePolicy.requiresSignedReleaseEvidence(in: "production"))
    }

    func testSigningBackendLabelsKeepEnterpriseOptional() {
        let common = NornReleaseAttestation(
            mode: "norn-signed-private",
            issuer: "https://token.actions.githubusercontent.com",
            subjectDigest: "sha256:digest",
            materialSHA: "source"
        )
        XCTAssertEqual(common.displayMode, "Norn-signed private")
        var enterprise = common
        enterprise.mode = "github-private"
        XCTAssertEqual(enterprise.displayMode, "GitHub Enterprise private")
    }

    func testProductionGateDoesNotClaimEnvironmentReviewerSupport() {
        XCTAssertEqual(ReleasePipelineFeaturePolicy.productionGateLabel, "Protected tag + Norn gate")
        XCTAssertFalse(ReleasePipelineFeaturePolicy.productionGateLabel.localizedCaseInsensitiveContains("approval"))
    }
}
