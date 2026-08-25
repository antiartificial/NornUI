import Foundation

protocol NornClientProtocol: Sendable {
    func capabilities() async throws -> NornCapabilities
    func hostMetrics() async throws -> NornHostMetrics
    func health() async throws -> NornHealth
    func serviceManifest() async throws -> NornServiceManifest
	func apps() async throws -> [NornAppStatus]
    func operations(activeOnly: Bool, limit: Int) async throws -> [NornOperation]
    func operation(id: String) async throws -> NornOperation
    func releases() async throws -> NornReleaseList
	func fleetInventory() async throws -> NornFleetInventory
	func fleetPlans() async throws -> [NornOperation]
	func planFleetCapacity(pool: String, request: NornFleetPlanRequest, idempotencyKey: String) async throws -> NornOperation
	func fleetReconciliations(planID: String) async throws -> NornFleetReconciliationList
	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus
	func createFleetPullRequest(planID: String) async throws -> NornOperation
	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation
	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt
	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt
    func queue(_ request: NornMaintenanceRequest, idempotencyKey: String) async throws -> NornOperation
    func events(after cursor: Int64?) -> AsyncThrowingStream<NornControlEvent, Error>
}

extension NornClientProtocol {
	func apps() async throws -> [NornAppStatus] { [] }
	func fleetInventory() async throws -> NornFleetInventory { .unconfigured }
	func fleetPlans() async throws -> [NornOperation] { [] }
	func planFleetCapacity(pool: String, request: NornFleetPlanRequest, idempotencyKey: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func fleetReconciliations(planID: String) async throws -> NornFleetReconciliationList {
		.init(schemaVersion: "norn.fleet-reconciliation/v1", planID: planID, reconciliations: [], count: 0)
	}
	func fleetGitHubStatus() async throws -> NornFleetGitHubStatus { .unconfigured }
	func createFleetPullRequest(planID: String) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func dispatchFleetApply(planID: String, allowDestructive: Bool) async throws -> NornOperation { throw NornClientError.invalidResponse }
	func createApp(_ request: NornCreateAppRequest) async throws -> NornAppMutationReceipt { throw NornClientError.invalidResponse }
	func setAppDeployment(app: String, enabled: Bool) async throws -> NornAppMutationReceipt { throw NornClientError.invalidResponse }
}
