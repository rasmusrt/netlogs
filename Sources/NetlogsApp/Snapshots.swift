import AppKit
import SwiftUI
import NetlogsCore

/// `NetlogsApp --snapshots [folder] [seconds] [--all-metrics]`
///
/// `--all-metrics` also renders Analysis with each of the other figures
/// picked, as `analysis-<metric>-<width>.png`.
///
/// Renders Analysis, Router and Monitor v2 into PNG files at three window
/// widths, without ever showing a window or taking focus. The point is to
/// check layout — narrow, normal, wide — without driving the screen of the
/// Mac it runs on.
///
/// Analysis and Router read the real session store, read-only in practice
/// (the loaders only flush, which writes nothing when another process owns
/// the live session). Monitor v2 runs its own short live session against a
/// throwaway store in the temporary folder, like `--uicheck`, so the real
/// sidebar never gains a snapshot session.
enum Snapshots {

    /// Detail-column widths: a laptop window with the sidebar open, a
    /// typical one, and a wide desktop one.
    static let widths: [CGFloat] = [640, 900, 1300]
    /// Tall enough that no screen's content is cut off by its scroll view.
    static let height: CGFloat = 2200

    static func runBlocking() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments.drop { $0 != "--snapshots" }.dropFirst()
            .filter { !$0.hasPrefix("-") }
        let folder = URL(fileURLWithPath: (args.first.map { NSString(string: $0).expandingTildeInPath })
                         ?? NSString(string: "~/netlogs-snapshots").expandingTildeInPath)
        let seconds = args.dropFirst().first.flatMap(Double.init) ?? 20

        let code = MainActor.assumeIsolated { () -> Int32 in
            // No Dock icon, no menu bar, never frontmost.
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApp.appearance = NSAppearance(named: .aqua)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try run(folder: folder, seconds: seconds)
            } catch {
                print("Snapshots FAIL — \(error)")
                return 1
            }
        }
        exit(code)
    }

    @MainActor
    private static func run(folder: URL, seconds: TimeInterval) throws -> Int32 {
        let store = try SessionStore(url: try SessionStore.defaultURL())
        let settings = AppSettings()

        var written: [String] = []
        for width in widths {
            written.append(try render(AnalysisView(store: store, settings: settings),
                                      name: "analysis", width: width, folder: folder, settle: 4))
            written.append(try render(RouterView(store: store),
                                      name: "router", width: width, folder: folder, settle: 3))
            if CommandLine.arguments.contains("--all-metrics") {
                for metric in AnalysisMetric.allCases where metric != .latency {
                    written.append(try render(
                        AnalysisView(store: store, settings: settings, initialMetric: metric),
                        name: "analysis-\(metric.rawValue)", width: width, folder: folder, settle: 4))
                }
            }
        }

        // Monitor v2 needs a running session to have anything to draw.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("netlogs-snapshots-\(UUID().uuidString).sqlite")
        let controller = MonitorController(store: try SessionStore(url: url))
        print("Snapshots — recording a \(Int(seconds)) s live session for Monitor…")
        controller.start(settings: MonitorSettings(throughputEnabled: false))
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        for width in widths {
            let view = LiveSessionView(controller: controller, mode: .constant(.summary),
                                       usesV2: true)
            written.append(try render(view, name: "monitor-v2", width: width,
                                      folder: folder, settle: 1))
        }
        controller.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        try? FileManager.default.removeItem(at: url)

        print("")
        written.forEach { print("wrote \($0)") }
        return 0
    }

    /// Lays the view out in a window that is never put on screen, lets it
    /// load, and saves what it drew.
    @MainActor
    private static func render<V: View>(_ view: V, name: String, width: CGFloat,
                                        folder: URL, settle: TimeInterval) throws -> String {
        let size = NSSize(width: width, height: height)
        let hosting = NSHostingView(rootView:
            view
                .frame(width: width, height: height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Laid out and drawn, but never ordered in.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = folder.appendingPathComponent("\(name)-\(Int(width)).png")
        try png.write(to: file)
        window.close()
        return file.path
    }
}
