import SwiftUI
import SilkCore

// The three pieces the current design added to Mirror, plus the shield the door
// rows now raise. All ported from the handoff prototype and the stylesheet
// it loads.

// MARK: - The week band

/// Seven days as one graded band. It replaced a bar chart, and the reasoning is
/// the point: **one colour, opacity carries the score, darker is better.** No
/// axis, no numerals, no day labels — the band is read as texture, and the exact
/// figures are deliberately withheld. Today's seat is *bare*, never zero: a
/// score is written once, when the day closes.
struct WeekBand: View {
    /// Six closed days, oldest first. Today is not among them — it has no score.
    /// `nil` is a day that was never scored (it predates the install), and it
    /// draws the same bare seat today does.
    var closedScores: [Int?]
    var night: Bool

    /// Day carries dusk-slate. Night carries paper, scaled to 0.78 so the top of
    /// the ramp reads as a written day and not as a lamp — Mirror's night colour
    /// is the hedgerow, and the band stays out of its way.
    private var hue: Color { night ? Silk.paper : Silk.duskSlate }
    private var ramp: Double { night ? 0.78 : 1 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(closedScores.enumerated()), id: \.offset) { i, score in
                seat(score, leading: i == 0, trailing: false)
            }
            // Today: an empty seat, waiting to be written. Never a zero.
            seat(nil, leading: false, trailing: true)
        }
        .frame(height: 22)
        // The band is read as texture and the figures are deliberately
        // withheld — that holds for VoiceOver too. "Week" above it is the
        // spoken part.
        .accessibilityHidden(true)
    }

    /// A written day is a fill; an unwritten one is a 1pt ring. Fill-versus-ring
    /// is what separates them, not opacity — so a maximum score and an empty seat
    /// can never be confused.
    @ViewBuilder
    private func seat(_ score: Int?, leading: Bool, trailing: Bool) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: leading ? 2 : 0,
            bottomLeadingRadius: leading ? 2 : 0,
            bottomTrailingRadius: trailing ? 2 : 0,
            topTrailingRadius: trailing ? 2 : 0
        )
        if let score {
            shape.fill(hue.opacity(Self.opacity(for: score) * ramp))
        } else {
            shape.strokeBorder(hue.opacity(night ? 0.14 : 0.16), lineWidth: 1)
        }
    }

    /// The handoff hand-sets six opacities against six scores rather than giving
    /// a formula (74→.52, 88→.82, 79→.62, 91→.94, 63→.34, 82→.70). They are
    /// illustrative, so this maps the range monotonically instead of hard-coding
    /// them: a score is legible as *darker is better* and nothing more, which is
    /// exactly what the card asks for. The domain is deliberately narrow — a
    /// full 0–100 spread would leave every real week looking identical.
    static func opacity(for score: Int) -> Double {
        let t = (Double(score) - 55) / 40          // 55…95 → 0…1
        return min(0.94, max(0.20, 0.20 + t * 0.74))
    }
}

// MARK: - The shield, in-app

/// What a blocked app shows instead of itself — and, in this design, what a door
/// row raises when you tap it. One button, no escape hatch, no "just 5 more
/// minutes." It fades in over 450ms and never slams.
///
/// The real shield is drawn by `SilkShield`'s extension against
/// `ShieldConfiguration`, which is a fixed-slot API and cannot carry the serif
/// numeral. This in-app copy is the honest one; they will not match exactly, and
/// the extension is the one users meet at the wall.
struct ShieldOverlay: View {
    var title: String
    var app: String
    var night: Bool
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            // The spec's ground at the spec's alphas: .92 day, .94 night, under
            // a backdrop-filter blur(20px). The blur half
            // lives at the root — RootView blurs the stage the shield covers,
            // which over Silk's opaque grounds is the same light — so this
            // layer is the tinted veil alone. It replaced .ultraThinMaterial,
            // whose system grey argued with the paper.
            //
            // The colours are each face's own ground, as the wheel's veil is:
            // the handoff wrote night's as rgba(26,28,32,.94), the floor of a
            // slate radial the ground stopped drawing, and a blue-grey wall
            // over a warm black page announced itself at every edge. The alphas
            // are the spec's and unchanged — the wall is a wall because you can
            // just see the page through it.
            (night ? Silk.Night.ground.opacity(0.94)
                   : Silk.paper.opacity(0.92))

            VStack(spacing: 6) {
                // EnsoMark hides itself from VoiceOver; the title below is
                // the shield's voice.
                EnsoMark(color: night ? Silk.paperAlpha(0.40) : Silk.inkAlpha(0.60))
                    .frame(width: 15, height: 15)
                    .padding(.bottom, 16)
                Text(title)
                    .font(Silk.serif(40))
                    .tracking(Silk.track(-0.02, 40))
                    .foregroundStyle(night ? Silk.paperAlpha(0.90) : Silk.ink)
                    .accessibilityIdentifier("silk.shield.title")
                if !app.isEmpty {
                    Text(app)
                        .font(Silk.sans(13.5))
                        .foregroundStyle(night ? Silk.paperAlpha(0.62) : Silk.inkAlpha(0.70))
                }
                Button(action: onDismiss) {
                    Text(SilkStrings.ok)
                        .font(Silk.sans(14, weight: .medium))
                        .foregroundStyle(night ? Silk.paperAlpha(0.80) : Silk.ink)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 11)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(night ? Silk.paperAlpha(0.16) : Silk.inkAlpha(0.16),
                                        lineWidth: 1)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 30)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Mirror parts") {
    ScrollView {
        ForEach([false, true], id: \.self) { night in
            VStack(spacing: 34) {
                WeekBand(closedScores: [74, 88, 79, 91, 63, 82], night: night)
                    .padding(.horizontal, 46)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
            .background(night ? Silk.Night.ground : Silk.paper)
        }
    }
}
#endif
