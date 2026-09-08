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

    /// The hedgerow's age, in the canvas's own units. Seeded at the floor so
    /// the first frame draws a Day-one border rather than an empty one; the
    /// page's own `onChange` replaces it with the reading below.
    @State private var age = Self.plantingAge()

    /// A day's growth, and therefore the floor: the border is never emptier
    /// than the day it was planted (docs/design/canvas/Main.dc.html:182).
    private static let dayOne = 550

    /// Every day since install, at 550 a day.
    ///
    /// It was `600_000` — a constant — so every install, on its first morning,
    /// opened on the design's *year-three* hedge in full flower. The whole
    /// point of the planting is that it says how long you have kept this up,
    /// and a border that arrives finished says nothing at all; worse, it can
    /// only ever stand still, so the one thing it is for could never happen.
    ///
    /// The canvas's own ages fall straight out of 550/day and are what the
    /// ladder was tuned against: Day one 550, Month one 16,500 (30 × 550),
    /// Year one 200,750, Year three 602,250, Year five 1,004,300 — the last of
    /// which is where the cap sits, because `Hedgerow` reads lushness as
    /// `sqrt(count / 1,000,000)` and has nothing left to say past it.
    ///
    /// Calendar days, not 24-hour spans, and deliberately not the Silk day
    /// (`DayBoundary.dayStart`, anchored on down-hours end): that boundary
    /// would move the border's growth by up to seven hours against the
    /// score beside it, and nothing on this page can tell a day of hedge
    /// from a day and seven hours of it. What must not vary is the count
    /// itself — one more each morning, whichever morning.
    private static func plantingAge(now: Date = .now) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: SharedStore.firstRun()),
                                      to: cal.startOfDay(for: now)).day ?? 0
        return min(1_000_000, max(dayOne, days * dayOne))
    }

    /// Reduce Motion takes the ceremony, not the border. The planting is the
    /// screen's meaning and it stays; what goes is the 1.15s creep across it,
    /// which is a large-area animation of exactly the kind the setting is for.
    /// The hedge is simply already standing when the page arrives.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var night: Bool { model.isDownHours }

    var body: some View {
        // The week, read ONCE for the whole page.
        //
        // `closedWeekScores` walks the seven buckets against the day records on
        // every call, and this body used to ask for it four times — once for the
        // band, and three more through an accessor on the model that returned
        // nothing but its last element (deleted since, with its last reader).
        // The caches under it (`dayRecordsCache`, `weekAttemptsCache`)
        // make each call cheap; they do not make four of them one, and a body
        // that asks the same question four times is a body whose cost moves with
        // whatever the answer is derived from next. So the answer is taken here
        // and handed down.
        let scores = model.closedWeekScores
        let lastClosed = scores.last ?? nil
        ZStack {
            Hedgerow(count: age, night: night, progress: grown)
                .ignoresSafeArea()

            // The column, centred in what is left above the key log. The seat
            // below it is the footnote's, so "centred" means centred between the
            // top glass and the log — not centred in the whole page, which would
            // sit visibly low.
            VStack(spacing: 0) {
                cluster(scores: scores, lastClosed: lastClosed)
                    .frame(maxHeight: .infinity)
                Color.clear.frame(height: 126)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footnote.padding(.bottom, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Silk.motion(0.45), value: lastClosed != nil)
        // 110 is measured from the glass in the mockup, the same coordinate space
        // as the bar's 44 — that is what gives the footnote its clearance.
        .ignoresSafeArea(.container, edges: .bottom)
        // The planting comes in with the page. It is keyed to the pager and not
        // to `onAppear`, because a `TabView(.page)` builds every page up front —
        // `onAppear` fires for Mirror while Now is still on screen, and the whole
        // growth would be spent before the swipe.
        .onChange(of: model.page, initial: true) { _, page in
            age = Self.plantingAge()
            guard page == 1 else {
                // LEAVING. If the next arrival is going to play the ceremony,
                // go bare here, off-screen, where nothing is watching.
                //
                // Resetting on arrival is what produced the snap: a replayed
                // ceremony found the border standing from last time, cleared it
                // to nothing on the frame the page settled, and grew it back.
                // The pager's selection lands when the swipe finishes, so this
                // fires with Mirror already off screen, and the swipe *back*
                // then finds a page that is bare because it was left bare.
                //
                // Conditional, because the alternative is worse: reset on every
                // leave and an ordinary revisit — one that has no ceremony to
                // spend — would arrive bare and pop to full instead.
                //
                // One residual, named rather than hidden: the six-hour window
                // can open while the app is alive and Mirror is never left
                // again, and that one visit still snaps. Closing it would mean
                // waking a timer for a border nobody is looking at.
                // Never under Reduce Motion: a bare arrival there is a cut to
                // full at the settle, the one transition Silk never makes.
                if !reduceMotion && Self.wouldEarnCeremony() { grown = 0 }
                return
            }
            // Only a page that arrives BARE plays. A border left standing —
            // the six-hour window opened after the last leave — stays; the
            // ceremony waits for the next arrival the leave below left bare.
            // Clearing a standing border here was the snap this branch exists
            // to prevent, by a wider door than the one it first closed.
            guard Self.wouldEarnCeremony(), grown == 0 else { grown = 1; return }
            // Reduce Motion: the hedge is there, it simply did not creep in —
            // and the visit is not spent, so the ceremony waits for a viewer
            // who will see it.
            guard !reduceMotion else { grown = 1; return }
            Self.spendCeremony()
            grown = 0
            Task { @MainActor in
                withAnimation(.linear(duration: 1.15)) { grown = 1 }
            }
        }
    }

    /// Whether a visit right now would earn the grow-in. The planting used to
    /// come in on every swipe to Mirror, and a ceremony repeated on demand
    /// reads as a trick, not a garden — a hedge does not regrow because you
    /// looked away. So the growth is spent: the first three visits ever play it
    /// in full (the planting is new; let it arrive), and after that it replays
    /// only when Mirror has not been seen for six hours — roughly a sitting,
    /// long enough that the return reads as coming back rather than flipping
    /// pages. Every other visit finds the border already standing.
    /// UserDefaults, not the App Group store: this is the screen's own memory
    /// of having been seen, no other process has any claim on it, and losing it
    /// costs one extra ceremony. Sanil's call (2026-08-25).
    ///
    /// Asking and spending are two calls, not one. The leave path has to ask
    /// whether the *next* arrival will earn a ceremony so it can go bare in
    /// advance, and a question that quietly consumed the answer would spend the
    /// growth on a page nobody is looking at.
    private static func wouldEarnCeremony(now: Date = .now) -> Bool {
        let d = UserDefaults.standard
        let plays = d.integer(forKey: "silk.mirror.grows")
        let last = d.double(forKey: "silk.mirror.grown.at")
        return !(plays >= 3 && now.timeIntervalSinceReferenceDate - last < 6 * 3600)
    }

    /// Marks one ceremony spent. Called on arrival and nowhere else.
    private static func spendCeremony(now: Date = .now) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: "silk.mirror.grows") + 1, forKey: "silk.mirror.grows")
        d.set(now.timeIntervalSinceReferenceDate, forKey: "silk.mirror.grown.at")
    }

    /// The score over the week, sharing one axis.
    private func cluster(scores: [Int?], lastClosed: Int?) -> some View {
        VStack(spacing: 0) {
            hero(lastClosed: lastClosed)
            week(scores: scores).padding(.top, 52)
        }
    }

    /// The score. A closed day's number is written once, when the day ends,
    /// and the hero holds the most recent one. Before any day has closed —
    /// the whole first day — it reads today's running score instead, named
    /// as today, so the screen always answers "how am I doing" with a number.
    /// The stroke is the score, so it is drawn at the score and nowhere else.
    private func hero(lastClosed: Int?) -> some View {
        let score = lastClosed ?? model.todayScore
        let dayName = lastClosed != nil ? model.lastClosedDayName
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
    private func week(scores: [Int?]) -> some View {
        VStack(spacing: 16) {
            Text(SilkStrings.week)
                .font(Silk.sans(12))
                .tracking(Silk.track(0.04, 12))
                .foregroundStyle(night ? Silk.paperAlpha(0.59) : Silk.inkAlpha(0.69))
            WeekBand(closedScores: scores, night: night)
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
            .accessibilityLabel(Text(SilkStrings.unlocksToday(n)))
    }
}
