import Foundation

/// The day record and the walk that produces it.
///
/// Pure — no FamilyControls, no `SharedStore` — so the whole mechanic is
/// testable from `swift test` the way `GrantLedger` is. Everything the wall
/// knows and Core cannot see arrives as the `wallStanding` argument.
///
/// Why records and not a running total: an `Int` incremented from two
/// processes silently drops increments, and Silk writes from the app and from
/// `SpendIntent`. Records are idempotent by `dayStart`, so a lost write can
/// lose a day but can never corrupt one.
///
/// See `docs/design/mirror-continuity.md` §2–§3.

// MARK: - The record

/// One closed Silk day, summarised once and never revised.
public struct DayRecord: Codable, Hashable, Sendable {
    /// Identity — the Silk day this summarises. Day starts when down hours
    /// end, not at midnight (`DayBoundary.dayStart`).
    public let dayStart: Date
    /// The union, in minutes, of every grant interval clipped to this day.
    public let grantedMinutes: Int
    /// Distinct reaches inside the day. `recordAttempt` already dedupes at
    /// 60 s, so this is per reach, not per shield render.
    public let reaches: Int
    /// Those reaches falling inside the down-hours window.
    public let lateReaches: Int
    /// Purchases, not sessions — how many grants were issued inside the day.
    ///
    /// The name the evidence supports is `switchCost`'s `S`, and it counts
    /// what `Validator` records: a top-up asked for *inside* a live grant
    /// returns `.restated` and writes nothing, so someone who takes 60 minutes
    /// at 09:00 and re-opens fifteen times has one unlock here. What this
    /// prices is repeat *buying* after a window closes, which is the shape of
    /// "five more, five more, five more" — and it is honestly less than the
    /// whole of what fragmentation feels like. score-weighting §4.2.
    ///
    /// Zero on a record written before this field existed. That decodes to the
    /// same score those days already had, because the term is zero below two.
    public let unlocks: Int
    /// The wall stood and Silk could see it. Decided at write time and never
    /// revised — an unobserved day credits nothing, charges nothing, and
    /// draws a ring.
    public let observed: Bool

    public init(dayStart: Date, grantedMinutes: Int, reaches: Int,
                lateReaches: Int, unlocks: Int = 0, observed: Bool) {
        self.dayStart = dayStart
        self.grantedMinutes = grantedMinutes
        self.reaches = reaches
        self.lateReaches = lateReaches
        self.unlocks = unlocks
        self.observed = observed
    }

    /// `unlocks` postdates the first persisted records, so it decodes as
    /// optional — the same accommodation `GrantLedger.closedUntil` makes, and
    /// for the same reason: a record written once is never revised, so an old
    /// one must still decode rather than be rewritten. The synthesized
    /// `encode(to:)` still writes all six keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayStart = try c.decode(Date.self, forKey: .dayStart)
        grantedMinutes = try c.decode(Int.self, forKey: .grantedMinutes)
        reaches = try c.decode(Int.self, forKey: .reaches)
        lateReaches = try c.decode(Int.self, forKey: .lateReaches)
        unlocks = try c.decodeIfPresent(Int.self, forKey: .unlocks) ?? 0
        observed = try c.decode(Bool.self, forKey: .observed)
    }

    /// The day's contribution. Frozen arithmetic over frozen fields: a record
    /// written once can never be recomputed into a different number, which is
    /// what makes the hero monotone rather than merely "usually rising".
    public var fraction: Double {
        guard observed else { return 0 }
        let cost = Double(grantedMinutes + reaches + lateReaches)
            + DayLog.fragmentation(unlocks: unlocks, grantedMinutes: grantedMinutes)
        return max(0, 1 - cost / DayLog.allowance)
    }

    /// The day on Mirror's 0–100 scale: `fraction`, written as the number the
    /// hero draws. One rounding, defined here, so the hero and the week band
    /// can never disagree with the record by a point.
    public var score: Int { Int((fraction * 100).rounded()) }
}

// MARK: - The log

public enum DayLog {
    /// The day's allowance, in points, declared before the day starts rather
    /// than granted after it goes wrong. A granted minute costs one; a reach
    /// costs one; a reach inside down hours costs one more — the coefficients
    /// the shipped score already uses. 180 is the one number here that is not
    /// derived from anything; see mirror-continuity §8.5. Provisional until
    /// calibrated against a real device day.
    public static let allowance: Double = 180

    /// `switchCost`'s `c` — equivalent minutes charged per grant after the
    /// first. score-weighting §4.4, and that section is worth reading before
    /// touching this number: **it is a calibration constant, not an effect
    /// size, and no citation supports it.** The direct experimental test of
    /// the premise is null (Powers & Scerbo 2023: interruption *frequency* had
    /// no effect once timing was held), and consolidation carries a measured
    /// cost of its own (Fitz et al. 2019: batching lifted FoMO, d = 0.68).
    /// It ships because taking fifteen minutes as 5 + 5 + 5 is a different day
    /// from taking it once and the score could not previously tell them apart
    /// — not because the literature priced it.
    public static let switchCost: Double = 2

    /// The switch term's ceiling, as a share of the day's granted minutes.
    /// §4.4 sets it against *weighted* minutes; with no time-of-day curve
    /// shipped every multiplier is 1.0, so the two are the same number here.
    public static let switchCap: Double = 0.5

    /// What fragmentation costs: `c` per grant after the first, never more
    /// than half the minutes those grants bought.
    ///
    /// The cap is what stops a thin, choppy day from being all switch term —
    /// four two-minute grants would otherwise cost three times what they
    /// bought. It binds only below ~28 granted minutes; above that the term is
    /// flat in the session count, which is the shape §4.4 asks for.
    ///
    /// **What does not transfer from §4.4.** That section derives its form
    /// inside `score = 100 × M / W`, where the cap yields a structural floor —
    /// fragmentation alone can never take a score below 66.7. Silk scores by
    /// subtraction from an allowance (`growth-decision` verdict 3), so the
    /// floor is a property of the ratio form and is *not* inherited here. What
    /// survives is the ordering the floor existed to encode: the switch term
    /// is bounded against the minutes, so fragmentation can add at most half
    /// again to what the grants already cost, and can never be the whole of a
    /// day's number. Stated rather than quietly assumed.
    public static func fragmentation(unlocks: Int, grantedMinutes: Int) -> Double {
        guard unlocks > 1 else { return 0 }
        return min(switchCost * Double(unlocks - 1),
                   switchCap * Double(grantedMinutes))
    }

    /// How many grants were issued inside the day — `switchCost`'s `S`.
    ///
    /// Clipped at both ends exactly as `grantedMinutes` clips windows: a grant
    /// minted under a transiently forward clock carries a future `issuedAt`,
    /// and an open-ended `issuedAt >= dayStart` counts that phantom again on
    /// every later day. `GrantLedger.unlocks(dayStart:)` is this same rule,
    /// reached from the live ledger.
    ///
    /// A count, where `grantedMinutes` is a union. Two doors opened at once is
    /// one minute the wall was down but two decisions to open it, and the
    /// asymmetry is deliberate — this term prices the asking.
    public static func unlocks(_ grants: [Grant], from dayStart: Date, to dayEnd: Date) -> Int {
        grants.filter { $0.issuedAt >= dayStart && $0.issuedAt < dayEnd }.count
    }

    /// Today's number before the day closes: the record's own equation, taken
    /// on the live counts. Defined beside `DayRecord.fraction` so the running
    /// hero and the record it becomes at the day's turn are one formula — the
    /// two can drift only by a coefficient change both would feel.
    ///
    /// `unlocks` defaults to zero, which is the same value an old record
    /// decodes to and costs the same nothing: the term is zero below two.
    public static func runningScore(grantedMinutes: Int, reaches: Int,
                                    lateReaches: Int, unlocks: Int = 0) -> Int {
        let cost = Double(grantedMinutes + reaches + lateReaches)
            + fragmentation(unlocks: unlocks, grantedMinutes: grantedMinutes)
        return Int((max(0, 1 - cost / allowance) * 100).rounded())
    }

    /// The cap `recordAttempt` enforces on the attempts blob. Mirrored here
    /// because §3.5's observability rule turns on the blob being *at* it.
    public static let attemptsCap = 2000

    /// How many attempts the render path's append buffer holds before it has
    /// to pay for a fold. Small on purpose: the shield encodes the whole tail
    /// on every reach, so the tail is the thing that must stay cheap, and 64
    /// is more reaches than a heavy day produces between two app foregrounds.
    public static let attemptsTailCap = 64

    /// The attempts blob as it stands once the render path's tail buffer is
    /// folded in — **the single definition of "the attempts", used both by the
    /// fold that writes it and by every reader that has not folded yet.**
    ///
    /// Why it lives in Core rather than beside the `UserDefaults` keys. The
    /// shield extension may not re-encode a 2000-entry `[Date]` on the path
    /// that draws the wall, so a reach is appended to a small tail key and the
    /// app folds it later. That split is only safe while a reader cannot tell
    /// the two states apart, and §3.5's observability rule is the reader that
    /// could: `summarise` calls a day unobservable when the blob is AT its cap
    /// and the day starts before the blob's oldest entry, so a merge that
    /// trimmed differently from the fold would move a day's verdict simply by
    /// virtue of when the app was last opened. One function, both callers, and
    /// the rule reads the same number either way.
    ///
    /// **Idempotent**, which is what makes the fold safe to lose a race:
    /// `UserDefaults` has no compare-and-swap, and two processes can fold the
    /// same tail (the app on foreground, the shield when the tail overflows).
    /// Entries the blob already carries are dropped, so a doubled fold cannot
    /// double-count a reach — the failure this would otherwise have is an
    /// inflated `reaches` term on a real day, which is a wrong verdict rather
    /// than a missing one.
    ///
    /// Order is preserved (blob first, then the tail in the order it was
    /// appended) and the cap is applied last, exactly as `recordAttempt` used
    /// to apply it.
    public static func foldedAttempts(blob: [Date], tail: [Date]) -> [Date] {
        guard !tail.isEmpty else { return capped(blob) }
        // Only the blob's own tail-length window can hold a doubled fold — a
        // fold appends to the end — so the membership set stays small rather
        // than being built over all 2000 entries on every read.
        let known = Set(blob.suffix(attemptsTailCap * 2))
        var out = blob
        out.append(contentsOf: tail.filter { !known.contains($0) })
        return capped(out)
    }

    private static func capped(_ attempts: [Date]) -> [Date] {
        guard attempts.count > attemptsCap else { return attempts }
        return Array(attempts.dropFirst(attempts.count - attemptsCap))
    }

    /// A Silk day shorter or longer than this is a boundary that moved under
    /// the user — a timezone change, not a day. It draws a ring rather than a
    /// fill, because `observed` has a span term even though `fraction` does
    /// not (§3.3).
    public static let sameSpan = (min: 20.0 * 3600, max: 28.0 * 3600)

    /// The largest backfill a single walk will emit. A 90-day absence is
    /// expected (§3.7); this exists so a boundary that has moved absurdly far
    /// cannot spin. It matches the record cap, so a walk can never produce
    /// more records than the store keeps.
    public static let maxWalk = 2000

    // MARK: Summarising one day

    /// Summarise one closed Silk day.
    ///
    /// `attempts` must be the **whole** blob, not a pre-filtered slice: §3.5
    /// decides observability partly from whether the blob is at its cap, and
    /// a slice cannot answer that. Filtering to the day happens here.
    ///
    /// `wallStanding` is the caller's verdict on the two facts Core cannot
    /// see — `policy.wallEnabled` and `WallController.standing == .up`. It is
    /// ANDed with the three this function *can* decide (span, attempts cap,
    /// heartbeat), so a caller cannot accidentally promote a day Core knows is
    /// unobservable.
    ///
    /// `heartbeats` are the instants the permanent daily schedule actually
    /// fired. `standing` only says the wall is *configured*; the Screen Time
    /// frameworks fail silently in the field for months, and a wall that is
    /// dead and never reached is otherwise indistinguishable from a wall that
    /// is alive and never reached — the day would score a perfect 1.000 while
    /// the product was dead. Requiring a heartbeat inside the day converts
    /// that from unfalsifiable to detected. It is the only liveness signal
    /// Silk has.
    public static func summarise(dayStart: Date,
                                 downHours: DownHours,
                                 grants: [Grant],
                                 attempts: [Date],
                                 heartbeats: [Date],
                                 wallStanding: Bool,
                                 calendar: Calendar = .current) -> DayRecord {
        let dayEnd = DayBoundary.nextDayStart(after: dayStart, calendar: calendar)

        let inDay = attempts.filter { $0 >= dayStart && $0 < dayEnd }
        let late = inDay.count { attempt in
            let c = calendar.dateComponents([.hour, .minute], from: attempt)
            return downHours.contains(TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0))
        }

        // The span term. A boundary that moved under the user produces a day
        // that is not a day; `fraction` would still be arithmetically fine,
        // which is exactly why the guard has to live on `observed`.
        let span = dayEnd.timeIntervalSince(dayStart)
        let sane = span >= sameSpan.min && span <= sameSpan.max

        // The blob is at its cap and this day starts before the oldest thing
        // in it, so the reach count would be a floor, not a count. A
        // fabricated fraction is worse than a ring.
        let truncated = attempts.count >= attemptsCap
            && (attempts.first.map { dayStart < $0 } ?? false)

        // The liveness term. The schedule is anchored at the day boundary, so
        // a day Silk was actually watching carries a firing at or just after
        // its start. No firing means the framework was not alive for this day,
        // whatever `standing` claims — and an unobserved day is a ring, so
        // this fails toward crediting nothing rather than crediting a dead
        // product at the maximum rate.
        let alive = heartbeats.contains { $0 >= dayStart && $0 < dayEnd }

        return DayRecord(dayStart: dayStart,
                         grantedMinutes: grantedMinutes(grants, from: dayStart, to: dayEnd),
                         reaches: inDay.count,
                         lateReaches: late,
                         unlocks: unlocks(grants, from: dayStart, to: dayEnd),
                         observed: wallStanding && sane && !truncated && alive)
    }

    /// The union, in minutes, of every grant interval `[issuedAt, expiresAt)`
    /// clipped to the day.
    ///
    /// **Union, not sum.** Two doors open at once is one minute the wall was
    /// down, not two — summing would charge a multi-door grant twice and make
    /// the cost depend on how the same span was sliced.
    ///
    /// Rounded to nearest rather than floored: a grant crossing a boundary is
    /// split in two, and flooring both halves loses up to a minute per
    /// crossing in a direction that always flatters the user.
    public static func grantedMinutes(_ grants: [Grant], from dayStart: Date, to dayEnd: Date) -> Int {
        let clipped: [(start: Date, end: Date)] = grants.compactMap { g in
            let s = max(g.issuedAt, dayStart)
            let e = min(g.expiresAt, dayEnd)
            return s < e ? (s, e) : nil
        }.sorted { $0.start < $1.start }

        var total: TimeInterval = 0
        var open: (start: Date, end: Date)?
        for interval in clipped {
            guard var current = open else { open = interval; continue }
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)   // overlap — extend
                open = current
            } else {
                total += current.end.timeIntervalSince(current.start)
                open = interval
            }
        }
        if let last = open { total += last.end.timeIntervalSince(last.start) }

        return Int((total / 60).rounded())
    }

    // MARK: The walk

    /// Every closed Silk day that has no record yet, oldest first.
    ///
    /// **No cursor.** `lastRecordedDayStart` is deliberately not stored: a
    /// cursor that advances past a write which did not land loses that day
    /// permanently, whereas this set-difference walk re-emits it on the next
    /// pass. That self-healing is what lets the compaction gate fail safe.
    ///
    /// `currentDayStart` is excluded — today is not closed and is never in
    /// the hero.
    ///
    /// Uses `DayBoundary.nextDayStart`, which adds a *calendar* day rather
    /// than 86 400 s, so a 23- or 25-hour Silk day is walked exactly once
    /// (pinned by `DSTNightTests`).
    ///
    /// **Bootstrapping.** With no records at all there is no anchor to walk
    /// from — §3.6 deletes `firstRun`, so nothing stamps the install. This
    /// emits the single day immediately before `currentDayStart` and lets the
    /// chain continue from there. On a real first run that day was not
    /// observed (the wall is not up during onboarding), so it writes a ring
    /// and the hero reads 0 on day 1, which is what §2.6 specifies. This is
    /// the one place the implementation had to decide something the document
    /// does not state.
    ///
    /// **Only fully-elapsed days are owed.** A boundary is emitted only when
    /// its `nextDayStart` is at or before `currentDayStart`. With a fixed
    /// boundary the two tests are the same test — but the records chain from
    /// the OLDEST record's time-of-day, while `currentDayStart` comes from the
    /// LIVE `policy.downHours`, and the moment the user moves when down hours
    /// end the two anchors disagree. `cursor < currentDayStart` alone would
    /// then summarise an old-anchored day two hours into itself, freezing a
    /// verdict over hours that have not happened yet ("summarised once, never
    /// revised" makes that permanent). Requiring the whole span to have
    /// elapsed keeps every written record honest; an old-anchored day is
    /// simply owed a little later, at the first sweep past its true end.
    ///
    /// **Future-dated records never anchor.** A record whose `dayStart` is at
    /// or past `currentDayStart` was written under a clock that has since
    /// gone backwards (or been corrected). Anchoring on it — or letting it
    /// satisfy the guard — would return an empty walk, and an empty walk
    /// green-lights compaction: real days would have their grants destroyed
    /// with no record ever written. Such records are ignored here entirely;
    /// with none in the past, the walk bootstraps as on a fresh install.
    public static func missingBoundaries(recorded: Set<Date>,
                                         upTo currentDayStart: Date,
                                         calendar: Calendar = .current) -> [Date] {
        let past = recorded.filter { $0 < currentDayStart }

        // Anchored on the OLDEST record, not the newest. Anchoring on the
        // newest would skip any gap behind it — which is a stored cursor
        // wearing a different hat, and loses exactly the day this walk exists
        // to recover.
        guard let anchor = past.min() else {
            let previous = calendar.date(byAdding: .day, value: -1, to: currentDayStart)
            return previous.map { [$0] } ?? []
        }

        var out: [Date] = []
        var cursor = DayBoundary.nextDayStart(after: anchor, calendar: calendar)
        while out.count < maxWalk {
            let next = DayBoundary.nextDayStart(after: cursor, calendar: calendar)
            guard next > cursor else { break }   // a boundary that cannot advance
            guard next <= currentDayStart else { break }   // day not fully closed
            if !past.contains(cursor) { out.append(cursor) }
            cursor = next
        }
        return out
    }

    /// Fold new records into the stored set, oldest first.
    ///
    /// **An existing record always wins.** `observed` is decided at write
    /// time and never revised, so a re-walk — which happens whenever a write
    /// fails to land and the set-difference walk re-emits the day — must not
    /// be able to change a verdict already recorded. Without this the hero
    /// stops being monotone: the same day could summarise differently on a
    /// later pass, when the attempts blob has moved on.
    ///
    /// Capped like every other array in the store, dropping oldest first.
    public static func merge(existing: [DayRecord], adding fresh: [DayRecord]) -> [DayRecord] {
        var byDay: [Date: DayRecord] = [:]
        for record in existing { byDay[record.dayStart] = record }
        for record in fresh where byDay[record.dayStart] == nil {
            byDay[record.dayStart] = record
        }
        var out = byDay.values.sorted { $0.dayStart < $1.dayStart }
        if out.count > recordCap { out.removeFirst(out.count - recordCap) }
        return out
    }

    /// How many closed days the store keeps — 2000, about 5.5 years, matching
    /// the convention every other array in `SharedStore` follows.
    public static let recordCap = 2000

    /// The permanent daily schedule's window, anchored at the day boundary.
    ///
    /// One minute short of a full turn, so the interval closes and reopens
    /// each day rather than being a single unbounded one — the reopening is
    /// what fires `intervalDidStart`, and the firing is the liveness record.
    ///
    /// Lives here rather than in `WallController` because the arithmetic
    /// borrows an hour whenever the boundary sits on the hour, which the
    /// default policy's 07:00 does — written the naive way it collapses start
    /// and end onto the same instant and the schedule is never a day long.
    public static func heartbeatWindow(anchoredAt boundary: TimeOfDay)
        -> (start: TimeOfDay, end: TimeOfDay) {
        (boundary, TimeOfDay(minutesSinceMidnight: boundary.minutes - 1))
    }

    /// The hero: whole days held, over closed observed days only.
    public static func daysHeld(_ records: [DayRecord]) -> Int {
        Int(records.reduce(0.0) { $0 + $1.fraction })
    }

    // MARK: The heartbeat log

    /// How many firings the store keeps. Strictly past `recordCap` (and
    /// `maxWalk`, which equals it) on purpose: `summarise` sets `observed`
    /// only from a beat inside the day, so the beat log must be able to vouch
    /// for at least as many days as a walk can ever summarise — a smaller cap
    /// would silently ring every day older than the beats that survived.
    public static let heartbeatCap = 2200

    /// The dedupe window: firings closer together than this are the daemon
    /// restating an interval, not a new day — unless the Silk day turned
    /// between them, which `heartbeatLog` checks separately.
    public static let heartbeatDedupe: TimeInterval = 3600

    /// Fold a firing into the beat log, or return nil when it is a
    /// restatement not worth a write.
    ///
    /// The dedupe cannot be a flat hour: `summarise` requires a beat strictly
    /// inside `[dayStart, dayEnd)` to mark the day observed, and re-arming the
    /// schedule on an app launch shortly before the boundary records a beat
    /// belonging to the CLOSING day — the daemon's genuine boundary firing
    /// then arrives within the hour and must not be swallowed, or a day the
    /// framework was demonstrably alive for is recorded dead (`observed`
    /// is written once and never revised). So a firing inside the window is
    /// still recorded when it falls in a later Silk day than the last one.
    ///
    /// `downHours` is optional because the writer (the monitor extension)
    /// reads it from a policy blob that can be absent; with no boundary to
    /// consult the flat window is all there is, and it fails toward a ring —
    /// the safe side.
    public static func heartbeatLog(_ beats: [Date], recording now: Date,
                                    downHours: DownHours?,
                                    calendar: Calendar = .current) -> [Date]? {
        // Self-heal a beat written under a clock that has since been corrected.
        // A stored beat further ahead of `now` than the dedupe window cannot be
        // jitter — it is a firing stamped by a forward-set clock, and left in
        // place it silences every genuine firing until real time passes it
        // (any real `now` is a "negative interval" against it), ringing every
        // honestly-lived day permanently. `missingBoundaries` already refuses
        // future-dated records; the beat log gets the same discipline. A beat
        // merely inside the window stays: the small-backwards case below is
        // pinned and heals by itself within the hour.
        var healed = beats
        healed.removeAll { $0.timeIntervalSince(now) >= heartbeatDedupe }
        let didHeal = healed.count != beats.count

        if let last = healed.last, now.timeIntervalSince(last) < heartbeatDedupe {
            // A clock that went backwards is also in here (negative interval);
            // dropping it keeps the log ordered.
            guard now > last, let downHours,
                  DayBoundary.dayStart(now: now, downHours: downHours, calendar: calendar)
                    != DayBoundary.dayStart(now: last, downHours: downHours, calendar: calendar)
            // A restatement is not worth a write — but a heal always is, or
            // the corrected log never lands and the fake beat stands forever.
            else { return didHeal ? healed : nil }
        }
        healed.append(now)
        if healed.count > heartbeatCap { healed.removeFirst(healed.count - heartbeatCap) }
        return healed
    }

    // MARK: The compaction gate

    /// The oldest instant a compaction may cut at: the end of the newest day
    /// in the *unbroken* summarised chain, clamped to `currentDayStart`.
    ///
    /// The record chain is anchored at the OLDEST record's time-of-day while
    /// `currentDayStart` comes from the live policy, and the moment the user
    /// moves when down hours end the two disagree. An old-anchored day then
    /// closes *after* the live boundary sweeps, and `compact(dayStart:
    /// currentDayStart)` would destroy that still-unsummarised day's grants —
    /// it would later be recorded with `grantedMinutes: 0`, permanently
    /// ("summarised once, never revised"). Compaction may only ever reach the
    /// frontier this returns; with no summarised past day at all, nothing may
    /// be dropped (`.distantPast`).
    ///
    /// Walked from the oldest record, not read off the newest: a hole behind
    /// the newest record — a day the self-healing walk still owes — is a day
    /// whose grants no record summarises, and a frontier past it would let the
    /// callers (which now compact to this frontier, gate or no gate) destroy
    /// them. The frontier stops at the first missing boundary.
    public static func compactionFrontier(recorded: Set<Date>,
                                          upTo currentDayStart: Date,
                                          calendar: Calendar = .current) -> Date {
        let past = recorded.filter { $0 < currentDayStart }
        guard let oldest = past.min() else { return .distantPast }
        var frontier = DayBoundary.nextDayStart(after: oldest, calendar: calendar)
        while frontier < currentDayStart, past.contains(frontier) {
            let next = DayBoundary.nextDayStart(after: frontier, calendar: calendar)
            guard next > frontier else { break }   // a boundary that cannot advance
            frontier = next
        }
        return min(frontier, currentDayStart)
    }

    // MARK: The corroboration horizon

    /// Evidence further than this past the last trusted instant is a claim,
    /// not a chain. Twice the longest legitimate Silk day, so no honest
    /// combination of DST, timezone travel and a missed firing can open it:
    /// a live daemon beats every day, and even a beat lost to a crash leaves
    /// the next one within two day-lengths of the one before.
    public static let evidenceGap: TimeInterval = 2 * sameSpan.max

    /// The newest evidence instant the chain can vouch for, or nil when no
    /// evidence is trusted at all.
    ///
    /// Evidence — heartbeats and attempts, taken together — is trusted only
    /// when it chains: each instant within `evidenceGap` of the last trusted
    /// one, anchored at the newest summarised day's end (`anchor`). An
    /// instant past the gap opens an *untrusted segment*: nothing in it is
    /// believed until the segment itself spans `sameSpan.min` — two chained
    /// daily beats — at which point the whole segment (and the gap behind it)
    /// is vouched for and the chain resumes from its end.
    ///
    /// Why: the daemon fires once at whatever boundary the clock claims, so a
    /// forward-set clock plants exactly ONE beat at the fake day's start.
    /// Under a bare `max()` that single beat was the newest evidence, vouched
    /// for the entire fabricated walk, and green-lit destroying every live
    /// grant. One isolated instant can be a lie; two instants a real day
    /// apart require the daemon to have genuinely lived through a day — which
    /// is also exactly what a real long absence produces on its second day
    /// back, so a genuine gap resumes after two beats while a clock blip
    /// never does.
    ///
    /// With no anchor (no summarised past day) every instant is trusted —
    /// the fresh-install bootstrap keeps its behavior.
    public static func corroborationHorizon(evidence: [Date],
                                            anchoredAt anchor: Date?) -> Date? {
        let sorted = evidence.sorted()
        guard let newest = sorted.last else { return nil }
        guard let anchor else { return newest }

        var trusted = anchor          // the gap baseline
        var horizon: Date?            // newest trusted evidence instant
        var segment: (first: Date, last: Date)?   // post-gap, not yet believed
        for instant in sorted {
            if let open = segment {
                if instant.timeIntervalSince(open.last) <= evidenceGap {
                    if instant.timeIntervalSince(open.first) >= sameSpan.min {
                        trusted = instant     // the segment matured: a real day
                        horizon = instant     // was lived past the gap
                        segment = nil
                    } else {
                        segment = (open.first, instant)
                    }
                } else {
                    segment = (instant, instant)   // the old blip never matured
                }
            } else if instant.timeIntervalSince(trusted) <= evidenceGap {
                trusted = max(trusted, instant)
                horizon = instant
            } else {
                segment = (instant, instant)
            }
        }
        return horizon
    }

    /// **The compaction gate.** Summarise every closed day that owes a record,
    /// persist it through `store`, read it back, and report whether compaction
    /// may proceed — to `currentDayStart`, which is what both callers pass to
    /// `compact(dayStart:)`.
    ///
    /// > No compaction without a record.
    ///
    /// Three refusals guard that rule, beyond the read-back proof itself:
    ///
    /// **Never past the frontier.** A `true` here green-lights
    /// `compact(dayStart: currentDayStart)`, so it may only be said when
    /// `compactionFrontier` has reached `currentDayStart` — every day before
    /// the cut is summarised. When the record chain's anchor lags the live
    /// boundary (down-hours end moved, timezone travel), the gate answers
    /// `false` and the ledger grows a little instead: the cheaper side of the
    /// trade, exactly as a record that failed to land is treated.
    ///
    /// **Never a day the world has not vouched for.** Under a forward-set
    /// clock, `currentDayStart` is a fabrication and the walk would owe every
    /// day between real time and the fake instant — each written as a
    /// permanent ring, evicting real history at the cap and green-lighting
    /// destruction of every live grant. So a boundary is summarised only when
    /// some TRUSTED instant — a heartbeat or an attempt on the corroboration
    /// chain (`corroborationHorizon`) — sits at or past it: proof the world
    /// reached that day. The daemon's own firing at the fake boundary does
    /// not qualify: an instant isolated past `evidenceGap` corroborates
    /// nothing until a second one a real day later joins it. With no evidence
    /// at all (a fresh install bootstrapping its first ring) the walk
    /// proceeds; the days the evidence cannot vouch for stay owed, which
    /// holds compaction.
    ///
    /// **Never keep a record from a day that has not happened.** A stored
    /// record dated at or past `currentDayStart` was written under a clock
    /// since corrected. Left standing, it satisfies the walk the moment real
    /// time reaches it, and the day the user actually lives through scores
    /// off hours that never existed. Deleting it revises no verdict — there
    /// was no day to have a verdict on — so it is purged here, and the real
    /// day is summarised from real counts when it genuinely closes.
    ///
    /// Lives here — pure, over an injected store — so the write-ordering
    /// protocol below is testable from `swift test` with a scripted
    /// concurrent writer, which no simulator race can pin reliably.
    ///
    /// **The stamp is read before the data it proves.** The proof-of-read
    /// protocol only works in one direction: stamp first, then records. Read
    /// the other way round, a concurrent writer landing between the two
    /// leaves the stamp already moved when it is first read, the pre-save
    /// check then "passes" against a records array from before the write, and
    /// the save erases the other process's records — the exact lost write the
    /// stamp exists to prevent. Both writers synchronise on the day boundary
    /// (the app's tick and `SpendIntent`'s sweep), so the window is
    /// correlated, not random.
    public static func recordClosedDays(upTo currentDayStart: Date,
                                        downHours: DownHours,
                                        ledger: GrantLedger,
                                        wallStanding: Bool,
                                        calendar: Calendar = .current,
                                        store: any DayRecordStore) -> Bool {
        let stampAtRead = store.daysStamp()
        let before = store.dayRecords()
        let owed = missingBoundaries(recorded: Set(before.map(\.dayStart)),
                                     upTo: currentDayStart,
                                     calendar: calendar)

        // A record dated at or past today was written under a clock since
        // corrected; purging it is part of any save this pass makes.
        let fabricated = before.contains { $0.dayStart >= currentDayStart }

        var fresh: [DayRecord] = []
        if !owed.isEmpty {
            // The whole blob, not a filtered slice — `summarise` decides
            // observability partly from whether the blob sits at its cap, and a
            // filtered slice cannot answer that.
            let blob = store.attemptsBlob()
            let beats = store.heartbeats()

            // The corroboration horizon: the newest instant the evidence
            // CHAIN vouches for — not the newest instant recorded, because
            // the daemon stamps one beat at whatever boundary the clock
            // claims, and a single far-future instant must corroborate
            // nothing (`corroborationHorizon`). A day past the horizon is a
            // day only the device clock claims occurred — its verdict waits,
            // and compaction waits with it. No evidence at all is the fresh
            // install writing its first ring, and walks unbounded.
            let evidence = blob + beats
            let anchor = before.lazy.map(\.dayStart)
                .filter { $0 < currentDayStart }.max()
                .map { DayBoundary.nextDayStart(after: $0, calendar: calendar) }
            let vouched: [Date]
            if evidence.isEmpty {
                vouched = owed
            } else if let horizon = corroborationHorizon(evidence: evidence,
                                                         anchoredAt: anchor) {
                vouched = owed.filter { $0 <= horizon }
            } else {
                vouched = []   // evidence exists and none of it is trusted
            }

            fresh = vouched.map { boundary in
                summarise(dayStart: boundary, downHours: downHours,
                          grants: ledger.grants, attempts: blob,
                          heartbeats: beats,
                          wallStanding: wallStanding, calendar: calendar)
            }
        }

        if !fresh.isEmpty || fabricated {
            // If another process wrote between our read and now, our copy is
            // stale and saving it wholesale would erase their records. Re-read
            // and merge onto what stands instead. Future-dated records are
            // dropped from the base before the merge, so the cap can never
            // evict a real day in favour of a fabricated one.
            let base = (store.daysStamp() == stampAtRead) ? before : store.dayRecords()
            let standing = base.filter { $0.dayStart < currentDayStart }
            store.save(dayRecords: merge(existing: standing, adding: fresh))
        }

        // Proof, not hope: re-read and confirm. A record that did not land
        // must hold the compaction, or its grants go with it. (Nothing owed
        // and nothing to purge is a true without a write, as ever.)
        let after = (fresh.isEmpty && !fabricated) ? before : store.dayRecords()
        let afterStarts = Set(after.map(\.dayStart))
        guard owed.allSatisfy({ afterStarts.contains($0) }) else { return false }

        // And never past the frontier: every owed day landing is not enough
        // when the chain's newest closed day ends after the cut the callers
        // will make.
        return compactionFrontier(recorded: afterStarts, upTo: currentDayStart,
                                  calendar: calendar) >= currentDayStart
    }
}

/// What the compaction gate needs from persistent storage, and nothing more.
/// `SharedStore` is the live conformance; tests script one to interleave a
/// concurrent writer at exact points, which is how the gate's ordering
/// protocol stays pinned from `swift test`.
public protocol DayRecordStore {
    /// Every closed day summarised so far, oldest first.
    func dayRecords() -> [DayRecord]
    /// The proof-of-read stamp under the current records blob; moves on every
    /// save, in any process.
    func daysStamp() -> String?
    /// The whole attempts blob, unfiltered.
    func attemptsBlob() -> [Date]
    /// Every recorded firing of the permanent daily schedule.
    func heartbeats() -> [Date]
    /// Persist the records wholesale and move the stamp.
    func save(dayRecords: [DayRecord])
}
