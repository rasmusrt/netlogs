import Foundation

/// How bad a round-trip time is, on a ramp chosen for the leg it describes.
///
/// The thresholds this replaces — 80 / 200 / 500 ms — were chosen during the
/// Phase 9 design-system pass to *tint a log table's rows*, and it showed. Red
/// began at 500 ms, well past the point a call is unusable, so the worst tier
/// arrived late and the orange band did the work of two. Nothing external
/// justified any of the three; they were the only ramp in the app with no
/// provenance, unlike ``BufferbloatGrade`` and the Wi-Fi signal ramp.
///
/// **The one number to trust is 300**: ITU-T G.114 puts the limit for
/// acceptable interactive voice at 150 ms one-way, which is 300 ms round trip.
/// Everything here is that number, apportioned to a leg and then halved twice —
/// the same anchor-and-multiples construction ``JitterGrade`` uses, so moving
/// the anchor moves every ramp coherently instead of stranding arbitrary values
/// beside a considered one.
///
/// One ramp for both hosts was the compromise this replaces. It could not be
/// right for both: G.114's budget is end-to-end, and spending it on the first
/// hop is a category error. Measured over this database's 224,666 router
/// replies the gateway's median is 6.7 ms and its 95th percentile 15.2 — so a
/// 70 ms reply, ten times what that link normally does, was graded "fine",
/// and the ramp fired on 0.03% of samples. It was not judging the gateway; it
/// was ignoring it.
public enum LatencyGrade: Int, Sendable, Equatable, Hashable, Comparable, CaseIterable {
    case fine
    case elevated
    case high
    case severe

    /// The thresholds for one leg of the path.
    ///
    /// A struct rather than a fifth `router | internet` enum. There are already
    /// four — `ProbeHost`, `OutageScope`, `PingHostColumn`, `PingHost` — and
    /// what varies here is the ramp itself, so passing the ramp says at each
    /// call site exactly what a reader needs to know: `on: .gateway`.
    public struct Ramp: Sendable, Equatable, Hashable {
        /// Worth a second look.
        public let elevatedMs: Double
        /// Interactive work is degraded.
        public let highMs: Double
        /// The whole budget for this leg is gone.
        public let severeMs: Double

        public init(elevatedMs: Double, highMs: Double, severeMs: Double) {
            self.elevatedMs = elevatedMs
            self.highMs = highMs
            self.severeMs = severeMs
        }

        /// Past your router: the whole of G.114's 300 ms round trip, because
        /// this figure is the app's stand-in for the end-to-end path.
        ///
        /// Over 224,797 internet replies: 95.9% `.fine`, 3.7% `.elevated`,
        /// 0.24% `.high`, 0.18% `.severe`.
        public static let internet = Ramp(elevatedMs: 75, highMs: 150, severeMs: 300)

        /// The first hop out of this Mac, which gets a fifth of the same
        /// budget — one hop of the many the round trip has to fit into, and
        /// physically the shortest of them.
        ///
        /// A fifth of 300 is 60, halved twice for 30 and 15. That the
        /// construction lands on 15 is worth stating, because the measurement
        /// agrees with it from the other direction: 15.2 ms is this database's
        /// 95th percentile for the gateway, and 15/30/60 leaves 95.0% of
        /// router replies `.fine` — the same shape the internet ramp has, so
        /// a tint still marks exceptions on both hosts rather than painting
        /// one table and abandoning the other.
        public static let gateway = Ramp(elevatedMs: 15, highMs: 30, severeMs: 60)
    }

    /// `on:` is not defaulted on purpose. A default is how one host's ramp
    /// silently graded the other for as long as it did.
    public init(milliseconds: Double, on ramp: Ramp) {
        switch milliseconds {
        case ..<ramp.elevatedMs: self = .fine
        case ..<ramp.highMs:     self = .elevated
        case ..<ramp.severeMs:   self = .high
        default:                 self = .severe
        }
    }

    public var label: String {
        switch self {
        case .fine:     return "fine"
        case .elevated: return "elevated"
        case .high:     return "high"
        case .severe:   return "severe"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How bad jitter is, anchored on the threshold the verdict already judges by.
///
/// Jitter used to be tinted with the latency ramp, whose first step was 80 ms,
/// while `SessionVerdict` calls a session unstable at 30 — so a 50 ms jitter
/// drove an amber verdict in the header while the number itself rendered plain.
/// One quantity cannot have two thresholds.
///
/// `SessionVerdict.jitterThresholdMs` is the only measured number here; the
/// rest double. Move it and the whole ramp moves with it.
public enum JitterGrade: Int, Sendable, Equatable, Hashable, Comparable, CaseIterable {
    case fine
    case elevated
    case high
    case severe

    public static var elevatedMs: Double { SessionVerdict.jitterThresholdMs }
    public static var highMs: Double { elevatedMs * 2 }
    public static var severeMs: Double { elevatedMs * 4 }

    public init(milliseconds: Double) {
        switch milliseconds {
        case ..<Self.elevatedMs: self = .fine
        case ..<Self.highMs:     self = .elevated
        case ..<Self.severeMs:   self = .high
        default:                 self = .severe
        }
    }

    public var label: String {
        switch self {
        case .fine:     return "fine"
        case .elevated: return "elevated"
        case .high:     return "high"
        case .severe:   return "severe"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How bad packet loss is, on the verdict's own two thresholds — so a tint and
/// a headline can never disagree about whether loss is worth reporting.
public enum LossGrade: Int, Sendable, Equatable, Hashable, Comparable, CaseIterable {
    case none
    case lossy
    case severe

    public static var lossyRatio: Double { SessionVerdict.lossyLossRatio }
    public static var severeRatio: Double { SessionVerdict.offlineLossRatio }

    public init(ratio: Double) {
        switch ratio {
        case ..<Self.lossyRatio:  self = .none
        case ..<Self.severeRatio: self = .lossy
        default:                  self = .severe
        }
    }

    public var label: String {
        switch self {
        case .none:   return "none"
        case .lossy:  return "lossy"
        case .severe: return "severe"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
