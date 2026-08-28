import ManagedSettings
import ManagedSettingsUI
import UIKit
import SilkCore

/// The wall. A statement, not a control: one word, one quiet line, one button
/// Apple forces us to render (it dismisses). No menu, no durations, no escape
/// hatch — "adding an escape hatch here does not make Silk gentler; it makes
/// the wall a negotiation, and then it is not a wall."
///
/// Apple's layout, Silk's ink. Nine tintable properties are all we get:
/// blur, background, icon, title, subtitle, two button labels, two button
/// backgrounds. The primary button always dismisses; a secondary button can
/// only .close/.defer via ShieldActionExtension — it cannot open Silk. So the
/// wall does not pretend: the title says whose wall this is ("Silk"), the
/// subtitle says where to go ("Open Silk"), and the walking is the user's.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    // Silk's grounds, as UIKit colors (tokens/color.css).
    private let paper = UIColor(red: 0.965, green: 0.953, blue: 0.925, alpha: 1)      // #F6F3EC
    private let ink = UIColor(red: 0.129, green: 0.118, blue: 0.090, alpha: 1)        // #211E17
    private let lacquer = UIColor(red: 0.086, green: 0.075, blue: 0.055, alpha: 1)    // #16130E
    private let linen = UIColor(red: 0.937, green: 0.914, blue: 0.859, alpha: 1)      // #EFE9DB

    /// The day ground is pre-compensation, not a colour choice, and it only
    /// happens to equal the day button's fill. If a device ever forces the
    /// ground to be re-measured, give this property its own value rather than
    /// editing `linen`: the day capsule separates from its wall by the layer
    /// order and nothing else, so dragging both to one new colour would leave
    /// the button visible only as prominent glass's blue rim.
    private var dayGround: UIColor { linen }

    // The ink and paper ramps. The two MARK values are still the tokens
    // tokens/color.css names; the two CAPTION values are the AA-floored ramp
    // Silk/DesignSystem.swift now states, and they diverge from the token
    // sheet on purpose — see the ramp note there.
    //
    // Mark and caption were one constant each until the ramp audit, and the
    // split is the finding: the icon is a graphic and answers to WCAG 1.4.11
    // (3:1), the subtitle is prose and answers to 1.4.3 (4.5:1). Sharing a
    // value meant the subtitle inherited the icon's floor and shipped under it.
    //
    // These are judged against the RENDERED wall, not the ground handed over —
    // title, subtitle and icon are all subviews of the effect view's
    // contentView, so like the button's fill they sit ABOVE the material and
    // read against what it renders (docs/design/screentime-ui.md): #FAF8F5 by
    // day, #2F2F29 at night. That is also why the day floor here (α ≈ 0.613)
    // is not the app's (α ≈ 0.618) — the material lifts its wall.
    private var inkMark: UIColor { ink.withAlphaComponent(0.60) }        // --silk-ink-60,   "shield mark" — 4.32:1 on #FAF8F5
    private var inkCaption: UIColor { ink.withAlphaComponent(0.70) }     // was .50 → 3.21:1, under AA. 5.94:1
    private var paperMark: UIColor { paper.withAlphaComponent(0.40) }    // --silk-paper-40, "night mark" — 3.28:1 on #2F2F29
    private var paperCaption: UIColor { paper.withAlphaComponent(0.62) } // was paperMark → 3.28:1, under AA. 5.45:1
    private var paperTitle: UIColor { paper.withAlphaComponent(0.90) }   // no token; _ds_bundle.css:465 spends it raw
    private var paperButton: UIColor { paper.withAlphaComponent(0.80) }  // --silk-paper-80, "night shield button"

    // The ensō mark, pre-rendered once per face. Identity, not information —
    // it is always whole, like EnsoMark in the app.
    private lazy var dayEnso: UIImage = Self.ensoIcon(color: inkMark)
    private lazy var nightEnso: UIImage = Self.ensoIcon(color: paperMark)

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        SharedStore.recordAttempt()

        let now = Date()
        let policy = SharedStore.loadPolicy()

        // Every wall also drives layer-4 of the re-lock: any shield render of
        // any app is a wake, and every wake reconciles.
        //
        // Ahead of the night face, and that ordering is the whole point. This
        // used to sit below it, so for the nine hours of the default down-hours
        // window every render returned early and layer 4 did not exist —
        // exactly the stretch when a grant issued before the edge expires
        // against a phone whose owner is asleep and whose Silk is not running.
        // The face a wall shows is a rendering decision; reconciling is not,
        // and nothing that decides what to draw may sit in front of it.
        Wall.reconcile(now: now)

        // Down hours: the night answers with the hour it opens, not the app.
        // There is nothing to go ask Silk for until then.
        guard let p = policy else { return day(subtitle: SilkStrings.openSilk) }
        if p.downHours.contains(currentTimeOfDay(now)) {
            return night(subtitle: "☾  \(p.downHours.end.display)")
        }

        // A door with balance shows it — "Open Silk · 30 left today" is the
        // one line that says where to go ask *and* what there is to ask for.
        // A non-door or a spent door says only where to go: dangling "0 left
        // today" on a wall that cannot open is an argument, not a statement.
        //
        // The number is what Silk would actually GIVE, not what the pool holds.
        // The pool's figure was a promise this wall could not keep: a door
        // closed by hand at noon, one that has spent its own ceiling, or an ask
        // ten minutes short of the night window all still rendered "Open Silk ·
        // 30 left today" — and this is the surface she hits first, so she walked
        // to Silk and got something smaller, or nothing.
        //
        // So the wall does not reproduce the clamps; it calls the one that mints
        // the grant. `Validator.askableMinutes` is the `.spend` arm's own
        // arithmetic, and `SilkCoreTests` pins the two together: for every
        // fixture, asking for this number grants exactly it. A clamp added to
        // the arm and not here now fails a test instead of shipping a wall that
        // promises what Silk refuses. (Reproducing two of the three clamps by
        // hand is what left the down-hours edge out, under a comment claiming
        // parity.)
        //
        // The Validator's ORDERING between its refusals is not reproduced and is
        // not needed: it decides which hour a refusal quotes, and this wall
        // quotes none. Every one of them arrives here as zero, and zero falls
        // through to saying only where to go.
        if let door = door(for: application, policy: p) {
            let ledger = SharedStore.loadLedger()
            // The ESTABLISHED day: the subtitle must promise what the bar
            // would actually give, and the bar windows on the established
            // day's start (`GrantLedger.effectiveDayStart`).
            let dayStart = ledger.effectiveDayStart(now: now, downHours: p.downHours,
                                                    calendar: .current)
            let askable = Validator.askableMinutes(door: door, state: p, ledger: ledger,
                                                   now: now, dayStart: dayStart)
            if askable > 0 {
                return day(subtitle: "\(SilkStrings.openSilk) · \(askable) \(SilkStrings.leftToday)")
            }
        }
        return day(subtitle: SilkStrings.openSilk)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        SharedStore.recordAttempt()
        let now = Date()
        // A wake is a wake whatever it was that hit the wall. A domain can
        // never open with a grant (docs/market/gaps.md #2), so this render
        // reconciles nothing of its own — but it is still a live process with
        // the ledger in front of it, and some other door's expiry may be
        // sitting in it. Layer 4 is defined by the wake, not by the subject.
        Wall.reconcile(now: now)
        // The same two faces as apps — a domain is not a door, so the day
        // face carries no balance, and the night face answers with the hour.
        if let p = SharedStore.loadPolicy(), p.downHours.contains(currentTimeOfDay(now)) {
            return night(subtitle: "☾  \(p.downHours.end.display)")
        }
        return day(subtitle: SilkStrings.openSilk)
    }

    // MARK: - The two faces
    //
    // Every colour below is pre-compensated for ScreenTimeUI, and both
    // compensations run opposite to the obvious. The ground composites *under*
    // the material, which lifts and neutralises it, so what is handed over is
    // the colour that renders as Silk's rather than the one that is Silk's —
    // these constants will look wrong against tokens/color.css, and correcting
    // them to match it is the mistake. The primary button is prominent glass,
    // which the system accent tints, so any translucency at all floods the
    // capsule blue and its fill must be an opaque blend, never an alpha. The
    // measurements behind both, the alpha floor a night fill must clear to stay
    // visible against its own wall, and the by-eye check that stands in for the
    // test nobody can write here are in docs/design/screentime-ui.md.

    private func day(subtitle: String) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialLight,
            backgroundColor: dayGround,
            icon: dayEnso,
            title: .init(text: SilkStrings.brand, color: ink),
            subtitle: .init(text: subtitle, color: inkCaption),
            primaryButtonLabel: .init(text: SilkStrings.ok, color: ink),
            // --silk-linen doing its own job, "raised surfaces on paper". The
            // fill sits over the material rather than under it, so it escapes
            // the compression and renders at #EFE9DB — a step of 1.14:1 from
            // the day wall, the size of step 0.16 buys on night and in the
            // direction a raised surface takes on a light ground. Escaping the
            // compression is the only reason it separates from a ground handed
            // over as the same colour; docs/design/screentime-ui.md says what
            // to do if a device ever shows otherwise.
            primaryButtonBackgroundColor: linen
        )
    }

    private func night(subtitle: String) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemChromeMaterialDark,
            backgroundColor: lacquer,
            icon: nightEnso,
            title: .init(text: SilkStrings.brand, color: paperTitle),
            subtitle: .init(text: subtitle, color: paperCaption),
            primaryButtonLabel: .init(text: SilkStrings.ok, color: paperButton),
            // --silk-paper-16 — the token the mockup spends on this button's
            // border — laid down against the ground because the fill cannot
            // carry an alpha. Below α ≈ 0.122 the blend comes out darker than
            // the wall it sits on, and the capsule reads as a hole punched in
            // the wall rather than as a button.
            primaryButtonBackgroundColor: Self.flatten(paper, over: lacquer, alpha: 0.16)
        )
    }

    /// Silk's night ramp is written as alphas on paper, but the wall's button
    /// cannot carry one: prominent glass floods blue at any translucency at
    /// all. This lays the alpha down against the ground once, here, so the
    /// value that crosses into ShieldConfiguration is opaque and the ramp still
    /// reads as the ramp.
    private static func flatten(_ top: UIColor, over bottom: UIColor, alpha: CGFloat) -> UIColor {
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: br + (tr - br) * alpha,
                       green: bg + (tg - bg) * alpha,
                       blue: bb + (tb - bb) * alpha,
                       alpha: 1)
    }

    // MARK: - The ensō

    /// A small monochrome ensō, drawn the way the wordmark draws it.
    ///
    /// This replicates Silk/EnsoPath.swift's `EnsoMark` — the authored gesture
    /// (four cubics, open on purpose, ds-bundle/guidelines/enso-symbols.svg
    /// #enso-s) as three fat strokes of increasing width cut at 100/55/22
    /// percent of arc length, which is what keeps it a brush mark instead of
    /// mud at small sizes. Replicated rather than shared because extensions
    /// must stay tiny: no new assets, no new targets, no SwiftUI dependency
    /// for one image. If EnsoPath.swift's numbers ever change, change these.
    private static func ensoIcon(color: UIColor) -> UIImage {
        let side: CGFloat = 64
        let viewBox: CGFloat = 200
        let start = CGPoint(x: 86, y: 24)
        let curves: [(c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
            (CGPoint(x: 55, y: 28), CGPoint(x: 26, y: 62), CGPoint(x: 23, y: 100)),
            (CGPoint(x: 20, y: 140), CGPoint(x: 54, y: 178), CGPoint(x: 98, y: 182)),
            (CGPoint(x: 144, y: 186), CGPoint(x: 178, y: 148), CGPoint(x: 180, y: 104)),
            (CGPoint(x: 182, y: 72), CGPoint(x: 168, y: 50), CGPoint(x: 146, y: 36)),
        ]

        // Flatten to a polyline with running length, so the cuts are fractions
        // of the *stroke*, not of the Bézier parameter — a parameter cut lands
        // the lift-off in the wrong place (see EnsoGeometry.arcTable).
        let samples = 64
        var points: [CGPoint] = [start]
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
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            cumulative.append(cumulative[i - 1] + (dx * dx + dy * dy).squareRoot())
        }
        let total = cumulative[cumulative.count - 1]

        // #enso-s: widths 14/17/21 (viewBox units), cut at 100/55/22 percent.
        // The widest is the shortest — that inversion is the taper.
        let widths: [CGFloat] = [14, 17, 21]
        let factors: [CGFloat] = [1.0, 0.55, 0.22]
        let s = side / viewBox

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(color.cgColor)
            for layer in 0..<widths.count {
                let target = factors[layer] * total
                cg.setLineWidth(widths[layer] * s)
                cg.beginPath()
                cg.move(to: CGPoint(x: points[0].x * s, y: points[0].y * s))
                var i = 1
                while i < points.count, cumulative[i] <= target {
                    cg.addLine(to: CGPoint(x: points[i].x * s, y: points[i].y * s))
                    i += 1
                }
                if i < points.count {
                    // Interpolate the final partial segment so the cut lands
                    // exactly where the hand would have lifted.
                    let span = cumulative[i] - cumulative[i - 1]
                    let t = span > 0 ? (target - cumulative[i - 1]) / span : 0
                    let a = points[i - 1], b = points[i]
                    cg.addLine(to: CGPoint(
                        x: (a.x + (b.x - a.x) * t) * s,
                        y: (a.y + (b.y - a.y) * t) * s
                    ))
                }
                cg.strokePath()
            }
        }
        // Ink is the brand; never let the system re-tint it.
        return image.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Helpers

    /// Which door this wall belongs to, if any. It returns the `Door` rather
    /// than a Bool because the subtitle now has to ask the ledger about this
    /// door in particular — its close, its ceiling — and the loop already has
    /// the door in hand.
    private func door(for application: Application, policy: PolicyState) -> Door? {
        guard let token = application.token else { return nil }
        let selections = SharedStore.loadDoorSelections()
        for door in policy.doors {
            if let sel = selections[door.id], sel.applicationTokens.contains(token) {
                return door
            }
        }
        return nil
    }

    private func currentTimeOfDay(_ date: Date) -> TimeOfDay {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}
