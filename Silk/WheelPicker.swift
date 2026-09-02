import SwiftUI
import SilkCore

// The wheel picker — Silk's one editor. Three rows on Settings open it, and it
// is a full-screen overlay rather than a sheet or a push: while a value is
// being chosen it is the only thing in the world, and the page waits behind a
// .97 ground it can just barely be felt through. (handoff README.md §4;
// Silk Mockup.dc.html:166-182)
//
// Tapping the backdrop commits and closes. There is no OK button and no
// Cancel: the value resting in the selection frame *is* the choice, and a
// second confirmation would be the system doubting what it can already see.
//
// With one qualification, which is the whole of `touched` below: a wheel that
// was never moved was never a choice. It opens on the seat NEAREST the stored
// value, so a wheel opened only to be read would otherwise write a number
// nobody chose — a budget of 35 opens on "30 min". Never moved is a dismissal;
// moved at all, including away and back to the seat it opened on, is the choice.

// ============================================================
// The column
// ============================================================

/// One wheel's worth of data: strings to spin, and where to open. The values
/// arrive pre-formatted — the picker renders them verbatim and knows nothing
/// about clocks or minutes, exactly as the prototype's wheels are handed
/// finished labels (Silk Mockup.dc.html:249-256).
struct WheelColumn: Identifiable {
    /// Stable identity, so the down-hours pair keeps each wheel's scroll if
    /// the overlay is rebuilt mid-flight.
    var id: String
    var values: [String]
    /// The index to open centred on. Clamped on entry, because a stored
    /// setting can outlive a table edit and a crash is not a design.
    var selected: Int
}

/// The five tables — four verbatim from the handoff (README.md:174-177 = Silk
/// Mockup.dc.html:236-239), and the caps, which the handoff predates. They live
/// beside the picker so the strings are audited in one place; the model passes
/// them in as columns and maps the committed indices back out.
enum WheelValues {
    static let downStart = ["8:00 PM", "8:30 PM", "9:00 PM", "9:30 PM",
                            "10:00 PM", "10:30 PM", "11:00 PM", "11:30 PM"]
    static let downEnd = ["5:00 AM", "5:30 AM", "6:00 AM", "6:30 AM",
                          "7:00 AM", "7:30 AM", "8:00 AM", "8:30 AM"]
    static let budgets = ["15 min", "30 min", "45 min", "60 min", "75 min", "90 min", "120 min"]
    static let undos = ["15 s", "30 s", "60 s", "90 s", "2 min", "5 min"]

    /// A door's own ceiling — `SilkCore.Caps.wheelValues`, not a copy of it.
    /// The seats and the minutes behind them are derived from one table there,
    /// so a wheel that shows "20 min" cannot commit 30; keeping the strings here
    /// and the values in the model was two hand-kept lists one edit apart.
    static let caps = Caps.wheelValues
}

// ============================================================
// The overlay
// ============================================================

/// The full-screen picker. Down hours passes two columns and gets two wheels
/// side by side, gap 8 (Silk Mockup.dc.html:168); budget and undo pass one.
///
/// Selections are held here, not written live: the prototype writes state on
/// every settle, but everything behind the overlay is hidden while it is up,
/// so the only observable moment is the backdrop tap — which delivers one
/// index per column and asks the parent to take the overlay down. Entry and
/// exit are both the parent's: the root fades the overlay in and out on the
/// one curve, so nothing here animates its own arrival or departure.
struct WheelPickerOverlay: View {
    var title: String
    var columns: [WheelColumn]
    var night: Bool
    /// One selected index per column, in column order — or **nil when no wheel
    /// was ever moved**. Commit and dismiss are the same gesture, so this is the
    /// overlay's only exit, and the two meanings have to be told apart here.
    ///
    /// Looking at a wheel must cost nothing: a wheel opens on the seat NEAREST
    /// the stored value, so a bare dismissal that committed would write a value
    /// the user never chose (budget 35 opens on "30 min"; a cap of 25 opens on
    /// "20 min", a silent tighten). But the model cannot infer that from the
    /// indices it receives — comparing them against the ones the wheel opened on
    /// also swallows a deliberate spin away and back, which made the opening
    /// seat permanently uncommittable: with the budget at 35 there was no
    /// gesture on that wheel that could set it to 30. Movement is a fact only
    /// the wheel has, so the wheel is what reports it.
    var onCommit: ([Int]?) -> Void

    @State private var selections: [Int]
    /// Set by the one `onChange` below, which sees every way a seat can change:
    /// a drag's settle, a tap on a row, and VoiceOver's adjustable action. It is
    /// never set on mount — `Wheel` puts itself on the selection's own seat and
    /// writes back only a landing that DIFFERS from it, and it will not write
    /// back at all until that seat has been applied. Both halves are load-bearing
    /// and both live in `Wheel.seat()`.
    @State private var touched = false

    init(title: String, columns: [WheelColumn], night: Bool,
         onCommit: @escaping ([Int]?) -> Void) {
        self.title = title
        self.columns = columns
        self.night = night
        self.onCommit = onCommit
        _selections = State(initialValue: columns.map {
            min(max($0.selected, 0), max($0.values.count - 1, 0))
        })
    }

    /// The veil, both faces: the ground itself at .97 (Silk Mockup.dc.html:368).
    /// Day lays `paper` on paper, so the veil is invisible as a colour and only
    /// the page under it goes; night lays `Night.ground` on the night radial and
    /// does the same thing, dimming the ellipse's centre by the one step the
    /// ellipse lifted it.
    ///
    /// It used to be `#1A1C20` at .97 under a comment claiming it was the
    /// ground's own floor. That was true of the handoff's slate radial and false
    /// of the ground Silk draws, so a cool blue-grey sheet was being laid over a
    /// warm black page. Internal, not fileprivate: Settings' door editor and the
    /// wait wear this exact veil, and they must reach one expression of it
    /// rather than three copies of a hex.
    static func veil(night: Bool) -> Color {
        (night ? Silk.Night.ground : Silk.paper).opacity(0.97)
    }

    var body: some View {
        ZStack {
            // The backdrop is the commit button — the whole screen, minus the
            // wheels themselves, which eat their taps the way the prototype's
            // `w.eat` stops propagation (Silk Mockup.dc.html:287).
            Self.veil(night: night)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCommit(touched ? selections : nil) }
                // The backdrop is the commit — VoiceOver needs it named to
                // leave the picker at all. Activation lands on the tap above.
                // Identifier last: it must ride the element the label creates.
                .accessibilityLabel(Text(SilkStrings.ok))
                .accessibilityAddTraits(.isButton)
                // Same placement as DoorOverlayScaffold: the identifier rides
                // the backdrop, not the ZStack. A container identifier stamps
                // itself onto every descendant and overwrites silk.picker.title
                // / silk.picker.wheel.N. The walks wait on `silk.picker` for
                // "the overlay is up"; the full-screen veil is that fact.
                .accessibilityIdentifier("silk.picker")

            VStack(spacing: 0) {
                // 12px, .12em, uppercase — the quietest voice on the screen
                // names what is being edited and then stays out of the way.
                // The sheet's ink-40 is the ramp's old floor (2.42:1); this is
                // the AA floor, still the ramp's quietest step. Hit-testing
                // off, so a tap on the word is a tap on the backdrop, as it is
                // in the DOM. (Silk Mockup.dc.html:167, 369)
                Text(title)
                    .textCase(.uppercase)
                    .font(Silk.sans(12))
                    .tracking(Silk.track(0.12, 12))
                    .foregroundStyle(night ? Silk.paperAlpha(0.60) : Silk.inkAlpha(0.65))
                    .padding(.bottom, 34)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("silk.picker.title")

                HStack(spacing: 8) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { i, column in
                        Wheel(values: column.values, selection: $selections[i], night: night,
                              axID: "silk.picker.wheel.\(i)")
                    }
                }
                // Drawn once for the whole overlay, not per wheel: with two
                // wheels up, one 280pt frame spans the pair — the frame marks
                // the reading line, not either wheel. (Silk Mockup.dc.html:179-182)
                .overlay { selectionFrame }
            }
        }
        // One place, watching the bindings themselves rather than the three
        // gestures that write them: a wheel is touched when a seat changes, by
        // whatever hand. Watching the gestures would have to enumerate them, and
        // the fourth one added would be the one that forgot.
        .onChange(of: selections) { touched = true }
    }

    /// Two 1pt hairlines at ink-14, 280 wide, centred on the middle row. The
    /// CSS puts their tops at −27 and +26 of centre — 53 apart, so the pt
    /// centres land at ∓26.5: a 1pt line above a 52pt gap reproduces both.
    private var selectionFrame: some View {
        VStack(spacing: 52) {
            hairline
            hairline
        }
        .frame(width: 280)
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the reading line is drawn, not spoken
    }

    private var hairline: some View {
        Rectangle()
            .fill(night ? Silk.paperAlpha(0.14) : Silk.inkAlpha(0.14))
            .frame(height: 1)
    }
}

// ============================================================
// One wheel
// ============================================================

/// A 128×312 window onto a column of 52pt rows. The geometry *is* the snap
/// unit: 312 − 2×130 of content margin leaves exactly one 52pt seat in the
/// middle, so view-aligned snapping can only ever rest a row dead centre —
/// the same arithmetic as the prototype's 130px spacers and
/// `round(scrollTop / 52)` (Silk Mockup.dc.html:171-176, 268).
private struct Wheel: View {
    var values: [String]
    @Binding var selection: Int
    var night: Bool
    /// Applied inside, after the wheel folds into one element — an identifier
    /// attached from outside lands on a wrapper that is no element at all,
    /// and XCUI never sees it.
    var axID: String

    /// What the scroll view reports at the centre anchor, and the one handle
    /// that moves it. Deliberately NOT seeded from the selection in an init —
    /// see `seat()`, which is where the wheel is put on its opening seat and
    /// where the reason it cannot be done in an init is written down.
    @State private var centred: Int?

    /// False until the opening seat has been applied. Until then the scroll view
    /// is resting somewhere nobody chose, and nothing it reports may reach
    /// `selection`.
    @State private var seated = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { i in
                    // white-space: nowrap — "10:30 PM" must never fold, so the
                    // text keeps its own width and the 128pt frame centres it.
                    Text(values[i])
                        .font(Silk.serif(24))
                        .tracking(Silk.track(-0.01, 24))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(i == selection ? fullInk : dimInk)
                        .frame(width: 128, height: 52)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Tap chooses and then rides to centre. The
                            // prototype leans on the browser's smooth scroll;
                            // Silk has one curve, so the ride runs on it.
                            selection = i
                            withAnimation(Silk.motion(0.4)) { centred = i }
                        }
                }
            }
            .scrollTargetLayout()
            // Only the selected row is full ink; the rest sit at ink-35 and
            // the handover crosses on the one curve, sharing it with the tap's
            // ride to centre. (Silk Mockup.dc.html:173, :33)
            .animation(Silk.motion(0.35), value: selection)
        }
        .contentMargins(.vertical, 130, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centred, anchor: .center)
        .scrollIndicators(.hidden)
        .frame(width: 128, height: 312)
        // The wheel dissolves into the ground rather than clipping: rows fade
        // over the outer thirds and are gone by the edge. The backdrop is
        // effectively opaque, so the dissolve is painted over the rows in the
        // veil's own colour — a mask would force the scrolling column
        // offscreen every frame of the drag.
        // linear-gradient(180deg, transparent 0%, black 32%, black 68%, transparent 100%)
        .overlay(alignment: .top) {
            LinearGradient(stops: [.init(color: veil, location: 0),
                                   .init(color: veil.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 312 * 0.32)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: veil.opacity(0), location: 0),
                                   .init(color: veil, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 312 * 0.32)
                .allowsHitTesting(false)
        }
        // The opening seat, applied the moment the wheel is on screen and never
        // again. `onAppear` and not `task`: a hop costs a rendered frame at the
        // wrong seat, and there is nothing to await.
        .onAppear { seat() }
        // The settle is the choice — the binding lands when the scroll rests,
        // which is the debounced `round(scrollTop / 52)` of the prototype.
        //
        // `seated` guards it, and that guard is what keeps `touched` honest.
        // Before the seat is applied the column is resting at offset 0 whatever
        // the selection says, and a position reported from there would be
        // written into `selection` — which is the overlay's `touched`, which is
        // the whole difference between a commit and a dismissal. A wheel that
        // wrote its own arrival into the selection would commit on a bare look,
        // every time, which is the regression this file's header exists to
        // prevent. Seating itself cannot trip it from the other side either: it
        // sets `centred` TO `selection`, so `landed != selection` is false.
        .onChange(of: centred) { _, landed in
            guard seated, let landed, landed != selection else { return }
            selection = landed
        }
        // One adjustable element per wheel: swipe up or down steps the value
        // and rides it to centre on the same curve the tap uses. The rows fold
        // into it — the resting value is the whole reading.
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(values[selection]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(axID)
    }

    /// Put the wheel on the seat it was opened with — once, instantly.
    ///
    /// `.scrollPosition(id:anchor:)` scrolls in response to a CHANGE in the
    /// value bound to it, and a value the binding was born holding is not one.
    /// So seeding `centred` in an init did nothing whatsoever: by the scroll
    /// view's first layout the binding already read the seat, there was nothing
    /// for the modifier to reconcile, and the column laid out at offset 0 and
    /// stayed there. Measured, not deduced — the column's own frame sat at the
    /// No-cap seat two seconds after the wheel opened, with the ink two rows
    /// below it on the stored value, because the ink is keyed on `selection` and
    /// only the scroll was wrong.
    ///
    /// That disagreement is the second cause of a bug the owner reported. A door
    /// capped at 10 min opened with the frame over "No cap"; the backdrop was
    /// tapped by someone who could see she had chosen No cap; and because no
    /// seat had actually moved the overlay correctly reported a dismissal, so
    /// nothing committed and nothing was said. "I set a cap it works, but when I
    /// try to go back to no cap it doesn't work."
    ///
    /// nil → selection IS a change, so the opening seat now rides the one
    /// mechanism that always worked: the same `centred` write the row tap and
    /// the VoiceOver step already make. `ScrollViewReader.scrollTo` would move
    /// it too, but it is a second positioning API stacked on the one already
    /// here — Apple's own note is that `scrollPosition` supersedes it — and two
    /// handles on one scroll is a thing to debug later, not a fix.
    ///
    /// Animations off, explicitly. The wheel "opens already resting on it, no
    /// animation" (the prototype sets `scrollTop` directly on mount, Silk
    /// Mockup.dc.html:264), and `onAppear` can be reached inside the transaction
    /// that raised the overlay — whose 0.4s would otherwise be handed to the
    /// seat and scroll it visibly into place from the wrong row.
    private func seat() {
        guard !seated else { return }
        seated = true
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { centred = selection }
    }

    private func step(_ delta: Int) {
        let next = min(max(selection + delta, 0), values.count - 1)
        guard next != selection else { return }
        selection = next
        withAnimation(Silk.motion(0.4)) { centred = next }
    }

    /// The backdrop's own colour at full strength — the ground, not the .97
    /// sheet: a veil laid on a ground cut from the same cloth reads as the
    /// ground, so painting the dissolve in it is painting in the backdrop.
    private var veil: Color { night ? Silk.Night.ground : Silk.paper }

    private var fullInk: Color { night ? Silk.paperAlpha(0.85) : Silk.ink }

    /// Night dims to rgba(246,243,236,.26) — the handoff's night-mode audit
    /// names this value directly (README.md:278). Day is ink-35.
    ///
    /// Left on the sheet's values by the ramp audit, and not because they pass.
    /// The rows are serif 24, which is WCAG "large" and answers to 3:1 rather
    /// than 4.5:1 — and these miss even that: ink-35 is 2.13:1 on paper and
    /// paper-26 is 2.22:1 on the night ground. Clearing 3:1 wants ink ≈ .48 and
    /// paper ≈ .37. It was not changed here because the unselected rows are the
    /// one place in the app where dimness is the mechanism rather than the
    /// hierarchy — they are the values you have NOT chosen, and the wheel says
    /// which one is live by how far the others recede. Raising them is a
    /// legitimate call, but it is a design decision about the picker and not
    /// the ramp fix, so it is named here rather than made quietly.
    private var dimInk: Color { night ? Silk.paperAlpha(0.26) : Silk.inkAlpha(0.35) }
}

// ============================================================

#Preview("Picker — budget · day") {
    ZStack {
        Ground(night: false).ignoresSafeArea()
        WheelPickerOverlay(
            title: "Budget",
            columns: [WheelColumn(id: "budget", values: WheelValues.budgets, selected: 3)],
            night: false,
            onCommit: { _ in })
    }
}

#Preview("Picker — down hours · night") {
    ZStack {
        Ground(night: true).ignoresSafeArea()
        WheelPickerOverlay(
            title: "Down hours",
            columns: [WheelColumn(id: "down.start", values: WheelValues.downStart, selected: 4),
                      WheelColumn(id: "down.end", values: WheelValues.downEnd, selected: 4)],
            night: true,
            onCommit: { _ in })
    }
}

#Preview("Picker — commit · live") {
    PickerRehearsal()
}

/// The whole gesture, rehearsed: tap a value to open its picker, spin or tap
/// a row, tap the backdrop — the label under the moon takes the commit. Both
/// grounds, single and double wheel.
private struct PickerRehearsal: View {
    @State private var night = false
    @State private var undoIndex = 2       // "60 s"
    @State private var startIndex = 4      // "10:00 PM"
    @State private var endIndex = 4        // "7:00 AM"
    @State private var editing: String?

    var body: some View {
        ZStack {
            Ground(night: night).ignoresSafeArea()

            VStack(spacing: 26) {
                Button(WheelValues.undos[undoIndex]) { editing = "undo" }
                Button("\(WheelValues.downStart[startIndex]) \u{2013} \(WheelValues.downEnd[endIndex])") {
                    editing = "down"
                }
                Button("\u{263E}") { night.toggle() }
            }
            .font(Silk.serif(21))
            .foregroundStyle(night ? Silk.paperAlpha(0.85) : Silk.ink)
            .buttonStyle(.plain)

            if editing == "undo" {
                WheelPickerOverlay(
                    title: "Undo",
                    columns: [WheelColumn(id: "undo", values: WheelValues.undos, selected: undoIndex)],
                    night: night) { picks in
                        // nil = the wheel was never moved, which is a dismissal.
                        if let picks { undoIndex = picks[0] }
                        editing = nil
                    }
            }
            if editing == "down" {
                WheelPickerOverlay(
                    title: "Down hours",
                    columns: [WheelColumn(id: "down.start", values: WheelValues.downStart, selected: startIndex),
                              WheelColumn(id: "down.end", values: WheelValues.downEnd, selected: endIndex)],
                    night: night) { picks in
                        if let picks { startIndex = picks[0]; endIndex = picks[1] }
                        editing = nil
                    }
            }
        }
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
    }
}
