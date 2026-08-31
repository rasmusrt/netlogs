import AppKit
import SwiftUI
import NetlogsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance — two would mean two writers on netlogs.sqlite.
        // Match on the running binary's on-disk path (reliable for both the
        // bare dev binary and the .app; `bundleIdentifier` is nil for the
        // former), plus bundle id when LaunchServices provides it.
        let me = NSRunningApplication.current
        let myPath = me.executableURL?.resolvingSymlinksInPath().path
        let myBID = Bundle.main.bundleIdentifier

        let siblings = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != me.processIdentifier else { return false }
            if let b = app.bundleIdentifier, b == myBID { return true }
            if let p = app.executableURL?.resolvingSymlinksInPath().path, p == myPath { return true }
            return false
        }
        if let first = siblings.min(by: {
            ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
        }) {
            first.activate()
            NSApp.terminate(nil)
            return
        }

        // A bare SwiftPM binary started from a shell stays unactivated.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the only window of a single-`Window` scene leaves the app
    /// running with nothing on screen and no menu entry to get it back —
    /// clicking the Dock icon looked like the app was broken. Reopen it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        for window in sender.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return true
    }
}

/// The app's scene graph.
struct NetlogsScene: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Opened once at launch; a failure here is shown instead of the UI.
    @State private var store = Result { try SessionStore(url: try SessionStore.defaultURL()) }
    @State private var settings = AppSettings()

    var body: some Scene {
        // `Window`, not `WindowGroup` — a single-window utility, no ⌘N.
        Window("Netlogs", id: "netlogs.main") {
            Group {
                switch store {
                case .success(let store):
                    // Sized for a quarter-screen tile, not for a comfortable
                    // full-screen layout: the summary cards are full-width rows
                    // that reflow, and the header sheds its counters before it
                    // sheds the verdict.
                    RootView(store: store, settings: settings)
                        .frame(minWidth: 560, minHeight: 420)
                case .failure(let error):
                    StorageErrorView(error: error)
                }
            }
            // Removes the 1pt rule under the toolbar.
            //
            // Not `window.titlebarSeparatorStyle = .none`, which is the
            // documented control and does nothing here: on macOS 26 the rule
            // is a `_NSLayerBasedFillColorView` inside
            // `NSTitlebarBackgroundView`, and it survives the window property
            // being `.none`. Hiding the toolbar background stops it being
            // created at all.
            //
            // This replaced an `NSViewRepresentable` that set the window
            // property, walked `NSSplitViewController.splitViewItems` to set
            // theirs, and re-applied from five window notifications.
            // Instrumenting the view tree showed `NavigationSplitView` on
            // macOS 26 vends no `NSSplitViewController` under the window's
            // content view controller, so the split-item walk matched
            // nothing — and with the whole thing disabled (separator style
            // back to `.automatic`) the rule still does not appear. It was
            // inert, and it was the reason this looked unfixable.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .preferredColorScheme(settings.theme.colorScheme)
        }
        .windowResizability(.contentMinSize)
        // SwiftUI persists whether a `Window` scene was open at quit. Close the
        // window once and every later launch came up with no window at all and
        // no menu entry to get one back — the app looked dead while it was in
        // fact running. Always present it.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {} // no "New Window"
            // The mode switch also lives in the toolbar, but a segmented
            // control collapses into the overflow menu on a narrow window —
            // so the menu is where the shortcuts actually belong.
            // CHART DISABLED — no view switch while there is only one view.
            // CommandGroup(before: .sidebar) {
            //     ForEach(Array(DetailMode.allCases.enumerated()), id: \.element) { index, mode in
            //         Button { settings.detailMode = mode } label: {
            //             Label(mode.rawValue, systemImage: mode.systemImage)
            //         }
            //         .keyboardShortcut(
            //             KeyEquivalent(Character("\(index + 1)")), modifiers: .command
            //         )
            //     }
            //     Divider()
            // }
        }

        Settings {
            SettingsScreen(settings: settings, store: try? store.get())
                .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}

struct StorageErrorView: View {
    let error: Error
    var body: some View {
        ContentUnavailableView {
            Label("Can't open the database", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text(String(describing: error))
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}
