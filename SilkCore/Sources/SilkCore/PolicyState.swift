import Foundation

/// A minute-of-day, 0..<1440. Down hours are wall-clock local by decision
/// (docs/market/gaps.md #10); grants expire at absolute instants.
public struct TimeOfDay: Hashable, Codable, Sendable, Comparable {
    public let minutes: Int  // since midnight

    public init(hour: Int, minute: Int = 0) {
        self.minutes = ((hour * 60 + minute) % 1440 + 1440) % 1440
    }

    public init(minutesSinceMidnight: Int) {
        self.minutes = ((minutesSinceMidnight % 1440) + 1440) % 1440
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutes < rhs.minutes }

    /// "5:00", "10:30" — 12-hour, no am/pm; the surrounding sentence carries context.
    public var display: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", h12, minute)
    }
}

/// A door: a named app the user may ask for. The name is simultaneously the
/// voice vocabulary, the launch mapping, and the web-domain block.
public struct Door: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String          // display name, user-chosen from the catalogue
    public var aliases: [String]     // learned shorthand (the alias table)

    public init(id: UUID = UUID(), name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }

    /// All spoken forms, lowercased, for matching.
    public var spokenForms: [String] { ([name] + aliases).map { $0.lowercased() } }
}

/// The night window. May cross midnight (22:00 → 7:00).
public struct DownHours: Hashable, Codable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    /// Whether `t` falls inside the window.
    public func contains(_ t: TimeOfDay) -> Bool {
        if start.minutes <= end.minutes {
            return t.minutes >= start.minutes && t.minutes < end.minutes
        }
        // crosses midnight
        return t.minutes >= start.minutes || t.minutes < end.minutes
    }

    /// Window length in minutes.
    public var length: Int {
        ((end.minutes - start.minutes) % 1440 + 1440) % 1440
    }

    /// Whether this window blocks every minute `other` blocks. A window is an
    /// arc on a 24-hour circle, so what it costs the user is the set of those
    /// minutes and not the count of them, which is why polarity asks this and
    /// not `length`. A zero-length window blocks nothing and so is covered by
    /// every window, including another zero-length one elsewhere, which makes
    /// mutual coverage mean "blocks the same minutes", not "is the same window".
    public func covers(_ other: DownHours) -> Bool {
        if other.length == 0 { return true }
        let offset = TimeOfDay(minutesSinceMidnight: other.start.minutes - start.minutes)
        return offset.minutes + other.length <= length
    }
}

/// The whole of Silk's policy. Small on purpose: if it doesn't fit here,
/// Silk doesn't do it.
public struct PolicyState: Hashable, Codable, Sendable {
    public var budgetMinutes: Int          // one daily allowance for all distraction
    public var downHours: DownHours        // one night window
    public var doors: [Door]               // 3–6 named doors
    public var wallEnabled: Bool           // the categories behind the wall (tokens live outside Core)

    public init(budgetMinutes: Int, downHours: DownHours, doors: [Door], wallEnabled: Bool = true) {
        self.budgetMinutes = budgetMinutes
        self.downHours = downHours
        self.doors = doors
        self.wallEnabled = wallEnabled
    }

    public func door(named utteranceToken: String) -> Door? {
        let t = utteranceToken.lowercased()
        return doors.first { $0.spokenForms.contains(t) }
    }

    /// What a parked loosening becomes when its day finally turns.
    ///
    /// A pending is a whole-policy snapshot taken when the sentence was said,
    /// and the policy keeps moving under it: tightening is instant, and
    /// Settings edits doors now. Assigning that snapshot wholesale at maturity
    /// reverts whatever was tightened since it was parked — the loosening wins
    /// by outliving the tightening, which is rule 3 exactly backwards. So the
    /// snapshot is merged, field by field, and never assigned.
    ///
    /// A field matures on two conditions, and needs both. The pending must
    /// actually have *proposed* it — a snapshot carries all four fields, but a
    /// sentence moves one — and the live value must still be sitting where the
    /// pending left it. `baseline` is the policy the pending was measured
    /// against; if the live value has since left the baseline then a later hand
    /// moved it, and the later hand wins. That is the whole rule, and it is
    /// symmetric: it declines to revert a tightening and equally declines to
    /// re-apply a loosening the user has already been granted by other means.
    ///
    /// Doors are never merged. They are taken live, always, because no
    /// loosening can change the door list — an add asked for at the bar is
    /// refused, and a removal never waits — so the live list is the only truth
    /// there is. Restoring a snapshot's doors would drop a door bound in
    /// Settings since, taking its app off the wall with it, or bring a dropped
    /// door back with no selection left to except it.
    ///
    /// A `nil` baseline matures nothing. It means a pending was persisted by a
    /// build that stored no baseline, and there is no way to tell what it
    /// proposed — every field of the snapshot is equally suspect. Backfilling
    /// the live policy as the baseline is the tempting repair and the wrong
    /// one: it makes `live == baseline` true for every field by construction,
    /// which collapses the rule to "assign whatever the pending differs from
    /// live on" — the wholesale revert this exists to prevent, arriving one
    /// boundary later. Returning `self` errs the only safe way, and the caller
    /// drops the pending rather than honouring it blind.
    public func maturing(_ pending: PolicyState, parkedAgainst baseline: PolicyState?) -> PolicyState {
        guard let baseline else { return self }
        var next = self  // live, so the door list comes forward untouched
        if pending.budgetMinutes != baseline.budgetMinutes,
           budgetMinutes == baseline.budgetMinutes {
            next.budgetMinutes = pending.budgetMinutes
        }
        if pending.downHours != baseline.downHours,
           downHours == baseline.downHours {
            next.downHours = pending.downHours
        }
        if pending.wallEnabled != baseline.wallEnabled,
           wallEnabled == baseline.wallEnabled {
            next.wallEnabled = pending.wallEnabled
        }
        return next
    }

    /// The entries of a door-keyed store this policy still owns. Anything keyed
    /// by door id outlives the door, and the wall unions every stored app
    /// selection with no policy filter — so one left behind shields its app
    /// with no row, no grant path and no Settings entry, and only a wipe clears
    /// it. Generic over the value so FamilyControls stays in the app layer and
    /// the rule is provable from `swift test`.
    public func owned<Value>(_ store: [UUID: Value]) -> [UUID: Value] {
        let live = Set(doors.map(\.id))
        return store.filter { live.contains($0.key) }
    }
}
