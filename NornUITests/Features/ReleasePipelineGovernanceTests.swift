import XCTest
@testable import NornUI

final class ReleasePipelineGovernanceTests: XCTestCase {
    func testDeliveryNeverPresentsManualStagingOrProductionMutations() {
        XCTAssertFalse(ReleasePipelineFeaturePolicy.permitsManualMutation(in: "staging"))
        XCTAssertFalse(ReleasePipelineFeaturePolicy.permitsManualMutation(in: "production"))
        XCTAssertFalse(ReleasePipelineFeaturePolicy.permitsManualMutation(in: "development"))
    }
}
