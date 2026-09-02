import SwiftUI

/// Sun through leaves, pooled in the top of the screen — the day ground's only
/// texture. Four overlapping pools: three of warm light and one cool green-grey,
/// the shadow between the leaves. Peak alpha is .045: this is meant to be felt
/// and not seen, so it must never be "corrected" into something visible.
/// (ds-bundle/_ds_bundle.css:46-56)
struct Dapple: View {
    /// Multiplies every pool's alpha. Ships at 1. It exists because light this
    /// faint is unreviewable at true strength — turn it up to prove the shapes
    /// are where the CSS says they are, never to ship a brighter wash.
    var gain: Double = 1

    var body: some View {
        GeometryReader { geo in
            // Radii are authored on the 390pt mock canvas; one uniform scale
            // keyed to width keeps each pool the same shape on every iPhone.
            let scale = geo.size.width / 390
            let box = CGSize(width: geo.size.width, height: geo.size.height * 0.46)

            ZStack {
                ForEach(Self.pools) { pool in
                    // CSS `transparent` interpolates premultiplied, so the
                    // faithful port is the same hue at alpha 0 — not .clear,
                    // which is black at alpha 0 and would grey the paper.
                    // The sheet writes it this way itself at :184 and :203.
                    EllipticalGradient(
                        stops: [
                            .init(color: pool.color.opacity(pool.alpha * gain), location: 0),
                            .init(color: pool.color.opacity(0), location: pool.fade)
                        ],
                        center: .center,
                        startRadiusFraction: 0,
                        endRadiusFraction: 0.5   // the frame is 2r wide, so this is exactly r
                    )
                    .frame(width: pool.rx * 2 * scale, height: pool.ry * 2 * scale)
                    .position(x: pool.x * box.width, y: pool.y * box.height)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()   // a CSS background paints inside its box; the pool at 47% -3% hangs off the top
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // light, not information
    }

    /// One radial-gradient per row, in sheet order. `x`/`y` are fractions of the
    /// wash box; `fade` is the stop where the light reaches nothing.
    private struct Pool: Identifiable {
        let id: Int
        let rx: CGFloat, ry: CGFloat
        let x: CGFloat, y: CGFloat
        let color: Color
        let alpha: Double
        let fade: CGFloat
    }

    // Warm sun, except the last: #96A084 is the cool green-grey of leaf shadow,
    // and it is what keeps the wash from reading as a lens flare.
    private static let pools: [Pool] = [
        Pool(id: 0, rx: 150, ry: 100, x: 0.16, y:  0.05,
             color: Color(red: 240 / 255, green: 214 / 255, blue: 150 / 255), alpha: 0.045, fade: 0.72),
        Pool(id: 1, rx: 100, ry: 130, x: 0.47, y: -0.03,
             color: Color(red: 238 / 255, green: 208 / 255, blue: 138 / 255), alpha: 0.034, fade: 0.70),
        Pool(id: 2, rx: 170, ry: 120, x: 0.85, y:  0.09,
             color: Color(red: 236 / 255, green: 206 / 255, blue: 142 / 255), alpha: 0.040, fade: 0.72),
        Pool(id: 3, rx:  80, ry: 100, x: 0.33, y:  0.15,
             color: Color(red: 150 / 255, green: 160 / 255, blue: 132 / 255), alpha: 0.028, fade: 0.70)
    ]
}

/// The night counterpart: one pool sitting behind the hero, so the closing hour
/// has something to sit in. Night is not day inverted — day gets four sources,
/// night gets one. (ds-bundle/_ds_bundle.css:59-66)
///
/// It was dusk blue. On the blacker ground the blue was the one cool thing left
/// in a warm room and it read as a colour cast rather than as light, so the pool
/// is now the faintest green of the hedgerow — barely above the ground, and the
/// same family as the planting it sits among.
struct Moonwash: View {
    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 390
            let side = 340 * scale

            RadialGradient(
                stops: [
                    .init(color: Silk.hedgeWash.opacity(0.075), location: 0),
                    .init(color: Silk.hedgeWash.opacity(0), location: 0.74)
                ],
                center: .center,
                startRadius: 0,
                endRadius: side / 2   // `closest-side` on a square box is half its side
            )
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: 110 * scale + side / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // light, not information
    }
}

/// The ground itself. By day it is flat paper; at night it is a warm near-black
/// radial, below `lacquer` rather than above it.
///
///   radial-gradient(ellipse 118% 78% at 50% 34%, #1C1913 0%, #0E0C08 100%)
///
/// That line is `docs/design/canvas/Night.dc.html:18` verbatim, and the two
/// stops are `Silk.Night.linen` and `Silk.Night.ground`. It replaces the older
/// handoff geometry (580×440 at 32%, with a #15120C stop at 48%): the radii are
/// fractions of the screen rather than points on a 390pt canvas, so the ground
/// no longer has to be scaled to fit a phone, and the middle stop is gone
/// because the canvas draws two.
///
/// **This reverses a recorded decision.** The handoff had settled on a warm-cool
/// slate (#262B32 → #1A1C20) because near-black "read as too harsh", and this was
/// the one place the night ground was not `lacquer`. It was taken blacker on
/// request, and the harshness the handoff feared is answered differently now:
/// Mirror's hedgerow gives night something to sit against, so the ground no
/// longer has to carry the whole room by itself. The warmth is kept — these are
/// lacquer's hues, not neutral black — because Silk's paper is warm and a neutral
/// night reads as a different app.
///
/// The night text floors in `DesignSystem` were measured against the *old*,
/// lighter ground. A darker ground only raises contrast for paper-on-night, so
/// every one of them still clears; none were re-derived downward.
struct Ground: View {
    var night: Bool

    var body: some View {
        GeometryReader { geo in
            // CSS states an ellipse's RADII; `endRadiusFraction` is a single
            // scalar and cannot express two, so it stays at its default .5 and
            // the gradient's own frame carries the shape — 2r on each axis, the
            // way `Dapple` sizes its pools. 118% of the width and 78% of the
            // height are radii, so the frame is 2.36w × 1.56h: far larger than
            // the screen, which is what makes the visible page the warm middle
            // of a much wider fall rather than the whole of a small one.
            // `Night.ground` fills whatever the ellipse leaves.
            ZStack {
                Silk.Night.ground
                EllipticalGradient(
                    stops: [.init(color: Silk.Night.linen, location: 0),
                            .init(color: Silk.Night.ground, location: 1)],
                    center: .center
                )
                .frame(width: geo.size.width * 2.36, height: geo.size.height * 1.56)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.34)
            }
            .opacity(night ? 1 : 0)
            .background(Silk.paper)
        }
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the ground says night by colour; the greeting says it in words
    }
}

/// The light behind every Silk screen, day and night. Both washes stay mounted
/// and dissolve into each other — sunset is a change in the room, not a swap of
/// two rooms, so nothing may insert or remove.
///
/// Night is the app's down-hours window, passed in. Never the system color
/// scheme: Silk's night is a policy, not a preference.
struct Atmosphere: View {
    var night: Bool

    var body: some View {
        ZStack {
            Dapple().opacity(night ? 0 : 1)
            Moonwash().opacity(night ? 1 : 0)
        }
        // .8s is the wash's own transition, slower than any interaction —
        // the room dims at its pace, not the tap's. (Interactive.html:37, :44)
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // light, not information
    }
}

#Preview("Atmosphere") {
    /// A 390×800 screen, the canvas everything above is authored against.
    /// (ds-bundle/_ds_bundle.css:30-34)
    func screen(_ label: String, ground: Color, @ViewBuilder wash: () -> some View) -> some View {
        VStack(spacing: 12) {
            ZStack {
                ground
                wash()
            }
            .frame(width: 390, height: 800)
            .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
            Text(label)
                .font(Silk.sans(12))
                .foregroundStyle(Silk.inkAlpha(0.52))
        }
    }

    return ScrollView([.horizontal, .vertical]) {
        HStack(alignment: .top, spacing: 28) {
            screen("day · dapple", ground: Silk.paper) { Atmosphere(night: false) }
            screen("night · moonwash", ground: Silk.Night.ground) { Atmosphere(night: true) }
            // True strength is below the threshold of notice; 10× is the proof
            // the four pools exist and land where the sheet puts them.
            screen("dapple · 10× alpha", ground: Silk.paper) { Dapple(gain: 10) }
        }
        .padding(28)
    }
    .background(Silk.linen)
}
