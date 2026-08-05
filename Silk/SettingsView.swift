import SwiftUI
import SilkCore

/// Settings: the few global values, plus per-door allowances. The third page.
///
/// There is no page title and no section header above the first group — both
/// were cut as unnecessary (handoff README.md §3): the wordmark already signs
/// the screen, and three rows reading "Down hours / Budget / Undo" are their
/// own heading. Only the doors group earns a title, because door names are
/// user data and would otherwise read as more settings.
///
/// Every value arrives pre-formatted — "☾ 10:00 PM – 7:00 AM", "60 min · day",
/// "60 s" — because the model owns the clock and the composition rules
/// (SilkCore's DownHours already builds the first one, separator and all).
/// This view renders strings and reports taps; the wheel picker the taps open
/// is the parent's to raise, exactly as the shield is.
struct SettingsView: View {
    /// The three global rows' serif slots, verbatim.
    var downHours: String
    var budget: String
    var undo: String
    /// One row per door, in policy order. Value is the door's own daily ceiling
    /// — "20 min", or "No cap" — pre-formatted, like everything else here. It
    /// is not the day's balance: this page is the rules, and Now's list is the
    /// day.
    var doors: [SettingsDoorItem]
    /// Whether the quiet add row follows the doors: room under the maximum of
    /// six doors, and something left in the catalogue. The model decides.
    var showsAddRow: Bool
    var night: Bool
    var onTapDownHours: () -> Void
    var onTapBudget: () -> Void
    var onTapUndo: () -> Void
    /// A door row was tapped: the parent raises the editor overlay, exactly
    /// as the three global rows raise the wheel.
    var onTapDoor: (String) -> Void
    var onAddDoor: () -> Void

    var body: some View {
        // The same defence NowView mounts: rows are model-driven, and a long
        // door list on a small screen must scale the column uniformly rather
        // than clip rows off the bottom where nothing says they exist. Silk
        // has nothing to scroll.
        GeometryReader { geo in
            let reserve = max(0, Self.chromeReserve - geo.safeAreaInsets.bottom)
            let usable = geo.size.height - reserve
            let scale = min(1, usable / max(1, columnHeight))
            column
                .scaleEffect(scale, anchor: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // A door joining or leaving moves rows and the scale together;
                // both ride the one curve so nothing jumps. Keyed on ids only,
                // deliberately: a door's cap changing moves no row and resizes
                // nothing, so there is no layout to carry — the new value simply
                // stands where the old one did, which is how a row that states a
                // rule should take a new rule.
                .animation(Silk.motion(0.4), value: doors.map(\.id))
                .animation(Silk.motion(0.35), value: showsAddRow)
        }
    }

    /// Bar bottom 44 + bar height 52 — the chrome the root pins to the glass.
    private static let chromeReserve: CGFloat = 96

    /// 62 + wordmark 13 + 64, then 52 a row, then the title block 44 + 15 + 14.
    /// The add row is a row like any other: 52 when it shows.
    private var columnHeight: CGFloat {
        62 + 13 + 64 + 3 * 52 + 44 + 15 + 14
            + CGFloat(doors.count + (showsAddRow ? 1 : 0)) * 52
    }

    private var column: some View {
        VStack(spacing: 0) {
            // The wordmark's seat, held empty — the mockup mounts one mark
            // above both pages (Silk Mockup.dc.html:77, margin-top 62), and in
            // the app that one mark is the root's, on its own undimmed layer.
            // Mounting a second here would double it; the column keeps the
            // 13pt so the group's 64 still measures from the same place.
            Color.clear.frame(height: 13)
                .padding(.top, 62)

            // First group at 64, not the doors' usual 26: with no greeting and
            // no hero above it, the group takes a longer breath off the
            // wordmark. (Silk Mockup.dc.html:150)
            VStack(spacing: 0) {
                SettingsRow(name: SilkStrings.downHours, value: downHours,
                            night: night, showsRule: true, action: onTapDownHours)
                    .accessibilityIdentifier("silk.settings.down")
                SettingsRow(name: SilkStrings.budget, value: budget,
                            night: night, showsRule: true, action: onTapBudget)
                    .accessibilityIdentifier("silk.settings.budget")
                SettingsRow(name: SilkStrings.undo, value: undo,
                            night: night, showsRule: false, action: onTapUndo)
                    .accessibilityIdentifier("silk.settings.undo")
            }
            .padding(.horizontal, 46)
            .padding(.top, 64)

            // Mirror's .silk-chart__title, borrowed whole: sans 12, .04em,
            // ink-48 by day and paper-32 at night, margins 44/46/14.
            // (ds-bundle/_ds_bundle.css:377-382; Silk Mockup.dc.html:48, :155)
            Text(SilkStrings.apps)
                .font(Silk.sans(12))
                .tracking(Silk.track(0.04, 12))
                .foregroundStyle(night ? Silk.paperAlpha(0.32) : Silk.inkAlpha(0.48))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 44)
                .padding(.horizontal, 46)
                .padding(.bottom, 14)
                // The one section title on the page — VoiceOver can jump by it.
                .accessibilityAddTraits(.isHeader)

            // Per-door rows. These rows tap now: the owner asked to edit the
            // apps behind Silk after setup, so a tap raises the editor
            // (Rebind / Remove) the way the three global rows raise the
            // wheel. This deliberately amends the earlier canon note that
            // door rows were statements only — the row's *value* is still
            // not a control (a door's minutes are changed by asking Silk at
            // the bar), and the rows still carry no state dot: this list is
            // the rules, Now's list is the day.
            VStack(spacing: 0) {
                ForEach(doors) { door in
                    SettingsRow(name: door.name, value: door.value,
                                night: night,
                                showsRule: showsAddRow || door.id != doors.last?.id,
                                action: { onTapDoor(door.name) })
                        .accessibilityIdentifier("silk.settings.door.\(door.name)")
                        .transition(.opacity)
                }
                // The quiet way in for a seventh-minus-one app: a row in the
                // group's own costume, dimmed to affordance — it states
                // nothing, so it cannot dress like the statements above it.
                if showsAddRow {
                    SettingsRow(name: SilkStrings.addAnApp, value: "",
                                night: night, showsRule: false, quiet: true,
                                action: onAddDoor)
                        .accessibilityIdentifier("silk.settings.door.add")
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 46)
        }
    }
}

/// A door row's worth of data for Settings: a name and a finished string.
struct SettingsDoorItem: Identifiable {
    var name: String
    var value: String
    var id: String { name }
}

// ============================================================
// One row
// ============================================================

/// The doors idiom in a second costume: 52pt, hairline-ruled, sans name on
/// the left — but the serif slot rides the far edge (`margin-left: auto` on
/// the mockup's `__time`, Silk Mockup.dc.html:152) instead of trailing the
/// name, and there is no state dot. A settings row states a rule, and a rule
/// has no today.
private struct SettingsRow: View {
    var name: String
    var value: String
    var night: Bool
    /// The last row in a group drops its rule, as `.silk-door:last-child` does.
    var showsRule: Bool
    /// The add row's costume: an affordance, not a statement, so its name
    /// sits at the caption's ink rather than a door's.
    var quiet: Bool = false
    /// nil renders a statement. Every row taps now — the doors group opens
    /// the editor since the owner asked for post-setup editing (this amends
    /// the earlier "statements, not controls" canon note deliberately).
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .font(Silk.sans(15, weight: .medium))       // .silk-door__name, default costume
                .tracking(Silk.track(-0.005, 15))           // --silk-track-tight on --silk-size-body
                .foregroundStyle(nameInk)
            // The floor keeps the value off the name when a door has a long
            // name and the row runs out of room — same clause as DoorRow's dot.
            Spacer(minLength: 8)
            Text(value)
                .font(Silk.serif(14))                       // --silk-size-time; tabular baked in
                .foregroundStyle(night ? Silk.paperAlpha(0.26) : Silk.inkAlpha(0.50))
        }
        .frame(height: 52)                                  // _ds_bundle.css:223
        .overlay(alignment: .bottom) {
            if showsRule {
                // ink .055 — the faintest line Silk draws (_ds_bundle.css:224).
                Rectangle()
                    .fill(night ? Silk.paperAlpha(0.05) : Silk.inkAlpha(0.055))
                    .frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var nameInk: Color {
        if quiet {
            return night ? Silk.paperAlpha(0.28) : Silk.inkAlpha(0.45)
        }
        return night ? Silk.paperAlpha(0.36) : Silk.inkAlpha(0.84)
    }
}

// ============================================================
// The door editor
// ============================================================

/// Silk's own quiet overlay for editing the doors group — the wheel picker's
/// idiom in a second costume: the same .97 veil, the same uppercase whisper
/// of a title, the backdrop as the one exit. The menu offers Rebind and
/// Remove for a tapped door; the add mode offers the catalogue names not
/// already doors, in setup's chip costume. The guidance slot under either is
/// setup's own line, seated here with its own identifier.
struct DoorEditOverlay: View {
    enum Mode: Equatable {
        /// A door row was tapped: its name titles the overlay.
        case menu(doorName: String)
        /// The add row was tapped: pick a name from what's still free.
        case add(available: [String])
    }
    var mode: Mode
    var night: Bool
    var onRebind: () -> Void
    /// Daily cap: the parent takes this editor down and raises the wheel on the
    /// door — the two never share the screen, so the wheel's own title carries
    /// the name from here.
    var onCap: () -> Void
    var onRemove: () -> Void
    var onAdd: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            // The backdrop is the exit — the whole screen, minus the rows and
            // chips, which eat their taps as the wheels do.
            // The overlay's identifier rides the backdrop, never the ZStack:
            // an identifier on the container stamps itself onto every child
            // element, and Rebind, Remove and the guidance line would all
            // answer to the overlay's name instead of their own.
            (night ? WheelPickerOverlay.nightVeil.opacity(0.97) : Silk.paperAlpha(0.97))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityLabel(Text(SilkStrings.ok))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("silk.settings.editor")

            VStack(spacing: 0) {
                // The picker's own quiet title voice, verbatim.
                Text(title)
                    .textCase(.uppercase)
                    .font(Silk.sans(12))
                    .tracking(Silk.track(0.12, 12))
                    .foregroundStyle(night ? Silk.paperAlpha(0.35) : Silk.inkAlpha(0.40))
                    .padding(.bottom, 34)
                    .allowsHitTesting(false)

                switch mode {
                case .menu:
                    menuRows
                case .add(let names):
                    addChips(names)
                }

                // The steering that used to live here moved into the picker
                // sheet, where it stays on screen for as long as Apple's list
                // does. The editor is back to being only its actions.
            }
        }
    }

    private var title: String {
        switch mode {
        case .menu(let name): name
        case .add: SilkStrings.addAnApp
        }
    }

    /// Three rows now — 156pt inside the same 280pt frame the wheel's selection
    /// line spans, which is what the two overlays rhyme on. Only the last row
    /// drops its rule, so the shift is Change app and Daily cap ruled, Remove
    /// bare.
    ///
    /// The middle row is `dailyCap` and deliberately not `budget`: the overlay's
    /// title is already the door name, so "TIKTOK / Change app / Budget /
    /// Remove" reads as "TikTok's budget" — a per-door allowance, which is the
    /// one thing a cap is not, on a page whose global row already says "Budget".
    private var menuRows: some View {
        VStack(spacing: 0) {
            editorRow(SilkStrings.rebind, id: "silk.settings.rebind",
                      showsRule: true, action: onRebind)
            editorRow(SilkStrings.dailyCap, id: "silk.settings.cap",
                      showsRule: true, action: onCap)
            editorRow(SilkStrings.remove, id: "silk.settings.remove",
                      showsRule: false, action: onRemove)
        }
        .frame(width: 280)
    }

    /// The doors idiom at the picker's scale: 52pt, hairline-ruled, and the
    /// serif because these are sentences Silk offers, not labels.
    private func editorRow(_ label: String, id: String,
                           showsRule: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Silk.serif(19))
                .foregroundStyle(night ? Silk.paperAlpha(0.85) : Silk.inkAlpha(0.92))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                // Inside the label, as setup's chips carry theirs: attached
                // outside the button it lands on a wrapper that is no
                // element at all, and XCUI never sees it (Wheel's own note).
                .accessibilityIdentifier(id)
                .contentShape(Rectangle())
        }
        .buttonStyle(SilkPressStyle())
        .overlay(alignment: .bottom) {
            if showsRule {
                Rectangle()
                    .fill(night ? Silk.paperAlpha(0.05) : Silk.inkAlpha(0.055))
                    .frame(height: 1)
            }
        }
    }

    /// Setup's chip costume, unbound: outline only — nothing here is selected,
    /// a tap is a choice that immediately runs the one-app binding.
    private func addChips(_ names: [String]) -> some View {
        FlowLayout(spacing: 10) {
            ForEach(names, id: \.self) { name in
                Button {
                    onAdd(name)
                } label: {
                    Text(name)
                        .font(Silk.sans(14))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        // Inside the label, as setup's chips carry theirs —
                        // outside the button, XCUI never sees it.
                        .accessibilityIdentifier("add.chip.\(name)")
                        .overlay(
                            Capsule().stroke(night ? Silk.paperAlpha(0.14) : Silk.inkAlpha(0.14),
                                             lineWidth: 1)
                        )
                        .foregroundStyle(night ? Silk.paperAlpha(0.72) : Silk.inkAlpha(0.72))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 34)
        .animation(Silk.motion(0.35), value: names)
    }
}

// ============================================================

#Preview("Settings — day") {
    ZStack {
        Ground(night: false).ignoresSafeArea()
        SettingsView(downHours: PreviewValues.window,
                     budget: PreviewValues.budget,
                     undo: PreviewValues.undo,
                     doors: PreviewValues.doors,
                     showsAddRow: true,
                     night: false,
                     onTapDownHours: {}, onTapBudget: {}, onTapUndo: {},
                     onTapDoor: { _ in }, onAddDoor: {})
    }
}

#Preview("Settings — night") {
    ZStack {
        Ground(night: true).ignoresSafeArea()
        SettingsView(downHours: PreviewValues.window,
                     budget: PreviewValues.budget,
                     undo: PreviewValues.undo,
                     doors: PreviewValues.doors,
                     showsAddRow: true,
                     night: true,
                     onTapDownHours: {}, onTapBudget: {}, onTapUndo: {},
                     onTapDoor: { _ in }, onAddDoor: {})
    }
}

#Preview("Settings — live") {
    SettingsRehearsal()
}

/// The handoff's exact card, composed the way the model will compose it. The
/// window string is spelled in escapes because the gaps are load-bearing and
/// invisible: ☾, then nbsp + space, and an en dash between the hours — this
/// is a range, never a hyphen (ApertureView.swift's preview sets the
/// precedent; SilkCore's DownHours.apertureText builds the same string).
private enum PreviewValues {
    static let window = "\u{263E}\u{00A0} 10:00 PM \u{2013} 7:00 AM"
    static let budget = "60 min \u{00B7} \(SilkStrings.perDay)"
    static let undo = "60 s"
    /// A door's own ceiling, or the wheel's first seat where it has none. Most
    /// doors are uncapped — a cap is the exception a user reaches for, and a
    /// preview whose every row carries one would read as an allowance table.
    static let doors = [SettingsDoorItem(name: "Instagram", value: "20 min"),
                        SettingsDoorItem(name: "TikTok", value: "15 min"),
                        SettingsDoorItem(name: "Clash", value: SilkStrings.noCap),
                        SettingsDoorItem(name: "YouTube", value: SilkStrings.noCap)]
}

/// The whole page, rehearsed against the picker: tap a row, spin or tap a
/// value, tap the backdrop — the row takes the commit. The moon crosses the
/// ground, so both faces of both components can be walked in one preview.
/// This wiring is a sketch of what AppModel will own for real.
private struct SettingsRehearsal: View {
    private enum Slot { case down, budget, undo }

    @State private var night = false
    @State private var startIndex = 4      // "10:00 PM"
    @State private var endIndex = 4        // "7:00 AM"
    @State private var budgetIndex = 3     // "60 min"
    @State private var undoIndex = 2       // "60 s"
    @State private var editing: Slot?

    var body: some View {
        ZStack {
            Ground(night: night).ignoresSafeArea()
            Atmosphere(night: night).ignoresSafeArea()

            SettingsView(
                downHours: "\u{263E}\u{00A0} \(WheelValues.downStart[startIndex]) \u{2013} \(WheelValues.downEnd[endIndex])",
                budget: "\(WheelValues.budgets[budgetIndex]) \u{00B7} \(SilkStrings.perDay)",
                undo: WheelValues.undos[undoIndex],
                doors: PreviewValues.doors,
                showsAddRow: true,
                night: night,
                onTapDownHours: { editing = .down },
                onTapBudget: { editing = .budget },
                onTapUndo: { editing = .undo },
                onTapDoor: { _ in }, onAddDoor: {})

            Button("\u{263E}") { night.toggle() }
                .font(Silk.serif(15))
                .buttonStyle(.plain)
                .foregroundStyle(night ? Silk.paperAlpha(0.5) : Silk.inkAlpha(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 60)

            switch editing {
            case .down:
                WheelPickerOverlay(
                    title: SilkStrings.downHours,
                    columns: [WheelColumn(id: "down.start", values: WheelValues.downStart, selected: startIndex),
                              WheelColumn(id: "down.end", values: WheelValues.downEnd, selected: endIndex)],
                    night: night) { picks in
                        // nil = the wheel was never moved, which is a dismissal.
                        if let picks { startIndex = picks[0]; endIndex = picks[1] }
                        editing = nil
                    }
            case .budget:
                WheelPickerOverlay(
                    title: SilkStrings.budget,
                    columns: [WheelColumn(id: "budget", values: WheelValues.budgets, selected: budgetIndex)],
                    night: night) { picks in
                        if let picks { budgetIndex = picks[0] }
                        editing = nil
                    }
            case .undo:
                WheelPickerOverlay(
                    title: SilkStrings.undo,
                    columns: [WheelColumn(id: "undo", values: WheelValues.undos, selected: undoIndex)],
                    night: night) { picks in
                        if let picks { undoIndex = picks[0] }
                        editing = nil
                    }
            case nil:
                EmptyView()
            }
        }
        .animation(Silk.motion(Silk.Motion.crossing), value: night)
    }
}
