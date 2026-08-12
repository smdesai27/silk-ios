import SwiftUI
import SilkCore

// The chrome: the four small things that sit around the composition. None of
// them read the system appearance — night is the down-hours window, handed
// down by the container, so every piece takes it as a parameter.
// (_ds_bundle.css: .silk-dots, .silk-wordmark, .silk-door, .silk-cmdbar)

// One curve for everything, from Silk.motion. Dots answer the thumb at .4s
// (Interactive.html:126); doors take .5s (_ds_bundle.css:234, 239, 245) — a
// door changing state is a fact about the day, not a flick.

// ============================================================
// Page dots
// ============================================================

/// One dot per page — Now, Mirror, Settings in the handoff's order
/// (README.md:54-56; the older "two screens deep" vision predates Settings
/// earning its seat). Replaces UIPageControl, which draws iOS grey on Silk's
/// paper and cannot be told otherwise.
///
/// The dots are tappable. The web prototype navigates by tap because a web
/// prototype has no swipe; on iOS the swipe is the gesture and the tap is the
/// shortcut, so it gets both.
struct PageDots: View {
    var count: Int
    @Binding var index: Int
    var night: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Button { withAnimation(Silk.motion(0.45)) { index = i } } label: {
                    Circle()
                        .fill(i == index ? active : inactive)
                        .frame(width: 5, height: 5)      // _ds_bundle.css:315
                        // 12 wide leaves exactly the 7pt gap the CSS asks for
                        // (_ds_bundle.css:312, 12 − 5); 44 tall is the thumb.
                        // The dot stays 5pt, so the row's centre is still the
                        // dot's centre. The interior frames already abut, so
                        // only the row's outer edges take extra slop — grown
                        // symmetrically, which keeps the row optically centred.
                        .frame(width: 12, height: 44)
                        .padding(.leading, i == 0 ? 8 : 0)
                        .padding(.trailing, i == count - 1 ? 8 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A page number is user-facing data, not a sentence — labelling
                // these "Page 1 of 2" would spend a string off a budget of
                // twenty-five. The traits already say button and selected.
                .accessibilityLabel(Text("\(i + 1)"))
                .accessibilityAddTraits(i == index ? [.isSelected] : [])
                .accessibilityIdentifier("silk.dot.\(i)")
            }
        }
        .animation(Silk.motion(Silk.Motion.dots), value: index)
    }

    private var active: Color { night ? Silk.paperAlpha(0.50) : Silk.inkAlpha(0.60) }
    private var inactive: Color { night ? Silk.paperAlpha(0.14) : Silk.inkAlpha(0.16) }
}

// ============================================================
// Wordmark
// ============================================================

/// The mark and the name, once, at the top of Now. Never a header bar.
struct Wordmark: View {
    var night: Bool

    /// --silk-track-mark, .34em on --silk-size-mark. SwiftUI tracks *after*
    /// every glyph including the last, so the trailing space is clawed back
    /// and the pair stays geometrically centred — the CSS does the same thing
    /// with `margin-right: -.34em`.
    ///
    /// Measured, not assumed, because the claw-back is only right if SwiftUI
    /// really does track after the last glyph — and it does. On a 3x simulator
    /// screenshot (1206px wide, centre 603.0) the lockup's ink runs columns
    /// 520…686, midpoint 603.5: **0.17pt right of centre**. Drop the claw-back
    /// and the same arithmetic puts it 2.3pt right. Leave it in.
    private static let track = Silk.track(0.34, 11)

    /// The lockup is centred; it does not *read* centred. This nudge is the
    /// difference, and it is named for what it is — an optical correction, not
    /// a bug fix. Nothing above it is wrong.
    ///
    /// Why the eye disagrees with the geometry, from the same screenshot: the
    /// ensō is the heaviest thing here and all of it is at the left end. It
    /// carries 38.8% of the lockup's ink in the leading 21% of its width (it is
    /// drawn at .68 against the text's .62, and its widest stroke forms the
    /// left edge — the densest column in the whole mark sits 1pt in from it).
    /// The right end is the opposite: the K's raking leg feathers out, its last
    /// 1.7pt carrying almost no ink at all. So the ink centroid lands 2.80pt
    /// left of the geometric centre.
    ///
    /// The eye splits the difference rather than following the centroid, so the
    /// nudge is not 2.80. Two independent low-pass measures of the ink profile
    /// agree on where it does land: the midpoint of the 10%-of-ink flanks, and
    /// the half-maximum width after a .75pt Gaussian blur — the squint test,
    /// quantified — both put the perceived centre 1.0pt left. Hence 1pt, which
    /// is also 1.8% of the 55.7pt lockup, where this correction usually lands.
    ///
    /// Fixed, not scaled: `Silk.sans` is `.system(size:)` with no `relativeTo`,
    /// and the mark's frame is a literal 13, so the lockup is the same width at
    /// every Dynamic Type setting and so is the correction.
    ///
    /// `offset` and not padding, because padding would widen the lockup and
    /// centring would then hand half the nudge straight back.
    private static let opticalNudge: CGFloat = 1

    var body: some View {
        HStack(spacing: 8) {                             // _ds_bundle.css:98
            EnsoMark(color: night ? Silk.paperAlpha(0.40) : Silk.inkAlpha(0.68))
                .frame(width: 13, height: 13)            // _ds_bundle.css:100
            // The product's mark, not something Silk says — it costs nothing
            // against the string budget.
            //
            // And for the same reason it keeps its tokens while the rest of the
            // text ramp was lifted to the AA floor: WCAG 1.4.3 exempts a
            // logotype, and this is one — the lockup is the brand, not prose.
            // The exemption is worth taking rather than waiving, because the
            // 1pt nudge above is derived from THIS pair of alphas: the centroid
            // sits left because the mark is drawn at .68 against the text's
            // .62, and darkening the text alone would move it without moving
            // the correction that answers to it.
            Text("SILK")
                .font(Silk.sans(11, weight: .medium))
                .tracking(Self.track)
                .padding(.trailing, -Self.track)
                .foregroundStyle(night ? Silk.paperAlpha(0.50) : Silk.inkAlpha(0.62))
        }
        // One place, so Now, Settings and the conversation stage all get it.
        .offset(x: Self.opticalNudge)
    }
}

// ============================================================
// Doors
// ============================================================

/// live — in play today · rest — not in play · open — a grant is running.
enum DoorRowState {
    case live, rest, open
}

/// A door, not a row. The naming is load-bearing: a door shows state and
/// offers no control — no toggle, no chevron, no icon, no Manage. Weight is
/// the state signal and the 6pt dot is the only mark. (Doors.prompt.md)
struct DoorRow: View {
    var name: String
    /// The row's serif slot, rendered verbatim — nil when the door is at rest.
    /// `DoorState.displayTime()` in SilkCore is what fills it, and the
    /// separator belongs to that string ("· 5:00", "· till 4:52"), so this row
    /// must not add one of its own. Silk answers in deadlines, not countdowns.
    var time: String?
    var state: DoorRowState
    var night: Bool
    /// The last door in a group drops its rule.
    var showsRule: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .font(Silk.sans(15, weight: state == .rest ? .regular : .medium))
                .tracking(Silk.track(-0.005, 15))       // --silk-track-tight on --silk-size-body
                .foregroundStyle(nameColor)
            // Always present, empty at rest: the time sits right after the
            // name rather than at the far edge, so if the view came and went
            // the name would shuffle every time a door opened.
            Text(timeText)
                .font(Silk.serif(14))                    // --silk-size-time; tabular is baked in
                .foregroundStyle(night ? Silk.paperAlpha(0.56) : Silk.inkAlpha(0.70))
            // `margin-left: auto` on the dot (_ds_bundle.css:242). The floor is
            // not from the CSS — it keeps the dot off the time when a door has
            // a long name and the row runs out of room.
            Spacer(minLength: 8)
            dot
        }
        .frame(height: 52)                               // _ds_bundle.css:223
        .overlay(alignment: .bottom) {
            if showsRule {
                // ink .055 — the faintest line Silk draws (_ds_bundle.css:224).
                Rectangle()
                    .fill(night ? Silk.paperAlpha(0.05) : Silk.inkAlpha(0.055))
                    .frame(height: 1)
                    .accessibilityHidden(true)   // a rule organizes; it says nothing
            }
        }
        // Colours cross the .5s; the weight snaps, exactly as the CSS does
        // (it transitions `color` only).
        .animation(Silk.motion(Silk.Motion.door), value: state)
    }

    /// The gap before the time is a non-breaking space inside the serif span,
    /// exactly as the markup sets it (Doors.html: `<span class="t ny">&nbsp;·
    /// 5:00</span>`) — CSS gives `.silk-door__time` no margin. Keeping it a
    /// character rather than a spacing keeps it in the time's own font and
    /// size, so it grows with the type instead of staying a fixed 4pt.
    private var timeText: String {
        guard let time else { return "" }
        return "\u{00A0}\(time)"
    }

    private var nameColor: Color {
        guard !night else {
            // Under lacquer every name dims alike. An open door keeps its
            // pop in the dot, never in the type.
            return state == .rest ? Silk.paperAlpha(0.55) : Silk.paperAlpha(0.61)
        }
        switch state {
        case .live: return Silk.inkAlpha(0.84)
        case .rest: return Silk.inkAlpha(0.66)
        case .open: return Silk.inkAlpha(0.90)
        }
    }

    /// One circle in three costumes. Fill and ring are both colours, so a
    /// door waking or resting cross-fades instead of swapping shapes.
    private var dot: some View {
        Circle()
            .fill(dotFill)
            .overlay(Circle().strokeBorder(dotRing, lineWidth: 1))
            .frame(width: 6, height: 6)                  // _ds_bundle.css:243
            // The state the dot marks is spoken by the door's label.
            .accessibilityHidden(true)
    }

    private var dotFill: Color {
        switch state {
        case .live: return night ? Silk.paperAlpha(0.30) : Silk.inkAlpha(0.72)
        case .rest: return .clear
        // Leaf keeps its colour at night — the one pop that survives the
        // crossing. A grant that is running is still running after dark.
        case .open: return Silk.leaf
        }
    }

    private var dotRing: Color {
        guard state == .rest else { return .clear }
        return night ? Silk.paperAlpha(0.18) : Silk.inkAlpha(0.35)
    }
}

// ============================================================
// Command bar
// ============================================================

/// The only input in Silk: budgets, down hours, grants — all of it is said
/// here, in a sentence. There is no settings screen behind it.
///
/// A hairline on the paper, never a filled field: a filled input would make
/// this a chat app, which is exactly what it isn't. It should recede until
/// you want it. (CommandBar.prompt.md)
///
/// **No placeholder text.** The current design leaves the bar empty — an empty
/// hairline asks nothing, and "Tell Silk…" was an instruction the screen does not
/// need to carry.
///
/// The mic is real but it is not voice: in the prototype it is a `<label for>`
/// that focuses the input. It is an affordance for reaching the bar one-handed,
/// so here it focuses the field too, and nothing about it records audio.
///
/// The bar is also the conversation's handle — the "docked" choreography
/// (handoff README.md:196-212). Focus with nothing said raises it to the
/// vertical middle over 450ms on the one curve; the first send glides it home
/// in one continuous move and it stays docked while the thread lives. Both
/// states are driven from outside: `hasTurns` is the prototype's `has-turns`
/// class (Silk Mockup.dc.html:28, 389), and `rise` is the distance to travel,
/// because only the container knows how much room the keyboard has left it.
struct CommandBar: View {
    @Binding var text: String
    var night: Bool
    var onSubmit: () -> Void
    /// The thread is non-empty — docked even while focused. Defaults keep the
    /// pre-conversation call sites (and their planted bar) compiling unchanged.
    var hasTurns: Bool = false
    /// How far the focus rise travels, in points. 0 means the bar never
    /// leaves home and only the keyboard lifts it. Compute with
    /// `CommandBar.riseDistance(in:)` from the height of the bar's own
    /// keyboard-avoiding container.
    var rise: CGFloat = 0
    /// Hoisted focus, so the root can dim the stage and clear the thread on
    /// blur. nil keeps focus private, as before.
    var focus: FocusState<Bool>.Binding? = nil

    @FocusState private var innerFocus: Bool

    /// The CSS's -312 is measured on the keyboardless 800pt design frame:
    /// the docked bar's centre sits at 800 − 44 − 26 = 730, and 730 − 312
    /// lands it at 418 — the frame's middle, 18pt low. Generalised:
    /// rise(h) = (h − 70) − (h/2 + 18) = h/2 − 88, which returns exactly 312
    /// for h = 800 and, when the container has already been shortened by a
    /// keyboard, the residual that puts the bar mid-way up the *visible*
    /// paper instead of stacking the full 312 on top of the keyboard's lift.
    static func riseDistance(in containerHeight: CGFloat) -> CGFloat {
        max(0, containerHeight / 2 - 88)
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $innerFocus }
    private var isFocused: Bool { focusBinding.wrappedValue }
    /// Rising means "say something"; docking means "we are talking now."
    private var raised: Bool { isFocused && !hasTurns }

    var body: some View {
        HStack(spacing: 12) {                            // _ds_bundle.css:293
            TextField("", text: $text)
                .accessibilityIdentifier("silk.bar")
                // The empty hairline asks nothing on screen; VoiceOver still
                // needs the field named. "Bar" is what the mic's label calls it.
                .accessibilityLabel("Bar")
                .focused(focusBinding)
                .submitLabel(.send)
                .autocorrectionDisabled()
                .onSubmit(onSubmit)
                // 15 → 18 on focus (Silk Mockup.dc.html:23, 32) — and font
                // size is not animatable on a text field, so the field is set
                // at 18 and scaled to 15/18 when idle. Down-scaling keeps the
                // raised state, the one being read and typed into, pixel-true;
                // and because the CSS tracks in em, tracking scaling along
                // with the glyphs is the correct behaviour, not a side effect:
                // track(-0.005, 18) × 15/18 = track(-0.005, 15) exactly.
                .font(Silk.sans(18))                     // focused body size
                .tracking(Silk.track(-0.005, 18))        // --silk-track-tight
                .scaleEffect(isFocused ? 1 : 15.0 / 18.0, anchor: .leading)
                // Full ink, not the greeting's ramp — what you typed is yours,
                // and the caret is ink too so no system blue crosses the paper.
                .foregroundStyle(night ? Silk.paperAlpha(0.85) : Silk.ink)
                .tint(night ? Silk.paperAlpha(0.85) : Silk.ink)

            Button { focusBinding.wrappedValue = true } label: {
                MicGlyph()
                    .frame(width: 18, height: 18)        // _ds_bundle.css:294
                    .foregroundStyle(night ? Silk.paperAlpha(0.42) : Silk.inkAlpha(0.55))
                    // 18 is the glyph's box, sized for a cursor. The target is
                    // 44 — the same claw-back PageDots uses — so reaching the
                    // bar one-handed, which is the mic's whole purpose, works.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Focus the bar")
            .padding(.trailing, -13)
        }
        .padding(.horizontal, 20)                        // _ds_bundle.css:274
        .frame(height: 52)                               // _ds_bundle.css:271
        // The pill is the input: without this only the ~20pt text line is
        // tappable and most of the 52 hits nothing.
        .contentShape(Rectangle())
        .onTapGesture { focusBinding.wrappedValue = true }
        // strokeBorder, not stroke: CSS draws its 1px border inside the box,
        // and a centred stroke would put half a point outside the 52.
        .background(
            RoundedRectangle(cornerRadius: 26)           // _ds_bundle.css:275
                .strokeBorder(night ? Silk.paperAlpha(0.12) : Silk.inkAlpha(0.14), lineWidth: 1)
        )
        // The rise. One translate on the one curve, and the same curve back:
        // the dock is not a second choreography, it is this one reversing
        // (Silk Mockup.dc.html:22, 26, 28).
        .offset(y: raised ? -rise : 0)
        .animation(Silk.motion(0.45), value: raised)
        // The grow rides focus, not the rise — the input holds 18 while the
        // conversation is docked (Silk Mockup.dc.html:32 keys on `input:focus`).
        .animation(Silk.motion(0.45), value: isFocused)
        // The keyboard's own arrival re-measures the container and retargets
        // `rise` mid-flight; covering it with the same curve keeps the two
        // motions one motion instead of a lift with a snap in it.
        .animation(Silk.motion(0.45), value: rise)
    }
}

/// The mic, drawn rather than borrowed: a capsule, a cradle arc and a stem,
/// stroked 1.6 in a 24-unit box (guidelines/enso-symbols.svg, `#mic`).
struct MicGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            Path { p in
                p.addRoundedRect(in: CGRect(x: 9 * s, y: 3 * s, width: 6 * s, height: 11 * s),
                                 cornerSize: CGSize(width: 3 * s, height: 3 * s))
                p.move(to: CGPoint(x: 5.5 * s, y: 11.5 * s))
                p.addArc(center: CGPoint(x: 12 * s, y: 11.5 * s), radius: 6.5 * s,
                         startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                p.move(to: CGPoint(x: 12 * s, y: 18 * s))
                p.addLine(to: CGPoint(x: 12 * s, y: 21 * s))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// ============================================================

#Preview {
    @Previewable @State var page = 0
    @Previewable @State var dayText = ""
    @Previewable @State var nightText = "20 min instagram"

    HStack(spacing: 0) {
        ChromeGallery(night: false, page: $page, text: $dayText)
        ChromeGallery(night: true, page: $page, text: $nightText)
    }
}

private struct ChromeGallery: View {
    var night: Bool
    @Binding var page: Int
    @Binding var text: String

    var body: some View {
        // Gallery framing only — the screen's real insets live in NowView.
        VStack(spacing: 0) {
            Wordmark(night: night)
                .padding(.top, 28)

            // Six doors: every state with a time and without one, so the
            // baseline can be checked against itself. The time strings are the
            // ones `DoorState.displayTime()` actually produces, separator and
            // all — a resting door with a time is impossible in the model, and
            // is here only to prove the row does not move when it appears.
            VStack(spacing: 0) {
                DoorRow(name: "Instagram", time: "· 5:00", state: .live, night: night, showsRule: true)
                DoorRow(name: "TikTok", time: nil, state: .live, night: night, showsRule: true)
                DoorRow(name: "Clash", time: "· till 4:52", state: .open, night: night, showsRule: true)
                DoorRow(name: "Discord", time: nil, state: .open, night: night, showsRule: true)
                DoorRow(name: "Reddit", time: "· 9:00", state: .rest, night: night, showsRule: true)
                DoorRow(name: "YouTube", time: nil, state: .rest, night: night, showsRule: false)
            }
            .padding(.horizontal, 46)                   // .silk-doors 26px 46px 0
            .padding(.top, 26)

            Spacer()

            CommandBar(text: $text, night: night, onSubmit: {})
                .padding(.horizontal, 28)               // .silk-cmdbar left/right 28
            // The CSS sets the dots 24px off the bottom; most of that is
            // already inside the 44pt tap target, so only the remainder is left.
            PageDots(count: 2, index: $page, night: night)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(night ? Silk.lacquer : Silk.paper)
    }
}
