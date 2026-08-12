import SwiftUI

// The ensō is a brush gesture, not a geometric ring. Everything here exists to
// keep it a gesture: one authored path, arc-length parameterised so the stroke
// can be cut anywhere and still land where the hand would have lifted.
//
//   The stroke is the budget. No track, no ghost ring — spent time is bare paper.
//   (ds-bundle/components/Components/Enso/Enso.prompt.md)

// MARK: - Geometry

/// The gesture itself, and the arc-length machinery the lift-off flick needs.
///
/// Every ensō variant in the design system shares one path `d`
/// (ds-bundle/guidelines/enso-symbols.svg) — what changes is how much of it is
/// drawn. It is four cubics, counter-clockwise from roughly 11 o'clock, and it
/// is **open**: the last point (146,36) never meets the first (86,24). Closing
/// it or rotating it destroys the gesture, so nothing here does either.
enum EnsoGeometry {
    /// All numbers below are in the authored 200×200 viewBox.
    static let viewBox: CGFloat = 200

    struct Cubic: Sendable {
        let c1, c2, end: CGPoint
    }

    static let start = CGPoint(x: 86, y: 24)
    static let curves: [Cubic] = [
        Cubic(c1: CGPoint(x: 55, y: 28), c2: CGPoint(x: 26, y: 62), end: CGPoint(x: 23, y: 100)),
        Cubic(c1: CGPoint(x: 20, y: 140), c2: CGPoint(x: 54, y: 178), end: CGPoint(x: 98, y: 182)),
        Cubic(c1: CGPoint(x: 144, y: 186), c2: CGPoint(x: 178, y: 148), end: CGPoint(x: 180, y: 104)),
        Cubic(c1: CGPoint(x: 182, y: 72), c2: CGPoint(x: 168, y: 50), end: CGPoint(x: 146, y: 36)),
    ]

    /// Uniform fit — the ensō is a circle-ish gesture and must never be squashed
    /// to fill a non-square frame.
    static func fitScale(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) / viewBox
    }

    static func transform(in rect: CGRect) -> CGAffineTransform {
        let s = fitScale(in: rect)
        return CGAffineTransform(
            translationX: rect.midX - viewBox * s / 2,
            y: rect.midY - viewBox * s / 2
        ).scaledBy(x: s, y: s)
    }

    // MARK: Arc-length table

    /// A flattened polyline plus its running length, so a fraction of the
    /// *stroke* maps to a point — which is not what a fraction of the Bézier
    /// parameter would give you. Built once; the curve never changes.
    struct ArcTable: Sendable {
        let points: [CGPoint]
        let cumulative: [CGFloat]
        var total: CGFloat { cumulative[cumulative.count - 1] }
    }

    /// 128 samples per cubic. Verified against the authored variants: this table
    /// puts fraction .37 at (40.0, 151.1) and .82 at (180.1, 102.2), the exact
    /// flick origins hand-placed in #enso-37 and #enso-82.
    static let arcTable: ArcTable = {
        let samples = 128
        var points: [CGPoint] = [start]
        points.reserveCapacity(curves.count * samples + 1)

        var p0 = start
        for c in curves {
            for i in 1...samples {
                let t = CGFloat(i) / CGFloat(samples)
                let u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
                points.append(CGPoint(
                    x: a * p0.x + b * c.c1.x + cc * c.c2.x + d * c.end.x,
                    y: a * p0.y + b * c.c1.y + cc * c.c2.y + d * c.end.y
                ))
            }
            p0 = c.end
        }

        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            cumulative.append(cumulative[i - 1] + (dx * dx + dy * dy).squareRoot())
        }
        return ArcTable(points: points, cumulative: cumulative)
    }()

    /// First sample at or past `target`, with the local interpolant.
    private static func locate(_ target: CGFloat) -> (index: Int, t: CGFloat) {
        let cum = arcTable.cumulative
        var lo = 0, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        let i = max(1, lo)
        let span = cum[i] - cum[i - 1]
        let t = span <= 0 ? 0 : (target - cum[i - 1]) / span
        return (i, min(max(t, 0), 1))
    }

    /// Where the brush is when `fraction` of the stroke has been drawn.
    static func point(atFraction fraction: Double, in rect: CGRect) -> CGPoint {
        let f = min(max(fraction, 0), 1)
        let (i, t) = locate(CGFloat(f) * arcTable.total)
        let a = arcTable.points[i - 1], b = arcTable.points[i]
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        return p.applying(transform(in: rect))
    }

    /// Unit direction of travel there. No `rect`: the fit is a uniform scale
    /// plus a translation, neither of which turns a direction.
    static func tangent(atFraction fraction: Double) -> CGVector {
        let f = min(max(fraction, 0), 1)
        let (i, _) = locate(CGFloat(f) * arcTable.total)
        let a = arcTable.points[i - 1], b = arcTable.points[i]
        let dx = b.x - a.x, dy = b.y - a.y
        let n = (dx * dx + dy * dy).squareRoot()
        guard n > 0 else { return CGVector(dx: 0, dy: -1) }
        return CGVector(dx: dx / n, dy: dy / n)
    }
}

// MARK: - Path

/// The authored gesture, fitted into `rect`. Left open on purpose.
struct EnsoPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: EnsoGeometry.start)
        for c in EnsoGeometry.curves {
            path.addCurve(to: c.end, control1: c.c1, control2: c.c2)
        }
        return path.applying(EnsoGeometry.transform(in: rect))
    }
}

// MARK: - The living circle

/// Seven strokes make one brush mark.
///
/// Five stacked body layers of increasing width, each cut shorter than the last,
/// are what make it read as a loaded brush thinning as it lifts rather than as a
/// progress ring. A dry-brush hair rides inside them. A flick leaves the tip
/// tangentially. Nothing draws the part already spent.
///
/// Cutting is done with `.trim`, not `StrokeStyle(dash:)`: the SVG relies on
/// `pathLength="100"` to make dashes mean percent, and `StrokeStyle` has no
/// equivalent — its dashes are in points, so they would drift with frame size.
struct EnsoView: View {
    /// 0...1 — the fraction of the budget remaining. At 0 the ensō is gone.
    var fraction: Double
    var color: Color = Silk.leaf

    /// How a change in `fraction` is crossed.
    ///
    /// The budget *steps*: it sits at one true value, a grant lands, and it
    /// sits at the next. Crossing that step on the one Silk curve is what the
    /// canonical behavior reference specifies by name, and it is the default
    /// here for every surface that shows a budget.
    ///
    /// `nil` is for the one caller that is not showing a stepped value — the
    /// wait, where the mark is being *drawn*, frame by frame, by a hand. A
    /// 0.45s tween applied to a number that already moves every frame does not
    /// produce a curve; it produces a smear, because each frame starts a new
    /// interpolation the next frame interrupts. So the wait draws every frame
    /// itself and passes nil, which is not an opt-out from the curve but a
    /// statement that there is no transition here to curve.
    var motion: Animation? = Silk.motion(0.45)

    /// enso-symbols.svg #enso-full: five paths, widths 2.2 → 4.6, dasharrays
    /// 100 / 80 / 58 / 34 / 16 against pathLength 100. The widest is the
    /// shortest — that inversion is the taper.
    private static let widths: [CGFloat] = [2.2, 2.6, 3.0, 3.8, 4.6]
    private static let factors: [Double] = [1.0, 0.80, 0.58, 0.34, 0.16]

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            // Widths are viewBox-200 units and must be scaled with the frame.
            // At the Now hero's 232pt this is 1.16 — using them raw draws the
            // brush 14% thinner than it was authored.
            let s = EnsoGeometry.fitScale(in: rect)
            let f = min(max(fraction, 0), 1)

            ZStack {
                ForEach(0..<5) { i in
                    EnsoPath()
                        .trim(from: 0, to: f * Self.factors[i])
                        .stroke(color, style: StrokeStyle(lineWidth: Self.widths[i] * s, lineCap: .round))
                }

                // The dry-brush hair: one short, faint segment inside the ink,
                // where the loaded brush skipped (enso-symbols.svg 6th path —
                // width 0.7, opacity .45). `translate(4 4) scale(0.96)` about
                // the origin is exactly a 0.96 scale about (100,100), so it sits
                // just inside the body rather than beside it.
                EnsoPath()
                    .trim(from: hairStart(f), to: hairEnd(f))
                    .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 0.7 * s, lineCap: .round))
                    .scaleEffect(0.96)

                // The lift-off flick — width 1.1, opacity .85 (enso-symbols.svg
                // 7th path). It must leave the path *tangentially at the point
                // where the stroke ends*; a flick at the wrong angle reads as a
                // stray mark (Enso.prompt.md). Interactive.html `setEnso` cuts it
                // below 0.03, where there is no stroke left to lift off from.
                if f > 0.03 {
                    EnsoFlick(fraction: f)
                        .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // One curve for the whole system. Once, forward — never a filling ring.
        .animation(motion, value: fraction)
        // The stroke is scenery; the numeral it circles carries the state.
        // VoiceOver reads the budget, never the brush.
        .accessibilityHidden(true)
    }

    /// Interactive.html `setEnso`: `hd = 8 + 6*frac` percent, offset so the hair
    /// stays centred at `frac/2` — the middle of whatever is still drawn. The
    /// static symbols freeze this (14 long at -31, or 11 at -18 for #enso-37);
    /// a budget that recedes needs the general form, or the hair strands itself
    /// on bare paper once the stroke retreats past it.
    private func hairLength(_ f: Double) -> Double {
        f <= 0 ? 0 : (8 + 6 * f) / 100
    }

    private func hairStart(_ f: Double) -> Double {
        max(0, f - hairLength(f)) / 2
    }

    /// Below f ≈ .085 that formula makes the hair longer than the ink it lives
    /// in, and the JS lets it run out past the tip onto bare paper. Spent time
    /// is paper; nothing may be drawn on it. Clipped to the tip.
    private func hairEnd(_ f: Double) -> Double {
        min(f, hairStart(f) + hairLength(f))
    }
}

/// The flick: a straight tangent 10 viewBox-units long, projecting forward from
/// the tip (Interactive.html `setEnso`). Animatable so it travels with the tip
/// instead of teleporting when the budget changes.
private struct EnsoFlick: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = EnsoGeometry.point(atFraction: fraction, in: rect)
        let t = EnsoGeometry.tangent(atFraction: fraction)
        let len = 10 * EnsoGeometry.fitScale(in: rect)
        var path = Path()
        path.move(to: p)
        path.addLine(to: CGPoint(x: p.x + t.dx * len, y: p.y + t.dy * len))
        return path
    }
}

// MARK: - Wordmark

/// The mark that sits beside SILK — 13pt in the wordmark (_ds_bundle.css:100),
/// 15pt on the shield (_ds_bundle.css:440). At that size the five-layer taper
/// turns to mud, so the same gesture is drawn with three fat strokes instead
/// (#enso-s: widths 14 / 17 / 21, cut at 100 / 55 / 22). It carries no budget —
/// the mark is identity, so it is always whole.
struct EnsoMark: View {
    var color: Color

    private static let widths: [CGFloat] = [14, 17, 21]
    private static let factors: [Double] = [1.0, 0.55, 0.22]

    var body: some View {
        GeometryReader { geo in
            let s = EnsoGeometry.fitScale(in: CGRect(origin: .zero, size: geo.size))
            ZStack {
                ForEach(0..<3) { i in
                    EnsoPath()
                        .trim(from: 0, to: Self.factors[i])
                        .stroke(color, style: StrokeStyle(lineWidth: Self.widths[i] * s, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // Identity, not information — the wordmark's text is the spoken part.
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Ensō — the living circle") {
    let steps: [Double] = [1.0, 0.75, 0.4, 0.12, 0.0]

    return ScrollView {
        VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { night in
                VStack(spacing: 22) {
                    HStack(spacing: 8) {
                        ForEach(steps, id: \.self) { f in
                            VStack(spacing: 10) {
                                EnsoView(fraction: f, color: night ? Silk.duskBlue : Silk.leaf)
                                    .frame(width: 62, height: 62)
                                Text(String(format: "%.2f", f))
                                    .font(Silk.serif(11))
                                    .monospacedDigit()
                                    .foregroundStyle(night ? Silk.paperAlpha(0.44) : Silk.inkAlpha(0.52))
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        EnsoMark(color: night ? Silk.paperAlpha(0.40) : Silk.inkAlpha(0.68))
                            .frame(width: 13, height: 13)
                        EnsoMark(color: night ? Silk.paperAlpha(0.40) : Silk.inkAlpha(0.60))
                            .frame(width: 15, height: 15)
                    }
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
                .background(night ? Silk.lacquer : Silk.paper)
            }

            // The size it actually ships at on Now.
            EnsoView(fraction: 0.62, color: Silk.leaf)
                .frame(width: 232, height: 232)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(Silk.paper)
        }
    }
    .background(Silk.paper)
}
