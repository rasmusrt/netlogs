import Foundation

/// Which host's column a range query reads.
///
/// Named rather than passed as a string so no call site can interpolate an
/// arbitrary column name into SQL, and so "which host" stays the explicit
/// choice it is everywhere else in this app.
public enum PingHostColumn: String, Sendable, CaseIterable {
    case router, internet

    var column: String {
        switch self {
        case .router:   return "router_ms"
        case .internet: return "internet_ms"
        }
    }
}
