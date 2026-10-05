import SwiftUI
import NetlogsCore

/// Ceiling on rows handed to a `SamplesTable` (plan §8.3: "cap what you render,
/// never what you persist").
///
/// Held over from when this was a SwiftUI `Table`, which used automatic row
/// heights: AppKit measured those by instantiating an `NSHostingView` for every
/// *inserted* row, not just the visible ones — roughly 46 KB each. Handing it a
/// ten-hour session's 38,228 samples took the app from 98 MB to 1.8 GB and hung
/// the main thread for 27 seconds. The cap stays now that the `Table` is gone,
/// because reading 38k rows out of SQLite to build the array is itself ~115 MB.
///
/// File scope, not a static on the view: the view is `@MainActor` and this is
/// read by `SessionDetail`, which is built off the main actor.
let samplesTableRenderCap = 500

/// Fixed. The whole point of not using `Table` here: a fixed height is a height
/// AppKit never has to measure, so a row costs no hosting view.
private let rowHeight: CGFloat = 24

/// Column widths, negotiated the way `Table`'s ranged `.width(min:ideal:max:)`
/// used to negotiate them.
///
/// Fixed widths do not work here. At a 620 pt window the detail column has only
/// ~386 pt to give, the four fixed columns want 344 of it, and the flexible Time
/// column was left with single digits — its header wrapped to "Ti / m / e" and
/// every timestamp rendered as "…". So the fixed columns shrink toward their
/// minimums first, and Time keeps a floor.
///
/// Both the header and the rows take their widths from one of these, computed
/// once per layout, which is what keeps a header above its own column. That was
/// the other narrow-width failure mode: any drift between the two slides the
/// labels off the values.
private struct ColumnWidths {
    let seq: CGFloat
    let rtt: CGFloat
    let load: CGFloat

    /// Time never drops below this, and takes everything the others leave.
    static let timeFloor: CGFloat = 76

    private static let seqRange: (min: CGFloat, ideal: CGFloat) = (40, 56)
    private static let rttRange: (min: CGFloat, ideal: CGFloat) = (62, 92)
    private static let loadRange: (min: CGFloat, ideal: CGFloat) = (88, 104)

    /// `available` is the width left for columns — the caller has already taken
    /// off its own horizontal padding and the inter-column gaps.
    init(available: CGFloat) {
        let idealTotal = Self.seqRange.ideal + 2 * Self.rttRange.ideal + Self.loadRange.ideal
        let minTotal = Self.seqRange.min + 2 * Self.rttRange.min + Self.loadRange.min
        let room = max(0, available - Self.timeFloor)

        // How far between "everything shrunk" and "everything at its ideal" the
        // room allows. Clamped, so a very wide table stops at the ideals rather
        // than growing the pills, and a very narrow one stops at the minimums
        // and lets the row clip instead of eating Time.
        let t = idealTotal > minTotal
            ? min(1, max(0, (room - minTotal) / (idealTotal - minTotal)))
            : 1
        func lerp(_ r: (min: CGFloat, ideal: CGFloat)) -> CGFloat {
            (r.min + t * (r.ideal - r.min)).rounded()
        }
        seq = lerp(Self.seqRange)
        rtt = lerp(Self.rttRange)
        load = lerp(Self.loadRange)
    }
}

/// The ping log.
///
/// Shared by the live and saved screens, which previously used two `Table`s
/// with the same columns at different widths.
///
/// The All/Failures segmented control that used to sit here is gone. Filtering
/// a five-minute window to "failures" was a trap — a session whose outage was
/// an hour ago rendered empty, which reads as "no failures". Failures now have
/// their own sheet, opened from the count in the header, and that sheet sees
/// the whole session.
struct SamplesTable: View {
    let title: String
    let rows: [PingSample]
    /// Total the caller holds, when it is more than it handed over.
    var totalCount: Int?
    var footnote: String?

    /// Says so when the table is showing a window rather than everything —
    /// silently truncating a log is worse than not showing one.
    private var resolvedFootnote: String? {
        if let totalCount, totalCount > rows.count {
            return "most recent \(rows.count.formatted()) of \(totalCount.formatted())"
                + " · export for the full log"
        }
        return footnote
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let footnote = resolvedFootnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)

            // `GeometryReader` is greedy in both axes, which is what the log has
            // to be: `SessionScaffold` gives the summary stack
            // `.layoutPriority(1)` and expects the log to take everything left
            // over, down to the window's bottom edge. The `Table` did that on
            // its own; a bare `ScrollView` does not (the same "will not adopt a
            // height" behaviour the scaffold documents), and without it the
            // detail column stopped short and `NavigationSplitView` sized the
            // sidebar to match, leaving a strip of window under both.
            GeometryReader { geo in
                let widths = ColumnWidths(
                    available: geo.size.width - 2 * Space.m - 4 * Space.s
                )
                VStack(spacing: 0) {
                    columnHeader(widths)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row($0, widths) }
                        }
                    }
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView("No samples yet", systemImage: "waveform.path.ecg")
                    }
                }
            }
        }
    }

    private func columnHeader(_ w: ColumnWidths) -> some View {
        HStack(spacing: Space.s) {
            Text("#").frame(width: w.seq, alignment: .leading)
            Text("Time")
                .frame(minWidth: ColumnWidths.timeFloor, maxWidth: .infinity, alignment: .leading)
            Text("Router").frame(width: w.rtt, alignment: .leading)
            Text("Internet").frame(width: w.rtt, alignment: .leading)
            Text("Load").frame(width: w.load, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.xs)
    }

    private func row(_ sample: PingSample, _ w: ColumnWidths) -> some View {
        HStack(spacing: Space.s) {
            Text("\(sample.id)")
                .font(.tabularSmall)
                .foregroundStyle(.tertiary)
                .frame(width: w.seq, alignment: .leading)
            Text(sample.timestamp, format: .dateTime.hour().minute().second())
                .font(.tabular)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: ColumnWidths.timeFloor, maxWidth: .infinity, alignment: .leading)
            RTTCell(ms: sample.routerMs, lateMs: sample.routerLateMs, ramp: .gateway)
                .frame(width: w.rtt, alignment: .leading)
            RTTCell(ms: sample.internetMs, lateMs: sample.internetLateMs, ramp: .internet)
                .frame(width: w.rtt, alignment: .leading)
            // `Spacer`, not a bare `if`: an unfulfilled `if` in a ViewBuilder is
            // an `EmptyView`, and `.frame(width:)` on an `EmptyView` reserves
            // nothing — so on idle rows (almost all of them) the Load column
            // collapsed and the flexible Time column swallowed the slack,
            // sliding Router and Internet a whole column right of their headers.
            HStack(spacing: 0) {
                if sample.phase != .idle {
                    Chip(text: sample.phase.rawValue)
                        .foregroundStyle(Palette.Chart.load(sample.phase))
                }
                Spacer(minLength: 0)
            }
            .frame(width: w.load)
        }
        .padding(.horizontal, Space.m)
        .frame(height: rowHeight)
        .background { stripe(sample) }
    }

    /// The banding, keyed on the sample's own sequence number rather than on its
    /// position in the array.
    ///
    /// This is the whole reason the `Table` had to go. The log is a sliding
    /// window — one row in at the top, one out at the bottom — so every row's
    /// *index* changes every second, and AppKit's alternating backgrounds are
    /// index-keyed: every visible row's colour flipped on every tick, one row
    /// of new data invalidating the entire viewport once a second, forever.
    /// Keyed on `id`, the band belongs to the sample and travels down with it.
    ///
    /// Drawing it by hand was tried once before and rejected, but that attempt
    /// drew per *cell*, so the fill had to bleed sideways across the column
    /// gutters — which squared off the inset table's rounded ends and left a
    /// hairline between rows. A single full-width row background has no gutters
    /// to cross. `Palette.cardFill` is the same fill the cards use, which is
    /// what `NSColor.alternatingContentBackgroundColors[1]` was matched to.
    @ViewBuilder
    private func stripe(_ sample: PingSample) -> some View {
        if sample.id.isMultiple(of: 2) {
            // Inset and rounded, so the banding reads like the inset table's
            // did rather than running to the window edge.
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.cardFill)
                .padding(.horizontal, Space.s)
        }
    }
}

/// One round-trip time, as a tinted pill.
///
/// Every value is tinted, not just the bad ones. The first pass only coloured
/// outliers on the theory that colouring everything would bury them — but in
/// practice a wall of uncoloured numbers is what buries them, and a green pill
/// carries real information: it says "this one is fine" without being read.
/// Scanning the column becomes a colour task instead of a numeric one, which is
/// the whole point of having a log on screen.
private struct RTTCell: View {
    let ms: Double?
    /// RTT of a reply that arrived after the deadline. Rendered as the number
    /// it is, marked late — the row used to read "timeout", which in this
    /// column looks identical to a dropped packet and is not one.
    var lateMs: Double?
    /// Which leg this column is. The router column and the internet column sit
    /// side by side, and a shared ramp made the left one almost always green.
    let ramp: LatencyGrade.Ramp

    init(ms: Double?, lateMs: Double? = nil, ramp: LatencyGrade.Ramp) {
        self.ms = ms
        self.lateMs = lateMs
        self.ramp = ramp
    }

    var body: some View {
        if let ms {
            pill(ms, tint: Palette.pill(ms, on: ramp), suffix: "ms")
        } else if let lateMs {
            // Warning, not critical. The link answered; it answered slowly.
            pill(lateMs, tint: Palette.bad, suffix: "ms late")
        } else {
            Text("no reply")
                .font(.tabularSmall.weight(.semibold))
                .foregroundStyle(Palette.critical)
                .padding(.horizontal, Space.s - 1)
                .padding(.vertical, 2)
                .background(Palette.fill(Palette.critical), in: Capsule())
        }
    }

    private func pill(_ value: Double, tint: Color, suffix: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(Fmt.ms(value)).font(.tabularSmall.weight(.medium))
            Text(suffix).font(.system(size: 9))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.s - 1)
        .padding(.vertical, 2)
        .background(tint.opacity(Palette.fillOpacity), in: Capsule())
    }
}
