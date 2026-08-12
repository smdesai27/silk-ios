import SwiftUI
import SilkCore

/// Mirror: the score, the week, and the log of early applies.
///
/// The wordmark is absent here on purpose — Mirror is the one screen Silk does
/// not sign. The score's pop is dusk-slate, not Now's leaf: one pop per screen,
/// and a different one per screen.
struct MirrorView: View {
    @Environment(AppModel.self) private var model

    private var night: Bool { model.isDownHours }

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(.top, 96)
            week.padding(.top, 52)
            Spacer(minLength: 0)
            footnote.padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Silk.motion(0.45), value: model.lastClosedScore != nil)
        // 110 is measured from the glass in the mockup, the same coordinate space
        // as the bar's 44 — that is what gives the footnote its clearance.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// The score. A closed day's number is written once, when the day ends,
    /// and the hero holds the most recent one. Before any day has closed —
    /// the whole first day — it reads today's running score instead, named
    /// as today, so the screen always answers "how am I doing" with a number.
    /// The stroke is the score, so it is drawn at the score and nowhere else.
    private var hero: some View {
        let score = model.lastClosedScore ?? model.todayScore
        let dayName = model.lastClosedScore != nil ? model.lastClosedDayName
                                                   : SilkStrings.today
        return ZStack {
            EnsoView(fraction: Double(score) / 100.0,
                     color: night ? Silk.scoreRingNight : Silk.scoreRing)
                .frame(width: 190, height: 190)
            VStack(spacing: 6) {
                Text("\(score)")
                    .font(Silk.serif(72))
                    .tracking(Silk.track(-0.045, 72))
                    .frame(height: 72)              // line-height: 1
                    .foregroundStyle(night ? Silk.paperAlpha(0.92) : Silk.ink)
                    // One spoken element — "82, Sunday" — Now's hero pattern:
                    // the day rides as the value, the numeral keeps its label.
                    .accessibilityValue(Text(dayName))
                Text(dayName)
                    .font(Silk.sans(12))
                    .tracking(Silk.track(0.015, 12))
                    .foregroundStyle(night ? Silk.paperAlpha(0.64) : Silk.inkAlpha(0.71))
                    // Already spoken above, as the numeral's value.
                    .accessibilityHidden(true)
            }
        }
    }

    /// No equation. Earlier versions printed the formula ("82 = 100 − 12
    /// attempts − 6 late"); it was removed on purpose — how the score is
    /// calculated is not something the user needs carried on the page.
    private var week: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SilkStrings.week)
                .font(Silk.sans(12))
                .tracking(Silk.track(0.04, 12))
                .foregroundStyle(night ? Silk.paperAlpha(0.59) : Silk.inkAlpha(0.69))
                .padding(.bottom, 16)
            WeekBand(closedScores: model.closedWeekScores, night: night)
        }
        .padding(.horizontal, 46)
    }

    /// The key log: exceptions spent, and when the last one was.
    ///
    /// The canon's second glyph is ⚿ (U+269F). No font iOS ships draws it, and it
    /// lands as tofu in the design's own prototype too — visible in the handoff
    /// render. The SF Symbol is the same key at the same optical size.
    private var footnote: some View {
        Text("\(Image(systemName: "key")) \(model.keyLog)")
            .font(Silk.serif(12.5))
            .tracking(Silk.track(0.02, 12.5))
            .foregroundStyle(night ? Silk.paperAlpha(0.56) : Silk.inkAlpha(0.67))
    }
}
