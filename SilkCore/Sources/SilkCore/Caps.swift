import Foundation

/// Everything a per-app ceiling has to *say*, and the seats it is chosen from.
///
/// These are compositions, not state: a wheel index, a Settings row's value, the
/// toast a commit leaves, the pending row's one line, and the cap half of an
/// undo. Every one of them lived in `AppModel` first, and every one of them was
/// therefore reachable only from the thirteen-minute simulator — which is to say
/// from nothing, because no walk selects the No-cap seat and no walk parks a cap
/// loosening. A cap is the one rule with no hero number beside it to contradict
/// a wrong sentence, so the sentences are the feature; they belong where the
/// pre-push hook can hold them to account in a tenth of a second.
///
/// None of it needs SwiftUI, and none of it reads the App Group. `AppModel`,
/// `NowView` and the shield keep one-line wrappers.
public enum Caps {

    // MARK: - The wheel's seats

    /// The cap seats. Seven minute values on the same 5/10/15 grain the shortest
    /// grants use — a ceiling lives on the shared pool, and a seat coarser than
    /// the grants it bounds would be unspinnable to a useful number. (It is
    /// deliberately *not* `budgetTable`'s 15-minute grid, which cannot express a
    /// 5- or 10-minute ceiling at all.)
    ///
    /// It starts at 5 and not at 0: zero is a permanent close by rule with no
    /// costume and no lift — the Validator's `.setDoorCap` arm refuses it — and
    /// it is not reachable from any surface. It is deliberately NOT clamped to
    /// the current budget either: the sum of caps is unconstrained and a cap
    /// above the budget is legal, harmless, and the honest thing to store.
    public static let wheelTable = [5, 10, 15, 20, 30, 45, 60]              // minutes

    /// The seat strings, derived from the table rather than written beside it.
    /// Two hand-kept parallel lists is one edit away from a wheel that shows
    /// "20 min" and commits 30, and nothing in either suite would notice.
    ///
    /// The No-cap seat sits FIRST, above the numbers, so the minutes ascend
    /// downward exactly as the budget wheel's do and the first step down from
    /// No cap is the tightening one. It is the one seat in the product where a
    /// word is unavoidable: minutes cannot express absence, and a blank seat
    /// would be invisible *and* silent, since the wheel's accessibility value is
    /// its entire VoiceOver reading.
    public static let wheelValues: [String] =
        [SilkStrings.noCap] + wheelTable.map { "\($0) \(SilkStrings.minutes)" }

    /// The seat a stored ceiling opens on. Seat 0 is No cap; every other seat is
    /// one ahead of `wheelTable`, and a value said off the grid — the bar takes
    /// any integer — opens on its nearest seat.
    public static func wheelSeat(for cap: Int?) -> Int {
        guard let cap else { return 0 }
        return 1 + nearestIndex(to: cap, in: wheelTable)
    }

    /// The ceiling a committed seat means — nil at seat 0, because absence is
    /// not a number. Out-of-range clamps rather than traps: this index arrives
    /// from a scroll view's snap, and a crash is not the failure mode a wheel
    /// should have.
    public static func wheelMinutes(atSeat seat: Int) -> Int? {
        guard seat > 0, !wheelTable.isEmpty else { return nil }
        return wheelTable[min(seat - 1, wheelTable.count - 1)]
    }

    /// The seat an off-grid value opens on. Shared by every wheel in the app,
    /// not just this one — it lives here because the cap table is the only table
    /// with a home in the spine, and one copy is better than two.
    public static func nearestIndex(to value: Int, in table: [Int]) -> Int {
        table.indices.min { abs(table[$0] - value) < abs(table[$1] - value) } ?? 0
    }

    // MARK: - What the surfaces say

    /// A Settings door row's value: the door's own ceiling, or the wheel's
    /// No-cap seat when it has none, because the row must read back what the
    /// wheel would show.
    public static func settingsValue(cap: Int?) -> String {
        cap.map { "\($0) \(SilkStrings.minutes)" } ?? SilkStrings.noCap
    }

    /// The toast a cap change leaves behind — or nil when no ceiling moved and
    /// the caller's own receipt (the pool's balance) stands.
    ///
    /// What moved is derived by state diff, the same discipline polarity is held
    /// to, and the DOORS are iterated rather than the dictionary because
    /// `doorCaps`' order is nondeterministic across launches.
    ///
    /// **The live grant outranks the ceiling, and that ordering is the whole
    /// point.** `state(of:)` puts a running grant ahead of cap exhaustion (§2.6
    /// rule 1) and the Validator's `.spend` arm does the same (§4.2 Correction
    /// 2), for the same reason: the wall really is down, `openDoors` holds the
    /// door, the row draws `· till 10:30` and the bar answers `.restated`. A
    /// receipt that said "closed until 7:00" in that second would be the fourth
    /// surface, contradicting the other three, and it would be the only one the
    /// user is actually shown. So the closed sentence is spoken only when the
    /// ceiling is what shuts the door *right now*; otherwise the receipt names
    /// the ceiling, which is what actually moved and what the door will hold
    /// from the next ask.
    public static func receipt(for proposed: PolicyState, movedFrom previous: PolicyState,
                               ledger: GrantLedger, now: Date, dayStart: Date,
                               calendar: Calendar = .current) -> String? {
        for door in previous.doors where proposed.doorCaps[door.id] != previous.doorCaps[door.id] {
            // A key that went absent is not a ceiling to read back. Two ways to
            // get here and neither wants a cap sentence: a cap CLEARED is a
            // loosening, so it parks and the caller answers "Applies tomorrow."
            // before any receipt is composed; and a door REMOVED takes its cap
            // with it, where what actually moved is the door list.
            guard let cap = proposed.doorCaps[door.id] else { return nil }
            if ledger.activeGrant(for: door, at: now) == nil,
               ledger.remainingMinutes(cap: cap, doorID: door.id, dayStart: dayStart,
                                       calendar: calendar) <= 0 {
                // The honest sentence when the new ceiling has already bitten:
                // the door is shut, and the hour it lifts is tomorrow's.
                let t = Validator.timeOfDay(DayBoundary.nextDayStart(after: dayStart,
                                                                     calendar: calendar),
                                            calendar: calendar)
                return SilkStrings.closedUntil(door.name, until: t)
            }
            // `settingsBudget`'s own composition, so the reply reads back what
            // the Settings row is about to show.
            return "\(door.name) \(cap) \(SilkStrings.minutes) \u{00B7} \(SilkStrings.perDay)."
        }
        return nil
    }

    /// What a parked ceiling change will deliver for ONE door — the value alone,
    /// because every surface that says it has already named the door: the detail
    /// card is titled with it, and the pending row prefixes it below. nil when
    /// this door's ceiling is not what the merge will move.
    ///
    /// The value is the row's, not the wheel's: bare minutes and a lowercased
    /// "no cap". `settingsValue` says "20 min" and "No cap" because it is read
    /// as a standing rule under a label; this is read after "Tomorrow:" or after
    /// a door's name, mid-sentence, where the unit is redundant and a capital is
    /// wrong — the same reason `till` is lowercased in the row's serif slot.
    public static func pendingValue(next: PolicyState, live: PolicyState,
                                    door: Door) -> String? {
        guard next.doorCaps[door.id] != live.doorCaps[door.id] else { return nil }
        // Minutes cannot express absence, so the wheel's own first seat says it.
        guard let cap = next.doorCaps[door.id] else {
            return SilkStrings.noCap.lowercased()                          // "no cap"
        }
        return "\(cap)"                                                    // "20"
    }

    /// The pending row's line for a parked cap change — or nil when no ceiling
    /// is what the merge will deliver.
    ///
    /// `live.doors` is iterated, never the dictionary: order must be
    /// deterministic across launches, and going through the door list handles a
    /// removed door for free — its key is unreachable, the summary falls to nil,
    /// and the row and its "Apply now." button correctly disappear.
    ///
    /// Composed FROM `pendingValue` rather than beside it, so the card ("no cap")
    /// and the row ("TikTok no cap") and the Settings toast ("Tomorrow: TikTok no
    /// cap") cannot drift into three renderings of one waiting fact.
    public static func pendingSummary(next: PolicyState, live: PolicyState) -> String? {
        for door in live.doors {
            guard let value = pendingValue(next: next, live: live, door: door) else { continue }
            return "\(door.name) \(value)"                    // "TikTok no cap" / "TikTok 20"
        }
        return nil
    }

    /// The cap half of a tighten's undo: put back every ceiling *this turn*
    /// moved, and nothing else.
    ///
    /// Per key, for the same reason the budget and window clauses are per field.
    /// The undo window runs up to five minutes with Settings usable underneath,
    /// so a wholesale `caps = previous` would erase a ceiling set on a different
    /// door in between — an instant loosening she never asked for, from a
    /// control that promises to undo one turn. The union of both key sets, so a
    /// cap the proposal CLEARED is restored too; assigning the nil-bearing
    /// subscript removes the key, which is the correct inverse.
    ///
    /// AND ONLY WHERE THE TURN'S OWN VALUE IS STILL STANDING. Naming a
    /// different door was never the only way another hand could get in — a
    /// later turn can move the SAME door, and then this offer is putting back a
    /// value nobody is looking at. Say "cap tiktok at 20", then inside the
    /// window "cap tiktok at 10": undoing the first wrote 20 over the live 10,
    /// which is a LOOSENING applied instantly, out of a control that promises
    /// to undo one turn — and it destroyed the second turn's tighten while that
    /// turn's own pill still stood claiming it could put back 20. Comparing
    /// against the live map is the whole rule: an offer whose value has been
    /// overwritten since has nothing of its own left to restore.
    ///
    /// `changed` is that answer, and the caller needs it rather than merely
    /// wanting it: an undo reports whether the restore landed, and "Put back."
    /// may only be written over one that did. Receipts never lie.
    public static func restoring(_ previous: [UUID: Int], over proposed: [UUID: Int],
                                 into caps: [UUID: Int]) -> (caps: [UUID: Int], changed: Bool) {
        var caps = caps
        var changed = false
        for id in Set(previous.keys).union(proposed.keys)
        where previous[id] != proposed[id] && caps[id] == proposed[id] {
            caps[id] = previous[id]
            changed = true
        }
        return (caps, changed)
    }
}
