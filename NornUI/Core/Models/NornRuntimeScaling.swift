import Foundation

nonisolated struct NornRuntimeScaleTarget: Hashable, Sendable {
    var process: String
    var count: Int
}

nonisolated enum NornRuntimeScaling {
    static func unavailableReason(for app: NornAppStatus) -> String? {
        guard let processes = app.spec.processes, !processes.isEmpty else { return "No process configuration is available." }
        if app.spec.regions != nil || processes.values.contains(where: { $0.regions?.isEmpty == false }) {
            return "This server’s scaling control cannot select a region. Regional apps require region-aware controls."
        }
        if processes.values.contains(where: { $0.schedule?.isEmpty == false || $0.function != nil }) {
            return "Scheduled jobs and on-demand functions use separate lifecycle controls."
        }
        guard app.nomadStatus != nil else { return "No scheduler job has been reported for this app." }
        return nil
    }

    static func eligibleProcesses(for app: NornAppStatus) -> [String] {
        guard unavailableReason(for: app) == nil else { return [] }
        return (app.spec.processes ?? [:]).keys.sorted()
    }

    static func maxCount(for app: NornAppStatus, process: String) -> Int {
        guard let spec = app.spec.processes?[process] else { return 0 }
        if spec.singleton == true || (spec.hostPort ?? 0) > 0 { return 1 }
        return min(999, max(1, spec.scaling?.max ?? 999))
    }

    /// Suggested restart capacity, not an assertion about the scheduler's current target.
    static func targets(for app: NornAppStatus) -> [NornRuntimeScaleTarget] {
        eligibleProcesses(for: app).map { process in
            let scaling = app.spec.processes?[process]?.scaling
            let configured = (scaling?.perRegion ?? 0) > 0 ? scaling!.perRegion! : max(1, scaling?.min ?? 1)
            return .init(process: process, count: min(configured, maxCount(for: app, process: process)))
        }
    }

    static func isValid(_ targets: [NornRuntimeScaleTarget], for app: NornAppStatus) -> Bool {
        let processes = eligibleProcesses(for: app)
        return !targets.isEmpty && Set(targets.map(\.process)).count == targets.count
            && targets.allSatisfy { processes.contains($0.process) && (0...maxCount(for: app, process: $0.process)).contains($0.count) }
    }
}
