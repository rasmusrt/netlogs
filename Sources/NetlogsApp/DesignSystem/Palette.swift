import SwiftUI
import NetlogsCore

/// The single home for status colour.
///
/// Status colour was previously literal at eighteen call sites, with the
/// bufferbloat ramp typed out twice (`BufferbloatCard.tint` and again inline in
/// the throughput sheet) and the `0.12` fill opacity magic-numbered three
/// times. Semantic greys were already handled well by `.secondary` /
/// `.tertiary` / `.separator`, so this covers only the part that was not.
///
/// Everything here is a system colour, so both appearances and the accessibility
/// contrast settings are handled for us — see the "refined native" direction.
enum Palette {

    // MARK: - Surfaces

    /// Card fill.
    ///
    /// A *relative* fill, not a fixed colour, and that is the whole point.
    /// Every fixed value tried here was wrong somewhere: matched to the window
    /// it vanished, matched to the ping log's stripe it came out darker than
    /// its own ground in dark mode, and painting an explicit canvas to make a
    /// fixed value work turned the summary into an opaque slab against a
    /// translucent log.
    ///
    /// `.quinary` composites over whatever is actually behind it — white at a
    /// low opacity in dark, black in light — so a card is always exactly one
    /// step from its ground, in either appearance, over an opaque background or
    /// a vibrant one. Measured, it lands within a point or two of the values
    /// that were being hand-picked (41 on a 30 ground in dark; ~242 on white),
    /// and it is the same construction as
    /// `NSColor.alternatingContentBackgroundColors[1]`, which is why the cards
    /// and the ping log's striped rows agree without either being tuned to the
    /// other.
    static let cardFill: AnyShapeStyle = AnyShapeStyle(.quinary)

    /// Banding for alternating rows *inside* a card. One step stronger than
    /// ``cardFill``, because it sits on top of it — `.quinary` on `.quinary`
    /// is invisible.
    static let rowStripe: AnyShapeStyle = AnyShapeStyle(.quaternary)

    // MARK: - Status ramp

    static let good = Color.green
    static let warn = Color.yellow
    static let bad = Color.orange
    static let critical = Color.red

    /// The wash behind a status-tinted surface — badges, banners, bands.
    static let fillOpacity: Double = 0.12

    static func fill(_ color: Color) -> Color { color.opacity(fillOpacity) }

    // MARK: - Domain ramps

    static func grade(_ grade: BufferbloatGrade) -> Color {
        switch grade {
        case .excellent: return good
        case .moderate:  return warn
        case .poor:      return bad
        case .severe:    return critical
        }
    }

    static func bufferbloat(_ milliseconds: Double) -> Color {
        grade(BufferbloatGrade(milliseconds: milliseconds))
    }

    static func verdict(_ verdict: SessionVerdict) -> Color {
        switch verdict.severity {
        case 0:  return verdict == .insufficientData ? .secondary : good
        case 1:  return warn
        case 2:  return bad
        default: return critical
        }
    }

    /// Latency thresholds for the log table, in milliseconds.
    ///
    /// Deliberately generous, and deliberately returning `nil` below the first
    /// one. Tinting every row would make the table a wall of colour and hide
    /// the outliers it exists to reveal; only values worth a second look get
    /// painted. These are host-agnostic — a router at 80 ms and an internet
    /// host at 80 ms are both worth noticing.
    enum Latency {
        static let elevated: Double = 80
        static let high: Double = 200
        static let severe: Double = 500
    }

    /// A colour for every latency, for the log table's pills — where "this one
    /// is fine" is worth saying out loud rather than leaving blank.
    static func pill(_ milliseconds: Double) -> Color {
        latency(milliseconds) ?? good
    }

    /// `nil` means "normal — leave it the default colour". Used where a tint is
    /// an exception rather than a rule, such as a summary card's max.
    static func latency(_ milliseconds: Double) -> Color? {
        switch milliseconds {
        case ..<Latency.elevated: return nil
        case ..<Latency.high:     return warn
        case ..<Latency.severe:   return bad
        default:                  return critical
        }
    }

    // MARK: - Chart

    enum Chart {
        /// The primary trace. Fixed rather than `.accentColor` so it can never
        /// collide with the status ramp when someone picks a red accent.
        static let internet = Color.blue
        /// The secondary trace, deliberately quiet.
        static let router = Color.secondary

        static let downloadBand = Color.blue
        static let uploadBand = Color.purple
        static let bandOpacity: Double = 0.10
        static let envelopeOpacity: Double = 0.15

        static func load(_ phase: LoadPhase) -> Color {
            switch phase {
            case .downloading: return downloadBand
            case .uploading:   return uploadBand
            case .idle:        return .clear
            }
        }

        static func outage(_ scope: OutageScope) -> Color {
            switch scope {
            case .router:   return Palette.warn
            case .internet: return Palette.bad
            case .both:     return Palette.critical
            }
        }
    }
}
