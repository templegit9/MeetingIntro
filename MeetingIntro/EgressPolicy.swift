import Foundation

// The App Store build talks to Microsoft 365 and to a model on this Mac, nothing else.
// Hosts are removed at compile time; this is the runtime backstop for user-editable
// endpoints (a custom AI base URL typed into Settings).
enum EgressPolicy {
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func isLocal(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return localHosts.contains(host)
    }

    static func permits(_ url: URL) -> Bool {
        #if MAS
        guard let host = url.host?.lowercased() else { return false }
        return localHosts.contains(host)
            || host == "graph.microsoft.com"
            || host == "login.microsoftonline.com"
        #else
        return true
        #endif
    }
}
