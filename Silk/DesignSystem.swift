import SwiftUI

/// Silk's design tokens, ported from ds-bundle/tokens/{color,type}.css.
/// Two grounds, alpha ramps on ink and paper, two rationed pops — one pop
/// moment per screen, a wall not wallpaper.
enum Silk {
    // Grounds
    static let paper = Color(red: 0.965, green: 0.953, blue: 0.925)      // #F6F3EC
    static let linen = Color(red: 0.937, green: 0.914, blue: 0.859)      // #EFE9DB
    static let ink = Color(red: 0.129, green: 0.118, blue: 0.090)        // #211E17
    static let lacquer = Color(red: 0.086, green: 0.075, blue: 0.055)    // #16130E

    // Pops (ration these) — one per screen. Now takes the leaf; Mirror takes
    // dusk-slate. openSky is deliberately unused on both: the handoff calls it
    // synthetic, and it was the aperture's colour, which Now no longer has.
    static let leaf = Color(red: 0.373, green: 0.541, blue: 0.322)       // #5F8A52
    static let openSky = Color(red: 0.306, green: 0.525, blue: 0.722)    // #4E86B8
    static let duskBlue = Color(red: 0.431, green: 0.498, blue: 0.541)   // #6E7F8A

    /// Mirror's pop — a value shift of the duskBlue hue family, not openSky.
    /// The week band and the score ensō share it.
    static let duskSlate = Color(red: 0.235, green: 0.310, blue: 0.361)  // #3C4F5C
    static let duskSlateNight = Color(red: 0.624, green: 0.714, blue: 0.769) // #9FB6C4

    /// The score ensō carries the same hue at the alpha the handoff sets on it.
    static let scoreRing = Color(red: 0.235, green: 0.310, blue: 0.361).opacity(0.92)
    static let scoreRingNight = Color(red: 0.620, green: 0.718, blue: 0.780).opacity(0.82)

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
