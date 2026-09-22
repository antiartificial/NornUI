import Foundation

/// Client-side DigitalOcean size catalog + platform policy for the Fleet Builder.
///
/// This is the design-time stand-in for a future server `/api/v1/fleet/plan` endpoint
/// (Phase C). The web client mirrors these exact values so both platforms validate and
/// cost a fleet identically. Keep values in sync with `v2/ui/src/lib/fleetCatalog.ts`.
nonisolated enum FleetCatalog {
    nonisolated struct Size: Sendable, Hashable, Identifiable {
        let slug: String
        let vcpu: Int
        let memGB: Int
        let usdMonthly: Int
        var id: String { slug }
        var specLabel: String { "\(vcpu)vcpu / \(memGB)gb" }
    }

    /// Self-managed droplet sizes (control, app, self-run DB, cache/queue nodes).
    static let nodeSizes: [Size] = [
        Size(slug: "s-2vcpu-4gb", vcpu: 2, memGB: 4, usdMonthly: 24),
        Size(slug: "s-4vcpu-8gb", vcpu: 4, memGB: 8, usdMonthly: 48),
        Size(slug: "g-2vcpu-8gb", vcpu: 2, memGB: 8, usdMonthly: 63),
        Size(slug: "g-4vcpu-16gb", vcpu: 4, memGB: 16, usdMonthly: 126),
        Size(slug: "s-8vcpu-16gb", vcpu: 8, memGB: 16, usdMonthly: 96),
    ]

    /// DigitalOcean Managed Database sizes.
    static let managedSizes: [Size] = [
        Size(slug: "db-s-1vcpu-2gb", vcpu: 1, memGB: 2, usdMonthly: 15),
        Size(slug: "db-s-2vcpu-4gb", vcpu: 2, memGB: 4, usdMonthly: 60),
        Size(slug: "db-s-4vcpu-8gb", vcpu: 4, memGB: 8, usdMonthly: 120),
        Size(slug: "db-s-6vcpu-16gb", vcpu: 6, memGB: 16, usdMonthly: 240),
        Size(slug: "db-s-8vcpu-32gb", vcpu: 8, memGB: 32, usdMonthly: 480),
        Size(slug: "db-s-16vcpu-64gb", vcpu: 16, memGB: 64, usdMonthly: 960),
    ]

    /// DigitalOcean regions that offer Spaces (needed for state + WAL backup).
    static let spacesRegions: Set<String> = ["nyc3", "sfo3", "ams3", "sgp1", "fra1", "syd1", "blr1"]

    /// Regions offered in the builder's region pickers.
    static let regionOptions: [String] = ["nyc3", "sfo3", "fra1", "tor1"]
    static let secondRegionDefault = "sfo3"

    static let lbMonthly = 12
    static let spacesMonthly = 5

    // Co-located role minimums (the tested floor for each role).
    static let controlMinVCPU = 2, controlMinMemGB = 4
    static let appMinVCPU = 1, appMinMemGB = 2
    static let dbSelfMinVCPU = 2, dbSelfMinMemGB = 8

    static func node(_ slug: String) -> Size? { nodeSizes.first { $0.slug == slug } }
    static func managed(_ slug: String) -> Size? { managedSizes.first { $0.slug == slug } }
    static func any(_ slug: String) -> Size? { node(slug) ?? managed(slug) }

    static func hasSpaces(_ region: String) -> Bool { spacesRegions.contains(region) }
}
