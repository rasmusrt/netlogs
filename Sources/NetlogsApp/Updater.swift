import AppKit
import Observation
import Security
import NetlogsCore

/// Finds new releases on GitHub and installs them in place.
///
/// Not Sparkle. Sparkle wants an appcast hosted somewhere, a second signing
/// key kept beside the Developer ID, and a step in the release script for
/// each — for an app whose releases already live on GitHub with a notarized
/// zip attached. Asking GitHub's `releases/latest` endpoint gets the same
/// answer, and the Developer ID signature the release is notarized with is
/// what proves a download is ours: it is checked against this copy's own team
/// before anything is replaced.
///
/// Homebrew installs replace themselves the same way. Brew then still records
/// the older version, so a later `brew upgrade` reinstalls the version that is
/// already there — harmless. The cask deliberately does not say
/// `auto_updates true` yet: that makes plain `brew upgrade` skip the app, and
/// copies older than this updater have no other way to hear of a release.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? {
        didSet { UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey) }
    }
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.automaticKey) }
    }
    /// "Later" in the sidebar. Not persisted: the reminder comes back at the
    /// next launch, which is the point of a reminder.
    private(set) var dismissed: AppVersion?

    let current: AppVersion
    /// Why this copy cannot replace itself, or `nil` when it can. When it
    /// cannot, "install" opens the release page instead.
    let cannotInstallReason: String?
    /// A local build ("Netlogs Beta", or the bare SwiftPM binary). It never
    /// checks on its own: it is usually ahead of the last release, and when it
    /// is not, the fix is a rebuild rather than a download.
    let isDevBuild: Bool

    private static let automaticKey = "netlogs.updates.automatic"
    private static let lastCheckedKey = "netlogs.updates.lastChecked"
    /// Once a day. GitHub allows 60 unauthenticated requests an hour per
    /// address; this is nowhere near it.
    private static let interval: TimeInterval = 24 * 3600

    init(bundle: Bundle = .main) {
        let defaults = UserDefaults.standard
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date

        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = shortVersion.flatMap(AppVersion.init) ?? AppVersion("0")!

        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let isApp = bundle.bundleURL.pathExtension == "app"
        isDevBuild = !isApp || name != "Netlogs"

        let parent = bundle.bundleURL.deletingLastPathComponent().path
        if isDevBuild {
            cannotInstallReason = "This is a local build. Rebuild it to update."
        } else if Self.ownTeamIdentifier() == nil {
            cannotInstallReason = "This copy is not signed with a Developer ID."
        } else if !FileManager.default.isWritableFile(atPath: parent)
                    || !FileManager.default.isWritableFile(atPath: bundle.bundleURL.path) {
            // Also the case for an app macOS is running translocated from a
            // read-only location, e.g. straight out of Downloads.
            cannotInstallReason = "Netlogs can't write to \(parent)."
        } else {
            cannotInstallReason = nil
        }

        // Lives as long as the app; there is one updater and it is never freed.
        Task { await self.startAutomaticChecks() }
    }

    /// The release to mention in the sidebar, if any.
    var pendingRelease: AppRelease? {
        guard case .available(let release) = state, release.version != dismissed else { return nil }
        return release
    }

    func dismiss() {
        if case .available(let release) = state { dismissed = release.version }
    }

    // MARK: - Checking

    /// Checks at launch when a day has passed, then once a day while running.
    private func startAutomaticChecks() async {
        guard !isDevBuild else { return }
        // Not in the first seconds after launch, which belong to the app.
        try? await Task.sleep(for: .seconds(10))
        while !Task.isCancelled {
            if automatic, Date().timeIntervalSince(lastChecked ?? .distantPast) >= Self.interval {
                await check(userInitiated: false)
            }
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// The menu item and the Settings button. Says what it found, including
    /// "nothing" — an automatic check only speaks when there is something new.
    func checkFromMenu() {
        Task {
            await check(userInitiated: true)
            switch state {
            case .available(let release): offer(release)
            case .upToDate:
                alert("You're up to date",
                      "Netlogs \(current) is the newest version.")
            case .failed(let message):
                alert("Couldn't check for updates", message)
            default: break
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard state != .checking, state != .installing else { return }
        let before = state
        state = .checking
        do {
            var request = URLRequest(url: AppRelease.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404 is "no release published yet", which is being up to date.
            if status == 404 {
                state = .upToDate
            } else {
                let release = try AppRelease.decode(data)
                state = release.isNewer(than: current) ? .available(release) : .upToDate
            }
            lastChecked = Date()
        } catch {
            // A silent check that fails says nothing — no network on a train
            // is not news — and keeps whatever it knew before.
            state = userInitiated
                ? .failed("GitHub didn't answer. Check the connection and try again.")
                : before
        }
    }

    // MARK: - Installing

    /// "Install" from the sidebar or the alert.
    func install(_ release: AppRelease) {
        guard cannotInstallReason == nil, let zip = release.zipURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard state != .installing else { return }
        state = .installing
        Task {
            do {
                try await replaceAndRelaunch(from: zip, expecting: release.version)
            } catch {
                state = .available(release)
                alert("Couldn't install Netlogs \(release.version)",
                      "\(error.localizedDescription)\n\nYou can download it from the release page instead.",
                      openOnOK: release.pageURL)
            }
        }
    }

    private func replaceAndRelaunch(from zip: URL, expecting version: AppVersion) async throws {
        let dest = Bundle.main.bundleURL
        guard let team = Self.ownTeamIdentifier() else { throw InstallError("This copy is not signed.") }
        let ownID = Bundle.main.bundleIdentifier

        // Same volume as the app, so the final move is a rename rather than a
        // copy that could be cut off halfway through.
        let stage = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: dest, create: true)
        let (download, response) = try await URLSession.shared.download(from: zip)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError("The download failed.")
        }
        let archive = stage.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: download, to: archive)

        let unpacked = stage.appendingPathComponent("unpacked")
        let newApp = unpacked.appendingPathComponent("Netlogs.app")
        try await Task.detached {
            // ditto, the same tool that packed it: it keeps the bundle's
            // symlinks and signature intact, which Archive Utility also does
            // but `unzip` does not.
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                throw InstallError("The download didn't contain Netlogs.app.")
            }
            let info = Bundle(url: newApp)
            guard info?.bundleIdentifier == ownID else {
                throw InstallError("The download is a different app.")
            }
            let newVersion = (info?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                .flatMap(AppVersion.init)
            guard newVersion == version else {
                throw InstallError("The download is not version \(version).")
            }
            guard Self.isSigned(newApp, byTeam: team) else {
                throw InstallError("The download isn't signed by the same developer as this copy.")
            }
        }.value

        // The swap has to happen after this process exits — a running app's
        // bundle can be moved, but then the relaunch would find the old one.
        // A detached shell waits for the exit, swaps, puts the old copy back
        // if the swap fails, and opens whichever copy is now in place.
        let script = """
        pid="$1"; new="$2"; dest="$3"; stage="$4"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i+1)); [ "$i" -gt 300 ] && exit 1
          sleep 0.2
        done
        if mv "$dest" "$stage/previous.app"; then
          if mv "$new" "$dest"; then rm -rf "$stage"; else mv "$stage/previous.app" "$dest"; fi
        fi
        open "$dest"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "netlogs-update",
                             String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, dest.path, stage.path]
        try process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func offer(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = "Netlogs \(release.version) is available"
        var text = "You have \(current)."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "\n\n" + String(notes.prefix(600)) }
        if let reason = cannotInstallReason { text += "\n\n" + reason }
        alert.informativeText = text
        alert.addButton(withTitle: cannotInstallReason == nil ? "Install and Relaunch" : "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { install(release) }
    }

    private func alert(_ title: String, _ text: String, openOnOK url: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let url {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        } else {
            _ = alert.runModal()
        }
    }

    // MARK: - Signatures

    /// The team that signed the running app, `nil` for an ad-hoc signature.
    nonisolated static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A valid Apple-issued signature from `team`, the same check Gatekeeper
    /// starts from.
    nonisolated static func isSigned(_ app: URL, byTeam team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
                                    | UInt32(kSecCSStrictValidate)
                                    | UInt32(kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallError("Unpacking the download failed.") }
    }
}

/// File scope, not nested in `Updater`, so the unpack-and-verify step can
/// throw it off the main actor.
private struct InstallError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
