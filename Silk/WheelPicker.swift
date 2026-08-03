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

/// The four tables, verbatim from the handoff (README.md:174-177 = Silk
/// Mockup.dc.html:236-239). They live beside the picker so the strings are
/// audited in one place; the model passes them in as columns and maps the
/// committed indices back out.
enum WheelValues {
    static let downStart = ["8:00 PM", "8:30 PM", "9:00 PM", "9:30 PM",
                            "10:00 PM", "10:30 PM", "11:00 PM", "11:30 PM"]
    static let downEnd = ["5:00 AM", "5:30 AM", "6:00 AM", "6:30 AM",
                          "7:00 AM", "7:30 AM", "8:00 AM", "8:30 AM"]
    static let budgets = ["15 min", "30 min", "45 min", "60 min", "75 min", "90 min", "120 min"]
    static let undos = ["15 s", "30 s", "60 s", "90 s", "2 min", "5 min"]
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
    /// One selected index per column, in column order. Commit and dismiss are
    /// the same gesture, so this is the overlay's only exit.
    var onCommit: ([Int]) -> Void

    @State private var selections: [Int]

    init(title: String, columns: [WheelColumn], night: Bool,
         onCommit: @escaping ([Int]) -> Void) {
        self.title = title
        self.columns = columns
        self.night = night
        self.onCommit = onCommit
        _selections = State(initialValue: columns.map {
            min(max($0.selected, 0), max($0.values.count - 1, 0))
        })
    }

    /// rgba(26,28,32,.97) — the night ground's own floor, #1A1C20, not the
    /// warm lacquer: the overlay is a veil over the slate radial, so it must
    /// be cut from the same cloth. (Silk Mockup.dc.html:368; Ground.low)
    /// Internal, not fileprivate: Settings' door editor is the same overlay
    /// idiom and must wear the same veil rather than a second constant.
    static let nightVeil = Color(red: 26 / 255, green: 28 / 255, blue: 32 / 255)

    var body: some View {
        ZStack {
            // The backdrop is the commit button — the whole screen, minus the
            // wheels themselves, which eat their taps the way the prototype's
            // `w.eat` stops propagation (Silk Mockup.dc.html:287).
            (night ? Self.nightVeil.opacity(0.97) : Silk.paperAlpha(0.97))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCommit(selections) }
                // The backdrop is the commit — VoiceOver needs it named to
                // leave the picker at all. Activation lands on the tap above.
                // Identifier last: it must ride the element the label creates.
                .accessibilityLabel(Text(SilkStrings.ok))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("silk.picker.backdrop")

            VStack(spacing: 0) {
                // 12px, .12em, uppercase, ink-40 — the quietest voice on the
                // screen names what is being edited and then stays out of the
                // way. Hit-testing off, so a tap on the word is a tap on the
                // backdrop, as it is in the DOM. (Silk Mockup.dc.html:167, 369)
                Text(title)
                    .textCase(.uppercase)
                    .font(Silk.sans(12))
                    .tracking(Silk.track(0.12, 12))
                    .foregroundStyle(night ? Silk.paperAlpha(0.35) : Silk.inkAlpha(0.40))
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
        .accessibilityIdentifier("silk.picker")
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

    /// What the scroll view reports at the centre anchor. Seeded from the
    /// selection so the wheel opens already resting on it, no animation —
    /// the prototype sets `scrollTop` directly on mount (Silk Mockup.dc.html:264).
    @State private var centred: Int?

    init(values: [String], selection: Binding<Int>, night: Bool, axID: String) {
        self.values = values
        self._selection = selection
        self.night = night
        self.axID = axID
        _centred = State(initialValue: selection.wrappedValue)
    }

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
        // The settle is the choice — the binding lands when the scroll rests,
        // which is the debounced `round(scrollTop / 52)` of the prototype.
        .onChange(of: centred) { _, landed in
            if let landed, landed != selection { selection = landed }
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

    private func step(_ delta: Int) {
        let next = min(max(selection + delta, 0), values.count - 1)
        guard next != selection else { return }
        selection = next
        withAnimation(Silk.motion(0.4)) { centred = next }
    }

    /// The backdrop's own colour at full strength: nightVeil or paper at .97
    /// over a ground cut from the same cloth reads as the veil itself.
    private var veil: Color { night ? WheelPickerOverlay.nightVeil : Silk.paper }

    private var fullInk: Color { night ? Silk.paperAlpha(0.85) : Silk.ink }

    /// Night dims to rgba(246,243,236,.26) — the handoff's night-mode audit
    /// names this value directly (README.md:278). Day is ink-35.
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
                        undoIndex = picks[0]
                        editing = nil
                    }
            }
            if editing == "down" {
                WheelPickerOverlay(
                    title: "Down hours",
                    columns: [WheelColumn(id: "down.start", values: WheelValues.downStart, selected: startIndex),
                              WheelColumn(id: "down.end", values: WheelValues.downEnd, selected: endIndex)],
                    night: night) { picks in
                        startIndex = picks[0]
                        endIndex = picks[1]
                        editing = nil
                    }
            }
        }
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
    }
}
