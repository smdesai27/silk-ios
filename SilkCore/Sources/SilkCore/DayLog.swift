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
    /// The wall stood and Silk could see it. Decided at write time and never
    /// revised — an unobserved day credits nothing, charges nothing, and
    /// draws a ring.
    public let observed: Bool

    public init(dayStart: Date, grantedMinutes: Int, reaches: Int,
                lateReaches: Int, observed: Bool) {
        self.dayStart = dayStart
        self.grantedMinutes = grantedMinutes
        self.reaches = reaches
        self.lateReaches = lateReaches
        self.observed = observed
    }

    /// The day's contribution. Frozen arithmetic over frozen fields: a record
    /// written once can never be recomputed into a different number, which is
    /// what makes the hero monotone rather than merely "usually rising".
    public var fraction: Double {
        guard observed else { return 0 }
        let cost = Double(grantedMinutes + reaches + lateReaches)
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

    /// Today's number before the day closes: the record's own equation, taken
    /// on the live counts. Defined beside `DayRecord.fraction` so the running
    /// hero and the record it becomes at the day's turn are one formula — the
    /// two can drift only by a coefficient change both would feel.
    public static func runningScore(grantedMinutes: Int, reaches: Int,
                                    lateReaches: Int) -> Int {
        let cost = Double(grantedMinutes + reaches + lateReaches)
        return Int((max(0, 1 - cost / allowance) * 100).rounded())
    }

    /// The cap `recordAttempt` enforces on the attempts blob. Mirrored here
    /// because §3.5's observability rule turns on the blob being *at* it.
    public static let attemptsCap = 2000

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
        if let last = beats.last, now.timeIntervalSince(last) < heartbeatDedupe {
            // A clock that went backwards is also in here (negative interval);
            // dropping it keeps the log ordered.
            guard now > last, let downHours,
                  DayBoundary.dayStart(now: now, downHours: downHours, calendar: calendar)
                    != DayBoundary.dayStart(now: last, downHours: downHours, calendar: calendar)
            else { return nil }
        }
        var out = beats
        out.append(now)
        if out.count > heartbeatCap { out.removeFirst(out.count - heartbeatCap) }
        return out
    }

    // MARK: The compaction gate

    /// **The compaction gate.** Summarise every closed day that owes a record,
    /// persist it through `store`, read it back, and report whether compaction
    /// may proceed.
    ///
    /// > No compaction without a record.
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
        guard !owed.isEmpty else { return true }

        // The whole blob, not a filtered slice — `summarise` decides
        // observability partly from whether the blob sits at its cap, and a
        // filtered slice cannot answer that.
        let blob = store.attemptsBlob()
        let beats = store.heartbeats()

        let fresh = owed.map { boundary in
            summarise(dayStart: boundary, downHours: downHours,
                      grants: ledger.grants, attempts: blob,
                      heartbeats: beats,
                      wallStanding: wallStanding, calendar: calendar)
        }

        // If another process wrote between our read and now, our copy is
        // stale and saving it wholesale would erase their records. Re-read and
        // merge onto what stands instead.
        let base = (store.daysStamp() == stampAtRead) ? before : store.dayRecords()
        store.save(dayRecords: merge(existing: base, adding: fresh))

        // Proof, not hope: re-read and confirm. A record that did not land
        // must hold the compaction, or its grants go with it.
        let after = Set(store.dayRecords().map(\.dayStart))
        return owed.allSatisfy { after.contains($0) }
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
