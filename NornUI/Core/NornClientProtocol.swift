import Foundation

protocol NornClientProtocol: Sendable {
    func capabilities() async throws -> NornCapabilities
    func hostMetrics() async throws -> NornHostMetrics
    func resourceSuggestions() async throws -> [NornResourceSuggestion]
    func health() async throws -> NornHealth
	func hostStatus() async throws -> NornHostStatus
    func serviceManifest() async throws -> NornServiceManifest
	func apps() async throws -> [NornAppStatus]
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation]
    func operation(id: String) async throws -> NornOperation
    func releases() async throws -> NornReleaseList
	func rotateCredential() async throws -> NornIssuedToken
	func revokeCredential() async throws
	func fleetInventory() async throws -> NornFleetInventory
	func fleetPlans() async throws -> [NornOperation]
	func planFleetCapacity(pool: String, request: NornFleetPlanRequest, idempotencyKey: String) async throws -> NornOperation
	func fleetReconciliations(planID: String) async throws -> NornFleetReconciliationList
	func fleetRunnerAttempts(planID: String) async throws -> NornFleetRunnerAttemptList
	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus
	func createFleetPullRequest(planID: String) async throws -> NornOperation
	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation
	func deployments() async throws -> [NornDeployment]
	func deploymentSteps(deploymentID: String) async throws -> [NornDeploymentStep]
	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt
	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt
	func releaseQualifications(app: String) async throws -> [NornReleaseQualification]
	func preflightRelease(app: String, request: NornReleaseActionRequest, idempotencyKey: String) async throws -> NornOperation
	func deployRelease(app: String, request: NornReleaseActionRequest, idempotencyKey: String) async throws -> NornOperation
	func qualifyRelease(app: String, deploymentID: String, idempotencyKey: String) async throws -> NornReleaseQualification
	func promoteRelease(app: String, request: NornReleasePromotionRequest, idempotencyKey: String) async throws -> NornOperation
	/// Compatibility runtime observability. This is intentionally separate from
	/// durable app operations because the server streams the current Nomad logs.
	func appLogs(app: String) async throws -> String
	/// Compatibility runtime control. Restarts active Nomad allocations directly
	/// and does not create a durable operation receipt.
	func restartApp(app: String) async throws
    func scaleApp(app: String, process: String, count: Int) async throws
	func appSnapshots(app: String) async throws -> [NornAppSnapshot]
	func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation
    func eventStreamInfo() async throws -> NornEventStreamInfo
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error>
}

extension NornClientProtocol {
	func resourceSuggestions() async throws -> [NornResourceSuggestion] { [] }
	func rotateCredential() async throws -> NornIssuedToken { throw NornClientError.invalidResponse }
	func revokeCredential() async throws { throw NornClientError.invalidResponse }
	func hostStatus() async throws -> NornHostStatus { throw NornClientError.invalidResponse }
	func apps() async throws -> [NornAppStatus] { [] }
	func fleetInventory() async throws -> NornFleetInventory { .unconfigured }
	func fleetPlans() async throws -> [NornOperation] { [] }
	func planFleetCapacity(pool: String, request: NornFleetPlanRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func fleetReconciliations(planID: String) async throws -> NornFleetReconciliationList {
		.init(schemaVersion: "norn.fleet-reconciliation/v1", planID: planID, reconciliations: [], count: 0)
	}
	func fleetRunnerAttempts(planID: String) async throws -> NornFleetRunnerAttemptList {
		.init(schemaVersion: "norn.fleet-runner-attempt/v1", planID: planID, attempts: [], count: 0, serverTime: .now)
	}
	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus { .unconfigured }
	func createFleetPullRequest(planID: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func deployments() async throws -> [NornDeployment] { [] }
	func deploymentSteps(deploymentID: String) async throws -> [NornDeploymentStep] { [] }
	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt { throw NornClientError.invalidResponse }
	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt { throw NornClientError.invalidResponse }
	func releaseQualifications(app: String) async throws -> [NornReleaseQualification] { [] }
	func preflightRelease(app: String, request: NornReleaseActionRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func deployRelease(app: String, request: NornReleaseActionRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func qualifyRelease(app: String, deploymentID: String, idempotencyKey: String) async throws -> NornReleaseQualification { throw NornClientError.invalidResponse }
	func promoteRelease(app: String, request: NornReleasePromotionRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func appLogs(app: String) async throws -> String { throw NornClientError.invalidResponse }
	func restartApp(app: String) async throws { throw NornClientError.invalidResponse }
    func scaleApp(app: String, process: String, count: Int) async throws { throw NornClientError.invalidResponse }
	func appSnapshots(app: String) async throws -> [NornAppSnapshot] { [] }
	func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func eventStreamInfo() async throws -> NornEventStreamInfo { throw NornClientError.invalidResponse }
}
