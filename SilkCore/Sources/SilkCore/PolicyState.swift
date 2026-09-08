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
    /// The display name, user-chosen from the catalogue. A `let`: a door is
    /// never renamed, only replaced (`DoorRoster`, the editor's rebind), and
    /// a stored `var` with an observer was a write path nothing wrote through.
    public let name: String
    /// The name lowercased, kept rather than computed. `door(named:)` is
    /// asked once per token and once per bigram of every sentence, and each
    /// ask used to lowercase every door's name again: `String.lowercased()`
    /// was the single largest symbol left in the parser's profile once the
    /// grammar itself had been made cheap. Derived from `name` in both
    /// initializers, never encoded — an older blob without it decodes the same.
    public let key: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.key = name.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        key = name.lowercased()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
    }

    /// The door's spoken form, lowercased: **its name and nothing else**.
    ///
    /// It used to be a union — the name, a per-user `aliases` table, and the
    /// launch catalogue's own nicknames ("ig", "insta", "yt", "the gram").
    /// Every one of those is gone, and the reason is the spend grammar above
    /// it. A nickname is only ever read by `DeterministicParser.door(_:in:)`,
    /// which asks "did this sentence name a door" of every token of arbitrary
    /// prose; a short nickname answers yes far more often than the user meant
    /// one ("20 minutes ig", "im about to snap"), and the catalogue's own
    /// comment already records three exclusions it had to make for exactly
    /// that. With the bare shortcut form no longer granting, the nicknames
    /// bought nothing but the hijacks: what a nickname now reaches is a
    /// "Write it out:" hint on a door the sentence may never have meant.
    ///
    /// `aliases` is gone as a STORED property too, and nothing migrates: a
    /// blob written by an older build still carries an `aliases` key, and the
    /// synthesized decoder ignores keys it has no property for. A door that
    /// answered to "ig" yesterday answers to "Instagram" today.
    ///
    /// An array rather than a String because `door(named:)` and
    /// `DoorRoster.canAdd` both ask "does this door answer to this word", and
    /// the shape of that question is a membership test.
    public var spokenForms: [String] { [key] }
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
    /// One daily allowance for all distraction. Never past a day: the setter
    /// clamps, so no writer — a parse, a wheel, a decode, a migration — can
    /// hold a number `Validator` would refuse (see `maxMinutesPerDay`).
    public var budgetMinutes: Int {
        didSet { budgetMinutes = Self.clampedDaily(budgetMinutes) }
    }
    public var downHours: DownHours        // one night window
    public var doors: [Door]               // 3–6 named doors
    public var wallEnabled: Bool           // the categories behind the wall (tokens live outside Core)
    /// doorID → the most minutes of the shared budget that door may draw in a
    /// Silk day. A ceiling on the one pool, not an allowance out of it: the sum
    /// is unconstrained, and an absent entry is no ceiling at all rather than a
    /// ceiling of zero. Keyed by id and not by name because a name can be
    /// re-added and a cap must not re-attach to a door the user never capped.
    ///
    /// Here rather than on `Door` because `maturing` takes the door list live
    /// and never merges it: a cap stored on a `Door` could never mature a parked
    /// loosening, and would be dropped on the floor by the one code path that
    /// exists to deliver it. Inside `PolicyState` it also rides inside
    /// `silk.policy`, so `wipeAll` needs no new entry and no extension can strip
    /// it. Splitting it into a sibling App Group key would reintroduce both.
    public var doorCaps: [UUID: Int] {
        didSet { doorCaps = doorCaps.mapValues(Self.clampedDaily) }
    }

    // MARK: - The day's ceiling
    //
    // ONE constant, and every daily minute number in the policy is measured
    // against it: the pool, and every per-door ceiling. Both are counted against
    // a Silk day and both refill at its boundary, so a number larger than the
    // day cannot mean what it says — there is no day for the 1441st minute to
    // be spent in.

    /// The most minutes any daily number in this policy may mean: one day.
    ///
    /// A parsed number is unbounded, and nothing downstream bounded it. The
    /// reader takes an eighteen-digit literal straight through `Int(tok)`
    /// (`NumberParser.allNumbers`), and its hours multiplier already saturates
    /// at `Int.max` rather than trapping (`NumberParser.saturating`) — so
    /// "budget 999999999999999999" compiled, passed provenance, and parked as
    /// an ordinary loosening. Once applied, `Validator`'s `.spend` arm clamped
    /// the ask to a pool of 10^18 and computed `asked * 60`, which is not an
    /// `Int`: "instagram 999999999999999999" was a SIGTRAP in the bar, reachable
    /// in two sentences from a clean install. The clamp is the fix; the
    /// validator's `Double` multiply is the belt behind it, because a policy can
    /// also arrive from a stored blob this function never touched.
    public static let maxMinutesPerDay = 1440

    /// A daily minute count as this policy is willing to hold it.
    ///
    /// CLAMPED, NOT REFUSED, and the precedent is P4: a duration that overruns
    /// the pool is not an error, it is bounded to what she can actually have,
    /// and the read-back then states the bounded number ("Requested durations
    /// clamp to the minutes actually remaining"). A budget of a billion is the
    /// same sentence one order of absurdity further out, and answering it with
    /// "Didn't get that." would teach nothing about why. So "budget
    /// 999999999999999999" parks as `Tomorrow: 1440` — a day, named — and the
    /// user can see exactly what she is getting.
    ///
    /// The floor is here for symmetry rather than for a live path: no parser
    /// produces a negative, and a stored negative budget would already read as
    /// an empty pool through `remainingMinutes`' own `max(0, …)`.
    public static func clampedDaily(_ minutes: Int) -> Int {
        min(max(0, minutes), maxMinutesPerDay)
    }

    /// `doorCaps` goes last and carries a default, so every call site that
    /// predates caps keeps compiling — a door with no entry is simply uncapped,
    /// which is what those call sites already mean.
    public init(budgetMinutes: Int, downHours: DownHours, doors: [Door],
                wallEnabled: Bool = true, doorCaps: [UUID: Int] = [:]) {
        // RAW on purpose — the one door the ceiling does not guard. Observers
        // do not fire in an initializer, the decoder clamps for itself, and
        // every live writer goes through a setter or the decoder; this init
        // is how a test hands the validator a state past the ceiling and
        // proves its `Double` multiply is a real belt and not dead code.
        self.budgetMinutes = budgetMinutes
        self.downHours = downHours
        self.doors = doors
        self.wallEnabled = wallEnabled
        self.doorCaps = doorCaps
    }

    /// `doorCaps` postdates the first persisted policies, so it decodes as
    /// optional; synthesized `encode(to:)` still writes all five keys, so the
    /// blob self-heals on the first save.
    ///
    /// Mandatory, and not a nicety: a synthesized decode throws
    /// `keyNotFound("doorCaps")` on a payload written before the field even
    /// though the property has a default value. `SharedStore.decode` swallows
    /// that throw, `loadPolicy` returns nil, and the user re-onboards with her
    /// budget, doors, night window and wall gone. The same throw reaches the
    /// pending and the baseline, and this one init covers all three keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Clamped on the way in, so a blob written before the ceiling existed
        // (or one hand-corrupted) reads back as the same day the bar enforces:
        // every surface that draws the budget draws the number `Validator`
        // will honour, and the hero cannot show a figure the bar refuses.
        budgetMinutes = Self.clampedDaily(try c.decode(Int.self, forKey: .budgetMinutes))
        downHours     = try c.decode(DownHours.self, forKey: .downHours)
        doors         = try c.decode([Door].self, forKey: .doors)
        wallEnabled   = try c.decode(Bool.self, forKey: .wallEnabled)
        // `decodeIfPresent` maps an absent key and a JSON null to no caps, and
        // still throws on a present-but-malformed value — so this is a
        // migration and not a blanket catch.
        doorCaps      = (try c.decodeIfPresent([UUID: Int].self, forKey: .doorCaps) ?? [:])
            .mapValues(Self.clampedDaily)
    }

    public func door(named utteranceToken: String) -> Door? {
        let t = utteranceToken.lowercased()
        return doors.first { $0.key == t }
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
    /// actually have *proposed* it — a snapshot carries every field, but a
    /// sentence moves one — and the live value must still be sitting where the
    /// pending left it. `baseline` is the policy the pending was measured
    /// against; if the live value has since left the baseline then a later hand
    /// moved it, and the later hand wins. That is the whole rule, and it is
    /// symmetric: it declines to revert a tightening and equally declines to
    /// re-apply a loosening the user has already been granted by other means.
    ///
    /// "One field" is where `doorCaps` parts company with the three scalars. A
    /// dictionary is not a fourth scalar, it is a family of fields keyed by
    /// door, so the merge unit there is the key and the rule above is applied
    /// once per key rather than once to the whole map — see the loop.
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
        // A dictionary field is not a fourth scalar — it is N independent
        // fields keyed by door, and the merge unit is therefore the key, not
        // the field. Merging wholesale lets a cap set on an unrelated door
        // between the parking and the boundary cancel the whole thing, and the
        // loss is invisible before it happens and unrecoverable after.
        //
        // The union of the pending's and the baseline's keys, and only those: a
        // key present in neither was proposed by nobody, and a matured "No cap"
        // is a key in the baseline that is absent from the pending, which the
        // union is the only way to reach. Assigning the nil-bearing subscript
        // removes the key, which is exactly the matured clearing.
        //
        // The live-door guard is a filter, never a prune. `maturing` must stay a
        // pure merge: `keyTapped` guards on `next != policy` to keep the scarce,
        // journalled key from being burned on a no-op, and a merge that also
        // tidied orphans would make `next` differ from live when nothing
        // matured, spending the key — and destroying the pending — to delete a
        // dictionary entry nobody can see. Pruning belongs where a door
        // actually leaves — `proposedState(.removeDoor)` is one such place — so
        // the live policy is canonical here and this loop only has to decline
        // to resurrect an entry, never to delete one.
        let liveDoorIDs = Set(doors.map(\.id))
        for id in Set(pending.doorCaps.keys).union(baseline.doorCaps.keys)
        where liveDoorIDs.contains(id)
              && pending.doorCaps[id] != baseline.doorCaps[id]
              && doorCaps[id] == baseline.doorCaps[id] {
            next.doorCaps[id] = pending.doorCaps[id]
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
