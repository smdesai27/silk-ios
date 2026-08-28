import SwiftUI
import SilkCore

/// Mirror: the score, the week, and the log of early applies — standing in a
/// hedgerow that is every day since install.
///
/// The wordmark is absent here on purpose — Mirror is the one screen Silk does
/// not sign.
///
/// Two things changed with the planting. The **loom** is gone: it drew this
/// month as a woven rectangle in the middle of the screen and crowded the
/// score, and the border now carries duration better than it did. And the score
/// and the week became **one centred column** on a single 190pt axis — the
/// ensō's own diameter — rather than a centred numeral above a band that ran
/// the full width at 46pt margins. Nothing else about either is different.
///
/// At night Mirror no longer takes dusk-slate. The hedgerow is the only colour
/// on the screen and the score reads in plain paper light, which is what let
/// the greens go as deep as they do.
struct MirrorView: View {
    @Environment(AppModel.self) private var model

    /// How much of the planting is in. Linear on purpose — the stagger inside
    /// `Hedgerow` is what shapes the growth, and curving it twice reads as a
    /// lurch. 1.15s is atmosphere, so it is allowed past the 350–450ms band the
    /// canon sets for discrete UI.
    @State private var grown: Double = 0

    /// The hedgerow's age. **`AppModel` carries no days-since-install figure**,
    /// so this is the design's year-three planting until the ledger grows one.
    private static let plantingAge = 600_000

    private var night: Bool { model.isDownHours }

    var body: some View {
        ZStack {
            Hedgerow(count: Self.plantingAge, night: night, progress: grown)
                .ignoresSafeArea()

            // The column, centred in what is left above the key log. The seat
            // below it is the footnote's, so "centred" means centred between the
            // top glass and the log — not centred in the whole page, which would
            // sit visibly low.
            VStack(spacing: 0) {
                cluster.frame(maxHeight: .infinity)
                Color.clear.frame(height: 126)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footnote.padding(.bottom, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Silk.motion(0.45), value: model.lastClosedScore != nil)
        // 110 is measured from the glass in the mockup, the same coordinate space
        // as the bar's 44 — that is what gives the footnote its clearance.
        .ignoresSafeArea(.container, edges: .bottom)
        // The planting comes in with the page. It is keyed to the pager and not
        // to `onAppear`, because a `TabView(.page)` builds every page up front —
        // `onAppear` fires for Mirror while Now is still on screen, and the whole
        // growth would be spent before the swipe.
        .onChange(of: model.page, initial: true) { _, page in
            guard page == 1 else { return }
            guard Self.earnsCeremony() else { grown = 1; return }
            grown = 0
            Task { @MainActor in
                withAnimation(.linear(duration: 1.15)) { grown = 1 }
            }
        }
    }

    /// Whether this visit earns the grow-in. The planting used to come in on
    /// every swipe to Mirror, and a ceremony repeated on demand reads as a
    /// trick, not a garden — a hedge does not regrow because you looked away.
    /// So the growth is spent: the first three visits ever play it in full
    /// (the planting is new; let it arrive), and after that it replays only
    /// when Mirror has not been seen for six hours — roughly a sitting, long
    /// enough that the return reads as coming back rather than flipping pages.
    /// Every other visit finds the border already standing. UserDefaults, not
    /// the App Group store: this is the screen's own memory of having been
    /// seen, no other process has any claim on it, and losing it costs one
    /// extra ceremony. Sanil's call (2026-08-25).
    private static func earnsCeremony(now: Date = .now) -> Bool {
        let d = UserDefaults.standard
        let plays = d.integer(forKey: "silk.mirror.grows")
        let last = d.double(forKey: "silk.mirror.grown.at")
        if plays >= 3,
           now.timeIntervalSinceReferenceDate - last < 6 * 3600 { return false }
        d.set(plays + 1, forKey: "silk.mirror.grows")
        d.set(now.timeIntervalSinceReferenceDate, forKey: "silk.mirror.grown.at")
        return true
    }

    /// The score over the week, sharing one axis.
    private var cluster: some View {
        VStack(spacing: 0) {
            hero
            week.padding(.top, 52)
        }
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
    ///
    /// 190 wide and centre-aligned: the band is the ensō's base, not a rule
    /// across the page, so the label sits over its middle rather than its
    /// leading edge.
    private var week: some View {
        VStack(spacing: 16) {
            Text(SilkStrings.week)
                .font(Silk.sans(12))
                .tracking(Silk.track(0.04, 12))
                .foregroundStyle(night ? Silk.paperAlpha(0.59) : Silk.inkAlpha(0.69))
            WeekBand(closedScores: model.closedWeekScores, night: night)
        }
        .frame(width: 190)
    }

    /// Today's unlocks — how many times a door was opened since the day began.
    ///
    /// It read the lifetime key journal until now ("3 · Jul 12"). Every other
    /// element on this page is one day, and a total since install was the only
    /// thing here that could not be acted on.
    ///
    /// The canon's second glyph is ⚿ (U+269F). No font iOS ships draws it, and it
    /// lands as tofu in the design's own prototype too — visible in the handoff
    /// render. The SF Symbol is the same key at the same optical size.
    ///
    /// Spoken as a sentence because it cannot be read as one: a glyph beside a
    /// numeral reaches VoiceOver as "key, 2".
    private var footnote: some View {
        let n = model.unlocksToday
        return Text("\(Image(systemName: "key")) \(n)")
            .font(Silk.serif(12.5))
            .tracking(Silk.track(0.02, 12.5))
            .foregroundStyle(night ? Silk.paperAlpha(0.56) : Silk.inkAlpha(0.67))
            .accessibilityLabel(Text("\(n) \(n == 1 ? SilkStrings.unlockToday : SilkStrings.unlocksToday)"))
    }
}
