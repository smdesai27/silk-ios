import SwiftUI

/// The aperture — a piece of sky held by the page. It shows the down-hours
/// window and is the one object in Silk with real material depth: everything
/// else is ink on paper, this is a recessed pane of glass.
///
/// Two faces, and the inversion is the point. By day it is a quiet recess
/// pressed into the paper; at night, when the doors have dimmed and the ensō
/// has gone to rest, it is the only thing on the screen still awake — the
/// screen's one pop. Both faces cross-fade over .8s, so day→night reads as
/// dusk falling rather than a theme toggle.
/// (ds-bundle/components/Components/Aperture/Aperture.prompt.md)
///
/// Fixed at 234×56: the gradients are pixel-tuned to that box and scaling
/// smears the glass. The 18pt gap above it belongs to the screen, not here.
struct ApertureView: View {
    /// Already formatted — "☾  10:00 PM – 7:00 AM". The caller owns the clock;
    /// the aperture only holds it.
    var text: String
    var night: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 27, style: .circular) }

    var body: some View {
        ZStack {
            dayFace.opacity(night ? 0 : 1)
            nightFace.opacity(night ? 1 : 0)

            // One line, in the sky's blue-grey rather than ink — the text
            // belongs to the window, not to the page. Serif, because these
            // are numerals.
            Text(text)
                .font(Silk.serif(13.5))
                .tracking(Silk.track(0.01, 13.5))
                .foregroundStyle(night ? Self.nightText : Self.dayText)
        }
        .frame(width: 234, height: 56)
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("silk.aperture")
    }

    // MARK: - Day — cool ceramic, pressed into the paper

    /// The washes are wider than the pane, so every layer above the ground is
    /// an overlay: overlays never argue with layout, and the clip stays 234×56.
    private var dayFace: some View {
        shape
            .fill(
                LinearGradient(
                    stops: [.init(color: Color(red: 0.800, green: 0.831, blue: 0.839), location: 0),     // #CCD4D6
                            .init(color: Color(red: 0.827, green: 0.847, blue: 0.827), location: 0.54),  // #D3D8D3
                            .init(color: Color(red: 0.847, green: 0.863, blue: 0.827), location: 1)],    // #D8DCD3
                    startPoint: .top, endPoint: .bottom)
            )
            // Light pools up from under the bottom lip, then a breath of open
            // sky along the top — the pane is lit from the room, not the page.
            .overlay { wash(Self.dayPool, alpha: 0.85, rx: 190, ry: 40, centerY: 60.48, stop: 0.70) }
            .overlay { wash(Silk.openSky, alpha: 0.16, rx: 152, ry: 46, centerY: -8, stop: 0.78) }
            // The recess falling off the top lip. `inset 0 9px 16px -9px`
            // (_ds_bundle.css:189) reads heavy, but the +9 offset and the −9
            // spread cancel: the shadow's hard edge lands exactly on the top
            // lip, so all that shows inside the pane is one Gaussian tail
            // decaying downward. The stops are .18·Φ(−y/σ) at σ = 16/2 = 8pt —
            // half alpha at the lip, nothing left by 22pt.
            .overlay {
                LinearGradient(
                    stops: [.init(color: Silk.inkAlpha(0.090), location: 0),
                            .init(color: Silk.inkAlpha(0.056), location: 0.071),
                            .init(color: Silk.inkAlpha(0.029), location: 0.143),
                            .init(color: Silk.inkAlpha(0.012), location: 0.214),
                            .init(color: Silk.inkAlpha(0), location: 0.40)],
                    startPoint: .top, endPoint: .bottom)
            }
            // …and the tight line under the lip, which is also what draws the
            // shade down the two sides. (inset 0 2px 6px)
            .overlay { lip(Silk.inkAlpha(0.14), drop: 2, blur: 3, weight: 4) }
            // A hairline along the bottom edge lifts the pane back out of the
            // paper. The stylesheet lifts it with pure white (.40) and the
            // canon has no white, so it is the paper ramp instead — which is
            // what the rest of the app already reaches for.
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [.init(color: Silk.paperAlpha(0), location: 0.7),
                                .init(color: Silk.paperAlpha(0.40), location: 1)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .clipShape(shape)
            .compositingGroup()                                     // fade the pane, not each layer
            .shadow(color: Silk.paperAlpha(0.55), radius: 0, y: 1)     // 0 1px 0 — the sill
    }

    // MARK: - Night — a lit window in a dark wall

    private var nightFace: some View {
        shape
            .fill(
                LinearGradient(
                    stops: [.init(color: Color(red: 0.239, green: 0.322, blue: 0.392), location: 0),     // #3D5264
                            .init(color: Color(red: 0.149, green: 0.204, blue: 0.251), location: 0.58),  // #263440
                            .init(color: Color(red: 0.106, green: 0.153, blue: 0.192), location: 1)],    // #1B2731
                    startPoint: .top, endPoint: .bottom)
            )
            // Dusk enters from above and settles at the bottom — the reverse
            // of the day pane, which is why the two faces read as one object
            // turning rather than two objects swapping.
            .overlay { wash(Self.nightSkyHigh, alpha: 0.40, rx: 192, ry: 58, centerY: -12, stop: 0.76) }
            .overlay { wash(Self.nightSkyLow, alpha: 0.28, rx: 174, ry: 50, centerY: 60.48, stop: 0.74) }
            // Deeper recess than day, and it runs all the way round: the wall
            // this window is cut into has thickness.
            // (inset 0 2px 8px .45, then inset 0 0 12px 4px .32)
            .overlay { lip(Self.nightShade.opacity(0.45), drop: 2, blur: 4, weight: 4) }
            .overlay { lip(Self.nightShade.opacity(0.32), drop: 0, blur: 6, weight: 8) }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [.init(color: Self.nightSill.opacity(0), location: 0.7),
                                .init(color: Self.nightSill.opacity(0.12), location: 1)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .clipShape(shape)
            .compositingGroup()
            // 0 0 34px 2px — the only light that spills onto the lacquer, and
            // the screen's one pop. This one falls outside the pane, so it is a
            // real shadow: 34 → 17 by the same diameter-to-sigma halving. The
            // 2px spread goes unclaimed; SwiftUI has no term for it, and at
            // .16 alpha it is below the threshold of the eye.
            .shadow(color: Silk.openSky.opacity(0.16), radius: 17)
    }

    // MARK: - Porting the CSS

    /// A CSS `radial-gradient(rx ry at 50% centerY, color, transparent stop%)`.
    /// EllipticalGradient fills whatever frame it is given, so the ellipse is a
    /// 2rx × 2ry frame parked on the requested center; `endRadiusFraction` .5
    /// would reach that frame's edge, so the CSS stop scales it down. `centerY`
    /// is in points down from the top lip — the stylesheet's `108%` is 60.48.
    private func wash(_ color: Color, alpha: Double, rx: CGFloat, ry: CGFloat,
                      centerY: CGFloat, stop: Double) -> some View {
        EllipticalGradient(
            colors: [color.opacity(alpha), color.opacity(0)],
            endRadiusFraction: 0.5 * stop
        )
        .frame(width: rx * 2, height: ry * 2)
        .offset(y: centerY - 28)                                   // against the 56pt box's center
    }

    /// One CSS `inset 0 Ypx Bpx Spx` shadow. SwiftUI has no inset shadow, so
    /// the ring is stroked on the edge, pushed down, blurred, and its outer
    /// half is clipped away by the pane — the half that survives is the depth.
    /// Two conversions, and all three lips obey both: `weight` = 2·(Y + S), so
    /// that exactly the inward reach the CSS declares lands inside the clip,
    /// and `blur` = B/2, because CSS states a blur diameter where SwiftUI takes
    /// a sigma.
    private func lip(_ color: Color, drop: CGFloat, blur: CGFloat, weight: CGFloat) -> some View {
        shape
            .stroke(color, lineWidth: weight)
            .offset(y: drop)
            .blur(radius: blur)
    }

    // Sky colours, local to the aperture: this is the one surface in Silk that
    // is neither ink nor paper. (_ds_bundle.css, .silk-aperture)
    private static let dayText = Color(red: 0.157, green: 0.220, blue: 0.275).opacity(0.82)     // rgba(40,56,70,.82)
    private static let nightText = Color(red: 0.839, green: 0.878, blue: 0.910).opacity(0.85)   // rgba(214,224,232,.85)
    private static let dayPool = Color(red: 0.886, green: 0.898, blue: 0.863)                   // #E2E5DC
    private static let nightSkyHigh = Color(red: 0.431, green: 0.549, blue: 0.659)              // rgb(110,140,168)
    private static let nightSkyLow = Color(red: 0.494, green: 0.612, blue: 0.722)               // rgb(126,156,184)
    private static let nightSill = Color(red: 0.639, green: 0.733, blue: 0.808)                 // rgb(163,187,206)
    /// The CSS asks for pure black in the first night lip; the canon does not
    /// allow it. This is the coolest near-black the aperture already contains —
    /// the stylesheet names it one line down, for the second lip.
    private static let nightShade = Color(red: 0.055, green: 0.071, blue: 0.094)                // rgb(14,18,24)
}

#if DEBUG
#Preview("Aperture — day, night, setup") {
    @Previewable @State var night = false

    // What DownHours.apertureText composes at run time (SilkCore/DoorState.swift).
    // Spelled in escapes because the gaps are load-bearing and invisible: ☾,
    // then nbsp + space, and an en dash between the hours — this is a range,
    // never a hyphen. Times are user data, so no SilkStrings entry buys this.
    let window = "\u{263E}\u{00A0} 10:00 PM \u{2013} 7:00 AM"

    VStack(spacing: 0) {
        VStack(spacing: 26) {
            ApertureView(text: window, night: false)

            // Setup. The card gives the aperture no second face for onboarding —
            // it is a label, never a control, so setup swaps the string and
            // nothing else.
            ApertureView(text: "\u{263E}\u{00A0} 9:30 PM \u{2013} 6:30 AM", night: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Silk.paper)

        ApertureView(text: window, night: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(Silk.lacquer)

        // Tap the moon to watch dusk fall, on the one curve.
        VStack(spacing: 22) {
            ApertureView(text: window, night: night)
            Button("\u{263E}") { night.toggle() }
                .font(Silk.serif(15))
                .foregroundStyle(night ? Silk.paperAlpha(0.5) : Silk.inkAlpha(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(night ? Silk.lacquer : Silk.paper)
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
    }
    .ignoresSafeArea()
}
#endif
