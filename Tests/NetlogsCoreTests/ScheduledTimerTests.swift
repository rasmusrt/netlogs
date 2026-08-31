import XCTest
@testable import NetlogsCore

final class ScheduledTimerTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ticks: [ScheduledTimer.Tick] = []
        func append(_ t: ScheduledTimer.Tick) { lock.lock(); ticks.append(t); lock.unlock() }
        var snapshot: [ScheduledTimer.Tick] { lock.lock(); defer { lock.unlock() }; return ticks }
    }

    func testFiresAtExpectedRateWithoutDrift() async throws {
        let sink = Sink()
        let timer = ScheduledTimer(
            interval: .milliseconds(100),
            queue: DispatchQueue(label: "test.timer"),
            onTick: { sink.append($0) }
        )
        timer.start()
        try await Task.sleep(for: .seconds(2))
        timer.stop()

        let ticks = sink.snapshot
        // ~20 ticks in 2 s; allow slack for a loaded CI machine.
        XCTAssertGreaterThanOrEqual(ticks.count, 17, "too few ticks: \(ticks.count)")
        XCTAssertLessThanOrEqual(ticks.count, 22, "too many ticks: \(ticks.count)")

        // Counts are 1-based and strictly sequential.
        XCTAssertEqual(ticks.map(\.count), Array(1...ticks.count))

        // The drift property: lateness does not grow with tick index. If the
        // timer rescheduled off "now" each fire, the last tick's lateness would
        // be roughly ticks.count × schedulingError. Anchored scheduling keeps it
        // flat and small.
        let lateMs = ticks.map { $0.lateness * 1000 }
        for (i, l) in lateMs.enumerated() {
            XCTAssertLessThan(l, 60, "tick \(i + 1) late by \(l) ms — looks like drift")
            XCTAssertGreaterThan(l, -5, "tick \(i + 1) fired early by \(l) ms")
        }
        let firstHalf = lateMs.prefix(lateMs.count / 2).reduce(0, +) / Double(max(1, lateMs.count / 2))
        let lastHalf = lateMs.suffix(lateMs.count / 2).reduce(0, +) / Double(max(1, lateMs.count / 2))
        XCTAssertLessThan(lastHalf - firstHalf, 20,
                          "average lateness grew \(lastHalf - firstHalf) ms across the run")
    }

    func testReanchorsAfterAGap() async throws {
        // A stalled handler (stand-in for the Mac sleeping) should make the next
        // tick re-anchor: its scheduledAt jumps to ~now, and count stays
        // contiguous (no id reset).
        let sink = Sink()
        let interval = Duration.milliseconds(100)
        let stalled = LockedFlag()

        let timer = ScheduledTimer(interval: interval, queue: DispatchQueue(label: "test.reanchor")) { tick in
            sink.append(tick)
            if tick.count == 4, !stalled.testAndSet() {
                Thread.sleep(forTimeInterval: 0.45) // ~4.5 intervals — looks like a sleep
            }
        }
        timer.start()
        try await Task.sleep(for: .milliseconds(1200))
        timer.stop()

        let ticks = sink.snapshot
        XCTAssertGreaterThan(ticks.count, 8)
        XCTAssertEqual(ticks.map(\.count), Array(1...ticks.count), "count stays contiguous across the gap")

        // The tick right after the stalled one must have re-anchored: its
        // scheduledAt is close to when it fired, not ~0.45 s behind.
        let afterGap = ticks[5]
        XCTAssertLessThan(abs(afterGap.lateness), interval.timeInterval,
                          "post-gap tick re-anchored (lateness \(afterGap.lateness) s)")
        // …and the grid keeps ticking from there.
        //
        // Asserted as a property of the schedule, not as a wall-clock
        // threshold. The previous check demanded lateness under 60 ms on a
        // 100 ms interval, which is really a measurement of how busy the
        // machine is — it drifted to 61–63 ms under load and failed
        // intermittently. What re-anchoring actually promises is that the
        // scheduled instants sit on a fixed grid afterwards and lateness stops
        // accumulating back toward the length of the stall.
        let tail = Array(ticks.suffix(4))
        for (earlier, later) in zip(tail, tail.dropFirst()) {
            XCTAssertEqual(
                later.scheduledAt.timeIntervalSince(earlier.scheduledAt),
                interval.timeInterval,
                accuracy: 0.001,
                "scheduled instants stay exactly one interval apart"
            )
        }
        for t in tail {
            XCTAssertLessThan(abs(t.lateness), interval.timeInterval,
                              "lateness stays inside one interval (\(t.lateness) s)")
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func testAndSet() -> Bool { lock.lock(); defer { lock.unlock() }; let was = done; done = true; return was }
    }

    func testStopIsIdempotent() {
        let timer = ScheduledTimer(
            interval: .milliseconds(50),
            queue: DispatchQueue(label: "test.timer.idem"),
            onTick: { _ in }
        )
        timer.start()
        timer.stop()
        timer.stop() // must not crash
    }
}
