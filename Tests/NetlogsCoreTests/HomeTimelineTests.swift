import XCTest
@testable import NetlogsCore

final class HomeTimelineTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// Four one-hour buckets.
    private var interval: DateInterval { DateInterval(start: start, duration: 4 * 3600) }

    private func at(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }

    private func wifi(_ hours: Double, rssi: Int, channel: Int = 36) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(timestamp: at(hours), interfaceName: "en0", kind: .wifi,
                            rssi: rssi, channel: channel, band: "5 GHz")
    }

    private func ping(_ id: UInt32, _ hours: Double, router: Double?) -> PingSample {
        PingSample(id: id + PingSample.warmupSampleCount, timestamp: at(hours),
                   routerMs: router, internetMs: 20, phase: .idle)
    }

    private func build(recorded: [DateInterval],
                       diagnostics: [DiagnosticsSnapshot] = [],
                       samples: [PingSample] = [],
                       wan: WANTrace = WANTrace()) -> HomeTimeline {
        HomeTimeline.build(interval: interval, recorded: recorded, diagnostics: diagnostics,
                           samples: samples, wan: wan, bucketCount: 4)
    }

    func testUnrecordedBucketsAreNilNotZero() {
        let timeline = build(recorded: [DateInterval(start: at(0), end: at(1))],
                             samples: [ping(0, 0.5, router: 3), ping(1, 2.5, router: 3)])
        XCTAssertTrue(timeline.buckets[0].measured)
        XCTAssertEqual(timeline.buckets[0].routerMs ?? 0, 3, accuracy: 0.001)
        XCTAssertFalse(timeline.buckets[2].measured)
        XCTAssertNil(timeline.buckets[2].routerMs, "a sample outside a recording is not drawn")
        XCTAssertEqual(timeline.events.first?.kind, .notRecording)
    }

    func testWeakSignalAndSlowRouterBecomeEvents() {
        let all = [DateInterval(start: at(0), end: at(4))]
        let timeline = build(
            recorded: all,
            diagnostics: [wifi(0.5, rssi: -50), wifi(1.5, rssi: -74), wifi(2.5, rssi: -52)],
            samples: [ping(0, 0.5, router: 2), ping(1, 3.5, router: 60), ping(2, 3.6, router: 80)]
        )
        let kinds = Set(timeline.events.map(\.kind))
        XCTAssertTrue(kinds.contains(.weakWiFi))
        XCTAssertTrue(kinds.contains(.slowRouter))
        XCTAssertFalse(kinds.contains(.notRecording))
        XCTAssertEqual(timeline.events.first { $0.kind == .weakWiFi }?.value, -74)
        XCTAssertEqual(timeline.events.first { $0.kind == .slowRouter }?.value ?? 0, 70, accuracy: 0.001)
    }

    func testChannelChangeAndNewestFirst() {
        let timeline = build(
            recorded: [DateInterval(start: at(0), end: at(4))],
            diagnostics: [wifi(0.5, rssi: -50, channel: 36), wifi(3.2, rssi: -50, channel: 100)]
        )
        XCTAssertEqual(timeline.events.first?.kind, .channelChange)
        XCTAssertEqual(timeline.events.first?.value, 100)
        XCTAssertEqual(timeline.events.map(\.id), Array(0..<timeline.events.count))
    }

    func testRouterLossIsAShareOfPings() {
        let timeline = build(
            recorded: [DateInterval(start: at(0), end: at(1))],
            samples: [ping(0, 0.1, router: 2), ping(1, 0.2, router: nil),
                      ping(2, 0.3, router: 2), ping(3, 0.4, router: 2)]
        )
        XCTAssertEqual(timeline.buckets[0].routerLoss ?? 0, 0.25, accuracy: 0.001)
        XCTAssertFalse(timeline.hasWiFi)
        XCTAssertFalse(timeline.hasGateway)
    }
}
