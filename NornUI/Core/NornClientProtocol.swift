import Foundation

protocol NornClientProtocol: Sendable {
    func capabilities() async throws -> NornCapabilities
    func hostMetrics() async throws -> NornHostMetrics
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
	func advanceFleetRunnerAttempt(planID: String, attempt: NornFleetRunnerAttempt) async throws -> NornFleetRunnerAttempt
	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus
	func createFleetPullRequest(planID: String) async throws -> NornOperation
	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation
	func deployments() async throws -> [NornDeployment]
	func deploymentSteps(deploymentID: String) async throws -> [NornDeploymentStep]
	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt
	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt
	func appSnapshots(app: String) async throws -> [NornAppSnapshot]
	func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error>
}

extension NornClientProtocol {
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
	func advanceFleetRunnerAttempt(planID: String, attempt: NornFleetRunnerAttempt) async throws -> NornFleetRunnerAttempt { throw NornClientError.invalidResponse }
	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus { .unconfigured }
	func createFleetPullRequest(planID: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func deployments() async throws -> [NornDeployment] { [] }
	func deploymentSteps(deploymentID: String) async throws -> [NornDeploymentStep] { [] }
	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt { throw NornClientError.invalidResponse }
	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt { throw NornClientError.invalidResponse }
	func appSnapshots(app: String) async throws -> [NornAppSnapshot] { [] }
	func queueAppOperation(_ request: NornAppOperationRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
}
