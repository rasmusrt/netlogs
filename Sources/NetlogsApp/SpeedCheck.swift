import Foundation
import NetlogsCore

/// `NetlogsApp --speed` — run one `HTTPThroughput` download + upload + meta and
/// print the numbers, including bytes transferred (Phase 5 data-volume check).
enum SpeedCheck {
    static func runBlocking() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let provider = HTTPThroughput()
        let sem = DispatchSemaphore(value: 0)

        Task {
            print("fetching /meta …")
            let meta = await provider.fetchMeta()
            print("  ISP: \(meta?.isp ?? "—")   colo: \(meta?.colo ?? "—")\n")

            print("download — 10 s, first 1 s discarded …")
            let d = await provider.measureDownload(duration: .seconds(10), discardingFirst: .seconds(1))
            print(String(format: "  %.1f Mbps over %.1f s   (%.0f MB)\n", d.mbps, d.seconds, Double(d.bytes) / 1_000_000))

            print("upload — 10 s, first 1 s discarded …")
            let u = await provider.measureUpload(duration: .seconds(10), discardingFirst: .seconds(1))
            print(String(format: "  %.1f Mbps over %.1f s   (%.0f MB)\n", u.mbps, u.seconds, Double(u.bytes) / 1_000_000))

            let total = Double(d.bytes + u.bytes) / 1_000_000
            print(String(format: "total transferred this test: %.0f MB  (Ookla runs were ~470 MB)", total))
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
