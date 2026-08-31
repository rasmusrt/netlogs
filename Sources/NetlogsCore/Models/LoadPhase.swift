import Foundation

/// Which phase of a throughput test the engine is in when a ``PingSample`` is
/// produced. Every sample carries one of these so latency-under-load can be
/// measured against the app's own ping targets (plan §7).
public enum LoadPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case downloading
    case uploading
}
