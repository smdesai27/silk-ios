import Foundation

/// Tighten vs loosen is NEVER parsed from words. It is a pure function of two
/// states under a total order on strictness. Silk's own example sentences flip
/// under the same verb shape — "add Reddit" loosens (a new door), "block
/// YouTube too" tightens (a bigger wall) — so any verb-keyed classifier will
/// eventually invert one, and a flipped loosen silently weakens the wall.
/// (docs/market/language-layer.md §7)
public enum Polarity: Equatable, Sendable {
    case tighten     // applies instantly, from anywhere
    case loosen      // applies tomorrow, unless the key is tapped
    case unchanged
}

public enum PolarityEngine {

    /// Compare a proposed policy against the current one.
    /// Any loosening dimension makes the whole change a loosening — the
    /// conservative reading, because loosening is the guarded path.
    public static func classify(current: PolicyState, proposed: PolicyState) -> Polarity {
        var loosens = false
        var tightens = false

        // Budget: fewer minutes is tighter.
        if proposed.budgetMinutes < current.budgetMinutes { tightens = true }
        if proposed.budgetMinutes > current.budgetMinutes { loosens = true }

        // Night window: which minutes it blocks, not how many. Length cannot
        // see position, so moving 22:00–07:00 to 23:00–08:30 read as a pure
        // tighten — half an hour longer — and landed instantly, handing the
        // ten o'clock hour back the same evening.
        if !proposed.downHours.covers(current.downHours) { loosens = true }
        if !current.downHours.covers(proposed.downHours) { tightens = true }

        // Doors: a door is a permission to ask. Fewer doors is tighter.
        if proposed.doors.count < current.doors.count { tightens = true }
        if proposed.doors.count > current.doors.count { loosens = true }

        // The wall itself: turning it off is the ultimate loosening.
        if current.wallEnabled && !proposed.wallEnabled { loosens = true }
        if !current.wallEnabled && proposed.wallEnabled { tightens = true }

        // Per-door ceilings. Absent is not zero, it is infinity — a door with no
        // cap has no ceiling — so both sides read through `?? Int.max`.
        //
        // Doors present in BOTH states, and never the union of the dictionary's
        // keys. `proposedState(.removeDoor)` drops the leaving door's cap, so a
        // key-set comparison would read the removal of a capped door as "a
        // ceiling went to infinity" = loosens, the conservative merge below
        // would return .loosen for the whole proposal, and "drop tiktok" — the
        // most tightening thing a user can say — would answer "Applies
        // tomorrow." while TikTok stayed a door all day. It would also flip
        // `isTighten` false, so at night the removal would be answered with the
        // opening hour and lost entirely. The doors.count rule already speaks
        // for every add and every removal; caps must not speak for them twice.
        //
        // RAW caps, never an effective min(cap, budgetMinutes). The effective
        // form looks more truthful and fails silently: with a budget of 30 and
        // TikTok capped at 40, raising the cap 40 → 60 leaves min(cap, budget)
        // at 30 both sides, classify returns .unchanged, `settle`'s
        // `proposed != policy` guard does NOT catch it because doorCaps really
        // did change, and `enact`'s .unchanged branch returns a receipt without
        // ever assigning `policy`. The wheel closes, a toast reads the balance,
        // and the edit is thrown away — to be discovered months later when the
        // budget rises and the door is still capped at 40. The budget dimension
        // already accounts for every effective-ceiling movement the budget
        // causes; comparing effective ceilings double-counts it and lets a
        // budget cut and a cap raise cancel inside one proposal.
        let shared = Set(current.doors.map(\.id)).intersection(proposed.doors.map(\.id))
        for id in shared {
            let before = current.doorCaps[id] ?? Int.max
            let after  = proposed.doorCaps[id] ?? Int.max
            if after < before { tightens = true }
            if after > before { loosens = true }
        }

        if loosens { return .loosen }        // conservative: mixed → loosen path
        if tightens { return .tighten }
        return .unchanged
    }

    /// Apply a rule-change command to a state, producing the proposed state.
    /// Spending is not a rule change — a grant is a debit, not a parameter.
    ///
    /// **This is where a parsed number becomes policy, so this is where it is
    /// bounded.** Every command carrying minutes goes through
    /// `PolicyState.clampedDaily`, and the two that do are the two the grammar
    /// can write an arbitrary integer into: the pool and a door's ceiling.
    /// Nothing further down the pipe checks magnitude — `Validator`'s
    /// provenance guards ask where a number came from and never how big it is,
    /// and `classify` is a pure comparison — so a bound applied anywhere else
    /// would be one the next surface forgets. Applied here it covers the
    /// grammar, the widener and every wheel at once, because all of them reach
    /// the policy through this function.
    public static func proposedState(applying command: Command, to state: PolicyState) -> PolicyState? {
        var s = state
        switch command {
        case .setBudget(let m):
            s.budgetMinutes = PolicyState.clampedDaily(m)
        case .setDownHoursStart(let t):
            s.downHours.start = t
        case .setDownHoursEnd(let t):
            s.downHours.end = t
        case .addDoor(let name):
            s.doors.append(Door(name: name))
        case .removeDoor(let door):
            s.doors.removeAll { $0.id == door.id }
            // The cap goes with the door. Anything keyed by door id outlives the
            // door otherwise, can never be revived (a re-added door gets a fresh
            // UUID) and can never be removed. This is what makes classify's
            // "present in both" restriction mandatory rather than merely wise.
            s.doorCaps.removeValue(forKey: door.id)
        case .setDoorCap(let door, let minutes):
            // nil removes the key: the cap is cleared. A number is bounded to
            // the day like the pool is — a ceiling of 10^18 is not a lid, and
            // it is `Int.max` in every comparison `classify` makes anyway.
            s.doorCaps[door.id] = minutes.map(PolicyState.clampedDaily)
        case .spend, .placeBoundAsk, .closeDoorToday, .closeAllToday, .status, .downHoursQuery:
            return nil  // not rule changes
        }
        return s
    }
}
