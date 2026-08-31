import XCTest
@testable import NetlogsCore

final class ModelRoundTripTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testPingSampleRoundTrip() throws {
        let sample = PingSample(
            id: 4_242,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.25),
            routerMs: 3.14,
            internetMs: nil,
            phase: .uploading
        )
        XCTAssertEqual(try roundTrip(sample), sample)
    }

    func testMonitorSettingsRoundTrip() throws {
        let settings = MonitorSettings(
            routerHost: "10.0.0.1",
            internetHost: "8.8.8.8",
            pingInterval: .milliseconds(500),
            pingTimeout: .seconds(2),
            throughputEnabled: true,
            throughputInterval: 30,
            diagnosticsInterval: .seconds(5)
        )
        XCTAssertEqual(try roundTrip(settings), settings)
    }

    func testLoadPhaseRoundTrip() throws {
        for phase in LoadPhase.allCases {
            XCTAssertEqual(try roundTrip(phase), phase)
        }
    }

    func testPingSampleTimeoutFlags() {
        let s = PingSample(id: 1, timestamp: .now, routerMs: nil, internetMs: 12, phase: .idle)
        XCTAssertTrue(s.routerTimedOut)
        XCTAssertFalse(s.internetTimedOut)
    }
}
