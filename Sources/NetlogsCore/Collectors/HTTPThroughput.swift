import Foundation

/// Own throughput test against Cloudflare's public speed endpoints (plan §6.3),
/// replacing the Ookla CLI. Time-boxed per direction, first ~1 s discarded for
/// TCP slow start, with a byte cap as a safety valve on very fast links.
///
/// Endpoints (`speed.cloudflare.com`): `__down?bytes=N`, `__up`, `meta`.
/// **Verify Cloudflare's terms of use before distributing** (plan §13 Q1) — the
/// whole thing sits behind `ThroughputProvider` so it can be swapped.
public struct HTTPThroughput: ThroughputProvider {

    public var connections: Int
    public var maxBytesPerDirection: Int
    public var host: String

    public init(
        connections: Int = 4,
        // ~100 MB/direction ≈ 200 MB/test, matching Cloudflare's own "up to
        // 200 MB" budget (PHASE5-NOTES). On a fast link the time box is cut
        // short by this; a few seconds of steady state is still enough for the
        // trend-over-time job (plan §6.3).
        maxBytesPerDirection: Int = 100 * 1_000_000,
        host: String = "speed.cloudflare.com"
    ) {
        self.connections = connections
        self.maxBytesPerDirection = maxBytesPerDirection
        self.host = host
    }

    private var downURL: URL { URL(string: "https://\(host)/__down?bytes=2000000000")! }
    private var upURL: URL { URL(string: "https://\(host)/__up")! }
    private var metaURL: URL { URL(string: "https://\(host)/meta")! }

    /// The endpoints 403 without this — they only serve the speed-test origin.
    private var referer: String { "https://\(host)/" }

    // MARK: - Download

    public func measureDownload(duration: Duration, discardingFirst warmup: Duration) async -> ThroughputMeasurement {
        let counter = TransferCounter()
        let session = Self.makeSession(delegate: counter, connections: connections)
        defer { session.invalidateAndCancel() }

        for _ in 0..<connections {
            var request = URLRequest(url: downURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue(referer, forHTTPHeaderField: "Referer")
            session.dataTask(with: request).resume()
        }

        let window = await Self.runWindow(
            duration: duration, warmup: warmup, cap: maxBytesPerDirection,
            read: { counter.received }
        )
        return ThroughputMeasurement(bytes: window.bytes, seconds: window.seconds)
    }

    // MARK: - Upload

    public func measureUpload(duration: Duration, discardingFirst warmup: Duration) async -> ThroughputMeasurement {
        let counter = TransferCounter()
        let session = Self.makeSession(delegate: counter, connections: connections)
        let runner = UploadRunner(session: session, url: upURL, referer: referer, chunkBytes: 16 * 1024 * 1024)
        defer { runner.stop(); session.invalidateAndCancel() }

        runner.start(connections: connections)

        let window = await Self.runWindow(
            duration: duration, warmup: warmup, cap: maxBytesPerDirection,
            read: { counter.sent }
        )
        return ThroughputMeasurement(bytes: window.bytes, seconds: window.seconds)
    }

    // MARK: - Meta

    public func fetchMeta() async -> ThroughputMeta? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: metaURL)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        guard
            let (data, _) = try? await session.data(for: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `colo` is either a string or `{ "iata": "CPH", … }` depending on the day.
        let colo: String?
        if let s = json["colo"] as? String {
            colo = s
        } else if let dict = json["colo"] as? [String: Any] {
            colo = dict["iata"] as? String
        } else {
            colo = nil
        }
        return ThroughputMeta(isp: json["asOrganization"] as? String, colo: colo)
    }

    // MARK: - Shared window logic

    /// Wait out `warmup`, then measure until `duration` elapses or `cap` bytes,
    /// polling so a very fast link can't blow past the cap.
    private static func runWindow(
        duration: Duration, warmup: Duration, cap: Int,
        read: @Sendable () -> Int
    ) async -> (bytes: Int, seconds: Double) {
        try? await Task.sleep(for: warmup)
        let bytesAtWarmup = read()
        let startedAt = DispatchTime.now()
        let deadline = startedAt.uptimeNanoseconds + UInt64(max(0, (duration - warmup).wholeNanoseconds))

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if read() - bytesAtWarmup >= cap { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        return (read() - bytesAtWarmup, Double(elapsedNs) / 1_000_000_000)
    }

    private static func makeSession(delegate: TransferCounter, connections: Int) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = connections + 2
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }
}

// MARK: - Byte counter delegate

private final class TransferCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _received = 0
    private var _sent = 0

    var received: Int { lock.withLock { _received } }
    var sent: Int { lock.withLock { _sent } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let n = data.count
        lock.withLock { _received += n }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        let n = Int(bytesSent)
        lock.withLock { _sent += n }
    }

    // Tasks are cancelled deliberately at the time box — errors are expected.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {}
}

// MARK: - Upload: keep N chunks in flight until stopped

private final class UploadRunner: @unchecked Sendable {
    private let session: URLSession
    private let request: URLRequest
    private let body: Data
    private let lock = NSLock()
    private var running = false
    private var tasks: [URLSessionUploadTask] = []

    init(session: URLSession, url: URL, referer: String, chunkBytes: Int) {
        self.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.request = request
        self.body = Data(count: chunkBytes) // zeros, CoW-shared across tasks
    }

    func start(connections: Int) {
        lock.withLock { running = true }
        for _ in 0..<connections { launchOne() }
    }

    func stop() {
        let toCancel: [URLSessionUploadTask] = lock.withLock {
            running = false
            defer { tasks.removeAll() }
            return tasks
        }
        toCancel.forEach { $0.cancel() }
    }

    private func launchOne() {
        guard lock.withLock({ running }) else { return }
        let task = session.uploadTask(with: request, from: body) { [weak self] _, _, _ in
            self?.launchOne() // chain another as soon as one finishes
        }
        lock.withLock { tasks.append(task) }
        task.resume()
    }
}
