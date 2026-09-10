import Foundation

nonisolated struct AppDeploymentRecency {
    let latestByApp: [String: NornDeployment]

    private let activityDates: [String: Date]

    init(deployments: [NornDeployment], operations: [NornOperation] = []) {
        latestByApp = deployments.reduce(into: [:]) { result, deployment in
            if let current = result[deployment.app] {
                let date = deployment.finishedAt ?? deployment.startedAt
                let currentDate = current.finishedAt ?? current.startedAt
                guard date > currentDate || (date == currentDate && deployment.id > current.id) else { return }
            }
            result[deployment.app] = deployment
        }
        var dates = latestByApp.mapValues { $0.finishedAt ?? $0.startedAt }
        for operation in operations where operation.status.isActive && operation.kind.localizedCaseInsensitiveContains("deploy") {
            guard let app = operation.app, !app.isEmpty else { continue }
            dates[app] = max(dates[app] ?? .distantPast, operation.startedAt)
        }
        activityDates = dates
    }

    func precedes(_ left: String, _ right: String, ascending: Bool = false, leftTie: String? = nil, rightTie: String? = nil) -> Bool {
        let lhs = activityDates[left]
        let rhs = activityDates[right]
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs: return ascending ? lhs < rhs : lhs > rhs
        case (_?, nil): return true
        case (nil, _?): return false
        default: return (leftTie ?? left).localizedStandardCompare(rightTie ?? right) == .orderedAscending
        }
    }
}
