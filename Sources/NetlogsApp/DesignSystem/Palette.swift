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

    /// `nil` means "normal — leave it the default colour". Used where a tint is
    /// an exception rather than a rule, such as a summary card's max.
    ///
    /// The thresholds live in `LatencyGrade` now, in Core, so the score and the
    /// tint read one ramp. Tinting every row would make the table a wall of
    /// colour and hide the outliers it exists to reveal — over the real
    /// database 95% of replies fall below the first step *on both ramps*,
    /// which is what keeps this honest.
    ///
    /// `on:` says which leg the figure describes; there is no default, because
    /// grading a gateway reply on the internet ramp is the bug this replaced.
    static func latency(_ milliseconds: Double, on ramp: LatencyGrade.Ramp) -> Color? {
        grade(LatencyGrade(milliseconds: milliseconds, on: ramp))
    }

    static func grade(_ grade: LatencyGrade) -> Color? {
        switch grade {
        case .fine:     return nil
        case .elevated: return warn
        case .high:     return bad
        case .severe:   return critical
        }
    }

    /// A colour for every latency, for the log table's pills — where "this one
    /// is fine" is worth saying out loud rather than leaving blank.
    static func pill(_ milliseconds: Double, on ramp: LatencyGrade.Ramp) -> Color {
        latency(milliseconds, on: ramp) ?? good
    }

    /// Jitter, on the ramp anchored to the rule the verdict already uses.
    ///
    /// It was tinted with ``latency(_:)``, whose first step was 80 ms, while
    /// `SessionVerdict` calls a session "Unstable latency" at 30. A 50 ms
    /// jitter drove an amber verdict in the header while the number itself
    /// rendered plain white two inches below it.
    static func jitter(_ milliseconds: Double) -> Color? {
        switch JitterGrade(milliseconds: milliseconds) {
        case .fine:     return nil
        case .elevated: return warn
        case .high:     return bad
        case .severe:   return critical
        }
    }

    /// A score's colour is its limiting component's own grade colour, not a
    /// second number→colour ramp. So the score is by construction the same
    /// colour as the card for the thing limiting it, and `nil` — inherit the
    /// default — when nothing is.
    static func score(_ score: NetworkScore) -> Color? {
        guard let constraint = score.constraint else { return nil }
        // From the component's own measurement, not from its score: the score
        // is a reparameterisation, and colouring from the number it came out of
        // rather than the number it went in with would put a rounding step
        // between the tint and the figure beside it.
        switch constraint.kind {
        case .loss:        return loss(constraint.measurement)
        case .latency:     return latency(constraint.measurement, on: .internet)
        case .jitter:      return jitter(constraint.measurement)
        case .bufferbloat: return bufferbloat(constraint.measurement)
        }
    }

    /// Loss, on the verdict's own thresholds.
    static func loss(_ ratio: Double) -> Color? {
        switch LossGrade(ratio: ratio) {
        case .none:   return nil
        case .lossy:  return bad
        case .severe: return critical
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
