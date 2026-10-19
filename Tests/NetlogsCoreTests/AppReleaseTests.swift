import XCTest
@testable import NetlogsCore

/// The update check: which version is newer, and what a GitHub release says.
final class AppReleaseTests: XCTestCase {

    // MARK: - Versions

    func testComparesNumericallyNotAsText() {
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.1.1")!, AppVersion("0.2")!)
        XCTAssertLessThan(AppVersion("1.9.9")!, AppVersion("2.0.0")!)
    }

    func testMissingPartsReadAsZero() {
        XCTAssertEqual(AppVersion("0.2")!, AppVersion("0.2.0")!)
        XCTAssertFalse(AppVersion("0.2")! < AppVersion("0.2.0")!)
    }

    func testTagPrefixAndSuffixAreIgnored() {
        XCTAssertEqual(AppVersion("v0.1.1")?.parts, [0, 1, 1])
        XCTAssertEqual(AppVersion("1.2.3-beta")?.parts, [1, 2, 3])
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
    }

    // MARK: - Release payload

    private func payload(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [String] = ["Netlogs-0.2.0.zip"]) -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","browser_download_url":"https://github.com/rasmusrt/netlogs/releases/download/\#(tag)/\#($0)"}"#
        }.joined(separator: ",")
        return Data(#"""
        {"tag_name":"\#(tag)","body":"Notes","html_url":"https://github.com/rasmusrt/netlogs/releases/tag/\#(tag)",
         "draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(list)]}
        """#.utf8)
    }

    func testDecodesVersionZipAndPage() throws {
        let release = try AppRelease.decode(payload())
        XCTAssertEqual(release.version, AppVersion("0.2.0"))
        XCTAssertEqual(release.zipURL?.lastPathComponent, "Netlogs-0.2.0.zip")
        XCTAssertEqual(release.pageURL.absoluteString,
                       "https://github.com/rasmusrt/netlogs/releases/tag/v0.2.0")
        XCTAssertEqual(release.notes, "Notes")
        XCTAssertTrue(release.isNewer(than: AppVersion("0.1.1")!))
        XCTAssertFalse(release.isNewer(than: AppVersion("0.2")!))
    }

    func testPicksTheAppZipAmongOtherAssets() throws {
        let release = try AppRelease.decode(payload(assets: ["Source.zip", "Netlogs-0.2.0.zip"]))
        XCTAssertEqual(release.zipURL?.lastPathComponent, "Netlogs-0.2.0.zip")
    }

    func testReleaseWithoutTheZipStillOffersThePage() throws {
        let release = try AppRelease.decode(payload(assets: []))
        XCTAssertNil(release.zipURL)
    }

    func testDraftsAndPrereleasesAreNotOffered() {
        XCTAssertThrowsError(try AppRelease.decode(payload(draft: true)))
        XCTAssertThrowsError(try AppRelease.decode(payload(prerelease: true)))
    }

    func testRateLimitResponseIsNotARelease() {
        let body = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        XCTAssertThrowsError(try AppRelease.decode(body)) {
            XCTAssertEqual($0 as? AppRelease.DecodeError, .notARelease)
        }
    }
}
