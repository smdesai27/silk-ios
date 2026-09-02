import SwiftUI

/// Silk's design tokens, ported from ds-bundle/tokens/{color,type}.css.
/// Two grounds, alpha ramps on ink and paper, two rationed pops — one pop
/// moment per screen, a wall not wallpaper.
enum Silk {
    // Grounds
    static let paper = Color(red: 0.965, green: 0.953, blue: 0.925)      // #F6F3EC
    static let linen = Color(red: 0.937, green: 0.914, blue: 0.859)      // #EFE9DB
    static let ink = Color(red: 0.129, green: 0.118, blue: 0.090)        // #211E17

    /// Night lacquer. The token sheet calls it "the night ground" and the app
    /// no longer draws it as one — `Ground(night:)` draws the canvas radial in
    /// `Night` below. It survives because it is that radial's own middle: the
    /// midpoint of #1C1913 and #0E0C08 is #15130E, one level of red off this
    /// value. A surface that cannot carry a gradient and must still read as the
    /// night page therefore hands over lacquer, which is exactly what
    /// `SilkShield` does with `ShieldConfiguration.backgroundColor`.
    static let lacquer = Color(red: 0.086, green: 0.075, blue: 0.055)    // #16130E

    /// **Night's cloth.** Day is cut from one material — `paper` is the ground,
    /// `linen` the one raised surface, `ink` what is written on both, and every
    /// day overlay is `paper` at an alpha, so a veil reads as the page itself
    /// with the page taken out of it. Night is now cut the same way, from the
    /// warm near-black the canvas draws (`docs/design/canvas/Night.dc.html:18`,
    /// `radial-gradient(ellipse 118% 78% at 50% 34%, #1C1913 0%, #0E0C08 100%)`).
    ///
    /// **This retires the handoff's slate.** Every night overlay in the app was
    /// still `#1A1C20` — the floor of the `#262B32 → #1A1C20` radial the handoff
    /// specified and the ground stopped drawing — so a blue-grey sheet was being
    /// laid over a warm black page and the join was visible on every one of
    /// them. The two values below are the canvas's own stops and nothing else is
    /// a night ground colour anywhere in Silk.
    ///
    /// The step between them is the step day takes between `paper` and `linen`:
    /// `linen` over `ground` is 1.13:1, `linen` over `paper` is 1.09:1. Sizes of
    /// step, not alphas — a dark face needs a little more separation to show the
    /// same lift, which is the same asymmetry `docs/design/screentime-ui.md`
    /// measures at the wall.
    enum Night {
        /// Night's `paper`: the ground itself. `Ground` fills the page with it
        /// and lays the ellipse on top, so this is the colour under everything
        /// and the colour every veil is cut from.
        static let ground = Color(red: 14 / 255, green: 12 / 255, blue: 8 / 255)   // #0E0C08

        /// Night's `linen`: the one step a surface takes when it is raised off
        /// the ground. It is also the ellipse's centre — the ground's gradient
        /// runs `linen → ground` and nothing else — so the light pooled at the
        /// top of the page and a surface lifted off it are the same value by
        /// construction, which is the whole reason the night face reads as one
        /// material.
        static let linen = Color(red: 28 / 255, green: 25 / 255, blue: 19 / 255)  // #1C1913
    }

    // Pops (ration these) — one per screen. Now takes the leaf; Mirror takes
    // dusk-slate. openSky is deliberately unused on both: the handoff calls it
    // synthetic, and it was the aperture's colour, which Now no longer has.
    static let leaf = Color(red: 0.373, green: 0.541, blue: 0.322)       // #5F8A52
    static let openSky = Color(red: 0.306, green: 0.525, blue: 0.722)    // #4E86B8
    static let duskBlue = Color(red: 0.431, green: 0.498, blue: 0.541)   // #6E7F8A

    /// Mirror's pop — a value shift of the duskBlue hue family, not openSky.
    /// The week band and the score ensō share it.
    ///
    /// There is no night counterpart. `#9FB6C4` was one, and it went with the
    /// slate: Mirror's night pop is paper over the hedgerow (`scoreRingNight`),
    /// and a light blue in a warm room was the cast the night ground was taken
    /// blacker to be rid of.
    static let duskSlate = Color(red: 0.235, green: 0.310, blue: 0.361)  // #3C4F5C

    /// The wash behind the night hero, and nothing else — the faintest green of
    /// the hedgerow, standing in for what was dusk blue. #607858 at 7.5%.
    static let hedgeWash = Color(red: 0.376, green: 0.471, blue: 0.345)  // #607858

    /// The score ensō. By day it carries dusk-slate at the alpha the handoff sets
    /// on it. **At night it carries paper**: Mirror's night pop is the hedgerow
    /// now, and a dusk-slate ring competing with the planting was the one thing
    /// that kept the greens from going deep.
    static let scoreRing = Color(red: 0.235, green: 0.310, blue: 0.361).opacity(0.92)
    static let scoreRingNight = Color(red: 0.965, green: 0.953, blue: 0.925).opacity(0.70)

    /// The ramps. **Text has a floor: ink .65 by day, paper .55 at night.**
    ///
    /// The sheet's ramp was authored by eye and the bottom half of it does not
    /// reach WCAG AA (4.5:1) for text under 24pt. Composited and measured, the
    /// day ramp crosses 4.5:1 at α ≈ .618 — so every step from `--silk-ink-40`
    /// through `--silk-ink-60` was failing, and the three Mirror carries were
    /// the clearest: footnote .45 → 2.76:1, "Week" .48 → 3.00:1, the hero's day
    /// name .52 → 3.36:1. Night was worse than the token sheet implies, because
    /// paper is not laid on `lacquer` on any real screen: `Ground(night:)` draws
    /// a #262B32 → #1A1C20 radial and `Moonwash` puts duskBlue .09 over its
    /// centre, exactly where the hero sits. Against lacquer the night floor
    /// would be α ≈ .472; against the ground Silk actually draws it is .509,
    /// and under the moonwash .533.
    ///
    /// Hence the floors above, which clear the worst ground each face has:
    /// ink .65 → 4.98:1 on flat paper, 4.87:1 under `Dapple`, 4.79:1 on linen;
    /// paper .55 → 5.69:1 on lacquer, 4.99:1 on the ground, 4.68:1 under the
    /// moonwash.
    ///
    /// **Both night grounds named above are now history and the floor stands.**
    /// The slate radial was replaced by the canvas's warm black (`Night`), whose
    /// lightest stop #1C1913 is darker than the slate's darkest, and the
    /// moonwash was re-cut from duskBlue to `hedgeWash` at the same .075. Every
    /// figure moves the one way that needs no re-derivation: paper on a darker
    /// ground gains contrast, so paper .55 clears AA on the ellipse's centre by
    /// more than the 4.68:1 it was floored at. Nothing in the remap table below
    /// changes, which is the point of recording it against the worst ground
    /// rather than the current one.
    ///
    /// The whole text ramp was shifted, not just the failing floor, and that is
    /// the load-bearing part. Lifting only what failed would have collided the
    /// steps against the floor — Now's pending row states its label at ink-70
    /// and its value at ink-50, and floor-clamping alone puts both at .65 and
    /// makes one row out of two. So each face is remapped monotonically onto
    /// [floor, body], leaving everything at ink .84 / paper .80 and above where
    /// it was:
    ///
    ///     day    .40→.65  .44→.66  .45→.67  .48→.69  .50→.70  .52→.71
    ///            .55→.72  .58→.73  .60→.74  .62→.75  .70→.78  .72→.79  .80→.82
    ///     night  .24→.55  .26→.56  .28→.57  .32→.59  .35→.60  .36→.61
    ///            .40→.62  .42→.63  .44→.64  .50→.67  .72→.76
    ///
    /// Order survives; the *spread* necessarily does not. A ramp with a 4.5:1
    /// floor and a 15:1 ceiling cannot hold the gaps a ramp with a 2.4:1 floor
    /// had — Mirror's footnote and hero label were 2.76:1 and 3.36:1 (a 22%
    /// step) and are now 5.48:1 and 5.98:1 (9%). Alpha carries less of the
    /// hierarchy than it did, so size, weight and tracking carry more. That is
    /// a real change to the design's voice and it was made deliberately;
    /// docs/design/canon.md records it as a divergence from the token sheet.
    ///
    /// **These figures apply to text only.** Hairlines, door rules, dots,
    /// rings, capsule fills, gradients and the ensō mark are not text: WCAG
    /// 1.4.3 does not reach them, `--silk-ink-055` is still "the faintest line
    /// Silk draws", and every non-text call site keeps its token value.
    static func inkAlpha(_ a: Double) -> Color { ink.opacity(a) }
    static func paperAlpha(_ a: Double) -> Color { paper.opacity(a) }

    /// The serif voice: numerals and the sentences Silk speaks in its own
    /// voice. Tabular is baked in, not left to call sites — `.silk-serif` is
    /// `tabular-nums` in the stylesheet, and a digit that shifts width as the
    /// budget counts down is the single most common way to break this face.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// CSS tracks in `em`; SwiftUI tracks in points. Every letter-spacing in the
    /// stylesheet is therefore a function of its own size, and hard-coding the
    /// product is how the wordmark ended up at 4.0 instead of 3.74.
    static func track(_ em: CGFloat, _ size: CGFloat) -> CGFloat { em * size }

    /// One motion curve for the whole system — cubic-bezier(.22,1,.28,1), no
    /// springs (docs/design/canon.md). Only the duration varies, and the
    /// stylesheet declares exactly these.
    static func motion(_ seconds: Double) -> Animation {
        .timingCurve(0.22, 1, 0.28, 1, duration: seconds)
    }

    /// The page transition (.55s in the prototype) is deliberately absent: the
    /// pager is a `TabView(.page)`, so the swipe runs UIKit's scroll physics and
    /// no Silk curve is applied to it. Declaring a duration nothing reads would
    /// claim the crossing was ported when it was not.
    enum Motion {
        /// Day ↔ night. Atmosphere, so it is allowed to run past the 350–450ms
        /// band the canon sets for discrete UI.
        static let crossing = 0.8
        static let door = 0.5
        static let toast = 0.4
        static let dots = 0.4
        /// The wall fading in, and back out. Named because the model now owns
        /// it: the shield's curve is set where the shield is raised, not by a
        /// container modifier that would hand the same curve to the pager.
        static let shield = 0.45
        /// The wheel and the door editor — one stratum, one duration. Same
        /// reason: `AppModel` raises and lowers them, so it states their curve.
        static let overlay = 0.4
    }

    /// Three haptics, zero sound. Nothing else in the app may vibrate.
    @MainActor
    enum Haptic {
        private static let notify = UINotificationFeedbackGenerator()
        private static let impact = UIImpactFeedbackGenerator(style: .rigid)

        /// Wakes the Taptic Engine ahead of a moment that will fire — call when
        /// a command is submitted or a wheel opens, so the haptic lands on the
        /// beat rather than tens of milliseconds behind it.
        static func prepare() {
            notify.prepare()
            impact.prepare()
        }

        static func grant() { notify.notificationOccurred(.success) }
        static func refusal() { notify.notificationOccurred(.warning) }
        static func tighten() { impact.impactOccurred() }
    }
}

/// Pressed-state acknowledgment for tappable rows: an immediate ink dim on
/// touch, restored on the one curve at release.
struct SilkPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(configuration.isPressed ? nil : Silk.motion(0.35),
                       value: configuration.isPressed)
    }
}
