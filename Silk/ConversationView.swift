import SwiftUI
import SilkCore

// The conversation: the thread over the dimmed page, and the model that owns
// it. The bar itself lives in Chrome.swift; this file is everything that
// appears once the bar has been spoken into.
//
// The choreography is the "docked" model, chosen over two rejected
// alternatives (handoff README.md:196-212): the bar rises to invite, docks
// home on the first send, and stays docked for the rest of the conversation.
// Rising means "say something"; docking means "we are talking now." Nothing
// in this file may improvise on that.

// ============================================================
// The model
// ============================================================

/// The live conversation. Cleared on blur — a thread is a moment, not a log,
/// and Silk keeps no transcript (README.md:292 `thread … cleared on blur`).
///
/// Turns are keyed by a stable id, never by index: replies land
/// asynchronously, and an index-keyed update rewrites the wrong turn once a
/// second question is asked before the first answer arrives. The handoff
/// calls this out by name (README.md:301-303), and the prototype threads an
/// `id` through `send`/`undoTurn` for exactly this reason
/// (Silk Mockup.dc.html:341-352).
@MainActor
@Observable
final class ConversationModel {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        /// Your line, verbatim. What you typed is yours — it is never edited.
        var you: String
        /// nil while the reply is in flight; the slot renders "…" until the
        /// real words land (~480ms in previews) and fade in
        /// (Silk Mockup.dc.html:342 seeds `msg: '…'`).
        var reply: String?
        /// A turn that changed something carries the way back. The closure
        /// captures the prior state wholesale — the prototype captures the
        /// previous `doors` array and restores it in one move (README.md:303-304)
        /// — so undo needs no diffing and no knowledge of what the turn did.
        /// It reports whether the restore landed: an offer can expire under
        /// the pill (a later ledger mutation retires every earlier offer),
        /// and a receipt may only be written over a restore that happened.
        var undo: (() -> Bool)?
        /// Undone turns must not land a late reply over "Put back." — the
        /// 480ms window is small but real.
        var undone = false

        /// Closures don't compare, but whether the pill shows does — and the
        /// thread animates on this equality, so everything the eye can see
        /// must participate in it.
        static func == (lhs: Turn, rhs: Turn) -> Bool {
            lhs.id == rhs.id && lhs.you == rhs.you && lhs.reply == rhs.reply
                && lhs.undone == rhs.undone && (lhs.undo == nil) == (rhs.undo == nil)
        }
    }

    private(set) var turns: [Turn] = []

    /// Mirrored from the root's FocusState (`onChange`) — FocusState cannot
    /// live outside a view, so the model holds its shadow. Blur clears the
    /// thread here, in one place, exactly as the prototype's `onCmdBlur`
    /// does (Silk Mockup.dc.html:387).
    var focused = false {
        didSet { if !focused { clear() } }
    }

    /// The blur, as the conversation's own decision rather than the view's.
    ///
    /// Every teardown path in the app calls this instead of writing `focused`
    /// directly, because there is one case where a blur must not land yet: a
    /// turn still at "…". `AppModel.handle` is async and suspends twice before
    /// it decides anything — the widener's parse and the beat — and it applies
    /// what it decided whether or not this conversation is still on screen. With
    /// the thread already cleared, `land` addresses an id that is gone and
    /// swallows the receipt: the door shuts, the haptic fires, and there is no
    /// sentence saying so and no Undo pill to take it back. "Receipts never
    /// lie", inverted — the state moved and nothing said so — and a tighten is
    /// the one thing canon will not let the user loosen again before tomorrow.
    ///
    /// So the teardown is DEFERRED by one reply, never abandoned. The keyboard
    /// still goes down (that is the view's own business and happens either
    /// way); only the thread stands, over the still-dimmed page, until the
    /// receipt lands on it. The next tap finds nothing pending and clears as it
    /// always did — a thread is still a moment and not a log.
    ///
    /// This is the rule the standing wait already had one beat later, and it
    /// lives on the model for the reason that one did not: the tap-out catcher
    /// writes this shadow directly and never passes through the view's
    /// `onChange`, so a guard written in either place alone is a guard with a
    /// way around it.
    ///
    /// It cannot hang the thread open: `handle` resolves every turn it starts
    /// on every path — landed, dropped, or answered later by the wait — and the
    /// widener's own deadline bounds the longest of those at two seconds
    /// (`SilkModelParser.deadline`).
    func blur() {
        guard !hasPendingTurn else { return }
        focused = false
    }

    /// The `has-turns` class, as state: thread non-empty ⇒ the bar is docked
    /// even while focused (Silk Mockup.dc.html:28, 389).
    var hasTurns: Bool { !turns.isEmpty }

    /// A turn still waiting on the pipeline — the one the thread is drawing as
    /// "…" right now.
    ///
    /// Blur may not tear the thread down while one stands. `handle` is async
    /// and suspends twice before it decides anything — the widener's parse and
    /// the beat — and `apply` runs on the far side of both regardless of what
    /// the screen did in between. With the thread cleared, `land` addresses an
    /// id that is gone and swallows the receipt: the door shuts, the haptic
    /// fires, and there is no sentence saying so and no Undo pill to take it
    /// back. "Receipts never lie" inverted — the state moved and nothing said
    /// so — and a tighten is the one thing canon will not let the user loosen
    /// again before tomorrow.
    ///
    /// The standing wait already suppresses the blur for exactly this reason
    /// (SilkApp.swift), and this is the same rule one beat earlier. The thread
    /// is still a moment and not a log: the teardown is DEFERRED by one reply,
    /// never abandoned, and the widener's own deadline bounds that reply at two
    /// seconds (SilkModelParser.deadline). The next tap-out finds nothing
    /// pending and clears as it always did.
    var hasPendingTurn: Bool { turns.contains { $0.reply == nil } }

    /// The bar's rise condition — focused with nothing said yet. First send
    /// flips `hasTurns` and the bar glides home in one continuous move.
    var raised: Bool { focused && !hasTurns }

    /// The page dims on focus alone, and stays dim while docked-in-conversation:
    /// the CSS keys the stage on `input:focus`, not on `has-turns`
    /// (Silk Mockup.dc.html:24-25).
    var stageDimmed: Bool { focused }

    /// Only the last three are kept in view (README.md:223,
    /// Silk Mockup.dc.html:391 `slice(-3)`); older ones have already
    /// dissolved into the top fade.
    var visibleTurns: [Turn] { Array(turns.suffix(3)) }

    /// Appends a pending turn and returns its id, which the reply must quote
    /// back to `land`. Follow-ups append — a second send never replaces the
    /// first turn (README.md:232-233).
    @discardableResult
    func ask(_ you: String) -> Turn.ID {
        let turn = Turn(you: you, reply: nil, undo: nil)
        turns.append(turn)
        return turn.id
    }

    /// The reply arrives, addressed by id. A turn that blurred away or was
    /// already undone swallows its late reply silently — there is nothing
    /// left to say it to.
    func land(_ reply: String, undo: (() -> Bool)? = nil, for id: Turn.ID) {
        guard let i = turns.firstIndex(where: { $0.id == id }), !turns[i].undone else { return }
        turns[i].reply = reply
        turns[i].undo = undo
    }

    /// A turn whose answer is never coming: the wait it was holding went stale
    /// while she was elsewhere, and the ask went with it.
    ///
    /// Not a refusal — nothing refused it — and not silence either. An
    /// unresolved "…" left standing is the app claiming to still be thinking
    /// about a sentence it has already forgotten, and it would sit there until
    /// the next blur. The sentence goes the way an unsent one does.
    func drop(_ id: Turn.ID) {
        turns.removeAll { $0.id == id }
    }

    /// The way back closes on the clock, not only on a tap: the Undo setting
    /// is the window, and when it shuts the pill goes without a word. The
    /// reply stands — only the offer is withdrawn. A turn already undone
    /// keeps its "Put back."; there is nothing left here to expire.
    func expireUndo(_ id: Turn.ID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].undo = nil
    }

    /// Runs the turn's way back. When it lands, the reply is rewritten to
    /// "Put back." and the pill drops (Silk Mockup.dc.html:348-352) — the
    /// change is its own receipt, no toast, no second sentence. When the
    /// offer expired under the pill (a later mutation beat the tap), only
    /// the pill goes: the reply keeps stating what actually happened, and
    /// the turn is not marked undone, because it wasn't. Receipts never lie.
    func undo(_ id: Turn.ID) {
        guard let i = turns.firstIndex(where: { $0.id == id }), let action = turns[i].undo else { return }
        let landed = action()
        turns[i].undo = nil
        guard landed else { return }
        turns[i].reply = SilkStrings.putBack
        turns[i].undone = true
    }

    func clear() { turns = [] }
}

// ============================================================
// The stage
// ============================================================

/// The page yielding to the conversation: opacity .05, blur 7, hit-testing
/// off, the opacity over 450ms on the one curve (Silk Mockup.dc.html:21,
/// 24-25). The blur radius snaps rather than animating — an animating radius
/// re-renders the whole stage offscreen every frame, and behind a fade to .05
/// the difference cannot be seen. The root wraps the pager and the dots in
/// this; the wordmark is never wrapped — it is the one thing that never
/// yields (README.md:203-205).
private struct SilkStage: ViewModifier {
    var dimmed: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: dimmed ? 7 : 0)
            .animation(nil, value: dimmed)
            .opacity(dimmed ? 0.05 : 1)
            .allowsHitTesting(!dimmed)
            .animation(Silk.motion(0.45), value: dimmed)
    }
}

extension View {
    /// `.fx-stage` under `input:focus` — apply to everything behind the
    /// conversation except the wordmark and the bar.
    func silkStage(dimmed: Bool) -> some View {
        modifier(SilkStage(dimmed: dimmed))
    }
}

// ============================================================
// The thread
// ============================================================

/// The running exchange, column-justified to the bottom of its box so new
/// turns push old ones up and out through the top fade. Expects a
/// glass-bounded, keyboard-respecting container: it ignores the container's
/// safe area itself, so its 116/150 insets are measured from the glass — and
/// from the keyboard's top edge when one is up, which keeps the thread 54pt
/// clear of the docked bar in both worlds.
struct ConversationThread: View {
    var model: ConversationModel
    var night: Bool

    var body: some View {
        VStack(spacing: 26) {                            // gap: 26px (README.md:215-216)
            ForEach(model.visibleTurns) { turn in
                TurnCell(turn: turn,
                         newest: turn.id == model.visibleTurns.last?.id,
                         night: night) {
                    model.undo(turn.id)
                }
            }
        }
        // justify-content: flex-end — the newest words sit nearest the bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // New turns fade in on the one curve, short end of the band — the
        // canon grants no second easing family (canon.md: one motion curve,
        // 350–450ms).
        .animation(Silk.motion(0.35), value: model.visibleTurns)
        // overflow: hidden + the top fade in one stroke: the mask is sized to
        // the box, so anything pushed past its top edge is already invisible —
        // old turns dissolve into the paper rather than clipping
        // (Silk Mockup.dc.html:30-31).
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.24),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .padding(.horizontal, 40)                        // left/right: 40px (README.md:214)
        .padding(.top, 116)                              // top: 116px
        .padding(.bottom, 150)                           // bottom: 150px
        // The box is measured from the glass, not the safe area — and only
        // `.container` is ignored, so the keyboard still lifts the bottom
        // inset's origin to its own top edge.
        .ignoresSafeArea(.container)
        // A bare identifier on a plain VStack is stamped onto every
        // descendant, and the turns' own ids (silk.turn.reply, silk.turn.undo)
        // drown under it. Declaring the stack a container keeps the name on
        // the box and the children's names on the children.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("silk.thread")
    }
}

/// One turn: your line, Silk's reply, and — when the turn changed something —
/// the way back.
private struct TurnCell: View {
    var turn: ConversationModel.Turn
    var newest: Bool
    var night: Bool
    var onUndo: () -> Void

    /// Only the newest turn at full strength; the past drops to .4
    /// (Silk Mockup.dc.html:52, 391-394 `ex-past`). Applied piecewise below
    /// rather than once on the cell: a cell-wide `.opacity(0.4)` renders the
    /// dim but silently stops the Undo pill's taps — the press fell through
    /// to the tap-out catcher and tore the whole thread down.
    private var dim: Double { newest ? 1 : 0.4 }

    var body: some View {
        VStack(spacing: 0) {
            // .ex-you — 13px sans, +.01em (Silk Mockup.dc.html:50, 54). The
            // mockup's ink-40 / paper-32 are the ramp's old floor and land at
            // 2.42:1 and 2.66:1; this is their AA-floored image (Silk.swift).
            Text(turn.you)
                .font(Silk.sans(13))
                .tracking(Silk.track(0.01, 13))
                .foregroundStyle(night ? Silk.paperAlpha(0.59) : Silk.inkAlpha(0.65))
                .opacity(dim)
                .allowsHitTesting(false)

            // .ex-silk — Silk's voice, so the serif, and never sans: 23px,
            // -.01em, ink-84 day / paper-85 night (Silk Mockup.dc.html:51, 55).
            // lineSpacing tops the serif's natural box up to the CSS's 1.35
            // (≈31pt at 23). `text-wrap: pretty` has no SwiftUI spelling;
            // centred two-liners are close enough at these lengths.
            Text(turn.reply ?? "…")
                .font(Silk.serif(23))
                .tracking(Silk.track(-0.01, 23))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(night ? Silk.paperAlpha(0.85) : Silk.inkAlpha(0.84))
                // The real reply lands over the "…" as a fade, not a swap —
                // same curve the turn arrived on.
                .contentTransition(.opacity)
                .animation(Silk.motion(0.35), value: turn.reply)
                .padding(.top, 14)                       // margin-top: 14px (Silk Mockup.dc.html:200)
                .opacity(dim)
                .allowsHitTesting(false)
                .accessibilityIdentifier("silk.turn.reply")
                // The bar's answer, spoken. It was the one surface in the app
                // that never announced: the only `Announcement` anywhere served
                // a Settings wheel, so a wheel commit spoke and the feature's
                // own primary surface did not. The reply mutates in place on a
                // view VoiceOver is not focused on, so without this there is no
                // speech, and on the read-back paths no haptic either — the
                // answer simply exists somewhere, to be found by swiping.
                //
                // `.high` and not the default, and the reason is one line up in
                // SilkApp: the return key's own resignation is deliberately
                // refused for a beat, so this fires while the system keyboard is
                // still live and a default-priority post is droppable behind
                // typing feedback. Unguarded by `newest`, because the identity
                // is stable — it speaks once per change, and re-speaks the "Put
                // back." receipt, which is a receipt and deserves saying.
                .onChange(of: turn.reply) { _, landed in
                    guard let landed else { return }
                    var announcement = AttributedString(landed)
                    announcement.accessibilitySpeechAnnouncementPriority = .high
                    AccessibilityNotification.Announcement(announcement).post()
                }
                // The "…" is a drawing, not a word. Named, the rotor reads
                // "horizontal ellipsis"; hidden, the turn is simply not there
                // yet — which is the truth, and which invents no new string
                // (nothing outside Strings.swift may speak).
                .accessibilityHidden(turn.reply == nil)

            // .ex-undo — a hairline pill, 13px, border ink-14 / paper-16 (Silk
            // Mockup.dc.html:53, 56). The label's ink-52 / paper-40 are lifted
            // to the AA floor; the border is not text and keeps its token.
            // The prototype
            // preventDefault()s its mousedown so pressing it cannot blur the
            // input and tear the thread down (README.md:229-230). SwiftUI
            // buttons never steal first responder, so the equivalent here is
            // structural: the pill consumes its own tap, and only the texts
            // above pass touches through to the root's tap-out catcher.
            if turn.undo != nil {
                Button(action: onUndo) {
                    Text(SilkStrings.undo)
                        .font(Silk.sans(13))
                        .foregroundStyle(night ? Silk.paperAlpha(0.62) : Silk.inkAlpha(0.71))
                        .padding(.vertical, 8)           // padding: 8px 20px
                        .padding(.horizontal, 20)
                        .background(
                            Capsule()                    // border-radius: 999px
                                .strokeBorder(night ? Silk.paperAlpha(0.16) : Silk.inkAlpha(0.14),
                                              lineWidth: 1)
                        )
                        .opacity(dim)                    // dim the drawing, not the button
                        // The pill draws ~32pt tall; hit-testing grows to the
                        // 44 thumb — a near-miss here falls through to the
                        // tap-out catcher and tears the whole thread down.
                        .contentShape(Capsule().inset(by: -8))
                }
                .buttonStyle(.plain)
                .padding(.top, 20)                       // margin-top: 20px
                .accessibilityIdentifier("silk.turn.undo")
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

// ============================================================
// Preview — the whole choreography on a fake page
// ============================================================

#Preview("Conversation — day") {
    ConversationDemo(night: false)
}

#Preview("Conversation — night") {
    ConversationDemo(night: true)
}

/// A stub Now page — nothing from AppModel — with the bar, the stage and a
/// toy reply engine, so every beat can be exercised in the canvas: tap the
/// bar (rise + dim), type "give me instagram 15" and return (dock, "…",
/// reply, Undo pill, the door behind the veil turning open), press Undo
/// ("Put back.", door restored, focus kept), send nonsense ("Didn't get
/// that." appends), tap out (thread clears, page returns).
private struct ConversationDemo: View {
    var night: Bool

    @State private var convo = ConversationModel()
    @State private var input = ""
    @State private var page = 0
    @State private var instagramOpen = false
    @State private var keyboard: CGFloat = 0
    @FocusState private var barFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // The page: everything that yields. The root wraps its pager the
            // same way.
            stage
                .silkStage(dimmed: convo.stageDimmed)
                // The page must not squish when the keyboard arrives — only
                // the bar answers it (SilkApp.swift does the same for the pager).
                .ignoresSafeArea(.keyboard, edges: .bottom)

            // Tap-out: the stage is hit-dead while dimmed, so an invisible
            // catcher under the thread picks up the tap and blurs. Blur is
            // the one teardown path — the model clears the thread on it.
            if barFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { barFocused = false }
                    .ignoresSafeArea()
            }

            ConversationThread(model: convo, night: night)

            // The wordmark never yields (README.md:204-205) — over the stage,
            // outside the dim, and transparent to touch so tapping through it
            // still reaches the catcher.
            VStack {
                Wordmark(night: night).padding(.top, 62)
                Spacer()
            }
            .allowsHitTesting(false)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            // Bar + dots, measured from the glass and ignoring the keyboard —
            // the same geometry RootView uses. The GeometryReader's height is
            // therefore glass-to-glass and constant while a keyboard arrives;
            // the keyboard's own height is observed and handed to the bar, which
            // sums the two into one offset on one curve.
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    PageDots(count: 2, index: $page, night: night)
                        .silkStage(dimmed: convo.stageDimmed)
                        .padding(.bottom, 24 - (44 - 5) / 2)
                    CommandBar(text: $input,
                               night: night,
                               onSubmit: submit,
                               hasTurns: convo.hasTurns,
                               containerHeight: geo.size.height,
                               keyboard: keyboard,
                               focus: $barFocused)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .silkKeyboardHeight($keyboard)
        }
        .background((night ? Silk.lacquer : Silk.paper).ignoresSafeArea())
        // FocusState cannot leave the view, so the model gets its shadow —
        // this is the integration seam RootView repeats.
        .onChange(of: barFocused) { _, focused in
            convo.focused = focused
        }
        .preferredColorScheme(night ? .dark : .light)
    }

    /// Stub content in NowView's shape — greeting, hero, doors — built from
    /// components and literals only.
    private var stage: some View {
        VStack(spacing: 0) {
            // The wordmark's seat is left empty here; the real mark sits on
            // its own undimmed layer above.
            Color.clear.frame(height: 62 + 13)

            Text(SilkStrings.goodAfternoon)
                .font(Silk.serif(21))
                .tracking(Silk.track(-0.005, 21))
                .foregroundStyle(night ? Silk.paperAlpha(0.82) : Silk.inkAlpha(0.90))
                .padding(.top, 32)

            ZStack {
                EnsoView(fraction: 0.62, color: night ? Silk.duskBlue : Silk.leaf)
                    .frame(width: 232, height: 232)
                VStack(spacing: 8) {
                    Text("40")
                        .font(Silk.serif(92))
                        .tracking(Silk.track(-0.045, 92))
                        .frame(height: 92)
                        .foregroundStyle(night ? Silk.paperAlpha(0.92) : Silk.ink)
                    Text(SilkStrings.minLeftToday)
                        .font(Silk.sans(12.5))
                        .tracking(Silk.track(0.015, 12.5))
                        .foregroundStyle(night ? Silk.paperAlpha(0.44) : Silk.inkAlpha(0.52))
                }
            }
            .frame(height: 232)
            .padding(.top, 22)

            VStack(spacing: 0) {
                DoorRow(name: "Instagram",
                        time: instagramOpen ? "· 0:15" : nil,
                        state: instagramOpen ? .open : .rest,
                        night: night, showsRule: true)
                DoorRow(name: "TikTok", time: "· 5:00", state: .live, night: night, showsRule: true)
                DoorRow(name: "YouTube", time: nil, state: .rest, night: night, showsRule: false)
            }
            .padding(.horizontal, 46)
            .padding(.top, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The stub reply engine — the shapes come from the handoff's reply table
    /// (README.md:239-247), the delay from the prototype's 480ms
    /// (Silk Mockup.dc.html:346). The real engine is AppModel's; this one
    /// exists so the preview can land replies and undo closures without it.
    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        guard !text.isEmpty else { return }
        let id = convo.ask(text)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(480))
            let t = text.lowercased()
            if t.contains("instagram"), t.contains("15") {
                // Undo captures the prior state by closure and restores it
                // wholesale, the way AppModel captures the prior doors array.
                let wasOpen = instagramOpen
                instagramOpen = true
                convo.land("Instagram \(SilkStrings.isOpenFor) 15 \(SilkStrings.minutes).",
                           undo: { instagramOpen = wasOpen; return true },
                           for: id)
            } else {
                convo.land(SilkStrings.didntGetThat, for: id)
            }
        }
    }
}
