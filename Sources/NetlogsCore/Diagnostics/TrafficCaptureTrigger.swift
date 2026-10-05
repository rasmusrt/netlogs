import Foundation

/// Decides when a latency episode is worth finding out what this Mac is doing.
///
/// Pure and value-typed so the policy is testable without spawning `nettop`,
/// which takes five seconds and looks at the whole machine.
///
/// ## The condition
///
/// Internet RTT above `internetMs` **while** router RTT stays below `routerMs`.
/// Both halves are load-bearing. The internet half alone fires on every
/// congested moment including ones where the whole link is down; the router
/// half is what says "the LAN is fine, so this is the path or the uplink" —
/// which is the only situation where the answer might be a process on this
/// machine. It is the exact signature of all five episodes in session
/// `B4DA0F59`: gateway 3–8 ms throughout, internet ramping past a second.
///
/// ## The debounce is the whole design
///
/// An episode is a *ramp*, not a spike. 00:09:12–00:09:37 held the condition
/// true for twenty-five consecutive samples. A naive trigger fires twenty-five
/// times, spawns twenty-five five-second `nettop` runs that overlap each other,
/// and writes twenty-five near-identical rows — turning a diagnostic into a
/// load generator on the machine it is diagnosing.
///
/// So: one capture per episode (`quiet` consecutive good samples end it), and a
/// hard `cooldown` floor between captures regardless.
public struct TrafficCaptureTrigger: Sendable, Equatable {

    /// Internet RTT at or above this is "diverged". 300 ms is well clear of the
    /// worst normal reading on a healthy link — this database's internet p95 is
    /// under 40 ms — and well below the timeout, so the trigger fires while the
    /// episode is still building rather than after it has peaked.
    public var internetMs: Double
    /// Router RTT must stay under this. 10 ms against a measured 3–8 ms
    /// gateway: high enough not to miss an episode where the LAN also twitched,
    /// low enough that a genuinely struggling LAN does not qualify.
    public var routerMs: Double
    /// Consecutive samples below the threshold that end an episode. Five, so a
    /// ramp that dips under 300 ms for a sample or two on its way up is still
    /// one episode and not three.
    public var quiet: Int
    /// Minimum wall time between captures, whatever the samples say. Ten
    /// minutes: long enough that a bad hour costs six captures rather than
    /// three hundred, short enough to catch a second, distinct episode.
    public var cooldown: TimeInterval

    private var lastCapture: Date?
    private var goodRun: Int
    private var inEpisode: Bool

    public init(
        internetMs: Double = 300,
        routerMs: Double = 10,
        quiet: Int = 5,
        cooldown: TimeInterval = 600
    ) {
        self.internetMs = internetMs
        self.routerMs = routerMs
        self.quiet = quiet
        self.cooldown = cooldown
        self.lastCapture = nil
        self.goodRun = 0
        self.inEpisode = false
    }

    /// `true` at most once per episode, and never twice inside `cooldown`.
    ///
    /// A timeout counts as diverged — `internetRttMs` is `nil` only when nothing
    /// came back at all, and a missing reply is at least as strong a signal as a
    /// slow one. A late reply carries its real RTT and is judged on it.
    public mutating func shouldCapture(_ sample: PingSample, now: Date) -> Bool {
        // The router has to be healthy, and a router that did not answer is not
        // healthy — an episode where both legs went quiet is a link problem, and
        // no process list explains it.
        guard let router = sample.routerRttMs, router < routerMs else {
            goodRun = 0
            return false
        }
        let diverged = sample.internetRttMs.map { $0 >= internetMs } ?? true

        guard diverged else {
            goodRun += 1
            if goodRun >= quiet { inEpisode = false }
            return false
        }
        goodRun = 0
        guard !inEpisode else { return false } // already captured this one
        if let last = lastCapture, now.timeIntervalSince(last) < cooldown {
            // Still inside the cooldown. Mark the episode anyway, so the moment
            // the cooldown lapses we do not immediately fire on its tail.
            inEpisode = true
            return false
        }
        inEpisode = true
        lastCapture = now
        return true
    }
}
