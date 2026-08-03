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

        // Night window: longer is tighter.
        if proposed.downHours.length > current.downHours.length { tightens = true }
        if proposed.downHours.length < current.downHours.length { loosens = true }

        // Doors: a door is a permission to ask. Fewer doors is tighter.
        if proposed.doors.count < current.doors.count { tightens = true }
        if proposed.doors.count > current.doors.count { loosens = true }

        // The wall itself: turning it off is the ultimate loosening.
        if current.wallEnabled && !proposed.wallEnabled { loosens = true }
        if !current.wallEnabled && proposed.wallEnabled { tightens = true }

        if loosens { return .loosen }        // conservative: mixed → loosen path
        if tightens { return .tighten }
        return .unchanged
    }

    /// Apply a rule-change command to a state, producing the proposed state.
    /// Spending is not a rule change — a grant is a debit, not a parameter.
    public static func proposedState(applying command: Command, to state: PolicyState) -> PolicyState? {
        var s = state
        switch command {
        case .setBudget(let m):
            s.budgetMinutes = m
        case .setDownHoursStart(let t):
            s.downHours.start = t
        case .setDownHoursEnd(let t):
            s.downHours.end = t
        case .addDoor(let name):
            s.doors.append(Door(name: name))
        case .removeDoor(let door):
            s.doors.removeAll { $0.id == door.id }
        case .spend, .placeBoundAsk, .closeDoorToday, .closeAllToday, .status, .downHoursQuery:
            return nil  // not rule changes
        }
        return s
    }
}
