import Foundation

/// Requested scopes are derived from the selected authority's public
/// capability document. The returned credential remains the source of truth
/// for every action gate after enrollment.
enum NornEnrollmentScopes {
    static func requested(
        capabilities: NornCapabilities?,
        requestsAPIWrite: Bool,
        requestsPlatformOperations: Bool,
        requestsHostOperations: Bool,
        requestsFleetOperations: Bool,
        requestsTerminalSessions: Bool
    ) -> [String] {
        guard capabilities?.isFleetAuthorityOnly != true else {
            return requestsAPIWrite ? ["api:read", "api:write"] : ["api:read"]
        }

        var scopes = ["api:read", "events:read"]
        if requestsAPIWrite || requestsFleetOperations { scopes.append("api:write") }
        if requestsPlatformOperations { scopes.append("platform:operate") }
        if requestsHostOperations { scopes.append("host:operate") }
        if requestsTerminalSessions { scopes.append("apps:exec") }
        return scopes
    }
}
