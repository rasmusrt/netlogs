import Foundation

/// Every number the UI renders goes through here.
///
/// `Fmt.ms` existed before Phase 9 but was never called — every site inlined
/// its own `String(format: "%.1f", …)`, which is how "12.3" and "12" ended up
/// side by side on the same card. The split below matters: `ms` returns the
/// number alone, for when the unit is a separate, quieter piece of text
/// (`MetricView`); `msLabel` returns both, for running text.
enum Fmt {

    /// "H:MM:SS"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1h 23m" / "4m 12s" / "38s"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    /// The number alone: "12.3" / "—".
    static func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    /// Number and unit: "12.3 ms" / "—".
    static func msLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f ms", value)
    }

    /// Rounded, for values where a decimal is noise: "340" / "—".
    static func msCoarse(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value)
    }

    /// "512" / "—". Throughput is never interesting to a decimal place.
    static func mbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value)
    }

    /// "2.4%", "<0.1%" for a non-zero share too small to render, or "—".
    ///
    /// 13 failures in 38,228 samples is 0.034%, which printed as "0.0% of the
    /// session" — indistinguishable from none, on a sheet whose whole purpose
    /// is showing that they happened.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        let pct = fraction * 100
        if pct > 0 && pct < 0.05 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }

    /// "1.2 GB" / "340 MB"
    static func bytes(_ count: Int) -> String {
        let mb = Double(count) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f MB", mb)
    }

    /// A traffic rate: "4.2 MB/s", "310 kB/s", "—" for nothing.
    ///
    /// Bytes per second, not bits, because that is what `nettop` reports and
    /// converting would invite the reader to compare it against a line speed
    /// quoted in Mbps — which is a real comparison worth making, but not one to
    /// make silently by changing units behind their back.
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "—" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f kB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
