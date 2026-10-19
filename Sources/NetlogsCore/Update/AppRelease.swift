import Foundation

/// A dotted version number — "0.1.1", "v0.2", "1.0.0-beta" — compared the way
/// a person would: numerically, part by part, missing parts read as zero.
///
/// String comparison gets "0.10.0" < "0.9.0" wrong, which is the first release
/// after 0.9 telling everyone they are up to date.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    /// `nil` for anything without a leading number. A leading "v" (the tag
    /// convention) and anything after the numbers ("-beta", " (2)") are ignored.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        var parts: [Int] = []
        for piece in rest.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = piece.prefix(while: \.isNumber)
            guard let n = Int(digits) else { break }
            parts.append(n)
            if digits.count != piece.count { break }
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A published release, as GitHub's `releases/latest` endpoint describes it.
///
/// Only what the update check needs: the version, the zip to install from, and
/// the page to send someone to when installing in place is not possible.
public struct AppRelease: Sendable, Equatable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    /// The `Netlogs-<version>.zip` asset `Scripts/release.sh` builds. `nil`
    /// when the release has no such asset — then only the page is offered.
    public let zipURL: URL?

    public init(version: AppVersion, notes: String, pageURL: URL, zipURL: URL?) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.zipURL = zipURL
    }

    /// The endpoint the app asks. Drafts and pre-releases are never "latest",
    /// so a release only reaches users once it is published as a full one.
    public static let latestURL = URL(string: "https://api.github.com/repos/rasmusrt/netlogs/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }

    public enum DecodeError: Error, Equatable {
        case notARelease
        case unreadableVersion(String)
    }

    public static func decode(_ data: Data) throws -> AppRelease {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw DecodeError.notARelease }
        guard payload.draft != true, payload.prerelease != true else { throw DecodeError.notARelease }
        guard let version = AppVersion(payload.tag_name) else {
            throw DecodeError.unreadableVersion(payload.tag_name)
        }
        // By name, not "the first .zip": a release may one day carry a source
        // archive or a dSYM zip beside the app.
        let zip = payload.assets.first {
            $0.name.hasPrefix("Netlogs-") && $0.name.hasSuffix(".zip")
        }
        return AppRelease(version: version, notes: payload.body ?? "",
                          pageURL: payload.html_url, zipURL: zip?.browser_download_url)
    }

    /// Whether this release is worth offering to someone running `current`.
    public func isNewer(than current: AppVersion) -> Bool { version > current }
}
