import SwiftUI
import SilkCore

// The wait: the screen between asking for an app and walking into it.
//
// It says nothing. There is a mark being drawn and the name of the app it will
// open, and when the ink lands the door opens. Zero strings — the wait
// doctrine is explicit that this is not minimalism but the only way this
// surface passes the canon at all.

// ============================================================
// The monotonic reading
// ============================================================

/// The app's one monotonic origin, and the only clock the wait is measured on.
///
/// `Date` is the wrong instrument and it is worth saying why once, here, rather
/// than at every call site. It moves when the user moves it in Settings, when
/// the network corrects it, and across a DST edge — and every one of those
/// would hand back seconds nobody watched, on the one screen in Silk whose job
/// is to charge for seconds. `ContinuousClock` cannot be moved and cannot go
/// backwards, so the price is the price.
///
/// It is also why `TimelineView(.animation)`'s own `context.date` is never read
/// below: that is a wall clock, and it is right there, and taking it would
/// silently reintroduce everything this enum exists to refuse.
enum Monotonic {
    /// Boot-relative and arbitrary — which is exactly why `Wait` never persists
    /// a reading. The origin is per-process; only differences mean anything.
    private static let origin = ContinuousClock.now

    static var reading: TimeInterval {
        let d = origin.duration(to: ContinuousClock.now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

// ============================================================
// The surface
// ============================================================

/// The wall, with its own mark being drawn on it.
///
/// The composition is the shield's, deliberately: a veil, a mark, and one line
/// of user data underneath (MirrorParts.swift `ShieldOverlay`). The wait *is*
/// the wall — the last of it — so it wears the wall's clothes rather than
/// introducing a fourth kind of overlay.
///
/// Two things distinguish this mark from the budget's, and both are load
/// bearing. It is drawn in **ink**, never the pop, and it carries **no
/// numeral**. The budget ensō is always leaf or dusk blue, always 232pt, and
/// always wrapped around the number it states; nothing here is any of those, so
/// nothing here can be read as a claim about the balance — which matters
/// because the balance does not move until the ink lands, and a mark asserting
/// otherwise for six seconds would be the app's only number lying.
struct WaitOverlay: View {
    var wait: Wait
    /// The door's name. User data, not a string — it costs nothing against the
    /// vocabulary, and it is the only thing on screen that answers "what am I
    /// waiting for", which is the question a return from an interruption asks.
    var app: String
    var night: Bool

    var body: some View {
        ZStack {
            // The same veil the wheel and the door editor wear, from the same
            // constant. A second colour here would be a second kind of overlay.
            WheelPickerOverlay.veil(night: night)
                .ignoresSafeArea()
                // Eats every touch. There is no control on this screen — no
                // dismiss, no skip, no "open now" — and the way out is the way
                // out of any screen: leave. Leaving costs nothing, because
                // nothing has been debited yet. A button here would make the
                // wait a negotiation, and then it is not a wait.
                .contentShape(Rectangle())
                .onTapGesture { }

            VStack(spacing: 24) {
                // The one thing that moves. `TimelineView(.animation)` is the
                // whole engine: it asks for a frame, the body reads the clock,
                // and the fraction is a pure function of watched seconds. There
                // is no Timer, no CADisplayLink, no @State written per frame,
                // and no animation in flight that a scene change could leave
                // mid-interpolation — which is what makes the pause exact.
                //
                // It also stops on its own when the app is not visible, so the
                // paused wait costs nothing while she is away.
                TimelineView(.animation) { _ in
                    EnsoView(fraction: wait.fraction(at: Monotonic.reading),
                             color: night ? Silk.paperAlpha(0.44) : Silk.inkAlpha(0.60),
                             // Drawn, not transitioned — see EnsoView.motion.
                             motion: nil)
                        .frame(width: Self.mark, height: Self.mark)
                }
                Text(app)
                    .font(Silk.sans(13.5))
                    .tracking(Silk.track(-0.005, 13.5))
                    .foregroundStyle(night ? Silk.paperAlpha(0.62) : Silk.inkAlpha(0.70))
            }
            // One spoken element, and it is the app's name — the same word she
            // typed. The mark hides itself (EnsoPath.swift), as it does on Now:
            // a stroke that says nothing to a sighted user must not become the
            // one thing a VoiceOver user hears, and an element that "updates
            // frequently" and has nothing to say is a void with a label on it.
            // The grant readback lands in the thread when the ink does, which
            // is the sentence VoiceOver has always read here.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("silk.wait")
        }
        // Modal, or the veil is a wall only to people looking at it. Without
        // this the layers underneath stay in the accessibility tree: a
        // VoiceOver user swipes past the wait to the command bar, focuses it,
        // and raises the system keyboard — the one window the veil cannot
        // cover, and precisely the state `SilkApp`'s focus drop exists to
        // prevent — and a send from there arrives with a wait already standing.
        // The touch layer above is already closed by the tap eater; this closes
        // the other one.
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
    }

    /// 132, not Now's 232. The wait is not the hero and must not be mistaken
    /// for it — at the hero's size, in the hero's seat, an ink mark would read
    /// as the budget in a costume.
    private static let mark: CGFloat = 132
}

// ============================================================
// Preview
// ============================================================

#if DEBUG
/// A wait frozen at `f` of its length: never watched, so `fraction` answers
/// from the banked seconds alone and the ink holds still. A live one would show
/// a different frame every time the preview is opened, which is no way to look
/// at a stroke.
private func parked(at f: Double) -> Wait {
    Wait(doorID: UUID(), minutes: 20, length: 6, watched: 6 * f)
}

#Preview("The wait") {
    ScrollView {
        VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { night in
                HStack(spacing: 0) {
                    ForEach([0.08, 0.35, 0.7, 1.0], id: \.self) { f in
                        WaitOverlay(wait: parked(at: f), app: "Instagram", night: night)
                            .frame(width: 190, height: 300)
                            .clipped()
                    }
                }
                .background(night ? Silk.Night.ground : Silk.paper)
            }
        }
    }
}
#endif
