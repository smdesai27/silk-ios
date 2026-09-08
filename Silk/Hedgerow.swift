import SwiftUI

// The hedgerow: every day since install, drawn as a border that only thickens.
//
// Ported from the design canvas (docs/design/canvas/Main.dc.html) rather than
// re-invented, so the two stay comparable — same seed, same noise, same ladder,
// same clearing. What the border says is *duration*: it creeps further in,
// stacks more of its five tone steps, and finally flowers. Nothing is ever
// subtracted, so a bad week cannot take the garden back.
//
// It replaces the loom, which drew this month as a woven rectangle in the
// middle of Mirror and crowded the score.

// MARK: - Ladders

/// Five tone steps, deepest first, plus the blossom. Night is the same ladder
/// taken down — not a silhouette, and not the dusk-slate the rest of Mirror
/// used to borrow.
private enum Ladder {
    static let day: [Color] = [
        Color(red:  38/255, green:  62/255, blue: 40/255),
        Color(red:  52/255, green:  84/255, blue: 50/255),
        Color(red:  86/255, green: 122/255, blue: 74/255),
        Color(red: 124/255, green: 158/255, blue: 90/255),
        Silk.paper
    ]
    static let night: [Color] = [
        Color(red: 22/255, green:  38/255, blue: 24/255),
        Color(red: 34/255, green:  56/255, blue: 34/255),
        Color(red: 52/255, green:  80/255, blue: 48/255),
        Color(red: 78/255, green: 110/255, blue: 66/255),
        Silk.paper
    ]
    /// Underlayer, near, mid, fresh, blossom.
    static let alpha: [Double] = [0.82, 0.88, 0.90, 0.85, 0.55]
    /// Only the three spray passes carry stems.
    static let stemWidth: [CGFloat] = [0, 1.32, 1.08, 0.792, 0]
}

// MARK: - Noise, ported verbatim

private struct LCG {
    var x: UInt32
    init(_ seed: UInt32) { x = seed }
    mutating func next() -> Double {
        x = x &* 1664525 &+ 1013904223
        return Double(x) / 4294967296.0
    }
}

private func h2f(_ x: Double, _ y: Double) -> Double {
    let n = sin(x * 127.1 + y * 311.7) * 43758.5453
    return n - floor(n)
}

private func vnoise(_ x: Double, _ y: Double) -> Double {
    let xi = floor(x), yi = floor(y), xf = x - xi, yf = y - yi
    let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
    return h2f(xi, yi) * (1 - u) * (1 - v) + h2f(xi + 1, yi) * u * (1 - v)
         + h2f(xi, yi + 1) * (1 - u) * v + h2f(xi + 1, yi + 1) * u * v
}

private func fbm(_ x: Double, _ y: Double, _ octaves: Int) -> Double {
    var s = 0.0, a = 0.5, f = 1.0, n = 0.0
    for _ in 0..<octaves { s += a * vnoise(x * f, y * f); n += a; f *= 2.07; a *= 0.5 }
    return s / n
}

private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// The one Silk curve, solved for a scalar — the per-leaf easing. The *outer*
/// animation is linear on purpose: the stagger is what shapes the growth, and
/// curving it twice reads as a lurch.
///
/// **Solved once, into a table.** A cubic Bézier's x has no closed-form
/// inverse, so this bisects — and it used to bisect twenty-two times for every
/// leaf on every frame, with a phone-sized planting running to roughly fifteen
/// hundred items and the grow-in lasting 1.15s. That is about two million
/// bisection steps for one ceremony, all of them recomputing the same 256
/// answers over and over.
///
/// 256 samples with a linear read between them. The error that leaves is
/// bounded by the curve's own bend across a 1/256 step, which on a 20pt leaf is
/// far below a pixel; and the sampled function is a shape, not a fact — nothing
/// downstream of it is a number anyone reads.
private enum SilkEase {
    private static let steps = 256
    private static let table: [Double] = (0...steps).map { solve(Double($0) / Double(steps)) }

    static func value(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let p = x * Double(steps)
        let i = Int(p)
        return table[i] + (table[i + 1] - table[i]) * (p - Double(i))
    }

    /// The bisection itself, now run 257 times in total rather than per leaf.
    private static func solve(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let x1 = 0.22, y1 = 1.0, x2 = 0.28, y2 = 1.0
        func cx(_ t: Double) -> Double { let u = 1 - t; return 3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t }
        func cy(_ t: Double) -> Double { let u = 1 - t; return 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<22 {
            let v = cx(t)
            if abs(v - x) < 0.00001 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return cy(t)
    }
}

private func silkEase(_ x: Double) -> Double { SilkEase.value(x) }

// MARK: - Leaf forms

private enum Leaf {
    static func blade(ang: CGFloat, length: CGFloat, width: CGFloat) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.32, y: -width))
        p.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.32, y: width))
        p.closeSubpath()
        return p.applying(CGAffineTransform(rotationAngle: ang))
    }

    /// Ivy: six lobes about the stem, the outline closed back through the origin.
    private static let lobes: [(CGFloat, CGFloat)] = [
        (-1.45, 0.55), (-0.80, 0.85), (-0.27, 1.0), (0.27, 1.0), (0.80, 0.85), (1.45, 0.55)
    ]

    static func ivy(ang: CGFloat, radius: CGFloat) -> Path {
        var p = Path()
        p.move(to: .zero)
        for i in lobes.indices {
            let la = lobes[i].0, lr = lobes[i].1 * radius
            let pt = CGPoint(x: cos(la) * lr, y: sin(la) * lr)
            if i == 0 {
                p.addLine(to: pt)
            } else {
                let ma = (la + lobes[i - 1].0) / 2
                p.addQuadCurve(to: pt, control: CGPoint(x: cos(ma) * radius * 0.34,
                                                       y: sin(ma) * radius * 0.34))
            }
        }
        p.addLine(to: .zero)
        p.closeSubpath()
        return p.applying(CGAffineTransform(rotationAngle: ang))
    }

    enum Kind { case blade, ivy, fern }

    static func path(_ kind: Kind, ang: CGFloat, length: CGFloat) -> Path {
        let m = min(length, 20)
        switch kind {
        case .ivy:
            return ivy(ang: ang, radius: m * 0.55)
        case .fern:
            var p = blade(ang: ang, length: m * 0.6, width: m * 0.14)
            p.addPath(blade(ang: ang + 0.4, length: m * 0.45, width: m * 0.11))
            return p
        case .blade:
            return blade(ang: ang, length: m, width: m * 0.40)
        }
    }
}

// MARK: - The planting

/// Built once per size and age. Every leaf, stem and blossom carries a birth
/// time; the settled paths are the same planting pre-combined, five fills and
/// three strokes, so the steady state costs nothing to redraw.
struct Planting {
    struct Item {
        /// **A stem's curve, absolute — and a stem's only.** It is what
        /// `trimmedPath` cuts while the runner draws itself on, tip-first, and
        /// there is no other way to express that.
        ///
        /// A leaf carries an EMPTY path here, and `placed` is the whole of its
        /// geometry. It used to carry its own copy, local to the attach point,
        /// so the unfurl could rotate and scale about the origin — but that is
        /// the same transform either way: conjugating it by the translation to
        /// the attach point turns it into a transform of `placed`, which is
        /// what `paint` now does. One copy of every leaf in the planting
        /// instead of two — the settled aggregate below is the other, and it
        /// pays for the steady state, which is most of Mirror's life.
        var path: Path
        var origin: CGPoint
        var band: Int
        var t0: Double
        var isStem: Bool
        /// How much of the 0…1 progress the unfurl takes. Leaves and stems share
        /// the 0.40 the stagger was tuned around; blossoms are born after every
        /// leaf and get exactly the time that remains, so they too are whole
        /// when the settled paths take over at progress 1.
        var window: Double = 0.40
        /// The item where it finally sits: the leaf already translated to its
        /// attach point, the stem exactly as drawn. Filled in by `add`, and the
        /// same path the settled aggregate is built from, so it costs one copy
        /// of the geometry and not two computations of it.
        ///
        /// It is what an item costs once it has finished unfurling. Mid-frame
        /// a settled leaf used to be redrawn through a copied context, a
        /// rotate, a scale and — for stems — a fresh `trimmedPath` allocation,
        /// all to arrive at a transform that is the identity. Now it is a fill.
        var placed = Path()
    }

    var items: [Item] = []
    var settledFills: [Path] = Array(repeating: Path(), count: 5)
    var settledStems: [Path] = Array(repeating: Path(), count: 5)

    /// Built off the main actor. This walks a few thousand random draws, three
    /// spray passes and as many `Path` constructions, and it used to run
    /// synchronously inside the view's `task` — which is main-actor isolated —
    /// on the first frame Mirror mounted. That is a hitch on the one screen
    /// whose whole point is a thing arriving smoothly.
    ///
    /// `nonisolated` and `async`: a nonisolated async function does not inherit
    /// its caller's executor, so awaiting it from the view hands the work to
    /// the concurrent pool. The result is `sending` because a `Planting` is
    /// full of `Path`, which is not `Sendable` — but every one of them is built
    /// here, from nothing, and never shared, so the region is provably the
    /// caller's to take.
    nonisolated static func build(size: CGSize, count: Int) async -> sending Planting {
        var out = Planting()
        let W = size.width, H = size.height
        guard W > 1, H > 1 else { return out }

        var rng = LCG(11)
        func r() -> Double { rng.next() }

        let lush = min(max((Double(count) / 1_000_000).squareRoot(), 0), 1)
        let g = 0.68 + 0.32 * lush
        let reach = 0.11 + (0.17 - 0.11) * lush
        let minD = Double(min(W, H))
        // 0.65 thins every pass at once. At full strength the planting read as a
        // curtain on a phone-sized frame rather than a border — the canvas cards
        // were near-square, so the same numbers looked far lighter there.
        let area = min(3.1, Double(W * H) / (206 * 330)) * 0.65

        // The clearing the score, the key log and the bar keep. Fractions of the
        // frame, so it holds on every iPhone rather than only on the 390 canvas.
        func clearing(_ x: Double, _ y: Double) -> Double {
            let w = Double(W), h = Double(H)
            let a = exp(-(pow((x - 0.5 * w) / (0.3385 * w), 2) + pow((y - 0.4597 * h) / (0.2322 * h), 2)))
            let b = exp(-(pow((x - 0.5 * w) / (0.5385 * w), 2) + pow((y - 0.9550 * h) / (0.0734 * h), 2)))
            let c = exp(-(pow((x - 0.5 * w) / (0.3282 * w), 2) + pow((y - 0.8697 * h) / (0.0355 * h), 2)))
            return min(1, a + b + c)
        }

        // Per-edge weighting. All four edges used to share one reach, which on a
        // 402×874 phone handed the two long sides about twice the leaf area of the
        // short ones — it read as two vertical curtains rather than as a border, and
        // the near-square canvas cards never showed it. The sides are pulled in; the
        // bottom further still, because the bar and the dots live there.
        func edgeT(_ x: Double, _ y: Double) -> Double {
            let sides = min(x, Double(W) - x) / 0.75
            let vertical = min(y, (Double(H) - y) / 0.55)
            return min(sides, vertical) / minD
        }

        func density(_ x: Double, _ y: Double) -> Double {
            let e = edgeT(x, y)
            let wob = 1 + (fbm(x / (minD * 0.33) + 3, y / (minD * 0.33) + 3, 2) - 0.5) * 2 * 0.30
            var dn = 1 - smoothstep(0, reach * wob, e)
            dn *= 0.55 + 1.3 * fbm(x / Double(W) * 3.1 + 7, y / Double(H) * 3.1 + 7, 2)
            dn *= 1 - 0.96 * clearing(x, y)
            return dn
        }

        func inwardness(_ x: Double, _ y: Double) -> Double {
            min(max(edgeT(x, y) / reach, 0), 1)
        }

        func inwardAngle(_ x: Double, _ y: Double) -> Double {
            let d = [x, Double(W) - x, y, Double(H) - y]
            let m = d.min() ?? 0
            let a: Double = m == d[0] ? 0 : m == d[1] ? .pi : m == d[2] ? .pi / 2 : -.pi / 2
            return a + (r() - 0.5) * 1.1
        }

        /// Creep: the birth time runs edge-inward, so the ivy crosses the frame
        /// the way it would across a wall.
        func birth(depth: Int, inward: Double) -> Double {
            min(0.60, 0.58 * inward + 0.09 * (Double(depth) / 4) + 0.05 * r())
        }

        func add(_ item: Item) {
            var item = item
            if item.isStem {
                // The same `Path` value, so this shares storage rather than
                // copying it — a stem is already drawn where it lives.
                item.placed = item.path
            } else {
                item.placed = item.path.applying(
                    CGAffineTransform(translationX: item.origin.x, y: item.origin.y))
                // And the local copy is dropped: `paint` unfurls `placed` about
                // the attach point instead, which is the identical transform.
                item.path = Path()
            }
            out.items.append(item)
            if item.isStem {
                out.settledStems[item.band].addPath(item.placed)
            } else {
                out.settledFills[item.band].addPath(item.placed)
            }
        }

        // The mass the sprays sit in.
        for _ in 0..<Int(150 * g * area) {
            let x = Double(W) * r(), y = Double(H) * r()
            let d0 = density(x, y)
            if d0 <= 0.12 || r() > d0 { continue }
            let p = Leaf.blade(ang: CGFloat(r() * 6.28),
                               length: CGFloat(15 + 5 * r()),
                               width: CGFloat(7 + 2 * r()))
            add(Item(path: p, origin: CGPoint(x: x, y: y), band: 0,
                     t0: birth(depth: 0, inward: inwardness(x, y)), isStem: false))
        }

        // Three passes of sprays: near, mid, fresh.
        struct Pass { var band: Int; var size: CGFloat; var n: Int; var kinds: [Leaf.Kind] }
        let passes = [
            Pass(band: 1, size: 1.10, n: 46, kinds: [.blade, .ivy, .blade, .blade, .fern]),
            Pass(band: 2, size: 0.90, n: 40, kinds: [.blade, .fern, .ivy, .blade]),
            Pass(band: 3, size: 0.66, n: 20, kinds: [.blade, .fern, .blade])
        ]

        for pass in passes {
            for q in 0..<Int(Double(pass.n) * g * area) {
                var sx = 0.0, sy = 0.0, found = false
                for _ in 0..<40 {
                    let tx = Double(W) * r(), ty = Double(H) * r()
                    let d = density(tx, ty)
                    if d > 0.15 && r() < d { sx = tx; sy = ty; found = true; break }
                }
                if !found { continue }

                let base = birth(depth: pass.band, inward: inwardness(sx, sy))
                var ang = r() < 0.55 ? inwardAngle(sx, sy) : r() * 6.28
                var px = sx, py = sy

                for segment in 0..<3 {
                    let nx = px + cos(ang) * (8 + 3 * r())
                    let ny = py + sin(ang) * (8 + 3 * r())
                    if density(nx, ny) <= 0.12 { break }

                    // The stem draws itself on, tip-first, the way a runner extends.
                    let dx = nx - px, dy = ny - py
                    let len = (dx * dx + dy * dy).squareRoot()
                    let bow = len * 0.18 * (r() - 0.5)
                    var stem = Path()
                    stem.move(to: CGPoint(x: px, y: py))
                    stem.addQuadCurve(
                        to: CGPoint(x: nx, y: ny),
                        control: CGPoint(x: (px + nx) / 2 + (-dy / max(len, 0.001)) * bow,
                                         y: (py + ny) / 2 + (dx / max(len, 0.001)) * bow))
                    add(Item(path: stem, origin: .zero, band: pass.band,
                             t0: min(0.60, base + Double(segment) * 0.045), isStem: true))

                    // Each leaf scales from the point it attaches and rotates the
                    // last few degrees open — an unfurl, not a fade.
                    var cluster = Path()
                    for k in 0..<3 {
                        let side: Double = (k % 2) != 0 ? 1 : -1
                        let kind = pass.kinds[(q + k) % pass.kinds.count]
                        cluster.addPath(Leaf.path(kind,
                                                  ang: CGFloat(ang + side * (0.8 + r() * 0.5)),
                                                  length: CGFloat(11 + 9 * r()) * pass.size))
                    }
                    add(Item(path: cluster, origin: CGPoint(x: nx, y: ny), band: pass.band,
                             t0: min(0.60, base + Double(segment) * 0.045 + 0.02), isStem: false))

                    px = nx; py = ny; ang += (r() - 0.5) * 0.6
                }
            }
        }

        // Blossoms arrive with the years — last in, always.
        let bloom = min(max((Double(count) - 450_000) / 350_000, 0), 1)
        for _ in 0..<Int(60 * bloom * area) {
            let x = Double(W) * r(), y = Double(H) * r()
            let d = density(x, y)
            if d <= 0.25 || r() > d { continue }
            // One soft dot, not four petals. At 1.6pt a four-petal cluster resolves
            // into a plus sign on a phone and reads as sparkle rather than flowering.
            var petals = Path()
            petals.addEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
            // Born past the leaves' 0.60 cap — never with them — and unfurling
            // in whatever remains of the run, so the latest bud is still open
            // by the time the settled paths swap in.
            let t0 = 0.70 + 0.22 * r()
            add(Item(path: petals, origin: CGPoint(x: x, y: y), band: 4,
                     t0: t0, isStem: false, window: 1 - t0))
        }

        return out
    }
}

// MARK: - The view

struct Hedgerow: View, @MainActor Animatable {
    /// The lifetime metric the border reads. **Not yet wired to real data** —
    /// `AppModel` carries no days-since-install figure, so this is passed in and
    /// the default is the design's year-three planting. Lushness is
    /// `sqrt(count / 1,000,000)`, the million reached at year five.
    var count: Int
    var night: Bool
    /// 0…1. Linear from the caller; the per-leaf curve is applied here.
    var progress: Double

    /// The interpolation channel. `Canvas` is not an animatable leaf and a plain
    /// view's body sees only the endpoints of `withAnimation`, so without this
    /// the planting snapped in fully grown — the creep never drew. Same
    /// mechanism as `EnsoFlick`: declare the scalar, and SwiftUI walks it.
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @State private var planting = Planting()

    private struct Key: Hashable { var w: CGFloat; var h: CGFloat; var count: Int }

    var body: some View {
        GeometryReader { geo in
            // `rendersAsynchronously` because this is scenery: nothing here is a
            // number anyone reads, so a frame arriving off the main thread — and
            // one frame late under load — costs nothing, while the main thread
            // keeps the swipe that brought the page here.
            Canvas(opaque: false, rendersAsynchronously: true) { ctx, _ in
                Self.paint(ctx, planting, progress: progress, night: night)
            }
            .task(id: Key(w: geo.size.width.rounded(), h: geo.size.height.rounded(), count: count)) {
                let built = await Planting.build(size: geo.size, count: count)
                // The id changed under us: a later task is already building the
                // planting this frame actually wants.
                guard !Task.isCancelled else { return }
                planting = built
            }
        }
        .allowsHitTesting(false)
        // Scenery. The score and the week carry Mirror's meaning; VoiceOver is
        // told the numbers, never the planting.
        .accessibilityHidden(true)
    }

    private static func paint(_ ctx: GraphicsContext, _ p: Planting,
                              progress: Double, night: Bool) {
        let ladder = night ? Ladder.night : Ladder.day

        // Settled: five fills and three strokes, whatever the planting's size.
        if progress >= 0.999 {
            for band in 0..<5 {
                let stems = p.settledStems[band]
                if !stems.isEmpty {
                    ctx.stroke(stems,
                               with: .color(ladder[band].opacity(Ladder.alpha[band] * 0.9)),
                               style: StrokeStyle(lineWidth: Ladder.stemWidth[band], lineCap: .round))
                }
                let fills = p.settledFills[band]
                if !fills.isEmpty {
                    ctx.fill(fills, with: .color(ladder[band].opacity(Ladder.alpha[band])))
                }
            }
            return
        }

        // Two thirds of a frame, near the end of the run, is items that have
        // already finished — the unfurl window is 0.40 and the births are
        // spread over 0.60, so the settled and the still-moving are always
        // mixed rather than in phases. Folding the settled ones into an
        // accumulated path would therefore mean a cumulative snapshot at every
        // checkpoint of progress, which is megabytes of duplicated geometry for
        // a minority of the frames. They get a fast path instead: the placed
        // geometry, one fill, no ease, no trim, no copied context.
        for item in p.items {
            let raw = (progress - item.t0) / item.window
            if raw <= 0 { continue }

            if raw >= 1 {
                let a = Ladder.alpha[item.band]
                if item.isStem {
                    ctx.stroke(item.placed,
                               with: .color(ladder[item.band].opacity(a * 0.9)),
                               style: StrokeStyle(lineWidth: Ladder.stemWidth[item.band],
                                                  lineCap: .round))
                } else {
                    ctx.fill(item.placed, with: .color(ladder[item.band].opacity(a)))
                }
                continue
            }

            let e = silkEase(raw)
            if e <= 0.001 { continue }
            let alpha = Ladder.alpha[item.band] * min(1, e * 1.35)

            if item.isStem {
                ctx.stroke(item.path.trimmedPath(from: 0, to: e),
                           with: .color(ladder[item.band].opacity(alpha * 0.9)),
                           style: StrokeStyle(lineWidth: Ladder.stemWidth[item.band], lineCap: .round))
            } else {
                // The unfurl, about the attach point, applied to the PLACED
                // leaf — so no second copy of the geometry has to be kept for
                // the fraction of a second the leaf is opening.
                //
                // Translating back by the origin before the fill is what makes
                // the two identical: the placed leaf is the local one moved to
                // its attach point, so undoing that move first leaves exactly
                // the local geometry under exactly the old transform.
                var c = ctx
                c.translateBy(x: item.origin.x, y: item.origin.y)
                c.rotate(by: .radians(-0.34 * (1 - e)))
                c.scaleBy(x: e, y: e)
                c.translateBy(x: -item.origin.x, y: -item.origin.y)
                c.fill(item.placed, with: .color(ladder[item.band].opacity(alpha)))
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Hedgerow — the ladder") {
    ScrollView(.horizontal) {
        HStack(spacing: 16) {
            ForEach([550, 16_500, 200_000, 600_000, 1_000_000], id: \.self) { n in
                ForEach([false, true], id: \.self) { night in
                    ZStack {
                        (night ? Silk.Night.ground : Silk.paper)
                        Hedgerow(count: n, night: night, progress: 1)
                    }
                    .frame(width: 195, height: 422)
                }
            }
        }
        .padding(20)
    }
    .background(Silk.linen)
}
#endif
