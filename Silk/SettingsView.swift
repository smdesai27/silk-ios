import SwiftUI
import FamilyControls
import ManagedSettings
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
                            night: night, showsRule: true,
                            axID: "silk.settings.down", action: onTapDownHours)
                SettingsRow(name: SilkStrings.budget, value: budget,
                            night: night, showsRule: true,
                            axID: "silk.settings.budget", action: onTapBudget)
                SettingsRow(name: SilkStrings.undo, value: undo,
                            night: night, showsRule: false,
                            axID: "silk.settings.undo", action: onTapUndo)
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
                                axID: "silk.settings.door.\(door.name)",
                                action: { onTapDoor(door.name) })
                        .transition(.opacity)
                }
                // The quiet way in for a seventh-minus-one app: a row in the
                // group's own costume, dimmed to affordance — it states
                // nothing, so it cannot dress like the statements above it.
                if showsAddRow {
                    SettingsRow(name: SilkStrings.addAnApp, value: "",
                                night: night, showsRule: false, quiet: true,
                                axID: "silk.settings.door.add",
                                action: onAddDoor)
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
    /// The row's name in the accessibility tree. Carried in rather than
    /// applied from outside, because the row is a `Button` now — see `body`.
    var axID: String
    /// Every row taps — the doors group opens the editor since the owner asked
    /// for post-setup editing (this amends the earlier "statements, not
    /// controls" canon note deliberately).
    var action: () -> Void

    /// A `Button`, not a `contentShape` + `onTapGesture`, and the difference is
    /// felt rather than seen. These rows live inside `TabView(.page)` — a
    /// UIPageViewController over a UIScrollView — where a SwiftUI tap gesture
    /// must lose pan arbitration before it can fire. Touch-down therefore
    /// produced *nothing* for the length of that arbitration, and the overlay
    /// arriving was the only acknowledgment the row ever gave. Every other
    /// tappable row in the app is already a `Button` under `SilkPressStyle`
    /// (Now's doors, the editor's own rows); this one was the exception.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(name)
                    .font(Silk.sans(15, weight: .medium))   // .silk-door__name, default costume
                    .tracking(Silk.track(-0.005, 15))       // --silk-track-tight on --silk-size-body
                    .foregroundStyle(nameInk)
                // The floor keeps the value off the name when a door has a long
                // name and the row runs out of room — same clause as DoorRow's dot.
                Spacer(minLength: 8)
                Text(value)
                    .font(Silk.serif(14))                   // --silk-size-time; tabular baked in
                    .foregroundStyle(night ? Silk.paperAlpha(0.26) : Silk.inkAlpha(0.50))
            }
            .frame(height: 52)                              // _ds_bundle.css:223
            .contentShape(Rectangle())
            // All three inside the label, in this order, and the identifier
            // last. Two mechanics decide where a name actually lands. An
            // identifier attached OUTSIDE a Button rides a wrapper that is no
            // element at all (the editor's own rows carry theirs inside for
            // exactly this reason) — and one attached to this HStack before it
            // folds would be stamped onto BOTH Texts, leaving the tree with
            // copies of the row's name on elements reading "Budget" and
            // "60 min · day" and the whole row on neither. `combine` folds the
            // pair into one element first; the identifier then rides that
            // element, whose label is the row entire, which is what the six
            // walks match on.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(axID)
        }
        .buttonStyle(SilkPressStyle())
        // Outside the button, as the editor's rows keep theirs: the press dims
        // what the row says, never the line that organizes the group.
        .overlay(alignment: .bottom) {
            if showsRule {
                // ink .055 — the faintest line Silk draws (_ds_bundle.css:224).
                Rectangle()
                    .fill(night ? Silk.paperAlpha(0.05) : Silk.inkAlpha(0.055))
                    .frame(height: 1)
            }
        }
    }

    private var nameInk: Color {
        if quiet {
            return night ? Silk.paperAlpha(0.28) : Silk.inkAlpha(0.45)
        }
        return night ? Silk.paperAlpha(0.36) : Silk.inkAlpha(0.84)
    }
}

// ============================================================
// The two overlays a doors row raises
// ============================================================

/// The veil, the backdrop, the column and the exit both door overlays share.
///
/// The veil is byte-identical to the wheel's on purpose, and it is the one thing
/// here that may not change. Both overlays are drawn on the same stratum, and
/// `AppModel.openCapWheel` swaps this one for the wheel in a single un-animated
/// frame precisely because two veils of the same colour at the same alpha make
/// that swap invisible — cross-fade them and composited coverage dips to .735 at
/// the midpoint and the page ghosts back through. The veil is the stratum's
/// floor; what stands on it is the costume, and the costume is what changed.
///
/// The identifier rides the BACKDROP and never this ZStack: an identifier on a
/// container stamps itself onto every descendant and overwrites the child's own,
/// so `silk.settings.cap`, `silk.settings.rebind`, `silk.settings.remove` and
/// every `add.chip.…` would answer to the overlay's name instead of their own.
///
/// One identifier for two components, deliberately: `silk.settings.editor` names
/// the stratum a door row or the add row raises, and the walks that wait on it
/// are waiting for "something came up here", not for which of the two.
private struct DoorOverlayScaffold<Content: View>: View {
    var night: Bool
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            (night ? WheelPickerOverlay.nightVeil.opacity(0.97) : Silk.paperAlpha(0.97))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityLabel(Text(SilkStrings.ok))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("silk.settings.editor")

            // The 280pt overlay column — the width the wheel's selection line
            // spans. It is the one measurement the two strata still share, so a
            // card and a wheel raised from the same row occupy the same block of
            // the screen and the handoff between them moves nothing sideways.
            content.frame(width: 280)
        }
    }
}

/// What a door row raises: the door, stated.
///
/// This was `DoorEditOverlay`, and it was the wheel picker's costume worn by
/// three tappable rows — the same .97 veil, the same uppercase whisper of a
/// title, the same 280pt column of centred 52pt serif rows. Someone who had just
/// learned "tap Budget, a wheel spins" met three centred serif rows in that veil
/// and read them as a wheel that had failed to draw. The wheel's rows are values
/// you scroll; these are verbs you tap, and nothing in the costume told them
/// apart. That is the whole of the report.
///
/// So the costume comes from the page the card was opened FROM. Settings' own
/// furniture — 52pt rows, a sans 15 medium name on the left, a serif value riding
/// the far edge, one hairline at ink .055 — says "still in Settings, looking at
/// one app" where the picker's costume said "a value is being chosen". And the
/// card is left-aligned top to bottom where the wheel is centred top to bottom,
/// which is most of the difference at a glance, before a single word is read.
///
/// It also **states before it offers**. The door's name and its bound icon head
/// the card; the cap row reads the ceiling actually in force; only then, under
/// the one rule, the two things that change something. Everything is legible
/// before anything is tapped, which is what was asked for.
///
/// No Close and no Done. The backdrop is the exit both overlays have always had,
/// and a card whose only escape is a button is a card that has to be dismissed
/// twice.
struct DoorDetailCard: View {
    var name: String
    /// The bound app's icon — **optional by construction**, not by defence.
    /// `ApplicationToken` is opaque and cannot be minted, so on the simulator
    /// every door's token is nil and every UI walk ever run sees this card
    /// without one. A header that only composed with the icon present would be a
    /// header nothing automated has ever looked at.
    var icon: ApplicationToken?
    /// The ceiling in force — "20 min", or "No cap" — already composed through
    /// `Caps.settingsValue(cap:)` by the mount site, never formatted here. The
    /// spine pins `settingsValue(cap: 20) == wheelValues[wheelSeat(for: 20)]`
    /// (CapsTests), and reading back exactly what the wheel would show is the
    /// entire reason this row exists.
    var cap: String
    /// The ceiling this door is *waiting* for — "no cap", "45" — or nil when
    /// nothing is parked on it. Composed through `Caps.pendingValue`, the same
    /// call Now's pending row composes its own line from, so the two surfaces
    /// cannot disagree about what tomorrow holds.
    ///
    /// This row is the whole answer to the report. Clearing a ceiling is a
    /// loosening (rule 3), so it parks — and the row behind this card, this
    /// card's cap row and the wheel all went on reading the ceiling still in
    /// force, with the ask visible on none of them. Re-opening the wheel and
    /// clearing it again produced the same reply over the same unchanged screen,
    /// which is exactly what "it doesn't work for some reason" describes. The
    /// card states the wait where the gesture was made.
    var pending: String?
    var night: Bool
    /// Daily cap: the parent takes this card down and raises the wheel on the
    /// door in one un-animated frame — the two never share the screen, so the
    /// wheel's own title carries the door name from here.
    var onCap: () -> Void
    /// The key, spent from here. The same call Now's pending row makes.
    var onApplyNow: () -> Void
    var onRebind: () -> Void
    var onRemove: () -> Void
    var onClose: () -> Void

    var body: some View {
        DoorOverlayScaffold(night: night, onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                // Apple's own icon for the app actually behind this door, at the
                // size an icon is recognised rather than merely noticed. Setup's
                // chip proved the idiom at 15pt (OnboardingView); the card is the
                // one place there is room to show it properly. Hit-testing off,
                // like the wheel's title: a tap on it is a tap on the backdrop.
                if let icon {
                    Label(icon)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                        // The header speaks the door's name one line down; the
                        // icon is proof for the eye, as EnsoMark is on the shield.
                        .accessibilityHidden(true)
                }

                // The door's name, in the one sans size above a row's — a name,
                // so sans (canon), and the card's subject, so the largest thing
                // in it. Never uppercased: the wheel's title whisper is what this
                // card is being told apart from.
                Text(name)
                    .font(Silk.sans(18, weight: .medium))
                    .tracking(Silk.track(-0.005, 18))
                    .foregroundStyle(statedInk)
                    .padding(.bottom, 30)
                    .allowsHitTesting(false)

                // What the door currently IS …
                capRow

                // … and what it is waiting to become, when something is. Under
                // the cap row and above the rule, because it is a second
                // statement about the ceiling and not a third verb: the rule
                // divides what is stated from what is offered, and a parked
                // change is stated.
                if let pending { pendingRow(pending) }

                // … and, under the one rule, what can be done about it. The rule
                // divides the statement from the offers; it is not a row
                // separator, which is why there is exactly one and it does not
                // repeat between the two actions.
                Rectangle()
                    .fill(night ? Silk.paperAlpha(0.05) : Silk.inkAlpha(0.055))
                    .frame(height: 1)

                actionRow(SilkStrings.rebind, id: "silk.settings.rebind", action: onRebind)
                actionRow(SilkStrings.remove, id: "silk.settings.remove", action: onRemove)
            }
            // The key spent from this card takes the pending row away and moves
            // the cap row's value in the same frame, and the card is still up to
            // watch it happen. One curve, the overlay's own — scoped to this
            // column and no wider, so the card's 0.4 is never lent to the page
            // underneath it.
            .animation(Silk.motion(Silk.Motion.overlay), value: pending)
        }
    }

    /// The row this redesign exists for: a `SettingsRow` in everything but its
    /// ink. 52pt, the label sans 15 medium on the left, the value serif riding
    /// the far edge, exactly as the page states a rule.
    ///
    /// The page's ramp is inverted here, deliberately. There the name is what you
    /// scan a column for and the value is the detail, so the name is ink .84 and
    /// the value ink .50. Here the door is already named at the top of the card
    /// and the VALUE is the thing that was invisible before — so the value takes
    /// the card's full voice and the label takes the page's name ink. Serif 15
    /// rather than the page's 14 for the same reason: level with its label, the
    /// pair reads as one statement rather than as a row with a footnote.
    private var capRow: some View {
        Button(action: onCap) {
            HStack(spacing: 0) {
                Text(SilkStrings.dailyCap)
                    .font(Silk.sans(15, weight: .medium))
                    .tracking(Silk.track(-0.005, 15))
                    .foregroundStyle(night ? Silk.paperAlpha(0.36) : Silk.inkAlpha(0.84))
                // The floor keeps the value off the label if the two ever meet.
                Spacer(minLength: 8)
                Text(cap)
                    .font(Silk.serif(15))
                    .foregroundStyle(statedInk)
            }
            .frame(height: 52)
            .contentShape(Rectangle())
            // Both mechanics, in this order, and the identifier last. `combine`
            // folds the label and the value into ONE element first, so the
            // identifier rides an element whose label is the row entire ("Daily
            // cap No cap") — which is what the walk matches on, and which is the
            // whole point: the value is readable without tapping. Applied before
            // the fold it would be stamped onto both Texts and the row would
            // answer to neither. Applied outside the Button it would ride a
            // wrapper XCUI never sees.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("silk.settings.cap")
        }
        .buttonStyle(SilkPressStyle())
    }

    /// The parked ceiling, and the one way to have it before the day turns.
    ///
    /// Now's pending row, on the card's grid — the same three parts in the same
    /// order (sans label, serif value, the key riding the far edge), because it
    /// is the same fact and a user who has seen one should recognise the other.
    /// The value takes the page's quieter value ink rather than the card's full
    /// voice, and that is the point rather than a nicety: the ceiling above it is
    /// in force and this one is not, so the row that states the live rule stays
    /// the loudest thing on the card.
    ///
    /// Nothing here explains polarity. The canon's rule is that a deferral is a
    /// time-statement and never an explanation, so the *why* is carried by form:
    /// the live ceiling is stated above, unchanged, and this line sits under it
    /// naming a different day. Two rows, one glance, no lecture.
    private func pendingRow(_ value: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(SilkStrings.tomorrow)
                    .font(Silk.sans(15, weight: .medium))
                    .tracking(Silk.track(-0.005, 15))
                    .foregroundStyle(night ? Silk.paperAlpha(0.36) : Silk.inkAlpha(0.70))
                Text(value)
                    .font(Silk.serif(15))
                    .lineLimit(1)
                    .foregroundStyle(night ? Silk.paperAlpha(0.26) : Silk.inkAlpha(0.50))
            }
            // Folded first, so the identifier rides an element whose label is
            // the statement entire ("Tomorrow: no cap") — and folded on this
            // inner stack and not the row, so it cannot swallow the button's own
            // identifier the way a container identifier stamps its descendants.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("silk.settings.pending")

            Spacer(minLength: 8)

            Button(action: onApplyNow) {
                Text(SilkStrings.applyNow)
                    .font(Silk.serif(12.5))
                    .tracking(Silk.track(0.015, 12.5))
                    .foregroundStyle(night ? Silk.paperAlpha(0.44) : Silk.inkAlpha(0.45))
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("silk.settings.pending.apply")
        }
        .frame(height: 52)
        .transition(.opacity)
    }

    /// The two verbs, demoted under the rule. Sans and not the old serif 19:
    /// Silk's serif is for values and for the sentences Silk speaks, and "Change
    /// app" is neither — it is a label on a control, which is sans 15 medium
    /// everywhere else in the app.
    ///
    /// Their ink is the app's own secondary-action pair: `inkAlpha(0.45)` by day,
    /// which setup's "Other apps" and the page's quiet add row both speak at, and
    /// `paperAlpha(0.40)` at night, which is the handoff's `--silk-paper-40`
    /// (`.silk-btn-later`, the "Not now" of a proposal). Quieter than the cap row
    /// in both faces, which is the demotion.
    private func actionRow(_ label: String, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Silk.sans(15, weight: .medium))
                .tracking(Silk.track(-0.005, 15))
                .foregroundStyle(night ? Silk.paperAlpha(0.40) : Silk.inkAlpha(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52)
                // Inside the label, as setup's chips carry theirs: attached
                // outside the button it lands on a wrapper that is no element at
                // all, and XCUI never sees it.
                .accessibilityIdentifier(id)
                .contentShape(Rectangle())
        }
        .buttonStyle(SilkPressStyle())
    }

    /// What the card states — the door's name, and the ceiling in force. The
    /// overlay's full voice (`--silk-paper-85` at night), not the page's: the
    /// page dims its names to .36 because it is a list under a wordmark on the
    /// open ground, and this card is the only thing on the screen.
    private var statedInk: Color {
        night ? Silk.paperAlpha(0.85) : Silk.inkAlpha(0.92)
    }
}

/// What the quiet add row raises: the catalogue names still free.
///
/// A second component rather than a second `case`, and the split is the point.
/// The two modes shared a veil and a title voice and nothing else — and the
/// shared title voice was the defect: the add mode wore the wheel's uppercase
/// whisper for exactly the reason the menu did, so redesigning only the menu
/// would have left half the complaint standing behind the same identifier. Split,
/// each says what it is in the card's header voice, and neither carries a
/// `switch` that has to be read before its layout can be.
struct DoorAddOverlay: View {
    var available: [String]
    var night: Bool
    var onAdd: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        DoorOverlayScaffold(night: night, onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                // The card's header voice on the card's grid: the two things a
                // Settings row can raise are the same piece of furniture, and
                // neither of them is the wheel.
                Text(SilkStrings.addAnApp)
                    .font(Silk.sans(18, weight: .medium))
                    .tracking(Silk.track(-0.005, 18))
                    .foregroundStyle(night ? Silk.paperAlpha(0.85) : Silk.inkAlpha(0.92))
                    .padding(.bottom, 30)
                    .allowsHitTesting(false)

                // Setup's chip costume, unbound: outline only — nothing here is
                // selected, a tap is a choice that immediately runs the one-app
                // binding. They flow inside the scaffold's 280 now rather than
                // against their own margin, so the header's left edge and the
                // first chip's are the same edge.
                FlowLayout(spacing: 10) {
                    ForEach(available, id: \.self) { name in
                        Button {
                            onAdd(name)
                        } label: {
                            Text(name)
                                .font(Silk.sans(14))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                // Inside the label, as setup's chips carry theirs
                                // — outside the button, XCUI never sees it.
                                .accessibilityIdentifier("add.chip.\(name)")
                                .overlay(
                                    Capsule().stroke(night ? Silk.paperAlpha(0.14)
                                                           : Silk.inkAlpha(0.14),
                                                     lineWidth: 1)
                                )
                                .foregroundStyle(night ? Silk.paperAlpha(0.72)
                                                       : Silk.inkAlpha(0.72))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(Silk.motion(0.35), value: available)
            }
        }
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

// The card in both faces and in both of the two states the icon has. Neither
// preview can show a real icon — `ApplicationToken` is opaque and Xcode's canvas
// has no Screen Time authorization — so `icon: nil` is not a shortcut here, it is
// the only thing previews and the simulator will ever render. The day card
// carries a ceiling and the night card carries none, so both halves of
// `Caps.settingsValue` are walked without a model.

#Preview("Door card — day") {
    ZStack {
        Ground(night: false).ignoresSafeArea()
        DoorDetailCard(name: "Instagram", icon: nil, cap: "20 min", pending: nil,
                       night: false,
                       onCap: {}, onApplyNow: {}, onRebind: {}, onRemove: {}, onClose: {})
    }
}

#Preview("Door card — night") {
    ZStack {
        Ground(night: true).ignoresSafeArea()
        DoorDetailCard(name: "TikTok", icon: nil, cap: SilkStrings.noCap, pending: nil,
                       night: true,
                       onCap: {}, onApplyNow: {}, onRebind: {}, onRemove: {}, onClose: {})
    }
}

/// The state the report is about: a ceiling of 20 still in force, a clearing
/// parked against it, and the key offered where the wheel was spun. The two rows
/// disagree on purpose — that disagreement IS the feature, and it is the whole
/// reason "Applies tomorrow." over an unchanged card read as a dropped command.
#Preview("Door card — a parked clearing") {
    ZStack {
        Ground(night: false).ignoresSafeArea()
        DoorDetailCard(name: "Instagram", icon: nil, cap: "20 min",
                       pending: SilkStrings.noCap.lowercased(), night: false,
                       onCap: {}, onApplyNow: {}, onRebind: {}, onRemove: {}, onClose: {})
    }
}

#Preview("Add an app — day") {
    ZStack {
        Ground(night: false).ignoresSafeArea()
        DoorAddOverlay(available: PreviewValues.addable, night: false,
                       onAdd: { _ in }, onClose: {})
    }
}

#Preview("Add an app — night") {
    ZStack {
        Ground(night: true).ignoresSafeArea()
        DoorAddOverlay(available: PreviewValues.addable, night: true,
                       onAdd: { _ in }, onClose: {})
    }
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
    /// The whole catalogue minus the four doors above — what the add overlay
    /// offers a user four apps in, and enough names to see the flow wrap inside
    /// the 280 column.
    static let addable = ["X", "Reddit", "Snapchat", "Facebook", "Threads",
                          "Pinterest", "Twitch", "Netflix", "LinkedIn"]
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
